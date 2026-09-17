//
//  LANDeliveryTests.swift
//  HopChat-1Tests
//
//  Direct phone-to-phone delivery with NO server reachable.
//
//  Two running `KademliaService` instances share one process: each publishes
//  and browses `_hopchat._tcp`, completes the signed hello exchange (which
//  pins the other's certificate, TOFU) and then delivers `directEnvelope`s over
//  TCP. Both servers point at a closed loopback port, so anything that
//  arrives can only have come over the LAN.
//
//  Both certificates are signed by the same throwaway server key, so each
//  service accepts the other's. Each test uses its own phone numbers and its
//  own services, torn down at the end.
//
//  If Bonjour is unavailable in the test environment (no local-network
//  access), discovery never completes and every test records a known issue
//  instead of failing — unless HOPCHAT_REQUIRE_LAN=1, which makes it a failure.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

// MARK: - A pair of running LAN peers

@MainActor
private struct LANPair {
    let alice: ServiceHarness      // sender
    let bob: ServiceHarness        // receiver

    struct DiscoveryFailed: Error, CustomStringConvertible {
        var description: String {
            "HOPCHAT_REQUIRE_LAN=1 but the two services never discovered each other over Bonjour"
        }
    }

    static let skipComment: Comment = """
        The two services never discovered each other: Bonjour / local-network \
        access looks unavailable here. Skipping the LAN delivery suite.
        """

    static func make(alicePhone: String, bobPhone: String) async throws -> LANPair {
        let server = Curve25519.Signing.PrivateKey()
        let alice = try await ServiceHarness.running(phone: alicePhone, serverKey: server)
        let bob = try await ServiceHarness.running(phone: bobPhone, serverKey: server)
        #expect(alice.service.isRegistered)
        #expect(bob.service.isRegistered)
        return LANPair(alice: alice, bob: bob)
    }

    /// Waits for the authenticated hello in both directions. `false` means
    /// Bonjour never got there (the caller skips); throws when the
    /// environment demands LAN.
    func discover(timeout: TimeInterval = 30) async throws -> Bool {
        let found = await waitUntil(timeout: timeout, interval: 0.2) {
            alice.service.presenceMap[bob.phone] == .online
                && bob.service.presenceMap[alice.phone] == .online
        }
        if !found, ProcessInfo.processInfo.environment["HOPCHAT_REQUIRE_LAN"] == "1" {
            throw DiscoveryFailed()
        }
        return found
    }

    func stop() {
        alice.stop()
        bob.stop()
    }

    func aliceCopy(_ id: String) -> StoredMessage? {
        alice.store.thread(ConversationStore.conversationID(peer: bob.phone))
            .first { $0.id == id }
    }

    var bobThread: [StoredMessage] {
        bob.store.thread(ConversationStore.conversationID(peer: alice.phone))
    }
}

// MARK: - Suite

@MainActor
@Suite("LAN — direct delivery without a server", .serialized, .timeLimit(.minutes(2)))
struct LANDeliveryTests {

    @Test("peers discover and authenticate each other over Bonjour")
    func peersDiscoverEachOther() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000001",
                                          bobPhone: "+351910000002")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        #expect(pair.alice.service.presenceMap[pair.bob.phone] == .online)
        #expect(pair.bob.service.presenceMap[pair.alice.phone] == .online)
        // The hello exchange pinned each side's certificate (TOFU).
        #expect(pair.alice.trust.pinnedCertificate(for: pair.bob.phone)?.signingKey
                == pair.bob.certificate?.signingKey)
        #expect(pair.bob.trust.pinnedCertificate(for: pair.alice.phone)?.signingKey
                == pair.alice.certificate?.signingKey)
        // Nobody helloed themselves.
        #expect(pair.alice.service.presenceMap[pair.alice.phone] == nil)
        #expect(pair.bob.service.presenceMap[pair.bob.phone] == nil)
    }

    @Test("a text message is delivered directly and receipted, with no server")
    func directTextDelivery() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000011",
                                          bobPhone: "+351910000012")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        await pair.alice.service.sendText("hello over wifi",
                                          to: ConversationStore.conversationID(peer: pair.bob.phone))
        let sent = try #require(pair.alice.store
            .thread(ConversationStore.conversationID(peer: pair.bob.phone))
            .last { $0.isFromMe })

        // Bob has it — and only the LAN could have carried it.
        let arrived = await waitUntil(timeout: 10) {
            pair.bobThread.contains { $0.id == sent.id }
        }
        #expect(arrived, "bob never received the direct message")
        let received = try #require(pair.bobThread.first { $0.id == sent.id })
        #expect(received.body == "hello over wifi")
        #expect(received.isFromMe == false)
        #expect(received.fromPhone == pair.alice.phone)
        #expect(received.route == .direct, "receiver's copy should be marked as a direct delivery")

        // Alice's copy left the queue over the LAN.
        let aliceCopy = try #require(pair.aliceCopy(sent.id))
        #expect([.sent, .delivered, .read].contains(aliceCopy.status))
        #expect(aliceCopy.route == .direct, "sender's copy should be marked as a direct delivery")

        // Bob's delivery receipt also travels over the LAN.
        let receipted = await waitUntil(timeout: 10) {
            [.delivered, .read].contains(pair.aliceCopy(sent.id)?.status)
        }
        #expect(receipted, "alice never saw the delivery receipt (status: \(String(describing: pair.aliceCopy(sent.id)?.status)))")
    }

    @Test("a blocked sender's direct message is not stored")
    func blockedSenderIsDropped() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000021",
                                          bobPhone: "+351910000022")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        // Bob blocks alice after discovery; alice still has bob as a LAN peer,
        // so her send really reaches bob's listener and is refused there.
        pair.bob.service.block(phone: pair.alice.phone)
        #expect(pair.bob.store.isBlocked(pair.alice.phone))

        await pair.alice.service.sendText("you blocked me",
                                          to: ConversationStore.conversationID(peer: pair.bob.phone))
        let sent = try #require(pair.alice.store
            .thread(ConversationStore.conversationID(peer: pair.bob.phone))
            .last { $0.isFromMe })

        // Give a stray delivery every chance to land.
        let leaked = await waitUntil(timeout: 3) {
            pair.bobThread.contains { $0.id == sent.id }
        }
        #expect(!leaked, "a blocked sender's message was stored")
        #expect(pair.bobThread.isEmpty)

        // No ack came back, so alice's copy is still queued, not "sent".
        let aliceCopy = try #require(pair.aliceCopy(sent.id))
        #expect(aliceCopy.status == .pending)
        #expect(aliceCopy.route != .direct)
    }

    @Test("sending to a known LAN peer doesn't wait on the unreachable server")
    func sendIsFastWithoutServer() async throws {
        let pair = try await LANPair.make(alicePhone: "+351910000031",
                                          bobPhone: "+351910000032")
        defer { pair.stop() }

        guard try await pair.discover() else {
            withKnownIssue(LANPair.skipComment) { Issue.record("Bonjour unavailable") }
            return
        }

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await pair.alice.service.sendText("quick",
                                              to: ConversationStore.conversationID(peer: pair.bob.phone))
        }
        #expect(elapsed < .seconds(5), "sendText took \(elapsed) with a LAN peer available")

        let sent = try #require(pair.alice.store
            .thread(ConversationStore.conversationID(peer: pair.bob.phone))
            .last { $0.isFromMe })
        #expect([.sent, .delivered, .read].contains(pair.aliceCopy(sent.id)?.status))
        let arrived = await waitUntil(timeout: 10) {
            pair.bobThread.contains { $0.id == sent.id }
        }
        #expect(arrived)
    }
}
