//
//  SettingsDeveloperView.swift
//  HopChat-1
//
//  DEBUG-only server overrides (contract §6: `hopchat.dev.serverHost`,
//  `hopchat.dev.allowPlaintext`, `hopchat.dev.serverKey`). The whole file is
//  compiled out of Release builds — unlike the v1 bootstrap-IP editor, which
//  shipped to users.
//

#if DEBUG

import SwiftUI

struct SettingsDeveloperView: View {

    @StateObject private var kad = KademliaService.shared

    @AppStorage("hopchat.dev.serverHost")    private var serverHost = ""
    @AppStorage("hopchat.dev.allowPlaintext") private var allowPlaintext = false
    @AppStorage("hopchat.dev.serverKey")     private var serverKey = ""

    @State private var isReconnecting = false

    var body: some View {
        Form {
            Section {
                TextField("Host or IP", text: $serverHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityLabel(Text("Server host override"))

                Toggle(isOn: $allowPlaintext) {
                    Text("Allow plaintext transport")
                }
                .accessibilityHint(Text("Debug only. Talks to a local server without TLS."))

                LabeledContent {
                    Text(verbatim: "\(AppConfig.serverHost):\(AppConfig.serverPort)")
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    Text("Effective endpoint")
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text("Server")
            } footer: {
                Text("Leave the host empty to use the built-in default.")
            }

            Section {
                TextField("Base64 Ed25519 key", text: $serverKey, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .lineLimit(1...4)
                    .accessibilityLabel(Text("Pinned server signing key override"))

                LabeledContent {
                    Text(AppConfig.isServerKeyConfigured ? "Configured" : "Missing")
                        .foregroundStyle(AppConfig.isServerKeyConfigured ? Color.secondary : Color.red)
                } label: {
                    Text("Pinned key")
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text("Server signing key")
            } footer: {
                Text("`bootstrap.py` prints this key at startup. Without it the app refuses to connect.")
            }

            Section {
                LabeledContent {
                    Text(connectionText)
                } label: {
                    Text("Connection")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Connection: \(connectionText)"))

                LabeledContent {
                    Text(kad.isRegistered ? "Registered" : "Not registered")
                } label: {
                    Text("Identity")
                }
                .accessibilityElement(children: .combine)

                Button {
                    isReconnecting = true
                    Task {
                        await kad.reconnect()
                        isReconnecting = false
                    }
                } label: {
                    Text(isReconnecting ? "Reconnecting…" : "Reconnect")
                        .frame(minHeight: 44)
                }
                .disabled(isReconnecting)
                .accessibilityHint(Text("Drops the connection and starts a new one with the settings above"))
            } header: {
                Text("Status")
            }
        }
        .navigationTitle(Text("Developer"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var connectionText: String {
        switch kad.connectionState {
        case .offline:           return "Offline"
        case .connecting:        return "Connecting…"
        case .online:            return "Online"
        case .error(let message): return "Error: \(message)"
        }
    }
}

#Preview {
    NavigationStack { SettingsDeveloperView() }
}

#endif
