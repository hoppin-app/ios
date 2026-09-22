//
//  MeshRouter.swift
//  HopChat-1
//
//  The routing layer of the BLE mesh: flooding with TTL, a seen-set for
//  de-duplication, a store-carry-forward cache and the "have"/"want" exchange
//  that drains that cache into a phone we just met.
//
//  There is no Bluetooth here on purpose. A `MeshLink` is just an id and a
//  closure that hands bytes to *some* transport, so the whole routing policy
//  runs in the simulator over an in-memory network (see `MeshRouterTests`).
//
//  Three rules are worth stating out loud, because they are the ones that are
//  easy to "optimise" into a privacy bug:
//
//  1. **A packet that is ours is forwarded anyway.** Stopping at the recipient
//     would tell the carrier who the recipient is: the packet would visibly
//     die at one phone. Delivery and forwarding are independent decisions.
//  2. **`hint` is a filter, never an address.** A match only means "worth
//     trying `openMesh`"; ~1 in 256 packets matches by chance, and the router
//     neither knows nor records whether the trial succeeded beyond a counter.
//  3. **Carriers are strangers.** Every inbound packet is decoded strictly,
//     size/TTL/expiry checked, and rate limited per link before it can cost us
//     any memory.
//
//  Everything is `@MainActor`, so there are no locks and no ordering surprises:
//  links are iterated in attach order and delivery is synchronous unless a
//  `forwardDelay` is configured.
//

import Foundation

/// One connected peer, from the router's point of view.
///
/// `id` identifies the *connection*, not the phone — mesh links deliberately
/// carry no identity (see the guide, §3), and the id is what tells the router
/// which link a packet must not be echoed back to.
@MainActor
final class MeshLink {

    let id: UUID
    /// Hand encoded bytes to the transport.
    let send: (Data) -> Void

    init(id: UUID = UUID(), send: @escaping (Data) -> Void) {
        self.id = id
        self.send = send
    }
}

@MainActor
final class MeshRouter {

    // MARK: - Configuration

    nonisolated struct Limits: Sendable {
        /// Packets held for store-carry-forward.
        var maxCachedPackets = 500
        /// Total encoded size of the cache.
        var maxCacheBytes = 5 * 1024 * 1024
        /// Per-link token bucket for inbound packets.
        var packetsPerMinutePerLink = 60
        /// Most ids a single "have" summary may advertise.
        var maxHaveIDs = 256
        /// Packet ids remembered for de-duplication (24 h, oldest evicted).
        var maxSeenIDs = 4_096
    }

    nonisolated struct Stats: Equatable, Sendable {
        var received = 0
        var forwarded = 0
        var dropped = 0
        var duplicates = 0
        var delivered = 0
        var rateLimited = 0
    }

    /// How long a packet id stays in the seen-set.
    static let seenRetention: TimeInterval = 24 * 3600
    /// A "have"/"want" packet is link-local and short lived.
    static let syncLifetime: TimeInterval = 60

    private let limits: Limits
    private let now: () -> Date

    /// Called for every packet whose body this device might be able to open.
    /// Return true when it really was ours (the service tries `openMesh`).
    var onPacketForUs: ((MeshPacket) -> Bool)?

    /// Hints this device currently answers to (`CryptoManager.meshHints`).
    var myHints: () -> Set<UInt8> = { [] }

    /// Every accepted, non-duplicate envelope packet — ours or a stranger's.
    /// Diagnostics only (link health, the developer screen); routing decisions
    /// must not depend on it.
    var onPacketSeen: ((MeshPacket) -> Void)?

    /// Jitter before a forwarded copy leaves, so a packet's origin isn't
    /// obvious from who transmitted it first (guide §3, "Timing"). Defaults to
    /// zero: tests — and the first BLE bring-up — stay deterministic.
    var forwardDelay: (MeshPacket, MeshLink) -> Duration = { _, _ in .zero }

    // MARK: - State

    private var links: [UUID: MeshLink] = [:]
    /// Attach order, so forwarding is deterministic.
    private var linkOrder: [UUID] = []

    private var seen: [Data: Date] = [:]
    private var seenOrder: [Data] = []

    private struct Cached {
        let packet: MeshPacket
        let encoded: Data
        let addedAt: Date
    }
    private var cache: [Data: Cached] = [:]
    private var cacheOrder: [Data] = []
    private var cacheBytes = 0

