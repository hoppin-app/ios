//
//  IngestOutcomeTests.swift
//  HopChat-1Tests
//
//  The inbound pipeline, driven directly through `processIncoming` — no server
//  needed. These cover the contract's §4 validation order and, above all, the
//  accept/reject/defer decision that drives the relay ack.
//
//  The regression they exist for: `ingest` used to ack *every* fetched
//  envelope, including ones dropped for transient reasons (locked Keychain, an
//  unacknowledged key change). Acking deletes the mail from the relay, so those
//  messages were lost forever. `.retryLater` must never be acked and must never
//  be recorded as seen, so redelivery still works.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

@MainActor
private struct Pair {
    let server: Curve25519.Signing.PrivateKey
    let alice: ServiceHarness      // sender
    let bob: ServiceHarness        // receiver under test
    let now: Date

    static func make(now: Date = Date(),
                     bobTrustBacking: KeyValueSecureStore = InMemorySecureStore())
    async throws -> Pair {
        let server = Curve25519.Signing.PrivateKey()
        let alice = try await ServiceHarness.offline(phone: "+351912345678",
                                                     serverKey: server, now: now)
        let bob = try await ServiceHarness.offline(phone: "+14155552671",
                                                   serverKey: server, now: now,
                                                   trustBacking: bobTrustBacking)
        return Pair(server: server, alice: alice, bob: bob, now: now)
    }

    /// Pins alice's certificate on bob's side (as a prior conversation would).
    func pinAliceOnBob() throws {
        bob.trust.evaluate(try EnvelopeFactory.requireCertificate(alice))
    }
}

// MARK: - Accepted

@MainActor
@Suite("Ingest — accepted envelopes")
struct IngestAcceptedTests {

    @Test("a valid text envelope is accepted and stored")
    func acceptsValidMessage() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()

        let envelope = try EnvelopeFactory.text("hello bob", from: pair.alice, to: pair.bob,
                                                timestamp: pair.now)
        let outcome = await pair.bob.service.processIncoming(envelope)

        #expect(outcome == .accepted)
        let thread = pair.bob.store.thread(pair.alice.phone)
        #expect(thread.count == 1)
        #expect(thread.first?.body == "hello bob")
        #expect(thread.first?.isFromMe == false)
        #expect(thread.first?.status == .delivered)
        #expect(thread.first?.isRead == false)
        #expect(pair.bob.store.hasSeenEnvelope(envelope.id))
        #expect(pair.bob.store.contact(for: pair.alice.phone) != nil,
                "an unknown sender should become a contact")
    }

    @Test("a replayed envelope is accepted again but stored only once")
    func replayStoresOnce() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()
        let envelope = try EnvelopeFactory.text("only once", from: pair.alice, to: pair.bob,
                                                timestamp: pair.now)

        #expect(await pair.bob.service.processIncoming(envelope) == .accepted)
        #expect(await pair.bob.service.processIncoming(envelope) == .accepted,
                "a duplicate is settled, so it must be acked rather than requeued")
        #expect(pair.bob.store.thread(pair.alice.phone).count == 1)
    }

    @Test("a message delivered directly and then again via the relay is stored once, as direct")
    func directThenRelayStoresOnce() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()
        let envelope = try EnvelopeFactory.text("both paths", from: pair.alice, to: pair.bob,
                                                timestamp: pair.now)

        #expect(await pair.bob.service.processIncoming(envelope, viaLAN: true) == .accepted)
        // The sender's LAN ack got lost, so it also went through the relay.
        #expect(await pair.bob.service.processIncoming(envelope, viaLAN: false) == .accepted,
                "the relay copy must be acked, not requeued")
        let thread = pair.bob.store.thread(pair.alice.phone)
        #expect(thread.count == 1)
        #expect(thread.first?.route == .direct)
    }

    @Test("a first-contact envelope pins the sender and is accepted")
    func firstContactIsAccepted() async throws {
        let pair = try await Pair.make()      // nothing pinned yet
        let envelope = try EnvelopeFactory.text("first hello", from: pair.alice, to: pair.bob,
                                                timestamp: pair.now)

        #expect(await pair.bob.service.processIncoming(envelope) == .accepted)
        #expect(pair.bob.trust.pinnedSigningKey(for: pair.alice.phone)
                == pair.alice.crypto.signingPublicKeyBase64)
        #expect(pair.bob.store.thread(pair.alice.phone).count == 1)
    }

    @Test("receipts are applied without being stored as messages")
    func receiptsAreNotStored() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()

        // Bob has an outgoing message that alice acknowledges.
        let cid = pair.alice.phone
        pair.bob.store.appendMessage(
            StoredMessage(id: "out-1", conversationID: cid,
                          fromPhone: pair.bob.phone, toPhone: cid,
                          body: "sent earlier",
                          timestamp: pair.now, status: .sent, isFromMe: true))

        let delivery = try EnvelopeFactory.seal(
            ChatPayload(kind: .deliveryReceipt, refIDs: ["out-1"],
                        sentAt: Int64(pair.now.timeIntervalSince1970)),
            from: pair.alice, to: pair.bob, timestamp: pair.now)
        #expect(await pair.bob.service.processIncoming(delivery) == .accepted)
        #expect(pair.bob.store.thread(cid).first { $0.id == "out-1" }?.status == .delivered)

        let read = try EnvelopeFactory.seal(
            ChatPayload(kind: .readReceipt, refIDs: ["out-1"],
                        sentAt: Int64(pair.now.timeIntervalSince1970)),
            from: pair.alice, to: pair.bob, timestamp: pair.now)
        #expect(await pair.bob.service.processIncoming(read) == .accepted)
        #expect(pair.bob.store.thread(cid).first { $0.id == "out-1" }?.status == .read)

        // Only the original outgoing message exists.
        #expect(pair.bob.store.thread(cid).count == 1)
    }
}

