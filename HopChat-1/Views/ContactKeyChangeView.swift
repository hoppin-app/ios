//
//  ContactKeyChangeView.swift
//  HopChat-1
//
//  Resolving a changed signing key: what changed, what it might mean, and the
//  two ways out — verify the new safety number, or accept the new key.
//

import SwiftUI
import os

struct ContactKeyChangeView: View {

    let contact: Contact

    @StateObject private var kad   = KademliaService.shared
    @StateObject private var trust = TrustStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var confirmAccept = false

    private var previousKey: String? { trust.pinnedSigningKey(for: contact.phone) }
    private var pendingCertificate: IdentityCertificate? { trust.pendingCertificate(for: contact.phone) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Security code changed", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("The encryption key hoppin has for \(contact.displayName) is not the one it saw before. Messages to them are held back until you decide.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Section {
                keyRow(title: String(localized: "Key hoppin trusted"), value: previousKey)
                keyRow(title: String(localized: "New key"), value: pendingCertificate?.signingKey)
                if let issued = pendingCertificate?.issuedAt {
                    HStack {
                        Text("New key issued")
                        Spacer()
                        Text(Date(timeIntervalSince1970: TimeInterval(issued)), style: .date)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text("What changed")
            } footer: {
                Text("This can happen when someone reinstalls hoppin or changes phone. It can also mean someone is impersonating them.")
            }

            Section {
                NavigationLink {
                    SafetyNumberView(contact: contact,
                                     theirSigningKey: pendingCertificate?.signingKey)
                } label: {
                    Label("Verify Now", systemImage: "qrcode.viewfinder")
                        .frame(minHeight: 44)
                }

                Button {
                    confirmAccept = true
                } label: {
                    Label("Accept New Key", systemImage: "checkmark.circle")
                        .frame(minHeight: 44)
                }
            } header: {
                Text("What you can do")
            } footer: {
                Text("Verifying compares a safety number with them in person or over a call you trust. That is the only way to be sure. Accepting simply trusts the new key so you can keep messaging, and it will no longer be marked verified.")
            }
        }
        .navigationTitle("Security Code")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Accept the new key for \(contact.displayName)?",
                            isPresented: $confirmAccept,
                            titleVisibility: .visible) {
            Button("Accept New Key") {
                Task {
                    await kad.acceptKeyChange(phone: contact.phone)
                    Log.ui.notice("key change accepted from UI")
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll be able to send messages again. If you haven't checked with them another way, you can't be sure who is on the other end.")
        }
    }

    private func keyRow(title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
            Text(value.map(Self.shortKey) ?? String(localized: "Unknown"))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// First 16 characters of the key, in groups of four — enough to see at a
    /// glance that two keys differ, without pretending to be a fingerprint.
    nonisolated static func shortKey(_ key: String) -> String {
        let chars = Array(key.prefix(16))
        var groups: [String] = []
        var i = 0
        while i < chars.count {
            let end = min(i + 4, chars.count)
            groups.append(String(chars[i..<end]))
            i = end
        }
        return groups.joined(separator: " ") + "…"
    }
}
