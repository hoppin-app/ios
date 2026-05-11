//
//  CryptoManager.swift
//  HopChat-1
//

import Foundation
import CryptoKit
import Security

final class CryptoManager {
    static let shared = CryptoManager()

    private let agreementKey: Curve25519.KeyAgreement.PrivateKey
    private let signingKey:   Curve25519.Signing.PrivateKey

    // Cached peer public keys: phone → key
    private var peerAgreementKeys: [String: Curve25519.KeyAgreement.PublicKey] = [:]
    private var peerSigningKeys:   [String: Curve25519.Signing.PublicKey]      = [:]

    // Own public keys for inclusion in messages (base64 encoded)
    var agreementPublicKeyBase64: String {
        agreementKey.publicKey.rawRepresentation.base64EncodedString()
    }
    var signingPublicKeyBase64: String {
        signingKey.publicKey.rawRepresentation.base64EncodedString()
    }

    private init() {
        agreementKey = CryptoManager.loadOrGenerateAgreementKey()
        signingKey   = CryptoManager.loadOrGenerateSigningKey()
    }

    // MARK: - Peer Key Registration

    func storePeerKeys(phone: String, agreementKeyBase64: String?, signingKeyBase64: String?) {
        if let b64 = agreementKeyBase64,
           let data = Data(base64Encoded: b64),
           let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data) {
            peerAgreementKeys[phone] = key
        }
        if let b64 = signingKeyBase64,
           let data = Data(base64Encoded: b64),
           let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) {
            peerSigningKeys[phone] = key
        }
    }

    func hasPeerKeys(for phone: String) -> Bool {
        peerAgreementKeys[phone] != nil
    }

    // MARK: - Encryption / Decryption

    /// Encrypt `message` for `phone`. Returns base64 AES-GCM ciphertext, or nil if no peer key.
    func encrypt(message: String, forPhone phone: String) -> String? {
        guard let peerKey  = peerAgreementKeys[phone],
              let shared   = try? agreementKey.sharedSecretFromKeyAgreement(with: peerKey),
              let msgData  = message.data(using: .utf8),
              let sealed   = try? AES.GCM.seal(msgData, using: derivedKey(from: shared))
        else { return nil }
        return sealed.combined?.base64EncodedString()
    }

    /// Decrypt base64 ciphertext from `phone`. Returns plaintext, or nil on failure.
    func decrypt(ciphertext: String, fromPhone phone: String) -> String? {
        guard let peerKey    = peerAgreementKeys[phone],
              let shared     = try? agreementKey.sharedSecretFromKeyAgreement(with: peerKey),
              let cipherData = Data(base64Encoded: ciphertext),
              let box        = try? AES.GCM.SealedBox(combined: cipherData),
              let plainData  = try? AES.GCM.open(box, using: derivedKey(from: shared))
        else { return nil }
        return String(data: plainData, encoding: .utf8)
    }

    // MARK: - Signing / Verification

    /// Sign a canonical payload string. Returns base64 signature.
    func sign(payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let sig  = try? signingKey.signature(for: data)
        else { return nil }
        return sig.base64EncodedString()
    }

    /// Verify a base64 signature on `payload` from `phone`.
    func verify(payload: String, signature: String, fromPhone phone: String) -> Bool {
        guard let peerKey     = peerSigningKeys[phone],
              let payloadData = payload.data(using: .utf8),
              let sigData     = Data(base64Encoded: signature)
        else { return false }
        return peerKey.isValidSignature(sigData, for: payloadData)
    }

    // MARK: - Key Derivation

    private func derivedKey(from secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("HopChat-E2E-v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    // MARK: - Keychain persistence

    private static func loadOrGenerateAgreementKey() -> Curve25519.KeyAgreement.PrivateKey {
        let tag = "hopchat.agreementKey.v1"
        if let data = keychainLoad(tag: tag),
           let key  = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        keychainSave(key.rawRepresentation, tag: tag)
        return key
    }

    private static func loadOrGenerateSigningKey() -> Curve25519.Signing.PrivateKey {
        let tag = "hopchat.signingKey.v1"
        if let data = keychainLoad(tag: tag),
           let key  = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        keychainSave(key.rawRepresentation, tag: tag)
        return key
    }

    private static func keychainLoad(tag: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "HopChat.CryptoKeys",
            kSecAttrAccount as String: tag,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func keychainSave(_ data: Data, tag: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "HopChat.CryptoKeys",
            kSecAttrAccount as String: tag,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}

// MARK: - Canonical signing payload

extension CryptoManager {
    /// Canonical string to sign for a KadMessage: txID|senderPhone|chatBody
    static func signingPayload(txID: String, senderPhone: String, chatBody: String?) -> String {
        "\(txID)|\(senderPhone)|\(chatBody ?? "")"
    }
}
