//
//  IntegrationTests.swift
//  HopChat-1Tests
//
//  End-to-end against a REAL `bootstrap.py`, started by `lib/run_tests.sh`.
//  A simulator process cannot spawn the server itself, so the script starts it,
//  writes /tmp/hoppin-test-server.json, and these tests read that file.
//  Without it every test here skips, so a plain `xcodebuild test` still passes.
//
//  Two full `KademliaService` instances run in one process (separate secure
//  stores, separate store directories, LAN disabled), so a message really is
//  sealed, deposited, long-poll fetched, decrypted, persisted and receipted.
//
//  Registration is expensive: the server allows 3 `verifyStart` per phone and
//  10 per IP per hour. Each role therefore verifies **once** per process; later
//  tests clone that identity's secure store, which is what a returning app
//  launch does anyway.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

// MARK: - Shared registered identities

@MainActor
final class IntegrationIdentities {

    static let shared = IntegrationIdentities()

    private var snapshots: [String: [String: Data]] = [:]

    /// Registers `phone` once per process and returns its secure-store contents.
    func snapshot(role: String, phone: String, info: ServerInfo) async throws -> [String: Data] {
        if let existing = snapshots[role] { return existing }

        let backing = SharedMemoryStore()
        let harness = ServiceHarness.connected(info: info, secureStore: backing)
        _ = try await harness.service.requestVerificationCode(phone: phone)
        try await harness.service.confirmVerification(phone: phone, code: info.fixedCode)
        harness.service.stop()

        let snapshot = backing.snapshot
        #expect(snapshot[SecureStoreAccount.certificate] != nil,
                "registration should store a certificate for \(role)")
        snapshots[role] = snapshot
        return snapshot
    }

    /// Forces the next `snapshot(role:...)` for this role to register again
    /// (used by the key-change and delete-account tests).
    func forget(role: String) { snapshots.removeValue(forKey: role) }

    /// Replaces a role's cached identity (after a certificate renewal the old
    /// certificate is superseded server-side and must not be reused).
    func update(role: String, from harness: ServiceHarness) {
        guard let store = harness.secureStore as? SharedMemoryStore else { return }
        snapshots[role] = store.snapshot
    }
}

// MARK: - Test world

@MainActor
struct World {

    let info: ServerInfo

    struct ServerRequired: Error, CustomStringConvertible {
        var description: String {
            "HOPPIN_REQUIRE_SERVER=1 but \(RepoPaths.serverInfoURL.path) is missing or invalid"
        }
    }

    /// `nil` (skip) without a server — unless `lib/run_tests.sh` asked for
    /// one, in which case a missing server is a hard failure, never a skip.
    static func make() throws -> World? {
        guard let info = ServerInfo.current else {
            if ProcessInfo.processInfo.environment["HOPPIN_REQUIRE_SERVER"] == "1" {
                throw ServerRequired()
            }
            return nil
        }
        return World(info: info)
    }

    /// A started service for `role`, using the cached registration.
    func party(_ role: String, phone: String, start: Bool = true) async throws -> ServiceHarness {
        let snapshot = try await IntegrationIdentities.shared.snapshot(role: role,
                                                                      phone: phone,
                                                                      info: info)
        let harness = ServiceHarness.connected(
            info: info,
            secureStore: SharedMemoryStore(items: snapshot))
        if start {
            await harness.service.start()
            #expect(harness.service.isRegistered)
            #expect(harness.service.myPhone == phone)
        }
        harness.setCertificate(harness.crypto.certificate ?? IdentityFactory.makeCertificate(
            phone: phone, signingKey: "", agreementKey: "",
            serverKey: Curve25519.Signing.PrivateKey()))
        return harness
    }

    /// A direct client, for the protocol-level (attack) tests.
    func client(for crypto: CryptoManager) -> ServerClient {
        ServerClient(crypto: crypto,
                     host: info.host,
                     port: info.port,
                     useTLS: false,
                     pins: [],
                     serverKeyBase64: info.serverKey)
    }

    /// Empties a mailbox left over from an earlier test.
    func drain(_ harness: ServiceHarness) async {
        for _ in 0..<3 {
            _ = await harness.service.performBackgroundFetch()
        }
    }
}

let alicePhone = "+351912345678"
let bobPhone = "+14155552671"
let carolPhone = "+447700900123"

// MARK: - Registration

@MainActor
@Suite("Integration — verification and certificates", .serialized)
struct VerificationIntegrationTests {

