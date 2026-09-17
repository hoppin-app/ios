//
//  HopChat_1Tests.swift
//  HopChat-1Tests
//
//  Cross-language conformance: every assertion here is against
//  `docs/fixtures/crypto_vectors.json`, which `server/make_vectors.py`
//  generates from the Python implementation. If Swift and Python ever disagree
//  about a single byte, these fail.
//
//  The fixtures use fixed timestamps (certs issued 1700000000, expiring
//  4102444800; wire 1790000500; envelope 1790000600), so validity is always
//  checked against `Fixtures.referenceDate` rather than the wall clock.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

// MARK: - §1 Canonical encoding

@Suite("Fixtures — canonical encoding (§1)")
struct CanonicalFixtureTests {

    @Test("every canonical vector encodes byte-for-byte")
    func canonicalVectors() throws {
        let vectors = try Fixtures.require()
        #expect(!vectors.canonical.isEmpty)
        for testCase in vectors.canonical {
            let encoded = Canonical.encode(testCase.fields)
            #expect(encoded.hexString == testCase.hex,
                    "canonical mismatch for \(testCase.fields)")
            #expect(encoded.count == testCase.byteLength,
                    "length mismatch for \(testCase.fields)")
        }
    }

    @Test("contract example: [ab, \"\", é] → 2:ab0:2:é")
    func contractExample() {
        #expect(Canonical.encode(["ab", "", "é"]) == Data("2:ab0:2:é".utf8))
    }

    @Test("empty list encodes to no bytes")
    func emptyList() {
        #expect(Canonical.encode([]).isEmpty)
    }

    @Test("length prefixes are UTF-8 byte counts, not character counts")
    func multibyteLengths() {
        #expect(Canonical.encode(["é"]) == Data([0x32, 0x3A, 0xC3, 0xA9]))
        #expect(Canonical.encode(["👍"]) == Data([0x34, 0x3A, 0xF0, 0x9F, 0x91, 0x8D]))
        // A family emoji is one grapheme but 25 UTF-8 bytes.
        #expect(Canonical.encode(["👨‍👩‍👧‍👦"]).prefix(3) == Data("25:".utf8))
    }

    @Test("a colon inside a field cannot forge another field")
    func injectionIsUnambiguous() {
        #expect(Canonical.encode(["a:b", "c"]) != Canonical.encode(["a", "b:c"]))
        #expect(Canonical.encode(["3:c"]) != Canonical.encode(["3", "c"]))
    }

    @Test("field helpers render integers and booleans per contract")
    func fieldHelpers() {
        #expect(Canonical.field(Int64(0)) == "0")
        #expect(Canonical.field(Int64(1_790_000_000)) == "1790000000")
        #expect(Canonical.field(UInt16(0)) == "0")
        #expect(Canonical.field(true) == "1")
        #expect(Canonical.field(false) == "0")
        #expect(Canonical.field(String?.none) == "")
    }
}

// MARK: - §2 Certificates

@Suite("Fixtures — identity certificates (§2)")
struct CertificateFixtureTests {

