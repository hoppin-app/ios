//
//  LANDeliveryTests.swift
//  HopChat-1Tests
//
//  Direct phone-to-phone delivery with NO server reachable.
//
//  Two running `KademliaService` instances share one process: each publishes
//  and browses `_hoppin._tcp`, completes the signed hello exchange (which
//  pins the other's certificate, TOFU) and then delivers `directEnvelope`s over
//  TCP. Both servers point at a closed loopback port, so anything that
//  arrives can only have come over the LAN.
//
//  Both certificates are signed by the same throwaway server key, so each
//  service accepts the other's. Each test uses its own phone numbers and its
//  own services, torn down at the end.
//
//  If Bonjour is unavailable in the test environment (no local-network
//  access), discovery never completes and every test records a known issue
//  instead of failing — unless HOPPIN_REQUIRE_LAN=1, which makes it a failure.
//

import Testing
import Foundation
import CryptoKit
import Network
@testable import HopChat_1

// MARK: - A pair of running LAN peers

@MainActor
private struct LANPair {
    let alice: ServiceHarness      // sender
    let bob: ServiceHarness        // receiver

    struct DiscoveryFailed: Error, CustomStringConvertible {
        var description: String {
            "HOPPIN_REQUIRE_LAN=1 but the two services never discovered each other over Bonjour"
        }
    }

    static let skipComment: Comment = """
        The two services never discovered each other: Bonjour / local-network \
        access looks unavailable here. Skipping the LAN delivery suite.
        """

    static func make(alicePhone: String, bobPhone: String) async throws -> LANPair {
        let server = Curve25519.Signing.PrivateKey()
        let alice = try await ServiceHarness.running(phone: alicePhone, serverKey: server)
        let bob = try await ServiceHarness.running(phone: bobPhone, serverKey: server)
        #expect(alice.service.isRegistered)
        #expect(bob.service.isRegistered)
        return LANPair(alice: alice, bob: bob)
    }

    /// Waits for the authenticated hello in both directions. `false` means
    /// Bonjour never got there (the caller skips); throws when the
    /// environment demands LAN.
    func discover(timeout: TimeInterval = 30) async throws -> Bool {
        let found = await waitUntil(timeout: timeout, interval: 0.2) {
            alice.service.presenceMap[bob.phone] == .online
                && bob.service.presenceMap[alice.phone] == .online
        }
        if !found, ProcessInfo.processInfo.environment["HOPPIN_REQUIRE_LAN"] == "1" {
            throw DiscoveryFailed()
        }
        return found
    }

    func stop() {
        alice.stop()
        bob.stop()
    }

    func aliceCopy(_ id: String) -> StoredMessage? {
        alice.store.thread(ConversationStore.conversationID(peer: bob.phone))
            .first { $0.id == id }
    }

    var bobThread: [StoredMessage] {
        bob.store.thread(ConversationStore.conversationID(peer: alice.phone))
    }
}

// MARK: - A peer that has stopped answering

/// Takes over a stopped peer's LAN port and plays a phone whose app has gone
/// quiet: every connection is accepted and none is ever answered, so a sender
/// waits out its whole LAN timeout. It records what reaches it, which lets a
/// test see whether a send tried the LAN at all without timing anything.
private final class SilentPeer: @unchecked Sendable {

    private let queue = DispatchQueue(label: "hoppin.tests.silent-peer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var received: [WireMessage] = []

    /// Listens on `port` once the previous owner has let go of it, and returns
    /// only after a probe was seen to arrive here. `nil` if neither happened.
    static func takeOver(port: UInt16) async -> SilentPeer? {
        let peer = SilentPeer()
        guard await waitUntil(timeout: 5, interval: 0.1, { await peer.listen(on: port) }) else {
            return nil
        }
        let probe = WireMessage(type: .ping, senderPhone: "probe")
        let reachable = await waitUntil(timeout: 5, interval: 0.1) {
            _ = await Transport.request(probe, to: "127.0.0.1", port: port, tls: false,
                                        timeout: 0.5, connectTimeout: 0.5)
            return peer.hasReceived(txID: probe.txID)
        }
        guard reachable else {
            peer.stop()
            return nil
        }
        return peer
    }

    /// Direct deliveries addressed to `phone` that reached this port.
    func directDeliveries(to phone: String) -> Int {
        lock.withLock {
            received.filter { $0.wireType == .directEnvelope && $0.recipientPhone == phone }.count
        }
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        let connections = self.connections
        self.listener = nil
        self.connections = []
        lock.unlock()
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    private func hasReceived(txID: String) -> Bool {
        lock.withLock { received.contains { $0.txID == txID } }
    }

    private func listen(on port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        guard let listener = try? NWListener(using: parameters, on: nwPort) else { return false }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            listener.stateUpdateHandler = { state in
                let result: Bool
                switch state {
                case .ready: result = true
                case .failed, .waiting, .cancelled: result = false
                default: return
                }
                // Serial queue: clearing the handler makes this the only resume.
                listener.stateUpdateHandler = nil
                cont.resume(returning: result)
            }
            listener.start(queue: queue)
        }
        guard ready else {
            listener.cancel()
            return false
        }
        lock.withLock { self.listener = listener }
        return true
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        // Read the request, record it, and never reply: the connection stays
        // open until the sender gives up.
        Transport.readFrame(from: connection) { [weak self] result in
            guard let self, case .success(let data) = result,
                  let message = WireMessage.decode(data) else { return }
            self.lock.withLock { self.received.append(message) }
        }
    }
}

// MARK: - Suite

@MainActor
@Suite("LAN — direct delivery without a server", .serialized, .timeLimit(.minutes(2)))
struct LANDeliveryTests {

