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
                ForEach(filteredContacts) { contact in
                    ContactRow(contact: contact, myPhone: kad.myPhone,
                               presenceStatus: kad.presenceMap[contact.phone] ?? .offline)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedContact = contact }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.removeContact(phone: contact.phone)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
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

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle()
                        .fill(avatarColor(for: contact.name))
                        .frame(width: 52, height: 52)
                    Text(initials)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
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
}

// MARK: - Contact Detail Sheet

struct ContactDetailSheet: View {
    let contact: Contact
    @Environment(\.dismiss) private var dismiss
    @StateObject private var kad   = KademliaService.shared
    @StateObject private var store = ConversationStore.shared
    @State private var confirmDelete = false
    @State private var showEditName  = false
    @State private var editedName    = ""

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

                    Section {
                        Button {
                            editedName = contact.name
                            showEditName = true
                        } label: {
                            Label("Edit Name", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete Contact")
                                Spacer()
                            }
                        }
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
            .confirmationDialog(
                "Delete \(contact.name)?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Contact", role: .destructive) {
                    store.removeContact(phone: contact.phone)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove the contact.")
            }
            .alert("Edit Name", isPresented: $showEditName) {
                TextField("Display name", text: $editedName)
                Button("Save") {
                    let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    store.renameContact(phone: contact.phone, newName: trimmed)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This name is only visible to you.")
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
