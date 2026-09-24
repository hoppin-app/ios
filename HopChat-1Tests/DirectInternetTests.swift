//
//  DirectInternetTests.swift
//  HopChat-1Tests
//
//  Reaching a contact directly across networks over IPv6 (contract §10).
//
//  Bonjour can't cross a router, so two phones on different Wi-Fi networks
//  used to have only the relay. Now each side publishes where it can be
//  reached, inside a sealed envelope, and delivery is attempted there first.
//
//  The address layer is tested as pure functions; the delivery path is tested
//  for real, over IPv6 loopback with no Bonjour involved — which is exactly
//  the shape of a cross-network send: an address learned out of band, dialled
//  directly.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

// MARK: - Which addresses may be published

@Suite("Direct — addresses worth publishing")
struct DirectAddressTests {

    @Test("only global unicast IPv6 is publishable")
    func globalOnly() {
        #expect(DirectAddress.isGloballyRoutable("2001:db8::1"))
        #expect(DirectAddress.isGloballyRoutable("2a00:1450:4003:80c::200e"))
        #expect(DirectAddress.isGloballyRoutable("3ffe::1"))

        // Everything a peer on another network cannot reach.
        #expect(!DirectAddress.isGloballyRoutable("::1"), "loopback")
        #expect(!DirectAddress.isGloballyRoutable("fe80::1"), "link-local is the LAN path's job")
        #expect(!DirectAddress.isGloballyRoutable("fe80::1%en0"), "a scope is never routable")
        #expect(!DirectAddress.isGloballyRoutable("fd12:3456::1"), "unique-local")
        #expect(!DirectAddress.isGloballyRoutable("ff02::fb"), "multicast")
        #expect(!DirectAddress.isGloballyRoutable("::ffff:192.168.1.5"), "IPv4-mapped")
        #expect(!DirectAddress.isGloballyRoutable("192.168.1.5"), "IPv4 needs STUN, not this")
        #expect(!DirectAddress.isGloballyRoutable(""))
        #expect(!DirectAddress.isGloballyRoutable("not an address"))
    }

    @Test("a candidate is only built from something reachable and fresh")
    func candidates() {
        let now = Date()
        let soon = now.addingTimeInterval(600)

        let good = DirectAddress.candidate(from: ["fe80::1", "2001:db8::5"],
                                           port: 51234, expiresAt: soon, now: now)
        #expect(good?.address == "2001:db8::5", "the link-local one is skipped")
        #expect(good?.port == 51234)

        #expect(DirectAddress.candidate(from: [], port: 51234, expiresAt: soon, now: now) == nil)
        #expect(DirectAddress.candidate(from: ["fe80::1"], port: 51234,
                                        expiresAt: soon, now: now) == nil)
        #expect(DirectAddress.candidate(from: ["2001:db8::5"], port: 0,
                                        expiresAt: soon, now: now) == nil,
                "port 0 means the listener never bound")
        #expect(DirectAddress.candidate(from: ["2001:db8::5"], port: 51234,
                                        expiresAt: now.addingTimeInterval(-1), now: now) == nil,
                "already expired")
    }

    @Test("a contact cannot make us hold an address forever")
    func lifetimeIsCapped() {
        let now = Date()
        let greedy = now.addingTimeInterval(365 * 86_400)
        let candidate = DirectAddress.candidate(from: ["2001:db8::5"], port: 51234,
                                                expiresAt: greedy, now: now)
        let cap = now.addingTimeInterval(DirectAddress.maxAcceptedLifetime)
        #expect(candidate?.expiresAt == cap)
        #expect(candidate?.isFresh(at: cap.addingTimeInterval(1)) == false)
    }

    @Test("this machine's own addresses are all publishable")
    func localAddresses() {
        // Whatever this machine has, nothing unroutable may come back.
        for address in DirectAddress.local() {
            #expect(DirectAddress.isGloballyRoutable(address), "\(address) is not routable")
        }
        #expect(DirectAddress.local().count <= DirectAddress.maxAddresses)
        // Loopback is never offered, even though it is always up.
        #expect(!DirectAddress.local().contains("::1"))
    }
}

// MARK: - The hint on the wire

@MainActor
@Suite("Direct — the address hint")
struct AddressHintPayloadTests {

    private func hint(addresses: [String] = ["2001:db8::5"],
                      port: UInt16? = 51234,
                      expires: Int64? = Int64(Date().timeIntervalSince1970) + 600) -> ChatPayload {
        ChatPayload(kind: .addressHint, directAddresses: addresses,
                    directPort: port, directExpiresAt: expires)
    }

    @Test("it survives the wire unchanged")
    func roundTrip() throws {
        let payload = hint()
        let decoded = try #require(ChatPayload.decode(try payload.encoded()))
        #expect(decoded == payload)
        #expect(decoded.isWellFormed)
    }

    @Test("a malformed hint is refused")
    func malformed() {
        #expect(!hint(addresses: []).isWellFormed)
        #expect(!hint(port: nil).isWellFormed)
        #expect(!hint(port: 0).isWellFormed)
        #expect(!hint(expires: nil).isWellFormed)
        #expect(!hint(addresses: ["2001:db8::5", "2001:db8::6", "2001:db8::7"]).isWellFormed,
                "more addresses than we ever publish")
        #expect(!hint(addresses: [String(repeating: "a", count: 200)]).isWellFormed)
    }

    @Test("it is never stored, never receipted, and never sent over the mesh")
    func classification() {
        let payload = hint()
        #expect(payload.isTransient)
        #expect(!payload.isStoredMessage)
        #expect(!payload.isMeshEligible, "the mesh exists for when there is no internet")
        #expect(!payload.isDirectEligible, "a hint must go by the road that always works")
    }
}

