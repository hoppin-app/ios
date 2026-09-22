//
//  TestSupport.swift
//  HopChat-1Tests
//
//  Shared helpers: cross-language fixtures, fake secure stores, temp
//  directories, fixed clocks and the integration-server handshake file.
//
//  Nothing here talks to the network. `ServerInfo` only *reads* the JSON that
//  `scripts/run_tests.sh` writes; when it is absent the integration suite skips.
//

import Foundation
import Testing
@testable import HopChat_1

// MARK: - Repository paths

/// Locates files inside the checkout. The simulator shares the host
/// filesystem, so the compile-time source path is a reliable anchor.
enum RepoPaths {

    /// Directory containing this source file.
    static let testSourceDirectory: URL =
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    /// The checkout root: the first ancestor holding `docs/fixtures`.
    static let root: URL = {
        var dir = testSourceDirectory
        for _ in 0..<8 {
            let marker = dir.appendingPathComponent("docs/fixtures/crypto_vectors.json")
            if FileManager.default.fileExists(atPath: marker.path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        // Fall back to the parent of HopChat-1Tests/.
        return testSourceDirectory.deletingLastPathComponent()
    }()

    static var fixturesURL: URL {
        if let override = ProcessInfo.processInfo.environment["HOPPIN_FIXTURES"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return root.appendingPathComponent("docs/fixtures/crypto_vectors.json")
    }

    /// Handshake file written by `scripts/run_tests.sh`.
    static var serverInfoURL: URL {
        if let override = ProcessInfo.processInfo.environment["HOPPIN_TEST_SERVER"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: "/tmp/hoppin-test-server.json")
    }
}

// MARK: - Cross-language fixtures (docs/fixtures/crypto_vectors.json)

struct CryptoVectors: Decodable {

    struct Party: Decodable {
        let agreementKeyBase64: String
        let agreementPrivateBase64: String
        let phone: String
        let signingKeyBase64: String
        let signingSeedBase64: String
    }

    struct CanonicalCase: Decodable {
        let byteLength: Int
        let fields: [String]
        let hex: String
    }

    struct CertificateCase: Decodable {
        let certificate: IdentityCertificate
        let json: String
        let signedFieldsHex: String?
        let valid: Bool
    }

    struct EnvelopeCase: Decodable {
        let derivedKeyHex: String
        let digestHex: String
        let envelope: Envelope
        let ephemeralPrivateBase64: String
        let header: [String]
        let headerCanonicalHex: String
        let hkdfSalt: String
        let nonceHex: String
        let plaintextHex: String
        let plaintextJSON: String
        let signedFieldsHex: String
    }

    struct PhoneCase: Decodable {
        let expected: String?
        let raw: String
        let region: String?
    }

    struct SafetyNumberCase: Decodable {
        let algorithm: String
        let aliceHalf: String
        let bobHalf: String
        let expected: String
        let iterations: Int
    }

    struct ServerKeys: Decodable {
        let publicKeyBase64: String
        let seedBase64: String
    }

    struct WireCase: Decodable {
        let message: WireMessage
        let signature: String
        let signedFields: [String]
        let signedFieldsHex: String
    }

    let alice: Party
    let bob: Party
    let canonical: [CanonicalCase]
    let certificates: [String: CertificateCase]
    let envelope: EnvelopeCase
    let phones: [PhoneCase]
    let safetyNumber: SafetyNumberCase
    let server: ServerKeys
    let version: Int
    let wire: WireCase
}

enum Fixtures {

    /// Loaded once per process; `nil` when the fixture file is missing.
    static let vectors: CryptoVectors? = {
        guard let data = try? Data(contentsOf: RepoPaths.fixturesURL) else { return nil }
        return try? JSONDecoder().decode(CryptoVectors.self, from: data)
    }()

    /// The fixture certificates use `issuedAt` 1700000000 and the wire/envelope
    /// messages fixed timestamps, so every validity check runs against a fixed
    /// reference date rather than the wall clock.
    static let referenceDate = Date(timeIntervalSince1970: 1_790_000_600)

    static func require() throws -> CryptoVectors {
        try #require(vectors,
                     "docs/fixtures/crypto_vectors.json is missing or unreadable — run server/make_vectors.py")
    }
}

// MARK: - Hex helpers

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        var out = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            guard let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex),
                  let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}

