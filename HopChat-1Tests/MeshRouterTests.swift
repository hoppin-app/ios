//
//  MeshRouterTests.swift
//  HopChat-1Tests
//
//  The mesh routing layer over an in-memory network — no Bluetooth, no radio,
//  no timers. `SimNetwork` wires `MeshRouter`s together with synchronous links
//  and a FIFO queue, so a topology (line, diamond, partition-then-merge, a
//  20-node random graph) is a few lines and every run is deterministic.
//
//  What these exist to protect:
//  - a packet that is *ours* must still be forwarded, or the carrier can see
//    where mail stops and learns who the recipient is;
//  - `.retryLater`-style transient drops have an equivalent here: a rate
//    limited link must not be torn down, only throttled;
//  - store-carry-forward is the whole point of the mesh — B walking from A to
//    C must deliver, which is the have/want exchange on attach.
//

import Testing
import Foundation
@testable import HopChat_1

// MARK: - Harness

/// A movable clock shared by every router in a simulation.
@MainActor
final class SimClock {
    var value: Date
    init(_ value: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.value = value }
    func advance(_ seconds: TimeInterval) { value = value.addingTimeInterval(seconds) }
    var now: () -> Date { { [unowned self] in self.value } }
}

@MainActor
final class SimNode {

    let index: Int
    let router: MeshRouter
    /// Hints this node answers to.
    var hints: Set<UInt8> = []
    /// Every packet the router offered us (hint matched).
    var observed: [MeshPacket] = []
    /// The subset we claimed as really ours.
    var delivered: [MeshPacket] = []
    /// Stands in for a successful `CryptoManager.openMesh`.
    var isMine: (MeshPacket) -> Bool = { _ in true }

    init(index: Int, clock: SimClock, limits: MeshRouter.Limits = .init()) {
        self.index = index
        self.router = MeshRouter(limits: limits, now: clock.now)
        router.myHints = { [unowned self] in self.hints }
        router.onPacketForUs = { [unowned self] packet in
            self.observed.append(packet)
            guard self.isMine(packet) else { return false }
            self.delivered.append(packet)
            return true
        }
    }

    var stats: MeshRouter.Stats { router.stats }
}

@MainActor
final class SimNetwork {

    let clock: SimClock
    private(set) var nodes: [SimNode] = []
    private var connections: [String: UUID] = [:]
    private var queue: [(node: SimNode, data: Data, from: UUID)] = []
    /// Set to drop a fraction of transmissions; unused by default.
    var deliveredFrames = 0

    init(clock: SimClock? = nil) { self.clock = clock ?? SimClock() }

    @discardableResult
    func addNode(limits: MeshRouter.Limits = .init()) -> SimNode {
        let node = SimNode(index: nodes.count, clock: clock, limits: limits)
        nodes.append(node)
        return node
    }

    private func key(_ a: SimNode, _ b: SimNode) -> String {
        let (lo, hi) = a.index < b.index ? (a.index, b.index) : (b.index, a.index)
        return "\(lo)-\(hi)"
    }

    /// One bidirectional link, sharing a connection id on both sides — which is
    /// what makes "never forward back to the source" work.
    func connect(_ a: SimNode, _ b: SimNode) {
        let id = UUID()
        connections[key(a, b)] = id
        a.router.attach(MeshLink(id: id) { [unowned self] data in
            self.queue.append((node: b, data: data, from: id))
        })
        b.router.attach(MeshLink(id: id) { [unowned self] data in
            self.queue.append((node: a, data: data, from: id))
        })
    }

    func disconnect(_ a: SimNode, _ b: SimNode) {
        guard let id = connections.removeValue(forKey: key(a, b)) else { return }
        a.router.detach(id)
        b.router.detach(id)
    }

    func linkID(_ a: SimNode, _ b: SimNode) -> UUID? { connections[key(a, b)] }

    /// True when `run` hit its step cap — i.e. the network never went quiet.
    private(set) var stalled = false

    /// Drains the network until quiet.
    func run(maxSteps: Int = 2_000_000) {
        var steps = 0
        while !queue.isEmpty {
            steps += 1
            if steps >= maxSteps { stalled = true; return }
            let frame = queue.removeFirst()
            deliveredFrames += 1
            frame.node.router.receive(frame.data, from: frame.from)
        }
    }

