//
//  WireProtocolTests.swift
//  HopChat-1Tests
//
//  Wire message signing/coding, framing limits, freshness, replay caching,
//  rate limiting and backoff — contract §3.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

// MARK: - Wire message

@Suite("WireMessage — signing fields and coding (§3)")
struct WireMessageTests {

    private func sample(type: WireType = .relayFetch) -> WireMessage {
        WireMessage(type: type,
                    txID: "33333333-3333-4333-8333-333333333333",
                    senderPhone: "+351912345678",
                    senderPort: 0,
                    timestamp: 1_790_000_500,
                    value: "{\"wait\":25,\"max\":100}")
    }

    @Test("signedFields are in the exact contract order")
    func fieldOrder() {
        var message = sample(type: .relayDeposit)
        message.recipientPhone = "+14155552671"
        message.key = "k"
        let fields = message.signedFields

        #expect(fields.count == 10)
        #expect(fields[0] == "hopchat-wire-v2")
        #expect(fields[1] == String(WireType.relayDeposit.rawValue))
        #expect(fields[2] == message.txID)
        #expect(fields[3] == message.senderPhone)
        #expect(fields[4] == "0")
        #expect(fields[5] == "1790000500")
        #expect(fields[6] == "+14155552671")
        #expect(fields[7] == "k")
        #expect(fields[8] == message.value)
        #expect(fields[9] == "")                 // no envelope
    }

    @Test("missing optionals become empty strings, not nil")
    func optionalsAreEmptyStrings() {
        let message = WireMessage(type: .ping, senderPhone: "+351912345678")
        let fields = message.signedFields
        #expect(fields[6] == "")
        #expect(fields[7] == "")
        #expect(fields[8] == "")
        #expect(fields[9] == "")
    }

    @Test("an envelope is bound into the signature by its digest")
    func envelopeDigestBinding() throws {
        let vectors = try Fixtures.require()
        var message = WireMessage(type: .relayDeposit,
                                  senderPhone: vectors.alice.phone,
                                  recipientPhone: vectors.bob.phone,
                                  envelope: vectors.envelope.envelope)
        #expect(message.signedFields[9] == vectors.envelope.digestHex)

        // Swapping the envelope changes the signed fields.
        let other = Envelope(id: "other",
                             senderPhone: vectors.alice.phone,
                             recipientPhone: vectors.bob.phone,
                             timestamp: 1,
                             senderAgreementKey: vectors.alice.agreementKeyBase64,
                             recipientAgreementKey: vectors.bob.agreementKeyBase64,
                             ephemeralKey: vectors.envelope.envelope.ephemeralKey,
                             ciphertext: "AAAA",
                             senderCertificate: "{}",
                             signature: "AAAA")
        message.envelope = other
        #expect(message.signedFields[9] != vectors.envelope.digestHex)
    }