// MARK: - Secure stores

/// A secure store that fails every operation, standing in for a locked device.
///
/// The v1 bug this guards against: a throwing Keychain was treated as "no key",
/// so the app generated a brand-new identity and orphaned every existing chat.
final class ThrowingSecureStore: KeyValueSecureStore, @unchecked Sendable {

    struct Failure: Error, Equatable { let operation: String }

    private let lock = NSLock()
    private var _isAvailable = false
    private let backing = InMemorySecureStore()

    /// Reads and writes succeed again once this flips to `true`.
    var isAvailable: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isAvailable }
        set { lock.lock(); _isAvailable = newValue; lock.unlock() }
    }

    init(isAvailable: Bool = false) {
        self._isAvailable = isAvailable
    }

    func data(for account: String) throws -> Data? {
        guard isAvailable else { throw Failure(operation: "read") }
        return try backing.data(for: account)
    }

    func set(_ data: Data, for account: String) throws {
        guard isAvailable else { throw Failure(operation: "write") }
        try backing.set(data, for: account)
    }

    func delete(_ account: String) throws {
        guard isAvailable else { throw Failure(operation: "delete") }
        try backing.delete(account)
    }

    func deleteAll() throws {
        guard isAvailable else { throw Failure(operation: "deleteAll") }
        try backing.deleteAll()
    }
}

/// An in-memory store whose contents can be handed to a second instance, so a
/// test can simulate "same device, fresh process".
final class SharedMemoryStore: KeyValueSecureStore, @unchecked Sendable {

    private let lock = NSLock()
    private var items: [String: Data]

    init(items: [String: Data] = [:]) { self.items = items }

    var snapshot: [String: Data] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func data(for account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    func set(_ data: Data, for account: String) throws {
        lock.lock(); items[account] = data; lock.unlock()
    }

    func delete(_ account: String) throws {
        lock.lock(); items.removeValue(forKey: account); lock.unlock()
    }

    func deleteAll() throws {
        lock.lock(); items.removeAll(); lock.unlock()
    }
}

// MARK: - Temporary directories

/// A scratch directory removed when the test releases it.
final class TempDirectory: @unchecked Sendable {

    let url: URL

    init(_ name: String = "hoppin-tests") {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A private `UserDefaults` suite for legacy-migration tests.
final class TempDefaults: @unchecked Sendable {

    let name: String
    let defaults: UserDefaults

    init() {
        name = "hoppin.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name) ?? .standard
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

// MARK: - Fixed clocks

enum TestClock {
    /// A `@Sendable` clock pinned to one instant.
    static func fixed(_ date: Date) -> @Sendable () -> Date { { date } }

    /// A clock the test can move.
    final class Movable: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date

        init(_ start: Date = Date()) { _now = start }

        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return _now }
            set { lock.lock(); _now = newValue; lock.unlock() }
        }

        func advance(by interval: TimeInterval) {
            lock.lock(); _now = _now.addingTimeInterval(interval); lock.unlock()
        }

        var closure: @Sendable () -> Date { { [self] in now } }
    }
}

// MARK: - Integration server handshake

/// Written by `scripts/run_tests.sh` before it launches `xcodebuild test`.
struct ServerInfo: Decodable, Sendable {
    let host: String
    let port: UInt16
    let serverKey: String
    let fixedCode: String

    /// `nil` when no development server is running — the integration suite then
    /// skips instead of failing.
    static let current: ServerInfo? = {
        guard let data = try? Data(contentsOf: RepoPaths.serverInfoURL) else { return nil }
        guard let info = try? JSONDecoder().decode(ServerInfo.self, from: data) else { return nil }
        guard !info.serverKey.isEmpty,
              Data(base64Encoded: info.serverKey)?.count == 32 else { return nil }
        return info
    }()

    static let skipComment: Comment = """
        No development bootstrap server: run `scripts/run_tests.sh` to start one \
        (it writes /tmp/hoppin-test-server.json). Skipping the integration suite.
        """
}

// MARK: - Polling

/// Polls `condition` until it holds or the deadline passes.
/// Returns `true` when the condition was met.
@discardableResult
func waitUntil(timeout: TimeInterval = 10,
               interval: TimeInterval = 0.1,
               _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    return await condition()
}