    @Test("verifyStart → verifyConfirm issues a valid, pinned-key certificate")
    func registrationIssuesCertificate() async throws {
        guard let world = try World.make() else {
            withKnownIssue(ServerInfo.skipComment) { Issue.record("integration server absent") }
            return
        }

        let harness = try await world.party("alice", phone: alicePhone)
        defer { harness.stop() }

        let cert = try #require(harness.crypto.certificate)
        #expect(cert.v == 1)
        #expect(cert.phone == alicePhone)
        #expect(cert.signingKey == harness.crypto.signingPublicKeyBase64)
        #expect(cert.agreementKey == harness.crypto.agreementPublicKeyBase64)
        #expect(cert.isValid(serverKeyBase64: world.info.serverKey))
        #expect(cert.expiresAt - cert.issuedAt == 30 * 86_400)
        #expect(cert.expiresSoon == false)
    }

    @Test("a wrong code is refused and issues nothing")
    func wrongCodeRefused() async throws {
        guard let world = try World.make() else { return }

        // A number used only here, so the shared roles keep their rate budget.
        let phone = "+351911222333"
        let harness = ServiceHarness.connected(info: world.info)
        defer { harness.stop() }

        _ = try await harness.service.requestVerificationCode(phone: phone)
        await #expect(throws: (any Error).self) {
            try await harness.service.confirmVerification(phone: phone, code: "000000")
        }
        #expect(harness.crypto.certificate == nil)
        #expect(harness.service.isRegistered == false)
    }

    @Test("an invalid phone number never reaches the server")
    func invalidPhoneRejectedLocally() async throws {
        guard let world = try World.make() else { return }
        let harness = ServiceHarness.connected(info: world.info)
        defer { harness.stop() }

        await #expect(throws: ServiceError.invalidPhone) {
            _ = try await harness.service.requestVerificationCode(phone: "12")
        }
        await #expect(throws: ServiceError.invalidPhone) {
            _ = try await harness.service.requestVerificationCode(phone: "abc")
        }
    }

    @Test("a certificate lookup returns only the certificate")
    func certificateLookup() async throws {
        guard let world = try World.make() else { return }
        let alice = try await world.party("alice", phone: alicePhone)
        _ = try await world.party("bob", phone: bobPhone, start: false)
        defer { alice.stop() }

        let client = world.client(for: alice.crypto)
        let found = try #require(try await client.lookupCertificate(phone: bobPhone))
        #expect(found.phone == bobPhone)
        #expect(found.isValid(serverKeyBase64: world.info.serverKey))

        // An unregistered number returns nothing at all.
        #expect(try await client.lookupCertificate(phone: "+351999888777") == nil)
    }
}

// MARK: - Messaging

@MainActor
@Suite("Integration — messaging through the relay", .serialized)
struct RelayIntegrationTests {

    @Test("a text message travels end to end and is receipted", .timeLimit(.minutes(2)))
    func textRoundTrip() async throws {
        guard let world = try World.make() else {
            withKnownIssue(ServerInfo.skipComment) { Issue.record("integration server absent") }
            return
        }

        let alice = try await world.party("alice", phone: alicePhone)
        let bob = try await world.party("bob", phone: bobPhone)
        defer { alice.stop(); bob.stop() }
        await world.drain(alice)
        await world.drain(bob)

        _ = try await alice.service.addContact(phone: bobPhone, name: "Bob")
        let body = "integration hello \(UUID().uuidString.prefix(8))"
        await alice.service.sendText(body, to: bobPhone)

        // Bob's relay loop picks it up, decrypts it and persists it.
        let arrived = await waitUntil(timeout: 45) {
            bob.store.thread(alicePhone).contains { $0.body == body }
        }
        #expect(arrived, "the message never reached Bob")

        let received = try #require(bob.store.thread(alicePhone).first { $0.body == body })
        #expect(received.isFromMe == false)
        #expect(received.fromPhone == alicePhone)
        #expect(received.status == .delivered)
        #expect(received.isRead == false)
        #expect(bob.store.unreadCount(alicePhone) == 1)

        // Bob's delivery receipt travels back and moves Alice's status on.
        let delivered = await waitUntil(timeout: 45) {
            alice.store.thread(bobPhone).first { $0.body == body }?.status == .delivered
        }
        #expect(delivered, "Alice never saw the delivery receipt")

        // Reading the thread sends a read receipt.
        bob.service.markRead(conversationID: alicePhone)
        #expect(bob.store.unreadCount(alicePhone) == 0)

        let read = await waitUntil(timeout: 45) {
            alice.store.thread(bobPhone).first { $0.body == body }?.status == .read
        }
        #expect(read, "Alice never saw the read receipt")
    }