// MARK: - Rejected (permanent — must be acked so the mailbox drains)

@MainActor
@Suite("Ingest — permanent rejections")
struct IngestRejectedTests {

    @Test("a certificate signed by an attacker key is rejected")
    func forgedCertificate() async throws {
        let pair = try await Pair.make()
        let attacker = Curve25519.Signing.PrivateKey()

        // Alice's real keys, but a certificate self-signed by the attacker.
        let forged = IdentityFactory.makeCertificate(
            phone: pair.alice.phone,
            signingKey: pair.alice.crypto.signingPublicKeyBase64,
            agreementKey: pair.alice.crypto.agreementPublicKeyBase64,
            serverKey: attacker,
            issuedAt: pair.now)
        let envelope = try EnvelopeFactory.text("trust me", from: pair.alice, to: pair.bob,
                                                timestamp: pair.now)
        let tampered = EnvelopeFactory.mutate(envelope,
                                              senderCertificate: forged.encodedJSON())

        #expect(await pair.bob.service.processIncoming(tampered) == .rejected)
        #expect(pair.bob.store.thread(pair.alice.phone).isEmpty)
        #expect(pair.bob.trust.pinnedCertificate(for: pair.alice.phone) == nil,
                "a forged certificate must never be pinned")
    }

    @Test("an expired certificate is rejected")
    func expiredCertificate() async throws {
        let pair = try await Pair.make()
        let expiredIssue = pair.now.addingTimeInterval(-40 * 86_400)
        let expired = IdentityFactory.makeCertificate(
            phone: pair.alice.phone,
            signingKey: pair.alice.crypto.signingPublicKeyBase64,
            agreementKey: pair.alice.crypto.agreementPublicKeyBase64,
            serverKey: pair.server,
            issuedAt: expiredIssue)
        let envelope = try EnvelopeFactory.text("stale identity", from: pair.alice,
                                                to: pair.bob, timestamp: pair.now)
        let tampered = EnvelopeFactory.mutate(envelope,
                                              senderCertificate: expired.encodedJSON())
        #expect(await pair.bob.service.processIncoming(tampered) == .rejected)
    }

    @Test("a certificate bound to another phone is rejected")
    func certificatePhoneMismatch() async throws {
        let pair = try await Pair.make()
        let envelope = try EnvelopeFactory.text("hi", from: pair.alice, to: pair.bob,
                                                timestamp: pair.now)
        // senderPhone claims someone else while the certificate says alice.
        let tampered = EnvelopeFactory.mutate(envelope, senderPhone: "+447700900123")
        #expect(await pair.bob.service.processIncoming(tampered) == .rejected)
    }

    @Test("an envelope signed by the wrong key is rejected")
    func wrongSigningKey() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()

        let envelope = try EnvelopeFactory.text("hi", from: pair.alice, to: pair.bob,
                                                timestamp: pair.now)
        let impostorKey = Curve25519.Signing.PrivateKey()
        let badSignature = try impostorKey
            .signature(for: Canonical.encode(envelope.signedFields))
            .base64EncodedString()
        let tampered = EnvelopeFactory.mutate(envelope, signature: badSignature)

        #expect(await pair.bob.service.processIncoming(tampered) == .rejected)
        #expect(pair.bob.store.thread(pair.alice.phone).isEmpty)
    }

    @Test("an envelope addressed to someone else is rejected")
    func wrongRecipient() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()
        let envelope = try EnvelopeFactory.text("not for you", from: pair.alice,
                                                to: pair.bob, timestamp: pair.now)
        let tampered = EnvelopeFactory.mutate(envelope, recipientPhone: "+447700900123")
        #expect(await pair.bob.service.processIncoming(tampered) == .rejected)
    }

    @Test("an envelope older than 7 days is rejected")
    func staleEnvelope() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()
        let old = pair.now.addingTimeInterval(-8 * 86_400)
        let envelope = try EnvelopeFactory.text("ancient", from: pair.alice, to: pair.bob,
                                                timestamp: old)
        #expect(await pair.bob.service.processIncoming(envelope) == .rejected)
        #expect(pair.bob.store.thread(pair.alice.phone).isEmpty)
    }

    @Test("an envelope from the future beyond the window is rejected")
    func futureEnvelope() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()
        let future = pair.now.addingTimeInterval(8 * 86_400)
        let envelope = try EnvelopeFactory.text("tomorrow", from: pair.alice, to: pair.bob,
                                                timestamp: future)
        #expect(await pair.bob.service.processIncoming(envelope) == .rejected)
    }

    @Test("a tampered recipientAgreementKey breaks the AAD and is rejected")
    func tamperedAgreementKey() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()
        let envelope = try EnvelopeFactory.text("hi", from: pair.alice, to: pair.bob,
                                                timestamp: pair.now)
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        let tampered = EnvelopeFactory.mutate(envelope, recipientAgreementKey: other)
        #expect(await pair.bob.service.processIncoming(tampered) == .rejected)
        #expect(pair.bob.store.thread(pair.alice.phone).isEmpty)
    }

    @Test("an unknown sender agreement key is rejected")
    func unknownSenderAgreementKey() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()
        let envelope = try EnvelopeFactory.text("hi", from: pair.alice, to: pair.bob,
                                                timestamp: pair.now)
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        let tampered = EnvelopeFactory.mutate(envelope, senderAgreementKey: other)
        #expect(await pair.bob.service.processIncoming(tampered) == .rejected)
    }

    @Test("a blocked sender is rejected, recorded as seen, and gets no receipt")
    func blockedSender() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()
        pair.bob.store.setBlocked(pair.alice.phone, true)

        let envelope = try EnvelopeFactory.text("let me in", from: pair.alice, to: pair.bob,
                                                timestamp: pair.now)
        #expect(await pair.bob.service.processIncoming(envelope) == .rejected)
        #expect(pair.bob.store.thread(pair.alice.phone).isEmpty)
        #expect(pair.bob.store.hasSeenEnvelope(envelope.id),
                "a blocked sender's envelope is settled, not re-fetched forever")
        #expect(pair.bob.store.totalUnreadCount == 0)
    }

    @Test("a malformed payload is rejected")
    func malformedPayload() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()
        // An empty text body fails `isWellFormed`.
        let envelope = try EnvelopeFactory.seal(
            ChatPayload(kind: .text, text: "",
                        sentAt: Int64(pair.now.timeIntervalSince1970)),
            from: pair.alice, to: pair.bob, timestamp: pair.now)
        #expect(await pair.bob.service.processIncoming(envelope) == .rejected)
        #expect(pair.bob.store.thread(pair.alice.phone).isEmpty)
    }

    @Test("a group message from a non-member is rejected")
    func groupMessageFromStranger() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()
        pair.bob.store.upsertGroup(ChatGroup(id: "g1", name: "Trip",
                                             members: [pair.bob.phone, "+447700900123"],
                                             admins: [pair.bob.phone]))

        let envelope = try EnvelopeFactory.seal(
            ChatPayload(kind: .groupText, text: "let me in", groupID: "g1",
                        sentAt: Int64(pair.now.timeIntervalSince1970)),
            from: pair.alice, to: pair.bob, timestamp: pair.now)
        #expect(await pair.bob.service.processIncoming(envelope) == .rejected)
        #expect(pair.bob.store.thread(ConversationStore.conversationID(group: "g1")).isEmpty)
    }

    @Test("a relayed typing indicator is rejected (LAN only)")
    func typingOverRelay() async throws {
        let pair = try await Pair.make()
        try pair.pinAliceOnBob()
        let envelope = try EnvelopeFactory.seal(
            ChatPayload(kind: .typing, sentAt: Int64(pair.now.timeIntervalSince1970)),
            from: pair.alice, to: pair.bob, timestamp: pair.now)

        #expect(await pair.bob.service.processIncoming(envelope, viaLAN: false) == .rejected)
        #expect(pair.bob.service.typingPeers.isEmpty)
    }

    @Test("an attacker claiming the victim's number cannot impersonate them")
    func phoneNumberClaim() async throws {
        let pair = try await Pair.make()
        let attacker = try await ServiceHarness.offline(phone: "+447700900123",
                                                        serverKey: pair.server,
                                                        now: pair.now)
        try pair.pinAliceOnBob()

        // The attacker seals a message and rewrites senderPhone to alice's.
        let envelope = try EnvelopeFactory.text("I am alice", from: attacker, to: pair.bob,
                                                timestamp: pair.now)
        let spoofed = EnvelopeFactory.mutate(envelope, senderPhone: pair.alice.phone)

        #expect(await pair.bob.service.processIncoming(spoofed) == .rejected)
        #expect(pair.bob.store.thread(pair.alice.phone).isEmpty)
        // The real alice's pin is untouched.
        #expect(pair.bob.trust.pinnedSigningKey(for: pair.alice.phone)
                == pair.alice.crypto.signingPublicKeyBase64)
    }
}

