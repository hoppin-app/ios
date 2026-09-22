//
//  MeshCodecTests.swift
//  HopChat-1Tests
//
//  The BLE mesh's wire layer: the compact envelope encoding, the packet
//  header, padding, the hint, and the anonymous outer seal.
//
//  What matters here is what a *carrier* can learn. A phone relaying someone
//  else's packet must not be able to read it, tell who it is for, or alter it
//  — and the recipient must still be able to find its own mail with no address
//  on the wire.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

// MARK: - Two parties with certificates from the same server

@MainActor
private struct MeshPair {
    let alice: ServiceHarness
    let bob: ServiceHarness

    static func make() async throws -> MeshPair {
        let server = Curve25519.Signing.PrivateKey()
        return MeshPair(alice: try await ServiceHarness.offline(phone: "+351912345678", serverKey: server),
                        bob: try await ServiceHarness.offline(phone: "+14155552671", serverKey: server))
    }

    var bobAgreementKey: String {
        get throws { try EnvelopeFactory.requireCertificate(bob).agreementKey }
    }
}

// MARK: - Compact envelope

@MainActor
@Suite("Mesh — compact envelope encoding")
struct CompactEnvelopeTests {

    @Test("an envelope survives the round trip unchanged")
    func roundTrip() async throws {
        let pair = try await MeshPair.make()
        let envelope = try EnvelopeFactory.text("mesh hello", from: pair.alice, to: pair.bob)

        let encoded = try #require(CompactEnvelope.encode(envelope))
        let decoded = try #require(CompactEnvelope.decode(encoded))
        #expect(decoded == envelope)
    }

    @Test("the compact form is much smaller than the JSON one")
    func smallerThanJSON() async throws {
        let pair = try await MeshPair.make()
        let envelope = try EnvelopeFactory.text("mesh hello", from: pair.alice, to: pair.bob)

        let json = try JSONEncoder().encode(envelope).count
        let compact = try #require(CompactEnvelope.encode(envelope)).count
        // Base64, JSON keys and the embedded certificate cost roughly a third.
        // A short text message lands around 550 B compact vs ~1 kB of JSON,
        // which is what decides whether it fits in a brief BLE encounter.
        #expect(compact * 100 < json * 70, "compact \(compact) B vs JSON \(json) B")
        #expect(compact < 1024, "a short text message should fit in 1 KiB: \(compact) B")
    }

    @Test("garbage and truncated input are refused, never partly decoded")
    func rejectsGarbage() async throws {
        let pair = try await MeshPair.make()
        let envelope = try EnvelopeFactory.text("mesh hello", from: pair.alice, to: pair.bob)
        let good = try #require(CompactEnvelope.encode(envelope))

        #expect(CompactEnvelope.decode(Data()) == nil)
        #expect(CompactEnvelope.decode(Data(repeating: 0, count: 200)) == nil)
        #expect(CompactEnvelope.decode(good.prefix(good.count - 1)) == nil)
        #expect(CompactEnvelope.decode(good + Data([0])) == nil, "trailing bytes must fail")
        var wrongMagic = good
        wrongMagic[wrongMagic.startIndex] = 0x00
        #expect(CompactEnvelope.decode(wrongMagic) == nil)
    }
}

// MARK: - Packet, padding, hint

@Suite("Mesh — packet header, padding and hint")
struct MeshPacketTests {

    private func packet(ttl: UInt8 = MeshPacket.defaultTTL,
                        hint: UInt8 = 7,
                        expiresIn: TimeInterval = 3600,
                        body: Data = Data(repeating: 0xAB, count: 64)) -> MeshPacket {
        MeshPacket(packetID: MeshPacket.randomID(),
                   kind: .envelope,
                   ttl: ttl,
                   hint: hint,
                   expiresAt: UInt32(Date().addingTimeInterval(expiresIn).timeIntervalSince1970),
                   body: body)
    }

    @Test("a packet survives the round trip")
    func roundTrip() {
        let original = packet()
        let decoded = MeshPacket.decode(original.encoded())
        #expect(decoded == original)
    }

