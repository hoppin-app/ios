//
//  NodeID.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 25/02/2026.
//

import Foundation
import CryptoKit

// MARK: - DHT Storage Entry (value + TTL)

struct DHTEntry {
    let value:    String
    let storedAt: Date

    var isExpired: Bool {
        Date().timeIntervalSince(storedAt) > AppConfig.dhtTTL
    }
}

 
// MARK: - NodeID (256-bit / SHA-256)
 
struct NodeID: Equatable, Hashable, CustomStringConvertible {
    static let byteCount = 32           // SHA-256 → 256 bits
 
    let bytes: [UInt8]                  // always 32 bytes
 
    // MARK: Factories
 
    /// Deterministic ID derived from a phone number string.
    static func from(phone: String) -> NodeID {
        let hash = SHA256.hash(data: Data(phone.utf8))
        return NodeID(bytes: Array(hash))
    }
 
    /// Cryptographically random ID (used for bootstrap random lookups).
    static func random() -> NodeID {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return NodeID(bytes: bytes)
    }
 
    // MARK: XOR metric
 
    /// Byte-wise XOR distance between two NodeIDs.
    func distance(to other: NodeID) -> [UInt8] {
        zip(bytes, other.bytes).map { $0 ^ $1 }
    }
 
    /// Returns the k-bucket index (0–255) for `other` relative to `self`.
    ///
    /// The bucket index equals the number of leading zero *bits* in the XOR
    /// distance, which is the length of the common key prefix — exactly what
    /// the libp2p Kad-DHT spec calls "prefix length".
    func bucketIndex(relativeTo other: NodeID) -> Int {
        let xor = distance(to: other)
        var leadingZeros = 0
        for byte in xor {
            if byte == 0 {
                leadingZeros += 8
            } else {
                leadingZeros += byte.leadingZeroBitCount
                break
            }
        }
        // Clamp to valid bucket range 0–255.
        // (256 would mean identical IDs; the routing table guards against self-add.)
        return min(leadingZeros, 255)
    }
 
    // MARK: Helpers
 
    var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
 
// MARK: - Peer
 
struct KadPeer: Equatable, Hashable {
    let id:       NodeID
    let ip:       String
    let port:     UInt16
    let phone:    String
    var lastSeen: Date = Date()
 
    var address: String { "\(ip):\(port)" }
}
 
// MARK: - KBucket  (up to k = 20 peers, ping-before-evict)
 
struct KBucket {
    static let k = 20
 
    var peers: [KadPeer] = []
 
    /// Called when a full bucket wants to add a new peer.
    /// Returns the oldest peer that should be pinged; if it is alive the
    /// caller must do nothing, if it is dead the caller should call
    /// `confirmEvict(_:thenAdd:)`.
    var evictionCandidate: KadPeer? {
        peers.first   // front = oldest (least-recently seen)
    }
 
    /// Add or refresh a peer.
    ///
    /// - Returns: `nil` if the peer was inserted/refreshed immediately,
    ///   or the oldest peer that must be pinged before eviction can proceed.
    @discardableResult
    mutating func add(_ peer: KadPeer) -> KadPeer? {
        // Already known → move to tail (most-recently seen).
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            peers.remove(at: idx)
            peers.append(peer)
            return nil
        }
 
        // Bucket has room → just append.
        if peers.count < KBucket.k {
            peers.append(peer)
            return nil
        }
 
        // Bucket is full → return oldest for the caller to ping.
        // We do NOT insert yet; `confirmEvict` will do that if the ping fails.
        return peers.first
    }
 
    /// Call this after a failed ping of `old`.  Evicts `old` and inserts `new`.
    mutating func confirmEvict(_ old: NodeID, thenAdd new: KadPeer) {
        peers.removeAll { $0.id == old }
        peers.append(new)
    }
 
    mutating func remove(_ id: NodeID) {
        peers.removeAll { $0.id == id }
    }
}
 
// MARK: - RoutingTable  (256 buckets — one per prefix-length bit 0–255)
 
final class RoutingTable {
    let localID: NodeID
    // 256 buckets for the 256-bit SHA-256 keyspace.
    var buckets: [KBucket] = Array(repeating: KBucket(), count: 256)
 
    /// Closure invoked when a bucket is full and the oldest peer needs pinging.
    /// Parameters: (oldestPeer, newPeer).  The caller should ping `oldestPeer`;
    /// if it does not respond it should call `confirmEvict(_:thenAdd:)`.
    var onEvictionNeeded: ((KadPeer, KadPeer) -> Void)?
 
    init(localID: NodeID) { self.localID = localID }
 
    // MARK: Mutation
 
    func add(_ peer: KadPeer) {
        guard peer.id != localID else { return }
        let idx = localID.bucketIndex(relativeTo: peer.id)
        if let oldest = buckets[idx].add(peer) {
            // Bucket full — notify caller to ping `oldest`.
            onEvictionNeeded?(oldest, peer)
        }
    }
 
    /// Confirms that `oldID` failed its liveness ping; evicts it and adds `newPeer`.
    func confirmEvict(oldID: NodeID, newPeer: KadPeer) {
        let idx = localID.bucketIndex(relativeTo: newPeer.id)
        buckets[idx].confirmEvict(oldID, thenAdd: newPeer)
    }
 
    func remove(_ id: NodeID) {
        let idx = localID.bucketIndex(relativeTo: id)
        buckets[idx].remove(id)
    }
 
    // MARK: Queries
 
    /// Returns up to `k` peers closest to `target` by XOR distance.
    func closestPeers(to target: NodeID, k: Int = KBucket.k) -> [KadPeer] {
        buckets
            .flatMap { $0.peers }
            .sorted {
                $0.id.distance(to: target)
                    .lexicographicallyPrecedes($1.id.distance(to: target))
            }
            .prefix(k)
            .map { $0 }
    }
 
    var allPeers: [KadPeer] {
        buckets.flatMap { $0.peers }
    }
}
 
