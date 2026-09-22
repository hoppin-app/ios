//
//  KeychainStore.swift
//  HopChat-1
//
//  Secure key-value storage — Design Contract §7 ("Identity").
//  All secrets (identity keys, certificates, trust pins) live here, never in UserDefaults.
//

import Foundation
import Security

/// Abstraction over the Keychain so tests (and non-device contexts) can inject
/// an in-memory or failing store.
///
/// `data(for:)` returns `nil` **only** when the item does not exist; any other
/// condition (device locked, interaction not allowed, …) throws. Callers must
/// never treat a thrown error as "no key" — see `CryptoError.keyUnavailable`.
nonisolated protocol KeyValueSecureStore: AnyObject, Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func delete(_ account: String) throws
    func deleteAll() throws
}

/// Errors surfaced by `KeychainStore`.
nonisolated struct KeychainError: Error, CustomStringConvertible, Equatable {
    let status: OSStatus
    let operation: String

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain \(operation) failed: \(status) (\(message))"
    }
}

/// Keychain-backed store.
///
/// Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the background
/// relay fetch can decrypt mail while the device is locked (after first unlock),
/// while the keys never leave the device and are never backed up.
nonisolated final class KeychainStore: KeyValueSecureStore, @unchecked Sendable {

    static let shared = KeychainStore()

    private let service: String

    init(service: String = "hoppin.v2") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func data(for account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            // Device locked, interaction not allowed, corrupted keychain, …
            // NEVER interpret this as "no key exists".
            throw KeychainError(status: status, operation: "read")
        }
    }

    func set(_ data: Data, for account: String) throws {
        // Update in place first; only add when genuinely missing.
        // (Delete-then-add can lose the item if the process is interrupted.)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus, operation: "update")
        }

        var addQuery = baseQuery(account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Raced with another writer; the update path now applies.
            let retry = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
            guard retry == errSecSuccess else {
                throw KeychainError(status: retry, operation: "update")
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus, operation: "add")
        }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "deleteAll")
        }
    }
}

/// In-memory store for tests and previews.
nonisolated final class InMemorySecureStore: KeyValueSecureStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    init() {}

    func data(for account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    func set(_ data: Data, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = data
    }

    func delete(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items.removeValue(forKey: account)
    }

    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}