    @Test("a reply keeps its link to the original on both devices", .timeLimit(.minutes(2)))
    func replyRoundTrip() async throws {
        guard let world = try World.make() else {
            withKnownIssue(ServerInfo.skipComment) { Issue.record("integration server absent") }
            return
        }

        let alice = try await world.party("alice", phone: alicePhone)
        let bob = try await world.party("bob", phone: bobPhone)
        defer { alice.stop(); bob.stop() }
        await world.drain(alice)
        await world.drain(bob)

        _ = try await alice.service.addContact(phone: bobPhone, name: "Bob")
        let original = "question \(UUID().uuidString.prefix(8))"
        await alice.service.sendText(original, to: bobPhone)

        let arrived = await waitUntil(timeout: 45) {
            bob.store.thread(alicePhone).contains { $0.body == original }
        }
        #expect(arrived, "the original never reached Bob")
        let originalID = try #require(bob.store.thread(alicePhone).first { $0.body == original }?.id)
        // Both sides store the message under the same id — replies depend on it.
        #expect(alice.store.thread(bobPhone).contains { $0.id == originalID })

        let answer = "answer \(UUID().uuidString.prefix(8))"
        await bob.service.sendText(answer, to: alicePhone, replyingTo: originalID)
        #expect(bob.store.thread(alicePhone).first { $0.body == answer }?.replyToID == originalID)

        let replied = await waitUntil(timeout: 45) {
            alice.store.thread(bobPhone).contains { $0.body == answer }
        }
        #expect(replied, "the reply never reached Alice")
        #expect(alice.store.thread(bobPhone).first { $0.body == answer }?.replyToID == originalID)
    }

    @Test("an image within the size limit survives the round trip", .timeLimit(.minutes(2)))
    func imageRoundTrip() async throws {
        guard let world = try World.make() else { return }
        let alice = try await world.party("alice", phone: alicePhone)
        let bob = try await world.party("bob", phone: bobPhone)
        defer { alice.stop(); bob.stop() }
        await world.drain(bob)

        _ = try await alice.service.addContact(phone: bobPhone, name: "Bob")
        // A small but non-trivial "JPEG".
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        jpeg.append(Data((0..<8_000).map { UInt8($0 % 251) }))
        #expect(jpeg.count <= ChatPayload.maxImageBytes)

        await alice.service.sendImage(jpeg, to: bobPhone)

        let arrived = await waitUntil(timeout: 45) {
            bob.store.thread(alicePhone).contains { $0.kind == .image }
        }
        #expect(arrived, "the image never reached Bob")

        let received = try #require(bob.store.thread(alicePhone).last { $0.kind == .image })
        let filename = try #require(received.imageFilename)
        let data = try Data(contentsOf: bob.store.imageURL(filename))
        #expect(data == jpeg, "the image bytes changed in transit")
    }

    @Test("a group message fans out to both members", .timeLimit(.minutes(3)))
    func groupFanOut() async throws {
        guard let world = try World.make() else { return }
        let alice = try await world.party("alice", phone: alicePhone)
        let bob = try await world.party("bob", phone: bobPhone)
        let carol = try await world.party("carol", phone: carolPhone)
        defer { alice.stop(); bob.stop(); carol.stop() }
        await world.drain(bob)
        await world.drain(carol)

        _ = try await alice.service.addContact(phone: bobPhone, name: "Bob")
        _ = try await alice.service.addContact(phone: carolPhone, name: "Carol")

        let group = try await alice.service.createGroup(name: "Integration Trip",
                                                        members: [bobPhone, carolPhone])
        #expect(group.members.count == 3)
        #expect(group.admins == [alicePhone])

        // Both members must materialise the group from the groupCreate payload.
        let known = await waitUntil(timeout: 45) {
            bob.store.group(id: group.id) != nil && carol.store.group(id: group.id) != nil
        }
        #expect(known, "the group never reached both members")

        let cid = ConversationStore.conversationID(group: group.id)
        let body = "group hello \(UUID().uuidString.prefix(8))"
        await alice.service.sendText(body, to: cid)

        let bobGot = await waitUntil(timeout: 45) {
            bob.store.thread(cid).contains { $0.body == body }
        }
        let carolGot = await waitUntil(timeout: 45) {
            carol.store.thread(cid).contains { $0.body == body }
        }
        #expect(bobGot, "Bob never received the group message")
        #expect(carolGot, "Carol never received the group message")
    }

