//
//  HopChat_1Tests.swift
//  HopChat-1Tests
//
//  Created by Rodrigo Loução on 25/02/2026.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

// MARK: - NodeID Tests
// Passes

@Suite("NodeID")
struct NodeIDTests {

    @Test("from(phone:) is deterministic")
    func deterministicFromPhone() {
        let a = NodeID.from(phone: "+351912345678")
        let b = NodeID.from(phone: "+351912345678")
        #expect(a == b)
    }

    @Test("different phones produce different IDs")
    func differentPhonesDifferentIDs() {
        let a = NodeID.from(phone: "+351912345678")
        let b = NodeID.from(phone: "+351987654321")
        #expect(a != b)
    }

    @Test("distance to self is zero")
    func distanceToSelfIsZero() {
        let id = NodeID.from(phone: "+351912345678")
        let dist = id.distance(to: id)
        #expect(dist.allSatisfy { $0 == 0 })
    }

    @Test("distance is symmetric")
    func distanceSymmetric() {
        let a = NodeID.from(phone: "alice")
        let b = NodeID.from(phone: "bob")
        #expect(a.distance(to: b) == b.distance(to: a))
    }

    @Test("bucketIndex is in range 0–255")
    func bucketIndexRange() {
        let local = NodeID.random()
        for _ in 0..<50 {
            let other = NodeID.random()
            let idx = local.bucketIndex(relativeTo: other)
            #expect(idx >= 0 && idx <= 255)
        }
    }

    @Test("random produces 32 bytes")
    func randomIs32Bytes() {
        let id = NodeID.random()
        #expect(id.bytes.count == 32)
    }

    @Test("two randoms differ")
    func randomIsDifferent() {
        let a = NodeID.random()
        let b = NodeID.random()
        #expect(a != b)
    }
}

// MARK: - KBucket Tests
// Passes

@Suite("KBucket")
struct KBucketTests {

    @Test("add up to k peers fills bucket without eviction")
    func addUpToK() {
        var bucket = KBucket()
        for i in 0..<KBucket.k {
            let evict = bucket.add(makePeer(phone: "p\(i)"))
            #expect(evict == nil)
        }
        #expect(bucket.peers.count == KBucket.k)
    }

    @Test("full bucket returns oldest as eviction candidate")
    func fullBucketReturnsEvictionCandidate() {
        var bucket = KBucket()
        for i in 0..<KBucket.k {
            bucket.add(makePeer(phone: "p\(i)"))
        }
        let candidate = bucket.add(makePeer(phone: "new"))
        #expect(candidate?.phone == "p0")
    }

    @Test("known peer refresh moves it to tail")
    func knownPeerRefresh() {
        var bucket = KBucket()
        let peer = makePeer(phone: "alice")
        bucket.add(peer)
        bucket.add(makePeer(phone: "bob"))
        bucket.add(peer) // refresh alice
        #expect(bucket.peers.last?.phone == "alice")
    }

    @Test("confirmEvict replaces old peer with new")
    func confirmEvict() {
        var bucket = KBucket()
        for i in 0..<KBucket.k {
            bucket.add(makePeer(phone: "p\(i)"))
        }
        let newPeer = makePeer(phone: "newcomer")
        let old = bucket.add(newPeer)!
        bucket.confirmEvict(old.id, thenAdd: newPeer)
        #expect(bucket.peers.contains { $0.phone == "newcomer" })
        #expect(!bucket.peers.contains { $0.phone == old.phone })
    }

    private func makePeer(phone: String) -> KadPeer {
        KadPeer(id: NodeID.from(phone: phone), ip: "127.0.0.1", port: 4001, phone: phone)
    }
}

// MARK: - RoutingTable Tests
// Passes

@Suite("RoutingTable")
struct RoutingTableTests {

