//
//  PeopleView.swift
//  HopChat-1
//
//  Contact list: search, presence, per-contact verification state, add by number
//  or import from the system address book, blocked contacts in their own section.
//
//  Design Contract §7 — contacts never expose IP/port to the user.
//

import SwiftUI

// MARK: - Verification state

/// How much we trust the key we hold for a contact.
nonisolated enum ContactTrustState: Equatable {
    /// The contact's signing key changed and the user has not reviewed it.
    case keyChanged
    /// Safety number compared and marked verified.
    case verified
    /// Pinned on first sight, never compared.
    case unverified

    var label: String {
        switch self {
        case .keyChanged: return String(localized: "Security code changed")
        case .verified:   return String(localized: "Verified")
        case .unverified: return String(localized: "Not verified")
        }
    }

    var symbol: String {
        switch self {
        case .keyChanged: return "exclamationmark.triangle.fill"
        case .verified:   return "checkmark.shield.fill"
        case .unverified: return "shield"
        }
    }

    var tint: Color {
        switch self {
        case .keyChanged: return .orange
        case .verified:   return .green
        case .unverified: return .secondary
        }
    }
}

@MainActor
func contactTrustState(for phone: String, trust: TrustStore) -> ContactTrustState {
    if trust.hasPendingKeyChange(phone) { return .keyChanged }
    return trust.isVerified(phone) ? .verified : .unverified
}

/// Small badge that always states its meaning in text as well as colour/shape.
struct ContactVerificationBadge: View {
    let state: ContactTrustState
    var showsLabel: Bool = false

    var body: some View {
        Group {
            if showsLabel {
                Label(state.label, systemImage: state.symbol)
            } else {
                Image(systemName: state.symbol)
            }
        }
        .font(.footnote)
        .foregroundStyle(state.tint)
        .accessibilityLabel(Text(state.label))
    }
}

// MARK: - People

struct PeopleView: View {

    @StateObject private var store = ConversationStore.shared
    @StateObject private var kad   = KademliaService.shared
    @StateObject private var trust = TrustStore.shared

    @State private var searchText = ""
    @State private var selectedContact: Contact?
    @State private var showAddByNumber = false
    @State private var showImportPicker = false
    @State private var importedContact: ImportedContact?
    @State private var prefill: ContactPrefill?
    @State private var showBlocked = false

    var body: some View {
        NavigationStack {
            List {
                if !pendingKeyChangeContacts.isEmpty {
                    Section {
                        ForEach(pendingKeyChangeContacts) { contact in
                            contactRow(contact)
                        }
                    } header: {
                        Text("Needs your attention")
                    } footer: {
                        Text("The security code for these contacts changed. Review it before sending anything else.")
                    }
                }

                Section {
                    if activeContacts.isEmpty {
                        emptyRow
                    } else {
                        ForEach(activeContacts) { contact in
                            contactRow(contact)
                        }
                    }
                } header: {
                    if !activeContacts.isEmpty { Text("Contacts") }
                }

                if !blockedContacts.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showBlocked) {
                            ForEach(blockedContacts) { contact in
                                contactRow(contact)
                            }
                        } label: {
                            Text("Blocked (\(blockedContacts.count))")
                        }
                    } footer: {
                        Text("Blocked people can't reach you. Their messages are dropped.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("People")
            .searchable(text: $searchText, prompt: Text("Search contacts"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            prefill = nil
                            showAddByNumber = true
                        } label: {
                            Label("Enter a Number", systemImage: "keyboard")
                        }
                        Button {
                            showImportPicker = true
                        } label: {
                            Label("Import from Contacts", systemImage: "person.crop.circle.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(Text("Add contact"))
                }
            }
            .sheet(item: $selectedContact) { contact in
                ContactDetailSheet(contact: contact)
            }
            .sheet(isPresented: $showAddByNumber) {
                ContactAddView(prefill: prefill)
            }
            .sheet(isPresented: $showImportPicker) {
                ContactPickerView { picked in
                    showImportPicker = false
                    guard let picked else { return }
                    if picked.numbers.count == 1 {
                        prefill = ContactPrefill(phone: picked.numbers[0], name: picked.name)
                        showAddByNumber = true
                    } else if picked.numbers.count > 1 {
                        importedContact = picked
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(item: $importedContact) { picked in
                ContactNumberChooser(contact: picked) { number in
                    importedContact = nil
                    guard let number else { return }
                    prefill = ContactPrefill(phone: number, name: picked.name)
                    showAddByNumber = true
                }
            }
        }
    }

    // MARK: Rows

    private func contactRow(_ contact: Contact) -> some View {
        Button {
            selectedContact = contact
        } label: {
            ContactRow(contact: contact,
                       presence: kad.presenceMap[contact.phone] ?? .offline,
                       trustState: contactTrustState(for: contact.phone, trust: trust),
                       avatarURL: avatarURL(for: contact))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens contact details"))
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(searchText.isEmpty ? "No contacts yet" : "No contacts match")
                .font(.headline)
            Text(searchText.isEmpty
                 ? "Add someone by their phone number, or import them from your address book."
                 : "Try a different name or number.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    // MARK: Data

    private func avatarURL(for contact: Contact) -> URL? {
        guard let filename = contact.avatarFilename else { return nil }
        return store.avatarURL(filename)
    }

    private var matching: [Contact] {
        let all = store.contacts.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.phone.contains(query)
        }
    }

    private var pendingKeyChangeContacts: [Contact] {
        matching.filter { !$0.isBlocked && trust.pendingKeyChanges.contains($0.phone) }
    }

    private var activeContacts: [Contact] {
        matching.filter { !$0.isBlocked && !trust.pendingKeyChanges.contains($0.phone) }
    }

    private var blockedContacts: [Contact] {
        matching.filter(\.isBlocked)
    }
}

// MARK: - Contact row

struct ContactRow: View {
    let contact: Contact
    let presence: PresenceStatus
    let trustState: ContactTrustState
    var avatarURL: URL? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: contact.displayName, imageURL: avatarURL, size: 44)
                PresenceDot(status: presence)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(contact.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    ContactVerificationBadge(state: trustState)
                }
                Text(contact.phone)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(presence.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var parts = [contact.displayName, contact.phone, trustState.label, presence.label]
        if contact.isBlocked { parts.append(String(localized: "Blocked")) }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    PeopleView()
}
