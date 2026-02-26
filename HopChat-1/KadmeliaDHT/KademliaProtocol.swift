//
//  KademliaProtocol.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 25/02/2026.
//


import Foundation
import SwiftUI
import Combine

class KademliaProtocol: ObservableObject {
    let localPeer: KadPeer
    let routingTable: RoutingTable
    let transport: KademliaTransport
    
    // Local key-value store (phone -> peerInfo)
    private var storage: [String: String] = [:]
    
    // Pending requests: transactionID -> continuation
    private var pending: [String: CheckedContinuation<KadMessage?, Never>] = [:]
    private let pendingLock = NSLock()
    
    @Published var connectedPeers: Int = 0
    @Published var isBootstrapped: Bool = false
    
    init(phone: String, ip: String, port: UInt16 = 4001) {
        let id = NodeID.from(phone: phone)
        self.localPeer = KadPeer(id: id, ip: ip, port: port, phone:phone)
        self.routingTable = RoutingTable(localID: id)
        self.transport = KademliaTransport(port: port)
        
        setupMessageHandler()
    }
    
    // MARK: - Start
    func start() throws {
        try transport.startListening()
        print("🟢 Kademlia node started: \(localPeer.id)")
    }
    
    // MARK: - Message Handler
    private func setupMessageHandler() {
        transport.onMessage = { [weak self] message, ip, port in
            guard let self else { return }
            
            // Always add sender to routing table
            let sender = KadPeer(
                id: NodeID(bytes: message.senderID),
                ip: message.senderIP,
                port: message.senderPort,
                phone: message.senderPhone,
            )
            self.routingTable.add(sender)
            self.connectedPeers = self.routingTable.buckets.flatMap { $0.peers }.count
            
            // Resolve pending request if this is a reply
            self.pendingLock.lock()
            if let continuation = self.pending[message.transactionID] {
                self.pending.removeValue(forKey: message.transactionID)
                self.pendingLock.unlock()
                continuation.resume(returning: message)
                return
            }
            self.pendingLock.unlock()
            
            // Handle incoming requests
            Task { await self.handle(message, from: sender) }
        }
    }
    
    private func handle(_ message: KadMessage, from sender: KadPeer) async {
        guard let type = KadMessageType(rawValue: message.type) else { return }
        
        switch type {
            
        case .ping:
            let pong = KademliaTransport.makePong(from: localPeer, replyTo: message.transactionID)
            transport.send(pong, to: sender.ip, port: sender.port)
            print("🏓 PING from \(sender.id) → replied PONG")
            
        case .findNode:
            guard let targetBytes = message.targetID else { return }
            let target = NodeID(bytes: targetBytes)
            let closest = routingTable.closestPeers(to: target)
            let reply = KademliaTransport.makeFoundNode(
                from: localPeer,
                peers: closest,
                replyTo: message.transactionID
            )
            transport.send(reply, to: sender.ip, port: sender.port)
            print("🔍 FIND_NODE from \(sender.id) → returned \(closest.count) peers")
            
        case .store:
            guard let key = message.key, let value = message.value else { return }
            storage[key] = value
            print("💾 STORE \(key) = \(value)")
            
        case .findValue:
            guard let key = message.key else { return }
            if let value = storage[key] {
                let reply = KademliaTransport.makeFoundValue(
                    from: localPeer,
                    key: key,
                    value: value,
                    replyTo: message.transactionID
                )
                transport.send(reply, to: sender.ip, port: sender.port)
                print("✅ FOUND_VALUE \(key) = \(value)")
            } else {
                // Value not found — return closest peers instead
                let targetID = NodeID.from(phone: key)
                let closest = routingTable.closestPeers(to: targetID)
                let reply = KademliaTransport.makeFoundNode(
                    from: localPeer,
                    peers: closest,
                    replyTo: message.transactionID
                )
                transport.send(reply, to: sender.ip, port: sender.port)
                print("❓ FIND_VALUE \(key) not found → returned \(closest.count) peers")
            }
        case .connectRequest:
            let senderPhone = message.senderPhone
            print("📬 Connect request from \(senderPhone)")
            
            // Notify the UI — new contact request arrived!
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .newContactRequest,
                    object: nil,
                    userInfo: ["phone": senderPhone, "ip": sender.ip, "port": sender.port]
                )
            }
            
            // Auto-accept for now (later: show UI prompt)
            let reply = KademliaTransport.makeConnectAccept(from: localPeer, replyTo: message.transactionID)
            transport.send(reply, to: sender.ip, port: sender.port)
            
