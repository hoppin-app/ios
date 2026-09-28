//
//  GroupDetailView.swift
//  HopChat-1
//
//  Group members, admin actions (rename, add, remove) and leaving.
//
//  Admin state comes from the stored group, which the service only updates from
//  `groupUpdate` payloads signed by an existing admin — so the buttons below
//  mirror what the network will actually accept.
//

import SwiftUI
import os

struct GroupDetailView: View {

    let groupID: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ConversationStore.shared
    @StateObject private var kad = KademliaService.shared

    @State private var isRenaming = false
    @State private var newName = ""
    @State private var showAddMembers = false
    @State private var memberToRemove: String?
    @State private var showLeaveConfirmation = false
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var group: ChatGroup? { store.group(id: groupID) }
    private var isAdmin: Bool { group?.admins.contains(kad.myPhone) ?? false }

    var body: some View {
        Group {
            if let group {
                content(group)
            } else {
                ContentUnavailableView("Group unavailable",
                                       systemImage: "person.2.slash",
                                       description: Text("This group is no longer on this device."))
            }
        }
        .appBackground()
        .navigationTitle(Text("Group info"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func content(_ group: ChatGroup) -> some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AvatarView(name: group.name, imageURL: nil, size: 84)
                    Text(group.name)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("\(group.members.count) members")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
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

            if isAdmin, group.isActive {
                Section {
                    Button {
                        newName = group.name
                        isRenaming = true
                    } label: {
                        Label("Rename group", systemImage: "pencil")
                            .frame(minHeight: 44)
                    }
                    Button {
                        showAddMembers = true
                    } label: {
                        Label("Add members", systemImage: "person.badge.plus")
                            .frame(minHeight: 44)
                    }
                    .disabled(group.members.count >= AppConfig.maxGroupMembers)
                }
            }

            Section {
                ForEach(group.members, id: \.self) { phone in
                    memberRow(phone: phone, group: group)
                }
            } header: {
                Text("Members")
            } footer: {
                if group.members.count >= AppConfig.maxGroupMembers {
                    Text("This group is at the \(AppConfig.maxGroupMembers) member limit.")
                }
            }

            if group.isActive {
                Section {
                    Button(role: .destructive) {
                        showLeaveConfirmation = true
                    } label: {
                        Label("Leave group", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                            .frame(minHeight: 44)
                    }
                    .tint(.red)
                }
            }
        }
        .disabled(isWorking)
        .alert("Rename group", isPresented: $isRenaming) {
            TextField("Group name", text: $newName)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Remove member?",
               isPresented: Binding(get: { memberToRemove != nil },
                                    set: { if !$0 { memberToRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let phone = memberToRemove { Task { await remove(phone) } }
                memberToRemove = nil
            }
            Button("Cancel", role: .cancel) { memberToRemove = nil }
        } message: {
            Text("They'll stop receiving new messages in this group.")
        }
        .alert("Leave group?", isPresented: $showLeaveConfirmation) {
            Button("Leave", role: .destructive) {
                Task {
                    await kad.leaveGroup(groupID)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stop receiving messages from this group. You can only rejoin if an admin adds you back.")
        }
        .sheet(isPresented: $showAddMembers) {
            NavigationStack {
                AddGroupMembersView(groupID: groupID)
            }
        }
    }

    // MARK: Member row

    @ViewBuilder
    private func memberRow(phone: String, group: ChatGroup) -> some View {
        let isMe = phone == kad.myPhone
        let name = isMe ? String(localized: "You") : ConversationNaming.name(for: phone, store: store)
        let memberIsAdmin = group.admins.contains(phone)

        HStack(spacing: 12) {
            AvatarView(name: name,
                       imageURL: isMe ? nil : ConversationNaming.avatarURL(forPhone: phone, store: store),
                       size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                if name != phone {
                    Text(phone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if memberIsAdmin {
                Text("Admin")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(memberIsAdmin ? String(localized: "\(name), admin") : name))
        .swipeActions(edge: .trailing) {
            if isAdmin, !isMe, group.isActive {
                Button(role: .destructive) {
                    memberToRemove = phone
                } label: {
                    Label("Remove", systemImage: "person.badge.minus")
                }
            }
        }
    }

    // MARK: Actions

    private func rename() async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await kad.renameGroup(groupID, name: trimmed)
        } catch {
            errorMessage = describe(error)
            Log.ui.error("Group rename failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func remove(_ phone: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await kad.removeMember(phone, from: groupID)
        } catch {
            errorMessage = describe(error)
            Log.ui.error("Removing a group member failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Adding members

struct AddGroupMembersView: View {

    let groupID: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ConversationStore.shared
    @StateObject private var kad = KademliaService.shared

    @State private var selected: Set<String> = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var group: ChatGroup? { store.group(id: groupID) }

    private var candidates: [Contact] {
        let existing = Set(group?.members ?? [])
        return store.contacts
            .filter { !$0.isBlocked && !existing.contains($0.phone) && $0.phone != kad.myPhone }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var remainingSlots: Int {
        max(0, AppConfig.maxGroupMembers - (group?.members.count ?? AppConfig.maxGroupMembers))
    }

    var body: some View {
        Form {
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
                limit: remainingSlots,
                header: String(localized: "Add to group"),
                footer: String(localized: "\(remainingSlots - selected.count) slots left")
            )
        }
        .appBackground()
        .navigationTitle(Text("Add members"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await add() }
                } label: {
                    if isWorking { ProgressView() } else { Text("Add") }
                }
                .disabled(selected.isEmpty || isWorking)
            }
        }
    }

    private func add() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await kad.addMembers(Array(selected), to: groupID)
            dismiss()
        } catch {
            errorMessage = describe(error)
            Log.ui.error("Adding group members failed: \(String(describing: error), privacy: .public)")
        }
    }
}
