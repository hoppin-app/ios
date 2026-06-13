//
//  HomeView.swift
//  HopChat-1
//
// Created by Rodrigo Loução on 08/04/2026.
//

import SwiftUI

// MARK: - Chat List

struct ChatListView: View {
    @StateObject private var store   = ConversationStore.shared
    @StateObject private var kad     = KademliaService.shared
    @State private var navPath       = NavigationPath()
    @State private var searchText    = ""
    @State private var showNewChat   = false

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {

                // MARK: Header
                HStack {
                    Image(systemName: "wifi")
                        .font(.system(size: 25))
                        .foregroundStyle(.blue)
                    Text("Messages")
                        .font(.system(size: 28, weight: .bold))
                    Spacer()
                    Button { showNewChat = true } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18))
                            .foregroundStyle(.blue)
                            .padding(10)
                            .background(Color(.systemGray6), in: Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // MARK: Search
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $searchText).font(.system(size: 16))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                // MARK: Conversation List
                if filteredContacts.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No conversations yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Button("Start a Chat") { showNewChat = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(filteredContacts) { contact in
                            ZStack {
                                NavigationLink(value: contact) { EmptyView() }
                                    .opacity(0)
                                ChatRowView(
                                    contact: contact,
                                    myPhone: kad.myPhone,
                                    presenceStatus: kad.presenceMap[contact.phone] ?? .offline,
                                    unreadCount: store.unreadCount(with: contact.phone, myPhone: kad.myPhone)
                                )
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowSeparatorTint(Color(.separator))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.deleteConversation(with: contact.phone, myPhone: kad.myPhone)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color(.systemBackground))
            .sheet(isPresented: $showNewChat) {
                NewChatSheet()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newContactRequest)) { note in
                guard let phone = note.userInfo?["phone"] as? String,
                      let ip    = note.userInfo?["ip"]    as? String,
                      let port  = note.userInfo?["port"]  as? UInt16 else { return }
                let contact = Contact(phone: phone, name: phone, ip: ip, port: port, addedAt: Date())
                ConversationStore.shared.addContact(contact)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openChat)) { note in
                guard let phone = note.userInfo?["phone"] as? String,
                      let contact = store.contact(for: phone) else { return }
                // Small delay so the tab switch animation completes first
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    navPath.append(contact)
                }
            }
            .onAppear { NotificationService.shared.clearBadge() }
            .navigationDestination(for: Contact.self) { contact in
                TextRoomView(contact: contact, myPhone: kad.myPhone)
            }
        }
    }

    private var filteredContacts: [Contact] {
        let all = store.contacts.filter {
            store.lastMessage(with: $0.phone, myPhone: kad.myPhone) != nil
        }
        if searchText.isEmpty { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) ||
                            $0.phone.contains(searchText) }
    }
}

// MARK: - Chat Row

struct ChatRowView: View {
    let contact:        Contact
    let myPhone:        String
    let presenceStatus: PresenceStatus
    let unreadCount:    Int

    private var last: StoredMessage? {
        ConversationStore.shared.lastMessage(with: contact.phone, myPhone: myPhone)
    }

    private var hasUnread: Bool { unreadCount > 0 }

    var body: some View {
        HStack(spacing: 14) {
            // Avatar with presence dot
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle().fill(Color(.systemGray4)).frame(width: 52, height: 52)
                    Text(initials).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                }
                PresenceDot(status: presenceStatus)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(contact.name)
                    .font(.system(size: 16, weight: hasUnread ? .bold : .semibold))
                Text(last?.body ?? "No messages yet")
                    .font(.system(size: 14, weight: hasUnread ? .medium : .regular))
                    .foregroundStyle(hasUnread ? .primary : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let last {
                    Text(timeString(last.timestamp))
                        .font(.system(size: 13))
                        .foregroundStyle(hasUnread ? .blue : .secondary)
                }
                if hasUnread {
                    Text("\(unreadCount)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, unreadCount > 9 ? 6 : 0)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(.blue, in: Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var initials: String {
        let parts = contact.name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init)
        return parts.isEmpty ? String(contact.name.prefix(2)).uppercased() : parts.joined()
    }

    private func timeString(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
        } else if cal.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let f = DateFormatter(); f.dateStyle = .short; return f.string(from: date)
        }
    }
}

// MARK: - Presence Dot

struct PresenceDot: View {
    let status: PresenceStatus

    var body: some View {
        Circle()
            .fill(status == .online ? Color.green : Color(.systemGray4))
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
    }
}

// MARK: - New Chat Sheet

struct NewChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var kad = KademliaService.shared
    @State private var phone     = ""
    @State private var name      = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact") {
                    TextField("Phone number", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("Display name (optional)", text: $name)
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        guard !phone.isEmpty else { return }
                        isLoading = true
                        error = nil
                        Task {
                            let ok = await kad.connectTo(phone: phone)
                            isLoading = false
                            if ok {
                                if !name.isEmpty,
                                   let idx = ConversationStore.shared.contacts.firstIndex(where: { $0.phone == phone }) {
                                    let c = ConversationStore.shared.contacts[idx]
                                    let updated = Contact(phone: c.phone, name: name,
                                                         ip: c.ip, port: c.port, addedAt: c.addedAt)
                                    ConversationStore.shared.addContact(updated)
                                }
                                dismiss()
                            } else {
                                error = "Could not reach \(phone). Make sure they're on the same WiFi and have HopChat open."
                            }
                        }
                    } label: {
                        if isLoading {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else {
                            Text("Connect")
                                .multilineTextAlignment(.center)
                        }
                    }
                    .disabled(phone.isEmpty || isLoading)
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ChatListView()
}
