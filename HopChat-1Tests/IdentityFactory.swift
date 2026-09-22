//
//  IdentityFactory.swift
//  HopChat-1Tests
//
//  Builds `CryptoManager` instances with *known* keys, so the cross-language
//  fixtures (which were generated in Python) can be opened by the real Swift
//  implementation rather than by a test reimplementation of it.
//
//  `CryptoManager` deliberately exposes no key-import API — keys are only ever
//  generated on device. Tests therefore seed the secure store it reads, using
//  the storage format documented in CryptoManager (`AgreementRing`).
//

import Foundation
import CryptoKit
@testable import HopChat_1

enum SecureStoreAccount {
    static let signing = "identity.signing.v2"
    static let agreement = "identity.agreement.v2"
    static let certificate = "identity.certificate.v2"
}

enum IdentityFactory {

    /// The on-disk shape of `CryptoManager.AgreementRing` (private to the
    /// implementation, so it is mirrored here).
    struct AgreementRingJSON: Codable {
        struct Retired: Codable {
            var priv: String
            var retiredAt: Int64
        }
        var current: String
        var currentCreatedAt: Int64
        var pending: String?
        var retired: [Retired] = []
    }

    /// Seeds a secure store with a fixed identity.
    /// - Parameters:
    ///   - signingSeedBase64: raw 32-byte Ed25519 private key, base64.
    ///   - agreementPrivateBase64: raw 32-byte X25519 private key, base64.
    @discardableResult
    static func seed(_ store: KeyValueSecureStore,
                     signingSeedBase64: String,
                     agreementPrivateBase64: String,
                     certificateJSON: String? = nil,
                     createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                     retired: [AgreementRingJSON.Retired] = []) throws -> KeyValueSecureStore {
        guard let signingRaw = Data(base64Encoded: signingSeedBase64) else {
            throw CryptoError.invalidKey
        }
        try store.set(signingRaw, for: SecureStoreAccount.signing)

        let ring = AgreementRingJSON(current: agreementPrivateBase64,
                                     currentCreatedAt: Int64(createdAt.timeIntervalSince1970),
                                     pending: nil,
                                     retired: retired)
        try store.set(try JSONEncoder().encode(ring), for: SecureStoreAccount.agreement)

        if let certificateJSON {
            try store.set(Data(certificateJSON.utf8), for: SecureStoreAccount.certificate)
        }
        return store
    }

    /// A `CryptoManager` holding one of the fixture parties' keys.
    static func fixtureCrypto(party: CryptoVectors.Party,
                              certificateJSON: String?,
                              now: Date = Fixtures.referenceDate) throws -> CryptoManager {
        let store = InMemorySecureStore()
        try seed(store,
                 signingSeedBase64: party.signingSeedBase64,
                 agreementPrivateBase64: party.agreementPrivateBase64,
                 certificateJSON: certificateJSON)
        let crypto = CryptoManager(store: store)
        crypto.now = TestClock.fixed(now)
        return crypto
    }

    /// A freshly generated identity plus a certificate signed by `serverKey`,
    /// for tests that do not need the fixtures.
    static func makeLocal(phone: String,
                          serverKey: Curve25519.Signing.PrivateKey,
                          now: Date = Date(),
                          validity: TimeInterval = 30 * 86_400,
                          store: KeyValueSecureStore = InMemorySecureStore())
    throws -> (crypto: CryptoManager, certificate: IdentityCertificate) {
        let crypto = CryptoManager(store: store)
        crypto.now = TestClock.fixed(now)
        try crypto.ensureKeysLoaded()
        let keys = try crypto.publicKeys()
        let cert = makeCertificate(phone: phone,
                                   signingKey: keys.signing,
                                   agreementKey: keys.agreement,
                                   serverKey: serverKey,
                                   issuedAt: now,
                                   validity: validity)
        try crypto.setCertificate(cert)
        return (crypto, cert)
    }

    /// Signs a certificate exactly as `bootstrap.py` does (contract §2).
    static func makeCertificate(phone: String,
                                signingKey: String,
                                agreementKey: String,
                                serverKey: Curve25519.Signing.PrivateKey,
                                issuedAt: Date = Date(),
                                validity: TimeInterval = 30 * 86_400,
                                serial: String = UUID().uuidString) -> IdentityCertificate {
        let issued = Int64(issuedAt.timeIntervalSince1970)
        let expires = issued + Int64(validity)
        let fields = ["hoppin-cert-v1",
                      phone,
                      signingKey,
                      agreementKey,
                      String(issued),
                      String(expires),
                      serial]
        let signature = (try? serverKey.signature(for: Canonical.encode(fields)))?
            .base64EncodedString() ?? ""
        return IdentityCertificate(phone: phone,
                                   signingKey: signingKey,
                                   agreementKey: agreementKey,
                                   issuedAt: issued,
                                   expiresAt: expires,
                                   serial: serial,
                                   sig: signature)
    }
}
