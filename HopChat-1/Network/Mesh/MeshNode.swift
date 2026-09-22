//
//  MeshNode.swift
//  HopChat-1
//
//  Ties the Bluetooth radio (`BLETransport`) to the routing layer
//  (`MeshRouter`): links become router links, inbound frames become packets,
//  and the router's outbound packets go back out over the radio.
//
//  This is the only object the rest of the app needs to know about. In phase 3
//  `KademliaService` sets `hints` and `onEnvelope` and starts sending real
//  mail; until then the developer screen drives it with test packets.
//

import Foundation
import CoreBluetooth
import Combine
import os

/// What `KademliaService` needs from the mesh. It exists so the send and
/// receive paths can be tested without CoreBluetooth, which no simulator has.
@MainActor
protocol MeshDelivering: AnyObject {
    var isRunning: Bool { get }
    var linkCount: Int { get }
    /// Hints this device answers to; the node asks for them on every packet.
    var hints: () -> Set<UInt8> { get set }
    /// A packet whose hint matched. Return true when it really was ours.
    var onEnvelope: ((MeshPacket) -> Bool)? { get set }

    func start()
    func stop()
    func send(_ packet: MeshPacket)
    func packet(for envelope: Envelope,
                recipientAgreementKey agreementKey: String,
                crypto: CryptoManager,
                ttl: UInt8,
                lifetime: TimeInterval,
                now: Date) -> MeshPacket?
    func envelope(from packet: MeshPacket, crypto: CryptoManager) -> Envelope?
}

@MainActor
final class MeshNode: ObservableObject, MeshDelivering {

    static let shared = MeshNode()

    private let transport = BLETransport()
    let router: MeshRouter

    /// Hints this device answers to (`CryptoManager.meshHints`). Set by the
    /// service layer; empty means "nothing here is ours", which still forwards.
    var hints: () -> Set<UInt8> = { [] }
    /// A packet whose hint matched. Return true when it really was ours.
    /// It is forwarded either way — that is what hides the recipient.
    var onEnvelope: ((MeshPacket) -> Bool)?

    @Published private(set) var isRunning = false
    @Published private(set) var linkCount = 0
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var stats = MeshRouter.Stats()
    /// Every envelope packet seen, ours or not — the developer screen's counter.
    @Published private(set) var packetsSeen = 0
    var onPacketSeen: ((MeshPacket) -> Void)?

    private var sweepTask: Task<Void, Never>?

    init(router: MeshRouter? = nil) {
        // Built here rather than in a default argument: `MeshRouter` is
        // main-actor isolated and a default argument is evaluated nonisolated.
        let router = router ?? MeshRouter()
        self.router = router
        self.router.myHints = { [weak self] in self?.hints() ?? [] }
        self.router.onPacketForUs = { [weak self] packet in
            self?.onEnvelope?(packet) ?? false
        }
        self.router.onPacketSeen = { [weak self] packet in
            guard let self else { return }
            packetsSeen += 1
            onPacketSeen?(packet)
        }

        transport.onLinkUp = { [weak self] link in
            guard let self else { return }
            router.attach(link)
            linkCount = router.linkCount
            Log.net.info("Mesh link up (\(self.router.linkCount, privacy: .public) total)")
        }
        transport.onLinkDown = { [weak self] id in
            guard let self else { return }
            router.detach(id)
            linkCount = router.linkCount
        }
        transport.onPacket = { [weak self] data, linkID in
            guard let self else { return }
            router.receive(data, from: linkID)
            stats = router.stats
        }
        transport.onUnavailable = { [weak self] state in
            self?.bluetoothState = state
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        transport.start()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.isRunning else { return }
                router.sweep()
                stats = router.stats
            }
        }
    }

    func stop() {
        isRunning = false
        sweepTask?.cancel(); sweepTask = nil
        transport.stop()
        linkCount = 0
    }

    // MARK: - Sending

    /// Puts one of our own packets into the mesh.
    func send(_ packet: MeshPacket) {
        router.originate(packet)
        stats = router.stats
    }

    /// Builds the packet for a sealed envelope addressed to `agreementKey`.
    /// Returns nil when the envelope is too big for the mesh.
    func packet(for envelope: Envelope,
                recipientAgreementKey agreementKey: String,
                crypto: CryptoManager,
                ttl: UInt8 = MeshPacket.defaultTTL,
                lifetime: TimeInterval = MeshPacket.maxLifetime,
                now: Date = Date()) -> MeshPacket? {
        guard let compact = CompactEnvelope.encode(envelope),
              let padded = MeshPadding.pad(compact) else { return nil }
        let header = MeshPacket(packetID: MeshPacket.randomID(),
                                kind: .envelope,
                                ttl: ttl,
                                hint: MeshHint.value(agreementKeyBase64: agreementKey, at: now),
                                expiresAt: UInt32(now.addingTimeInterval(lifetime).timeIntervalSince1970),
                                body: Data())
        guard let body = try? crypto.sealForMesh(padded,
                                                 recipientAgreementKeyBase64: agreementKey,
                                                 authenticating: header.authenticatedHeader) else {
            return nil
        }
        return MeshPacket(packetID: header.packetID, kind: .envelope, ttl: ttl,
                          hint: header.hint, expiresAt: header.expiresAt, body: body)
    }

    /// Opens a packet that turned out to be ours.
    func envelope(from packet: MeshPacket, crypto: CryptoManager) -> Envelope? {
        guard let opened = crypto.openMesh(packet.body, authenticating: packet.authenticatedHeader),
              let compact = MeshPadding.unpad(opened) else { return nil }
        return CompactEnvelope.decode(compact)
    }
}
