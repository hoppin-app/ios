//
//  KadmeliaNode.swift
//  HopChat-1
//
//  NodeID / KBucket / RoutingTable, retained from v1 but scoped to
//  **authenticated LAN peers only** (contract §0: the open DHT — `store`,
//  `findValue`, hole punching and phone→IP lookup — is removed).
//
//  A peer only ever enters this table after a successful, signed `hello`
//  exchange, and its IP is always the observed TCP source address — never a
//  self-reported one.
//

import Foundation
import CryptoKit

// MARK: - NodeID (256-bit / SHA-256)

nonisolated struct NodeID: Equatable, Hashable, CustomStringConvertible {

    static let byteCount = 32

    let bytes: [UInt8]

    /// Deterministic ID derived from a phone number.
    static func from(phone: String) -> NodeID {
        NodeID(bytes: Array(SHA256.hash(data: Data(phone.utf8))))
    }

    static func random() -> NodeID {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return NodeID(bytes: bytes)
    }

    func distance(to other: NodeID) -> [UInt8] {
        zip(bytes, other.bytes).map { $0 ^ $1 }
    }

    /// k-bucket index (0–255): the number of leading zero bits of the XOR
    /// distance, i.e. the common prefix length.
    func bucketIndex(relativeTo other: NodeID) -> Int {
        var leadingZeros = 0
        for byte in distance(to: other) {
            if byte == 0 {
                leadingZeros += 8
            } else {
                leadingZeros += byte.leadingZeroBitCount
                break
            }
        }
        return min(leadingZeros, 255)
    }

    var description: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Authenticated LAN peer

/// A LAN peer whose identity certificate has been verified through a signed
/// `hello` exchange. `ip` is the TCP source address of that exchange.
nonisolated struct LANPeer: Equatable, Hashable {

    let id: NodeID
    /// Phone taken from the **verified certificate**, never from the wire field.
    let phone: String
    /// Observed TCP source IP.
    var ip: String
    /// Listening port, taken from the signed `senderPort` field.
    var port: UInt16
    /// The certificate JSON proven in the hello exchange.
    var certificateJSON: String
    var lastSeen: Date

    init(phone: String, ip: String, port: UInt16, certificateJSON: String, lastSeen: Date = Date()) {
        self.id = NodeID.from(phone: phone)
        self.phone = phone
        self.ip = ip
        self.port = port
        self.certificateJSON = certificateJSON
        self.lastSeen = lastSeen
    }

    var address: String { "\(ip):\(port)" }

    /// Contract §17 — a LAN peer seen in the last 5 minutes counts as online.
    func isOnline(now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSeen) < 5 * 60
    }

    static func == (lhs: LANPeer, rhs: LANPeer) -> Bool {
        lhs.phone == rhs.phone && lhs.ip == rhs.ip && lhs.port == rhs.port
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(phone)
    }
}

// MARK: - KBucket (k = 20, ping-before-evict)

nonisolated struct KBucket {

    static let k = 20

    private(set) var peers: [LANPeer] = []

    /// Adds or refreshes a peer.
    /// - Returns: `nil` when the peer was inserted or refreshed, otherwise the
    ///   least-recently-seen peer the caller should ping before evicting.
    @discardableResult
    mutating func add(_ peer: LANPeer) -> LANPeer? {
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            peers.remove(at: idx)
            peers.append(peer)
            return nil
        }
        if peers.count < KBucket.k {
            peers.append(peer)
            return nil
        }
        return peers.first
    }

    /// Evicts `old` after its liveness ping failed and inserts `new`.
    mutating func confirmEvict(_ old: NodeID, thenAdd new: LANPeer) {
        peers.removeAll { $0.id == old }
        peers.append(new)
    }

    mutating func remove(_ id: NodeID) {
        peers.removeAll { $0.id == id }
    }

    /// Drops peers not seen within `maxAge`.
    mutating func prune(olderThan maxAge: TimeInterval, now: Date = Date()) {
        peers.removeAll { now.timeIntervalSince($0.lastSeen) > maxAge }
    }
}

// MARK: - RoutingTable (256 buckets)

nonisolated final class RoutingTable {

    let localID: NodeID
    private var buckets: [KBucket] = Array(repeating: KBucket(), count: 256)

    /// Invoked when a bucket is full: (oldestPeer, newPeer). The caller should
    /// ping `oldestPeer` and call `confirmEvict` if it does not respond.
    var onEvictionNeeded: ((LANPeer, LANPeer) -> Void)?

    init(localID: NodeID) { self.localID = localID }

    // MARK: Mutation

    func add(_ peer: LANPeer) {
        guard peer.id != localID else { return }
        let idx = localID.bucketIndex(relativeTo: peer.id)
        if let oldest = buckets[idx].add(peer) {
            onEvictionNeeded?(oldest, peer)
        }
    }

    func confirmEvict(oldID: NodeID, newPeer: LANPeer) {
        let idx = localID.bucketIndex(relativeTo: newPeer.id)
        buckets[idx].confirmEvict(oldID, thenAdd: newPeer)
    }

    func remove(phone: String) {
        let id = NodeID.from(phone: phone)
        buckets[localID.bucketIndex(relativeTo: id)].remove(id)
    }

    func removeAll() {
        buckets = Array(repeating: KBucket(), count: 256)
    }

    /// Drops stale entries (default: not seen for 30 minutes).
    func prune(olderThan maxAge: TimeInterval = 30 * 60, now: Date = Date()) {
        for idx in buckets.indices {
            buckets[idx].prune(olderThan: maxAge, now: now)
        }
    }

    // MARK: Queries

    func peer(for phone: String) -> LANPeer? {
        let id = NodeID.from(phone: phone)
        return buckets[localID.bucketIndex(relativeTo: id)].peers.first { $0.id == id }
    }

    var allPeers: [LANPeer] { buckets.flatMap(\.peers) }

    func closestPeers(to target: NodeID, k: Int = KBucket.k) -> [LANPeer] {
        allPeers
            .sorted {
                $0.id.distance(to: target)
                    .lexicographicallyPrecedes($1.id.distance(to: target))
            }
            .prefix(k)
            .map { $0 }
    }
}