        default:
            break
        }
    }
    
    // MARK: - Ping a peer
    func ping(_ peer: KadPeer) async -> Bool {
        let message = KademliaTransport.makePing(from: localPeer)
        let reply = await sendAndWait(message, to: peer)
        return reply?.type == KadMessageType.pong.rawValue
    }
    
    // MARK: - Iterative FIND_NODE
    func findNode(_ target: NodeID) async -> [KadPeer] {
        var asked = Set<NodeID>()
        var closest = routingTable.closestPeers(to: target)
        
        while true {
            // Pick up to 3 unasked peers (alpha = 3)
            let toAsk = closest.filter { !asked.contains($0.id) }.prefix(3)
            guard !toAsk.isEmpty else { break }
            
            await withTaskGroup(of: [KadPeer].self) { group in
                for peer in toAsk {
                    asked.insert(peer.id)
                    group.addTask {
                        let msg = KademliaTransport.makeFindNode(from: self.localPeer, target: target)
                        guard let reply = await self.sendAndWait(msg, to: peer),
                              let peers = reply.peers else { return [] }
                        return peers.map { $0.toKadPeer() }
                    }
                }
                for await newPeers in group {
                    for p in newPeers {
                        self.routingTable.add(p)
                        if !closest.contains(p) { closest.append(p) }
                    }
                }
            }
            
            // Re-sort by distance to target
            closest = closest.sorted {
                $0.id.distance(to: target).lexicographicallyPrecedes($1.id.distance(to: target))
            }.prefix(KBucket.k).map { $0 }
        }
        
        return closest
    }
    
    // MARK: - Store a value in the DHT
    func store(key: String, value: String) async {
        let targetID = NodeID.from(phone: key)
        let closest = await findNode(targetID)
        
        // Store on self too
        storage[key] = value
        
        for peer in closest.prefix(KBucket.k) {
            let msg = KademliaTransport.makeStore(from: localPeer, key: key, value: value)
            transport.send(msg, to: peer.ip, port: peer.port)
        }
        print("📤 Stored '\(key)' on \(closest.count) peers")
    }
    
    // MARK: - Find a value in the DHT
    func findValue(key: String) async -> String? {
        // Check local storage first
        if let local = storage[key] { return local }
        
        var asked = Set<NodeID>()
        var closest = routingTable.closestPeers(to: NodeID.from(phone: key))
        
        while true {
            let toAsk = closest.filter { !asked.contains($0.id) }.prefix(3)
            guard !toAsk.isEmpty else { break }
            
            var found: String? = nil
            
            await withTaskGroup(of: (String?, [KadPeer]).self) { group in
                for peer in toAsk {
                    asked.insert(peer.id)
                    group.addTask {
                        let msg = KademliaTransport.makeFindValue(from: self.localPeer, key: key)
                        guard let reply = await self.sendAndWait(msg, to: peer) else { return (nil, []) }
                        
                        if reply.type == KadMessageType.foundValue.rawValue {
                            return (reply.value, [])
                        } else {
                            return (nil, reply.peers?.map { $0.toKadPeer() } ?? [])
                        }
                    }
                }
                for await (value, newPeers) in group {
                    if let value { found = value }
                    for p in newPeers {
                        self.routingTable.add(p)
                        if !closest.contains(p) { closest.append(p) }
                    }
                }
            }
            
            if let found { return found }
            
            closest = closest.sorted {
                $0.id.distance(to: NodeID.from(phone: key))
                    .lexicographicallyPrecedes($1.id.distance(to: NodeID.from(phone: key)))
            }.prefix(KBucket.k).map { $0 }
        }
        
        return nil
    }
    
    // MARK: - Send connection request to a phone number
    func requestConnect(toPhone phone: String, myPhone: String) async -> Bool {
        // 1. Find their IP from DHT
        guard let address = await findValue(key: "user-\(phone)") else {
            print("❌ Peer \(phone) not found in DHT")
            return false
        }
        
        let parts = address.split(separator: ":").map(String.init)
        guard parts.count == 2, let port = UInt16(parts[1]) else { return false }
        let ip = parts[0]
        
        // 2. Send connect request directly to their IP
        let peer = KadPeer(id: NodeID.from(phone: phone), ip: ip, port: port, phone: phone)
        let msg = KademliaTransport.makeConnectRequest(from: localPeer, myPhone: myPhone, toPhone: phone)
        let reply = await sendAndWait(msg, to: peer)
        
        return reply?.type == KadMessageType.connectAccept.rawValue
    }
    
    // MARK: - Bootstrap
    func bootstrap(bootnodes: [(ip: String, port: UInt16, phone: String)]) async {
        print("🚀 Bootstrapping with \(bootnodes.count) bootnodes...")
        
        // Ping all bootnodes
        for node in bootnodes {
            let tempPeer = KadPeer(id: NodeID.random(), ip: node.ip, port: node.port, phone: node.phone)
            let alive = await ping(tempPeer)
            if alive { print("✅ Bootnode \(node.ip):\(node.port) is alive") }
            else { print("❌ Bootnode \(node.ip):\(node.port) unreachable") }
        }
        
        // Find ourselves to populate routing table
        _ = await findNode(localPeer.id)
        
        isBootstrapped = true
        print("🌐 Bootstrap complete. Known peers: \(connectedPeers)")
    }
    
    // MARK: - Send and wait for reply (timeout 5s)
    private func sendAndWait(_ message: KadMessage, to peer: KadPeer) async -> KadMessage? {
        return await withCheckedContinuation { continuation in
            pendingLock.lock()
            pending[message.transactionID] = continuation
            pendingLock.unlock()
            
            transport.send(message, to: peer.ip, port: peer.port)
            
            // Timeout after 5 seconds
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.pendingLock.lock()
                if let cont = self.pending[message.transactionID] {
                    self.pending.removeValue(forKey: message.transactionID)
                    self.pendingLock.unlock()
                    cont.resume(returning: nil)
                } else {
                    self.pendingLock.unlock()
                }
            }
        }
    }
}

extension Notification.Name {
    static let newContactRequest = Notification.Name("newContactRequest")
}