    @Test("malformed packets are refused")
    func rejectsMalformed() {
        #expect(MeshPacket.decode(Data()) == nil)
        #expect(MeshPacket.decode(Data(repeating: 9, count: MeshPacket.headerSize)) == nil)
        #expect(MeshPacket.decode(packet().encoded().prefix(10)) == nil)

        var wrongVersion = packet().encoded()
        wrongVersion[wrongVersion.startIndex + 2] = 99
        #expect(MeshPacket.decode(wrongVersion) == nil)

        var absurdTTL = packet().encoded()
        absurdTTL[absurdTTL.startIndex + 5] = 200
        #expect(MeshPacket.decode(absurdTTL) == nil, "a huge ttl would let a packet circulate forever")

        var spentTTL = packet().encoded()
        spentTTL[spentTTL.startIndex + 5] = 0
        #expect(MeshPacket.decode(spentTTL) == nil, "a spent packet must not decode at all")

        // Unknown flag bits are ignored so later versions stay carriable.
        var futureFlag = packet().encoded()
        futureFlag[futureFlag.startIndex + 4] = 0x02
        #expect(MeshPacket.decode(futureFlag) != nil)
    }

    @Test("forwarding spends one hop and stops at the end")
    func forwarding() throws {
        let start = packet(ttl: 3)
        let now = Date()
        let once = try #require(start.forwarded(at: now))
        #expect(once.ttl == 2)
        let twice = try #require(once.forwarded(at: now))
        #expect(twice.ttl == 1)
        #expect(twice.forwarded(at: now) == nil, "ttl 1 must not travel further")
        #expect(packet(ttl: 5, expiresIn: -1).forwarded(at: now) == nil,
                "expired packets must not travel")
    }

    @Test("the authenticated header covers everything but the hop count")
    func authenticatedHeader() {
        let original = packet(ttl: 7)
        var hopped = original
        hopped.ttl = 3
        #expect(hopped.authenticatedHeader == original.authenticatedHeader,
                "forwarding must not break the seal")

        let other = packet(ttl: 7, hint: 8)
        #expect(other.authenticatedHeader != original.authenticatedHeader)
    }

    @Test("padding hides the message length and unpads exactly")
    func padding() throws {
        for length in [0, 1, 100, 510, 511, 1000] {
            let payload = Data(repeating: 0x5A, count: length)
            let padded = try #require(MeshPadding.pad(payload))
            #expect(MeshPadding.buckets.contains(padded.count),
                    "\(length) B padded to \(padded.count) B, which is not a bucket")
            #expect(MeshPadding.unpad(padded) == payload)
        }
        // Two different short messages look identical in size.
        let a = MeshPadding.pad(Data(repeating: 1, count: 20))?.count
        let b = MeshPadding.pad(Data(repeating: 1, count: 300))?.count
        #expect(a == b)
        #expect(MeshPadding.pad(Data(repeating: 1, count: 20 * 1024)) == nil)
    }

    @Test("the hint is stable per day, differs per key, and rolls over")
    func hint() {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let noon = Date(timeIntervalSince1970: 1_790_000_000)

        #expect(MeshHint.value(agreementKeyBase64: key, at: noon)
                == MeshHint.value(agreementKeyBase64: key, at: noon.addingTimeInterval(3600)))
        // Different keys almost always differ (1 in 256 collide by design).
        let collisions = (0..<64).filter { i in
            let k = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
            _ = i
            return MeshHint.value(agreementKeyBase64: k, at: noon) == MeshHint.value(agreementKeyBase64: key, at: noon)
        }.count
        #expect(collisions < 8, "hints should be spread out, got \(collisions)/64 collisions")
        _ = other   // a collision between two specific keys is allowed (1 in 256)

        // The candidate set covers yesterday, today and tomorrow.
        let candidates = MeshHint.candidates(agreementKeyBase64: key, at: noon)
        #expect(candidates.contains(MeshHint.value(agreementKeyBase64: key, at: noon)))
        #expect(candidates.contains(MeshHint.value(agreementKeyBase64: key,
                                                   at: noon.addingTimeInterval(86_400))))
        #expect(candidates.count <= 3)
    }
}

// MARK: - The anonymous outer seal

@MainActor
@Suite("Mesh — anonymous outer seal")
struct MeshSealTests {

    /// Builds the packet a sender would put on the mesh.
    private func seal(_ envelope: Envelope,
                      from sender: ServiceHarness,
                      toAgreementKey key: String,
                      ttl: UInt8 = MeshPacket.defaultTTL,
                      at now: Date = Date()) throws -> MeshPacket {
        let compact = try #require(CompactEnvelope.encode(envelope))
        let padded = try #require(MeshPadding.pad(compact))
        let header = MeshPacket(packetID: MeshPacket.randomID(),
                                kind: .envelope,
                                ttl: ttl,
                                hint: MeshHint.value(agreementKeyBase64: key, at: now),
                                expiresAt: UInt32(now.addingTimeInterval(3600).timeIntervalSince1970),
                                body: Data())
        let body = try sender.crypto.sealForMesh(padded,
                                                 recipientAgreementKeyBase64: key,
                                                 authenticating: header.authenticatedHeader)
        return MeshPacket(packetID: header.packetID, kind: .envelope, ttl: ttl,
                          hint: header.hint, expiresAt: header.expiresAt, body: body)
    }

