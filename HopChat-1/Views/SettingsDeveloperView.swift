//
//  SettingsDeveloperView.swift
//  HopChat-1
//
//  DEBUG-only server overrides (contract §6: `hoppin.dev.serverHost`,
//  `hoppin.dev.allowPlaintext`, `hoppin.dev.serverKey`). The whole file is
//  compiled out of Release builds — unlike the v1 bootstrap-IP editor, which
//  shipped to users.
//

#if DEBUG

import SwiftUI

struct SettingsDeveloperView: View {

    @StateObject private var kad = KademliaService.shared

    @AppStorage("hoppin.dev.serverHost")    private var serverHost = ""
    @AppStorage("hoppin.dev.serverPort")    private var serverPort = ""
    @AppStorage("hoppin.dev.allowPlaintext") private var allowPlaintext = false
    @AppStorage("hoppin.dev.serverKey")     private var serverKey = ""

    @State private var isReconnecting = false
    /// Pending reconnect after an edit; each keystroke pushes it back.
    @State private var applyTask: Task<Void, Never>?

    var body: some View {
        Form {
            Group {
                Section {
                    NavigationLink {
                        SettingsMeshDevView()
                    } label: {
                        Label("Mesh (dev)", systemImage: "dot.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Bluetooth mesh")
                } footer: {
                    Text("Phase 2 bring-up: start the radio on two phones and check the counters.")
                }

                Section {
                    TextField("Host or IP", text: $serverHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel(Text("Server host override"))

                    TextField("Port (blank = 4443 / 4001)", text: $serverPort)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numberPad)
                        .accessibilityLabel(Text("Server port override"))
                        .accessibilityHint(Text("For a tunnel or a server on a non-standard port."))

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
                    Text("Leave the host empty to use the built-in default. Changes apply a second after you stop typing.")
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
                    Button {
                        AppConfig.clearDevOverrides()
                        serverHost = ""
                        serverPort = ""
                        allowPlaintext = false
                        serverKey = ""
                        applyNow()
                    } label: {
                        Text("Use built-in server")
                            .frame(minHeight: 44)
                    }
                    .disabled(isReconnecting)
                    .accessibilityHint(Text("Clears every override above and reconnects to the relay the app ships with"))
                } footer: {
                    Text("Also clears values left behind by an old Xcode scheme.")
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
            .glassListRows()
        }
        .onChange(of: serverHost) { _, _ in applySoon() }
        .onChange(of: serverPort) { _, _ in applySoon() }
        .onChange(of: allowPlaintext) { _, _ in applySoon() }
        .onChange(of: serverKey) { _, _ in applySoon() }
        .onDisappear {
            // Leaving mid-debounce must not drop the edit.
            if applyTask != nil { applyNow() }
        }
        .lavaBackground()
        .navigationTitle(Text("Developer"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The service reads host, port and key once, when it builds its server
    /// client. Editing these fields used to change nothing until the app was
    /// force-quit, which cost an afternoon of "it's offline" on a phone that
    /// could reach the relay fine. Now an edit reconnects by itself.
    private func applySoon() {
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            applyNow()
        }
    }

    private func applyNow() {
        applyTask?.cancel()
        applyTask = nil
        isReconnecting = true
        Task {
            await kad.reconnect()
            isReconnecting = false
        }
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
