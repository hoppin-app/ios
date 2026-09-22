//
//  MeshServiceTests.swift
//  HopChat-1Tests
//
//  Phase 3: the app's own send and receive paths over the Bluetooth mesh.
//
//  The radio is replaced by `FakeMesh`, which keeps the real packing and
//  opening (a `MeshNode` with no transport started) and records what would
//  have gone on the air. The services point at a dead port, so every relay
//  attempt fails the way it does with no internet — which is exactly when the
//  mesh is supposed to take over.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

// MARK: - A mesh with no radio

@MainActor
final class FakeMesh: MeshDelivering {

    /// Packing and opening are the real thing; only the air is fake.
    private let node = MeshNode(router: MeshRouter())

    var isRunning = false
    /// Pretend there is someone in range. Zero means "nobody nearby".
    var linkCount = 1
    var hints: () -> Set<UInt8> = { [] }
    var onEnvelope: ((MeshPacket) -> Bool)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sent: [MeshPacket] = []

    func start() { startCount += 1; isRunning = true }
    func stop() { stopCount += 1; isRunning = false }
    func send(_ packet: MeshPacket) { sent.append(packet) }

    func packet(for envelope: Envelope,
                recipientAgreementKey agreementKey: String,
                crypto: CryptoManager,
                ttl: UInt8,
                lifetime: TimeInterval,
                now: Date) -> MeshPacket? {
        node.packet(for: envelope, recipientAgreementKey: agreementKey, crypto: crypto,
                    ttl: ttl, lifetime: lifetime, now: now)
    }

    func envelope(from packet: MeshPacket, crypto: CryptoManager) -> Envelope? {
        node.envelope(from: packet, crypto: crypto)
    }

    /// Hands a packet to this node as the radio would.
    @discardableResult
    func deliver(_ packet: MeshPacket) -> Bool {
        guard hints().contains(packet.hint) else { return false }
        return onEnvelope?(packet) ?? false
    }
}

// MARK: - Sending

@MainActor
@Suite("Mesh — sending when there is no internet", .serialized)
struct MeshSendTests {

    /// Alice (with a mesh) and Bob, both registered against the same server,
    /// with Bob's certificate already pinned — the state after any earlier
    /// conversation, and the only state in which sending offline is allowed.
    @MainActor
    private struct Pair {
        let alice: ServiceHarness
        let bob: ServiceHarness
        let mesh: FakeMesh

        /// `radioOn` is what the path monitor would have caused: the phone
        /// has no route to the internet, so the mesh is already up.
        static func make(radioOn: Bool = true) async throws -> Pair {
            let server = Curve25519.Signing.PrivateKey()
            let mesh = FakeMesh()
            let alice = try await ServiceHarness.offline(phone: "+351912345678",
                                                         serverKey: server, mesh: mesh)
            let bob = try await ServiceHarness.offline(phone: "+14155552671", serverKey: server)
            // After the harness, not before: building it starts and stops the
            // service, and stopping the service stops the radio.
            if radioOn { mesh.start() }
            alice.trust.evaluate(try EnvelopeFactory.requireCertificate(bob))
            bob.trust.evaluate(try EnvelopeFactory.requireCertificate(alice))
            UserDefaults.standard.set(true, forKey: AppConfig.Keys.meshEnabled)
            return Pair(alice: alice, bob: bob, mesh: mesh)
        }

        func reset() {
            UserDefaults.standard.removeObject(forKey: AppConfig.Keys.meshEnabled)
        }
    }