    @Test("does not add self")
    func doesNotAddSelf() {
        let local = NodeID.from(phone: "me")
        let rt = RoutingTable(localID: local)
        rt.add(KadPeer(id: local, ip: "127.0.0.1", port: 4001, phone: "me"))
        #expect(rt.allPeers.isEmpty)
    }

    @Test("closest peers sorted by XOR distance")
    func closestPeersSorted() {
        let local = NodeID.from(phone: "local")
        let rt = RoutingTable(localID: local)
        for phone in ["alice", "bob", "carol", "dave", "eve"] {
            rt.add(KadPeer(id: NodeID.from(phone: phone), ip: "127.0.0.1", port: 4001, phone: phone))
        }
        let target  = NodeID.from(phone: "alice")
        let closest = rt.closestPeers(to: target, k: 3)
        #expect(closest.first?.phone == "alice")
        for i in 0..<(closest.count - 1) {
            let d1 = closest[i].id.distance(to: target)
            let d2 = closest[i+1].id.distance(to: target)
            #expect(d1.lexicographicallyPrecedes(d2) || d1 == d2)
        }
    }

    @Test("returns at most k peers")
    func returnsAtMostK() {
        let local = NodeID.from(phone: "local")
        let rt = RoutingTable(localID: local)
        for i in 0..<50 {
            rt.add(KadPeer(id: NodeID.random(), ip: "127.0.0.1", port: 4001, phone: "p\(i)"))
        }
        let closest = rt.closestPeers(to: NodeID.random(), k: 5)
        #expect(closest.count <= 5)
    }
}

// MARK: - CryptoManager Tests (using isolated TestCryptoManager)
// Passes

@Suite("CryptoManager")
struct CryptoManagerTests {

    @Test("encrypt then decrypt round-trips")
    func encryptDecryptRoundTrip() {
        let alice = TestCryptoManager()
        let bob   = TestCryptoManager()

        alice.storePeerKeys(phone: "bob",   agreementBase64: bob.agreementPublicKeyBase64,   signingBase64: bob.signingPublicKeyBase64)
        bob.storePeerKeys(phone: "alice", agreementBase64: alice.agreementPublicKeyBase64, signingBase64: alice.signingPublicKeyBase64)

        let original   = "Hello, World! 🔐"
        let ciphertext = alice.encrypt(message: original, forPhone: "bob")
        #expect(ciphertext != nil)
        #expect(ciphertext != original)

        let decrypted  = bob.decrypt(ciphertext: ciphertext!, fromPhone: "alice")
        #expect(decrypted == original)
    }

    @Test("sign and verify round-trips")
    func signVerify() {
        let alice = TestCryptoManager()
        let bob   = TestCryptoManager()
        bob.storePeerKeys(phone: "alice", agreementBase64: alice.agreementPublicKeyBase64, signingBase64: alice.signingPublicKeyBase64)

        let payload = "tx123|alice|hello"
        let sig     = alice.sign(payload: payload)!
        #expect(bob.verify(payload: payload, signature: sig, fromPhone: "alice"))
    }

    @Test("tampered payload fails verification")
    func tamperedPayloadFails() {
        let alice = TestCryptoManager()
        let bob   = TestCryptoManager()
        bob.storePeerKeys(phone: "alice", agreementBase64: alice.agreementPublicKeyBase64, signingBase64: alice.signingPublicKeyBase64)

        let sig = alice.sign(payload: "tx123|alice|hello")!
        #expect(!bob.verify(payload: "tx123|alice|HACKED", signature: sig, fromPhone: "alice"))
    }

    @Test("encrypt returns nil without peer key")
    func encryptWithoutKey() {
        let crypto = TestCryptoManager()
        #expect(crypto.encrypt(message: "hello", forPhone: "unknown") == nil)
    }
}

// Isolated crypto context for testing — avoids Keychain/shared state
final class TestCryptoManager {
    let agreementKey = Curve25519.KeyAgreement.PrivateKey()
    let signingKey   = Curve25519.Signing.PrivateKey()