    @Test("a blocked sender's message never appears and gets no receipt",
          .timeLimit(.minutes(2)))
    func blockingWorksEndToEnd() async throws {
        guard let world = try World.make() else { return }
        let alice = try await world.party("alice", phone: alicePhone)
        let bob = try await world.party("bob", phone: bobPhone)
        defer { alice.stop(); bob.stop() }
        await world.drain(bob)

        bob.service.block(phone: alicePhone)
        #expect(bob.store.isBlocked(alicePhone))

        _ = try await alice.service.addContact(phone: bobPhone, name: "Bob")
        let body = "blocked message \(UUID().uuidString.prefix(8))"
        await alice.service.sendText(body, to: bobPhone)

        // Give the relay ample time to deliver it to Bob's client.
        try await Task.sleep(nanoseconds: 8_000_000_000)

        #expect(bob.store.thread(alicePhone).contains { $0.body == body } == false,
                "a blocked sender's message must never be stored")
        #expect(bob.store.totalUnreadCount == 0)
        #expect(alice.store.thread(bobPhone).first { $0.body == body }?.status != .delivered,
                "a blocked sender must not receive a delivery receipt")
    }

    @Test("a renewed certificate keeps messaging working", .timeLimit(.minutes(2)))
    func certificateRenewalKeepsWorking() async throws {
        guard let world = try World.make() else { return }
        let alice = try await world.party("alice", phone: alicePhone)
        let bob = try await world.party("bob", phone: bobPhone)
        defer { alice.stop(); bob.stop() }
        await world.drain(bob)

        let before = try #require(alice.crypto.certificate)

        // Rotate the agreement key and take a fresh certificate for it.
        let client = world.client(for: alice.crypto)
        let pending = try alice.crypto.prepareAgreementRotationOrThrow()
        let renewed = try await client.renewCertificate(agreementKey: pending)
        #expect(renewed.signingKey == before.signingKey)
        #expect(renewed.agreementKey == pending)
        #expect(renewed.serial != before.serial)
        #expect(renewed.isValid(serverKeyBase64: world.info.serverKey))
        try alice.crypto.commitAgreementRotation(certificate: renewed)
        IntegrationIdentities.shared.update(role: "alice", from: alice)

        // The old key still opens mail, and new mail uses the new one.
        _ = try await alice.service.addContact(phone: bobPhone, name: "Bob")
        let body = "after rotation \(UUID().uuidString.prefix(8))"
        await alice.service.sendText(body, to: bobPhone)

        let arrived = await waitUntil(timeout: 45) {
            bob.store.thread(alicePhone).contains { $0.body == body }
        }
        #expect(arrived, "a message sealed after rotation failed to decrypt")
    }
}

// MARK: - Key change

@MainActor
@Suite("Integration — key change blocks sending", .serialized)
struct KeyChangeIntegrationTests {

    @Test("an unacknowledged key change refuses to send until accepted",
          .timeLimit(.minutes(3)))
    func keyChangeBlocksSending() async throws {
        guard let world = try World.make() else {
            withKnownIssue(ServerInfo.skipComment) { Issue.record("integration server absent") }
            return
        }

        // A dedicated number: this identity is deliberately re-registered.
        let phone = "+351933444555"
        let bob = try await world.party("bob", phone: bobPhone)
        defer { bob.stop() }

        // First identity, and Bob pins it.
        let firstBacking = SharedMemoryStore()
        let first = ServiceHarness.connected(info: world.info, secureStore: firstBacking)
        _ = try await first.service.requestVerificationCode(phone: phone)
        try await first.service.confirmVerification(phone: phone, code: world.info.fixedCode)
        let firstCert = try #require(first.crypto.certificate)
        bob.trust.evaluate(firstCert)
        #expect(bob.trust.pinnedSigningKey(for: phone) == firstCert.signingKey)
        first.stop()

        // The contact "reinstalls": same number, brand-new keys.
        let second = ServiceHarness.connected(info: world.info)
        defer { second.stop() }
        _ = try await second.service.requestVerificationCode(phone: phone)
        try await second.service.confirmVerification(phone: phone, code: world.info.fixedCode)
        let secondCert = try #require(second.crypto.certificate)
        #expect(secondCert.signingKey != firstCert.signingKey)

        // Bob refreshes and sees the change: sending must now be refused.
        await bob.service.refreshCertificate(for: phone)
        #expect(bob.trust.hasPendingKeyChange(phone),
                "a changed signing key must raise a pending key change")
        #expect(bob.service.isEncryptionReady(for: phone) == false)

        bob.service.lastError = nil
        await bob.service.sendText("should not go out", to: phone)
        let blocked = bob.store.thread(phone).first { $0.body == "should not go out" }
        #expect(blocked?.status == .pending, "the message must not be marked sent")
        #expect(bob.service.lastError == ServiceError.keyChangeUnacknowledged.errorDescription,
                "the user must be told why sending was refused")

        func status(_ body: String, in cid: String) -> MessageStatus? {
            bob.store.thread(cid).first { $0.body == body }?.status
        }
        _ = blocked

        // A group that includes the changed contact: its message is held too.
        let group = try await bob.service.createGroup(name: "Key change group", members: [phone])
        let groupCID = ConversationStore.conversationID(group: group.id)
        await bob.service.sendText("group message held", to: groupCID)
        #expect(status("group message held", in: groupCID) == .pending,
                "a group message whose only recipient has a pending key change must be held")

        // Accepting the new key sends both held messages immediately — well
        // under the 30–60 s per-message backoff.
        let accepted = Date()
        await bob.service.acceptKeyChange(phone: phone)
        #expect(bob.trust.hasPendingKeyChange(phone) == false)
        #expect(bob.trust.pinnedSigningKey(for: phone) == secondCert.signingKey)

        let sent = await waitUntil(timeout: 10) {
            status("should not go out", in: phone) != .pending
                && status("group message held", in: groupCID) != .pending
        }
        let elapsed = Date().timeIntervalSince(accepted)
        #expect(sent, "held messages must go out as soon as the key change is accepted")
        #expect(elapsed < 15, "held messages took \(elapsed) s to send after acceptance")
        for (body, cid) in [("should not go out", phone), ("group message held", groupCID)] {
            let s = status(body, in: cid)
            #expect(s == .sent || s == .delivered || s == .read, "\(body): \(String(describing: s))")
        }

        // The reinstalled contact really receives the 1:1 message.
        let received = await waitUntil(timeout: 30) {
            second.store.thread(bobPhone).contains { $0.body == "should not go out" }
        }
        #expect(received, "the held 1:1 message never reached the contact")
    }
}

