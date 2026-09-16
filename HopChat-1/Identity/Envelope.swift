//
//  Envelope.swift
//  HopChat-1
//
//  End-to-end encrypted, relay-opaque envelope — Design Contract §4.
//  Lives in Identity/ (ownership map §8) because the crypto layer defines it.
//

import Foundation
import CryptoKit

nonisolated struct Envelope: Codable, Equatable, Hashable, Sendable {
    /// UUID string; also the message id.
    let id: String
    let senderPhone: String
    let recipientPhone: String
    /// Unix seconds.
    let timestamp: Int64
    /// Base64, sender's current agreement public key.
    let senderAgreementKey: String
    /// Base64, which of the recipient's agreement keys was used.
    let recipientAgreementKey: String
    /// Base64, per-message Curve25519 agreement public key.
    let ephemeralKey: String
    /// Base64 AES-GCM combined box (nonce | ciphertext | tag).
    let ciphertext: String
    /// Sender certificate, JSON.
    let senderCertificate: String
    /// Base64 Ed25519 signature by the sender's signing key over `signedFields`.
    let signature: String

    init(id: String,
         senderPhone: String,
         recipientPhone: String,
         timestamp: Int64,
         senderAgreementKey: String,
         recipientAgreementKey: String,
         ephemeralKey: String,
         ciphertext: String,
         senderCertificate: String,
         signature: String) {
        self.id = id
        self.senderPhone = senderPhone
        self.recipientPhone = recipientPhone
        self.timestamp = timestamp
        self.senderAgreementKey = senderAgreementKey
        self.recipientAgreementKey = recipientAgreementKey
        self.ephemeralKey = ephemeralKey
        self.ciphertext = ciphertext
        self.senderCertificate = senderCertificate
        self.signature = signature
    }

    /// `["hopchat-env-v2", id, senderPhone, recipientPhone, timestamp,
    ///   senderAgreementKey, recipientAgreementKey, ephemeralKey]`
    var header: [String] {
        Envelope.header(id: id,
                        senderPhone: senderPhone,
                        recipientPhone: recipientPhone,
                        timestamp: timestamp,
                        senderAgreementKey: senderAgreementKey,
                        recipientAgreementKey: recipientAgreementKey,
                        ephemeralKey: ephemeralKey)
    }

    /// `header + [ciphertext]` — the fields covered by `signature`.
    var signedFields: [String] { header + [ciphertext] }

    /// Lowercase hex SHA-256 over `Canonical(header + [ciphertext, signature])`.
    /// Used as the `envelope` binding in the wire-message signature (§3).
    var digestHex: String {
        let data = Canonical.encode(header + [ciphertext, signature])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds the canonical header field list without needing an `Envelope`
    /// instance (used while sealing, before the ciphertext exists).
    static func header(id: String,
                       senderPhone: String,
                       recipientPhone: String,
                       timestamp: Int64,
                       senderAgreementKey: String,
                       recipientAgreementKey: String,
                       ephemeralKey: String) -> [String] {
        ["hopchat-env-v2",
         id,
         senderPhone,
         recipientPhone,
         Canonical.field(timestamp),
         senderAgreementKey,
         recipientAgreementKey,
         ephemeralKey]
    }
}
