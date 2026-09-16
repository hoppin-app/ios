//
//  GroupCreateView.swift
//  HopChat-1
//
//  `NewGroupView` — name plus a multi-select of existing contacts.
//
//  Group membership is fanned out client-side, so the cap in
//  `AppConfig.maxGroupMembers` (32, *including* you) is enforced here as well as
//  in the service; the picker simply stops letting you add more.
//

import SwiftUI
import os

// MARK: - New group

struct NewGroupView: View {

    /// Called with the created group so the caller can open it.
    var onCreated: (ChatGroup) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ConversationStore.shared
    @StateObject private var kad = KademliaService.shared

    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var isCreating = false
    @State private var errorMessage: String?

    /// The creator counts toward the cap.
    private var maxOthers: Int { max(0, AppConfig.maxGroupMembers - 1) }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selected.isEmpty
            && !isCreating
    }

    var body: some View {
        Form {
            Section {
                TextField("Group name", text: $name)
                    .font(.body)
                    .textInputAutocapitalization(.words)
            } header: {
                Text("Name")
            }

            if let errorMessage {
                Section {
                    Label {
                        Text(errorMessage)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                }
            }

            ContactMultiPickerSection(
                selected: $selected,
                candidates: candidates,
                limit: maxOthers,
                header: String(localized: "Members"),
                footer: String(localized: "\(selected.count + 1) of \(AppConfig.maxGroupMembers) members")
            )
        }
        .navigationTitle(Text("New group"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await create() }
                } label: {
                    if isCreating {
                        ProgressView()
                    } else {
                        Text("Create")
                    }
                }
                .disabled(!canCreate)
            }
        }
    }

    private var candidates: [Contact] {
        store.contacts
            .filter { !$0.isBlocked && $0.phone != kad.myPhone }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let group = try await kad.createGroup(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                members: Array(selected)
            )
            Log.ui.info("Group created with \(group.members.count, privacy: .public) members")
            onCreated(group)
            dismiss()
        } catch {
            errorMessage = describe(error)
            Log.ui.error("Group creation failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Reusable member picker

struct ContactMultiPickerSection: View {

    @Binding var selected: Set<String>
    let candidates: [Contact]
    let limit: Int
    let header: String
    var footer: String?

    @StateObject private var store = ConversationStore.shared

    var body: some View {
        Section {
            if candidates.isEmpty {
                Text("No contacts available. Add people from the People tab first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { contact in
                    let isSelected = selected.contains(contact.phone)
                    let isDisabled = !isSelected && selected.count >= limit

                    Button {
                        toggle(contact.phone)
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: contact.displayName,
                                       imageURL: contact.avatarFilename.map { store.avatarURL($0) },
                                       size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.displayName)
                                    .font(.body)
                                    .foregroundStyle(isDisabled ? .secondary : .primary)
                                if contact.displayName != contact.phone {
                                    Text(contact.phone)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.blue : Color(.tertiaryLabel))
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .disabled(isDisabled)
                    .accessibilityLabel(Text(contact.displayName))
                    .accessibilityValue(Text(isSelected ? "Selected" : "Not selected"))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
        } header: {
            Text(header)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }

    private func toggle(_ phone: String) {
        if selected.contains(phone) {
            selected.remove(phone)
        } else if selected.count < limit {
            selected.insert(phone)
        }
    }
}

// MARK: - Error text

@MainActor
func describe(_ error: Error) -> String {
    if let serviceError = error as? ServiceError {
        return serviceError.errorDescription ?? String(localized: "Something went wrong.")
    }
    return error.localizedDescription
}