    var agreementPublicKeyBase64: String { agreementKey.publicKey.rawRepresentation.base64EncodedString() }
    var signingPublicKeyBase64:   String { signingKey.publicKey.rawRepresentation.base64EncodedString() }

    private var peerAgreementKeys: [String: Curve25519.KeyAgreement.PublicKey] = [:]
    private var peerSigningKeys:   [String: Curve25519.Signing.PublicKey]      = [:]

    func storePeerKeys(phone: String, agreementBase64: String, signingBase64: String) {
        if let d = Data(base64Encoded: agreementBase64), let k = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: d) { peerAgreementKeys[phone] = k }
        if let d = Data(base64Encoded: signingBase64),   let k = try? Curve25519.Signing.PublicKey(rawRepresentation: d)      { peerSigningKeys[phone] = k }
    }

    func encrypt(message: String, forPhone phone: String) -> String? {
        guard let pk = peerAgreementKeys[phone], let sh = try? agreementKey.sharedSecretFromKeyAgreement(with: pk),
              let d = message.data(using: .utf8), let s = try? AES.GCM.seal(d, using: derivedKey(sh))
        else { return nil }
        return s.combined?.base64EncodedString()
    }

    func decrypt(ciphertext: String, fromPhone phone: String) -> String? {
        guard let pk = peerAgreementKeys[phone], let sh = try? agreementKey.sharedSecretFromKeyAgreement(with: pk),
              let d = Data(base64Encoded: ciphertext), let box = try? AES.GCM.SealedBox(combined: d),
              let plain = try? AES.GCM.open(box, using: derivedKey(sh))
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    func sign(payload: String) -> String? {
        guard let d = payload.data(using: .utf8), let s = try? signingKey.signature(for: d) else { return nil }
        return s.base64EncodedString()
    }

    func verify(payload: String, signature: String, fromPhone phone: String) -> Bool {
        guard let pk = peerSigningKeys[phone], let pd = payload.data(using: .utf8), let sd = Data(base64Encoded: signature) else { return false }
        return pk.isValidSignature(sd, for: pd)
    }

    private func derivedKey(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("HopChat-E2E-v1".utf8), sharedInfo: Data(), outputByteCount: 32)
    }
}

// MARK: - Integration Tests

// Allocates unique loopback ports so parallel test runs don't clash.
private final class PortAllocator: @unchecked Sendable {
    static let shared = PortAllocator()
    private var next: UInt16 = 15200
    private let lock = NSLock()
    func allocate() -> UInt16 {
        lock.withLock { let p = next; next += 1; return p }
    }
}

// Thread-safe message collector. Uses polling so it stays async-friendly.
private final class Mailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [(phone: String, body: String, chatID: String)] = []
    private var totalPushed = 0

    // Total ever received (not affected by next() calls).
    var count: Int { lock.withLock { totalPushed } }

    func push(phone: String, body: String, chatID: String) {
        lock.withLock { messages.append((phone, body, chatID)); totalPushed += 1 }
    }

    // Returns the next unconsumed message, polling every 50 ms up to timeout.
    // Works correctly whether the message arrived before or after this is called.
    func next(timeout: Double = 5) async -> (phone: String, body: String, chatID: String)? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let msg = lock.withLock({ messages.isEmpty ? nil : messages.removeFirst() }) {
                return msg
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }
}

// Passes
@Suite("Integration – send / receive flow")
struct IntegrationTests {

    // Spin up a node on a unique loopback port.
    private func makeNode(phone: String) throws -> (KademliaProtocol, UInt16) {
        let port = PortAllocator.shared.allocate()
        let node = KademliaProtocol(phone: phone, ip: "127.0.0.1", port: port)
        try node.start()
        return (node, port)
    }

    // MARK: 1. Core path: direct send → ACK → onChatMessage

