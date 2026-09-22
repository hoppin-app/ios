//
//  IdentityCertificate.swift
//  HopChat-1
//
//  Server-signed binding phone → (signingKey, agreementKey) — Design Contract §2.
//

import Foundation
import CryptoKit

nonisolated struct IdentityCertificate: Codable, Equatable, Hashable, Sendable {
    let v: Int
    let phone: String
    /// Base64 raw 32-byte Ed25519 public key.
    let signingKey: String
    /// Base64 raw 32-byte X25519 public key.
    let agreementKey: String
    /// Unix seconds.
    let issuedAt: Int64
    /// Unix seconds.
    let expiresAt: Int64
    let serial: String
    /// Base64 raw 64-byte Ed25519 signature by the server key.
    let sig: String

    init(v: Int = 1,
         phone: String,
         signingKey: String,
         agreementKey: String,
         issuedAt: Int64,
         expiresAt: Int64,
         serial: String,
         sig: String) {
        self.v = v
        self.phone = phone
        self.signingKey = signingKey
        self.agreementKey = agreementKey
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.serial = serial
        self.sig = sig
    }

    /// `["hoppin-cert-v1", phone, signingKey, agreementKey, issuedAt, expiresAt, serial]`
    var signedFields: [String] {
        ["hoppin-cert-v1",
         phone,
         signingKey,
         agreementKey,
         Canonical.field(issuedAt),
         Canonical.field(expiresAt),
         serial]
    }

    /// Valid iff `v == 1`, the signature verifies with the pinned server key,
    /// `issuedAt - 300 <= now < expiresAt`, and `phone` is E.164.
    func isValid(serverKey: Curve25519.Signing.PublicKey, now: Date = Date()) -> Bool {
        guard v == 1 else { return false }
        guard PhoneNumber.isValidE164(phone) else { return false }
        let t = Int64(now.timeIntervalSince1970)
        guard t >= issuedAt - 300, t < expiresAt else { return false }
        guard let sigData = Data(base64Encoded: sig), sigData.count == 64 else { return false }
        // Keys must be well-formed 32-byte raw keys.
        guard let sk = Data(base64Encoded: signingKey), sk.count == 32,
              let ak = Data(base64Encoded: agreementKey), ak.count == 32 else { return false }
        return serverKey.isValidSignature(sigData, for: Canonical.encode(signedFields))
    }

    /// Convenience overload taking the pinned server key as base64.
    func isValid(serverKeyBase64: String, now: Date = Date()) -> Bool {
        guard let raw = Data(base64Encoded: serverKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return isValid(serverKey: key, now: now)
    }

    /// True when less than 7 days of validity remain (clients should renew).
    var expiresSoon: Bool { expiresSoon(now: Date()) }

    func expiresSoon(now: Date) -> Bool {
        expiresAt - Int64(now.timeIntervalSince1970) < 7 * 86_400
    }

    /// Decodes the transport JSON form (any key order).
    static func decode(_ json: String) -> IdentityCertificate? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(IdentityCertificate.self, from: data)
    }

    /// Encodes to compact JSON for transport / storage.
    func encodedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// The signing key as a CryptoKit public key, if well-formed.
    var signingPublicKey: Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: signingKey) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// The agreement key as a CryptoKit public key, if well-formed.
    var agreementPublicKey: Curve25519.KeyAgreement.PublicKey? {
        guard let raw = Data(base64Encoded: agreementKey) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }
}
