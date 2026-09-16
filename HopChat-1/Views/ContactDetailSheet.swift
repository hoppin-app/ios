//
//  ContactDetailSheet.swift
//  HopChat-1
//
//  Everything about one contact: message them, verify them, block, report,
//  delete. No IP or port — that was an internal detail v1 leaked to users.
//

import SwiftUI
import os

struct ContactDetailSheet: View {

    init(contact: Contact) {
        self.initialContact = contact
    }

    private let initialContact: Contact

    @StateObject private var store = ConversationStore.shared
    @StateObject private var kad   = KademliaService.shared
    @StateObject private var trust = TrustStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showEditName = false
    @State private var editedName = ""
    @State private var confirmDelete = false
    @State private var showReport = false
    @State private var confirmBlock = false

    /// Always render the live record so blocking/renaming updates in place.
    private var contact: Contact {
        store.contact(for: initialContact.phone) ?? initialContact
    }

    private var trustState: ContactTrustState {
        contactTrustState(for: contact.phone, trust: trust)
    }

    private var hasKeyChange: Bool { trust.pendingKeyChanges.contains(contact.phone) }

    var body: some View {
        NavigationStack {
            List {
                if hasKeyChange {
                    Section {
                        KeyChangeBanner(phone: contact.phone) {
                            keyChangeDestination = .verify
                        } onAccept: {
                            Task { await kad.acceptKeyChange(phone: contact.phone) }
                        }
                        NavigationLink {
                            ContactKeyChangeView(contact: contact)
                        } label: {
                            Label("Review Security Code Change", systemImage: "exclamationmark.triangle.fill")
                                .frame(minHeight: 44)
                        }
                    }
                }

                Section {
                    header
                }

                Section {
                    NavigationLink {
                        TextRoomView(contact: contact)
                    } label: {
                        Label("Send Message", systemImage: "bubble.left")
                            .frame(minHeight: 44)
                    }
                    .disabled(contact.isBlocked)
                }

                Section {
                    infoRow(title: String(localized: "Encryption"),
                            value: kad.isEncryptionReady(for: contact.phone)
                                ? String(localized: "End-to-end encrypted")
                                : String(localized: "Waiting for their key"),
                            symbol: kad.isEncryptionReady(for: contact.phone) ? "lock.fill" : "lock.open")
                    NavigationLink {
                        SafetyNumberView(contact: contact)
                    } label: {
                        HStack {
                            Text("Verification")
                            Spacer()
                            ContactVerificationBadge(state: trustState, showsLabel: true)
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text("Verification, \(trustState.label)"))
                    }
                    infoRow(title: String(localized: "Added"), value: addedText, symbol: nil)
                } header: {
                    Text("Security")
                } footer: {
                    Text("Verify the safety number to be sure you're talking to the right person.")
                }

                Section {
                    Button {
                        editedName = contact.name
                        showEditName = true
                    } label: {
                        Label("Edit Name", systemImage: "pencil")
                            .frame(minHeight: 44)
                    }

                    Button {
                        if contact.isBlocked {
                            kad.unblock(phone: contact.phone)
                            Log.ui.notice("contact unblocked")
                        } else {
                            confirmBlock = true
                        }
                    } label: {
                        Label(contact.isBlocked ? "Unblock" : "Block",
                              systemImage: contact.isBlocked ? "hand.raised.slash" : "hand.raised")
                            .frame(minHeight: 44)
                    }

                    Button {
                        showReport = true
                    } label: {
                        Label("Report", systemImage: "flag")
                            .frame(minHeight: 44)
                    }

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete Contact", systemImage: "trash")
                            .frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle("Contact")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $keyChangeDestination) { _ in
                SafetyNumberView(contact: contact,
                                 theirSigningKey: trust.pendingCertificate(for: contact.phone)?.signingKey)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showReport) {
                ReportView(contact: contact)
            }
            .alert("Edit Name", isPresented: $showEditName) {
                TextField("Display name", text: $editedName)
                Button("Save") {
                    let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    store.renameContact(phone: contact.phone, newName: trimmed)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This name is only visible to you.")
            }
            .confirmationDialog("Block \(contact.displayName)?",
                                isPresented: $confirmBlock,
                                titleVisibility: .visible) {
                Button("Block", role: .destructive) {
                    kad.block(phone: contact.phone)
                    Log.ui.notice("contact blocked")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Their messages won't reach you. They aren't told that you blocked them.")
            }
            .confirmationDialog("Delete \(contact.displayName)?",
                                isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete Contact and Messages", role: .destructive) {
                    store.removeContact(phone: contact.phone, deleteMessages: true)
                    dismiss()
                }
                Button("Delete Contact Only", role: .destructive) {
                    store.removeContact(phone: contact.phone, deleteMessages: false)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Do you want to delete your conversation with them as well? Deleted messages can't be recovered.")
            }
        }
    }

    // MARK: - Pieces

    @State private var keyChangeDestination: KeyChangeRoute?

    private enum KeyChangeRoute: Hashable, Identifiable {
        case verify
        var id: Int { 0 }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AvatarView(name: contact.displayName, imageURL: avatarURL, size: 88)
                .accessibilityHidden(true)
            Text(contact.displayName)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text(contact.phone)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(spacedDigits(contact.phone)))
            if contact.isBlocked {
                Label("Blocked", systemImage: "hand.raised.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var avatarURL: URL? {
        guard let filename = contact.avatarFilename else { return nil }
        return store.avatarURL(filename)
    }

    private var addedText: String {
        contact.addedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private func infoRow(title: String, value: String, symbol: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), \(value)"))
    }
}