    @Test("direct send delivers message and returns ACK chatID")
    func directSendDeliverAndAck() async throws {
        let (alice, _)     = try makeNode(phone: "alice-\(UUID())")
        let (bob, bobPort) = try makeNode(phone: "bob-\(UUID())")
        defer { alice.transport.stop(); bob.transport.stop() }

        alice.addPeer(KadPeer(id: bob.localPeer.id, ip: "127.0.0.1",
                              port: bobPort, phone: bob.localPeer.phone))

        let box = Mailbox()
        bob.onChatMessage = { phone, body, chatID, _ in
            box.push(phone: phone, body: body, chatID: chatID)
        }

        let chatID = await alice.sendChat(toPhone: bob.localPeer.phone, body: "Hello Bob!")
        #expect(chatID != nil, "sendChat must return a chatID when the peer ACKs")

        let msg = await box.next()
        #expect(msg != nil,                          "bob should deliver the message within timeout")
        #expect(msg?.phone == alice.localPeer.phone, "sender phone must match")
        #expect(msg?.body  == "Hello Bob!",          "message body must arrive intact")
    }

    // MARK: 2. Ping / pong round-trip

    @Test("ping returns pong")
    func pingReturnsPong() async throws {
        let (alice, _)     = try makeNode(phone: "ping-alice-\(UUID())")
        let (bob, bobPort) = try makeNode(phone: "ping-bob-\(UUID())")
        defer { alice.transport.stop(); bob.transport.stop() }

        let bobPeer = KadPeer(id: bob.localPeer.id, ip: "127.0.0.1",
                              port: bobPort, phone: bob.localPeer.phone)
        let alive = await alice.ping(bobPeer)
        #expect(alive == true)
    }

    // MARK: 3. sendChat returns nil when peer is unreachable

    @Test("sendChat returns nil for unknown peer")
    func sendToUnknownPeer() async throws {
        let (alice, _) = try makeNode(phone: "lonely-\(UUID())")
        defer { alice.transport.stop() }

        let chatID = await alice.sendChat(toPhone: "ghost-\(UUID())", body: "Anyone there?")
        #expect(chatID == nil)
    }

    // MARK: 4. Duplicate chatID suppressed on receiver

    @Test("duplicate chatID is not delivered twice")
    func duplicateSuppressed() async throws {
        let (alice, _)     = try makeNode(phone: "dup-alice-\(UUID())")
        let (bob, bobPort) = try makeNode(phone: "dup-bob-\(UUID())")
        defer { alice.transport.stop(); bob.transport.stop() }

        let bobPeer = KadPeer(id: bob.localPeer.id, ip: "127.0.0.1",
                              port: bobPort, phone: bob.localPeer.phone)
        alice.addPeer(bobPeer)

        let box = Mailbox()
        bob.onChatMessage = { phone, body, chatID, _ in
            box.push(phone: phone, body: body, chatID: chatID)
        }

        let fixedChatID = UUID().uuidString
        let first = KademliaTransport.makeChatMessage(from: alice.localPeer, body: "Once",
                                                       chatID: fixedChatID,
                                                       toPhone: bob.localPeer.phone)
        _ = await alice.transport.sendAndWait(first, to: bobPeer)
        _ = await box.next() // wait for legitimate delivery

        // Replay the identical chatID — Bob's seenChatIDs must block it.
        let replay = KademliaTransport.makeChatMessage(from: alice.localPeer, body: "Once",
                                                        chatID: fixedChatID,
                                                        toPhone: bob.localPeer.phone)
        _ = await alice.transport.sendAndWait(replay, to: bobPeer)
        try await Task.sleep(nanoseconds: 300_000_000) // give main queue time to fire

        #expect(box.count == 1, "Duplicate chatID must not be delivered twice")
    }

    // MARK: 5. CONNECT_REQUEST → CONNECT_ACCEPT handshake

