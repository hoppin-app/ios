//
//  TrustStore.swift
//  HopChat-1
//
//  Per-contact key pinning (TOFU), key-change detection, agreement-key history,
//  and safety-number verification — Design Contract §2, §4, §7.
//
//  All state is JSON inside the secure store (Keychain) — never UserDefaults.
//

import Foundation
import Combine
import CryptoKit
import os

@MainActor
final class TrustStore: ObservableObject {

    static let shared = TrustStore(store: KeychainStore.shared)

    private enum Account {
        static let pins = "trust.pins.v2"
        static let all = [pins]
    }

    /// Previously pinned agreement keys stay acceptable for this long (§4 step 2).
    nonisolated static let agreementRetention: TimeInterval = 30 * 86_400

    /// Result of evaluating a contact's certificate.
    enum Evaluation: Equatable {
        case newContact
        case trusted
        case keyChanged(previousSigningKey: String)
        /// The secure store could not be read (device locked / keychain error).
        /// Callers must NOT treat this as a new contact, retry later.
        case unavailable
    }

    private struct AgreementSighting: Codable, Equatable {
        var key: String
        var seenAt: Int64
    }

    private struct Pin: Codable, Equatable {
        var signingKey: String
        var certificateJSON: String
        var issuedAt: Int64
        var pinnedAt: Int64
        var verified: Bool
        var agreementKeys: [AgreementSighting]
        /// A certificate presenting a *different* signing key, awaiting user review.
        var pendingCertificateJSON: String?
        var pendingSigningKey: String?
    }

    private let store: KeyValueSecureStore
    private var pins: [String: Pin] = [:]
    private var loaded = false

    /// Injectable clock (tests).
    var now: () -> Date = { Date() }

    /// Phones whose signing key changed and the user has not accepted yet.
    /// Sending to these contacts must be refused (`ServiceError.keyChangeUnacknowledged`).
    @Published private(set) var pendingKeyChanges: Set<String> = []

    init(store: KeyValueSecureStore) {
        self.store = store
        _ = ensureLoaded()
    }

    // MARK: - Persistence

    @discardableResult
    private func ensureLoaded() -> Bool {
        if loaded { return true }
        let raw: Data?
        do { raw = try store.data(for: Account.pins) }
        catch {
            Log.crypto.error("trust pins read failed: \(String(describing: error), privacy: .public)")
            return false
        }
        if let raw, let decoded = try? JSONDecoder().decode([String: Pin].self, from: raw) {
            pins = decoded
        } else {
            pins = [:]
        }
        loaded = true
        pendingKeyChanges = Set(pins.filter { $0.value.pendingCertificateJSON != nil }.keys)
        return true
    }

