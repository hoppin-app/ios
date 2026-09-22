//
//  MeshPacket.swift
//  HopChat-1
//
//  What travels over the BLE mesh. A packet is carried by strangers' phones,
//  so nothing outside the header may say anything about who is talking to whom.
//
//      header (plain, 28 B)
//        "HM"        2 B  magic
//        version     1 B
//        type        1 B  envelope | have | want
//        flags       1 B  reserved (0)
//        ttl         1 B  hops remaining (1…maxTTL; 0 never decodes)
//        hint        1 B  cheap "might be mine" filter (see below)
//        reserved    1 B
//        packetID   16 B  random; identifies the packet for de-duplication
//        expiresAt   4 B  UInt32 unix seconds (dropped after this)
//
//      body (sealed, anonymous)
//        ephemeral  32 B  X25519 public key, fresh per packet
//        box         …    AES-GCM(padded CompactEnvelope), header as AAD
//
//  Finding your own mail: there is deliberately no recipient field. A phone
//  *tries to open* each packet with its own agreement keys (`CryptoManager`
//  `openMesh`). `hint` is one byte derived from the recipient's agreement key
//  and the packet's day, so a phone skips ~255 of every 256 packets without a
//  key operation — while telling an observer nothing, since a hint matches one
//  in 256 of *all* phones and changes daily.
//
//  `packetID` is random and unrelated to the envelope id: two carriers must not
//  be able to tell that two packets carry the same message.
//

import Foundation
import CryptoKit

nonisolated struct MeshPacket: Equatable, Sendable {

    enum Kind: UInt8, Sendable {
        /// A sealed envelope for someone.
        case envelope = 1
        /// "I am carrying these packet ids" (sent on connect).
        case have = 2
        /// "Send me these packet ids".
        case want = 3
    }

    static let magic = Data("HM".utf8)
    static let version: UInt8 = 1
    static let headerSize = 28
    static let idSize = 16

    /// Fresh per packet; only used for de-duplication.
    let packetID: Data
    let kind: Kind
    /// Hops remaining. Forwarders decrement; 0 is not forwarded.
    var ttl: UInt8
    let hint: UInt8
    /// Unix seconds; a packet is dropped everywhere after this.
    let expiresAt: UInt32
    /// Sealed body (envelope packets) or a plain id list (have/want).
    let body: Data

    static let defaultTTL: UInt8 = 7
    static let maxTTL: UInt8 = 10
    /// Longest a packet may live in the mesh.
    static let maxLifetime: TimeInterval = 24 * 3600
    /// Biggest packet a link will accept.
    static let maxBodyBytes = 16 * 1024

    // MARK: - Wire format

    func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + body.count)
        out.append(Self.magic)
        out.append(Self.version)
        out.append(kind.rawValue)
        out.append(0)               // flags
        out.append(ttl)
        out.append(hint)
        out.append(0)               // reserved
        out.append(packetID)
        out.append(withUnsafeBytes(of: expiresAt.bigEndian) { Data($0) })
        out.append(body)
        return out
    }

    static func decode(_ data: Data) -> MeshPacket? {
        guard data.count >= headerSize, data.count <= headerSize + maxBodyBytes else { return nil }
        // Slice-based: mesh input is attacker-controlled, so don't copy a whole
        // 16 KiB frame into an array just to read seven header bytes.
        let start = data.startIndex
        func byte(_ offset: Int) -> UInt8 { data[start + offset] }

        guard byte(0) == magic[magic.startIndex], byte(1) == magic[magic.startIndex + 1],
              byte(2) == version,
              let kind = Kind(rawValue: byte(3)) else { return nil }
        // Unknown flag bits are ignored rather than rejected: a later version
        // may set one, and this build should still carry those packets.
        let ttl = byte(5)
        guard ttl > 0, ttl <= maxTTL else { return nil }
        let hint = byte(6)
        let packetID = Data(data[(start + 8)..<(start + 8 + idSize)])
        var expiresAt: UInt32 = 0
        for offset in (8 + idSize)..<(8 + idSize + 4) {
            expiresAt = (expiresAt << 8) | UInt32(byte(offset))
        }
        let body = Data(data[(start + headerSize)...])
        return MeshPacket(packetID: packetID, kind: kind, ttl: ttl,
                          hint: hint, expiresAt: expiresAt, body: body)
    }

    /// The plain header, which is also the sealed body's authenticated data:
    /// a carrier cannot re-target or re-date a packet without breaking it.
    /// `ttl` is excluded — forwarders legitimately change it.
    var authenticatedHeader: Data {
        var out = Data()
        out.append(Self.magic)
        out.append(Self.version)
        out.append(kind.rawValue)
        out.append(hint)
        out.append(packetID)
        out.append(withUnsafeBytes(of: expiresAt.bigEndian) { Data($0) })
        return out
    }

    // MARK: - Helpers

    /// Always takes the caller's clock: router, link layer and tests must agree
    /// on expiry, and a device's clock may be skewed.
    func isExpired(at now: Date) -> Bool {
        Double(expiresAt) <= now.timeIntervalSince1970
    }

    /// A copy with one hop spent, or nil when it must not travel further.
    func forwarded(at now: Date) -> MeshPacket? {
        guard ttl > 1, !isExpired(at: now) else { return nil }
        var copy = self
        copy.ttl = ttl - 1
        return copy
    }

    static func randomID() -> Data {
        var bytes = [UInt8](repeating: 0, count: idSize)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}

// MARK: - Hint

nonisolated enum MeshHint {

    /// One byte from the recipient's agreement key and the packet's day.
    /// Anyone can compute it for a public key — that is the point: it filters
    /// work without naming anyone, and 1 in 256 packets matches by chance.
    static func value(agreementKeyBase64: String, at date: Date) -> UInt8 {
        var input = Data("hoppin-mesh-hint-v1".utf8)
        input.append(Data(agreementKeyBase64.utf8))
        input.append(withUnsafeBytes(of: dayIndex(date).bigEndian) { Data($0) })
        return Array(SHA256.hash(data: input))[0]
    }

    /// Whole days since the epoch; the hint changes daily.
    static func dayIndex(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 / 86_400)
    }

    /// The hints a phone should accept for a packet: the packet's own day plus
    /// the neighbouring days, so clock skew near midnight doesn't lose mail.
    static func candidates(agreementKeyBase64: String, at date: Date) -> Set<UInt8> {
        Set([-1, 0, 1].map {
            value(agreementKeyBase64: agreementKeyBase64,
                  at: date.addingTimeInterval(Double($0) * 86_400))
        })
    }
}

// MARK: - Padding

nonisolated enum MeshPadding {

    /// Buckets, in bytes. Every sealed body is padded up to the next one so a
    /// carrier cannot tell a short message from a long one.
    static let buckets = [512, 1024, 2048, 4096, 8192, 15 * 1024]

    /// `[UInt16 length][payload][zeros]`
    static func pad(_ payload: Data) -> Data? {
        guard payload.count <= 0xFFFF else { return nil }
        let needed = payload.count + 2
        guard let bucket = buckets.first(where: { $0 >= needed }) else { return nil }
        var out = withUnsafeBytes(of: UInt16(payload.count).bigEndian) { Data($0) }
        out.append(payload)
        out.append(Data(repeating: 0, count: bucket - needed))
        return out
    }

    static func unpad(_ padded: Data) -> Data? {
        guard padded.count >= 2 else { return nil }
        let bytes = [UInt8](padded)
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard 2 + length <= padded.count else { return nil }
        return Data(bytes[2..<(2 + length)])
    }
}
