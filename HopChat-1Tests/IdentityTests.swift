//
//  IdentityTests.swift
//  HopChat-1Tests
//
//  CryptoManager (sealing, rotation, key-loading safety) and TrustStore
//  (TOFU pinning, key change, verification, QR) — contract §2, §4, §7.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

// MARK: - Helpers

private func makePair(now: Date = Date(timeIntervalSince1970: 1_790_000_000))
throws -> (server: Curve25519.Signing.PrivateKey,
           alice: (crypto: CryptoManager, certificate: IdentityCertificate),
           bob: (crypto: CryptoManager, certificate: IdentityCertificate)) {
    let server = Curve25519.Signing.PrivateKey()
    let alice = try IdentityFactory.makeLocal(phone: "+351912345678", serverKey: server, now: now)
    let bob = try IdentityFactory.makeLocal(phone: "+14155552671", serverKey: server, now: now)
    return (server, alice, bob)
}

private func textPayload(_ text: String) throws -> Data {
    try ChatPayload(kind: .text, text: text, sentAt: 1_790_000_000).encoded()
}

// MARK: - Sealing / opening

@Suite("CryptoManager — seal and open (§4)")
struct SealOpenTests {

    @Test("seal then open round-trips the payload")
    func roundTrip() throws {
        let (_, alice, bob) = try makePair()
        let payload = try textPayload("Olá 👋")

        let envelope = try alice.crypto.seal(payload,
                                             envelopeID: UUID().uuidString,
                                             recipientPhone: bob.certificate.phone,
                                             recipientCert: bob.certificate,
                                             timestamp: 1_790_000_000)
        let opened = try bob.crypto.open(envelope, senderCert: alice.certificate)
        #expect(opened == payload)

        let decoded = try #require(ChatPayload.decode(opened))
        #expect(decoded.text == "Olá 👋")
    }

    @Test("the sealed envelope exposes no plaintext")
    func noPlaintextLeak() throws {
        let (_, alice, bob) = try makePair()
        let secret = "attack at dawn"
        let envelope = try alice.crypto.seal(try textPayload(secret),
                                             envelopeID: UUID().uuidString,
                                             recipientPhone: bob.certificate.phone,
                                             recipientCert: bob.certificate,
                                             timestamp: 1_790_000_000)
        let blob = try String(decoding: JSONEncoder().encode(envelope), as: UTF8.self)
        #expect(blob.contains(secret) == false)
        #expect(blob.contains("kind") == false)
    }

