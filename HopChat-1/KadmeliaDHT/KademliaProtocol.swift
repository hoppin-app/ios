//
//  KademliaProtocol.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 25/02/2026.
//

import Foundation
import SwiftUI
import Combine
 
final class KademliaProtocol: ObservableObject {
    let localPeer:    KadPeer
    let routingTable: RoutingTable
    let transport:    KademliaTransport
 
    var storage: [String: String] = [:]
 
    private var seenChatIDs = Set<String>()
 
    @Published var connectedPeers: Int  = 0
    @Published var isBootstrapped: Bool = false
 
    var onChatMessage: ((String, String, String, Date) -> Void)?
 
    init(phone: String, ip: String, port: UInt16) {
        let id = NodeID.from(phone: phone)
        self.localPeer    = KadPeer(id: id, ip: ip, port: port, phone: phone)
        self.routingTable = RoutingTable(localID: id)
        self.transport    = KademliaTransport(port: port)
        setupMessageHandler()
        setupEvictionHandler()
    }
 
    func start() throws {
        try transport.startListening()
        print("🟢 Kademlia node started: \(localPeer.id) on port \(localPeer.port)")
    }
 
    // MARK: - Eviction handler (ping-before-evict)
    //
    // When a k-bucket is full and a new peer arrives, the routing table calls
    // this closure with (oldest, new).  We ping `oldest`; if it replies it
    // stays and `new` is dropped.  If it times out we evict it and confirm
    // the insertion of `new`.
 
    private func setupEvictionHandler() {
        routingTable.onEvictionNeeded = { [weak self] oldest, newPeer in
            guard let self else { return }
            Task {
                let alive = await self.ping(oldest)
                if !alive {
                    self.routingTable.confirmEvict(oldID: oldest.id, newPeer: newPeer)
                    print("♻️ Evicted unresponsive peer \(oldest.phone), added \(newPeer.phone)")
                }
                // If alive, the bucket keeps `oldest` and silently drops `newPeer`.
            }
        }
    }
 
    // MARK: - Message Handler
    //
    // FIX (retained from previous version): resolve pending continuations
    // immediately on the transport queue to avoid the main-actor deadlock
    // that caused bootstrap PINGs to always time out.
 
    private func setupMessageHandler() {
        transport.onMessage = { [weak self] message, ip, port in
            guard let self else { return }
 
            let sender = KadPeer(id: NodeID(bytes: message.senderID),
                                 ip: ip, port: port,
                                 phone: message.senderPhone)
 
            if sender.phone != "bootstrap" {
                self.routingTable.add(sender)
                DispatchQueue.main.async {
                    self.connectedPeers = self.routingTable.allPeers.count
                }
            }
 
            Task { await self.handle(message, from: sender, actualIP: ip, actualPort: port) }
        }
    }
 
    // MARK: - Handle Incoming (unsolicited messages only)
 
    private func handle(_ message: KadMessage, from sender: KadPeer,
                        actualIP: String, actualPort: UInt16) async {
        guard let type = KadMessageType(rawValue: message.type) else { return }
 
        switch type {
 
        case .ping:
            let pong = KademliaTransport.makePong(from: localPeer,
                                                  replyTo: message.transactionID)
            transport.send(pong, to: actualIP, port: actualPort)
 
        case .pong:
            // Unsolicited PONG (keepalive reply or spontaneous).
            // Normal PING→PONG RPCs are resolved in the pending-continuation
            // dict inside KademliaTransport before reaching here.
            if let key = message.key, key.hasPrefix("public-addr-"),
               let value = message.value {
                storage[key] = value
                let parts = value.split(separator: ":").map(String.init)
                if parts.count == 2 {
                    print("🌍 My public address (async): \(value)")
                    storage["user-\(localPeer.phone)"] = value
                }
            }
 
        case .foundNode:
            break   // handled via pending continuation
 
        case .store:
            guard let key = message.key, let value = message.value else { return }
            storage[key] = value
 
        case .findValue:
            guard let key = message.key else { return }
            if let value = storage[key] {
                let reply = KademliaTransport.makeFoundValue(from: localPeer, key: key,
                                                            value: value,
                                                            replyTo: message.transactionID)
                transport.send(reply, to: actualIP, port: actualPort)
            } else {
                let closest = routingTable.closestPeers(to: NodeID.from(phone: key))
                let reply   = KademliaTransport.makeFoundNode(from: localPeer, peers: closest,
                                                             replyTo: message.transactionID)
                transport.send(reply, to: actualIP, port: actualPort)
            }
 
        case .findNode:
            guard let targetBytes = message.targetID else { return }
            let target  = NodeID(bytes: targetBytes)
            let closest = routingTable.closestPeers(to: target)
            let reply   = KademliaTransport.makeFoundNode(from: localPeer, peers: closest,
                                                         replyTo: message.transactionID)
            transport.send(reply, to: actualIP, port: actualPort)
 
        case .connectRequest:
            print("📬 Connect request from \(sender.phone)")
            let realSender = KadPeer(id: NodeID.from(phone: sender.phone),
                                     ip: actualIP, port: actualPort,
                                     phone: sender.phone)
            routingTable.add(realSender)
            storage["user-\(sender.phone)"] = "\(actualIP):\(actualPort)"
 
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .newContactRequest, object: nil,
                    userInfo: ["phone": sender.phone, "ip": actualIP, "port": actualPort]
                )
            }
            let reply = KademliaTransport.makeConnectAccept(from: localPeer,
                                                           replyTo: message.transactionID)
            transport.send(reply, to: actualIP, port: actualPort)
 
