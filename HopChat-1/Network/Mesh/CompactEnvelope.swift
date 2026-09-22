//
//  CompactEnvelope.swift
//  HopChat-1
//
//  Binary encoding of `Envelope` (and the certificate inside it) for the BLE
//  mesh. The JSON + base64 form is roughly twice the size, and over a link that
//  moves tens of kB/s that is the difference between a message arriving as
//  someone walks past and not arriving at all.
//
//  Layout (big-endian lengths, no padding):
//
//      "HCE2"                      4 B magic + version
//      id                         16 B raw UUID
//      timestamp                   8 B Int64
//      senderAgreementKey         32 B
//      recipientAgreementKey      32 B
//      ephemeralKey               32 B
//      signature                  64 B
//      senderPhone                1 B length + UTF-8
//      recipientPhone             1 B length + UTF-8
//      certificate                2 B length + compact certificate
//      ciphertext                 2 B length + bytes
//
//  The certificate is:
//
//      v                           1 B
//      signingKey                 32 B
//      agreementKey               32 B
//      issuedAt / expiresAt     2× 8 B
//      sig                        64 B
//      phone                       1 B length + UTF-8
//      serial                      1 B length + UTF-8
//
//  Decoding is strict: anything unexpected returns nil rather than a partly
//  filled value. Mesh input comes from strangers, so it is never trusted.
//

import Foundation

nonisolated enum CompactEnvelope {

    static let magic = Data("HCE2".utf8)

    /// Same limit the relay applies to an envelope (contract §4), which also
    /// caps what a mesh packet can carry.
    static let maxEncodedBytes = 64 * 1024

    // MARK: - Encode

    static func encode(_ envelope: Envelope) -> Data? {
        guard let id = uuidBytes(envelope.id),
              let senderAgreement = key32(envelope.senderAgreementKey),
              let recipientAgreement = key32(envelope.recipientAgreementKey),
              let ephemeral = key32(envelope.ephemeralKey),
              let signature = fixed(envelope.signature, 64),
              let certificate = IdentityCertificate.decode(envelope.senderCertificate),
              let certificateData = encodeCertificate(certificate),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let senderPhone = shortString(envelope.senderPhone),
              let recipientPhone = shortString(envelope.recipientPhone),
              certificateData.count <= 0xFFFF,
              ciphertext.count <= 0xFFFF else { return nil }

        var out = Data()
        out.append(magic)
        out.append(id)
        out.append(int64(envelope.timestamp))
        out.append(senderAgreement)
        out.append(recipientAgreement)
        out.append(ephemeral)
        out.append(signature)
        out.append(senderPhone)
        out.append(recipientPhone)
        out.append(uint16(certificateData.count))
        out.append(certificateData)
        out.append(uint16(ciphertext.count))
        out.append(ciphertext)
        return out.count <= maxEncodedBytes ? out : nil
    }

    private static func encodeCertificate(_ cert: IdentityCertificate) -> Data? {
        guard cert.v >= 0, cert.v <= 0xFF,
              let signingKey = key32(cert.signingKey),
              let agreementKey = key32(cert.agreementKey),
              let sig = fixed(cert.sig, 64),
              let phone = shortString(cert.phone),
              let serial = shortString(cert.serial) else { return nil }

        var out = Data([UInt8(cert.v)])
        out.append(signingKey)
        out.append(agreementKey)
        out.append(int64(cert.issuedAt))
        out.append(int64(cert.expiresAt))
        out.append(sig)
        out.append(phone)
        out.append(serial)
        return out
    }

    // MARK: - Decode

    static func decode(_ data: Data) -> Envelope? {
        guard data.count <= maxEncodedBytes else { return nil }
        var reader = Reader(data)
        guard reader.take(4) == magic,
              let id = reader.take(16).map(uuidString),
              let timestamp = reader.int64(),
              let senderAgreement = reader.take(32),
              let recipientAgreement = reader.take(32),
              let ephemeral = reader.take(32),
              let signature = reader.take(64),
              let senderPhone = reader.shortString(),
              let recipientPhone = reader.shortString(),
              let certificateData = reader.blob16(),
              let certificate = decodeCertificate(certificateData),
              let ciphertext = reader.blob16(),
              reader.isAtEnd else { return nil }

        return Envelope(id: id,
                        senderPhone: senderPhone,
                        recipientPhone: recipientPhone,
                        timestamp: timestamp,
                        senderAgreementKey: senderAgreement.base64EncodedString(),
                        recipientAgreementKey: recipientAgreement.base64EncodedString(),
                        ephemeralKey: ephemeral.base64EncodedString(),
                        ciphertext: ciphertext.base64EncodedString(),
                        senderCertificate: certificate.encodedJSON(),
                        signature: signature.base64EncodedString())
    }

    private static func decodeCertificate(_ data: Data) -> IdentityCertificate? {
        var reader = Reader(data)
        guard let v = reader.byte(),
              let signingKey = reader.take(32),
              let agreementKey = reader.take(32),
              let issuedAt = reader.int64(),
              let expiresAt = reader.int64(),
              let sig = reader.take(64),
              let phone = reader.shortString(),
              let serial = reader.shortString(),
              reader.isAtEnd else { return nil }

        return IdentityCertificate(v: Int(v),
                                   phone: phone,
                                   signingKey: signingKey.base64EncodedString(),
                                   agreementKey: agreementKey.base64EncodedString(),
                                   issuedAt: issuedAt,
                                   expiresAt: expiresAt,
                                   serial: serial,
                                   sig: sig.base64EncodedString())
    }

    // MARK: - Primitives

    private static func uuidBytes(_ string: String) -> Data? {
        guard let uuid = UUID(uuidString: string) else { return nil }
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    private static func uuidString(_ data: Data) -> String {
        let bytes = [UInt8](data)
        let uuid = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: uuid).uuidString
    }

    private static func key32(_ base64: String) -> Data? { fixed(base64, 32) }

    private static func fixed(_ base64: String, _ count: Int) -> Data? {
        guard let data = Data(base64Encoded: base64), data.count == count else { return nil }
        return data
    }

    /// 1-byte length + UTF-8 (phone numbers, serials).
    private static func shortString(_ string: String) -> Data? {
        let utf8 = Data(string.utf8)
        guard utf8.count <= 0xFF else { return nil }
        return Data([UInt8(utf8.count)]) + utf8
    }

    private static func int64(_ value: Int64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func uint16(_ value: Int) -> Data {
        withUnsafeBytes(of: UInt16(value).bigEndian) { Data($0) }
    }

    /// Bounds-checked sequential reader.
    private struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = 0
        }

        var isAtEnd: Bool { offset == data.count }

        mutating func take(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: count)
            offset += count
            return Data(data[start..<end])
        }

        mutating func byte() -> UInt8? {
            take(1)?.first
        }

        mutating func int64() -> Int64? {
            guard let raw = take(8) else { return nil }
            return raw.withUnsafeBytes { Int64(bigEndian: $0.loadUnaligned(as: Int64.self)) }
        }

        mutating func uint16() -> Int? {
            guard let raw = take(2) else { return nil }
            return Int(raw.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self)) })
        }

        mutating func shortString() -> String? {
            guard let length = byte(), let raw = take(Int(length)) else { return nil }
            return String(data: raw, encoding: .utf8)
        }

        mutating func blob16() -> Data? {
            guard let length = uint16() else { return nil }
            return take(length)
        }
    }
}