    @Test("tampered ciphertext is rejected")
    func tamperedCiphertext() throws {
        let (_, alice, bob) = try makePair()
        let envelope = try alice.crypto.seal(try textPayload("hello"),
                                             envelopeID: UUID().uuidString,
                                             recipientPhone: bob.certificate.phone,
                                             recipientCert: bob.certificate,
                                             timestamp: 1_790_000_000)

        var raw = try #require(Data(base64Encoded: envelope.ciphertext))
        raw[raw.count - 1] ^= 0x01                      // flip a tag bit
        let tampered = Envelope(id: envelope.id,
                                senderPhone: envelope.senderPhone,
                                recipientPhone: envelope.recipientPhone,
                                timestamp: envelope.timestamp,
                                senderAgreementKey: envelope.senderAgreementKey,
                                recipientAgreementKey: envelope.recipientAgreementKey,
                                ephemeralKey: envelope.ephemeralKey,
                                ciphertext: raw.base64EncodedString(),
                                senderCertificate: envelope.senderCertificate,
                                signature: envelope.signature)

        // The signature covers the ciphertext, so this fails before decryption.
        #expect(throws: CryptoError.badSignature) {
            _ = try bob.crypto.open(tampered, senderCert: alice.certificate)
        }
    }

    @Test("a tampered header (AAD) is rejected")
    func tamperedHeader() throws {
        let (_, alice, bob) = try makePair()
        let envelope = try alice.crypto.seal(try textPayload("hello"),
                                             envelopeID: UUID().uuidString,
                                             recipientPhone: bob.certificate.phone,
                                             recipientCert: bob.certificate,
                                             timestamp: 1_790_000_000)
        let tampered = Envelope(id: envelope.id,
                                senderPhone: envelope.senderPhone,
                                recipientPhone: envelope.recipientPhone,
                                timestamp: envelope.timestamp + 60,
                                senderAgreementKey: envelope.senderAgreementKey,
                                recipientAgreementKey: envelope.recipientAgreementKey,
                                ephemeralKey: envelope.ephemeralKey,
                                ciphertext: envelope.ciphertext,
                                senderCertificate: envelope.senderCertificate,
                                signature: envelope.signature)
        #expect(throws: CryptoError.badSignature) {
            _ = try bob.crypto.open(tampered, senderCert: alice.certificate)
        }
    }

    @Test("a re-signed but header-tampered envelope still fails the AEAD")
    func resignedHeaderStillFailsAEAD() throws {
        let (_, alice, bob) = try makePair()
        let envelope = try alice.crypto.seal(try textPayload("hello"),
                                             envelopeID: UUID().uuidString,
                                             recipientPhone: bob.certificate.phone,
                                             recipientCert: bob.certificate,
                                             timestamp: 1_790_000_000)
        // The attacker controls the signature (they are the sender) but the
        // header is also AEAD-authenticated, so decryption must still fail.
        let mutated = Envelope(id: envelope.id,
                               senderPhone: envelope.senderPhone,
                               recipientPhone: envelope.recipientPhone,
                               timestamp: envelope.timestamp + 60,
                               senderAgreementKey: envelope.senderAgreementKey,
                               recipientAgreementKey: envelope.recipientAgreementKey,
                               ephemeralKey: envelope.ephemeralKey,
                               ciphertext: envelope.ciphertext,
                               senderCertificate: envelope.senderCertificate,
                               signature: alice.crypto.sign(
                                   Envelope.header(id: envelope.id,
                                                   senderPhone: envelope.senderPhone,
                                                   recipientPhone: envelope.recipientPhone,
                                                   timestamp: envelope.timestamp + 60,
                                                   senderAgreementKey: envelope.senderAgreementKey,
                                                   recipientAgreementKey: envelope.recipientAgreementKey,
                                                   ephemeralKey: envelope.ephemeralKey)
                                   + [envelope.ciphertext]))
        #expect(throws: CryptoError.openFailed) {
            _ = try bob.crypto.open(mutated, senderCert: alice.certificate)
        }
    }

    @Test("a forged signature from another key is rejected")
    func forgedSignature() throws {
        let (server, alice, bob) = try makePair()
        let mallory = try IdentityFactory.makeLocal(phone: "+447700900123", serverKey: server)
        let envelope = try mallory.crypto.seal(try textPayload("I am alice"),
                                               envelopeID: UUID().uuidString,
                                               recipientPhone: bob.certificate.phone,
                                               recipientCert: bob.certificate,
                                               timestamp: 1_790_000_000)
        // Mallory's envelope presented as alice's: the signature no longer matches.
        #expect(throws: CryptoError.badSignature) {
            _ = try bob.crypto.open(envelope, senderCert: alice.certificate)
        }
    }

    @Test("the wrong recipient has no matching agreement key")
    func wrongRecipient() throws {
        let (server, alice, bob) = try makePair()
        let carol = try IdentityFactory.makeLocal(phone: "+447700900123", serverKey: server)
        let envelope = try alice.crypto.seal(try textPayload("for bob only"),
                                             envelopeID: UUID().uuidString,
                                             recipientPhone: bob.certificate.phone,
                                             recipientCert: bob.certificate,
                                             timestamp: 1_790_000_000)
        #expect(throws: CryptoError.noMatchingAgreementKey) {
            _ = try carol.crypto.open(envelope, senderCert: alice.certificate)
        }
    }

    @Test("each message uses a fresh ephemeral key and fresh ciphertext")
    func ephemeralKeysDiffer() throws {
        let (_, alice, bob) = try makePair()
        let payload = try textPayload("same text")
        var ephemerals = Set<String>()
        var ciphertexts = Set<String>()
        for _ in 0..<8 {
            let envelope = try alice.crypto.seal(payload,
                                                 envelopeID: UUID().uuidString,
                                                 recipientPhone: bob.certificate.phone,
                                                 recipientCert: bob.certificate,
                                                 timestamp: 1_790_000_000)
            ephemerals.insert(envelope.ephemeralKey)
            ciphertexts.insert(envelope.ciphertext)
        }
        #expect(ephemerals.count == 8)
        #expect(ciphertexts.count == 8)
    }

    @Test("sealing without a certificate throws noCertificate")
    func sealWithoutCertificate() throws {
        let (_, _, bob) = try makePair()
        let anonymous = CryptoManager(store: InMemorySecureStore())
        #expect(throws: CryptoError.noCertificate) {
            _ = try anonymous.seal(try textPayload("hi"),
                                   envelopeID: UUID().uuidString,
                                   recipientPhone: bob.certificate.phone,
                                   recipientCert: bob.certificate,
                                   timestamp: 1_790_000_000)
        }
    }

    @Test("a certificate that does not bind our own key is refused")
    func foreignCertificateRefused() throws {
        let (_, _, bob) = try makePair()
        let crypto = CryptoManager(store: InMemorySecureStore())
        try crypto.ensureKeysLoaded()
        #expect(throws: CryptoError.invalidKey) {
            try crypto.setCertificate(bob.certificate)
        }
    }
}