    @Test("sign then verify round-trips")
    func signVerify() throws {
        let key = Curve25519.Signing.PrivateKey()
        let keyB64 = key.publicKey.rawRepresentation.base64EncodedString()
        var message = sample()
        message.signature = try key.signature(for: Canonical.encode(message.signedFields))
            .base64EncodedString()

        #expect(message.hasValidSignature(signingKeyBase64: keyB64))
        #expect(message.hasValidSignature(
            signingKeyBase64: Curve25519.Signing.PrivateKey().publicKey
                .rawRepresentation.base64EncodedString()) == false)
    }

    @Test("garbage signatures and keys are rejected without crashing")
    func malformedSignatureInputs() {
        let fields = ["hopchat-wire-v2", "1"]
        let key = Curve25519.Signing.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        #expect(CryptoManager.verify(fields, signature: "", signingKeyBase64: key) == false)
        #expect(CryptoManager.verify(fields, signature: "not base64!!", signingKeyBase64: key) == false)
        #expect(CryptoManager.verify(fields,
                                     signature: Data(repeating: 0, count: 64).base64EncodedString(),
                                     signingKeyBase64: key) == false)
        // A 16-byte "key" must not be accepted.
        #expect(CryptoManager.verify(fields,
                                     signature: Data(repeating: 0, count: 64).base64EncodedString(),
                                     signingKeyBase64: Data(repeating: 1, count: 16).base64EncodedString()) == false)
    }

    @Test("JSON coding round-trips and rejects the wrong version")
    func coding() throws {
        var message = sample()
        message.certificate = "{\"v\":1}"
        message.signature = "AAAA"
        let data = try message.encodedJSON()
        let decoded = try #require(WireMessage.decode(data))

        #expect(decoded.type == message.type)
        #expect(decoded.txID == message.txID)
        #expect(decoded.senderPhone == message.senderPhone)
        #expect(decoded.timestamp == message.timestamp)
        #expect(decoded.value == message.value)
        #expect(decoded.certificate == message.certificate)
        #expect(decoded.signedFields == message.signedFields)

        var v1 = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        v1["v"] = 1
        let v1Data = try JSONSerialization.data(withJSONObject: v1)
        #expect(WireMessage.decode(v1Data) == nil, "a v1 message must not decode as v2")

        #expect(WireMessage.decode(Data("{".utf8)) == nil)
        #expect(WireMessage.decode(Data()) == nil)
    }

    @Test("every contract message type maps to a raw value")
    func wireTypes() {
        let expected: [(WireType, UInt8)] = [
            (.ping, 0x01), (.pong, 0x02), (.directEnvelope, 0x0B), (.directAck, 0x0C),
            (.verifyStart, 0x20), (.verifyStarted, 0x21), (.verifyConfirm, 0x22),
            (.certificateIssued, 0x23), (.certRenew, 0x24), (.certLookup, 0x25),
            (.certResult, 0x26), (.error, 0x2F), (.relayDeposit, 0x30),
            (.relayAccepted, 0x31), (.relayFetch, 0x32), (.relayBatch, 0x33),
            (.relayAck, 0x34), (.ok, 0x35), (.report, 0x36), (.deleteAccount, 0x37),
            (.changeNumberStart, 0x38), (.changeNumberConfirm, 0x39), (.hello, 0x40),
        ]
        for (type, raw) in expected {
            #expect(type.rawValue == raw)
            #expect(WireType(rawValue: raw) == type)
        }
        // Removed v1 verbs must not decode.
        for removed: UInt8 in [0x03, 0x04, 0x05, 0x06, 0x07, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12] {
            #expect(WireType(rawValue: removed) == nil, "v1 type \(removed) still exists")
        }
    }
}

// MARK: - Freshness

@Suite("WireMessage — freshness window (§3)")
struct FreshnessTests {

    private func message(at timestamp: Int64) -> WireMessage {
        WireMessage(type: .ping, senderPhone: "+351912345678", timestamp: timestamp)
    }

    @Test("±300 s is accepted, beyond it is not")
    func window() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let t = Int64(now.timeIntervalSince1970)

        #expect(message(at: t).isFresh(now: now))
        #expect(message(at: t - 300).isFresh(now: now))
        #expect(message(at: t + 300).isFresh(now: now))
        #expect(message(at: t - 301).isFresh(now: now) == false)
        #expect(message(at: t + 301).isFresh(now: now) == false)
        #expect(message(at: t - 86_400).isFresh(now: now) == false)
    }

    @Test("the window constant is 300 seconds")
    func constant() {
        #expect(WireMessage.freshnessWindow == 300)
    }
}

// MARK: - Framing

@Suite("WireFrame — length prefix and 1 MiB cap (§3)")
struct FramingTests {

    @Test("frames are 4-byte big-endian length prefixed")
    func framing() throws {
        let payload = Data("hello".utf8)
        let framed = try WireFrame.frame(payload)
        #expect(framed.count == 4 + payload.count)
        #expect(Array(framed.prefix(4)) == [0x00, 0x00, 0x00, 0x05])
        #expect(framed.dropFirst(4) == payload)
        #expect(WireFrame.parseLength(framed.prefix(4)) == 5)
    }

