//
//  SettingsMeshDevView.swift
//  HopChat-1
//
//  DEBUG-only bring-up screen for the BLE mesh (phase 2). The transport can't
//  be unit-tested — the simulator has no Bluetooth — so this is how two phones
//  are checked against each other: start the radio on both, watch the links
//  come up, then blast test packets one way and see what the other counts.
//
//  Test packets are ordinary `.envelope` packets whose body is sealed to a
//  throw-away key, so no device can open them: they exercise exactly the paths
//  real mail uses (chunking, forwarding, de-duplication) while carrying a
//  sequence number and a checksum the receiver can verify.
//

#if DEBUG

import SwiftUI
import CryptoKit
import CoreBluetooth

struct SettingsMeshDevView: View {

    @StateObject private var mesh = MeshNode.shared
    @State private var tester = MeshLoopbackTester()
    @State private var sending = false
    @State private var packetCount = 100

    var body: some View {
        Form {
            Group {
                Section {
                    Toggle(isOn: Binding(get: { mesh.isRunning },
                                         set: { $0 ? start() : mesh.stop() })) {
                        Text(verbatim: "Mesh radio")
                    }
                    LabeledContent {
                        Text(verbatim: bluetoothStateText)
                    } label: {
                        Text(verbatim: "Bluetooth")
                    }
                    LabeledContent {
                        Text(verbatim: "\(mesh.linkCount)")
                            .monospacedDigit()
                    } label: {
                        Text(verbatim: "Connected phones")
                    }
                } header: {
                    Text(verbatim: "Radio")
                } footer: {
                    Text(verbatim: "Start this on both phones. A link needs a few seconds to appear.")
                }

                Section {
                    stat("Seen", mesh.packetsSeen)
                    stat("Forwarded", mesh.stats.forwarded)
                    stat("Duplicates", mesh.stats.duplicates)
                    stat("Dropped", mesh.stats.dropped)
                    stat("Rate limited", mesh.stats.rateLimited)
                    stat("Delivered to us", mesh.stats.delivered)
                } header: {
                    Text(verbatim: "Router")
                }

                Section {
                    Stepper(value: $packetCount, in: 10...2000, step: 10) {
                        Text(verbatim: "Send \(packetCount) test packets")
                    }
                    Button {
                        Task { await sendTest() }
                    } label: {
                        Text(verbatim: sending ? "Sending…" : "Send now")
                    }
                    .disabled(sending || !mesh.isRunning || mesh.linkCount == 0)

                    stat("Test packets received", tester.received)
                    stat("Out of order", tester.outOfOrder)
                    stat("Corrupt", tester.corrupt)
                    Button {
                        tester.reset()
                    } label: {
                        Text(verbatim: "Reset counters")
                    }
                } header: {
                    Text(verbatim: "Loopback test")
                } footer: {
                    Text(verbatim: "Send from one phone and read the counters on the other. "
                         + "Corrupt must stay 0; received should reach the number sent.")
                }
            }
            .glassListRows()
        }
        .lavaBackground()
        .navigationTitle(Text(verbatim: "Mesh (dev)"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tester.attach(to: mesh) }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        LabeledContent {
            Text(verbatim: "\(value)").monospacedDigit()
        } label: {
            Text(verbatim: title)
        }
    }

    private func start() {
        tester.attach(to: mesh)
        mesh.start()
    }

    private func sendTest() async {
        sending = true
        defer { sending = false }
        for index in 0..<packetCount {
            mesh.send(tester.makePacket(sequence: index))
            // A brief pause keeps the BLE queue from overflowing and makes
            // "sent" vs "received" counts comparable.
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private var bluetoothStateText: String {
        switch mesh.bluetoothState {
        case .poweredOn:   return "on"
        case .poweredOff:  return "off"
        case .unauthorized: return "not allowed"
        case .unsupported: return "unsupported"
        case .resetting:   return "resetting"
        default:           return "unknown"
        }
    }
}

// MARK: - Loopback test

/// Sends numbered, checksummed packets and counts what comes back on the other
/// phone. Nothing here touches real mail.
@MainActor
@Observable
final class MeshLoopbackTester {

    private(set) var received = 0
    private(set) var outOfOrder = 0
    private(set) var corrupt = 0

    private var lastSequence = -1
    private var attached = false
    /// Sealed to a key nobody holds: unopenable, like a stranger's packet.
    private let strangerKey = Curve25519.KeyAgreement.PrivateKey()
        .publicKey.rawRepresentation.base64EncodedString()
    private static let marker = Data("HOPTEST1".utf8)

    func attach(to mesh: MeshNode) {
        guard !attached else { return }
        attached = true
        mesh.onPacketSeen = { [weak self] packet in
            self?.check(packet)
        }
    }

    func reset() {
        received = 0
        outOfOrder = 0
        corrupt = 0
        lastSequence = -1
    }

    /// `marker | sequence (4 B) | random payload | SHA-256 prefix (8 B)`,
    /// padded and put in a packet body as a real message would be.
    func makePacket(sequence: Int) -> MeshPacket {
        var payload = Self.marker
        payload.append(withUnsafeBytes(of: UInt32(sequence).bigEndian) { Data($0) })
        payload.append(Data((0..<64).map { _ in UInt8.random(in: 0...255) }))
        payload.append(Data(SHA256.hash(data: payload).prefix(8)))

        let body = MeshPadding.pad(payload) ?? payload
        return MeshPacket(packetID: MeshPacket.randomID(),
                          kind: .envelope,
                          ttl: MeshPacket.defaultTTL,
                          hint: 0,
                          expiresAt: UInt32(Date().addingTimeInterval(600).timeIntervalSince1970),
                          body: body)
    }

    private func check(_ packet: MeshPacket) {
        guard let payload = MeshPadding.unpad(packet.body),
              payload.count > Self.marker.count + 12,
              payload.prefix(Self.marker.count) == Self.marker else { return }

        received += 1
        let digest = Data(SHA256.hash(data: payload.dropLast(8)).prefix(8))
        guard digest == payload.suffix(8) else {
            corrupt += 1
            return
        }
        let start = payload.index(payload.startIndex, offsetBy: Self.marker.count)
        let sequence = Int(payload[start..<payload.index(start, offsetBy: 4)]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        if sequence <= lastSequence { outOfOrder += 1 }
        lastSequence = max(lastSequence, sequence)
    }
}

#endif