// MARK: - Key loading safety (the v1 "locked device wiped the identity" bug)

@Suite("CryptoManager — key loading never destroys an identity")
struct KeyLoadingTests {

    @Test("a throwing store surfaces keyUnavailable instead of generating keys")
    func throwingStoreDoesNotRegenerate() throws {
        let store = ThrowingSecureStore(isAvailable: true)

        // First launch with a working store: an identity is created.
        let first = CryptoManager(store: store)
        try first.ensureKeysLoaded()
        let originalSigning = try first.publicKeys().signing
        let originalAgreement = try first.publicKeys().agreement
        #expect(originalSigning.isEmpty == false)

        // Device locked: every read throws.
        store.isAvailable = false
        let locked = CryptoManager(store: store)
        #expect(throws: CryptoError.keyUnavailable) {
            try locked.ensureKeysLoaded()
        }
        #expect(locked.isReady == false)
        #expect(locked.signingPublicKeyBase64.isEmpty)
        #expect(locked.agreementPublicKeyBase64.isEmpty)

        // Unlocked again: the SAME identity is still there.
        store.isAvailable = true
        let recovered = CryptoManager(store: store)
        try recovered.ensureKeysLoaded()
        #expect(try recovered.publicKeys().signing == originalSigning)
        #expect(try recovered.publicKeys().agreement == originalAgreement)
    }

    @Test("a locked store never overwrites the stored key material")
    func lockedStoreWritesNothing() throws {
        let backing = SharedMemoryStore()
        let crypto = CryptoManager(store: backing)
        try crypto.ensureKeysLoaded()
        let before = backing.snapshot

        let throwing = ThrowingSecureStore(isAvailable: false)
        let locked = CryptoManager(store: throwing)
        _ = try? locked.ensureKeysLoaded()
        _ = locked.sign(["x"])
        _ = locked.prepareAgreementRotation()

        // The real store is untouched, and nothing was written to the failing one.
        #expect(backing.snapshot == before)
    }

    @Test("a malformed stored key is surfaced, not replaced")
    func malformedKeyIsNotReplaced() throws {
        let store = InMemorySecureStore()
        try store.set(Data([0x01, 0x02, 0x03]), for: SecureStoreAccount.signing)
        let crypto = CryptoManager(store: store)
        #expect(throws: CryptoError.invalidKey) {
            try crypto.ensureKeysLoaded()
        }
        #expect(try store.data(for: SecureStoreAccount.signing) == Data([0x01, 0x02, 0x03]))
    }

    @Test("sign returns empty rather than signing with a degraded key")
    func signWithUnavailableKey() {
        let crypto = CryptoManager(store: ThrowingSecureStore(isAvailable: false))
        #expect(crypto.sign(["hoppin-wire-v2"]).isEmpty)
        #expect(throws: CryptoError.keyUnavailable) {
            _ = try crypto.signOrThrow(["hoppin-wire-v2"])
        }
    }

    @Test("wipeAll removes every identity item")
    func wipe() throws {
        let store = InMemorySecureStore()
        let server = Curve25519.Signing.PrivateKey()
        let (crypto, _) = try IdentityFactory.makeLocal(phone: "+351912345678",
                                                        serverKey: server,
                                                        store: store)
        #expect(crypto.certificate != nil)
        try crypto.wipeAll()
        #expect(try store.data(for: SecureStoreAccount.signing) == nil)
        #expect(try store.data(for: SecureStoreAccount.agreement) == nil)
        #expect(try store.data(for: SecureStoreAccount.certificate) == nil)
        #expect(crypto.certificate == nil)
        #expect(crypto.myPhone.isEmpty)
    }
}