    @Test("alice and bob certificates verify against the pinned server key")
    func validCertificates() throws {
        let vectors = try Fixtures.require()
        for name in ["alice", "bob"] {
            let entry = try #require(vectors.certificates[name])
            #expect(entry.valid)
            #expect(entry.certificate.isValid(serverKeyBase64: vectors.server.publicKeyBase64,
                                              now: Fixtures.referenceDate),
                    "\(name) certificate should validate")
        }
    }

    @Test("signedFields match the generated canonical bytes")
    func signedFields() throws {
        let vectors = try Fixtures.require()
        for name in ["alice", "bob"] {
            let entry = try #require(vectors.certificates[name])
            let hex = try #require(entry.signedFieldsHex)
            #expect(Canonical.encode(entry.certificate.signedFields).hexString == hex,
                    "\(name) signedFields mismatch")
        }
    }

    @Test("a tampered certificate is rejected")
    func tamperedCertificate() throws {
        let vectors = try Fixtures.require()
        let entry = try #require(vectors.certificates["tampered"])
        #expect(entry.valid == false)
        #expect(entry.certificate.isValid(serverKeyBase64: vectors.server.publicKeyBase64,
                                          now: Fixtures.referenceDate) == false)
    }

    @Test("a certificate signed by another key is rejected")
    func wrongServerKey() throws {
        let vectors = try Fixtures.require()
        let entry = try #require(vectors.certificates["alice"])
        let other = Curve25519.Signing.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        #expect(entry.certificate.isValid(serverKeyBase64: other,
                                          now: Fixtures.referenceDate) == false)
    }

    @Test("validity window is enforced at both ends")
    func validityWindow() throws {
        let vectors = try Fixtures.require()
        let cert = try #require(vectors.certificates["alice"]).certificate
        let key = vectors.server.publicKeyBase64

        // issuedAt - 300 is the earliest accepted instant.
        let justBefore = Date(timeIntervalSince1970: TimeInterval(cert.issuedAt - 301))
        let atSkewEdge = Date(timeIntervalSince1970: TimeInterval(cert.issuedAt - 300))
        let afterExpiry = Date(timeIntervalSince1970: TimeInterval(cert.expiresAt))

        #expect(cert.isValid(serverKeyBase64: key, now: justBefore) == false)
        #expect(cert.isValid(serverKeyBase64: key, now: atSkewEdge))
        #expect(cert.isValid(serverKeyBase64: key, now: afterExpiry) == false)
    }

    @Test("decode/encode round-trips the transport JSON")
    func jsonRoundTrip() throws {
        let vectors = try Fixtures.require()
        let entry = try #require(vectors.certificates["alice"])
        let decoded = try #require(IdentityCertificate.decode(entry.json))
        #expect(decoded == entry.certificate)
        // Re-encoding is lossless. (Byte equality with Python's JSON is not
        // required: JSONEncoder escapes "/" as "\\/", and signatures cover the
        // canonical field list, never the JSON text.)
        #expect(IdentityCertificate.decode(decoded.encodedJSON()) == entry.certificate)
    }

    @Test("expiresSoon flags the last 7 days")
    func expiresSoon() throws {
        let vectors = try Fixtures.require()
        let cert = try #require(vectors.certificates["alice"]).certificate
        let sixDaysLeft = Date(timeIntervalSince1970: TimeInterval(cert.expiresAt - 6 * 86_400))
        let eightDaysLeft = Date(timeIntervalSince1970: TimeInterval(cert.expiresAt - 8 * 86_400))
        #expect(cert.expiresSoon(now: sixDaysLeft))
        #expect(cert.expiresSoon(now: eightDaysLeft) == false)
    }
}

// MARK: - §3 Wire message

@Suite("Fixtures — wire message (§3)")
struct WireFixtureTests {

    @Test("signedFields list matches the generator")
    func signedFieldsList() throws {
        let vectors = try Fixtures.require()
        #expect(vectors.wire.message.signedFields == vectors.wire.signedFields)
    }

    @Test("canonical bytes of the signed fields match")
    func signedFieldsBytes() throws {
        let vectors = try Fixtures.require()
        #expect(Canonical.encode(vectors.wire.message.signedFields).hexString
                == vectors.wire.signedFieldsHex)
    }

    @Test("the Python-generated signature verifies in Swift")
    func signatureVerifies() throws {
        let vectors = try Fixtures.require()
        #expect(CryptoManager.verify(vectors.wire.message.signedFields,
                                     signature: vectors.wire.signature,
                                     signingKeyBase64: vectors.alice.signingKeyBase64))
        #expect(vectors.wire.message.hasValidSignature(
            signingKeyBase64: vectors.alice.signingKeyBase64))
    }

    @Test("mutating any signed field breaks the signature")
    func mutationBreaksSignature() throws {
        let vectors = try Fixtures.require()
        var message = vectors.wire.message
        message.value = "{\"wait\":0,\"max\":1}"
        #expect(message.hasValidSignature(
            signingKeyBase64: vectors.alice.signingKeyBase64) == false)

        var retyped = vectors.wire.message
        retyped.type = WireType.relayDeposit.rawValue
        #expect(retyped.hasValidSignature(
            signingKeyBase64: vectors.alice.signingKeyBase64) == false)
    }

    @Test("the fixture message is a relayFetch of the expected shape")
    func shape() throws {
        let vectors = try Fixtures.require()
        let message = vectors.wire.message
        #expect(message.v == 2)
        #expect(message.wireType == .relayFetch)
        #expect(message.senderPhone == vectors.alice.phone)
        #expect(message.senderPort == 0)
        #expect(message.timestamp == 1_790_000_500)
        #expect(message.recipientPhone == nil)
        #expect(message.envelope == nil)
    }
}

// MARK: - §4 Envelope

@Suite("Fixtures — envelope (§4)")
struct EnvelopeFixtureTests {

