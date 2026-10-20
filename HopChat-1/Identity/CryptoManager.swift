//
//  CryptoManager.swift
//  HopChat-1
//
//  Identity keys, signing, and envelope sealing/opening — Design Contract §1, §2, §4, §7.
//
//  Threading: `nonisolated` + `@unchecked Sendable`; all mutable key state is
//  guarded by `lock`, so the network transport can seal/open off the main actor.
//

import Foundation
import CryptoKit
import os

nonisolated enum CryptoError: Error, Equatable {
    /// The secure store could not be read/written (e.g. device locked).
    /// Keys are NEVER regenerated in this case, retry later.
    case keyUnavailable
    /// No local agreement private key matches `envelope.recipientAgreementKey`.
    case noMatchingAgreementKey
    case invalidKey
    case sealFailed
    case openFailed
    case badSignature
    /// No identity certificate has been issued yet (not registered).
    case noCertificate
}

nonisolated final class CryptoManager: @unchecked Sendable {

    static let shared = CryptoManager(store: KeychainStore.shared)

    private enum Account {
        static let signing = "identity.signing.v2"
        static let agreement = "identity.agreement.v2"
        static let certificate = "identity.certificate.v2"
        static let all = [signing, agreement, certificate]
    }

    /// Retained rotated agreement keys stay usable for this long (§4: relayed
    /// mail may sit on the server for 7 days; 30 days gives ample slack).
    static let retentionWindow: TimeInterval = 30 * 86_400
    /// Agreement keys rotate weekly (§0 / §7).
    static let rotationInterval: TimeInterval = 7 * 86_400

    private let store: KeyValueSecureStore
    private let lock = NSLock()

    /// Injectable clock (tests). Set before first use.
    var now: @Sendable () -> Date = { ServerClock.now() }

    private var _signing: Curve25519.Signing.PrivateKey?
    private var _ring: AgreementRing?
    private var _certificate: IdentityCertificate?
    private var _certificateLoaded = false

    init(store: KeyValueSecureStore) {
        self.store = store
    }

    // MARK: - Stored agreement key ring

    private struct AgreementRing: Codable {
        struct Retired: Codable {
            var priv: String        // base64 raw private key
            var retiredAt: Int64    // unix seconds
        }
        var current: String         // base64 raw private key
        var currentCreatedAt: Int64
        var pending: String?        // prepared but not yet certified
        var retired: [Retired] = []
    }

    // MARK: - Key loading (contract: generate ONLY when the store returns nil)

    /// Loads (or, on a genuinely empty store, generates) the identity keys.
    /// Throws `CryptoError.keyUnavailable` if the store is unreadable — callers
    /// should retry later; keys are never overwritten.
    func ensureKeysLoaded() throws {
        lock.lock(); defer { lock.unlock() }
        try loadKeysLocked()
    }

    /// True when the identity keys are loaded and usable.
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return (try? loadKeysLocked()) != nil
    }

    private func loadKeysLocked() throws {
        if _signing == nil {
            let raw: Data?
            do { raw = try store.data(for: Account.signing) }
            catch {
                Log.crypto.error("signing key read failed: \(String(describing: error), privacy: .public)")
                throw CryptoError.keyUnavailable
            }
            if let raw {
                guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
                    // Present but unusable: do NOT overwrite, surface instead.
                    Log.crypto.error("stored signing key is malformed")
                    throw CryptoError.invalidKey
                }
                _signing = key
            } else {
                let key = Curve25519.Signing.PrivateKey()
                do { try store.set(key.rawRepresentation, for: Account.signing) }
                catch {
                    Log.crypto.error("signing key write failed: \(String(describing: error), privacy: .public)")
                    throw CryptoError.keyUnavailable
                }
                Log.crypto.notice("generated new identity signing key")
                _signing = key
            }
        }

        if _ring == nil {
            let raw: Data?
            do { raw = try store.data(for: Account.agreement) }
            catch {
                Log.crypto.error("agreement ring read failed: \(String(describing: error), privacy: .public)")
                throw CryptoError.keyUnavailable
            }
            if let raw {
                guard let ring = try? JSONDecoder().decode(AgreementRing.self, from: raw) else {
                    Log.crypto.error("stored agreement ring is malformed")
                    throw CryptoError.invalidKey
                }
                _ring = prune(ring)
            } else {
                let key = Curve25519.KeyAgreement.PrivateKey()
                let ring = AgreementRing(current: key.rawRepresentation.base64EncodedString(),
                                         currentCreatedAt: Int64(now().timeIntervalSince1970),
                                         pending: nil,
                                         retired: [])
                try persistLocked(ring)
                Log.crypto.notice("generated new identity agreement key")
                _ring = ring
            }
        }
    }

    private func persistLocked(_ ring: AgreementRing) throws {
        guard let data = try? JSONEncoder().encode(ring) else { throw CryptoError.invalidKey }
        do { try store.set(data, for: Account.agreement) }
        catch {
            Log.crypto.error("agreement ring write failed: \(String(describing: error), privacy: .public)")
            throw CryptoError.keyUnavailable
        }
        _ring = ring
    }

    private func prune(_ ring: AgreementRing) -> AgreementRing {
        var ring = ring
        let cutoff = Int64(now().addingTimeInterval(-Self.retentionWindow).timeIntervalSince1970)
        ring.retired.removeAll { $0.retiredAt < cutoff }
        return ring
    }

    private static func agreementPrivate(_ b64: String) -> Curve25519.KeyAgreement.PrivateKey? {
        guard let raw = Data(base64Encoded: b64) else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    // MARK: - Public keys

    /// Base64 raw Ed25519 public key; `""` if the store is currently unreadable.
    var signingPublicKeyBase64: String {
        (try? publicKeys().signing) ?? ""
    }

    /// Base64 raw X25519 public key; `""` if the store is currently unreadable.
    var agreementPublicKeyBase64: String {
        (try? publicKeys().agreement) ?? ""
    }

    /// Throwing accessor for both public keys — prefer this on paths that must
    /// distinguish "device locked" from "no identity".
    func publicKeys() throws -> (signing: String, agreement: String) {
        lock.lock(); defer { lock.unlock() }
        try loadKeysLocked()
        guard let signing = _signing, let ring = _ring,
              let ag = Self.agreementPrivate(ring.current) else { throw CryptoError.invalidKey }
        return (signing.publicKey.rawRepresentation.base64EncodedString(),
                ag.publicKey.rawRepresentation.base64EncodedString())
    }

    // MARK: - Certificate

    var certificate: IdentityCertificate? {
        lock.lock(); defer { lock.unlock() }
        return certificateLocked()
    }

    private func certificateLocked() -> IdentityCertificate? {
        if _certificateLoaded { return _certificate }
        let raw: Data?
        do { raw = try store.data(for: Account.certificate) }
        catch {
            Log.crypto.error("certificate read failed: \(String(describing: error), privacy: .public)")
            return nil    // not cached: retry on next access
        }
        _certificateLoaded = true
        if let raw, let s = String(data: raw, encoding: .utf8) {
            _certificate = IdentityCertificate.decode(s)
        } else {
            _certificate = nil
        }
        return _certificate
    }

    /// Stores the certificate issued for this device's keys.
    func setCertificate(_ cert: IdentityCertificate) throws {
        lock.lock(); defer { lock.unlock() }
        try loadKeysLocked()
        guard let signing = _signing else { throw CryptoError.invalidKey }
        guard cert.signingKey == signing.publicKey.rawRepresentation.base64EncodedString() else {
            // A certificate that does not bind our own key is useless (and a red flag).
            throw CryptoError.invalidKey
        }
        do { try store.set(Data(cert.encodedJSON().utf8), for: Account.certificate) }
        catch {
            Log.crypto.error("certificate write failed: \(String(describing: error), privacy: .public)")
            throw CryptoError.keyUnavailable
        }
        _certificate = cert
        _certificateLoaded = true
    }

    /// Our own E.164 phone from the stored certificate ("" when not registered).
    var myPhone: String { certificate?.phone ?? "" }

    // MARK: - Signing

    /// Signs the canonical encoding of `fields`. Returns `""` when the identity
    /// key is unavailable (use `signOrThrow` when that must be distinguished).
    func sign(_ fields: [String]) -> String {
        (try? signOrThrow(fields)) ?? ""
    }

    func signOrThrow(_ fields: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        try loadKeysLocked()
        guard let signing = _signing else { throw CryptoError.invalidKey }
        guard let sig = try? signing.signature(for: Canonical.encode(fields)) else {
            throw CryptoError.sealFailed
        }
        return sig.base64EncodedString()
    }

    /// Verifies an Ed25519 signature over `Canonical(fields)`.
    nonisolated static func verify(_ fields: [String], signature: String, signingKeyBase64: String) -> Bool {
        guard let sigData = Data(base64Encoded: signature), sigData.count == 64,
              let keyData = Data(base64Encoded: signingKeyBase64), keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sigData, for: Canonical.encode(fields))
    }

    // MARK: - Envelope sealing / opening (§4)

    private static let hkdfSalt = Data("hoppin-E2E-v2".utf8)

    private static func deriveKey(dh1: SharedSecret,
                                  dh2: SharedSecret,
                                  senderSigningKey: String,
                                  recipientSigningKey: String,
                                  header: [String]) -> SymmetricKey {
        var ikm = Data()
        dh1.withUnsafeBytes { ikm.append(contentsOf: $0) }
        dh2.withUnsafeBytes { ikm.append(contentsOf: $0) }
        let info = Canonical.encode(["hoppin-seal-v2", senderSigningKey, recipientSigningKey] + header)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                      salt: hkdfSalt,
                                      info: info,
                                      outputByteCount: 32)
    }

    /// Seals `payload` (the JSON `ChatPayload`) for `recipientCert`.
    func seal(_ payload: Data,
              envelopeID: String,
              recipientPhone: String,
              recipientCert: IdentityCertificate,
              timestamp: Int64) throws -> Envelope {
        lock.lock(); defer { lock.unlock() }
        try loadKeysLocked()
        guard let signing = _signing, let ring = _ring,
              let myAgreement = Self.agreementPrivate(ring.current) else { throw CryptoError.invalidKey }
        guard let cert = certificateLocked() else { throw CryptoError.noCertificate }
        guard let recipientAgreementPub = recipientCert.agreementPublicKey else { throw CryptoError.invalidKey }

        let mySigningKeyB64 = signing.publicKey.rawRepresentation.base64EncodedString()
        let myAgreementKeyB64 = myAgreement.publicKey.rawRepresentation.base64EncodedString()
        let recipientAgreementKeyB64 = recipientCert.agreementKey

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralKeyB64 = ephemeral.publicKey.rawRepresentation.base64EncodedString()

        let header = Envelope.header(id: envelopeID,
                                     senderPhone: cert.phone,
                                     recipientPhone: recipientPhone,
                                     timestamp: timestamp,
                                     senderAgreementKey: myAgreementKeyB64,
                                     recipientAgreementKey: recipientAgreementKeyB64,
                                     ephemeralKey: ephemeralKeyB64)

        guard let dh1 = try? ephemeral.sharedSecretFromKeyAgreement(with: recipientAgreementPub),
              let dh2 = try? myAgreement.sharedSecretFromKeyAgreement(with: recipientAgreementPub) else {
            throw CryptoError.sealFailed
        }
        let key = Self.deriveKey(dh1: dh1,
                                 dh2: dh2,
                                 senderSigningKey: mySigningKeyB64,
                                 recipientSigningKey: recipientCert.signingKey,
                                 header: header)

        guard let box = try? AES.GCM.seal(payload, using: key, authenticating: Canonical.encode(header)),
              let combined = box.combined else { throw CryptoError.sealFailed }
        let ciphertext = combined.base64EncodedString()

        guard let sig = try? signing.signature(for: Canonical.encode(header + [ciphertext])) else {
            throw CryptoError.sealFailed
        }

        return Envelope(id: envelopeID,
                        senderPhone: cert.phone,
                        recipientPhone: recipientPhone,
                        timestamp: timestamp,
                        senderAgreementKey: myAgreementKeyB64,
                        recipientAgreementKey: recipientAgreementKeyB64,
                        ephemeralKey: ephemeralKeyB64,
                        ciphertext: ciphertext,
                        senderCertificate: cert.encodedJSON(),
                        signature: sig.base64EncodedString())
    }

    /// Verifies the envelope signature and decrypts the payload.
    /// Certificate validity, freshness, replay and trust checks are the caller's
    /// responsibility (§4 "Receiver validation order").
    func open(_ envelope: Envelope, senderCert: IdentityCertificate) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try loadKeysLocked()
        guard let signing = _signing, let ring = _ring else { throw CryptoError.invalidKey }

        guard senderCert.phone == envelope.senderPhone else { throw CryptoError.badSignature }
        guard Self.verify(envelope.signedFields,
                          signature: envelope.signature,
                          signingKeyBase64: senderCert.signingKey) else { throw CryptoError.badSignature }

        // Pick the private key whose public key matches recipientAgreementKey.
        var candidates: [String] = [ring.current]
        if let pending = ring.pending { candidates.append(pending) }
        let cutoff = Int64(now().addingTimeInterval(-Self.retentionWindow).timeIntervalSince1970)
        candidates.append(contentsOf: ring.retired.filter { $0.retiredAt >= cutoff }.map(\.priv))

        var matched: Curve25519.KeyAgreement.PrivateKey?
        for b64 in candidates {
            guard let priv = Self.agreementPrivate(b64) else { continue }
            if priv.publicKey.rawRepresentation.base64EncodedString() == envelope.recipientAgreementKey {
                matched = priv
                break
            }
        }
        guard let priv = matched else { throw CryptoError.noMatchingAgreementKey }

        guard let ephRaw = Data(base64Encoded: envelope.ephemeralKey),
              let ephPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephRaw),
              let senderRaw = Data(base64Encoded: envelope.senderAgreementKey),
              let senderPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderRaw) else {
            throw CryptoError.invalidKey
        }
        guard let dh1 = try? priv.sharedSecretFromKeyAgreement(with: ephPub),
              let dh2 = try? priv.sharedSecretFromKeyAgreement(with: senderPub) else {
            throw CryptoError.openFailed
        }

        let key = Self.deriveKey(dh1: dh1,
                                 dh2: dh2,
                                 senderSigningKey: senderCert.signingKey,
                                 recipientSigningKey: signing.publicKey.rawRepresentation.base64EncodedString(),
                                 header: envelope.header)

        guard let ctData = Data(base64Encoded: envelope.ciphertext),
              let box = try? AES.GCM.SealedBox(combined: ctData),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Canonical.encode(envelope.header)) else {
            throw CryptoError.openFailed
        }
        return plain
    }

    // MARK: - Weekly agreement-key rotation

    /// True when the active agreement key is older than 7 days.
    var needsAgreementRotation: Bool {
        lock.lock(); defer { lock.unlock() }
        guard (try? loadKeysLocked()) != nil, let ring = _ring else { return false }
        return now().timeIntervalSince1970 - Double(ring.currentCreatedAt) > Self.rotationInterval
    }

    /// Generates (or returns the existing) pending agreement key and returns its
    /// base64 public key. The key is NOT active until `commitAgreementRotation`.
    func prepareAgreementRotation() -> String {
        (try? prepareAgreementRotationOrThrow()) ?? ""
    }

    func prepareAgreementRotationOrThrow() throws -> String {
        lock.lock(); defer { lock.unlock() }
        try loadKeysLocked()
        guard var ring = _ring else { throw CryptoError.invalidKey }
        if let pending = ring.pending, let priv = Self.agreementPrivate(pending) {
            return priv.publicKey.rawRepresentation.base64EncodedString()
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        ring.pending = key.rawRepresentation.base64EncodedString()
        try persistLocked(ring)
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Activates the pending key once the server has certified it. The previous
    /// key is retained for 30 days so relayed mail addressed to it still opens.
    func commitAgreementRotation(certificate cert: IdentityCertificate) throws {
        lock.lock(); defer { lock.unlock() }
        try loadKeysLocked()
        guard var ring = _ring, let signing = _signing else { throw CryptoError.invalidKey }
        guard let pendingB64 = ring.pending,
              let pending = Self.agreementPrivate(pendingB64),
              pending.publicKey.rawRepresentation.base64EncodedString() == cert.agreementKey else {
            throw CryptoError.invalidKey
        }
        guard cert.signingKey == signing.publicKey.rawRepresentation.base64EncodedString() else {
            throw CryptoError.invalidKey
        }

        let ts = Int64(now().timeIntervalSince1970)
        ring.retired.append(.init(priv: ring.current, retiredAt: ts))
        ring.current = pendingB64
        ring.currentCreatedAt = ts
        ring.pending = nil
        let cutoff = ts - Int64(Self.retentionWindow)
        ring.retired.removeAll { $0.retiredAt < cutoff }
        try persistLocked(ring)

        do { try store.set(Data(cert.encodedJSON().utf8), for: Account.certificate) }
        catch { throw CryptoError.keyUnavailable }
        _certificate = cert
        _certificateLoaded = true
        Log.crypto.notice("agreement key rotated")
    }

    /// All agreement public keys currently openable by this device
    /// (active, pending, and retained rotated keys).
    func openableAgreementKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard (try? loadKeysLocked()) != nil, let ring = _ring else { return [] }
        let cutoff = Int64(now().addingTimeInterval(-Self.retentionWindow).timeIntervalSince1970)
        let all = [ring.current] + (ring.pending.map { [$0] } ?? [])
            + ring.retired.filter { $0.retiredAt >= cutoff }.map(\.priv)
        return all.compactMap { Self.agreementPrivate($0)?.publicKey.rawRepresentation.base64EncodedString() }
    }

    // MARK: - Mesh (outer, anonymous layer)

    /// The BLE mesh wraps a sealed envelope in a second layer so the phones
    /// carrying it learn nothing: a fresh ephemeral key per packet, no sender
    /// field, and the packet header as authenticated data. Only the recipient
    /// can open it, and only by trying (there is no address on the wire).
    ///
    ///     body = ephemeral public key (32 B) || AES-GCM(payload)
    ///
    /// The inner envelope still carries the sender's signature and
    /// certificate, so authentication is unchanged — it just isn't visible
    /// until the recipient opens the outer layer.
    static let meshSalt = Data("hoppin-Mesh-v1".utf8)

    func sealForMesh(_ payload: Data,
                     recipientAgreementKeyBase64: String,
                     authenticating header: Data) throws -> Data {
        guard let raw = Data(base64Encoded: recipientAgreementKeyBase64),
              let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else {
            throw CryptoError.invalidKey
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        guard let dh = try? ephemeral.sharedSecretFromKeyAgreement(with: recipient) else {
            throw CryptoError.sealFailed
        }
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        let key = Self.meshKey(dh: dh, ephemeralPublic: ephemeralPublic, recipientPublic: raw)
        guard let box = try? AES.GCM.seal(payload, using: key, authenticating: header),
              let combined = box.combined else { throw CryptoError.sealFailed }
        return ephemeralPublic + combined
    }

    /// Tries to open a mesh body with every agreement key this device still
    /// holds. `nil` simply means "not ours" — the common case, and not an error.
    func openMesh(_ body: Data, authenticating header: Data) -> Data? {
        guard body.count > 32 else { return nil }
        let ephemeralPublic = body.prefix(32)
        let box = body.dropFirst(32)
        guard let sealed = try? AES.GCM.SealedBox(combined: box),
              let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublic) else {
            return nil
        }

        lock.lock(); defer { lock.unlock() }
        guard (try? loadKeysLocked()) != nil, let ring = _ring else { return nil }
        let cutoff = Int64(now().addingTimeInterval(-Self.retentionWindow).timeIntervalSince1970)
        let candidates = [ring.current] + (ring.pending.map { [$0] } ?? [])
            + ring.retired.filter { $0.retiredAt >= cutoff }.map(\.priv)

        for b64 in candidates {
            guard let priv = Self.agreementPrivate(b64),
                  let dh = try? priv.sharedSecretFromKeyAgreement(with: ephemeral) else { continue }
            let key = Self.meshKey(dh: dh,
                                   ephemeralPublic: Data(ephemeralPublic),
                                   recipientPublic: priv.publicKey.rawRepresentation)
            if let opened = try? AES.GCM.open(sealed, using: key, authenticating: header) {
                return opened
            }
        }
        return nil
    }

    /// Hints (see `MeshHint`) worth trying for packets addressed to this
    /// device: every agreement key it can still open, across the day boundary.
    func meshHints(at date: Date = Date()) -> Set<UInt8> {
        var out: Set<UInt8> = []
        for key in openableAgreementKeys() {
            out.formUnion(MeshHint.candidates(agreementKeyBase64: key, at: date))
        }
        return out
    }

    private static func meshKey(dh: SharedSecret,
                                ephemeralPublic: Data,
                                recipientPublic: Data) -> SymmetricKey {
        dh.hkdfDerivedSymmetricKey(using: SHA256.self,
                                   salt: meshSalt,
                                   sharedInfo: ephemeralPublic + recipientPublic,
                                   outputByteCount: 32)
    }

    // MARK: - Wipe

    /// Deletes every identity item (delete account / reset).
    func wipeAll() throws {
        lock.lock(); defer { lock.unlock() }
        _signing = nil
        _ring = nil
        _certificate = nil
        _certificateLoaded = false
        var thrown: Error?
        for account in Account.all {
            do { try store.delete(account) } catch { thrown = error }
        }
        if thrown != nil { throw CryptoError.keyUnavailable }
        Log.crypto.notice("identity wiped")
    }
}
