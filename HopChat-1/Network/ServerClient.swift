//
//  ServerClient.swift
//  HopChat-1
//
//  Typed client for the bootstrap/relay server (contract §3 message types,
//  §5 server policy).
//
//  Every reply is checked before it is believed: matching txID, sender
//  `"server"` and a valid signature by the **pinned** server Ed25519 key. An
//  unsigned or mis-signed reply is a hard failure. Its timestamp is not held to
//  the device clock (the signed txID already proves it current); it sets
//  `ServerClock` instead, so requests are stamped in the relay's time.
//

import Foundation
import os

enum ServerError: Error, Equatable, LocalizedError {
    case transport(String)
    case timeout
    /// This device has no network path at all.
    case offline
    /// The relay's host answered, but nothing is listening: the server is down.
    case refused
    /// TLS failed: the certificate matched none of the pins.
    case untrustedServer
    /// This build has no usable host, port or signing key to talk to.
    case notConfigured
    case badResponse
    case badServerSignature
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .transport(let detail): return String(localized: "Network error: \(detail)")
        case .timeout: return String(localized: "The server did not respond.")
        case .offline: return String(localized: "This device is offline.")
        case .refused: return String(localized: "The server isn't accepting connections.")
        case .untrustedServer: return String(localized: "The server's certificate didn't match.")
        case .notConfigured: return String(localized: "No server is configured.")
        case .badResponse: return String(localized: "The server sent an unexpected response.")
        case .badServerSignature: return String(localized: "The server's response could not be verified.")
        case .server(let code, let message): return message.isEmpty ? code : message
        }
    }
}

extension ServerError {
    init(_ failure: Transport.Failure) {
        switch failure {
        case .badRequest: self = .notConfigured
        case .offline: self = .offline
        case .refused: self = .refused
        case .untrusted: self = .untrustedServer
        case .unreachable, .noReply: self = .timeout
        }
    }
}

final class ServerClient {

    private let crypto: CryptoManager
    let host: String
    let port: UInt16
    let useTLS: Bool
    let pins: [String]
    let serverKeyBase64: String

    init(crypto: CryptoManager,
         host: String = AppConfig.serverHost,
         port: UInt16,
         useTLS: Bool,
         pins: [String],
         serverKeyBase64: String) {
        self.crypto = crypto
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.pins = pins
        self.serverKeyBase64 = serverKeyBase64
    }

    /// Convenience factory wired to `AppConfig`.
    static func makeDefault(crypto: CryptoManager) -> ServerClient {
        ServerClient(crypto: crypto,
                     host: AppConfig.serverHost,
                     port: AppConfig.serverPort,
                     useTLS: !AppConfig.usePlaintextTransport,
                     pins: AppConfig.serverSPKISHA256Base64,
                     serverKeyBase64: AppConfig.serverSigningKeyBase64)
    }

    // MARK: - Verification / certificates

    /// Requests an SMS code. Returns `retryAfter` in seconds.
    /// Sent without a certificate and signed with the prospective signing key.
    func verifyStart(phone: String) async throws -> Int {
        var message = WireMessage(type: .verifyStart, senderPhone: phone, key: phone)
        sign(&message, withCertificate: false)
        let reply = try await send(message, expecting: .verifyStarted)
        return Int(reply.value ?? "") ?? 60
    }

    func verifyConfirm(phone: String, code: String) async throws -> IdentityCertificate {
        let body: [String: String] = [
            "code": code,
            "signingKey": crypto.signingPublicKeyBase64,
            "agreementKey": crypto.agreementPublicKeyBase64,
        ]
        var message = WireMessage(type: .verifyConfirm,
                                  senderPhone: phone,
                                  key: phone,
                                  value: try json(body))
        sign(&message, withCertificate: false)
        let reply = try await send(message, expecting: .certificateIssued)
        return try certificate(from: reply.value)
    }

    func renewCertificate(agreementKey: String) async throws -> IdentityCertificate {
        var message = WireMessage(type: .certRenew,
                                  senderPhone: try myPhone(),
                                  value: try json(["agreementKey": agreementKey]))
        sign(&message)
        let reply = try await send(message, expecting: .certificateIssued)
        return try certificate(from: reply.value)
    }