    @Test("header field list and canonical bytes match")
    func header() throws {
        let vectors = try Fixtures.require()
        let envelope = vectors.envelope.envelope
        #expect(envelope.header == vectors.envelope.header)
        #expect(Canonical.encode(envelope.header).hexString
                == vectors.envelope.headerCanonicalHex)
    }

    @Test("signedFields canonical bytes match")
    func signedFields() throws {
        let vectors = try Fixtures.require()
        #expect(Canonical.encode(vectors.envelope.envelope.signedFields).hexString
                == vectors.envelope.signedFieldsHex)
    }

    @Test("digestHex matches (lowercase SHA-256 over header + ciphertext + signature)")
    func digest() throws {
        let vectors = try Fixtures.require()
        let digest = vectors.envelope.envelope.digestHex
        #expect(digest == vectors.envelope.digestHex)
        #expect(digest.count == 64)
        #expect(digest == digest.lowercased())
    }

    @Test("the envelope signature verifies with alice's signing key")
    func signature() throws {
        let vectors = try Fixtures.require()
        let envelope = vectors.envelope.envelope
        #expect(CryptoManager.verify(envelope.signedFields,
                                     signature: envelope.signature,
                                     signingKeyBase64: vectors.alice.signingKeyBase64))
    }

    @Test("bob opens the Python-sealed envelope and gets the exact plaintext")
    func openWithBobsKey() throws {
        let vectors = try Fixtures.require()
        let bobCertJSON = try #require(vectors.certificates["bob"]).json
        let aliceCert = try #require(vectors.certificates["alice"]).certificate

        let bob = try IdentityFactory.fixtureCrypto(party: vectors.bob,
                                                    certificateJSON: bobCertJSON)
        let plaintext = try bob.open(vectors.envelope.envelope, senderCert: aliceCert)

        #expect(plaintext.hexString == vectors.envelope.plaintextHex)
        #expect(String(decoding: plaintext, as: UTF8.self) == vectors.envelope.plaintextJSON)

        let payload = try #require(ChatPayload.decode(plaintext))
        #expect(payload.kind == .text)
        #expect(payload.text == "Olá Bob 👋 — é seguro?")
        #expect(payload.sentAt == 1_790_000_600)
        #expect(payload.isWellFormed)
    }

    @Test("a tampered header makes the AEAD open fail")
    func tamperedHeaderFails() throws {
        let vectors = try Fixtures.require()
        let bobCertJSON = try #require(vectors.certificates["bob"]).json
        let aliceCert = try #require(vectors.certificates["alice"]).certificate
        let bob = try IdentityFactory.fixtureCrypto(party: vectors.bob,
                                                    certificateJSON: bobCertJSON)

        let original = vectors.envelope.envelope
        let tampered = Envelope(id: original.id,
                                senderPhone: original.senderPhone,
                                recipientPhone: original.recipientPhone,
                                timestamp: original.timestamp + 1,   // authenticated
                                senderAgreementKey: original.senderAgreementKey,
                                recipientAgreementKey: original.recipientAgreementKey,
                                ephemeralKey: original.ephemeralKey,
                                ciphertext: original.ciphertext,
                                senderCertificate: original.senderCertificate,
                                signature: original.signature)

        // The signature covers the header, so this is caught before decryption.
        #expect(throws: CryptoError.badSignature) {
            _ = try bob.open(tampered, senderCert: aliceCert)
        }
    }

    @Test("ciphertext is the combined nonce|ct|tag form")
    func ciphertextShape() throws {
        let vectors = try Fixtures.require()
        let combined = try #require(Data(base64Encoded: vectors.envelope.envelope.ciphertext))
        let nonce = try #require(Data(hexString: vectors.envelope.nonceHex))
        #expect(combined.prefix(12) == nonce)
        let plaintextBytes = try #require(Data(hexString: vectors.envelope.plaintextHex)).count
        #expect(combined.count == 12 + plaintextBytes + 16)
    }

    @Test("envelope Codable round-trips unchanged")
    func codableRoundTrip() throws {
        let vectors = try Fixtures.require()
        let envelope = vectors.envelope.envelope
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        #expect(decoded == envelope)
        #expect(decoded.digestHex == envelope.digestHex)
    }
}

// MARK: - §7 Safety numbers

@Suite("Fixtures — safety numbers (§7)")
struct SafetyNumberFixtureTests {

    @Test("each side's 30-digit fingerprint matches")
    func halves() throws {
        let vectors = try Fixtures.require()
        let aliceHalf = TrustStore.fingerprint(phone: vectors.alice.phone,
                                               key: vectors.alice.signingKeyBase64)
        let bobHalf = TrustStore.fingerprint(phone: vectors.bob.phone,
                                             key: vectors.bob.signingKeyBase64)
        #expect(aliceHalf == vectors.safetyNumber.aliceHalf)
        #expect(bobHalf == vectors.safetyNumber.bobHalf)
        #expect(aliceHalf.count == 30)
        #expect(bobHalf.count == 30)
    }

