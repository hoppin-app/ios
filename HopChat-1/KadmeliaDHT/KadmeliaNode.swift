//
//  NodeID.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 25/02/2026.
//


import Foundation
import CryptoKit

// MARK: - NodeID (160-bit)
struct NodeID: Equatable, Hashable, CustomStringConvertible {
    let bytes: [UInt8] // 20 bytes = 160 bits
    
    // Generate from phone number
    static func from(phone: String) -> NodeID {
        let hash = Insecure.SHA1.hash(data: Data(phone.utf8))
        return NodeID(bytes: Array(hash))
    }
    
    // Generate random NodeID
    static func random() -> NodeID {
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, 20, &bytes)
        return NodeID(bytes: bytes)
    }
    
    // XOR distance between two NodeIDs
    func distance(to other: NodeID) -> [UInt8] {
        return zip(bytes, other.bytes).map { $0 ^ $1 }
    }
    
    // Which bucket does this node belong to? (0-159)
    func bucketIndex(relativeTo other: NodeID) -> Int {
        let xor = distance(to: other)
        for (i, byte) in xor.enumerated() {
            if byte != 0 {
                return i * 8 + (7 - Int(log2(Double(byte))))
            }
        }
        return 159 // same node
    }
    
    var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Peer
struct KadPeer: Equatable, Hashable {
    let id: NodeID
    let ip: String
    let port: UInt16
    var lastSeen: Date = Date()
    let phone: String
    
    var address: String { "\(ip):\(port)" }
}

// MARK: - KBucket (holds up to k=20 peers)
struct KBucket {
    static let k = 20
    var peers: [KadPeer] = []
    
    mutating func add(_ peer: KadPeer) {
        // Already exists? update lastSeen
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[idx] = peer
            return
        }
        if peers.count < KBucket.k {
            peers.append(peer)
        }
        // If full: drop oldest (simplified — real Kademlia pings oldest first)
        else {
            peers.removeFirst()
            peers.append(peer)
        }
    }
    
    mutating func remove(_ id: NodeID) {
        peers.removeAll { $0.id == id }
    }
}

// MARK: - RoutingTable (160 buckets)
class RoutingTable {
    let localID: NodeID
    var buckets: [KBucket] = Array(repeating: KBucket(), count: 160)
    
    init(localID: NodeID) {
        self.localID = localID
    }
    
    func add(_ peer: KadPeer) {
        guard peer.id != localID else { return }
        let idx = localID.bucketIndex(relativeTo: peer.id)
        buckets[idx].add(peer)
    }
    
    func remove(_ id: NodeID) {
        let idx = localID.bucketIndex(relativeTo: id)
        buckets[idx].remove(id)
    }
    
    // Find k closest peers to a target NodeID
    func closestPeers(to target: NodeID, k: Int = KBucket.k) -> [KadPeer] {
        let all = buckets.flatMap { $0.peers }
        return all.sorted {
            let d1 = $0.id.distance(to: target)
            let d2 = $1.id.distance(to: target)
            return d1.lexicographicallyPrecedes(d2)
        }.prefix(k).map { $0 }
    }
}