    @Test("with the relay unreachable a text hops over Bluetooth, and arrives")
    func textGoesOverTheMesh() async throws {
        let pair = try await Pair.make()
        defer { pair.reset() }
        let conversation = ConversationStore.conversationID(peer: pair.bob.phone)

        await pair.alice.service.sendText("no signal out here", to: conversation)

        let stored = try #require(pair.alice.store.thread(conversation).first)
        #expect(stored.status == .sent)
        #expect(stored.route == .mesh, "the relay was unreachable, so the mesh carried it")
        #expect(pair.mesh.sent.count == 1)

        // What went on the air is unreadable to anyone but Bob…
        let packet = try #require(pair.mesh.sent.first)
        #expect(pair.alice.crypto.openMesh(packet.body,
                                           authenticating: packet.authenticatedHeader) == nil,
                "not even the sender can open its own mesh packet")
        #expect(pair.bob.crypto.meshHints().contains(packet.hint))

        // …and Bob's app accepts it through the ordinary ingest path.
        let envelope = try #require(pair.mesh.envelope(from: packet, crypto: pair.bob.crypto))
        #expect(await pair.bob.service.processIncoming(envelope, viaMesh: true) == .accepted)
        let received = try #require(pair.bob.store
            .thread(ConversationStore.conversationID(peer: pair.alice.phone)).first)
        #expect(received.body == "no signal out here")
        #expect(received.route == .mesh)
    }

    @Test("a photo is never put on the mesh")
    func photosStayOff() async throws {
        let pair = try await Pair.make()
        defer { pair.reset() }
        let conversation = ConversationStore.conversationID(peer: pair.bob.phone)

        let jpeg = Data(repeating: 0xAB, count: 4_000)
        await pair.alice.service.sendImage(jpeg, to: conversation)

        #expect(pair.mesh.sent.isEmpty, "photos are too big to hop")
        let stored = try #require(pair.alice.store.thread(conversation).first)
        #expect(stored.status == .pending, "it waits for Wi-Fi or mobile data")
    }

    @Test("the setting is obeyed")
    func respectsTheSetting() async throws {
        let pair = try await Pair.make()
        defer { pair.reset() }
        pair.alice.service.setMeshEnabled(false)
        #expect(pair.mesh.stopCount >= 1, "switching it off stops the radio")

        await pair.alice.service.sendText("quiet",
                                          to: ConversationStore.conversationID(peer: pair.bob.phone))
        #expect(pair.mesh.sent.isEmpty)
    }

    @Test("a phone that still has a path doesn't switch the radio on")
    func neverStartsTheRadioWhileOnline() async throws {
        let pair = try await Pair.make(radioOn: false)
        defer { pair.reset() }
        let conversation = ConversationStore.conversationID(peer: pair.bob.phone)

        // The relay is unreachable here, but iOS never reported a lost path —
        // an unreachable server is no reason to spend the battery.
        await pair.alice.service.sendText("server is down", to: conversation)

        #expect(pair.mesh.startCount == 0)
        #expect(pair.mesh.sent.isEmpty)
        #expect(pair.alice.store.thread(conversation).first?.status == .pending)
    }

    @Test("with nobody in range the message stays pending for a later try")
    func nobodyNearby() async throws {
        let pair = try await Pair.make()
        defer { pair.reset() }
        pair.mesh.linkCount = 0
        let conversation = ConversationStore.conversationID(peer: pair.bob.phone)

        await pair.alice.service.sendText("anyone there?", to: conversation)

        #expect(pair.mesh.sent.isEmpty)
        let stored = try #require(pair.alice.store.thread(conversation).first)
        #expect(stored.status == .pending)
        #expect(stored.route == nil)
    }

    @Test("what the mesh will and won't carry")
    func eligibility() {
        #expect(ChatPayload(kind: .text, text: "hi").isMeshEligible)
        #expect(ChatPayload(kind: .groupText, text: "hi").isMeshEligible)
        #expect(ChatPayload(kind: .deliveryReceipt).isMeshEligible, "receipts hop too")
        #expect(ChatPayload(kind: .readReceipt).isMeshEligible)
        #expect(ChatPayload(kind: .profile).isMeshEligible)
        #expect(ChatPayload(kind: .deleteForEveryone).isMeshEligible)
        #expect(!ChatPayload(kind: .image).isMeshEligible)
        #expect(!ChatPayload(kind: .groupImage).isMeshEligible)
        #expect(!ChatPayload(kind: .typing).isMeshEligible, "typing stays on the LAN")
    }
}

// MARK: - Receiving