    private let bucket: TokenBucket

    private(set) var stats = Stats()

    init(limits: Limits = .init(), now: @escaping () -> Date = { Date() }) {
        self.limits = limits
        self.now = now
        self.bucket = TokenBucket(capacity: limits.packetsPerMinutePerLink, per: 60)
    }

    // MARK: - Links

    var linkCount: Int { links.count }

    /// Registers a link and immediately offers it what we are carrying.
    func attach(_ link: MeshLink) {
        if links[link.id] == nil { linkOrder.append(link.id) }
        links[link.id] = link
        sendHave(to: link)
    }

    func detach(_ id: UUID) {
        links[id] = nil
        linkOrder.removeAll { $0 == id }
    }

    // MARK: - Sending

    /// Our own new packet: cached and broadcast to every link.
    func originate(_ packet: MeshPacket) {
        markSeen(packet.packetID)
        store(packet)
        let data = packet.encoded()
        for link in orderedLinks() { link.send(data) }
    }

    // MARK: - Receiving

    /// Bytes arrived from a link.
    func receive(_ data: Data, from linkID: UUID) {
        stats.received += 1

        // A link we don't know about (already detached) is not a source of work.
        guard links[linkID] != nil else {
            stats.dropped += 1
            return
        }

        // Rate limit before anything that allocates: carriers are anonymous.
        guard bucket.consume(linkID.uuidString, now: now()) else {
            stats.rateLimited += 1
            stats.dropped += 1
            return
        }

        guard let packet = MeshPacket.decode(data), isAcceptable(packet) else {
            stats.dropped += 1
            return
        }

        switch packet.kind {
        case .have:
            handleHave(packet, from: linkID)
        case .want:
            handleWant(packet, from: linkID)
        case .envelope:
            handleEnvelope(packet, from: linkID)
        }
    }

    /// Everything a stranger's packet must satisfy before it costs us anything.
    private func isAcceptable(_ packet: MeshPacket) -> Bool {
        guard packet.ttl > 0 else { return false }
        guard packet.body.count <= MeshPacket.maxBodyBytes else { return false }
        guard !packet.isExpired(at: now()) else { return false }
        if packet.kind == .envelope && packet.body.isEmpty { return false }
        return true
    }

    private func handleEnvelope(_ packet: MeshPacket, from linkID: UUID) {
        guard !hasSeen(packet.packetID) else {
            stats.duplicates += 1
            return
        }
        markSeen(packet.packetID)
        onPacketSeen?(packet)

        // Delivery and forwarding are independent: see rule 1 at the top.
        if myHints().contains(packet.hint), let handler = onPacketForUs {
            if handler(packet) { stats.delivered += 1 }
        }

        // Cache the copy a future carry-forward would hand on: one hop already
        // spent, so a packet drained from the cache costs the same TTL as one
        // forwarded live.
        //
        // `onward` is `MeshPacket.forwarded(at:)` with the router's clock, so
        // expiry is decided in exactly one place.
        guard let onward = onward(packet) else { return }
        store(onward)
        forward(onward, excluding: linkID)
    }

    /// One hop spent, or nil when the packet must not travel further.
    private func onward(_ packet: MeshPacket) -> MeshPacket? {
        guard packet.ttl > 1, !packet.isExpired(at: now()) else { return nil }
        var copy = packet
        copy.ttl = packet.ttl - 1
        return copy
    }