    /// Bytes queued but not yet delivered (e.g. to a link we just detached).
    func dropQueued() { queue.removeAll() }
}

// MARK: - Packet helpers

@MainActor
private func packet(hint: UInt8,
                    ttl: UInt8 = MeshPacket.defaultTTL,
                    clock: SimClock,
                    lifetime: TimeInterval = 3600,
                    bodyByte: UInt8 = 0xAB,
                    bodySize: Int = 64) -> MeshPacket {
    MeshPacket(packetID: MeshPacket.randomID(),
               kind: .envelope,
               ttl: ttl,
               hint: hint,
               expiresAt: UInt32(clock.value.addingTimeInterval(lifetime).timeIntervalSince1970),
               body: Data(repeating: bodyByte, count: bodySize))
}

/// Deterministic PRNG, so the random topology is the same run to run.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Delivery and flooding

/// Wrapper suite, so `-only-testing:HopChat-1Tests/MeshRouterTests` selects the lot.
@MainActor
@Suite("MeshRouter")
struct MeshRouterTests {


@MainActor
@Suite("MeshRouter — delivery and flooding")
struct MeshRouterDeliveryTests {

    @Test("a packet originated on A is delivered on B when the hint matches")
    func roundTrip() {
        let net = SimNetwork()
        let a = net.addNode(), b = net.addNode()
        b.hints = [9]
        net.connect(a, b)
        net.run()

        let sent = packet(hint: 9, clock: net.clock)
        a.router.originate(sent)
        net.run()

        #expect(b.delivered.count == 1)
        #expect(b.delivered.first?.packetID == sent.packetID)
        #expect(b.delivered.first?.body == sent.body)
        #expect(b.stats.delivered == 1)
        #expect(a.delivered.isEmpty, "the originator does not deliver to itself")
    }

    @Test("a line A–B–C–D carries the packet to D, one TTL per hop")
    func lineTopologyDecrementsTTL() {
        let net = SimNetwork()
        let a = net.addNode(), b = net.addNode(), c = net.addNode(), d = net.addNode()
        for node in [a, b, c, d] { node.hints = [9] }        // everyone looks…
        for node in [a, b, c] { node.isMine = { _ in false } } // …only D owns it
        net.connect(a, b); net.connect(b, c); net.connect(c, d)
        net.run()

        a.router.originate(packet(hint: 9, ttl: 7, clock: net.clock))
        net.run()

        #expect(b.observed.map(\.ttl) == [7])
        #expect(c.observed.map(\.ttl) == [6])
        #expect(d.observed.map(\.ttl) == [5])
        #expect(d.delivered.count == 1)
        #expect(b.delivered.isEmpty && c.delivered.isEmpty)
    }

    @Test("TTL 2 dies before the far end of the line")
    func ttlExhaustion() {
        let net = SimNetwork()
        let a = net.addNode(), b = net.addNode(), c = net.addNode(), d = net.addNode()
        for node in [a, b, c, d] { node.hints = [9]; node.isMine = { _ in false } }
        net.connect(a, b); net.connect(b, c); net.connect(c, d)
        net.run()

        a.router.originate(packet(hint: 9, ttl: 2, clock: net.clock))
        net.run()

        // B may spend the last hop (ttl 2 → 1); C must not forward at ttl 1.
        #expect(b.observed.map(\.ttl) == [2])
        #expect(c.observed.map(\.ttl) == [1])
        #expect(d.observed.isEmpty, "a packet at ttl 1 must not be forwarded")
        #expect(c.stats.forwarded == 0)
    }

    @Test("a packet arriving by two paths is delivered and forwarded once")
    func duplicatesAreCollapsed() {
        let net = SimNetwork()
        let a = net.addNode(), b = net.addNode(), c = net.addNode(), d = net.addNode()
        d.hints = [9]
        net.connect(a, b); net.connect(a, c); net.connect(b, d); net.connect(c, d)
        net.run()

        a.router.originate(packet(hint: 9, clock: net.clock))
        net.run()

        #expect(d.observed.count == 1)
        #expect(d.delivered.count == 1)
        #expect(d.stats.duplicates == 1, "the second path's copy is a duplicate")
        #expect(d.stats.forwarded == 1, "and it is forwarded only once")
        #expect(c.stats.duplicates >= 1, "the copy coming back round the diamond is a duplicate")
    }