    /// `nil` when the phone is not registered with hoppin.
    func lookupCertificate(phone: String) async throws -> IdentityCertificate? {
        var message = WireMessage(type: .certLookup, senderPhone: try myPhone(), key: phone)
        sign(&message)
        let reply = try await send(message, expecting: .certResult)
        guard let value = reply.value, !value.isEmpty else { return nil }
        return try certificate(from: value)
    }

    // MARK: - Relay

    /// `notify` asks the relay to wake the recipient with a push. Only a
    /// message or a photo should: a receipt or a profile update that rang
    /// their phone would read as a "New message" with nothing new in it.
    func deposit(_ envelope: Envelope, notify: Bool = true) async throws {
        var message = WireMessage(type: .relayDeposit,
                                  senderPhone: try myPhone(),
                                  recipientPhone: envelope.recipientPhone,
                                  value: try json(["notify": notify]),
                                  envelope: envelope)
        sign(&message)
        _ = try await send(message, expecting: .relayAccepted)
    }

    /// Long-poll fetch. The server holds the connection up to `wait` seconds.
    func fetch(wait: Int, max: Int) async throws -> [Envelope] {
        let wait = Swift.max(0, Swift.min(25, wait))
        let max = Swift.max(1, Swift.min(100, max))
        var message = WireMessage(type: .relayFetch,
                                  senderPhone: try myPhone(),
                                  value: try json(["wait": wait, "max": max]))
        sign(&message)
        // The transport deadline must outlive the server's hold.
        let reply = try await send(message,
                                   expecting: .relayBatch,
                                   timeout: TimeInterval(wait + 10))
        guard let value = reply.value, !value.isEmpty else { return [] }
        guard let envelopes = try? JSONDecoder().decode([Envelope].self, from: Data(value.utf8)) else {
            throw ServerError.badResponse
        }
        return envelopes
    }

    func ack(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        var message = WireMessage(type: .relayAck,
                                  senderPhone: try myPhone(),
                                  value: try json(ids))
        sign(&message)
        _ = try await send(message, expecting: .ok)
    }

    // MARK: - Account

