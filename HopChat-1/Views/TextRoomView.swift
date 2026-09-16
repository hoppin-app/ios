//
//  TextRoomView.swift
//  HopChat-1
//
//  One conversation — 1:1 or group, same view. Identified only by its
//  `conversationID` (a phone number, or "group:<uuid>").
//
//  Security surface, which is the point of this screen:
//   • An unacknowledged key change for any participant pins a `KeyChangeBanner`
//     above the composer and disables sending, because the service will throw
//     `keyChangeUnacknowledged` anyway — better to say so than to fail silently.
//   • `isEncryptionReady(for:)` false → an explicit "can't encrypt yet" state
//     rather than messages that quietly never leave.
//   • `connectionState != .online` → an offline note; messages still queue.
//

import SwiftUI
import UIKit

// MARK: - Row model

private enum ChatRowItem: Identifiable {
    case day(Date)
    case message(StoredMessage)

    var id: String {
        switch self {
        case .day(let date):    return "day-\(Int(date.timeIntervalSince1970))"
        case .message(let msg): return msg.id
        }
    }
}

// MARK: - View

struct TextRoomView: View {

    let conversationID: String

    init(conversationID: String) {
        self.conversationID = conversationID
    }

    /// Convenience for callers that already have the contact in hand.
    init(contact: Contact) {
        self.conversationID = ConversationStore.conversationID(peer: contact.phone)
    }

    @StateObject private var store = ConversationStore.shared
    @StateObject private var kad = KademliaService.shared
    @ObservedObject private var trust = TrustStore.shared

    @State private var draft = ""
    @State private var fullScreenImage: URL?
    @State private var showGroupDetail = false
    @State private var showContactDetail = false
    @State private var pendingDeleteForEveryone: StoredMessage?

    // MARK: Derived state

    private var isGroup: Bool { ConversationStore.groupID(from: conversationID) != nil }
    private var group: ChatGroup? {
        ConversationStore.groupID(from: conversationID).flatMap { store.group(id: $0) }
    }
    private var contact: Contact? {
        isGroup ? nil : store.contact(for: conversationID)
    }

    private var messages: [StoredMessage] {
        store.messages[conversationID] ?? []
    }

    private var participants: [String] {
        if let group { return group.members.filter { $0 != kad.myPhone } }
        return [conversationID]
    }

    /// Participants whose signing key changed and the user hasn't reviewed.
    private var keyChangePhones: [String] {
        participants.filter { trust.pendingKeyChanges.contains($0) }
    }

    private var isEncryptionReady: Bool {
        kad.isEncryptionReady(for: conversationID)
    }

    private var isSendBlocked: Bool {
        !keyChangePhones.isEmpty || (group?.isActive == false)
    }

    private var title: String {
        ConversationNaming.title(for: conversationID, store: store)
    }

    private var subtitle: String? {
        if let group {
            return group.isActive
                ? String(localized: "\(group.members.count) members")
                : String(localized: "You left this group")
        }
        return kad.presenceMap[conversationID]?.label
    }

    private var rows: [ChatRowItem] {
        var out: [ChatRowItem] = []
        var lastDay: Date?
        let calendar = Calendar.current
        for message in messages {
            let day = calendar.startOfDay(for: message.timestamp)
            if lastDay != day {
                out.append(.day(day))
                lastDay = day
            }
            out.append(.message(message))
        }
        return out
    }