        case .holePunch:
            guard let phone   = message.key,
                  let address = message.value else { return }
            let parts = address.split(separator: ":").map(String.init)
            guard parts.count == 2, let peerPort = UInt16(parts[1]) else { return }
            let peerIP = parts[0]
 
            print("🕳 Hole punch: \(phone) @ \(peerIP):\(peerPort)")
            let peer = KadPeer(id: NodeID.from(phone: phone),
                               ip: peerIP, port: peerPort, phone: phone)
            routingTable.add(peer)
            storage["user-\(phone)"] = address
 
            let ping = KademliaTransport.makePing(from: localPeer)
            transport.send(ping, to: peerIP, port: peerPort)
 
        case .chatMessage:
            guard let body   = message.chatBody,
                  let chatID = message.chatID else { return }
            guard !seenChatIDs.contains(chatID) else { return }
            seenChatIDs.insert(chatID)
 
            let realSender = KadPeer(id: NodeID.from(phone: sender.phone),
                                     ip: actualIP, port: actualPort,
                                     phone: sender.phone)
            routingTable.add(realSender)
 
            let ack = KademliaTransport.makeChatAck(from: localPeer, chatID: chatID,
                                                    replyTo: message.transactionID)
            transport.send(ack, to: actualIP, port: actualPort)
 
            let ts = message.chatTimestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
            DispatchQueue.main.async {
                self.onChatMessage?(sender.phone, body, chatID, ts)
                NotificationCenter.default.post(
                    name: .incomingChatMessage, object: nil,
                    userInfo: ["phone": sender.phone, "body": body,
                               "chatID": chatID, "timestamp": ts]
                )
            }
 
        case .relay:
            guard let innerJSON = message.value,
                  let innerData = innerJSON.data(using: .utf8),
                  let innerMsg  = try? JSONDecoder().decode(KadMessage.self, from: innerData)
            else { return }
            await handle(innerMsg, from: sender,
                         actualIP: innerMsg.senderIP, actualPort: innerMsg.senderPort)
 