    @Test("the combined 60-digit safety number matches")
    func combined() throws {
        let vectors = try Fixtures.require()
        let number = TrustStore.safetyNumber(myPhone: vectors.alice.phone,
                                             myKey: vectors.alice.signingKeyBase64,
                                             theirPhone: vectors.bob.phone,
                                             theirKey: vectors.bob.signingKeyBase64)
        #expect(number == vectors.safetyNumber.expected)
        #expect(number.count == 60)
        #expect(number.allSatisfy { $0.isNumber })
    }

    @Test("argument order does not change the safety number")
    func orderIndependent() throws {
        let vectors = try Fixtures.require()
        let forward = TrustStore.safetyNumber(myPhone: vectors.alice.phone,
                                              myKey: vectors.alice.signingKeyBase64,
                                              theirPhone: vectors.bob.phone,
                                              theirKey: vectors.bob.signingKeyBase64)
        let reversed = TrustStore.safetyNumber(myPhone: vectors.bob.phone,
                                               myKey: vectors.bob.signingKeyBase64,
                                               theirPhone: vectors.alice.phone,
                                               theirKey: vectors.alice.signingKeyBase64)
        #expect(forward == reversed)
    }

    @Test("a different key yields a different safety number")
    func keySensitive() throws {
        let vectors = try Fixtures.require()
        let impostor = Curve25519.Signing.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        let real = TrustStore.safetyNumber(myPhone: vectors.alice.phone,
                                           myKey: vectors.alice.signingKeyBase64,
                                           theirPhone: vectors.bob.phone,
                                           theirKey: vectors.bob.signingKeyBase64)
        let fake = TrustStore.safetyNumber(myPhone: vectors.alice.phone,
                                           myKey: vectors.alice.signingKeyBase64,
                                           theirPhone: vectors.bob.phone,
                                           theirKey: impostor)
        #expect(real != fake)
    }

    @Test("display grouping is 12 groups of 5")
    func formatting() throws {
        let vectors = try Fixtures.require()
        let formatted = TrustStore.formattedSafetyNumber(vectors.safetyNumber.expected)
        let groups = formatted.split(separator: " ")
        #expect(groups.count == 12)
        #expect(groups.allSatisfy { $0.count == 5 })
    }
}

// MARK: - §2 Phone normalization

@Suite("Fixtures — phone normalization (§2)")
struct PhoneFixtureTests {

    @Test("all 16 normalization vectors match")
    func normalizationVectors() throws {
        let vectors = try Fixtures.require()
        #expect(vectors.phones.count == 16)
        for testCase in vectors.phones {
            let normalized = PhoneNumber.normalize(testCase.raw, defaultRegion: testCase.region)
            #expect(normalized == testCase.expected,
                    "normalize(\(testCase.raw), \(testCase.region ?? "nil")) → \(normalized ?? "nil")")
        }
    }

    @Test("E.164 validation")
    func e164() {
        #expect(PhoneNumber.isValidE164("+351912345678"))
        #expect(PhoneNumber.isValidE164("+14155552671"))
        #expect(PhoneNumber.isValidE164("+0123456789") == false)   // leading 0
        #expect(PhoneNumber.isValidE164("351912345678") == false)  // no +
        #expect(PhoneNumber.isValidE164("+12") == false)           // too short
        #expect(PhoneNumber.isValidE164("+1234567890123456") == false) // too long
        #expect(PhoneNumber.isValidE164("+3519123456a8") == false)
        #expect(PhoneNumber.isValidE164("") == false)
    }

    @Test("input filter keeps digits, one leading + and separators",
          arguments: [
            ("+351 912 345 678", "+351 912 345 678"),
            ("*351912345678", "351912345678"),        // hardware keyboard on a phone pad
            ("+351+912", "+351912"),                  // only one +, and only at the start
            ("(415) 555-2671", "(415) 555-2671"),
            ("Tel: +351 912", " +351 912"),           // pasted text keeps the number
            ("12#3*4", "1234"),
          ])
    func inputFilter(input: String, expected: String) {
        #expect(PhoneNumber.sanitizeInput(input) == expected)
    }

    @Test("filtered input still normalizes")
    func filteredInputNormalizes() {
        let typed = PhoneNumber.sanitizeInput("+351 912 345 678")
        #expect(PhoneNumber.normalize(typed, defaultRegion: "PT") == "+351912345678")
    }

    @Test("masking keeps only the first 6 and last 2 characters")
    func masking() {
        let masked = PhoneNumber.masked("+351912345678")
        #expect(masked == "+35191*****78")
        #expect(masked.contains("2345") == false)
        // Short inputs are returned unchanged rather than crashing.
        #expect(PhoneNumber.masked("+1234") == "+1234")
    }
}