    @Test("connect request is accepted by a reachable peer")
    func connectRequestAccepted() async throws {
        let (alice, _)     = try makeNode(phone: "cr-alice-\(UUID())")
        let (bob, bobPort) = try makeNode(phone: "cr-bob-\(UUID())")
        defer { alice.transport.stop(); bob.transport.stop() }

        alice.addPeer(KadPeer(id: bob.localPeer.id, ip: "127.0.0.1",
                              port: bobPort, phone: bob.localPeer.phone))

        let accepted = await alice.requestConnect(toPhone: bob.localPeer.phone)
        #expect(accepted == true)
    }

    // MARK: 6. DHT store → local retrieve

    @Test("stored value retrieved locally before TTL expires")
    func storeAndRetrieveLocally() async throws {
        let (alice, _) = try makeNode(phone: "dht-alice-\(UUID())")
        defer { alice.transport.stop() }

        alice.storage["test-key"] = DHTEntry(value: "hello-dht", storedAt: Date())
        let value = await alice.findValue(key: "test-key")
        #expect(value == "hello-dht")
    }

    // MARK: 7. Expired DHT entry not returned

    @Test("expired DHT entry is not returned by findValue")
    func expiredEntryIgnored() async throws {
        let (alice, _) = try makeNode(phone: "ttl-alice-\(UUID())")
        defer { alice.transport.stop() }

        let past = Date(timeIntervalSinceNow: -(AppConfig.dhtTTL + 1))
        alice.storage["stale-key"] = DHTEntry(value: "old-value", storedAt: past)

        // No peers to ask, so findValue falls through and returns nil for a stale local entry.
        let value = await alice.findValue(key: "stale-key")
        #expect(value == nil)
    }

    // MARK: 8. Bidirectional exchange

    @Test("bidirectional send: both nodes deliver to each other")
    func bidirectionalSend() async throws {
        let (alice, alicePort) = try makeNode(phone: "bi-alice-\(UUID())")
        let (bob,   bobPort)   = try makeNode(phone: "bi-bob-\(UUID())")
        defer { alice.transport.stop(); bob.transport.stop() }

        alice.addPeer(KadPeer(id: bob.localPeer.id,   ip: "127.0.0.1", port: bobPort,   phone: bob.localPeer.phone))
        bob.addPeer(KadPeer(id:   alice.localPeer.id, ip: "127.0.0.1", port: alicePort, phone: alice.localPeer.phone))

        let aliceBox = Mailbox()
        let bobBox   = Mailbox()
        alice.onChatMessage = { p, b, id, _ in aliceBox.push(phone: p, body: b, chatID: id) }
        bob.onChatMessage   = { p, b, id, _ in bobBox.push(phone: p, body: b, chatID: id) }

        async let a2b = alice.sendChat(toPhone: bob.localPeer.phone,   body: "Hi Bob!")
        async let b2a = bob.sendChat(toPhone:   alice.localPeer.phone, body: "Hi Alice!")
        let (aliceID, bobID) = await (a2b, b2a)

        #expect(aliceID != nil)
        #expect(bobID   != nil)

        let toAlice = await aliceBox.next()
        let toBob   = await bobBox.next()
        #expect(toAlice?.body == "Hi Alice!")
        #expect(toBob?.body   == "Hi Bob!")
    }
}

// MARK: - DHTEntry Tests
// Passes

@Suite("DHTEntry")
struct DHTEntryTests {

    @Test("fresh entry is not expired")
    func freshNotExpired() {
        let entry = DHTEntry(value: "1.2.3.4:4001", storedAt: Date())
        #expect(!entry.isExpired)
    }

    @Test("old entry is expired")
    func oldEntryExpired() {
        let past  = Date(timeIntervalSinceNow: -(AppConfig.dhtTTL + 1))
        let entry = DHTEntry(value: "1.2.3.4:4001", storedAt: past)
        #expect(entry.isExpired)
    }
}
