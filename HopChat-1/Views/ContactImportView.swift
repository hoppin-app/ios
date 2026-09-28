//
//  ContactImportView.swift
//  HopChat-1
//
//  Importing a contact from the system address book with
//  `CNContactPickerViewController`, which runs out of process: the app never
//  gains access to the address book and **no Contacts permission is requested**.
//  We deliberately never touch `CNContactStore`.
//

import SwiftUI
import ContactsUI
import os

// MARK: - Picked contact

nonisolated struct ImportedContact: Identifiable, Hashable {
    let id = UUID()
    let name: String
    /// Raw numbers as written in the address book, de-duplicated.
    let numbers: [String]
}

// MARK: - Picker

/// Thin wrapper around `CNContactPickerViewController`.
/// `onPick` receives `nil` when the user cancels.
struct ContactPickerView: UIViewControllerRepresentable {

    let onPick: (ImportedContact?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Only people we could actually message.
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let onPick: (ImportedContact?) -> Void
        private var finished = false

        init(onPick: @escaping (ImportedContact?) -> Void) {
            self.onPick = onPick
        }

        nonisolated func contactPicker(_ picker: CNContactPickerViewController,
                                       didSelect contact: CNContact) {
            MainActor.assumeIsolated {
                guard !finished else { return }
                finished = true
                var seen = Set<String>()
                var numbers: [String] = []
                for value in contact.phoneNumbers {
                    let raw = value.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { continue }
                    // De-duplicate on the normalized form so "+351 912…" and
                    // "912…" are not offered twice.
                    let key = PhoneNumber.normalize(raw) ?? raw
                    if seen.insert(key).inserted { numbers.append(raw) }
                }
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                Log.ui.debug("contact picker returned \(numbers.count, privacy: .public) number(s)")
                onPick(ImportedContact(name: name, numbers: numbers))
            }
        }

        nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            MainActor.assumeIsolated {
                guard !finished else { return }
                finished = true
                onPick(nil)
            }
        }
    }
}

// MARK: - Number chooser

/// Shown when the imported contact has more than one phone number.
struct ContactNumberChooser: View {

    let contact: ImportedContact
    /// `nil` when the user backs out.
    let onChoose: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(contact.numbers, id: \.self) { number in
                        Button {
                            onChoose(number)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(number)
                                    .foregroundStyle(.primary)
                                if let normalized = PhoneNumber.normalize(number), normalized != number {
                                    Text(normalized)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: 44)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(contact.name.isEmpty ? "Choose a number" : contact.name)
                } footer: {
                    Text("Pick the number this person uses on hoppin.")
                }
            }
            .appBackground()
            .navigationTitle("Choose Number")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onChoose(nil) }
                }
            }
        }
    }
}