        default:
            break
        }
    }
 
    // MARK: - Ping
 
    func ping(_ peer: KadPeer) async -> Bool {
        let msg   = KademliaTransport.makePing(from: localPeer)
        let reply = await transport.sendAndWait(msg, to: peer)
        return reply?.type == KadMessageType.pong.rawValue
    }
 
    // MARK: - Iterative FIND_NODE  (libp2p spec)
    //
    // Contacts α=3 peers concurrently per round, adding discovered peers to
    // the candidate list.  Terminates when either:
    //   (a) no unasked peers remain, or
    //   (b) a full round produces no candidate closer than the current best.
    // Condition (b) is the key addition over the previous implementation.
 
    func findNode(_ target: NodeID) async -> [KadPeer] {
        var asked   = Set<NodeID>()
        var closest = routingTable.closestPeers(to: target, k: KBucket.k)
 
        // Snapshot the best distance before the first round.
        var bestDistance: [UInt8]? = closest.first?.id.distance(to: target)
 
        while true {
            let toAsk = closest.filter { !asked.contains($0.id) }.prefix(3)
            guard !toAsk.isEmpty else { break }
 
            var newPeers: [KadPeer] = []
            await withTaskGroup(of: [KadPeer].self) { group in
                for peer in toAsk {
                    asked.insert(peer.id)
                    group.addTask {
                        let msg = KademliaTransport.makeFindNode(from: self.localPeer,
                                                                 target: target)
                        guard let reply = await self.transport.sendAndWait(msg, to: peer),
                              let peers = reply.peers else { return [] }
                        return peers.map { $0.toKadPeer() }
                    }
                }
                for await peers in group { newPeers += peers }
            }
 
            for p in newPeers {
                routingTable.add(p)
                if !closest.contains(p) { closest.append(p) }
            }
 
            closest = closest
                .sorted {
                    $0.id.distance(to: target)
                        .lexicographicallyPrecedes($1.id.distance(to: target))
                }
                .prefix(KBucket.k)
                .map { $0 }
 
            // Termination condition (b): stop if no closer node was found.
            let newBest = closest.first?.id.distance(to: target)
            if let old = bestDistance, let new = newBest, old == new {
                break
            }
            bestDistance = newBest
        }
 
        return closest
    }
 
    // MARK: - Store
 
    func store(key: String, value: String) async {
        storage[key] = value
        let targetID = NodeID.from(phone: key)
        let closest  = await findNode(targetID)
        for peer in closest.prefix(KBucket.k) {
            let msg = KademliaTransport.makeStore(from: localPeer, key: key, value: value)
            transport.send(msg, to: peer.ip, port: peer.port)
        }
    }
 
    // MARK: - Find Value
 
    func findValue(key: String) async -> String? {
        if let local = storage[key] { return local }
 
        var asked   = Set<NodeID>()
        var closest = routingTable.closestPeers(to: NodeID.from(phone: key))
 
        while true {
            let toAsk = closest.filter { !asked.contains($0.id) }.prefix(3)
            guard !toAsk.isEmpty else { break }
 
            var found: String?
            await withTaskGroup(of: (String?, [KadPeer]).self) { group in
                for peer in toAsk {
                    asked.insert(peer.id)
                    group.addTask {
                        let msg = KademliaTransport.makeFindValue(from: self.localPeer, key: key)
                        guard let reply = await self.transport.sendAndWait(msg, to: peer) else {
                            return (nil, [])
                        }
                        if reply.type == KadMessageType.foundValue.rawValue {
                            return (reply.value, [])
                        }
                        return (nil, reply.peers?.map { $0.toKadPeer() } ?? [])
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
 
    // MARK: - Send Chat
 
    @discardableResult
    func sendChat(toPhone phone: String, body: String) async -> String? {
        let peer: KadPeer
        if let direct = routingTable.allPeers.first(where: { $0.phone == phone }) {
            peer = direct
        } else if let address = await findValue(key: "user-\(phone)"),
                  let parsed = parsePeer(phone: phone, address: address) {
            peer = parsed
        } else {
            print("❌ sendChat: \(phone) not reachable")
            return nil
        }
 
        let chatID = UUID().uuidString
        let msg    = KademliaTransport.makeChatMessage(from: localPeer, body: body,
                                                       chatID: chatID)
        let reply  = await transport.sendAndWait(msg, to: peer)
        if reply?.type == KadMessageType.chatAck.rawValue {
            print("✅ Chat ACKed by \(phone)")
        } else {
            print("⚠️ No ACK from \(phone)")
        }
        return chatID
    }
 
    // MARK: - Connect Request
 
    func requestConnect(toPhone phone: String) async -> Bool {
        if let direct = routingTable.allPeers.first(where: { $0.phone == phone }) {
            print("🎯 Trying direct connect to \(phone) @ \(direct.ip):\(direct.port)")
            let msg   = KademliaTransport.makeConnectRequest(from: localPeer, toPhone: phone)
            let reply = await transport.sendAndWait(msg, to: direct)
            if reply?.type == KadMessageType.connectAccept.rawValue { return true }
        }
 
        guard let bootstrap = routingTable.allPeers.first(where: { $0.phone == "bootstrap" })
                ?? storage["user-bootstrap"].flatMap({ parsePeer(phone: "bootstrap", address: $0) })
        else {
            print("❌ No bootstrap peer known")
            return false
        }
 
        let msg = KademliaTransport.makeConnectRequest(from: localPeer, toPhone: phone)
        _ = await transport.sendAndWait(msg, to: bootstrap)
 
        try? await Task.sleep(nanoseconds: 2_000_000_000)
 
        if let direct = routingTable.allPeers.first(where: { $0.phone == phone }) {
            let msg2   = KademliaTransport.makeConnectRequest(from: localPeer, toPhone: phone)
            let reply2 = await transport.sendAndWait(msg2, to: direct)
            return reply2?.type == KadMessageType.connectAccept.rawValue
        }
 
        if let bs = routingTable.allPeers.first(where: { $0.phone == "bootstrap" }),
           let relayMsg = KademliaTransport.makeRelay(
               from: localPeer, toPhone: phone,
               wrapping: KademliaTransport.makeConnectRequest(from: localPeer, toPhone: phone)) {
            let reply = await transport.sendAndWait(relayMsg, to: bs)
            return reply?.type == KadMessageType.connectAccept.rawValue
        }
        return false
    }
 
    // MARK: - Bootstrap  (libp2p spec)
    //
    // Step 1: Ping each bootstrap peer to enter the network (unchanged).
    // Step 2: Look up our own ID — populates the k-buckets closest to us.
    // Step 3: Look up several random IDs — populates the rest of the 256
    //         buckets so we build awareness of the whole keyspace.
    //
    // The libp2p spec says: "The process starts by generating a random peer
    // ID and looking it up … The node then adds the closest peers it
    // discovers to its routing table and repeats the process multiple times.
    // This process also includes looking up its own peer ID."
 
    func bootstrap(peers: [KadPeer]) async {
        // Step 1 — contact bootstrap peers
        for peer in peers {
            let ping  = KademliaTransport.makePing(from: localPeer)
            print("🏓 Sending PING to bootstrap \(peer.ip):\(peer.port)")
            let reply = await transport.sendAndWait(ping, to: peer)
            if let reply {
                print("✅ Bootstrap \(peer.ip):\(peer.port) reachable — type=\(reply.type)")
                storage["user-bootstrap"] = "\(peer.ip):\(peer.port)"
                let bootstrapPeer = KadPeer(id: NodeID.from(phone: "bootstrap"),
                                            ip: peer.ip, port: peer.port,
                                            phone: "bootstrap")
                routingTable.add(bootstrapPeer)
 
                if let key = reply.key, key.hasPrefix("public-addr-"),
                   let value = reply.value {
                    storage[key] = value
                    print("🌍 My public address: \(value)")
                    storage["user-\(localPeer.phone)"] = value
                }
            } else {
                print("❌ Bootstrap \(peer.ip):\(peer.port) unreachable (timeout)")
            }
        }
 
        // Step 2 — self-lookup (builds awareness of nodes close to us)
        _ = await findNode(localPeer.id)
 
        // Step 3 — random lookups (builds awareness across all 256 buckets)
        // Three iterations is the typical libp2p default.
        for _ in 0..<3 {
            _ = await findNode(NodeID.random())
        }
 
        isBootstrapped = true
        print("🌐 Bootstrap done. Peers: \(connectedPeers)")
    }
 
    func addPeer(_ peer: KadPeer) {
        routingTable.add(peer)
        connectedPeers = routingTable.allPeers.count
    }
 
    // MARK: - Helpers
 
    private func parsePeer(phone: String, address: String) -> KadPeer? {
        let parts = address.split(separator: ":").map(String.init)
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return KadPeer(id: NodeID.from(phone: phone), ip: parts[0], port: port, phone: phone)
    }
}
 
// MARK: - Notification Names
 
extension Notification.Name {
    static let newContactRequest   = Notification.Name("hopchat.newContactRequest")
    static let incomingChatMessage = Notification.Name("hopchat.incomingChatMessage")
}
 
// MARK: - Public address helper
 
extension KademliaProtocol {
    func publicAddress(for phone: String) -> String? {
        storage["public-addr-\(phone)"]
    }
}
