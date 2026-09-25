//
//  SettingsPrivacyView.swift
//  HopChat-1
//
//  Read receipts, typing indicators, app lock, blocked contacts, and an
//  honest description of what the relay server can see (contract §0, §5).
//

import SwiftUI
import os

struct SettingsPrivacyView: View {

    @StateObject private var lock = AppLock.shared
    @StateObject private var store = ConversationStore.shared
    @StateObject private var kad = KademliaService.shared

    @AppStorage(AppConfig.Keys.directInternet)     private var directInternet = true
    @AppStorage(AppConfig.Keys.sendReadReceipts)     private var readReceipts = true
    @AppStorage(AppConfig.Keys.sendTypingIndicators) private var typingIndicators = true

    @State private var appLockOn = false
    @State private var lockError: String?

    private let timeoutOptions: [(seconds: Int, label: String)] = [
        (0, String(localized: "Immediately")),
        (60, String(localized: "After 1 minute")),
        (300, String(localized: "After 5 minutes")),
        (900, String(localized: "After 15 minutes")),
    ]

    var body: some View {
        Form {
            Group {
                if kad.localNetworkDenied {
                    localNetworkSection
                }
                receiptsSection
                directDeliverySection
                appLockSection
                blockedSection
                relaySection
            }
            .glassListRows()
        }
        .lavaBackground()
        .navigationTitle(Text("Privacy & Security"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { appLockOn = lock.isEnabled }
        .onChange(of: appLockOn) { _, wanted in
            guard wanted != lock.isEnabled else { return }
            Task { await applyAppLock(wanted) }
        }
    }

    // MARK: - Local network

    private var localNetworkSection: some View {
        Section {
            Label {
                Text("Nearby delivery is off. hoppin can't reach people on the same Wi-Fi until you allow Local Network access.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
            }
        } header: {
            Text("Local Network")
        } footer: {
            Text("Settings ▸ hoppin ▸ Local Network. Messages still arrive through the relay meanwhile.")
        }
    }

    // MARK: - Receipts

    /// Direct delivery across the internet trades a little privacy for a lot
    /// of independence from the relay, so the trade is spelled out rather than
    /// buried.
    private var directDeliverySection: some View {
        Section {
            Toggle(isOn: Binding(get: { directInternet },
                                 set: { kad.setDirectInternetEnabled($0) })) {
                Text("Deliver directly when possible")
            }
            .accessibilityHint(Text("Sends messages straight to the other phone when it can be reached, instead of through the relay."))
        } header: {
            Text("Direct delivery")
        } footer: {
            Text("Messages go straight to the person you are writing to whenever their phone can be reached, instead of through the relay. To make that work, the people you message learn your phone's network address — roughly your city and internet provider. Turn this off to route everything through the relay, which sees the address instead.")
        }
    }

    private var receiptsSection: some View {
        Section {
            Toggle(isOn: $readReceipts) {
                Text("Send read receipts")
            }
            .accessibilityHint(Text("Lets people see when you have read their message. You will not see theirs if this is off."))

            Toggle(isOn: $typingIndicators) {
                Text("Send typing indicators")
            }
            .accessibilityHint(Text("Shows people when you are typing. Only sent over your local network, never through the relay."))
        } header: {
            Text("Messaging")
        }
    }

    // MARK: - App lock

    private var appLockSection: some View {
        Section {
            Toggle(isOn: $appLockOn) {
                Text("Require \(lock.authenticationName)")
            }
            .disabled(lock.isAuthenticating)
            .accessibilityHint(Text("Locks hoppin when you leave the app"))

            if lock.isEnabled {
                Picker(selection: timeoutBinding) {
                    ForEach(timeoutOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                } label: {
                    Text("Lock")
                }
                .pickerStyle(.navigationLink)
                .accessibilityHint(Text("How long hoppin can stay in the background before it locks"))
            }

            if let message = lockError ?? lock.lastFailureMessage, !lock.isEnabled {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("App lock")
        } footer: {
            Text("App lock covers the screen when hoppin is not in front. It does not add extra encryption to your messages — they are already encrypted on disk by iOS.")
        }
    }

    private var timeoutBinding: Binding<Int> {
        Binding(get: { lock.timeout }, set: { lock.timeout = $0 })
    }

    private func applyAppLock(_ wanted: Bool) async {
        lockError = nil
        if wanted {
            let ok = await lock.setEnabled(true)
            if !ok {
                appLockOn = false
                lockError = lock.lastFailureMessage ?? String(localized: "Could not turn on app lock.")
            }
        } else {
            lock.isEnabled = false
        }
        appLockOn = lock.isEnabled
    }

    // MARK: - Blocked

    private var blockedSection: some View {
        Section {
            NavigationLink {
                SettingsBlockedContactsView()
            } label: {
                LabeledContent {
                    Text("\(blockedCount)")
                } label: {
                    Text("Blocked contacts")
                }
            }
            .accessibilityLabel(Text("Blocked contacts, \(blockedCount)"))
        }
    }

    private var blockedCount: Int {
        store.contacts.filter(\.isBlocked).count
    }

    // MARK: - What the server sees

    private var relaySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("hoppin uses one relay server so messages reach you when your phone is offline.")
                Label {
                    Text("It cannot read your messages, see your photos, or know what you typed. Everything is sealed with keys that only you and the person you are writing to hold.")
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.green)
                }
                Label {
                    Text("It does see phone numbers — yours and the one you are writing to — along with your IP address and the time each message passes through.")
                } icon: {
                    Image(systemName: "eye.fill").foregroundStyle(.orange)
                }
                Text("On the same Wi-Fi, messages go straight to the other phone and the server sees nothing at all.")
            }
            .font(.subheadline)
            .padding(.vertical, 4)
            .fixedSize(horizontal: false, vertical: true)

            NavigationLink {
                SettingsServerDataView()
            } label: {
                Label("Your data on the relay", systemImage: "server.rack")
            }
        } header: {
            Text("What the server can see")
        }
    }
}

// MARK: - Blocked contacts

struct SettingsBlockedContactsView: View {

    @StateObject private var kad = KademliaService.shared
    @StateObject private var store = ConversationStore.shared

    private var blocked: [Contact] {
        store.contacts.filter(\.isBlocked).sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            Group {
                if blocked.isEmpty {
                    Section {
                        Text("You haven't blocked anyone.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(blocked) { contact in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.name)
                                    if contact.name != contact.phone {
                                        Text(contact.phone)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)

                                Spacer(minLength: 12)

                                Button("Unblock") {
                                    kad.unblock(phone: contact.phone)
                                    Log.ui.info("Unblocked a contact")
                                }
                                .buttonStyle(.bordered)
                                .frame(minHeight: 44)
                                .accessibilityLabel(Text("Unblock \(contact.name)"))
                            }
                            .padding(.vertical, 2)
                        }
                    } footer: {
                        Text("Blocked people cannot send you messages, and are not told that they are blocked.")
                    }
                }
            }
            .glassListRows()
        }
        .lavaBackground()
        .navigationTitle(Text("Blocked"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { SettingsPrivacyView() }
}
