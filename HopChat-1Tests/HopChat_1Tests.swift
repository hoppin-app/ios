//
//  HopChat_1Tests.swift
//  HopChat-1Tests
//
//  Created by Rodrigo Loução on 25/02/2026.
//

import Testing
import CryptoKit
@testable import HopChat_1

// MARK: - NodeID Tests

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

// MARK: - DHTEntry Tests

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