// MARK: - Agreement-key rotation

@Suite("CryptoManager — weekly agreement-key rotation")
struct RotationTests {

    @Test("rotation is due only after 7 days")
    func rotationSchedule() throws {
        let clock = TestClock.Movable(Date(timeIntervalSince1970: 1_790_000_000))
        let crypto = CryptoManager(store: InMemorySecureStore())
        crypto.now = clock.closure
        try crypto.ensureKeysLoaded()

        #expect(crypto.needsAgreementRotation == false)
        clock.advance(by: 6 * 86_400)
        #expect(crypto.needsAgreementRotation == false)
        clock.advance(by: 2 * 86_400)
        #expect(crypto.needsAgreementRotation)
    }

    @Test("mail addressed to the previous key still opens after rotation")
    func oldMailStillOpens() throws {
        let server = Curve25519.Signing.PrivateKey()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = TestClock.Movable(start)

        let bobStore = InMemorySecureStore()
        let bobCrypto = CryptoManager(store: bobStore)
        bobCrypto.now = clock.closure
        try bobCrypto.ensureKeysLoaded()
        let bobKeys = try bobCrypto.publicKeys()
        let bobCert = IdentityFactory.makeCertificate(phone: "+14155552671",
                                                      signingKey: bobKeys.signing,
                                                      agreementKey: bobKeys.agreement,
                                                      serverKey: server,
                                                      issuedAt: start)
        try bobCrypto.setCertificate(bobCert)

        let alice = try IdentityFactory.makeLocal(phone: "+351912345678",
                                                   serverKey: server,
                                                   now: start)

        // Alice seals against bob's CURRENT key, then bob rotates.
        let envelope = try alice.crypto.seal(try textPayload("before rotation"),
                                             envelopeID: UUID().uuidString,
                                             recipientPhone: bobCert.phone,
                                             recipientCert: bobCert,
                                             timestamp: Int64(start.timeIntervalSince1970))

        clock.advance(by: 8 * 86_400)
        #expect(bobCrypto.needsAgreementRotation)
        let pending = try bobCrypto.prepareAgreementRotationOrThrow()
        #expect(pending != bobKeys.agreement)
        let renewed = IdentityFactory.makeCertificate(phone: "+14155552671",
                                                      signingKey: bobKeys.signing,
                                                      agreementKey: pending,
                                                      serverKey: server,
                                                      issuedAt: clock.now)
        try bobCrypto.commitAgreementRotation(certificate: renewed)

        #expect(bobCrypto.certificate?.agreementKey == pending)
        #expect(bobCrypto.needsAgreementRotation == false)
        #expect(bobCrypto.openableAgreementKeys().contains(bobKeys.agreement))

        // Relayed mail sealed against the old key must still open.
        let opened = try bobCrypto.open(envelope, senderCert: alice.certificate)
        #expect(ChatPayload.decode(opened)?.text == "before rotation")
    }

    @Test("a retired key is dropped after the 30-day retention window")
    func retiredKeyExpires() throws {
        let server = Curve25519.Signing.PrivateKey()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = TestClock.Movable(start)

        let bobCrypto = CryptoManager(store: InMemorySecureStore())
        bobCrypto.now = clock.closure
        try bobCrypto.ensureKeysLoaded()
        let bobKeys = try bobCrypto.publicKeys()
        try bobCrypto.setCertificate(
            IdentityFactory.makeCertificate(phone: "+14155552671",
                                            signingKey: bobKeys.signing,
                                            agreementKey: bobKeys.agreement,
                                            serverKey: server,
                                            issuedAt: start))

        let alice = try IdentityFactory.makeLocal(phone: "+351912345678",
                                                   serverKey: server,
                                                   now: start)
        let oldCert = try #require(bobCrypto.certificate)
        let envelope = try alice.crypto.seal(try textPayload("ancient"),
                                             envelopeID: UUID().uuidString,
                                             recipientPhone: oldCert.phone,
                                             recipientCert: oldCert,
                                             timestamp: Int64(start.timeIntervalSince1970))

        clock.advance(by: 8 * 86_400)
        let pending = try bobCrypto.prepareAgreementRotationOrThrow()
        try bobCrypto.commitAgreementRotation(
            certificate: IdentityFactory.makeCertificate(phone: "+14155552671",
                                                         signingKey: bobKeys.signing,
                                                         agreementKey: pending,
                                                         serverKey: server,
                                                         issuedAt: clock.now))
        #expect(throws: Never.self) {
            _ = try bobCrypto.open(envelope, senderCert: alice.certificate)
        }

