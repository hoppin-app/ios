//
//  AccountDeleteView.swift
//  HopChat-1
//
//  Account deletion + local wipe. Presented from Settings; initialisable with
//  no arguments. Deliberately explicit about what disappears — this is the one
//  screen in the app with no undo.
//

import SwiftUI
import os

struct DeleteAccountView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = KademliaService.shared

    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var showFinalAlert = false
    @FocusState private var focused: Bool

    private var isConfirmed: Bool {
        confirmation.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE"
    }

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                section(title: Text("Removed from the server"),
                        icon: "server.rack",
                        items: [
                            Text("Your identity certificate, so nobody can look you up on hoppin."),
                            Text("Every sealed message still waiting in your relay mailbox — undelivered messages are lost."),
                            Text("Your registration, freeing the number for a future sign-up."),
                        ])

                section(title: Text("Erased from this iPhone"),
                        icon: "iphone.slash",
                        items: [
                            Text("All conversations, including group chats."),
                            Text("All photos you sent or received in hoppin."),
                            Text("Your contacts, blocks and safety-number verifications."),
                            Text("Your encryption keys and every app setting."),
                        ])

                Label {
                    Text("This cannot be undone. hoppin keeps no backup — not on the server, not in iCloud.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Type DELETE to confirm")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("DELETE", text: $confirmation)
                        .font(.system(.title3, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                        .accessibilityLabel(Text("Type the word DELETE to confirm"))
                }

                if let errorText {
                    ErrorNotice(text: errorText)
                }

                Button(role: .destructive) {
                    showFinalAlert = true
                } label: {
                    Group {
                        if isWorking {
                            ProgressView()
                        } else {
                            Text("Delete My Account").font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!isConfirmed || isWorking || !service.isRegistered)

                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Keep My Account")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(Text("Delete Account"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(Text("Delete your hoppin account?"), isPresented: $showFinalAlert) {
            Button(role: .cancel) { } label: { Text("Cancel") }
            Button(role: .destructive) { performDelete() } label: { Text("Delete Everything") }
        } message: {
            Text("Your account and everything hoppin stores on this iPhone will be erased. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "trash.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text("Delete Account")
                .font(.system(.title, design: .rounded).weight(.bold))

            if !service.myPhone.isEmpty {
                Text("Signed in as \(service.myPhone)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section(title: Text, icon: String, items: [Text]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { title.font(.headline) } icon: {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
            }
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "minus")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    items[i]
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Delete

    private func performDelete() {
        guard isConfirmed, !isWorking else { return }
        focused = false
        errorText = nil
        isWorking = true
        Task {
            do {
                try await service.deleteAccountAndWipe()
                Log.ui.info("Account deleted and local state wiped")
                // The root view watches `isRegistered` and returns to onboarding.
                dismiss()
            } catch {
                errorText = offlineAwareText(for: error)
                Log.ui.error("Account deletion failed: \(String(describing: error), privacy: .public)")
            }
            isWorking = false
        }
    }

    private func offlineAwareText(for error: Error) -> String {
        if let service = error as? ServiceError, service == .unavailable {
            return String(localized: "hoppin couldn't reach the server, so nothing was deleted. Your messages are still here. Connect to the internet and try again.")
        }
        return VerificationErrorText.text(for: error)
    }
}

#Preview {
    NavigationStack { DeleteAccountView() }
}
