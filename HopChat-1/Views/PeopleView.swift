//
//  PeopleView.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 08/04/2026.
//
//  Contacts page — shows every contact the user has added.
//

import SwiftUI

struct PeopleView: View {
    @StateObject private var store = ConversationStore.shared
    @StateObject private var kad   = KademliaService.shared
    @State private var searchText  = ""
    @State private var showNewChat = false
    @State private var selectedContact: Contact?
    @State private var selectedTab = 1

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // MARK: Header
                HStack {
                    Image(systemName: "person.2")
                        .font(.system(size: 22))
                        .foregroundStyle(.blue)
                    Text("People")
                        .font(.system(size: 28, weight: .bold))
                    Spacer()
                    Button { showNewChat = true } label: {
                        Image(systemName: "person.badge.plus")
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
                    TextField("Search contacts", text: $searchText).font(.system(size: 16))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                // MARK: Body
                if store.contacts.isEmpty {
                    emptyState
                } else if filteredContacts.isEmpty {
                    noResultsState
                } else {
                    contactList
                }
            }
            .background(Color(.systemBackground))
            .sheet(isPresented: $showNewChat) { NewChatSheet() }
            .sheet(item: $selectedContact) { contact in
                ContactDetailSheet(contact: contact)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        TabBarItem(icon: "bubble.left",  label: "CHATS",    isSelected: selectedTab == 0) { selectedTab = 0 }
                        TabBarItem(icon: "person",        label: "PEOPLE",   isSelected: selectedTab == 1) { selectedTab = 1 }
                        TabBarItem(icon: "gearshape",     label: "SETTINGS", isSelected: selectedTab == 2) { selectedTab = 2 }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .background(Color(.systemBackground))
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedTab == 0 },
                set: { if !$0 { selectedTab = 1 } }
            )) {
                ChatListView().navigationBarBackButtonHidden(true)
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedTab == 2 },
                set: { if !$0 { selectedTab = 1 } }
            )) {
                SettingsView().navigationBarBackButtonHidden(true)
            }
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 90, height: 90)
                Image(systemName: "person.2")
                    .font(.system(size: 38))
                    .foregroundStyle(.blue.opacity(0.7))
            }
            VStack(spacing: 6) {
                Text("No contacts yet")
                    .font(.system(size: 20, weight: .semibold))
                Text("Add someone on the same WiFi\nto start chatting.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showNewChat = true
            } label: {
                Label("Add Contact", systemImage: "person.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 13)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("No contacts match \"\(searchText)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Contact List

    private var contactList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Online section (placeholder — contacts with recent activity)
                let online = filteredContacts // In a real app, filter by presence
                ForEach(online) { contact in
                    ContactRow(contact: contact, myPhone: kad.myPhone,
                               presenceStatus: kad.presenceMap[contact.phone] ?? .offline)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedContact = contact }
                    Divider().padding(.leading, 78)
                }
            }
            .padding(.bottom, 20)
        }
    }

    private var filteredContacts: [Contact] {
        let all = store.contacts.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !searchText.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.phone.contains(searchText)
        }
    }
}

// MARK: - Contact Row

struct ContactRow: View {
    let contact:        Contact
    let myPhone:        String
    let presenceStatus: PresenceStatus

    private var presenceLabel: String { presenceStatus.rawValue }

    private var presenceColor: Color {
        switch presenceStatus {
        case .online:   return .green
        case .recently: return .orange
        case .offline:  return .secondary
        }
    }

    // kept for fallback
    private var lastSeen: String {
        if let last = ConversationStore.shared.lastMessage(with: contact.phone, myPhone: myPhone) {
            let cal = Calendar.current
            if cal.isDateInToday(last.timestamp) {
                let f = DateFormatter(); f.timeStyle = .short
                return "Active \(f.string(from: last.timestamp))"
            } else if cal.isDateInYesterday(last.timestamp) {
                return "Active yesterday"
            }
        }
        return "Added \(shortDate(contact.addedAt))"
    }

    var body: some View {
        HStack(spacing: 14) {
            // Avatar
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(avatarColor(for: contact.name))
                    .frame(width: 52, height: 52)
                Text(initials)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                PresenceDot(status: presenceStatus)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(contact.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(contact.phone)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text(presenceLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(presenceColor)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var initials: String {
        let parts = contact.name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? String(contact.name.prefix(1)).uppercased() : letters
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }
}

// MARK: - Contact Detail Sheet

struct ContactDetailSheet: View {
    let contact: Contact
    @Environment(\.dismiss) private var dismiss
    @StateObject private var kad = KademliaService.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Hero avatar
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(avatarColor(for: contact.name))
                            .frame(width: 88, height: 88)
                        Text(initials)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(spacing: 4) {
                        Text(contact.name)
                            .font(.system(size: 22, weight: .bold))
                        Text(contact.phone)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 28)

                // Action button
                NavigationLink {
                    TextRoomView(contact: contact, myPhone: kad.myPhone)
                } label: {
                    Label("Send Message", systemImage: "bubble.left.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)

                // Info rows
                List {
                    Section("Connection Info") {
                        LabeledContent("IP Address", value: contact.ip)
                        LabeledContent("Port", value: "\(contact.port)")
                        LabeledContent("Added", value: {
                            let f = DateFormatter()
                            f.dateStyle = .long
                            return f.string(from: contact.addedAt)
                        }())
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var initials: String {
        let parts = contact.name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? String(contact.name.prefix(1)).uppercased() : letters
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }
}

#Preview {
    PeopleView()
}