        // 31 days after retirement the old key is gone for good.
        clock.advance(by: 31 * 86_400)
        #expect(bobCrypto.openableAgreementKeys().contains(bobKeys.agreement) == false)
        #expect(throws: CryptoError.noMatchingAgreementKey) {
            _ = try bobCrypto.open(envelope, senderCert: alice.certificate)
        }
    }

    @Test("commit refuses a certificate that does not carry the pending key")
    func commitRefusesMismatch() throws {
        let server = Curve25519.Signing.PrivateKey()
        let crypto = CryptoManager(store: InMemorySecureStore())
        try crypto.ensureKeysLoaded()
        let keys = try crypto.publicKeys()
        try crypto.setCertificate(
            IdentityFactory.makeCertificate(phone: "+351912345678",
                                            signingKey: keys.signing,
                                            agreementKey: keys.agreement,
                                            serverKey: server))
        _ = try crypto.prepareAgreementRotationOrThrow()

        let wrong = IdentityFactory.makeCertificate(
            phone: "+351912345678",
            signingKey: keys.signing,
            agreementKey: Curve25519.KeyAgreement.PrivateKey().publicKey
                .rawRepresentation.base64EncodedString(),
            serverKey: server)
        #expect(throws: CryptoError.invalidKey) {
            try crypto.commitAgreementRotation(certificate: wrong)
        }
    }

    @Test("prepare is idempotent until it is committed")
    func prepareIsIdempotent() throws {
        let crypto = CryptoManager(store: InMemorySecureStore())
        try crypto.ensureKeysLoaded()
        let first = try crypto.prepareAgreementRotationOrThrow()
        let second = try crypto.prepareAgreementRotationOrThrow()
        #expect(first == second)
    }
}

// MARK: - TrustStore

@MainActor
@Suite("TrustStore — TOFU pinning and key change (§2, §7)")
struct TrustStoreTests {

    private func makeCert(phone: String = "+14155552671",
                          serverKey: Curve25519.Signing.PrivateKey,
                          signing: String? = nil,
                          agreement: String? = nil,
                          issuedAt: Date = Date(timeIntervalSince1970: 1_790_000_000))
    -> IdentityCertificate {
        IdentityFactory.makeCertificate(
            phone: phone,
            signingKey: signing ?? Curve25519.Signing.PrivateKey().publicKey
                .rawRepresentation.base64EncodedString(),
            agreementKey: agreement ?? Curve25519.KeyAgreement.PrivateKey().publicKey
                .rawRepresentation.base64EncodedString(),
            serverKey: serverKey,
            issuedAt: issuedAt)
    }

    @Test("first sight pins; the same key afterwards is trusted")
    func tofu() {
        let server = Curve25519.Signing.PrivateKey()
        let trust = TrustStore(store: InMemorySecureStore())
        let cert = makeCert(serverKey: server)

        #expect(trust.evaluate(cert) == .newContact)
        #expect(trust.evaluate(cert) == .trusted)
        #expect(trust.pinnedCertificate(for: cert.phone) == cert)
        #expect(trust.pinnedSigningKey(for: cert.phone) == cert.signingKey)
        #expect(trust.pendingKeyChanges.isEmpty)
    }

    @Test("agreement-key rotation with the same signing key stays trusted")
    func rotationIsSilent() {
        let server = Curve25519.Signing.PrivateKey()
        let trust = TrustStore(store: InMemorySecureStore())
        let first = makeCert(serverKey: server)
        #expect(trust.evaluate(first) == .newContact)

        let rotated = makeCert(phone: first.phone,
                               serverKey: server,
                               signing: first.signingKey,
                               issuedAt: Date(timeIntervalSince1970: 1_790_600_000))
        #expect(trust.evaluate(rotated) == .trusted)
        #expect(trust.pinnedCertificate(for: first.phone)?.agreementKey == rotated.agreementKey)
        // Both agreement keys stay acceptable inside the retention window.
        #expect(trust.isRecentAgreementKey(first.agreementKey, for: first.phone))
        #expect(trust.isRecentAgreementKey(rotated.agreementKey, for: first.phone))
    }

