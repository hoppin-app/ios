//
//  HomeView.swift
//  HopChat-1
//
//  `ChatListView` — the Chats tab. Lists 1:1 threads *and* groups, newest
//  activity first, with search, unread badges, presence, and swipe actions.
//  The ⋯ menu selects several chats (archive / read / delete together) or
//  marks everything read; archived chats live behind an "Archived" row.
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
    let isArchived: Bool
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

    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var showingArchived = false
    @State private var confirmBulkDelete = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if visibleConversations.isEmpty && archivedCount == 0 && !showingArchived {
                    emptyState
                } else {
                    list
                }
            }
            .appBackground()
            .navigationTitle(showingArchived ? Text("Archived") : Text("Chats"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) { leadingToolbar }
                ToolbarItem(placement: .principal) { connectionBadge }
                ToolbarItem(placement: .primaryAction) {
                    if isSelecting {
                        Button {
                            let all = Set(visibleConversations.map(\.id))
                            selection = selection == all ? [] : all
                        } label: {
                            Text(selection.count == visibleConversations.count && !selection.isEmpty
                                 ? "Deselect All" : "Select All")
                        }
                    } else {
                        Button {
                            showCompose = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel(Text("New conversation"))
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting { selectionBar }
            }
            .alert(Text("Delete \(selection.count) chats?"), isPresented: $confirmBulkDelete) {
                Button("Delete", role: .destructive) {
                    for id in selection { store.deleteConversation(id) }
                    Log.ui.info("Deleted \(selection.count, privacy: .public) conversations")
                    endSelecting()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Messages in these chats will be removed from this device. This can't be undone.")
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

    // MARK: Menu and selection

    @ViewBuilder
    private var leadingToolbar: some View {
        if isSelecting {
            Button {
                endSelecting()
            } label: {
                Text("Done").fontWeight(.semibold)
            }
        } else {
            if showingArchived {
                Button {
                    withAnimation { showingArchived = false }
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel(Text("Back to chats"))
            }

            Menu {
                Button {
                    withAnimation { isSelecting = true }
                    store.showTabBar = false
                } label: {
                    Label("Select Chats", systemImage: "checkmark.circle")
                }
                .disabled(visibleConversations.isEmpty)

                Button {
                    kad.markAllRead()
                } label: {
                    Label("Read All", systemImage: "envelope.open")
                }
                .disabled(store.totalUnreadCount == 0)

                if !showingArchived {
                    Button {
                        withAnimation { showingArchived = true }
                    } label: {
                        Label("Archived Chats", systemImage: "archivebox")
                    }
                    .disabled(archivedCount == 0)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("More"))
        }
    }

    private var selectionBar: some View {
        let empty = selection.isEmpty
        let hasUnread = visibleConversations.contains { selection.contains($0.id) && $0.unread > 0 }
        return HStack {
            Button {
                store.setArchived(!showingArchived, for: Array(selection))
                endSelecting()
            } label: {
                Label(showingArchived ? "Unarchive" : "Archive",
                      systemImage: showingArchived ? "tray.and.arrow.up" : "archivebox")
            }
            .disabled(empty)

            Spacer()

            Button {
                for id in selection { kad.markRead(conversationID: id) }
                endSelecting()
            } label: {
                Label("Read", systemImage: "envelope.open")
            }
            .disabled(empty || !hasUnread)

            Spacer()

            Button(role: .destructive) {
                confirmBulkDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(empty)
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func endSelecting() {
        withAnimation {
            isSelecting = false
            selection = []
        }
        store.showTabBar = true
    }

    private var archivedRow: some View {
        Button {
            withAnimation { showingArchived = true }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "archivebox.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 52)
                Text("Archived")
                    .font(.body.weight(.semibold))
                Spacer()
                if archivedUnread > 0 {
                    Text("\(archivedUnread)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Palette.violet, in: Capsule())
                }
                Text("\(archivedCount)")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Archived chats, \(archivedCount)"))
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
            if !showingArchived, !isSelecting, archivedCount > 0, searchText.isEmpty {
                archivedRow
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            if visibleConversations.isEmpty, showingArchived {
                Text("No archived chats")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .listRowBackground(Color.clear)
            }

            ForEach(visibleConversations) { conversation in
                row(for: conversation)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        store.setArchived(!conversation.isArchived, for: [conversation.id])
                    } label: {
                        if conversation.isArchived {
                            Label("Unarchive", systemImage: "tray.and.arrow.up")
                        } else {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                    .tint(.gray)

                    if conversation.unread > 0 {
                        Button {
                            kad.markRead(conversationID: conversation.id)
                        } label: {
                            Label("Read", systemImage: "envelope.open")
                        }
                        .tint(Palette.violet)
                    }
                }
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

    /// Opens the chat normally; in select mode the same tap toggles a checkmark.
    /// (A `List(selection:)` would swallow the taps that open chats.)
    @ViewBuilder
    private func row(for conversation: ConversationSummary) -> some View {
        let content = ChatListRow(conversation: conversation,
                                  presence: conversation.peerPhone.flatMap { kad.presenceMap[$0] })
        if isSelecting {
            let isSelected = selection.contains(conversation.id)
            Button {
                if isSelected {
                    selection.remove(conversation.id)
                } else {
                    selection.insert(conversation.id)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    content
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        } else {
            // Hidden link keeps the row free of the disclosure chevron.
            ZStack {
                NavigationLink(value: conversation.id) { EmptyView() }
                    .opacity(0)
                content
            }
        }
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
                .foregroundStyle(Palette.warn)
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
                    .padding(.horizontal, 24)
            }
            .buttonStyle(.ink)
        }
    }

    // MARK: Derivation

    /// What the list shows: the archive or everything else.
    private var visibleConversations: [ConversationSummary] {
        conversations.filter { $0.isArchived == showingArchived }
    }

    private var archivedCount: Int {
        store.contacts.filter { $0.isArchived == true && store.messages[$0.phone]?.isEmpty == false }.count
            + store.groups.filter { $0.isArchived == true }.count
    }

    private var archivedUnread: Int {
        store.contacts.filter { $0.isArchived == true }.reduce(0) { $0 + store.unreadCount($1.phone) }
            + store.groups.filter { $0.isArchived == true }
                .reduce(0) { $0 + store.unreadCount(ConversationStore.conversationID(group: $1.id)) }
    }

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
            isArchived: contact?.isArchived ?? false,
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
            isArchived: group.isArchived ?? false,
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
                        .foregroundStyle(hasUnread ? Color.accentColor : Color(.tertiaryLabel))
                }
                if hasUnread {
                    Text(conversation.unread > 99 ? "99+" : "\(conversation.unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Palette.violet, in: Capsule())
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
                                .foregroundStyle(Color.accentColor)
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
            .appBackground()
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
