//
//  HomeView.swift
//  HopChat-1
//
//  `ChatListView` — the Chats tab. Lists 1:1 threads *and* groups, newest
//  activity first, with search, unread badges, presence, and swipe actions.
//
//  Performance note: the whole list is derived in a single pass over
//  `store.messages` (see `conversations`), so no row calls `store.thread(...)`
//  or re-scans the store while scrolling.
//

import SwiftUI
import os

// MARK: - Conversation summary

/// One row's worth of pre-computed data.
struct ConversationSummary: Identifiable, Equatable {
    let id: String            // conversationID
    let title: String
    let avatarURL: URL?
    let isGroup: Bool
    let peerPhone: String?    // nil for groups
    let groupID: String?      // nil for 1:1
    let last: StoredMessage?
    let sortDate: Date
    let unread: Int
    let isBlocked: Bool
    let searchHaystack: String
}

// MARK: - Naming helpers (shared with TextRoomView)

@MainActor
enum ConversationNaming {

    static func title(for conversationID: String, store: ConversationStore) -> String {
        if let groupID = ConversationStore.groupID(from: conversationID) {
            return store.group(id: groupID)?.name ?? String(localized: "Group")
        }
        return store.contact(for: conversationID)?.displayName ?? conversationID
    }

    static func avatarURL(for conversationID: String, store: ConversationStore) -> URL? {
        guard ConversationStore.groupID(from: conversationID) == nil,
              let filename = store.contact(for: conversationID)?.avatarFilename else { return nil }
        return store.avatarURL(filename)
    }

    static func name(for phone: String, store: ConversationStore) -> String {
        store.contact(for: phone)?.displayName ?? phone
    }

    static func avatarURL(forPhone phone: String, store: ConversationStore) -> URL? {
        guard let filename = store.contact(for: phone)?.avatarFilename else { return nil }
        return store.avatarURL(filename)
    }

    /// Preview line for a conversation row.
    static func preview(_ message: StoredMessage?) -> String {
        guard let message else { return String(localized: "No messages yet") }
        if message.isDeleted { return String(localized: "This message was deleted") }
        if message.kind == .image { return String(localized: "📷 Photo") }
        let body = message.translatedBody ?? message.body
        return body.isEmpty ? String(localized: "Message") : body
    }
}

// MARK: - Chat list

struct ChatListView: View {

    @StateObject private var store = ConversationStore.shared
    @StateObject private var kad = KademliaService.shared