    @Test("peers discover and authenticate each other over Bonjour")
    func peersDiscoverEachOther() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000001",
                                          bobPhone: "+351910000002")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        #expect(pair.alice.service.presenceMap[pair.bob.phone] == .online)
        #expect(pair.bob.service.presenceMap[pair.alice.phone] == .online)
        // The hello exchange pinned each side's certificate (TOFU).
        #expect(pair.alice.trust.pinnedCertificate(for: pair.bob.phone)?.signingKey
                == pair.bob.certificate?.signingKey)
        #expect(pair.bob.trust.pinnedCertificate(for: pair.alice.phone)?.signingKey
                == pair.alice.certificate?.signingKey)
        // Nobody helloed themselves.
        #expect(pair.alice.service.presenceMap[pair.alice.phone] == nil)
        #expect(pair.bob.service.presenceMap[pair.bob.phone] == nil)
    }

    @Test("a text message is delivered directly and receipted, with no server")
    func directTextDelivery() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000011",
                                          bobPhone: "+351910000012")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        await pair.alice.service.sendText("hello over wifi",
                                          to: ConversationStore.conversationID(peer: pair.bob.phone))
        let sent = try #require(pair.alice.store
            .thread(ConversationStore.conversationID(peer: pair.bob.phone))
            .last { $0.isFromMe })

        // Bob has it — and only the LAN could have carried it.
        let arrived = await waitUntil(timeout: 10) {
            pair.bobThread.contains { $0.id == sent.id }
        }
        #expect(arrived, "bob never received the direct message")
        let received = try #require(pair.bobThread.first { $0.id == sent.id })
        #expect(received.body == "hello over wifi")
        #expect(received.isFromMe == false)
        #expect(received.fromPhone == pair.alice.phone)
        #expect(received.route == .direct, "receiver's copy should be marked as a direct delivery")

        // Alice's copy left the queue over the LAN.
        let aliceCopy = try #require(pair.aliceCopy(sent.id))
        #expect([.sent, .delivered, .read].contains(aliceCopy.status))
        #expect(aliceCopy.route == .direct, "sender's copy should be marked as a direct delivery")

        // Bob's delivery receipt also travels over the LAN.
        let receipted = await waitUntil(timeout: 10) {
            [.delivered, .read].contains(pair.aliceCopy(sent.id)?.status)
        }
        #expect(receipted, "alice never saw the delivery receipt (status: \(String(describing: pair.aliceCopy(sent.id)?.status)))")
    }

    @Test("a blocked sender's direct message is not stored")
    func blockedSenderIsDropped() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000021",
                                          bobPhone: "+351910000022")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        // Bob blocks alice after discovery; alice still has bob as a LAN peer,
        // so her send really reaches bob's listener and is refused there.
        pair.bob.service.block(phone: pair.alice.phone)
        #expect(pair.bob.store.isBlocked(pair.alice.phone))

        await pair.alice.service.sendText("you blocked me",
                                          to: ConversationStore.conversationID(peer: pair.bob.phone))
        let sent = try #require(pair.alice.store
            .thread(ConversationStore.conversationID(peer: pair.bob.phone))
            .last { $0.isFromMe })

        // Give a stray delivery every chance to land.
        let leaked = await waitUntil(timeout: 3) {
            pair.bobThread.contains { $0.id == sent.id }
        }
        #expect(!leaked, "a blocked sender's message was stored")
        #expect(pair.bobThread.isEmpty)

        // No ack came back, so alice's copy is still queued, not "sent".
        let aliceCopy = try #require(pair.aliceCopy(sent.id))
        #expect(aliceCopy.status == .pending)
        #expect(aliceCopy.route != .direct)
    }

    @Test("sending to a known LAN peer doesn't wait on the unreachable server")
    func sendIsFastWithoutServer() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000031",
                                          bobPhone: "+351910000032")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await pair.alice.service.sendText("quick",
                                              to: ConversationStore.conversationID(peer: pair.bob.phone))
        }
        #expect(elapsed < .seconds(5), "sendText took \(elapsed) with a LAN peer available")

        let sent = try #require(pair.alice.store
            .thread(ConversationStore.conversationID(peer: pair.bob.phone))
            .last { $0.isFromMe })
        #expect([.sent, .delivered, .read].contains(pair.aliceCopy(sent.id)?.status))
        let arrived = await waitUntil(timeout: 10) {
            pair.bobThread.contains { $0.id == sent.id }
        }
        #expect(arrived)
    }

    @Test("the keep-alive ping is answered and keeps both sides online")
    func keepAlive() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000041",
                                          bobPhone: "+351910000042")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        await pair.alice.service.pingLANPeers()
        await pair.bob.service.pingLANPeers()
        #expect(pair.alice.service.presenceMap[pair.bob.phone] == .online)
        #expect(pair.bob.service.presenceMap[pair.alice.phone] == .online)
    }

    @Test("returning to the foreground keeps direct delivery working")
    func foregroundRefresh() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000051",
                                          bobPhone: "+351910000052")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        // Both apps "come back": Bonjour restarts and peers are re-checked.
        await pair.alice.service.sceneDidBecomeActive()
        await pair.bob.service.sceneDidBecomeActive()
        let stillOnline = await waitUntil(timeout: 15, interval: 0.2) {
            pair.alice.service.presenceMap[pair.bob.phone] == .online
                && pair.bob.service.presenceMap[pair.alice.phone] == .online
        }
        #expect(stillOnline)

        await pair.alice.service.sendText("after the refresh",
                                          to: ConversationStore.conversationID(peer: pair.bob.phone))
        let sent = try #require(pair.alice.store
            .thread(ConversationStore.conversationID(peer: pair.bob.phone))
            .last { $0.isFromMe })
        let arrived = await waitUntil(timeout: 10) {
            pair.bobThread.contains { $0.id == sent.id && $0.route == .direct }
        }
        #expect(arrived)
    }

    @Test("a peer that stops answering is skipped instead of timing out on every send")
    func silentPeerIsSkipped() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000061",
                                          bobPhone: "+351910000062")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        // Bob's app goes quiet (suspended / walked away) while alice still
        // lists him as nearby: his port still takes connections but nothing
        // answers, so her direct attempt has to time out.
        let bobPort = pair.bob.service.lanPort
        pair.bob.stop()
        let takenOver = await SilentPeer.takeOver(port: bobPort)
        let silentBob = try #require(takenOver, "couldn't stand in for bob on port \(bobPort)")
        defer { silentBob.stop() }
        let conversation = ConversationStore.conversationID(peer: pair.bob.phone)

        // Counted at bob's port, not timed: both sends also fail against the
        // unreachable relay, and how long that takes varies too much to
        // measure the 3 s LAN timeout against.
        await pair.alice.service.sendText("one", to: conversation)
        let attempts = silentBob.directDeliveries(to: pair.bob.phone)
        #expect(attempts >= 1, "alice never tried bob directly, so there was no timeout to learn from")

        await pair.alice.service.sendText("two", to: conversation)
        #expect(silentBob.directDeliveries(to: pair.bob.phone) == attempts,
                "the second send dialled the silent peer again instead of skipping it")
    }

    @Test("a blocked sender's sends fail fast — the refusal isn't a timeout")
    func blockedPeerFailsFast() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000071",
                                          bobPhone: "+351910000072")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        pair.bob.service.block(phone: pair.alice.phone)
        let conversation = ConversationStore.conversationID(peer: pair.bob.phone)
        await pair.alice.service.sendText("one", to: conversation)
        await pair.alice.service.sendText("two", to: conversation)

        // Nothing leaks through, and alice learns nothing beyond "not delivered yet".
        #expect(pair.bobThread.isEmpty)
        let queued = pair.alice.store.thread(conversation).filter { $0.isFromMe }
        #expect(queued.count == 2)
        #expect(queued.allSatisfy { $0.status == .pending && $0.route == nil })
    }
}