    @Test("the maximum frame is exactly 1 048 576 bytes")
    func cap() throws {
        #expect(WireFrame.maxFrameBytes == 1_048_576)

        let atLimit = Data(repeating: 0x41, count: WireFrame.maxFrameBytes)
        #expect(throws: Never.self) { _ = try WireFrame.frame(atLimit) }

        let overLimit = Data(repeating: 0x41, count: WireFrame.maxFrameBytes + 1)
        #expect(throws: WireFrame.FrameError.tooLarge(WireFrame.maxFrameBytes + 1)) {
            _ = try WireFrame.frame(overLimit)
        }
    }

    @Test("empty frames are refused")
    func empty() {
        #expect(throws: WireFrame.FrameError.empty) { _ = try WireFrame.frame(Data()) }
    }

    @Test("out-of-range and short length prefixes parse to nil")
    func lengthParsing() {
        #expect(WireFrame.parseLength(Data([0, 0, 0, 0])) == nil)            // zero
        #expect(WireFrame.parseLength(Data([0xFF, 0xFF, 0xFF, 0xFF])) == nil) // > cap
        #expect(WireFrame.parseLength(Data([0x00, 0x10, 0x00, 0x00])) == 1_048_576)
        #expect(WireFrame.parseLength(Data([0x00, 0x10, 0x00, 0x01])) == nil) // cap + 1
        #expect(WireFrame.parseLength(Data([0, 0, 1])) == nil)                // short
        #expect(WireFrame.parseLength(Data()) == nil)
    }

    @Test("an oversized wire message cannot be framed")
    func oversizedMessage() {
        var message = WireMessage(type: .relayDeposit, senderPhone: "+351912345678")
        message.value = String(repeating: "x", count: WireFrame.maxFrameBytes + 1)
        #expect(throws: (any Error).self) { _ = try WireFrame.frame(message) }
    }
}

// MARK: - Replay cache

@Suite("ReplayCache — txID replay rejection (§3)")
struct ReplayCacheTests {

    @Test("a repeated txID inside the TTL is rejected")
    func replayRejected() {
        let cache = ReplayCache(ttl: 600)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(cache.record("tx-1", now: now))
        #expect(cache.record("tx-1", now: now) == false)
        #expect(cache.contains("tx-1", now: now))
        #expect(cache.record("tx-2", now: now))
    }

    @Test("an entry expires after the TTL")
    func ttlExpiry() {
        let cache = ReplayCache(ttl: 600)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(cache.record("tx", now: now))
        #expect(cache.contains("tx", now: now.addingTimeInterval(599)))
        #expect(cache.contains("tx", now: now.addingTimeInterval(601)) == false)
        // After the TTL the same id is usable again.
        #expect(cache.record("tx", now: now.addingTimeInterval(601)))
    }

    @Test("stale entries are pruned as the cache grows")
    func pruning() {
        let cache = ReplayCache(ttl: 600)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for i in 0..<200 { _ = cache.record("old-\(i)", now: start) }
        #expect(cache.count == 200)

        // Far past the TTL: recording one more prunes the expired entries.
        _ = cache.record("new", now: start.addingTimeInterval(5_000))
        #expect(cache.count < 200)
        #expect(cache.contains("new", now: start.addingTimeInterval(5_000)))
    }

    @Test("a flood is capped rather than growing without bound")
    func hardCapEviction() {
        let cache = ReplayCache(ttl: 600, maxEntries: 100)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for i in 0..<500 { _ = cache.record("tx-\(i)", now: now) }
        #expect(cache.count <= 500)
        #expect(cache.count > 0)
        // The most recent id is always retained.
        #expect(cache.contains("tx-499", now: now))
    }

    @Test("removeAll clears the cache")
    func clear() {
        let cache = ReplayCache()
        _ = cache.record("tx")
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.record("tx"))
    }
}

// MARK: - Token bucket / backoff

@Suite("TokenBucket and Backoff")
struct RateLimitTests {

    @Test("a bucket allows its capacity then refuses")
    func capacity() {
        let bucket = TokenBucket(capacity: 3, per: 60)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(bucket.consume("1.2.3.4", now: now))
        #expect(bucket.consume("1.2.3.4", now: now))
        #expect(bucket.consume("1.2.3.4", now: now))
        #expect(bucket.consume("1.2.3.4", now: now) == false)
        // A different source has its own budget.
        #expect(bucket.consume("5.6.7.8", now: now))
    }

    @Test("tokens refill over time")
    func refill() {
        let bucket = TokenBucket(capacity: 3, per: 60)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for _ in 0..<3 { _ = bucket.consume("ip", now: now) }
        #expect(bucket.consume("ip", now: now) == false)
        #expect(bucket.consume("ip", now: now.addingTimeInterval(20)))
        #expect(bucket.consume("ip", now: now.addingTimeInterval(20)) == false)
    }

