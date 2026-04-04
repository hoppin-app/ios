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
    private var pending:     [String: CheckedContinuation<KadMessage?, Never>] = [:]
    private let pendingLock  = NSLock()
    private var seenChatIDs  = Set<String>()

    @Published var connectedPeers: Int  = 0
    @Published var isBootstrapped: Bool = false

    var onChatMessage: ((String, String, String, Date) -> Void)?

    init(phone: String, ip: String, port: UInt16) {
        let id = NodeID.from(phone: phone)
        self.localPeer    = KadPeer(id: id, ip: ip, port: port, phone: phone)
        self.routingTable = RoutingTable(localID: id)
        self.transport    = KademliaTransport(port: port)
        setupMessageHandler()
    }

    func start() throws {
        try transport.startListening()
        print("🟢 Kademlia node started: \(localPeer.id) on port \(localPeer.port)")
    }

    // MARK: - Message Handler
    private func setupMessageHandler() {
        transport.onMessage = { [weak self] message, ip, port in
            guard let self else { return }

            let sender = KadPeer(id: NodeID(bytes: message.senderID),
                                 ip: message.senderIP,
                                 port: message.senderPort,
                                 phone: message.senderPhone)

            // Only add non-bootstrap peers to routing table
            if sender.phone != "bootstrap" {
                self.routingTable.add(sender)
                self.connectedPeers = self.routingTable.allPeers.count
            }

            // Resolve pending RPC
            self.pendingLock.lock()
            if let cont = self.pending[message.transactionID] {
                self.pending.removeValue(forKey: message.transactionID)
                self.pendingLock.unlock()
                cont.resume(returning: message)
                return
            }
            self.pendingLock.unlock()

            Task { await self.handle(message, from: sender, actualIP: ip, actualPort: port) }
        }
    }

    // MARK: - Handle Incoming
    private func handle(_ message: KadMessage, from sender: KadPeer,
                        actualIP: String, actualPort: UInt16) async {
        guard let type = KadMessageType(rawValue: message.type) else { return }

        switch type {

        case .ping:
            let pong = KademliaTransport.makePong(from: localPeer, replyTo: message.transactionID)
            transport.send(pong, to: actualIP, port: actualPort)

        case .pong:
            // Bootstrap piggybacks our public address in key/value
            if let key = message.key, key.hasPrefix("public-addr-"),
               let value = message.value {
                storage[key] = value
                // Update our own public address in DHT
                let parts = value.split(separator: ":").map(String.init)
                if parts.count == 2, let port = UInt16(parts[1]) {
                    let publicIP = parts[0]
                    print("🌍 My public address: \(publicIP):\(port)")
                    // Store our real public address so others can find us
                    storage["user-\(localPeer.phone)"] = value
                }
            }

        case .foundNode:
            // Handled via pending continuation
            break

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
            // Add the requester to routing table using their ACTUAL address
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
            // Bootstrap told us about a peer's public address
            // key = their phone, value = "IP:PORT"
            guard let phone = message.key,
                  let address = message.value else { return }
            let parts = address.split(separator: ":").map(String.init)
            guard parts.count == 2, let port = UInt16(parts[1]) else { return }
            let peerIP = parts[0]

            print("🕳 Hole punch: \(phone) @ \(peerIP):\(port)")
            let peer = KadPeer(id: NodeID.from(phone: phone),
                               ip: peerIP, port: port, phone: phone)
            routingTable.add(peer)
            storage["user-\(phone)"] = address

            // Send a ping immediately to punch the NAT hole
            let ping = KademliaTransport.makePing(from: localPeer)
            transport.send(ping, to: peerIP, port: port)

        case .chatMessage:
            guard let body   = message.chatBody,
                  let chatID = message.chatID else { return }
            guard !seenChatIDs.contains(chatID) else { return }
            seenChatIDs.insert(chatID)

            // Update peer address from actual source
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

        default:
            break
        }
    }

    // MARK: - Ping
    func ping(_ peer: KadPeer) async -> Bool {
        let msg   = KademliaTransport.makePing(from: localPeer)
        let reply = await sendAndWait(msg, to: peer)
        return reply?.type == KadMessageType.pong.rawValue
    }

    // MARK: - Iterative FIND_NODE
    func findNode(_ target: NodeID) async -> [KadPeer] {
        var asked   = Set<NodeID>()
        var closest = routingTable.closestPeers(to: target)

        while true {
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
            closest = closest.sorted {
                $0.id.distance(to: target).lexicographicallyPrecedes($1.id.distance(to: target))
            }.prefix(KBucket.k).map { $0 }
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
                        guard let reply = await self.sendAndWait(msg, to: peer) else { return (nil, []) }
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
        // Try routing table first (fastest)
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
        let msg    = KademliaTransport.makeChatMessage(from: localPeer, body: body, chatID: chatID)
        let reply  = await sendAndWait(msg, to: peer)
        if reply?.type == KadMessageType.chatAck.rawValue {
            print("✅ Chat ACKed by \(phone)")
        } else {
            print("⚠️ No ACK from \(phone)")
        }
        return chatID
    }

    // MARK: - Connect Request (goes through bootstrap for hole punching)
    func requestConnect(toPhone phone: String) async -> Bool {
        // First try direct if we already know them
        if let direct = routingTable.allPeers.first(where: { $0.phone == phone }) {
            let msg   = KademliaTransport.makeConnectRequest(from: localPeer, toPhone: phone)
            let reply = await sendAndWait(msg, to: direct)
            if reply?.type == KadMessageType.connectAccept.rawValue { return true }
        }

        // Ask bootstrap to coordinate hole punch
        // Bootstrap will send HOLE_PUNCH to both sides
        guard let bootstrap = routingTable.allPeers.first(where: { $0.phone == "bootstrap" })
                ?? storage["user-bootstrap"].flatMap({ parsePeer(phone: "bootstrap", address: $0) })
        else {
            print("❌ No bootstrap peer known")
            return false
        }

        let msg   = KademliaTransport.makeConnectRequest(from: localPeer, toPhone: phone)
        let reply = await sendAndWait(msg, to: bootstrap)

        // Bootstrap responds with HOLE_PUNCH (handled in handle()), not connect accept
        // Give hole punch time to work (both sides ping each other)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Now try direct
        if let direct = routingTable.allPeers.first(where: { $0.phone == phone }) {
            let msg2  = KademliaTransport.makeConnectRequest(from: localPeer, toPhone: phone)
            let reply2 = await sendAndWait(msg2, to: direct)
            return reply2?.type == KadMessageType.connectAccept.rawValue
        }
        return false
    }

    // MARK: - Bootstrap
    func bootstrap(peers: [KadPeer]) async {
        for peer in peers {
            let msg   = KademliaTransport.makePing(from: localPeer)
            let reply = await sendAndWait(msg, to: peer)
            if reply != nil {
                // Store bootstrap peer for later hole punch requests
                storage["user-bootstrap"] = "\(peer.ip):\(peer.port)"
                let bootstrapPeer = KadPeer(id: NodeID.from(phone: "bootstrap"),
                                            ip: peer.ip, port: peer.port, phone: "bootstrap")
                routingTable.add(bootstrapPeer)
                print("✅ Bootstrap \(peer.ip):\(peer.port) reachable")
            } else {
                print("❌ Bootstrap \(peer.ip):\(peer.port) unreachable")
            }
        }
        _ = await findNode(localPeer.id)
        isBootstrapped = true
        print("🌐 Bootstrap done. Peers: \(connectedPeers)")
    }

    func addPeer(_ peer: KadPeer) {
        routingTable.add(peer)
        connectedPeers = routingTable.allPeers.count
    }

    // MARK: - RPC send-and-wait (5s timeout)
    func sendAndWait(_ message: KadMessage, to peer: KadPeer) async -> KadMessage? {
        await withCheckedContinuation { cont in
            pendingLock.lock()
            pending[message.transactionID] = cont
            pendingLock.unlock()

            transport.send(message, to: peer.ip, port: peer.port)

            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                pendingLock.lock()
                if let c = pending[message.transactionID] {
                    pending.removeValue(forKey: message.transactionID)
                    pendingLock.unlock()
                    c.resume(returning: nil)
                } else {
                    pendingLock.unlock()
                }
            }
        }
    }

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

// MARK: - Public address helper (used by KademliaService)
extension KademliaProtocol {
    /// Returns the public IP:PORT that the bootstrap server observed for this phone.
    func publicAddress(for phone: String) -> String? {
        storage["public-addr-\(phone)"]
    }
}
