//
//  ReportView.swift
//  HopChat-1
//
//  Report a contact to the operator, with an explicit opt-in before any message
//  text leaves the device, and a block-as-well option (on by default).
//

import SwiftUI
import os

nonisolated enum ReportReason: String, CaseIterable, Identifiable {
    case spam
    case harassment
    case impersonation
    case illegal
    case other

    nonisolated var id: String { rawValue }

    var title: String {
        switch self {
        case .spam:          return String(localized: "Spam or scam")
        case .harassment:    return String(localized: "Harassment or abuse")
        case .impersonation: return String(localized: "Pretending to be someone else")
        case .illegal:       return String(localized: "Illegal content")
        case .other:         return String(localized: "Something else")
        }
    }
}

struct ReportView: View {

    let contact: Contact

    @StateObject private var kad   = KademliaService.shared
    @StateObject private var store = ConversationStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var reason: ReportReason = .spam
    @State private var details = ""
    @State private var includeMessages = false
    @State private var blockToo = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false

    private var evidence: [StoredMessage] {
        store.recentMessages(with: contact.phone, limit: 20)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Why are you reporting \(contact.displayName)?")
                }

                Section {
                    TextField("Add details (optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityLabel(Text("Additional details, optional"))
                } footer: {
                    Text(reason == .other
                         ? "Tell us what happened so we can review it."
                         : "Anything else we should know?")
                }

                Section {
                    Toggle("Include my recent messages from this person so we can review them",
                           isOn: $includeMessages)
                        .frame(minHeight: 44)
                    if includeMessages && !evidence.isEmpty {
                        DisclosureGroup("Preview what would be sent (\(evidence.count))") {
                            ForEach(evidence) { message in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(message.body)
                                        .font(.footnote)
                                    Text(message.timestamp, style: .date)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                } header: {
                    Text("Evidence")
                } footer: {
                    if includeMessages {
                        Text(evidence.isEmpty
                             ? "You have no received messages from this person to include."
                             : "These messages will be sent to the hoppin operator in readable form. Nothing else from your chats is shared.")
                    } else {
                        Text("Off by default. Your messages stay end-to-end encrypted and the operator cannot read them unless you turn this on.")
                    }
                }

                Section {
                    Toggle("Block this person too", isOn: $blockToo)
                        .frame(minHeight: 44)
                } footer: {
                    Text("Blocking stops their messages from reaching you. You can unblock them later from their contact page.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting { ProgressView() } else { Text("Submit Report") }
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(isSubmitting || (reason == .other && details.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Report sent", isPresented: $didSubmit) {
                Button("Done") { dismiss() }
            } message: {
                Text(blockToo
                     ? "Thanks, we'll review it. This person is now blocked."
                     : "Thanks, we'll review it.")
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasonString = trimmed.isEmpty ? reason.rawValue : "\(reason.rawValue): \(trimmed)"
        do {
            try await kad.report(phone: contact.phone,
                                 reason: reasonString,
                                 includeRecentMessages: includeMessages)
            if blockToo { kad.block(phone: contact.phone) }
            Log.ui.notice("report submitted")
            didSubmit = true
        } catch let error as ServiceError {
            // Blocking is local, so honour it even when the report could not be sent.
            if blockToo { kad.block(phone: contact.phone) }
            let detail = error.errorDescription ?? String(localized: "Couldn't send the report.")
            errorMessage = String(localized: "\(detail) Your report wasn't sent. Try again when you're back online.")
        } catch {
            if blockToo { kad.block(phone: contact.phone) }
            errorMessage = String(localized: "Couldn't send the report. Check your connection and try again.")
        }
    }
}