    @Test("a different signing key raises keyChanged and blocks sending")
    func keyChangeDetected() {
        let server = Curve25519.Signing.PrivateKey()
        let trust = TrustStore(store: InMemorySecureStore())
        let original = makeCert(serverKey: server)
        #expect(trust.evaluate(original) == .newContact)

        let impostor = makeCert(phone: original.phone, serverKey: server)
        #expect(trust.evaluate(impostor) == .keyChanged(previousSigningKey: original.signingKey))
        #expect(trust.hasPendingKeyChange(original.phone))
        #expect(trust.pendingKeyChanges.contains(original.phone))
        // The pin is NOT replaced automatically.
        #expect(trust.pinnedSigningKey(for: original.phone) == original.signingKey)
        #expect(trust.pendingCertificate(for: original.phone) == impostor)
    }

    @Test("accepting a key change re-pins and clears verification")
    func acceptKeyChange() {
        let server = Curve25519.Signing.PrivateKey()
        let trust = TrustStore(store: InMemorySecureStore())
        let original = makeCert(serverKey: server)
        trust.evaluate(original)
        trust.setVerified(original.phone, true)
        #expect(trust.isVerified(original.phone))

        let replacement = makeCert(phone: original.phone, serverKey: server)
        trust.evaluate(replacement)
        trust.acceptKeyChange(for: original.phone)

        #expect(trust.pendingKeyChanges.isEmpty)
        #expect(trust.hasPendingKeyChange(original.phone) == false)
        #expect(trust.pinnedSigningKey(for: original.phone) == replacement.signingKey)
        #expect(trust.isVerified(original.phone) == false, "verification must not survive a key change")
    }

    @Test("rejecting a key change keeps the old pin")
    func rejectKeyChange() {
        let server = Curve25519.Signing.PrivateKey()
        let trust = TrustStore(store: InMemorySecureStore())
        let original = makeCert(serverKey: server)
        trust.evaluate(original)
        let impostor = makeCert(phone: original.phone, serverKey: server)
        trust.evaluate(impostor)

        trust.rejectKeyChange(for: original.phone)
        #expect(trust.pendingKeyChanges.isEmpty)
        #expect(trust.pinnedSigningKey(for: original.phone) == original.signingKey)
        #expect(trust.pendingCertificate(for: original.phone) == nil)
    }

    @Test("an unreadable store reports unavailable rather than pinning")
    func unavailableNeverPins() {
        let server = Curve25519.Signing.PrivateKey()
        let throwing = ThrowingSecureStore(isAvailable: false)
        let trust = TrustStore(store: throwing)
        let cert = makeCert(serverKey: server)

        #expect(trust.evaluate(cert) == .unavailable,
                "a locked Keychain must never be treated as a new contact")
        #expect(trust.pinnedCertificate(for: cert.phone) == nil)
        #expect(trust.pinnedSigningKey(for: cert.phone) == nil)
        #expect(trust.isVerified(cert.phone) == false)