// MARK: - Account deletion

@MainActor
@Suite("Integration — account deletion", .serialized)
struct AccountDeletionIntegrationTests {

    @Test("deleteAccountAndWipe purges the server and the device",
          .timeLimit(.minutes(2)))
    func deleteAccountPurgesEverything() async throws {
        guard let world = try World.make() else {
            withKnownIssue(ServerInfo.skipComment) { Issue.record("integration server absent") }
            return
        }

        let phone = "+351955666777"
        let victimBacking = SharedMemoryStore()
        let victim = ServiceHarness.connected(info: world.info, secureStore: victimBacking)
        defer { victim.stop() }
        _ = try await victim.service.requestVerificationCode(phone: phone)
        try await victim.service.confirmVerification(phone: phone, code: world.info.fixedCode)

        // Before deletion the server knows the number (proves a real round-trip).
        let bob = try await world.party("bob", phone: bobPhone, start: false)
        let bobClient = world.client(for: bob.crypto)
        let before = try await bobClient.lookupCertificate(phone: phone)
        #expect(before?.phone == phone, "the victim should be registered before deletion")

        // Keep a copy of the victim's credentials to try them after deletion.
        let staleClient = world.client(
            for: CryptoManager(store: SharedMemoryStore(items: victimBacking.snapshot)))

        victim.store.addContact(Contact(phone: bobPhone, name: "Bob"))
        victim.store.appendMessage(
            StoredMessage(id: UUID().uuidString, conversationID: bobPhone,
                          fromPhone: bobPhone, toPhone: phone,
                          body: "to be wiped", isFromMe: false))
        await victim.store.flush()

        try await victim.service.deleteAccountAndWipe()

        // Local state is gone.
        #expect(victim.service.isRegistered == false)
        #expect(victim.service.myPhone.isEmpty)
        #expect(victim.crypto.certificate == nil)
        #expect(victim.store.contacts.isEmpty)
        #expect(victim.store.messages.isEmpty)
        #expect(victim.trust.pinnedCertificate(for: bobPhone) == nil)

        // The server no longer knows the number…
        #expect(try await bobClient.lookupCertificate(phone: phone) == nil,
                "a deleted account must not be discoverable")

        // …and the deleted account's certificate (revoked server-side) can no
        // longer authenticate anything.
        do {
            _ = try await staleClient.fetch(wait: 0, max: 1)
            Issue.record("a deleted account's certificate was still accepted by the server")
        } catch let error as ServerError {
            guard case .server(let code, _) = error else {
                Issue.record("expected a cert_invalid rejection, got \(error)")
                return
            }
            #expect(code == "cert_invalid", "expected cert_invalid, got \(code)")
        }
    }
}

// MARK: - Attacks

@MainActor
@Suite("Integration — attacks are rejected", .serialized)
struct AttackIntegrationTests {

    /// Deposits a raw envelope as `sender`, bypassing the send pipeline.
    private func deposit(_ envelope: Envelope,
                         as sender: ServiceHarness,
                         world: World) async throws {
        try await world.client(for: sender.crypto).deposit(envelope)
    }

