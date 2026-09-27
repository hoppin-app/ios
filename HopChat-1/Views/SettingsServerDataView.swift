//
//  SettingsServerDataView.swift
//  HopChat-1
//
//  Everything the relay holds about this account, named plainly, next to the
//  things it deliberately does not hold (contract §0, §5). Every value here is
//  read from the device — the screen describes the record, it does not ask the
//  server to describe itself, because a server's own account of what it stores
//  is worth nothing.
//

import SwiftUI

struct SettingsServerDataView: View {

    @StateObject private var kad = KademliaService.shared

    private var certificate: IdentityCertificate? { CryptoManager.shared.certificate }

    var body: some View {
        Form {
            Group {
                heldSection
                notHeldSection
                avoidingSection
                removalSection
            }
            .glassListRows()
        }
        .lavaBackground()
        .navigationTitle(Text("Your Data"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Held

    private var heldSection: some View {
        Section {
            row(String(localized: "Phone number"),
                kad.myPhone.isEmpty ? String(localized: "Not verified") : kad.myPhone)

            if let certificate {
                row(String(localized: "Certificate issued"), stamp(certificate.issuedAt))
                row(String(localized: "Certificate expires"), stamp(certificate.expiresAt))
                row(String(localized: "Serial"), certificate.serial)
                keyRow(String(localized: "Signing key"), certificate.signingKey)
                keyRow(String(localized: "Agreement key"), certificate.agreementKey)
            }

            row(String(localized: "Relay"), AppConfig.serverHost)

            row(String(localized: "Notification token"),
                PushRegistration.shared.isRegisteredWithRelay
                    ? String(localized: "Registered")
                    : String(localized: "Not registered"))
        } header: {
            Text("What the relay holds")
        } footer: {
            Text("Both keys are public halves. They are how other people encrypt to you, and they reveal nothing about your messages. Undelivered messages sit on the relay as sealed envelopes and are erased the moment your phone collects them. The notification token lets the relay ask Apple to wake your phone; turning off message notifications removes it.")
        }
    }

    // MARK: - Not held

    private var notHeldSection: some View {
        Section {
            point("lock.fill", .green,
                  String(localized: "Your messages, photos and what you typed. They are sealed with keys the relay does not have."))
            point("person.2.slash.fill", .green,
                  String(localized: "Your contact list. It is never uploaded, so the relay cannot tell who you know."))
            point("key.slash.fill", .green,
                  String(localized: "Your private keys. They are generated on this device and never leave the Keychain."))
            point("externaldrive.badge.xmark", .green,
                  String(localized: "Your chat history. Conversations live on this device only."))
        } header: {
            Text("What it never sees")
        }
    }

    // MARK: - Unavoidable

    private var avoidingSection: some View {
        Section {
            point("eye.fill", .orange,
                  String(localized: "Your IP address, and the time each message passes through."))
            point("arrow.left.arrow.right", .orange,
                  String(localized: "Who you are writing to, whenever a message goes through the relay rather than straight to the other phone."))
        } header: {
            Text("What it can work out")
        } footer: {
            Text("Messages sent on the same Wi-Fi, over Bluetooth, or directly across the internet never reach the relay, so none of this is recorded for them.")
        }
    }

    // MARK: - Removal

    private var removalSection: some View {
        Section {
            NavigationLink {
                DeleteAccountView()
            } label: {
                Label("Delete account", systemImage: "trash")
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Deleting removes your certificate and any undelivered envelopes from the relay. Messages already delivered to other people stay on their phones.")
        }
    }

    // MARK: - Pieces

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Keys are long and nobody reads them in full; the ends are enough to
    /// compare against another device.
    private func keyRow(_ title: String, _ key: String) -> some View {
        row(title, key.count > 16 ? "\(key.prefix(8))…\(key.suffix(6))" : key)
    }

    private func point(_ icon: String, _ tint: Color, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .padding(.vertical, 2)
    }

    private func stamp(_ epochSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

#Preview {
    NavigationStack { SettingsServerDataView() }
}