// MARK: - Delivery

@MainActor
@Suite("Direct — delivery across networks", .serialized)
struct DirectDeliveryTests {

    /// Two registered services with no Bonjour between them, as if they were
    /// on different Wi-Fi networks. Bob is running (so his listener is up);
    /// Alice only knows what Bob tells her.
    @MainActor
    private struct Pair {
        let alice: ServiceHarness
        let bob: ServiceHarness

        static func make() async throws -> Pair {
            let server = Curve25519.Signing.PrivateKey()
            // Alice will dial loopback, which the real rule refuses: in the
            // app only a global IPv6 address is ever dialled.
            let alice = try await ServiceHarness.running(
                phone: "+351910000081", serverKey: server, enableLAN: false,
                dialableAddresses: { $0 == "::1" || DirectAddress.isGloballyRoutable($0) })
            let bob = try await ServiceHarness.running(phone: "+351910000082",
                                                       serverKey: server, enableLAN: true)
            alice.trust.evaluate(try EnvelopeFactory.requireCertificate(bob))
            bob.trust.evaluate(try EnvelopeFactory.requireCertificate(alice))
            UserDefaults.standard.set(true, forKey: AppConfig.Keys.directInternet)
            return Pair(alice: alice, bob: bob)
        }

        func stop() {
            alice.stop()
            bob.stop()
            UserDefaults.standard.removeObject(forKey: AppConfig.Keys.directInternet)
        }
    }

    /// The port Bob's listener bound to. Binding is asynchronous, so this
    /// waits rather than reading a zero.
    private func listeningPort(of harness: ServiceHarness) async throws -> UInt16 {
        _ = await waitUntil(timeout: 10, interval: 0.1) { harness.service.lanPort != 0 }
        let port = harness.service.lanPort
        try #require(port != 0, "the LAN listener never bound")
        return port
    }

    /// Hands Alice an address hint from Bob, the way one would arrive through
    /// the relay. `address` stands in for Bob's global IPv6.
    private func tell(_ alice: ServiceHarness,
                      about bob: ServiceHarness,
                      address: String,
                      port: UInt16) async throws {
        let payload = ChatPayload(kind: .addressHint,
                                  directAddresses: [address],
                                  directPort: port,
                                  directExpiresAt: Int64(Date().timeIntervalSince1970) + 600)
        let envelope = try EnvelopeFactory.seal(payload, from: bob, to: alice)
        #expect(await alice.service.processIncoming(envelope) == .accepted)
    }

    @Test("a message reaches a contact at the address they published")
    func deliversToPublishedAddress() async throws {
        let pair = try await Pair.make()
        defer { pair.stop() }

        let port = try await listeningPort(of: pair.bob)
        // ::1 stands in for a global address: the point is that it was learned
        // from the hint and dialled directly, with no Bonjour involved.
        try await tell(pair.alice, about: pair.bob, address: "::1", port: port)

        let conversation = ConversationStore.conversationID(peer: pair.bob.phone)
        await pair.alice.service.sendText("across the internet", to: conversation)

        let stored = try #require(pair.alice.store.thread(conversation).first)
        #expect(stored.status == .sent)
        #expect(stored.route == .direct, "the relay is unreachable in this test")

        let arrived = await waitUntil(timeout: 5, interval: 0.1) {
            pair.bob.store.thread(ConversationStore.conversationID(peer: pair.alice.phone))
                .contains { $0.body == "across the internet" }
        }
        #expect(arrived)
    }

    @Test("an address that doesn't answer costs one timeout, not every send")
    func deadAddressIsSkipped() async throws {
        let pair = try await Pair.make()
        defer { pair.stop() }

        // Nothing listens on this port.
        try await tell(pair.alice, about: pair.bob, address: "::1", port: 9)

        let conversation = ConversationStore.conversationID(peer: pair.bob.phone)
        let clock = ContinuousClock()
        let first = await clock.measure {
            await pair.alice.service.sendText("one", to: conversation)
        }
        let second = await clock.measure {
            await pair.alice.service.sendText("two", to: conversation)
        }
        #expect(first >= second, "first send \(first), second \(second)")
        #expect(pair.alice.store.thread(conversation).allSatisfy { $0.status == .pending },
                "with no relay and no direct route, messages wait")
    }

    @Test("turning it off stops dialling contacts")
    func settingIsObeyed() async throws {
        let pair = try await Pair.make()
        defer { pair.stop() }

        let port = try await listeningPort(of: pair.bob)
        try await tell(pair.alice, about: pair.bob, address: "::1", port: port)
        pair.alice.service.setDirectInternetEnabled(false)

        let conversation = ConversationStore.conversationID(peer: pair.bob.phone)
        await pair.alice.service.sendText("relay only please", to: conversation)

        #expect(pair.alice.store.thread(conversation).first?.status == .pending,
                "the relay is unreachable, and direct delivery was switched off")
        #expect(pair.bob.store.thread(ConversationStore.conversationID(peer: pair.alice.phone))
            .isEmpty)
    }

    @Test("a hint received while switched off is not kept")
    func hintIgnoredWhenOff() async throws {
        let pair = try await Pair.make()
        defer { pair.stop() }

        pair.alice.service.setDirectInternetEnabled(false)
        let port = try await listeningPort(of: pair.bob)
        try await tell(pair.alice, about: pair.bob, address: "::1", port: port)
        pair.alice.service.setDirectInternetEnabled(true)

        let conversation = ConversationStore.conversationID(peer: pair.bob.phone)
        await pair.alice.service.sendText("nothing to dial", to: conversation)
        #expect(pair.alice.store.thread(conversation).first?.status == .pending)
    }
}