    private var isTyping: Bool { kad.typingPeers.contains(conversationID) }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            messageList
            banners
            ChatComposer(text: $draft,
                         isSendBlocked: isSendBlocked,
                         blockedReason: blockedReason,
                         placeholder: String(localized: "Message"),
                         onSend: send,
                         onImage: sendImage,
                         onTyping: notifyTyping)
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { header } }
        .sheet(item: $fullScreenImage) { url in
            FullScreenImageViewer(url: url)
        }
        .sheet(isPresented: $showGroupDetail) {
            if let group {
                NavigationStack { GroupDetailView(groupID: group.id) }
            }
        }
        // TODO(people agent): `ContactDetailSheet` lives in Views/PeopleView.swift.
        // If that type is renamed, update this call site.
        .sheet(isPresented: $showContactDetail) {
            if let contact {
                ContactDetailSheet(contact: contact)
            }
        }
        .alert("Delete for everyone?",
               isPresented: Binding(get: { pendingDeleteForEveryone != nil },
                                    set: { if !$0 { pendingDeleteForEveryone = nil } })) {
            Button("Delete", role: .destructive) {
                if let message = pendingDeleteForEveryone {
                    Task { await kad.deleteForEveryone(messageID: message.id,
                                                       conversationID: conversationID) }
                }
                pendingDeleteForEveryone = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteForEveryone = nil }
        } message: {
            Text("Everyone in this chat will see that the message was deleted.")
        }
        .onAppear {
            NotificationService.shared.activeConversationID = conversationID
            kad.markRead(conversationID: conversationID)
            store.showTabBar = false
        }
        .onDisappear {
            if NotificationService.shared.activeConversationID == conversationID {
                NotificationService.shared.activeConversationID = nil
            }
            store.showTabBar = true
        }
        .onChange(of: messages.count) { _, _ in
            // New mail while the thread is open counts as read.
            kad.markRead(conversationID: conversationID)
        }
    }

    // MARK: Header

    private var header: some View {
        Button {
            if isGroup {
                showGroupDetail = true
            } else if contact != nil {
                showContactDetail = true
            }
        } label: {
            HStack(spacing: 10) {
                AvatarView(name: title,
                           imageURL: ConversationNaming.avatarURL(for: conversationID, store: store),
                           size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([title, subtitle].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(Text(isGroup ? "Opens group details" : "Opens contact details"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if messages.isEmpty {
                        emptyThread
                    }

                    ForEach(rows) { row in
                        switch row {
                        case .day(let date):
                            DaySeparator(date: date)
                        case .message(let message):
                            bubble(for: message)
                                .id(message.id)
                        }
                    }

                    if isTyping {
                        TypingBubble(name: isGroup ? nil : title)
                            .id("typing")
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            .onChange(of: isTyping) { _, typing in
                if typing { proxy.scrollTo("typing", anchor: .bottom) }
            }
        }
    }

    private func bubble(for message: StoredMessage) -> some View {
        ChatMessageBubble(
            message: message,
            senderName: (isGroup && !message.isFromMe)
                ? ConversationNaming.name(for: message.fromPhone, store: store)
                : nil,
            imageURL: message.imageFilename.map { store.imageURL($0) },
            onTapImage: { fullScreenImage = $0 },
            onRetry: { retry(message) }
        )
        .contextMenu { menu(for: message) }
    }

    @ViewBuilder
    private func menu(for message: StoredMessage) -> some View {
        if !message.isDeleted, message.kind == .text, !message.body.isEmpty {
            Button {
                UIPasteboard.general.string = message.translatedBody ?? message.body
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }

        if message.isFromMe, message.status == .failed {
            Button {
                retry(message)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }

        Button(role: .destructive) {
            store.deleteMessageLocally(messageID: message.id, conversationID: conversationID)
        } label: {
            Label("Delete for me", systemImage: "trash")
        }

        if message.isFromMe, !message.isDeleted {
            Button(role: .destructive) {
                pendingDeleteForEveryone = message
            } label: {
                Label("Delete for everyone", systemImage: "trash.slash")
            }
        }
    }

    private var emptyThread: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Messages here are end-to-end encrypted.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Say hello to start the conversation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 48)
        .padding(.bottom, 24)
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        if let phone = keyChangePhones.first {
            KeyChangeBanner(
                phone: ConversationNaming.name(for: phone, store: store),
                onVerify: {
                    if isGroup {
                        showGroupDetail = true
                    } else {
                        showContactDetail = true
                    }
                },
                onAccept: {
                    Task { await kad.acceptKeyChange(phone: phone) }
                }
            )
        } else if group?.isActive == false {
            inlineNote(icon: "rectangle.portrait.and.arrow.right",
                       text: String(localized: "You left this group."),
                       tint: .secondary)
        } else if !isEncryptionReady {
            inlineNote(icon: "lock.trianglebadge.exclamationmark",
                       text: String(localized: "Can't encrypt yet — verifying \(title)'s keys."),
                       tint: .orange)
        } else if kad.connectionState != .online {
            inlineNote(icon: "wifi.slash",
                       text: String(localized: "Messages will send when you're back online."),
                       tint: .secondary)
        }
    }

    private func inlineNote(icon: String, text: String, tint: Color) -> some View {
        Label {
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private var blockedReason: String? {
        if !keyChangePhones.isEmpty {
            return String(localized: "Review the security code change before sending.")
        }
        if group?.isActive == false {
            return String(localized: "You can't send messages to a group you've left.")
        }
        return nil
    }

    // MARK: Actions

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSendBlocked else { return }
        draft = ""
        Task { await kad.sendText(body, to: conversationID) }
    }

    private func sendImage(_ jpeg: Data) {
        guard !isSendBlocked else { return }
        Task { await kad.sendImage(jpeg, to: conversationID) }
    }

    private func retry(_ message: StoredMessage) {
        Task { await kad.retry(messageID: message.id, conversationID: conversationID) }
    }

    private func notifyTyping() {
        guard UserDefaults.standard.bool(forKey: AppConfig.Keys.sendTypingIndicators) else { return }
        kad.userIsTyping(in: conversationID)
    }
}

// MARK: - URL as a sheet item

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