        // Once readable, normal TOFU resumes.
        throwing.isAvailable = true
        #expect(trust.evaluate(cert) == .newContact)
    }

    @Test("agreement keys older than 30 days stop being acceptable")
    func agreementRetention() {
        let server = Curve25519.Signing.PrivateKey()
        let clock = TestClock.Movable(Date(timeIntervalSince1970: 1_790_000_000))
        let trust = TrustStore(store: InMemorySecureStore())
        trust.now = { clock.now }

        let cert = makeCert(serverKey: server)
        trust.evaluate(cert)
        #expect(trust.isRecentAgreementKey(cert.agreementKey, for: cert.phone))

        clock.advance(by: 31 * 86_400)
        #expect(trust.isRecentAgreementKey(cert.agreementKey, for: cert.phone) == false)
    }

    @Test("migratePin carries the pin to a new number")
    func migratePin() {
        let server = Curve25519.Signing.PrivateKey()
        let trust = TrustStore(store: InMemorySecureStore())
        let cert = makeCert(serverKey: server)
        trust.evaluate(cert)
        trust.setVerified(cert.phone, true)

        trust.migratePin(from: cert.phone, to: "+351911111111")
        #expect(trust.pinnedSigningKey(for: cert.phone) == nil)
        #expect(trust.pinnedSigningKey(for: "+351911111111") == cert.signingKey)
        #expect(trust.isVerified("+351911111111"))
    }

    @Test("migratePin carries a pending key change too")
    func migratePendingChange() {
        let server = Curve25519.Signing.PrivateKey()
        let trust = TrustStore(store: InMemorySecureStore())
        let cert = makeCert(serverKey: server)
        trust.evaluate(cert)
        trust.evaluate(makeCert(phone: cert.phone, serverKey: server))
        #expect(trust.pendingKeyChanges.contains(cert.phone))

        trust.migratePin(from: cert.phone, to: "+351911111111")
        #expect(trust.pendingKeyChanges.contains(cert.phone) == false)
        #expect(trust.pendingKeyChanges.contains("+351911111111"))
    }

    @Test("verification flags persist through the secure store")
    func verificationPersists() throws {
        let server = Curve25519.Signing.PrivateKey()
        let backing = SharedMemoryStore()
        let cert = makeCert(serverKey: server)

        let first = TrustStore(store: backing)
        first.evaluate(cert)
        first.setVerified(cert.phone, true)

        let reloaded = TrustStore(store: SharedMemoryStore(items: backing.snapshot))
        #expect(reloaded.isVerified(cert.phone))
        #expect(reloaded.pinnedSigningKey(for: cert.phone) == cert.signingKey)
    }

    @Test("wipe clears every pin")
    func wipe() {
        let server = Curve25519.Signing.PrivateKey()
        let store = InMemorySecureStore()
        let trust = TrustStore(store: store)
        let cert = makeCert(serverKey: server)
        trust.evaluate(cert)
        trust.evaluate(makeCert(phone: cert.phone, serverKey: server))

        trust.wipe()
        #expect(trust.pinnedCertificate(for: cert.phone) == nil)
        #expect(trust.pendingKeyChanges.isEmpty)
        #expect(try! store.data(for: "trust.pins.v2") == nil)
    }
}

// MARK: - QR verification

@Suite("TrustStore — QR verification strings (§7)")
struct QRTests {

    @Test("qrString and parseQR round-trip")
    func roundTrip() {
        let key = Curve25519.Signing.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        let phone = "+351912345678"
        let qr = TrustStore.qrString(phone: phone, signingKey: key)

        #expect(qr.hasPrefix("hoppin://verify?p=\(phone)&k="))
        #expect(qr.contains("+") == false || qr.contains("?p=+"))   // only the phone's plus

        let parsed = TrustStore.parseQR(qr)
        #expect(parsed?.phone == phone)
        #expect(parsed?.signingKey == key)
    }

    @Test("base64url encoding survives keys containing + and /")
    func base64URLSafety() throws {
        // Search for a key whose standard base64 has URL-unsafe characters.
        var key = ""
        for _ in 0..<64 {
            let candidate = Curve25519.Signing.PrivateKey().publicKey
                .rawRepresentation.base64EncodedString()
            if candidate.contains("+") || candidate.contains("/") { key = candidate; break }
        }
        guard !key.isEmpty else { return }  // vanishingly unlikely
        let qr = TrustStore.qrString(phone: "+14155552671", signingKey: key)
        let keyPart = try #require(qr.components(separatedBy: "&k=").last)
        #expect(keyPart.contains("/") == false)
        #expect(keyPart.contains("+") == false)
        #expect(TrustStore.parseQR(qr)?.signingKey == key)
    }

    @Test("malformed QR payloads are rejected")
    func malformed() {
        let key = Curve25519.Signing.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        #expect(TrustStore.parseQR("") == nil)
        #expect(TrustStore.parseQR("https://example.com/verify?p=+351912345678&k=\(key)") == nil)
        #expect(TrustStore.parseQR("hoppin://other?p=+351912345678&k=\(key)") == nil)
        #expect(TrustStore.parseQR("hoppin://verify?p=351912345678&k=\(key)") == nil)
        #expect(TrustStore.parseQR("hoppin://verify?p=+351912345678") == nil)
        #expect(TrustStore.parseQR("hoppin://verify?p=+351912345678&k=notbase64!!") == nil)
        // A 16-byte key is not a Curve25519 key.
        let short = Data(repeating: 7, count: 16).base64EncodedString()
        #expect(TrustStore.parseQR("hoppin://verify?p=+351912345678&k=\(short)") == nil)
    }

    @Test("surrounding whitespace from a scanner is tolerated")
    func whitespaceTolerated() {
        let key = Curve25519.Signing.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        let qr = "  " + TrustStore.qrString(phone: "+14155552671", signingKey: key) + "\n"
        #expect(TrustStore.parseQR(qr)?.phone == "+14155552671")
    }
}
