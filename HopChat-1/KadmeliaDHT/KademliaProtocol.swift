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

    // DHT storage with TTL
    var storage: [String: DHTEntry] = [:]

    private var seenChatIDs = Set<String>()

    // Rate limiting: phone → timestamps of recent CONNECT_REQUESTs
    private var connectRequestLog: [String: [Date]] = [:]
    private let connectRateLimit  = 5
    private let connectRateWindow: TimeInterval = 60

    // Offline delivery log (bootstrap-side).
    // targetPhone → unique senders that couldn't reach it.
    // In-memory only; acceptable for a bootstrap process that stays running.
    private struct OfflineWaiter {
        let senderPhone: String
        let senderIP:    String
        let senderPort:  UInt16
    }
    private var offlineLog: [String: [OfflineWaiter]] = [:]

    @Published var connectedPeers: Int  = 0
    @Published var isBootstrapped: Bool = false

    var onChatMessage: ((String, String, String, Date) -> Void)?
    /// Fired on the client when bootstrap notifies that a previously offline peer is now reachable.
    /// Parameters: (peerPhone, ip, port)
    var onPeerOnline: ((String, String, UInt16) -> Void)?
    /// Fired when a peer sends a typing indicator. Parameter: senderPhone.
    var onTypingIndicator: ((String) -> Void)?

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

    private func setupEvictionHandler() {
        routingTable.onEvictionNeeded = { [weak self] oldest, newPeer in
            guard let self else { return }
            Task {
                let alive = await self.ping(oldest)
                if !alive {
                    self.routingTable.confirmEvict(oldID: oldest.id, newPeer: newPeer)
                    print("♻️ Evicted unresponsive peer \(oldest.phone), added \(newPeer.phone)")
                }
            }
        }
    }

    // MARK: - Message Handler

    private func setupMessageHandler() {
        transport.onMessage = { [weak self] message, ip, port in
            guard let self else { return }

            let replyPort = message.senderPort
            let replyIP   = message.senderIP.isEmpty || message.senderIP == "0.0.0.0"
                              ? ip
                              : message.senderIP

            let sender = KadPeer(id: NodeID(bytes: message.senderID),
                                 ip: replyIP, port: replyPort,
                                 phone: message.senderPhone)

            // Register peer public keys whenever we see them
            if message.senderPublicKey != nil || message.senderSigningKey != nil {
                CryptoManager.shared.storePeerKeys(
                    phone: sender.phone,
                    agreementKeyBase64: message.senderPublicKey,
                    signingKeyBase64: message.senderSigningKey
                )
            }

            if sender.phone != "bootstrap" {
                self.routingTable.add(sender)
                DispatchQueue.main.async {
                    self.connectedPeers = self.routingTable.allPeers.count
                }
            }

            Task { await self.handle(message, from: sender,
                                     actualIP: replyIP, actualPort: replyPort) }
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
            if let key = message.key, key.hasPrefix("public-addr-"),
               let value = message.value {
                storage[key] = DHTEntry(value: value, storedAt: Date())
                let parts = value.split(separator: ":").map(String.init)
                if parts.count == 2 {
                    print("🌍 My public address (async): \(value)")
                    storage["user-\(localPeer.phone)"] = DHTEntry(value: value, storedAt: Date())
                }
            }

        case .foundNode:
            break

        case .store:
            guard let key = message.key, let value = message.value else { return }
            storage[key] = DHTEntry(value: value, storedAt: Date())

        case .findValue:
            guard let key = message.key else { return }
            if let entry = storage[key], !entry.isExpired {
                let reply = KademliaTransport.makeFoundValue(from: localPeer, key: key,
                                                            value: entry.value,
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
            // Rate limiting
            guard !isRateLimited(phone: sender.phone) else {
                print("⛔ Rate limit: ignoring CONNECT_REQUEST from \(sender.phone)")
                return
            }

            print("📬 Connect request from \(sender.phone)")
            let realSender = KadPeer(id: NodeID.from(phone: sender.phone),
                                     ip: actualIP, port: actualPort,
                                     phone: sender.phone)
            routingTable.add(realSender)
            storage["user-\(sender.phone)"] = DHTEntry(value: "\(actualIP):\(actualPort)",
                                                       storedAt: Date())

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
            storage["user-\(phone)"] = DHTEntry(value: address, storedAt: Date())

            let ping = KademliaTransport.makePing(from: localPeer)
            transport.send(ping, to: peerIP, port: peerPort)

        case .chatMessage:
            guard var body  = message.chatBody,
                  let chatID = message.chatID else { return }
            guard !seenChatIDs.contains(chatID) else { return }
            seenChatIDs.insert(chatID)

            // Verify signature if present
            if let sig = message.signature {
                let payload = CryptoManager.signingPayload(
                    txID: message.transactionID,
                    senderPhone: sender.phone,
                    chatBody: message.chatBody
                )
                if !CryptoManager.shared.verify(payload: payload,
                                                signature: sig,
                                                fromPhone: sender.phone) {
                    print("⚠️ Invalid signature from \(sender.phone) — dropping message")
                    return
                }
                print("✅ Signature verified from \(sender.phone)")
            }

            // Decrypt if encrypted
            if message.encrypted == true {
                if let plaintext = CryptoManager.shared.decrypt(ciphertext: body,
                                                                fromPhone: sender.phone) {
                    body = plaintext
                    print("🔓 Decrypted message from \(sender.phone)")
                } else {
                    print("⚠️ Decryption failed from \(sender.phone) — no shared key yet")
                    // Still deliver undecrypted so user sees something arrived
                }
            }

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

        case .offlineNotify:
            // Bootstrap-side: log that sender couldn't reach the target phone.
            guard let targetPhone = message.key else { return }
            let waiter = OfflineWaiter(senderPhone: sender.phone,
                                       senderIP: actualIP,
                                       senderPort: message.senderPort)
            // Deduplicate: one entry per (sender, target) pair.
            if !(offlineLog[targetPhone] ?? []).contains(where: { $0.senderPhone == waiter.senderPhone }) {
                offlineLog[targetPhone, default: []].append(waiter)
                print("📭 Offline log: \(sender.phone) → \(targetPhone) (\(offlineLog[targetPhone]!.count) waiter(s))")
            }

        case .cameOnline:
            // Bootstrap-side: a peer just reconnected — flush its offline log.
            let onlinePhone = sender.phone
            guard let waiters = offlineLog[onlinePhone], !waiters.isEmpty else { return }
            offlineLog.removeValue(forKey: onlinePhone)
            // Prefer the address the peer announced; fall back to the actual TCP source.
            let onlineAddress = message.value
                ?? storage["user-\(onlinePhone)"]?.value
                ?? "\(actualIP):\(message.senderPort)"
            print("📬 \(onlinePhone) came online — notifying \(waiters.count) waiter(s)")
            for waiter in waiters {
                let notify = KademliaTransport.makePeerOnline(from: localPeer,
                                                              peerPhone: onlinePhone,
                                                              address: onlineAddress)
                transport.send(notify, to: waiter.senderIP, port: waiter.senderPort)
                print("📤 Notified \(waiter.senderPhone) that \(onlinePhone) is reachable")
            }

        case .peerOnline:
            // Client-side: bootstrap tells us a previously offline peer is now reachable.
            guard let peerPhone = message.key,
                  let address   = message.value,
                  let peer      = parsePeer(phone: peerPhone, address: address) else { return }
            routingTable.add(peer)
            storage["user-\(peerPhone)"] = DHTEntry(value: address, storedAt: Date())
            print("🟢 Peer online: \(peerPhone) @ \(address) — will retry queued messages")
            DispatchQueue.main.async {
                self.onPeerOnline?(peerPhone, peer.ip, peer.port)
            }

        case .typingIndicator:
            // Fire-and-forget: tell the UI layer the sender is typing.
            DispatchQueue.main.async {
                self.onTypingIndicator?(sender.phone)
            }

        default:
            break
        }
    }

    // MARK: - Rate Limiting

    private func isRateLimited(phone: String) -> Bool {
        let now   = Date()
        var times = connectRequestLog[phone] ?? []
        times     = times.filter { now.timeIntervalSince($0) < connectRateWindow }
        times.append(now)
        connectRequestLog[phone] = times
        return times.count > connectRateLimit
    }

    // MARK: - Ping

    func ping(_ peer: KadPeer) async -> Bool {
        let msg   = KademliaTransport.makePing(from: localPeer)
        let reply = await transport.sendAndWait(msg, to: peer)
        return reply?.type == KadMessageType.pong.rawValue
    }

    // MARK: - Iterative FIND_NODE  (libp2p spec)

    func findNode(_ target: NodeID) async -> [KadPeer] {
        var asked   = Set<NodeID>()
        var closest = routingTable.closestPeers(to: target, k: KBucket.k)

        var bestDistance: [UInt8]? = closest.first?.id.distance(to: target)

        while true {
            let toAsk = closest.filter { !asked.contains($0.id) && $0.id != localPeer.id }.prefix(3)
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

            for p in newPeers where p.id != localPeer.id {
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

            let newBest = closest.first?.id.distance(to: target)
            if let old = bestDistance, let new = newBest, old == new { break }
            bestDistance = newBest
        }

        return closest
    }

    // MARK: - Store

    func store(key: String, value: String) async {
        storage[key] = DHTEntry(value: value, storedAt: Date())
        let targetID = NodeID.from(phone: key)
        let closest  = await findNode(targetID)
        for peer in closest.prefix(KBucket.k) {
            let msg = KademliaTransport.makeStore(from: localPeer, key: key, value: value)
            transport.send(msg, to: peer.ip, port: peer.port)
        }
    }

    // MARK: - Find Value

    func findValue(key: String) async -> String? {
        if let entry = storage[key], !entry.isExpired { return entry.value }

        var asked   = Set<NodeID>()
        var closest = routingTable.closestPeers(to: NodeID.from(phone: key))

        while true {
            let toAsk = closest.filter { !asked.contains($0.id) && $0.id != localPeer.id }.prefix(3)
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
                    for p in newPeers where p.id != localPeer.id {
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
                                                       chatID: chatID, toPhone: phone)
        let reply  = await transport.sendAndWait(msg, to: peer)
        if reply?.type == KadMessageType.chatAck.rawValue {
            print("✅ Chat ACKed by \(phone)")
        } else {
            print("⚠️ No ACK from \(phone)")
        }
        return reply?.type == KadMessageType.chatAck.rawValue ? chatID : nil
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
                ?? storage["user-bootstrap"].flatMap({ parsePeer(phone: "bootstrap", address: $0.value) })
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

    func bootstrap(peers: [KadPeer]) async {
        for peer in peers {
            let ping  = KademliaTransport.makePing(from: localPeer)
            print("🏓 Sending PING to bootstrap \(peer.ip):\(peer.port)")
            let reply = await transport.sendAndWait(ping, to: peer)
            if let reply {
                print("✅ Bootstrap \(peer.ip):\(peer.port) reachable — type=\(reply.type)")
                storage["user-bootstrap"] = DHTEntry(value: "\(peer.ip):\(peer.port)",
                                                     storedAt: Date())
                let bootstrapPeer = KadPeer(id: NodeID.from(phone: "bootstrap"),
                                            ip: peer.ip, port: peer.port,
                                            phone: "bootstrap")
                routingTable.add(bootstrapPeer)

                if let key = reply.key, key.hasPrefix("public-addr-"),
                   let value = reply.value {
                    storage[key] = DHTEntry(value: value, storedAt: Date())
                    print("🌍 My public address: \(value)")
                    storage["user-\(localPeer.phone)"] = DHTEntry(value: value, storedAt: Date())
                }
            } else {
                print("❌ Bootstrap \(peer.ip):\(peer.port) unreachable (timeout)")
            }
        }

        _ = await findNode(localPeer.id)

        for _ in 0..<3 {
            _ = await findNode(NodeID.random())
        }

        isBootstrapped = true
        print("🌐 Bootstrap done. Peers: \(connectedPeers)")

        // Tell bootstrap we're back online so it can flush its offline-notify log for us.
        if let bs = routingTable.allPeers.first(where: { $0.phone == "bootstrap" }) {
            let msg = KademliaTransport.makeCameOnline(from: localPeer)
            transport.send(msg, to: bs.ip, port: bs.port)
            print("📡 Sent cameOnline to bootstrap")
        }
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
        storage["public-addr-\(phone)"]?.value
    }
}
