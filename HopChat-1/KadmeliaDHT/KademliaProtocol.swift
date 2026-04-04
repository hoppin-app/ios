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
 
   // Local DHT key-value store  (key -> value)
   private var storage: [String: String] = [:]
 
   // Pending RPC replies: transactionID -> continuation
   private var pending:     [String: CheckedContinuation<KadMessage?, Never>] = [:]
   private let pendingLock  = NSLock()
 
   // Seen chat message IDs (dedup)
   private var seenChatIDs = Set<String>()
 
   @Published var connectedPeers: Int = 0
   @Published var isBootstrapped:  Bool = false
 
   /// Called on main thread when a chat message arrives.
   /// Parameters: (senderPhone, body, chatID, timestamp)
   var onChatMessage: ((String, String, String, Date) -> Void)?
 
   init(phone: String, ip: String, port: UInt16 = 4001) {
       let id = NodeID.from(phone: phone)
       self.localPeer    = KadPeer(id: id, ip: ip, port: port, phone: phone)
       self.routingTable = RoutingTable(localID: id)
       self.transport    = KademliaTransport(port: port)
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
 
           // Always update routing table with sender
           let sender = KadPeer(id: NodeID(bytes: message.senderID),
                                ip: message.senderIP,
                                port: message.senderPort,
                                phone: message.senderPhone)
           self.routingTable.add(sender)
           self.connectedPeers = self.routingTable.allPeers.count
 
           // Resolve pending RPC if this is a reply
           self.pendingLock.lock()
           if let cont = self.pending[message.transactionID] {
               self.pending.removeValue(forKey: message.transactionID)
               self.pendingLock.unlock()
               cont.resume(returning: message)
               return
           }
           self.pendingLock.unlock()
 
           // Dispatch incoming requests
           Task { await self.handle(message, from: sender) }
       }
   }
 
   // MARK: - Handle Incoming
   private func handle(_ message: KadMessage, from sender: KadPeer) async {
       guard let type = KadMessageType(rawValue: message.type) else { return }
 
       switch type {
 
       case .ping:
           let pong = KademliaTransport.makePong(from: localPeer, replyTo: message.transactionID)
           transport.send(pong, to: sender.ip, port: sender.port)
 
       case .findNode:
           guard let targetBytes = message.targetID else { return }
           let target  = NodeID(bytes: targetBytes)
           let closest = routingTable.closestPeers(to: target)
           let reply   = KademliaTransport.makeFoundNode(from: localPeer, peers: closest,
                                                        replyTo: message.transactionID)
           transport.send(reply, to: sender.ip, port: sender.port)
 
       case .store:
           guard let key = message.key, let value = message.value else { return }
           storage[key] = value
           print("💾 STORE \(key) = \(value)")
 
       case .findValue:
           guard let key = message.key else { return }
           if let value = storage[key] {
               let reply = KademliaTransport.makeFoundValue(from: localPeer, key: key, value: value,
                                                           replyTo: message.transactionID)
               transport.send(reply, to: sender.ip, port: sender.port)
           } else {
               let targetID = NodeID.from(phone: key)
               let closest  = routingTable.closestPeers(to: targetID)
               let reply    = KademliaTransport.makeFoundNode(from: localPeer, peers: closest,
                                                             replyTo: message.transactionID)
               transport.send(reply, to: sender.ip, port: sender.port)
           }
 
       case .connectRequest:
           print("📬 Connect request from \(sender.phone)")
           DispatchQueue.main.async {
               NotificationCenter.default.post(
                   name: .newContactRequest,
                   object: nil,
                   userInfo: ["phone": sender.phone, "ip": sender.ip, "port": sender.port]
               )
           }
           // Auto-accept (TODO: show UI prompt)
           let reply = KademliaTransport.makeConnectAccept(from: localPeer,
                                                          replyTo: message.transactionID)
           transport.send(reply, to: sender.ip, port: sender.port)
 
       case .chatMessage:
           guard let body   = message.chatBody,
                 let chatID = message.chatID else { return }
 
           // Dedup
           guard !seenChatIDs.contains(chatID) else { return }
           seenChatIDs.insert(chatID)
 
           // ACK
           let ack = KademliaTransport.makeChatAck(from: localPeer, chatID: chatID,
                                                   replyTo: message.transactionID)
           transport.send(ack, to: sender.ip, port: sender.port)
 
           // Deliver to UI
           let ts = message.chatTimestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
           DispatchQueue.main.async {
               self.onChatMessage?(sender.phone, body, chatID, ts)
               NotificationCenter.default.post(
                   name: .incomingChatMessage,
                   object: nil,
                   userInfo: ["phone": sender.phone, "body": body,
                              "chatID": chatID, "timestamp": ts]
               )
           }
           print("💬 Chat from \(sender.phone): \(body)")
 
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
       let targetID = NodeID.from(phone: key)
       let closest  = await findNode(targetID)
       storage[key] = value
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
                       let msg   = KademliaTransport.makeFindValue(from: self.localPeer, key: key)
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
 
   // MARK: - Send a chat message to a phone number
   /// Returns the chatID of the sent message, or nil if the peer was not found.
   @discardableResult
   func sendChat(toPhone phone: String, body: String) async -> String? {
       // Try routing table first (populated by Bonjour — most reliable on LAN)
       let peer: KadPeer
       if let direct = routingTable.allPeers.first(where: { $0.phone == phone }) {
           peer = direct
           print("📤 sendChat: using direct peer \(phone) @ \(direct.address)")
       } else if let address = await findValue(key: "user-\(phone)"),
                 let parsed = parsePeer(phone: phone, address: address) {
           peer = parsed
           print("📤 sendChat: using DHT address for \(phone) @ \(parsed.address)")
       } else {
           print("❌ sendChat: peer \(phone) not reachable")
           return nil
       }
 
       let chatID = UUID().uuidString
       let msg    = KademliaTransport.makeChatMessage(from: localPeer, body: body, chatID: chatID)
       let reply  = await sendAndWait(msg, to: peer)
 
       if reply?.type == KadMessageType.chatAck.rawValue {
           print("✅ Chat ACKed by \(phone)")
       } else {
           print("⚠️ No ACK from \(phone) (offline?)")
       }
       return chatID
   }
 
   // MARK: - Connection request
   func requestConnect(toPhone phone: String) async -> Bool {
       guard let address = await findValue(key: "user-\(phone)"),
             let peer    = parsePeer(phone: phone, address: address) else { return false }
       let msg   = KademliaTransport.makeConnectRequest(from: localPeer, toPhone: phone)
       let reply = await sendAndWait(msg, to: peer)
       return reply?.type == KadMessageType.connectAccept.rawValue
   }
 
   // MARK: - Bootstrap
   func bootstrap(peers: [KadPeer]) async {
       for peer in peers {
           _ = await ping(peer)
       }
       _ = await findNode(localPeer.id)
       isBootstrapped = true
       print("🌐 Bootstrap done. Peers: \(connectedPeers)")
   }
 
   // MARK: - Add peer directly (from Bonjour)
   func addPeer(_ peer: KadPeer) {
       routingTable.add(peer)
       connectedPeers = routingTable.allPeers.count
   }
 
   // MARK: - RPC send-and-wait (5 s timeout)
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
 
   // MARK: - Helpers
   private func parsePeer(phone: String, address: String) -> KadPeer? {
       let parts = address.split(separator: ":").map(String.init)
       guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
       return KadPeer(id: NodeID.from(phone: phone), ip: parts[0], port: port, phone: phone)
   }
}
 
extension Notification.Name {
    static let newContactRequest   = Notification.Name("hopchat.newContactRequest")
    static let incomingChatMessage = Notification.Name("hopchat.incomingChatMessage")
}