    @Test("a packet that is ours is forwarded anyway, and one that isn't is never delivered")
    func deliveryDoesNotStopForwarding() {
        let net = SimNetwork()
        let a = net.addNode(), b = net.addNode(), c = net.addNode()
        net.connect(a, b); net.connect(b, c)
        net.run()

        // 1. B's hint does not match: forwarded, never delivered.
        b.hints = [1]; c.hints = [9]
        a.router.originate(packet(hint: 9, clock: net.clock))
        net.run()
        #expect(b.observed.isEmpty, "a hint that doesn't match must not reach openMesh")
        #expect(c.delivered.count == 1)

        // 2. B's hint matches and the packet really is B's: still forwarded.
        b.hints = [9]
        let mine = packet(hint: 9, clock: net.clock)
        a.router.originate(mine)
        net.run()
        #expect(b.delivered.count == 1)
        #expect(c.delivered.count == 2, "the recipient must not swallow the packet")
        #expect(c.delivered.last?.packetID == mine.packetID)
    }
}

// MARK: - Validation

@MainActor
@Suite("MeshRouter — validation")
struct MeshRouterValidationTests {

    @Test("an expired packet is dropped and never forwarded")
    func expiredPacketIsDropped() {
        let net = SimNetwork()
        let a = net.addNode(), b = net.addNode(), c = net.addNode()
        for node in [b, c] { node.hints = [9] }
        net.connect(a, b); net.connect(b, c)
        net.run()

        let stale = MeshPacket(packetID: MeshPacket.randomID(), kind: .envelope, ttl: 7, hint: 9,
                               expiresAt: UInt32(net.clock.value.timeIntervalSince1970 - 10),
                               body: Data(repeating: 1, count: 32))
        a.router.originate(stale)
        net.run()

        #expect(b.observed.isEmpty)
        #expect(b.stats.dropped == 1)
        #expect(b.stats.forwarded == 0)
        #expect(c.observed.isEmpty)
        #expect(a.router.cachedPacketIDs.isEmpty, "an expired packet is not cached either")
    }

    @Test("garbage, truncated and out-of-range packets are rejected without crashing")
    func garbageIsRejected() {
        let net = SimNetwork()
        let a = net.addNode(), b = net.addNode()
        b.hints = Set(0...255)
        net.connect(a, b)
        net.run()
        let before = b.stats

        var generator = SplitMix64(seed: 42)
        let good = packet(hint: 9, clock: net.clock).encoded()
        var inputs: [Data] = [
            Data(),                                   // empty
            Data([0x48]),                             // one byte
            good.prefix(MeshPacket.headerSize - 1),   // truncated header
            Data([0x58, 0x58]) + good.dropFirst(2),   // wrong magic
            Data([0x48, 0x4D, 0x09]) + good.dropFirst(3),  // wrong version
            Data([0x48, 0x4D, 0x01, 0x7F]) + good.dropFirst(4),  // unknown kind
            // ttl 0
            MeshPacket(packetID: MeshPacket.randomID(), kind: .envelope, ttl: 0, hint: 9,
                       expiresAt: UInt32(net.clock.value.timeIntervalSince1970 + 60),
                       body: Data(repeating: 2, count: 16)).encoded(),
            // body over the cap
            MeshPacket(packetID: MeshPacket.randomID(), kind: .envelope, ttl: 4, hint: 9,
                       expiresAt: UInt32(net.clock.value.timeIntervalSince1970 + 60),
                       body: Data(repeating: 3, count: MeshPacket.maxBodyBytes + 1)).encoded(),
            // empty envelope body
            MeshPacket(packetID: MeshPacket.randomID(), kind: .envelope, ttl: 4, hint: 9,
                       expiresAt: UInt32(net.clock.value.timeIntervalSince1970 + 60),
                       body: Data()).encoded()
        ]
        for _ in 0..<32 {
            let length = Int.random(in: 0...200, using: &generator)
            inputs.append(Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }))
        }