// MARK: - Deferred (transient — must NOT be acked)

@MainActor
@Suite("Ingest — transient deferrals are never destroyed")
struct IngestRetryLaterTests {

    @Test("an unreadable Keychain defers the envelope instead of dropping it")
    func lockedKeychainDefers() async throws {
        let throwingTrust = ThrowingSecureStore(isAvailable: true)
        let pair = try await Pair.make(bobTrustBacking: throwingTrust)
        try pair.pinAliceOnBob()

        let envelope = try EnvelopeFactory.text("please survive", from: pair.alice,
                                                to: pair.bob, timestamp: pair.now)

        // Device locked: the trust store cannot be read.
        throwingTrust.isAvailable = false
        let lockedTrust = TrustStore(store: throwingTrust)
        #expect(lockedTrust.evaluate(try EnvelopeFactory.requireCertificate(pair.alice))
                == .unavailable)

        // A fresh receiver whose trust store is unreadable from the start.
        let bob = try await ServiceHarness.offline(phone: "+14155552671",
                                                   serverKey: pair.server,
                                                   now: pair.now,
                                                   trustBacking: throwingTrust)
        let deferred = try EnvelopeFactory.text("please survive", from: pair.alice,
                                                to: bob, timestamp: pair.now)
        let outcome = await bob.service.processIncoming(deferred)