    @Test("the recipient opens it; a stranger carrying it cannot")
    func onlyRecipientOpens() async throws {
        let pair = try await MeshPair.make()
        let carrier = try await ServiceHarness.offline(phone: "+14155550000",
                                                       serverKey: Curve25519.Signing.PrivateKey())
        let envelope = try EnvelopeFactory.text("carried by a stranger", from: pair.alice, to: pair.bob)
        let packet = try seal(envelope, from: pair.alice, toAgreementKey: try pair.bobAgreementKey)

        let openedByBob = try #require(pair.bob.crypto.openMesh(packet.body,
                                                                authenticating: packet.authenticatedHeader))
        let inner = try #require(MeshPadding.unpad(openedByBob))
        #expect(CompactEnvelope.decode(inner) == envelope)

        #expect(carrier.crypto.openMesh(packet.body, authenticating: packet.authenticatedHeader) == nil)
        #expect(pair.alice.crypto.openMesh(packet.body, authenticating: packet.authenticatedHeader) == nil,
                "not even the sender can re-open it — no copy of the ephemeral key is kept")
    }

    @Test("a carrier cannot read names or the certificate in the packet")
    func nothingIdentifyingOnTheWire() async throws {
        let pair = try await MeshPair.make()
        let envelope = try EnvelopeFactory.text("hello", from: pair.alice, to: pair.bob)
        let packet = try seal(envelope, from: pair.alice, toAgreementKey: try pair.bobAgreementKey)
        let wire = packet.encoded()

        for secret in [pair.alice.phone, pair.bob.phone, envelope.id,
                       envelope.senderAgreementKey, envelope.recipientAgreementKey] {
            #expect(wire.range(of: Data(secret.utf8)) == nil, "\(secret) appears in the packet")
        }
    }

    @Test("forwarding keeps the seal; tampering breaks it")
    func tamperEvident() async throws {
        let pair = try await MeshPair.make()
        let envelope = try EnvelopeFactory.text("hello", from: pair.alice, to: pair.bob)
        let packet = try seal(envelope, from: pair.alice, toAgreementKey: try pair.bobAgreementKey)

        // A legitimate hop only spends ttl.
        let hopped = try #require(packet.forwarded(at: Date()))
        #expect(pair.bob.crypto.openMesh(hopped.body, authenticating: hopped.authenticatedHeader) != nil)

        // Re-dating it, or flipping a byte, makes it unopenable.
        let redated = MeshPacket(packetID: packet.packetID, kind: .envelope, ttl: packet.ttl,
                                 hint: packet.hint, expiresAt: packet.expiresAt + 600, body: packet.body)
        #expect(pair.bob.crypto.openMesh(redated.body, authenticating: redated.authenticatedHeader) == nil)

        var flipped = packet.body
        flipped[flipped.index(flipped.startIndex, offsetBy: 40)] ^= 0xFF
        #expect(pair.bob.crypto.openMesh(flipped, authenticating: packet.authenticatedHeader) == nil)
    }

    @Test("the recipient's hint matches, so the cheap filter doesn't drop mail")
    func hintMatchesRecipient() async throws {
        let pair = try await MeshPair.make()
        let envelope = try EnvelopeFactory.text("hello", from: pair.alice, to: pair.bob)
        let packet = try seal(envelope, from: pair.alice, toAgreementKey: try pair.bobAgreementKey)

        #expect(pair.bob.crypto.meshHints().contains(packet.hint))
    }

    @Test("two packets of the same message look unrelated")
    func unlinkable() async throws {
        let pair = try await MeshPair.make()
        let envelope = try EnvelopeFactory.text("same message twice", from: pair.alice, to: pair.bob)
        let first = try seal(envelope, from: pair.alice, toAgreementKey: try pair.bobAgreementKey)
        let second = try seal(envelope, from: pair.alice, toAgreementKey: try pair.bobAgreementKey)

        #expect(first.packetID != second.packetID)
        #expect(first.body != second.body, "a fresh ephemeral key per packet makes copies unlinkable")
        #expect(first.body.count == second.body.count)
    }
}