@MainActor
@Suite("Mesh — receiving", .serialized)
struct MeshReceiveTests {

    private func pair() async throws -> (ServiceHarness, ServiceHarness) {
        let server = Curve25519.Signing.PrivateKey()
        let alice = try await ServiceHarness.offline(phone: "+351912345678", serverKey: server)
        let bob = try await ServiceHarness.offline(phone: "+14155552671", serverKey: server)
        bob.trust.evaluate(try EnvelopeFactory.requireCertificate(alice))
        return (alice, bob)
    }

    @Test("a typing indicator is refused over the mesh")
    func typingIsRefused() async throws {
        let (alice, bob) = try await pair()
        let envelope = try EnvelopeFactory.seal(ChatPayload(kind: .typing),
                                                from: alice, to: bob)
        #expect(await bob.service.processIncoming(envelope, viaMesh: true) == .rejected,
                "typing is only believed over an authenticated LAN link")
    }

    @Test("the same message arriving twice is stored once")
    func duplicateIsIgnored() async throws {
        let (alice, bob) = try await pair()
        let envelope = try EnvelopeFactory.text("twice", from: alice, to: bob)

        #expect(await bob.service.processIncoming(envelope, viaMesh: true) == .accepted)
        // The relay copy turns up later, as it will whenever the sender comes
        // back online: it must not become a second message.
        #expect(await bob.service.processIncoming(envelope) == .accepted)
        #expect(bob.store.thread(ConversationStore.conversationID(peer: alice.phone)).count == 1)
    }
}

// MARK: - Route precedence

@MainActor
@Suite("Mesh — how a message reports its route")
struct MeshRouteTests {

    @Test("a route never downgrades")
    func precedence() {
        #expect(MessageRoute.direct.precedence > MessageRoute.mesh.precedence)
        #expect(MessageRoute.mesh.precedence > MessageRoute.relay.precedence)
    }

    @Test("a mesh message re-sent through the relay keeps its mesh mark")
    func keepsTheMeshMark() throws {
        let temp = TempDirectory("hopchat-route")
        let store = ConversationStore(directory: temp.url, legacyDefaults: nil,
                                      debounce: .milliseconds(1))
        let conversation = ConversationStore.conversationID(peer: "+14155552671")
        let message = StoredMessage(id: "m1", conversationID: conversation,
                                    fromPhone: "+351912345678", toPhone: "+14155552671",
                                    kind: .text, body: "hop", timestamp: Date(),
                                    status: .sent, isFromMe: true, isRead: true)
        #expect(store.appendMessage(message))

        store.setRoute(.mesh, messageID: "m1", conversationID: conversation)
        store.setRoute(.relay, messageID: "m1", conversationID: conversation)
        #expect(store.thread(conversation).first?.route == .mesh)

        // Direct still wins: it is the strongest claim we can make.
        store.setRoute(.direct, messageID: "m1", conversationID: conversation)
        #expect(store.thread(conversation).first?.route == .direct)
    }

    @Test("messages the mesh took are the ones re-sent when internet returns")
    func awaitingDelivery() throws {
        let temp = TempDirectory("hopchat-route")
        let store = ConversationStore(directory: temp.url, legacyDefaults: nil,
                                      debounce: .milliseconds(1))
        let conversation = ConversationStore.conversationID(peer: "+14155552671")

        func add(_ id: String, status: MessageStatus, route: MessageRoute?) {
            _ = store.appendMessage(StoredMessage(id: id, conversationID: conversation,
                                                  fromPhone: "+351912345678",
                                                  toPhone: "+14155552671",
                                                  kind: .text, body: id, timestamp: Date(),
                                                  status: status, isFromMe: true, isRead: true,
                                                  route: route))
        }
        add("sent-by-mesh", status: .sent, route: .mesh)
        add("already-delivered", status: .delivered, route: .mesh)
        add("sent-by-relay", status: .sent, route: .relay)

        #expect(store.meshSentAwaitingDelivery().map(\.id) == ["sent-by-mesh"])
    }
}