    @Test("the server refuses an envelope signed by another key")
    func serverRejectsForeignSignature() async throws {
        guard let world = try World.make() else {
            withKnownIssue(ServerInfo.skipComment) { Issue.record("integration server absent") }
            return
        }
        let alice = try await world.party("alice", phone: alicePhone, start: false)
        let bob = try await world.party("bob", phone: bobPhone, start: false)
        defer { alice.stop(); bob.stop() }

        let bobCert = try #require(bob.crypto.certificate)
        let envelope = try alice.crypto.seal(
            try ChatPayload(kind: .text, text: "hi").encoded(),
            envelopeID: UUID().uuidString,
            recipientPhone: bobPhone,
            recipientCert: bobCert,
            timestamp: Int64(Date().timeIntervalSince1970))

        let forged = EnvelopeFactory.mutate(
            envelope,
            signature: try Curve25519.Signing.PrivateKey()
                .signature(for: Canonical.encode(envelope.signedFields))
                .base64EncodedString())

        await #expect(throws: ServerError.self) {
            try await deposit(forged, as: alice, world: world)
        }
    }

    @Test("the server refuses an envelope whose sender is not the depositor")
    func serverRejectsSenderMismatch() async throws {
        guard let world = try World.make() else { return }
        let alice = try await world.party("alice", phone: alicePhone, start: false)
        let bob = try await world.party("bob", phone: bobPhone, start: false)
        let carol = try await world.party("carol", phone: carolPhone, start: false)
        defer { alice.stop(); bob.stop(); carol.stop() }

        let bobCert = try #require(bob.crypto.certificate)
        // Carol seals real mail, then claims Alice sent it.
        let envelope = try carol.crypto.seal(
            try ChatPayload(kind: .text, text: "I am alice").encoded(),
            envelopeID: UUID().uuidString,
            recipientPhone: bobPhone,
            recipientCert: bobCert,
            timestamp: Int64(Date().timeIntervalSince1970))
        let spoofed = EnvelopeFactory.mutate(envelope, senderPhone: alicePhone)

        await #expect(throws: ServerError.self) {
            try await deposit(spoofed, as: carol, world: world)
        }
        _ = alice
    }

    @Test("the server refuses a superseded certificate")
    func supersededCertificateRejected() async throws {
        guard let world = try World.make() else { return }

        let phone = "+351977888999"
        let backing = SharedMemoryStore()
        let harness = ServiceHarness.connected(info: world.info, secureStore: backing)
        defer { harness.stop() }
        _ = try await harness.service.requestVerificationCode(phone: phone)
        try await harness.service.confirmVerification(phone: phone, code: world.info.fixedCode)

        // Keep a client still holding the pre-renewal certificate.
        let staleCrypto = CryptoManager(store: SharedMemoryStore(items: backing.snapshot))
        let staleClient = world.client(for: staleCrypto)
        let oldSerial = try #require(staleCrypto.certificate).serial

        let pending = try harness.crypto.prepareAgreementRotationOrThrow()
        let renewed = try await world.client(for: harness.crypto)
            .renewCertificate(agreementKey: pending)
        try harness.crypto.commitAgreementRotation(certificate: renewed)
        #expect(renewed.serial != oldSerial)

        // The old certificate stops working immediately, not only at expiry.
        await #expect(throws: ServerError.self) {
            _ = try await staleClient.lookupCertificate(phone: bobPhone)
        }
    }

    @Test("a client drops an envelope carrying a self-signed certificate",
          .timeLimit(.minutes(2)))
    func clientRejectsForgedCertificate() async throws {
        guard let world = try World.make() else { return }
        let bob = try await world.party("bob", phone: bobPhone)
        let carol = try await world.party("carol", phone: carolPhone, start: false)
        defer { bob.stop(); carol.stop() }
        await world.drain(bob)

        let bobCert = try #require(bob.crypto.certificate)
        let envelope = try carol.crypto.seal(
            try ChatPayload(kind: .text, text: "forged cert message").encoded(),
            envelopeID: UUID().uuidString,
            recipientPhone: bobPhone,
            recipientCert: bobCert,
            timestamp: Int64(Date().timeIntervalSince1970))

        // Carol replaces her real certificate with one she signed herself. The
        // server only checks the signature against the *wire* certificate, so
        // this is accepted for relay — the client must refuse it.
        let selfSigned = IdentityFactory.makeCertificate(
            phone: carolPhone,
            signingKey: carol.crypto.signingPublicKeyBase64,
            agreementKey: carol.crypto.agreementPublicKeyBase64,
            serverKey: Curve25519.Signing.PrivateKey())
        let forged = EnvelopeFactory.mutate(envelope,
                                            senderCertificate: selfSigned.encodedJSON())

        #expect(await bob.service.processIncoming(forged) == .rejected)
        #expect(bob.store.thread(carolPhone).contains { $0.body == "forged cert message" } == false)
    }

    @Test("a replayed envelope is stored only once", .timeLimit(.minutes(2)))
    func replayedEnvelopeStoredOnce() async throws {
        guard let world = try World.make() else { return }
        let alice = try await world.party("alice", phone: alicePhone, start: false)
        let bob = try await world.party("bob", phone: bobPhone)
        defer { alice.stop(); bob.stop() }
        await world.drain(bob)

        let bobCert = try #require(bob.crypto.certificate)
        let body = "replay me \(UUID().uuidString.prefix(8))"
        let envelope = try alice.crypto.seal(
            try ChatPayload(kind: .text, text: body,
                            sentAt: Int64(Date().timeIntervalSince1970)).encoded(),
            envelopeID: UUID().uuidString,
            recipientPhone: bobPhone,
            recipientCert: bobCert,
            timestamp: Int64(Date().timeIntervalSince1970))

        // Deliver it twice through the real relay (ack in between, so the
        // second deposit is accepted rather than deduplicated server-side).
        try await deposit(envelope, as: alice, world: world)
        let first = await waitUntil(timeout: 45) {
            bob.store.thread(alicePhone).contains { $0.body == body }
        }
        #expect(first, "the first copy never arrived")

        try await deposit(envelope, as: alice, world: world)
        try await Task.sleep(nanoseconds: 6_000_000_000)

        let copies = bob.store.thread(alicePhone).filter { $0.body == body }
        #expect(copies.count == 1, "a replayed envelope must be stored once, got \(copies.count)")
    }

    @Test("a stale envelope is refused by the client", .timeLimit(.minutes(2)))
    func staleEnvelopeRefused() async throws {
        guard let world = try World.make() else { return }
        let alice = try await world.party("alice", phone: alicePhone, start: false)
        let bob = try await world.party("bob", phone: bobPhone)
        defer { alice.stop(); bob.stop() }

        let bobCert = try #require(bob.crypto.certificate)
        let ancient = Int64(Date().timeIntervalSince1970) - 8 * 86_400
        let envelope = try alice.crypto.seal(
            try ChatPayload(kind: .text, text: "very old news").encoded(),
            envelopeID: UUID().uuidString,
            recipientPhone: bobPhone,
            recipientCert: bobCert,
            timestamp: ancient)

        #expect(await bob.service.processIncoming(envelope) == .rejected)
        #expect(bob.store.thread(alicePhone).contains { $0.body == "very old news" } == false)
    }

    @Test("a tampered header is refused by the client", .timeLimit(.minutes(2)))
    func tamperedHeaderRefused() async throws {
        guard let world = try World.make() else { return }
        let alice = try await world.party("alice", phone: alicePhone, start: false)
        let bob = try await world.party("bob", phone: bobPhone)
        defer { alice.stop(); bob.stop() }

        let bobCert = try #require(bob.crypto.certificate)
        let envelope = try alice.crypto.seal(
            try ChatPayload(kind: .text, text: "tamper target").encoded(),
            envelopeID: UUID().uuidString,
            recipientPhone: bobPhone,
            recipientCert: bobCert,
            timestamp: Int64(Date().timeIntervalSince1970))

        let other = Curve25519.KeyAgreement.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        let tampered = EnvelopeFactory.mutate(envelope, recipientAgreementKey: other)

        #expect(await bob.service.processIncoming(tampered) == .rejected)
        #expect(bob.store.thread(alicePhone).contains { $0.body == "tamper target" } == false)
    }
}

