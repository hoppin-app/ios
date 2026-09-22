//
//  MeshEndToEndTests.swift
//  HopChat-1Tests
//
//  The whole mesh stack except the radio: a real sealed envelope is packed,
//  chunked as BLE would chunk it, reassembled, routed through a carrier that
//  cannot read it, and opened by the recipient.
//
//  `BLETransport` itself can't run here (the simulator has no Bluetooth), so
//  the "radio" is a pair of reassemblers wired together — exactly what the
//  transport does with the bytes it receives.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

@MainActor
@Suite("Mesh — end to end through a carrier", .serialized)
struct MeshEndToEndTests {

    /// Sender, carrier (a stranger) and recipient, all with certificates from
    /// the same server so the inner envelope validates.
    private struct World {
        let alice: ServiceHarness
        let carrier: ServiceHarness
        let bob: ServiceHarness

        static func make() async throws -> World {
            let server = Curve25519.Signing.PrivateKey()
            return World(alice: try await ServiceHarness.offline(phone: "+351912345678", serverKey: server),
                         carrier: try await ServiceHarness.offline(phone: "+351933333333", serverKey: server),
                         bob: try await ServiceHarness.offline(phone: "+14155552671", serverKey: server))
        }
    }

    /// Splits bytes into BLE-sized chunks and feeds them to a reassembler, the
    /// way the transport does over a real link.
    private func overTheAir(_ data: Data,
                            maxChunk: Int,
                            into reassembler: BLEReassembler) -> Data? {
        guard let chunks = BLEFrame.chunks(kind: .packet, payload: data,
                                           maxChunk: maxChunk, frameID: 1) else { return nil }
        var assembled: BLEFrame.Assembled?
        for chunk in chunks {
            if let done = reassembler.accept(chunk) { assembled = done }
        }
        guard assembled?.kind == .packet else { return nil }
        return assembled?.payload
    }

    @Test("a message reaches its recipient through a carrier that can't read it")
    func throughACarrier() async throws {
        let world = try await World.make()
        let node = MeshNode(router: MeshRouter())
        let envelope = try EnvelopeFactory.text("through the mesh", from: world.alice, to: world.bob)
        let bobKey = try EnvelopeFactory.requireCertificate(world.bob).agreementKey

        // Alice packs it.
        let packet = try #require(node.packet(for: envelope,
                                              recipientAgreementKey: bobKey,
                                              crypto: world.alice.crypto))

        // The carrier receives it over "BLE", forwards it, and learns nothing.
        let carrierRouter = MeshRouter()
        carrierRouter.myHints = { world.carrier.crypto.meshHints() }
        var carrierOpened = 0
        carrierRouter.onPacketForUs = { p in
            if world.carrier.crypto.openMesh(p.body, authenticating: p.authenticatedHeader) != nil {
                carrierOpened += 1
                return true
            }
            return false
        }
        // Attaching a link also sends a "what are you carrying?" summary, so
        // only envelope packets count as forwarded mail here.
        var forwarded: [Data] = []
        let inLink = MeshLink(id: UUID()) { _ in }             // where it arrives from
        let outLink = MeshLink(id: UUID()) { data in
            if MeshPacket.decode(data)?.kind == .envelope { forwarded.append(data) }
        }
        carrierRouter.attach(inLink)
        carrierRouter.attach(outLink)

        let wire = try #require(overTheAir(packet.encoded(), maxChunk: 182, into: BLEReassembler()))

        // A packet from a link the router doesn't know is dropped outright.
        carrierRouter.receive(wire, from: UUID())
        #expect(carrierRouter.stats.dropped >= 1)
        #expect(forwarded.isEmpty)

        carrierRouter.receive(wire, from: inLink.id)
        #expect(carrierOpened == 0, "a carrier must never be able to open a stranger's packet")
        #expect(forwarded.count == 1, "the carrier must pass it on, to every link but the source")

        // Bob receives the forwarded copy, again over "BLE".
        let atBob = try #require(overTheAir(forwarded[0], maxChunk: 182, into: BLEReassembler()))
        let bobPacket = try #require(MeshPacket.decode(atBob))
        #expect(bobPacket.ttl == packet.ttl - 1, "one hop was spent")
        #expect(world.bob.crypto.meshHints().contains(bobPacket.hint))

        let opened = try #require(node.envelope(from: bobPacket, crypto: world.bob.crypto))
        #expect(opened == envelope)

        // And the app's own receive path accepts it, with the sender's
        // signature and certificate checked exactly as for relayed mail.
        world.bob.trust.evaluate(try EnvelopeFactory.requireCertificate(world.alice))
        let outcome = await world.bob.service.processIncoming(opened)
        #expect(outcome == .accepted)
        #expect(world.bob.store.thread(world.alice.phone).first?.body == "through the mesh")
    }

    @Test("a full-size message survives chunking at the smallest usable write size")
    func smallestChunks() async throws {
        let world = try await World.make()
        let node = MeshNode(router: MeshRouter())
        let long = String(repeating: "hop ", count: 300)     // ~1.2 kB of text
        let envelope = try EnvelopeFactory.text(long, from: world.alice, to: world.bob)
        let bobKey = try EnvelopeFactory.requireCertificate(world.bob).agreementKey
        let packet = try #require(node.packet(for: envelope,
                                              recipientAgreementKey: bobKey,
                                              crypto: world.alice.crypto))

        // 23 B is what a stubborn peer may negotiate; anything less can't carry
        // a mesh packet within the 512-chunk limit.
        let wire = try #require(overTheAir(packet.encoded(), maxChunk: 23, into: BLEReassembler()))
        let arrived = try #require(MeshPacket.decode(wire))
        let opened = try #require(node.envelope(from: arrived, crypto: world.bob.crypto))
        #expect(opened == envelope)
    }

    @Test("a packet damaged in flight is refused, not half-delivered")
    func damagedInFlight() async throws {
        let world = try await World.make()
        let node = MeshNode(router: MeshRouter())
        let envelope = try EnvelopeFactory.text("hello", from: world.alice, to: world.bob)
        let bobKey = try EnvelopeFactory.requireCertificate(world.bob).agreementKey
        let packet = try #require(node.packet(for: envelope,
                                              recipientAgreementKey: bobKey,
                                              crypto: world.alice.crypto))

        var wire = packet.encoded()
        wire[wire.index(wire.startIndex, offsetBy: wire.count - 5)] ^= 0xFF
        let arrived = try #require(MeshPacket.decode(wire))
        #expect(node.envelope(from: arrived, crypto: world.bob.crypto) == nil)
    }
}