    private func save() {
        guard loaded else { return }
        guard let data = try? JSONEncoder().encode(pins) else { return }
        do { try store.set(data, for: Account.pins) }
        catch {
            Log.crypto.error("trust pins write failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Evaluation (TOFU)

    /// Pins the certificate's signing key on first sight; on a changed signing key
    /// records a pending change (which blocks sending) and reports it.
    /// A newer certificate carrying the **same** signing key (weekly agreement-key
    /// rotation) is accepted silently.
    @discardableResult
    func evaluate(_ cert: IdentityCertificate) -> Evaluation {
        guard ensureLoaded() else { return .unavailable }
        let ts = Int64(now().timeIntervalSince1970)

        guard var pin = pins[cert.phone] else {
            pins[cert.phone] = Pin(signingKey: cert.signingKey,
                                   certificateJSON: cert.encodedJSON(),
                                   issuedAt: cert.issuedAt,
                                   pinnedAt: ts,
                                   verified: false,
                                   agreementKeys: [AgreementSighting(key: cert.agreementKey, seenAt: ts)],
                                   pendingCertificateJSON: nil,
                                   pendingSigningKey: nil)
            save()
            Log.crypto.notice("pinned new contact \(PhoneNumber.masked(cert.phone), privacy: .private)")
            return .newContact
        }

        if pin.signingKey == cert.signingKey {
            if cert.issuedAt >= pin.issuedAt {
                pin.certificateJSON = cert.encodedJSON()
                pin.issuedAt = cert.issuedAt
            }
            record(&pin, agreementKey: cert.agreementKey, at: ts)
            pins[cert.phone] = pin
            save()
            return .trusted
        }

        // Different signing key → possible impersonation. Never auto-replace.
        let previous = pin.signingKey
        pin.pendingCertificateJSON = cert.encodedJSON()
        pin.pendingSigningKey = cert.signingKey
        pins[cert.phone] = pin
        pendingKeyChanges.insert(cert.phone)
        save()
        Log.crypto.error("signing key changed for \(PhoneNumber.masked(cert.phone), privacy: .private)")
        return .keyChanged(previousSigningKey: previous)
    }

    private func record(_ pin: inout Pin, agreementKey: String, at ts: Int64) {
        let cutoff = ts - Int64(Self.agreementRetention)
        pin.agreementKeys.removeAll { $0.seenAt < cutoff }
        if let idx = pin.agreementKeys.firstIndex(where: { $0.key == agreementKey }) {
            pin.agreementKeys[idx].seenAt = max(pin.agreementKeys[idx].seenAt, ts)
        } else {
            pin.agreementKeys.append(AgreementSighting(key: agreementKey, seenAt: ts))
        }
        // Bound growth (weekly rotation ⇒ ~5 within the window).
        if pin.agreementKeys.count > 16 {
            pin.agreementKeys.sort { $0.seenAt > $1.seenAt }
            pin.agreementKeys = Array(pin.agreementKeys.prefix(16))
        }
    }

    // MARK: - Pins

    func pinnedCertificate(for phone: String) -> IdentityCertificate? {
        guard ensureLoaded(), let pin = pins[phone] else { return nil }
        return IdentityCertificate.decode(pin.certificateJSON)
    }

    func pinnedSigningKey(for phone: String) -> String? {
        guard ensureLoaded() else { return nil }
        return pins[phone]?.signingKey
    }

    /// Accepts a newer certificate for an already-pinned contact. Ignored unless
    /// the signing key is unchanged (rotation of the agreement key only).
    func updatePinnedCertificate(_ cert: IdentityCertificate) {
        guard ensureLoaded(), var pin = pins[cert.phone], pin.signingKey == cert.signingKey else { return }
        let ts = Int64(now().timeIntervalSince1970)
        if cert.issuedAt >= pin.issuedAt {
            pin.certificateJSON = cert.encodedJSON()
            pin.issuedAt = cert.issuedAt
        }
        record(&pin, agreementKey: cert.agreementKey, at: ts)
        pins[cert.phone] = pin
        save()
    }

    /// §4 step 2: a sender's agreement key is acceptable when it is the one in the
    /// current certificate or one pinned within the last 30 days.
    func isRecentAgreementKey(_ key: String, for phone: String) -> Bool {
        guard ensureLoaded(), let pin = pins[phone] else { return false }
        let cutoff = Int64(now().timeIntervalSince1970) - Int64(Self.agreementRetention)
        return pin.agreementKeys.contains { $0.key == key && $0.seenAt >= cutoff }
    }

    /// True when the contact's key changed and the user has not accepted it.
    func hasPendingKeyChange(_ phone: String) -> Bool {
        pendingKeyChanges.contains(phone)
    }

    /// The certificate presenting the new key, for the safety-number UI.
    func pendingCertificate(for phone: String) -> IdentityCertificate? {
        guard ensureLoaded(), let json = pins[phone]?.pendingCertificateJSON else { return nil }
        return IdentityCertificate.decode(json)
    }

    /// User accepted the new key: re-pin it and clear verification.
    func acceptKeyChange(for phone: String) {
        guard ensureLoaded(), var pin = pins[phone],
              let json = pin.pendingCertificateJSON,
              let cert = IdentityCertificate.decode(json) else {
            pendingKeyChanges.remove(phone)
            return
        }
        let ts = Int64(now().timeIntervalSince1970)
        pin.signingKey = cert.signingKey
        pin.certificateJSON = json
        pin.issuedAt = cert.issuedAt
        pin.pinnedAt = ts
        pin.verified = false
        pin.agreementKeys = [AgreementSighting(key: cert.agreementKey, seenAt: ts)]
        pin.pendingCertificateJSON = nil
        pin.pendingSigningKey = nil
        pins[phone] = pin
        pendingKeyChanges.remove(phone)
        save()
        Log.crypto.notice("key change accepted for \(PhoneNumber.masked(phone), privacy: .private)")
    }

    /// User rejected the new key: keep the existing pin and drop the proposal.
    func rejectKeyChange(for phone: String) {
        guard ensureLoaded(), var pin = pins[phone] else { return }
        pin.pendingCertificateJSON = nil
        pin.pendingSigningKey = nil
        pins[phone] = pin
        pendingKeyChanges.remove(phone)
        save()
    }

    // MARK: - Manual verification

    func isVerified(_ phone: String) -> Bool {
        guard ensureLoaded() else { return false }
        return pins[phone]?.verified ?? false
    }

    func setVerified(_ phone: String, _ verified: Bool) {
        guard ensureLoaded(), var pin = pins[phone] else { return }
        pin.verified = verified
        pins[phone] = pin
        save()
    }

    /// Number change: carry the pin (same keys) over to the new phone.
    func migratePin(from oldPhone: String, to newPhone: String) {
        guard ensureLoaded(), let pin = pins.removeValue(forKey: oldPhone) else { return }
        pins[newPhone] = pin
        if pendingKeyChanges.remove(oldPhone) != nil {
            pendingKeyChanges.insert(newPhone)
        }
        save()
    }

    func removePin(for phone: String) {
        guard ensureLoaded() else { return }
        pins.removeValue(forKey: phone)
        pendingKeyChanges.remove(phone)
        save()
    }

    /// Deletes every trust item (delete account / reset).
    func wipe() {
        pins = [:]
        pendingKeyChanges = []
        loaded = true
        for account in Account.all {
            do { try store.delete(account) }
            catch { Log.crypto.error("trust wipe failed: \(String(describing: error), privacy: .public)") }
        }
    }

    // MARK: - Safety numbers (§7)

    /// 60-digit safety number for the pair. Symmetric: both sides compute the same
    /// string regardless of argument order.
    nonisolated static func safetyNumber(myPhone: String, myKey: String,
                                         theirPhone: String, theirKey: String) -> String {
        let a = fingerprint(phone: myPhone, key: myKey)
        let b = fingerprint(phone: theirPhone, key: theirKey)
        return a <= b ? a + b : b + a
    }

    /// One side's 30-digit fingerprint:
    /// `h = Canonical(["hoppin-safety-v1", phone, key])`, then 5200 × `h = SHA512(h || rawKey)`,
    /// first 30 bytes → 6 × (5-byte big-endian mod 100000, zero-padded to 5 digits).
    nonisolated static func fingerprint(phone: String, key: String) -> String {
        let rawKey = Data(base64Encoded: key) ?? Data(key.utf8)
        var h = Canonical.encode(["hoppin-safety-v1", phone, key])
        for _ in 0..<5200 {
            var input = h
            input.append(rawKey)
            h = Data(SHA512.hash(data: input))
        }
        let bytes = Array(h.prefix(30))
        var out = ""
        for chunk in 0..<6 {
            var value: UInt64 = 0
            for i in 0..<5 {
                value = (value << 8) | UInt64(bytes[chunk * 5 + i])
            }
            out += String(format: "%05u", UInt32(value % 100_000))
        }
        return out
    }

    /// Groups a 60-digit safety number into 12 groups of 5 for display.
    nonisolated static func formattedSafetyNumber(_ digits: String) -> String {
        let chars = Array(digits)
        var groups: [String] = []
        var i = 0
        while i < chars.count {
            let end = min(i + 5, chars.count)
            groups.append(String(chars[i..<end]))
            i = end
        }
        return groups.joined(separator: " ")
    }

    // MARK: - QR verification

    /// `"hoppin://verify?p=<phone>&k=<b64url>"`
    nonisolated static func qrString(phone: String, signingKey: String) -> String {
        "hoppin://verify?p=\(phone)&k=\(base64URL(signingKey))"
    }

    nonisolated static func parseQR(_ s: String) -> (phone: String, signingKey: String)? {
        guard let comps = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == "hoppin",
              (comps.host?.lowercased() == "verify" || comps.path == "verify"),
              let items = comps.queryItems else { return nil }
        guard let rawPhone = items.first(where: { $0.name == "p" })?.value,
              let rawKey = items.first(where: { $0.name == "k" })?.value else { return nil }
        guard PhoneNumber.isValidE164(rawPhone) else { return nil }
        guard let key = base64Standard(rawKey),
              let data = Data(base64Encoded: key), data.count == 32 else { return nil }
        return (rawPhone, key)
    }

    nonisolated static func base64URL(_ standard: String) -> String {
        standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func base64Standard(_ urlSafe: String) -> String? {
        var s = urlSafe
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return s
    }
}
