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

    // Swipe right on a bubble → reply; swipe left anywhere → reveal every time.
    @State private var replyingToID: String?
    @State private var replySwipeID: String?
    @State private var replySwipeOffset: CGFloat = 0
    @State private var timeReveal: CGFloat = 0
    @State private var scrollTarget: String?
    @State private var fluid = FluidScrollModel()
    /// Translated messages the user flipped back to the original text.
    @State private var showingOriginal: Set<String> = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let replyThreshold: CGFloat = 56
    private static let replyMaxOffset: CGFloat = 80
    private static let timeRevealWidth: CGFloat = 72
    private static let bottomID = "thread-bottom"

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

    /// Reachable directly on the local network right now.
    private var allParticipantsNearby: Bool {
        !participants.isEmpty && participants.allSatisfy { kad.presenceMap[$0] == .online }
    }

    private var anyParticipantNearby: Bool {
        participants.contains { kad.presenceMap[$0] == .online }
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
                         replyContext: replyingToID.map { replyPreview(for: $0) },
                         onCancelReply: { withAnimation(.snappy) { replyingToID = nil } },
                         onSend: send,
                         onImage: sendImage,
                         onTyping: notifyTyping)
        }
        .lavaBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) { translateMenu }
        }
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
            .background(Color.clear)
        }
        .buttonStyle(.plain)
        .background(Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([title, subtitle].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(Text(isGroup ? "Opens group details" : "Opens contact details"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Translate menu

    private var translateLanguage: String? {
        store.translateLanguage(for: conversationID)
    }

    private var translateMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { translateLanguage },
                set: { language in
                    showingOriginal.removeAll()
                    Task { await kad.setAutoTranslate(language, for: conversationID) }
                }
            )) {
                Label("Off", systemImage: "nosign").tag(String?.none)
                ForEach(TranslateLanguage.all) { language in
                    Text("\(language.flag) \(language.name)").tag(Optional(language.code))
                }
            } label: {
                Text("Auto-translate")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "translate")
                .symbolVariant(translateLanguage == nil ? .none : .circle.fill)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(Text("Auto-translate"))
        .accessibilityValue(Text(translateLanguage.map { TranslateLanguage.name(for: $0) }
                                 ?? String(localized: "Off")))
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
                            swipeableRow(for: message)
                                .fluidScrollRow(fluid)
                                .id(message.id)
                        }
                    }

                    if isTyping {
                        TypingBubble(name: isGroup ? nil : title)
                            .fluidScrollRow(fluid)
                            .id("typing")
                    }

                    // Scroll target for "the very end", below the last row's footer.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            // Open at the bottom, and stay pinned there while lazily built
            // rows (photos, translations, replies) settle into their real
            // heights — estimated heights are what left the thread short
            // of the last message.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .fluidScrollSource(fluid, enabled: !reduceMotion)
            .scrollDismissesKeyboard(.interactively)
            .task(id: conversationID) {
                // Once after the first layout pass, and again after images
                // and translations have had a moment to resolve.
                await Task.yield()
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: messages.last?.id) { _, id in
                guard id != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
                scrollTarget = nil
            }
            .onChange(of: isTyping) { _, typing in
                if typing { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
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
            replyPreview: message.replyToID.map { replyPreview(for: $0) },
            showsFooter: message.id == messages.last?.id,
            showsOriginal: showingOriginal.contains(message.id),
            onTapImage: { fullScreenImage = $0 },
            onRetry: { retry(message) },
            onTapReply: { scrollTarget = $0 }
        )
        .contextMenu { menu(for: message) }
    }

    /// A bubble plus both swipe behaviours. The reply arrow sits behind the
    /// bubble and fades in as it's dragged right; the time label waits just
    /// past the trailing edge and slides in as the whole row moves left.
    private func swipeableRow(for message: StoredMessage) -> some View {
        let offset = replySwipeID == message.id ? replySwipeOffset : 0
        let progress = min(offset / Self.replyThreshold, 1)

        return ZStack(alignment: .leading) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(8)
                .background(Color(.tertiarySystemFill), in: Circle())
                .scaleEffect(0.6 + 0.4 * progress)
                .opacity(progress)
                .padding(.leading, 14)
                .accessibilityHidden(true)

            bubble(for: message)
                .offset(x: offset)
        }
        .offset(x: -timeReveal)
        .overlay(alignment: .trailing) {
            revealedTime(for: message)
                .frame(width: Self.timeRevealWidth - 8, alignment: .leading)
                .offset(x: Self.timeRevealWidth - timeReveal)
                .opacity(timeReveal / Self.timeRevealWidth)
        }
        .contentShape(Rectangle())
        .gesture(HorizontalPanGesture(
            onChange: { dragChanged($0, on: message) },
            onEnd: { dragEnded($0, on: message) }
        ))
        .accessibilityAction(named: Text("Reply")) { startReply(to: message) }
    }

    private func revealedTime(for message: StoredMessage) -> some View {
        HStack(spacing: 3) {
            Text(ChatFormatters.time(message.timestamp))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            if message.route == .direct {
                DirectRouteIcon().font(.system(size: 8))
            }
            if message.isFromMe {
                MessageStatusIcon(status: message.status)
                    .font(.system(size: 8))
            }
        }
        .accessibilityHidden(true)
    }

    private func canReply(to message: StoredMessage) -> Bool {
        !message.isDeleted && message.kind != .system && !isSendBlocked
    }

    private func dragChanged(_ x: CGFloat, on message: StoredMessage) {
        if x < 0 {
            // Left: rubber-band past the reveal width.
            let pull = -x
            let width = Self.timeRevealWidth
            timeReveal = pull <= width ? pull : width + (pull - width) * 0.15
            replySwipeOffset = 0
        } else {
            timeReveal = 0
            guard canReply(to: message) else { return }
            let damped = x <= Self.replyThreshold ? x : Self.replyThreshold + (x - Self.replyThreshold) * 0.3
            let newOffset = min(damped, Self.replyMaxOffset)
            if replySwipeOffset < Self.replyThreshold, newOffset >= Self.replyThreshold {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            replySwipeID = message.id
            replySwipeOffset = newOffset
        }
    }

    private func dragEnded(_ x: CGFloat, on message: StoredMessage) {
        let triggered = replySwipeID == message.id && replySwipeOffset >= Self.replyThreshold
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            replySwipeOffset = 0
            timeReveal = 0
        }
        if triggered { startReply(to: message) }
    }

    private func startReply(to message: StoredMessage) {
        guard canReply(to: message) else { return }
        withAnimation(.snappy) { replyingToID = message.id }
    }

    private func replyPreview(for id: String) -> ReplyPreview {
        guard let original = messages.first(where: { $0.id == id }), !original.isDeleted else {
            return ReplyPreview(messageID: id,
                                author: "",
                                snippet: String(localized: "Original message unavailable"),
                                isImage: false,
                                isMissing: true)
        }
        let author = original.isFromMe
            ? String(localized: "You")
            : ConversationNaming.name(for: original.fromPhone, store: store)
        let isImage = original.kind == .image
        return ReplyPreview(messageID: id,
                            author: author,
                            snippet: isImage ? String(localized: "Photo") : (original.translatedBody ?? original.body),
                            isImage: isImage,
                            isMissing: false)
    }

    @ViewBuilder
    private func menu(for message: StoredMessage) -> some View {
        if canReply(to: message) {
            Button {
                startReply(to: message)
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        }

        if !message.isDeleted, message.kind == .text, !message.body.isEmpty {
            Button {
                UIPasteboard.general.string = showingOriginal.contains(message.id)
                    ? message.body
                    : (message.translatedBody ?? message.body)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }

        if message.translatedBody != nil, !message.isDeleted {
            let original = showingOriginal.contains(message.id)
            Button {
                if original {
                    showingOriginal.remove(message.id)
                } else {
                    showingOriginal.insert(message.id)
                }
            } label: {
                Label(original ? "Show translation" : "Show original",
                      systemImage: "character.bubble")
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
            if allParticipantsNearby {
                inlineNote(icon: "dot.radiowaves.left.and.right",
                           text: String(localized: "No internet — sending directly over this network."),
                           tint: .secondary)
            } else if anyParticipantNearby {
                inlineNote(icon: "wifi.exclamationmark",
                           text: String(localized: "No internet — nearby members get messages now, the rest when you're back online."),
                           tint: .secondary)
            } else {
                inlineNote(icon: "wifi.slash",
                           text: String(localized: "Messages will send when you're back online."),
                           tint: .secondary)
            }
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
        let replyTo = replyingToID
        replyingToID = nil
        Task { await kad.sendText(body, to: conversationID, replyingTo: replyTo) }
    }

    private func sendImage(_ jpeg: Data) {
        guard !isSendBlocked else { return }
        let replyTo = replyingToID
        replyingToID = nil
        Task { await kad.sendImage(jpeg, to: conversationID, replyingTo: replyTo) }
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
