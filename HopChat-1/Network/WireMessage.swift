//
//  WireMessage.swift
//  HopChat-1
//
//  Design Contract §3 — v2 wire message, framing, signing and freshness.
//
//  Framing: 4-byte big-endian length + UTF-8 JSON, max frame 1 048 576 bytes.
//  Each TCP connection carries one request frame and at most one response.
//

import Foundation

// MARK: - Message types

nonisolated enum WireType: UInt8 {
    case ping                = 0x01
    case pong                = 0x02
    case directEnvelope      = 0x0B
    case directAck           = 0x0C
    case verifyStart         = 0x20
    case verifyStarted       = 0x21
    case verifyConfirm       = 0x22
    case certificateIssued   = 0x23
    case certRenew           = 0x24
    case certLookup          = 0x25
    case certResult          = 0x26
    case error               = 0x2F
    case relayDeposit        = 0x30
    case relayAccepted       = 0x31
    case relayFetch          = 0x32
    case relayBatch          = 0x33
    case relayAck            = 0x34
    case ok                  = 0x35
    case report              = 0x36
    case deleteAccount       = 0x37
    case changeNumberStart   = 0x38
    case changeNumberConfirm = 0x39
    case hello               = 0x40
}

// MARK: - Wire message

nonisolated struct WireMessage: Codable {

    var v: Int = 2
    var type: UInt8
    /// UUID string, unique per request. Responses reuse the request's txID.
    var txID: String
    /// `"server"` for server-originated messages.
    var senderPhone: String
    /// LAN listening port; 0 from the server or when not listening.
    var senderPort: UInt16
    /// Unix seconds.
    var timestamp: Int64
    /// Sender's certificate JSON. Required for every client→anyone message
    /// except `verifyStart` / `verifyConfirm`.
    var certificate: String?
    var recipientPhone: String?
    var key: String?
    var value: String?
    var envelope: Envelope?
    /// Base64 Ed25519 signature over `signedFields`.
    var signature: String

    init(type: WireType,
         txID: String = UUID().uuidString,
         senderPhone: String,
         senderPort: UInt16 = 0,
         timestamp: Int64 = Int64(Date().timeIntervalSince1970),
         certificate: String? = nil,
         recipientPhone: String? = nil,
         key: String? = nil,
         value: String? = nil,
         envelope: Envelope? = nil,
         signature: String = "") {
        self.v = 2
        self.type = type.rawValue
        self.txID = txID
        self.senderPhone = senderPhone
        self.senderPort = senderPort
        self.timestamp = timestamp
        self.certificate = certificate
        self.recipientPhone = recipientPhone
        self.key = key
        self.value = value
        self.envelope = envelope
        self.signature = signature
    }

    var wireType: WireType? { WireType(rawValue: type) }

    /// Contract §3 — the exact field list every signature covers.
    var signedFields: [String] {
        ["hopchat-wire-v2",
         String(type),
         txID,
         senderPhone,
         String(senderPort),
         String(timestamp),
         recipientPhone ?? "",
         key ?? "",
         value ?? "",
         envelope?.digestHex ?? ""]
    }

    // MARK: - Freshness

    static let freshnessWindow: Int64 = 300

    /// `false` when `|now - timestamp| > 300` (contract §3).
    func isFresh(now: Date = Date()) -> Bool {
        let n = Int64(now.timeIntervalSince1970)
        return abs(n - timestamp) <= WireMessage.freshnessWindow
    }

    // MARK: - Verification

    /// Verifies the signature against a base64 Ed25519 public key.
    func hasValidSignature(signingKeyBase64: String) -> Bool {
        CryptoManager.verify(signedFields,
                             signature: signature,
                             signingKeyBase64: signingKeyBase64)
    }

    // MARK: - Codable

    func encodedJSON() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> WireMessage? {
        guard let msg = try? JSONDecoder().decode(WireMessage.self, from: data),
              msg.v == 2 else { return nil }
        return msg
    }
}

// MARK: - Framing

nonisolated enum WireFrame {

    /// Contract §3 — maximum frame payload.
    static let maxFrameBytes = 1_048_576

    enum FrameError: Error, Equatable {
        case tooLarge(Int)
        case empty
    }

    /// Prefixes `payload` with its 4-byte big-endian length.
    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw FrameError.empty }
        guard payload.count <= maxFrameBytes else { throw FrameError.tooLarge(payload.count) }
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    /// Encodes and frames a wire message in one step.
    static func frame(_ message: WireMessage) throws -> Data {
        try frame(message.encodedJSON())
    }

    /// Parses a 4-byte big-endian length prefix, rejecting out-of-range values.
    static func parseLength(_ data: Data) -> Int? {
        guard data.count == 4 else { return nil }
        let length = Int(data.withUnsafeBytes { raw -> UInt32 in
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { dst in
                dst.copyBytes(from: raw.prefix(4))
            }
            return UInt32(bigEndian: value)
        })
        guard length > 0, length <= maxFrameBytes else { return nil }
        return length
    }
}