// MARK: - Ack policy (the message-loss regression)

@MainActor
@Suite("Integration — transient drops are never acked", .serialized)
struct AckPolicyIntegrationTests {

    /// Fetches without acking, so the test can see what is still queued.
    private func peekMailbox(_ harness: ServiceHarness, world: World) async throws -> [Envelope] {
        try await world.client(for: harness.crypto).fetch(wait: 0, max: 50)
    }

    @Test("a locked Keychain leaves the mail on the relay", .timeLimit(.minutes(3)))
    func lockedKeychainDoesNotAck() async throws {
        guard let world = try World.make() else {
            withKnownIssue(ServerInfo.skipComment) { Issue.record("integration server absent") }
            return
        }

        let alice = try await world.party("alice", phone: alicePhone, start: false)
        defer { alice.stop() }

        // Bob's identity is readable, but his TRUST store is not — exactly the
        // background-fetch-before-first-unlock case.
        let bobSnapshot = try await IntegrationIdentities.shared.snapshot(role: "bob",
                                                                          phone: bobPhone,
                                                                          info: world.info)
        let lockedTrust = ThrowingSecureStore(isAvailable: false)
        let bob = ServiceHarness.connected(info: world.info,
                                           trustBacking: lockedTrust,
                                           secureStore: SharedMemoryStore(items: bobSnapshot))
        defer { bob.stop() }
        await bob.service.start()

        // Clear anything queued from earlier tests, with a working trust store.
        let cleaner = try await world.party("bob", phone: bobPhone)
        await world.drain(cleaner)
        cleaner.stop()

        let bobCert = try #require(bob.crypto.certificate)
        let body = "must survive a locked keychain \(UUID().uuidString.prefix(8))"
        let envelope = try alice.crypto.seal(
            try ChatPayload(kind: .text, text: body,
                            sentAt: Int64(Date().timeIntervalSince1970)).encoded(),
            envelopeID: UUID().uuidString,
            recipientPhone: bobPhone,
            recipientCert: bobCert,
            timestamp: Int64(Date().timeIntervalSince1970))
        try await world.client(for: alice.crypto).deposit(envelope)

        // Bob fetches while locked: nothing is stored, and nothing is acked.
        _ = await bob.service.performBackgroundFetch()
        try await Task.sleep(nanoseconds: 3_000_000_000)

        #expect(bob.store.thread(alicePhone).contains { $0.body == body } == false,
                "an undecidable envelope must not be stored")
        #expect(bob.store.hasSeenEnvelope(envelope.id) == false,
                "a deferred envelope must not be recorded as seen")

        let stillQueued = try await peekMailbox(bob, world: world)
        #expect(stillQueued.contains { $0.id == envelope.id },
                "THE REGRESSION: the relay copy was acked away while the Keychain was locked")

        // Device unlocked: the same envelope is delivered for real.
        lockedTrust.isAvailable = true
        let delivered = await waitUntil(timeout: 60) {
            _ = await bob.service.performBackgroundFetch()
            return bob.store.thread(alicePhone).contains { $0.body == body }
        }
        #expect(delivered, "the deferred message never arrived after unlocking")
    }

    @Test("permanent rejections drain the mailbox", .timeLimit(.minutes(3)))
    func rejectionsAreAcked() async throws {
        guard let world = try World.make() else { return }

        let carol = try await world.party("carol", phone: carolPhone, start: false)
        defer { carol.stop() }

        // A fresh receiver whose mailbox we control.
        let phone = "+351966777888"
        let receiver = ServiceHarness.connected(info: world.info)
        defer { receiver.stop() }
        _ = try await receiver.service.requestVerificationCode(phone: phone)
        try await receiver.service.confirmVerification(phone: phone, code: world.info.fixedCode)
        receiver.service.stop()

        let receiverCert = try #require(receiver.crypto.certificate)

        // An envelope the receiver can never accept: a self-signed certificate.
        let envelope = try carol.crypto.seal(
            try ChatPayload(kind: .text, text: "forever invalid").encoded(),
            envelopeID: UUID().uuidString,
            recipientPhone: phone,
            recipientCert: receiverCert,
            timestamp: Int64(Date().timeIntervalSince1970))
        let selfSigned = IdentityFactory.makeCertificate(
            phone: carolPhone,
            signingKey: carol.crypto.signingPublicKeyBase64,
            agreementKey: carol.crypto.agreementPublicKeyBase64,
            serverKey: Curve25519.Signing.PrivateKey())
        let poisoned = EnvelopeFactory.mutate(envelope,
                                              senderCertificate: selfSigned.encodedJSON())
        try await world.client(for: carol.crypto).deposit(poisoned)

        // One fetch settles it; the mailbox must then be empty rather than
        // serving the same poison envelope forever.
        _ = await receiver.service.performBackgroundFetch()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let remaining = try await world.client(for: receiver.crypto).fetch(wait: 0, max: 50)
        #expect(remaining.contains { $0.id == poisoned.id } == false,
                "a permanently invalid envelope must be acked, not retried forever")
        #expect(receiver.store.thread(carolPhone).isEmpty)
    }

    @Test("an all-deferred batch does not spin the relay loop", .timeLimit(.minutes(3)))
    func deferredBatchDoesNotHotLoop() async throws {
        guard let world = try World.make() else { return }

        let alice = try await world.party("alice", phone: alicePhone, start: false)
        defer { alice.stop() }

        let bobSnapshot = try await IntegrationIdentities.shared.snapshot(role: "bob",
                                                                          phone: bobPhone,
                                                                          info: world.info)
        let lockedTrust = ThrowingSecureStore(isAvailable: false)
        let bob = ServiceHarness.connected(info: world.info,
                                           trustBacking: lockedTrust,
                                           secureStore: SharedMemoryStore(items: bobSnapshot))
        defer { bob.stop() }

        let bobCert = try #require(bob.crypto.certificate)
        for i in 0..<3 {
            let envelope = try alice.crypto.seal(
                try ChatPayload(kind: .text, text: "deferred \(i)").encoded(),
                envelopeID: UUID().uuidString,
                recipientPhone: bobPhone,
                recipientCert: bobCert,
                timestamp: Int64(Date().timeIntervalSince1970))
            try await world.client(for: alice.crypto).deposit(envelope)
        }

        // Run the real relay loop for a few seconds against an all-deferred
        // mailbox. With backoff this is a handful of fetches; without it, the
        // loop would spin as fast as the network allows.
        let started = Date()
        await bob.service.start()
        try await Task.sleep(nanoseconds: 6_000_000_000)
        bob.service.stop()
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed >= 6, "the loop should have run for the full window")
        #expect(bob.store.messages.isEmpty, "nothing should have been stored while deferred")

        // Everything is still on the relay, ready for a later unlock.
        lockedTrust.isAvailable = true
        let queued = try await world.client(for: bob.crypto).fetch(wait: 0, max: 50)
        #expect(queued.count >= 3, "deferred mail must still be queued, got \(queued.count)")
    }
}