    private func forward(_ packet: MeshPacket, excluding source: UUID) {
        let targets = orderedLinks().filter { $0.id != source }
        guard !targets.isEmpty else { return }
        let data = packet.encoded()
        stats.forwarded += 1
        for link in targets {
            let delay = forwardDelay(packet, link)
            if delay > .zero {
                Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    link.send(data)
                }
            } else {
                link.send(data)
            }
        }
    }

    // MARK: - have / want

    /// "I am carrying these packet ids." Link-local: ttl 1, never forwarded.
    private func sendHave(to link: MeshLink) {
        var body = Data()
        var count = 0
        for id in cacheOrder.reversed() where count < limits.maxHaveIDs {
            body.append(id)
            count += 1
        }
        let packet = MeshPacket(packetID: MeshPacket.randomID(),
                                kind: .have,
                                ttl: 1,
                                hint: 0,
                                expiresAt: syncExpiry(),
                                body: body)
        link.send(packet.encoded())
    }

    private func handleHave(_ packet: MeshPacket, from linkID: UUID) {
        guard let link = links[linkID] else { return }
        let offered = idList(packet.body)
        guard !offered.isEmpty else { return }

        var body = Data()
        var count = 0
        for id in offered where count < limits.maxHaveIDs {
            // Nothing we already hold, and nothing we already processed — a
            // second copy would only be counted as a duplicate.
            guard cache[id] == nil, !hasSeen(id) else { continue }
            body.append(id)
            count += 1
        }
        guard !body.isEmpty else { return }

        let want = MeshPacket(packetID: MeshPacket.randomID(),
                              kind: .want,
                              ttl: 1,
                              hint: 0,
                              expiresAt: syncExpiry(),
                              body: body)
        link.send(want.encoded())
    }

    private func handleWant(_ packet: MeshPacket, from linkID: UUID) {
        guard let link = links[linkID] else { return }
        let current = now()
        for id in idList(packet.body) {
            guard let entry = cache[id] else { continue }
            guard !entry.packet.isExpired(at: current) else { continue }
            link.send(entry.encoded)
        }
    }

    private func idList(_ body: Data) -> [Data] {
        let size = MeshPacket.idSize
        guard !body.isEmpty, body.count % size == 0,
              body.count / size <= limits.maxHaveIDs else { return [] }
        let bytes = [UInt8](body)
        return stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0..<($0 + size)]) }
    }

    private func syncExpiry() -> UInt32 {
        UInt32(now().addingTimeInterval(Self.syncLifetime).timeIntervalSince1970)
    }

    // MARK: - Seen-set

    private func hasSeen(_ id: Data) -> Bool {
        guard let at = seen[id] else { return false }
        guard now().timeIntervalSince(at) <= Self.seenRetention else {
            seen[id] = nil
            seenOrder.removeAll { $0 == id }
            return false
        }
        return true
    }

    private func markSeen(_ id: Data) {
        if seen[id] == nil { seenOrder.append(id) }
        seen[id] = now()
        while seenOrder.count > limits.maxSeenIDs {
            let oldest = seenOrder.removeFirst()
            seen[oldest] = nil
        }
    }

    // MARK: - Cache

    var cachedPacketIDs: Set<Data> { Set(cache.keys) }

    var cachedByteCount: Int { cacheBytes }

    /// Only `.envelope` packets are stored; "have"/"want" are link-local.
    private func store(_ packet: MeshPacket) {
        guard packet.kind == .envelope else { return }
        guard !packet.isExpired(at: now()) else { return }
        guard cache[packet.packetID] == nil else { return }

        let encoded = packet.encoded()
        guard encoded.count <= limits.maxCacheBytes else { return }

        cache[packet.packetID] = Cached(packet: packet, encoded: encoded, addedAt: now())
        cacheOrder.append(packet.packetID)
        cacheBytes += encoded.count
        trim()
    }

    /// Housekeeping: drop expired packets and trim the cache. Call periodically.
    func sweep() {
        let current = now()
        for (id, entry) in cache where entry.packet.isExpired(at: current) { remove(id) }
        let cutoff = current.addingTimeInterval(-Self.seenRetention)
        for id in seenOrder where (seen[id] ?? current) < cutoff {
            seen[id] = nil
        }
        seenOrder.removeAll { seen[$0] == nil }
        trim()
    }

    /// Expired first, then lowest TTL, then oldest.
    private func trim() {
        let current = now()
        if cache.count > limits.maxCachedPackets || cacheBytes > limits.maxCacheBytes {
            for (id, entry) in cache where entry.packet.isExpired(at: current) { remove(id) }
        }
        while cache.count > limits.maxCachedPackets || cacheBytes > limits.maxCacheBytes {
            guard let victim = cache.min(by: { lhs, rhs in
                if lhs.value.packet.ttl != rhs.value.packet.ttl {
                    return lhs.value.packet.ttl < rhs.value.packet.ttl
                }
                return lhs.value.addedAt < rhs.value.addedAt
            })?.key else { break }
            remove(victim)
        }
    }

    private func remove(_ id: Data) {
        guard let entry = cache.removeValue(forKey: id) else { return }
        cacheBytes -= entry.encoded.count
        cacheOrder.removeAll { $0 == id }
    }

    private func orderedLinks() -> [MeshLink] {
        linkOrder.compactMap { links[$0] }
    }
}