        #expect(outcome == .retryLater, "a locked Keychain must not destroy mail")
        #expect(bob.store.thread(pair.alice.phone).isEmpty)
        #expect(bob.store.hasSeenEnvelope(deferred.id) == false,
                "a deferred envelope must not be recorded as seen, or redelivery is swallowed")
        _ = envelope
    }

    @Test("the same envelope is delivered once the Keychain is readable again")
    func deferredEnvelopeIsDeliveredLater() async throws {
        let throwingTrust = ThrowingSecureStore(isAvailable: false)
        let server = Curve25519.Signing.PrivateKey()
        let now = Date()
        let alice = try await ServiceHarness.offline(phone: "+351912345678",
                                                     serverKey: server, now: now)
        let bob = try await ServiceHarness.offline(phone: "+14155552671",
                                                   serverKey: server, now: now,
                                                   trustBacking: throwingTrust)

        let envelope = try EnvelopeFactory.text("delayed but not lost", from: alice,
                                                to: bob, timestamp: now)
        #expect(await bob.service.processIncoming(envelope) == .retryLater)
        #expect(bob.store.thread(alice.phone).isEmpty)

        // Device unlocked; the relay redelivers the same envelope.
        throwingTrust.isAvailable = true
        #expect(await bob.service.processIncoming(envelope) == .accepted)
        #expect(bob.store.thread(alice.phone).first?.body == "delayed but not lost")
        #expect(bob.store.hasSeenEnvelope(envelope.id))
    }

    @Test("an unacknowledged key change defers mail rather than losing it")
    func keyChangeDefers() async throws {
        let server = Curve25519.Signing.PrivateKey()
        let now = Date()
        let bob = try await ServiceHarness.offline(phone: "+14155552671",
                                                   serverKey: server, now: now)

        // Bob pinned alice's original key.
        let original = try await ServiceHarness.offline(phone: "+351912345678",
                                                        serverKey: server, now: now)
        bob.trust.evaluate(try EnvelopeFactory.requireCertificate(original))

        // Alice reinstalls: same number, brand-new signing key.
        let reinstalled = try await ServiceHarness.offline(phone: "+351912345678",
                                                           serverKey: server, now: now)
        #expect(reinstalled.crypto.signingPublicKeyBase64
                != original.crypto.signingPublicKeyBase64)

        let envelope = try EnvelopeFactory.text("it's still me", from: reinstalled,
                                                to: bob, timestamp: now)
        #expect(await bob.service.processIncoming(envelope) == .retryLater,
                "mail from a changed key must be held, not acked away")
        #expect(bob.store.thread(reinstalled.phone).isEmpty)
        #expect(bob.store.hasSeenEnvelope(envelope.id) == false)
        #expect(bob.trust.hasPendingKeyChange(reinstalled.phone))

        // The user reviews the safety number and accepts.
        bob.trust.acceptKeyChange(for: reinstalled.phone)
        #expect(bob.trust.hasPendingKeyChange(reinstalled.phone) == false)

        // The relay redelivers and the message finally lands.
        #expect(await bob.service.processIncoming(envelope) == .accepted)
        #expect(bob.store.thread(reinstalled.phone).first?.body == "it's still me")
    }

    @Test("a rejected key change keeps deferring, and never stores the message")
    func rejectedKeyChangeKeepsDeferring() async throws {
        let server = Curve25519.Signing.PrivateKey()
        let now = Date()
        let bob = try await ServiceHarness.offline(phone: "+14155552671",
                                                   serverKey: server, now: now)
        let original = try await ServiceHarness.offline(phone: "+351912345678",
                                                        serverKey: server, now: now)
        bob.trust.evaluate(try EnvelopeFactory.requireCertificate(original))

        let impostor = try await ServiceHarness.offline(phone: "+351912345678",
                                                        serverKey: server, now: now)
        let envelope = try EnvelopeFactory.text("hello, it's 'alice'", from: impostor,
                                                to: bob, timestamp: now)
        #expect(await bob.service.processIncoming(envelope) == .retryLater)

        bob.trust.rejectKeyChange(for: impostor.phone)
        // The old pin stands, so the impostor's envelope is refused again.
        let outcome = await bob.service.processIncoming(envelope)
        #expect(outcome == .retryLater || outcome == .rejected)
        #expect(bob.store.thread(impostor.phone).isEmpty,
                "an impostor's message must never be shown as the pinned contact's")
    }

    @Test("outcome cases are distinct")
    func outcomeEquality() {
        #expect(IngestOutcome.accepted != IngestOutcome.rejected)
        #expect(IngestOutcome.accepted != IngestOutcome.retryLater)
        #expect(IngestOutcome.rejected != IngestOutcome.retryLater)
    }
}