    func report(reportedPhone: String,
                reason: String,
                evidence: [(id: String, timestamp: Int64, text: String)]) async throws {
        let items = evidence.prefix(20).map { item in
            ["id": item.id, "timestamp": String(item.timestamp), "text": item.text]
        }
        let body: [String: Any] = [
            "reportedPhone": reportedPhone,
            "reason": reason,
            "evidence": items.map { ["id": $0["id"]!,
                                     "timestamp": Int64($0["timestamp"]!) ?? 0,
                                     "text": $0["text"]!] as [String: Any] },
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var message = WireMessage(type: .report,
                                  senderPhone: try myPhone(),
                                  value: String(decoding: data, as: UTF8.self))
        sign(&message)
        _ = try await send(message, expecting: .ok)
    }

    /// Registers this install's APNs token with the relay, or clears it when
    /// `token` is empty. The relay stores it against the account so it can wake
    /// the phone for a deposited envelope; it never learns what the envelope
    /// says.
    func setPushToken(_ token: String, sandbox: Bool) async throws {
        var message = WireMessage(type: .pushToken,
                                  senderPhone: try myPhone(),
                                  key: token,
                                  value: try json(["sandbox": sandbox]))
        sign(&message)
        _ = try await send(message, expecting: .ok)
    }

    func deleteAccount() async throws {
        var message = WireMessage(type: .deleteAccount, senderPhone: try myPhone())
        sign(&message)
        _ = try await send(message, expecting: .ok)
    }

    func changeNumberStart(newPhone: String) async throws -> Int {
        var message = WireMessage(type: .changeNumberStart,
                                  senderPhone: try myPhone(),
                                  key: newPhone)
        sign(&message)
        let reply = try await send(message, expecting: .verifyStarted)
        return Int(reply.value ?? "") ?? 60
    }

    func changeNumberConfirm(newPhone: String, code: String) async throws -> IdentityCertificate {
        var message = WireMessage(type: .changeNumberConfirm,
                                  senderPhone: try myPhone(),
                                  value: try json(["newPhone": newPhone, "code": code]))
        sign(&message)
        let reply = try await send(message, expecting: .certificateIssued)
        return try certificate(from: reply.value)
    }

    // MARK: - Liveness

    @discardableResult
    func ping() async throws -> Bool {
        var message = WireMessage(type: .ping, senderPhone: try myPhone())
        sign(&message)
        _ = try await send(message, expecting: .pong, timeout: 8)
        return true
    }

    // MARK: - Plumbing

    private func myPhone() throws -> String {
        guard let phone = crypto.certificate?.phone else { throw ServerError.badResponse }
        return phone
    }

    /// Stamps in relay time (`ServerClock`), so a device whose clock is wrong
    /// still passes the relay's ±300 s freshness check.
    private func sign(_ message: inout WireMessage, withCertificate: Bool = true) {
        if withCertificate {
            message.certificate = crypto.certificate?.encodedJSON()
        }
        message.timestamp = ServerClock.timestamp()
        message.signature = crypto.sign(message.signedFields)
    }

    private func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func certificate(from value: String?) throws -> IdentityCertificate {
        guard let value, !value.isEmpty,
              let cert = IdentityCertificate.decode(value) else {
            throw ServerError.badResponse
        }
        return cert
    }

    /// Sends a signed request and validates the reply's identity before
    /// returning it.
    @discardableResult
    private func send(_ message: WireMessage,
                      expecting expected: WireType,
                      timeout: TimeInterval = Transport.defaultTimeout) async throws -> WireMessage {
        do {
            return try await sendOnce(message, expecting: expected, timeout: timeout)
        } catch ServerError.server(code: "stale", _) {
            // Our clock is off. The signed refusal carried the relay's time and
            // `ServerClock` has learned it: re-stamp, re-sign, try once more.
            var retry = message
            retry.txID = UUID().uuidString
            retry.timestamp = ServerClock.timestamp()
            retry.signature = crypto.sign(retry.signedFields)
            return try await sendOnce(retry, expecting: expected, timeout: timeout)
        }
    }

    private func sendOnce(_ message: WireMessage,
                          expecting expected: WireType,
                          timeout: TimeInterval) async throws -> WireMessage {

        // A missing key used to surface as "bad signature", and a port of 0 as
        // a timeout: both read as network trouble when the build was simply
        // not set up.
        guard AppConfig.isServerKeyConfigured || serverKeyBase64 != AppConfig.serverKeyPlaceholder,
              !host.isEmpty, port != 0 else {
            throw ServerError.notConfigured
        }

        let reply: WireMessage
        switch await Transport.requestResult(message, to: host, port: port, tls: useTLS,
                                             pins: pins, timeout: timeout) {
        case .success(let message):
            reply = message
        case .failure(let failure):
            throw ServerError(failure)
        }

        // Identity of the responder, before anything it says is acted on.
        guard reply.txID == message.txID, reply.senderPhone == "server" else {
            Log.net.error("Server reply identity mismatch")
            throw ServerError.badResponse
        }
        guard reply.hasValidSignature(signingKeyBase64: serverKeyBase64) else {
            Log.net.error("Server reply signature invalid, dropping")
            throw ServerError.badServerSignature
        }
        // No freshness check on the reply's timestamp: the relay signed the
        // txID this request just made up, so the reply is current whatever our
        // clock says. Checking it against the device clock is what turned the
        // relay's "stale" refusal into "unexpected reply" on a device whose
        // clock was wrong. Its timestamp is the relay's clock: learn from it.
        ServerClock.learn(serverTimestamp: reply.timestamp)

        if reply.wireType == .error {
            throw ServerError.server(code: reply.key ?? "internal", message: reply.value ?? "")
        }
        guard reply.wireType == expected else {
            Log.net.error("Server replied with type \(reply.type, privacy: .public), expected \(expected.rawValue, privacy: .public)")
            throw ServerError.badResponse
        }
        return reply
    }
}