    @State private var path: [String] = []
    @State private var searchText = ""
    @State private var showCompose = false
    @State private var conversationToDelete: ConversationSummary?
    @State private var groupToLeave: ConversationSummary?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if conversations.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text("Chats"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .principal) { connectionBadge }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel(Text("New conversation"))
                }
            }
            .searchable(text: $searchText, prompt: Text("Search chats"))
            .navigationDestination(for: String.self) { conversationID in
                TextRoomView(conversationID: conversationID)
            }
            .sheet(isPresented: $showCompose) {
                NewConversationSheet { conversationID in
                    showCompose = false
                    open(conversationID)
                }
            }
            .alert("Delete conversation?",
                   isPresented: Binding(get: { conversationToDelete != nil },
                                        set: { if !$0 { conversationToDelete = nil } })) {
                Button("Delete", role: .destructive) {
                    if let target = conversationToDelete {
                        store.deleteConversation(target.id)
                        Log.ui.info("Conversation deleted by the user")
                    }
                    conversationToDelete = nil
                }
                Button("Cancel", role: .cancel) { conversationToDelete = nil }
            } message: {
                Text("Messages in this chat will be removed from this device. This can't be undone.")
            }
            .alert("Leave group?",
                   isPresented: Binding(get: { groupToLeave != nil },
                                        set: { if !$0 { groupToLeave = nil } })) {
                Button("Leave", role: .destructive) {
                    if let groupID = groupToLeave?.groupID {
                        Task { await kad.leaveGroup(groupID) }
                    }
                    groupToLeave = nil
                }
                Button("Cancel", role: .cancel) { groupToLeave = nil }
            } message: {
                Text("You'll stop receiving messages from this group.")
            }
            .onAppear {
                NotificationService.shared.setBadge(store.totalUnreadCount)
                store.showTabBar = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openChat)) { note in
                guard let conversationID = note.userInfo?["conversationID"] as? String else { return }
                open(conversationID)
            }
        }
    }

    // MARK: Navigation

    private func open(_ conversationID: String) {
        // Groups and 1:1 chats use the same destination.
        if path.last == conversationID { return }
        path = [conversationID]
    }

    // MARK: Rows

    private var list: some View {
        List {
            ForEach(conversations) { conversation in
                ZStack {
                    NavigationLink(value: conversation.id) { EmptyView() }
                        .opacity(0)
                    ChatListRow(conversation: conversation,
                                presence: conversation.peerPhone.flatMap { kad.presenceMap[$0] })
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        conversationToDelete = conversation
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    if conversation.isGroup {
                        Button {
                            groupToLeave = conversation
                        } label: {
                            Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .tint(.orange)
                    } else if let phone = conversation.peerPhone, !conversation.isBlocked {
                        Button {
                            kad.block(phone: phone)
                            Log.ui.info("Contact blocked from the chat list")
                        } label: {
                            Label("Block", systemImage: "hand.raised")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: Connection badge

    @ViewBuilder
    private var connectionBadge: some View {
        switch kad.connectionState {
        case .online:
            EmptyView()
        case .connecting:
            Label {
                Text("Connecting…")
            } icon: {
                ProgressView().controlSize(.mini)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .offline:
            Label("Offline", systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Add someone by phone number, then start a chat. Everything you send is end-to-end encrypted.")
        } actions: {
            Button {
                showCompose = true
            } label: {
                Text("Start a chat")
                    .font(.body.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Derivation

    /// Single pass over the store: every thread plus every active group.
    private var conversations: [ConversationSummary] {
        var summaries: [ConversationSummary] = []
        var seenGroupConversations = Set<String>()

        for (conversationID, thread) in store.messages {
            let last = thread.last
            if let groupID = ConversationStore.groupID(from: conversationID) {
                guard let group = store.group(id: groupID) else { continue }
                seenGroupConversations.insert(conversationID)
                summaries.append(summary(for: group,
                                         conversationID: conversationID,
                                         last: last))
            } else {
                summaries.append(summary(forPeer: conversationID, last: last))
            }
        }

        // Groups with no messages yet still belong in the list.
        for group in store.groups {
            let conversationID = ConversationStore.conversationID(group: group.id)
            guard !seenGroupConversations.contains(conversationID) else { continue }
            summaries.append(summary(for: group, conversationID: conversationID, last: nil))
        }

        summaries.sort { $0.sortDate > $1.sortDate }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return summaries }
        return summaries.filter { $0.searchHaystack.localizedCaseInsensitiveContains(query) }
    }

    private func summary(forPeer phone: String, last: StoredMessage?) -> ConversationSummary {
        let contact = store.contact(for: phone)
        let title = contact?.displayName ?? phone
        return ConversationSummary(
            id: phone,
            title: title,
            avatarURL: contact?.avatarFilename.map { store.avatarURL($0) },
            isGroup: false,
            peerPhone: phone,
            groupID: nil,
            last: last,
            sortDate: last?.timestamp ?? contact?.addedAt ?? .distantPast,
            unread: store.unreadCount(phone),
            isBlocked: contact?.isBlocked ?? false,
            searchHaystack: [title, phone, last?.body ?? ""].joined(separator: " ")
        )
    }

    private func summary(for group: ChatGroup,
                         conversationID: String,
                         last: StoredMessage?) -> ConversationSummary {
        ConversationSummary(
            id: conversationID,
            title: group.name.isEmpty ? String(localized: "Group") : group.name,
            avatarURL: nil,
            isGroup: true,
            peerPhone: nil,
            groupID: group.id,
            last: last,
            sortDate: last?.timestamp ?? group.createdAt,
            unread: store.unreadCount(conversationID),
            isBlocked: false,
            searchHaystack: [group.name, last?.body ?? ""].joined(separator: " ")
        )
    }
}

// MARK: - Row

struct ChatListRow: View {

    let conversation: ConversationSummary
    let presence: PresenceStatus?

    private var hasUnread: Bool { conversation.unread > 0 }

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: conversation.title,
                           imageURL: conversation.avatarURL,
                           size: 52)
                if let presence {
                    PresenceDot(status: presence)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if conversation.isGroup {
                        Image(systemName: "person.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(conversation.title)
                        .font(.body.weight(hasUnread ? .bold : .semibold))
                        .lineLimit(1)
                    if conversation.isBlocked {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }

                Text(ConversationNaming.preview(conversation.last))
                    .font(.subheadline)
                    .foregroundStyle(hasUnread ? .primary : .secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if let last = conversation.last {
                    Text(ChatFormatters.listStamp(last.timestamp))
                        .font(.caption2)
                        .foregroundStyle(hasUnread ? .blue : Color(.tertiaryLabel))
                }
                if hasUnread {
                    Text(conversation.unread > 99 ? "99+" : "\(conversation.unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(.blue, in: Capsule())
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        var parts = [conversation.isGroup ? String(localized: "Group, \(conversation.title)") : conversation.title]
        parts.append(ConversationNaming.preview(conversation.last))
        if let last = conversation.last {
            parts.append(ChatFormatters.listStamp(last.timestamp))
        }
        if hasUnread {
            parts.append(String(localized: "\(conversation.unread) unread"))
        }
        if let presence, !conversation.isGroup {
            parts.append(presence.label)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - New conversation sheet

struct NewConversationSheet: View {

    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ConversationStore.shared
    @State private var searchText = ""
    @State private var showNewGroup = false

    private var contacts: [Contact] {
        let available = store.contacts
            .filter { !$0.isBlocked }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return available }
        return available.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.phone.contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showNewGroup = true
                    } label: {
                        Label {
                            Text("New group")
                                .font(.body)
                        } icon: {
                            Image(systemName: "person.3.fill")
                                .foregroundStyle(.blue)
                        }
                        .frame(minHeight: 44)
                    }
                }

                Section {
                    if contacts.isEmpty {
                        Text("No contacts yet. Add someone from the People tab first.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(contacts) { contact in
                            Button {
                                onPick(ConversationStore.conversationID(peer: contact.phone))
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarView(name: contact.displayName,
                                               imageURL: contact.avatarFilename.map { store.avatarURL($0) },
                                               size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contact.displayName)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        if contact.displayName != contact.phone {
                                            Text(contact.phone)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                        }
                    }
                } header: {
                    Text("New chat")
                }
            }
            .navigationTitle(Text("New conversation"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: Text("Search contacts"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showNewGroup) {
                NewGroupView { group in
                    onPick(ConversationStore.conversationID(group: group.id))
                }
            }
        }
    }
}

#Preview {
    ChatListView()
}