        let source = try! #require(net.linkID(a, b))
        for input in inputs { b.router.receive(input, from: source) }
        net.run()

        #expect(b.observed.isEmpty)
        #expect(b.delivered.isEmpty)
        #expect(b.router.cachedPacketIDs.isEmpty)
        #expect(b.stats.forwarded == before.forwarded)
        #expect(b.stats.dropped >= inputs.count)
    }

    @Test("have and want packets are never forwarded and never cached")
    func syncPacketsStayLinkLocal() {
        let net = SimNetwork()
        let a = net.addNode(), b = net.addNode(), c = net.addNode()
        net.connect(a, b); net.connect(b, c)
        net.run()

        for node in [a, b, c] {
            #expect(node.router.cachedPacketIDs.isEmpty)
            #expect(node.stats.forwarded == 0)
            #expect(node.observed.isEmpty)
        }
        #expect(b.stats.received >= 2, "both neighbours offered a have summary")
    }
}

// MARK: - Store-carry-forward

@MainActor
@Suite("MeshRouter — store, carry, forward")
struct MeshRouterCarryTests {

    @Test("B carries a packet from A to C after the link to A is gone")
    func carryForward() {
        let net = SimNetwork()
        let a = net.addNode(), b = net.addNode(), c = net.addNode()
        c.hints = [9]
        b.hints = [1]                       // B cannot read it, only carry it

        net.connect(a, b)
        net.run()
        let carried = packet(hint: 9, clock: net.clock)
        a.router.originate(carried)
        net.run()

        #expect(b.router.cachedPacketIDs.contains(carried.packetID))
        #expect(c.observed.isEmpty, "C was not connected to anything yet")

        // B walks away from A and meets C.
        net.disconnect(a, b)
        net.clock.advance(300)
        net.connect(b, c)
        net.run()

        #expect(c.delivered.count == 1)
        #expect(c.delivered.first?.packetID == carried.packetID)
        #expect(c.delivered.first?.ttl == carried.ttl - 1, "the carried copy has one hop spent")
        #expect(c.router.cachedPacketIDs.contains(carried.packetID))
    }

    @Test("a want is only answered for packets the peer actually lacks")
    func haveWantSkipsWhatWeHave() {
        let net = SimNetwork()
        let a = net.addNode(), b = net.addNode()
        net.connect(a, b)
        net.run()

        a.router.originate(packet(hint: 9, clock: net.clock))
        net.run()
        let framesAfterFlood = net.deliveredFrames

        // Reconnecting: both sides now hold it, so the have exchange is a no-op.
        net.disconnect(a, b)
        net.connect(a, b)
        net.run()
        let extra = net.deliveredFrames - framesAfterFlood
        #expect(extra == 2, "just the two have summaries; nothing is re-sent")
        #expect(b.observed.count <= 1)
    }

    @Test("the cache never exceeds its packet or byte limits under a flood")
    func cacheLimitsHold() {
        let net = SimNetwork()
        var limits = MeshRouter.Limits()
        limits.maxCachedPackets = 20
        limits.packetsPerMinutePerLink = 10_000
        let a = net.addNode(limits: limits), b = net.addNode(limits: limits)
        net.connect(a, b)
        net.run()

        for index in 0..<200 {
            a.router.originate(packet(hint: 9, ttl: 7, clock: net.clock,
                                      bodyByte: UInt8(index % 251), bodySize: 128))
            net.run()
            #expect(a.router.cachedPacketIDs.count <= limits.maxCachedPackets)
            #expect(b.router.cachedPacketIDs.count <= limits.maxCachedPackets)
        }
        #expect(a.router.cachedPacketIDs.count == limits.maxCachedPackets)
        #expect(a.router.cachedByteCount <= limits.maxCacheBytes)

        // A byte budget smaller than the packet count budget also holds.
        var tight = MeshRouter.Limits()
        tight.maxCachedPackets = 500
        tight.maxCacheBytes = 4 * (MeshPacket.headerSize + 128)
        let c = net.addNode(limits: tight)
        for _ in 0..<50 {
            c.router.originate(packet(hint: 9, clock: net.clock, bodySize: 128))
        }
        #expect(c.router.cachedByteCount <= tight.maxCacheBytes)
        #expect(c.router.cachedPacketIDs.count == 4)
    }

