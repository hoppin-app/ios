//
//  ContactAddView.swift
//  HopChat-1
//
//  Add a contact by phone number (typed, or pre-filled from the address-book
//  picker). The number is normalized to E.164 before it is sent anywhere.
//

import SwiftUI
import os

nonisolated struct ContactPrefill: Identifiable, Hashable {
    let id = UUID()
    let phone: String
    let name: String
}

struct ContactAddView: View {

    var prefill: ContactPrefill? = nil

    @StateObject private var kad = KademliaService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var rawPhone = ""
    @State private var name = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var notOnHopChat = false
    @State private var addedName: String?

    private var normalized: String? { PhoneNumber.normalize(rawPhone) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Phone number", text: $rawPhone)
                        .keyboardType(.numbersAndPunctuation)
                        .textContentType(.telephoneNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: rawPhone) { _, new in
                            let clean = PhoneNumber.sanitizeInput(new)
                            if clean != new { rawPhone = clean }
                        }
                        .frame(minHeight: 44)
                        .accessibilityLabel(Text("Phone number"))
                    TextField("Name (optional)", text: $name)
                        .textContentType(.name)
                        .frame(minHeight: 44)
                        .accessibilityLabel(Text("Name, optional"))
                } header: {
                    Text("Contact")
                } footer: {
                    if let normalized {
                        Text("Will be added as \(normalized)")
                            .accessibilityLabel(Text("Will be added as \(spacedDigits(normalized))"))
                    } else if !rawPhone.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("That doesn't look like a valid phone number. Include the country code, for example +351 912 345 678.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Include the country code, for example +351 912 345 678.")
                    }
                }

                if notOnHopChat {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("They're not on HopChat yet", systemImage: "person.crop.circle.badge.questionmark")
                                .font(.headline)
                            Text("Send them an invite and try again once they've joined.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ShareLink(item: AppConfig.inviteURL) {
                                Label("Invite them", systemImage: "square.and.arrow.up")
                                    .frame(minHeight: 44)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await add() }
                    } label: {
                        HStack {
                            Spacer()
                            if isAdding {
                                ProgressView()
                            } else {
                                Text("Add Contact")
                            }
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(normalized == nil || isAdding)
                }
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let prefill, rawPhone.isEmpty {
                    rawPhone = prefill.phone
                    name = prefill.name
                }
            }
            .alert("Contact added",
                   isPresented: Binding(get: { addedName != nil },
                                        set: { if !$0 { addedName = nil } })) {
                Button("Done") {
                    addedName = nil
                    dismiss()
                }
            } message: {
                Text("\(addedName ?? "") was added. Messages to them are end-to-end encrypted.")
            }
        }
    }

    private func add() async {
        guard let phone = normalized else { return }
        isAdding = true
        errorMessage = nil
        notOnHopChat = false
        defer { isAdding = false }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let contact = try await kad.addContact(phone: phone,
                                                   name: trimmedName.isEmpty ? nil : trimmedName)
            Log.ui.notice("contact added")
            addedName = contact.displayName
        } catch ServiceError.notOnHopChat {
            notOnHopChat = true
        } catch let error as ServiceError {
            errorMessage = error.errorDescription ?? String(localized: "Couldn't add this contact.")
        } catch {
            errorMessage = String(localized: "Couldn't add this contact. Check your connection and try again.")
        }
    }
}

/// Reads a number/digit string aloud one character at a time for VoiceOver.
nonisolated func spacedDigits(_ s: String) -> String {
    s.map { String($0) }.joined(separator: " ")
}
