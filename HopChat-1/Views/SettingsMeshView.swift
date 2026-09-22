//
//  SettingsMeshView.swift
//  HopChat-1
//
//  The user-facing switch for Bluetooth mesh delivery (contract §9).
//
//  The radio is not something the user drives directly: it comes up on its own
//  when the phone has no internet and goes away again when it does. What this
//  screen offers is consent — whether the phone may use Bluetooth at all, and
//  whether it may carry other people's sealed mail — plus an honest picture of
//  what is happening right now.
//

import SwiftUI
import CoreBluetooth

struct SettingsMeshView: View {

    @StateObject private var mesh = MeshNode.shared
    @StateObject private var kad = KademliaService.shared
    @AppStorage(AppConfig.Keys.meshEnabled) private var meshEnabled = true

    var body: some View {
        Form {
            Group {
                Section {
                    Toggle(isOn: Binding(get: { meshEnabled },
                                         set: { kad.setMeshEnabled($0) })) {
                        Label("Send over Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                    }
                } footer: {
                    Text("""
                         With no Wi-Fi and no mobile data, HopChat can pass a \
                         message to nearby phones over Bluetooth until it \
                         reaches the person you sent it to. It is switched on \
                         only while you are offline.
                         """)
                }

                if meshEnabled {
                    Section {
                        LabeledContent {
                            Text(statusText).foregroundStyle(.secondary)
                        } label: {
                            Text("Status")
                        }
                        if mesh.isRunning {
                            LabeledContent {
                                Text("\(mesh.linkCount)").monospacedDigit()
                            } label: {
                                Text("Phones nearby")
                            }
                        }
                        if mesh.bluetoothState == .unauthorized || mesh.bluetoothState == .poweredOff {
                            Button {
                                openSystemSettings()
                            } label: {
                                Text("Open Settings")
                            }
                        }
                    } header: {
                        Text("Right now")
                    }

                    Section {
                        Text("""
                             Messages stay sealed the whole way. A phone that \
                             carries one cannot read it, cannot tell who sent \
                             it and cannot tell who it is for — it only knows \
                             it is passing something along, which is what \
                             makes the hop work at all.
                             """)
                        Text("""
                             Photos still need Wi-Fi or mobile data; they are \
                             too large to hop. Messages can take a while to \
                             arrive and may not arrive at all if nobody comes \
                             close enough. As soon as you are back online, \
                             anything unconfirmed is sent the normal way.
                             """)
                    } header: {
                        Text("What to expect")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .glassListRows()
        }
        .lavaBackground()
        .navigationTitle(Text("Bluetooth mesh"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusText: String {
        guard meshEnabled else { return String(localized: "Off") }
        switch mesh.bluetoothState {
        case .poweredOff:   return String(localized: "Bluetooth is off")
        case .unauthorized: return String(localized: "Bluetooth not allowed")
        case .unsupported:  return String(localized: "Not supported on this device")
        default: break
        }
        if mesh.isRunning {
            return mesh.linkCount > 0
                ? String(localized: "Connected")
                : String(localized: "Looking for phones nearby")
        }
        return String(localized: "Idle — you have internet")
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    NavigationStack { SettingsMeshView() }
}