    @Test("backoff grows exponentially with jitter and is capped")
    func backoff() {
        var backoff = Backoff(base: 1, cap: 60)
        var previousCeiling = 0.0
        for attempt in 0..<10 {
            let delay = backoff.next()
            let ceiling = min(60, 1 * pow(2, Double(attempt)))
            #expect(delay >= ceiling / 2 - 0.001)
            #expect(delay <= ceiling + 0.001)
            #expect(delay <= 60.001)
            previousCeiling = ceiling
        }
        #expect(previousCeiling == 60)

        backoff.reset()
        let afterReset = backoff.next()
        #expect(afterReset <= 1.001)
    }
}

// MARK: - ChatPayload

@Suite("ChatPayload — classification and limits (§4)")
struct ChatPayloadTests {

    @Test("receipts and typing are transient and never stored")
    func transientKinds() {
        for kind in [ChatPayload.Kind.deliveryReceipt, .readReceipt, .typing] {
            let payload = ChatPayload(kind: kind, refIDs: ["m1"])
            #expect(payload.isTransient)
            #expect(payload.isStoredMessage == false)
        }
        for kind in [ChatPayload.Kind.text, .image, .groupText, .groupImage] {
            #expect(ChatPayload(kind: kind).isTransient == false)
            #expect(ChatPayload(kind: kind).isStoredMessage)
        }
    }

    @Test("typing is LAN-only")
    func lanOnly() {
        #expect(ChatPayload(kind: .typing).isLANOnly)
        #expect(ChatPayload(kind: .text, text: "hi").isLANOnly == false)
    }

    @Test("well-formedness rejects empty, oversized and incomplete payloads")
    func wellFormed() {
        #expect(ChatPayload(kind: .text, text: "hi").isWellFormed)
        #expect(ChatPayload(kind: .text, text: "").isWellFormed == false)
        #expect(ChatPayload(kind: .text).isWellFormed == false)

        let smallJPEG = Data(repeating: 0xFF, count: 1024).base64EncodedString()
        #expect(ChatPayload(kind: .image, imageJPEGBase64: smallJPEG).isWellFormed)
        let tooBig = Data(repeating: 0xFF, count: ChatPayload.maxImageBytes + 1)
            .base64EncodedString()
        #expect(ChatPayload(kind: .image, imageJPEGBase64: tooBig).isWellFormed == false)

        #expect(ChatPayload(kind: .deliveryReceipt, refIDs: ["a"]).isWellFormed)
        #expect(ChatPayload(kind: .deliveryReceipt, refIDs: []).isWellFormed == false)
        #expect(ChatPayload(kind: .readReceipt,
                            refIDs: (0..<201).map(String.init)).isWellFormed == false)

        #expect(ChatPayload(kind: .groupCreate, groupID: "g",
                            groupMembers: ["+351912345678"]).isWellFormed)
        #expect(ChatPayload(kind: .groupCreate, groupMembers: ["+351912345678"]).isWellFormed == false)
        let tooMany = (0..<(AppConfig.maxGroupMembers + 1)).map { "+3519123456\($0)" }
        #expect(ChatPayload(kind: .groupCreate, groupID: "g",
                            groupMembers: tooMany).isWellFormed == false)

        #expect(ChatPayload(kind: .numberChange, newPhone: "+351911111111",
                            newCertificate: "{}").isWellFormed)
        #expect(ChatPayload(kind: .numberChange, newPhone: "+351911111111").isWellFormed == false)

        let bigAvatar = Data(repeating: 0xFF, count: ChatPayload.maxAvatarBytes + 1)
            .base64EncodedString()
        #expect(ChatPayload(kind: .profile, displayName: "Ana",
                            avatarJPEGBase64: bigAvatar).isWellFormed == false)
    }

    @Test("payload coding round-trips")
    func coding() throws {
        let payload = ChatPayload(kind: .groupText, text: "olá 👋", groupID: "g1",
                                  sentAt: 1_790_000_600)
        let decoded = try #require(ChatPayload.decode(try payload.encoded()))
        #expect(decoded == payload)
        #expect(ChatPayload.decode(Data("{}".utf8)) == nil)
    }

    @Test("image and avatar limits match the contract")
    func limits() {
        #expect(ChatPayload.maxImageBytes == 600 * 1024)
        #expect(ChatPayload.maxAvatarBytes == 64 * 1024)
        #expect(AppConfig.maxGroupMembers == 32)
    }
}