    @Test("sweep drops expired packets from the cache")
    func sweepDropsExpired() {
        let net = SimNetwork()
        let a = net.addNode()
        a.router.originate(packet(hint: 9, clock: net.clock, lifetime: 60))
        a.router.originate(packet(hint: 9, clock: net.clock, lifetime: 7200))
        #expect(a.router.cachedPacketIDs.count == 2)

        net.clock.advance(120)
        a.router.sweep()
        #expect(a.router.cachedPacketIDs.count == 1)
    }
}

// MARK: - Abuse limits

@MainActor
@Suite("MeshRouter — abuse limits")
struct MeshRouterLimitTests {

    @Test("a link over its budget has the extra packets dropped, and stays up")
    func rateLimiting() {
        let net = SimNetwork()
        var limits = MeshRouter.Limits()
        limits.packetsPerMinutePerLink = 5
        let a = net.addNode(), b = net.addNode(limits: limits)
        b.hints = [9]
        net.connect(a, b)
        net.run()                     // the have exchange spends one token

        for _ in 0..<12 { a.router.originate(packet(hint: 9, clock: net.clock)) }
        net.run()

        #expect(b.observed.count == 4, "5 tokens, one already spent on the have")
        #expect(b.stats.rateLimited == 8)
        #expect(b.router.linkCount == 1, "throttling must not tear the link down")

        // The bucket refills: the link is usable again a minute later.
        net.clock.advance(60)
        a.router.originate(packet(hint: 9, clock: net.clock))
        net.run()
        #expect(b.observed.count == 5)
    }
}

// MARK: - Random network

@MainActor
@Suite("MeshRouter — random network")
struct MeshRouterRandomNetworkTests {

    @Test("a 20-node random network delivers at least 99% of packets within TTL")
    func randomNetworkDelivers() {
        var generator = SplitMix64(seed: 0xC0FFEE)
        let net = SimNetwork()

        var limits = MeshRouter.Limits()
        limits.packetsPerMinutePerLink = 1_000_000   // flooding is measured elsewhere
        limits.maxCachedPackets = 500

        let count = 20
        for index in 0..<count {
            let node = net.addNode(limits: limits)
            node.hints = [UInt8(index + 1)]          // distinct hint per node
        }

        // A ring (so the graph is connected) plus 30 deterministic chords.
        for index in 0..<count {
            net.connect(net.nodes[index], net.nodes[(index + 1) % count])
        }
        var edges = Set((0..<count).map { "\($0)-\(($0 + 1) % count)" })
        var added = 0
        while added < 30 {
            let x = Int.random(in: 0..<count, using: &generator)
            let y = Int.random(in: 0..<count, using: &generator)
            guard x != y else { continue }
            let key = x < y ? "\(x)-\(y)" : "\(y)-\(x)"
            guard !edges.contains(key) else { continue }
            edges.insert(key)
            net.connect(net.nodes[x], net.nodes[y])
            added += 1
        }
        net.run()

        let messages = 100
        var expected: [Int: Int] = [:]      // destination index → packets sent to it
        for _ in 0..<messages {
            let source = Int.random(in: 0..<count, using: &generator)
            var destination = Int.random(in: 0..<count, using: &generator)
            if destination == source { destination = (destination + 1) % count }
            expected[destination, default: 0] += 1
            net.nodes[source].router.originate(
                packet(hint: UInt8(destination + 1), ttl: MeshPacket.maxTTL, clock: net.clock))
            net.run()
        }

        let delivered = net.nodes.reduce(0) { $0 + $1.delivered.count }
        #expect(delivered >= Int(Double(messages) * 0.99),
                "delivered \(delivered)/\(messages)")
        for (index, sentToNode) in expected {
            #expect(net.nodes[index].delivered.count <= sentToNode,
                    "node \(index) delivered a packet more than once")
        }
        // Nobody kept more than the cache allows, even under a 100-packet flood.
        for node in net.nodes {
            #expect(node.router.cachedPacketIDs.count <= limits.maxCachedPackets)
        }
    }
}
}
