//
//  KademliaService.swift
//  HopChat-1
//
import Foundation
import SwiftUI
import Combine
 
@MainActor
final class KademliaService: ObservableObject {
    static let shared = KademliaService()
 
    @Published var isBootstrapped = false
    @Published var connectedPeers = 0
    @Published var status         = "Offline"
    @Published var myPhone: String = ""
 
    private(set) var node:    KademliaProtocol?
    private      var bonjour: BonjourDiscovery?
 
    // MARK: - Register / Join
 
    func register(phone: String) async {
        myPhone = phone
        status  = "Looking up IP…"
 
        let ip = localWiFiIP() ?? "127.0.0.1"
 
        // On simulators, each instance needs a unique port since they share the same IP.
        // We derive a stable port from the phone number so it's always the same for a given user.
        let port = stablePort(for: phone)
        print("📶 IP: \(ip), port: \(port)")
        status = "Starting node…"
 
        let kad = KademliaProtocol(phone: phone, ip: ip, port: port)
        self.node = kad
 
        // Wire incoming chat messages → ConversationStore
        kad.onChatMessage = { [weak self] senderPhone, body, chatID, timestamp in
            guard let self else { return }
            let msg = StoredMessage(id: chatID,
                                   fromPhone: senderPhone,
                                   toPhone: self.myPhone,
                                   body: body,
                                   timestamp: timestamp,
                                   delivered: true,
                                   isFromMe: false)
            ConversationStore.shared.appendMessage(msg)
 
            if ConversationStore.shared.contact(for: senderPhone) == nil {
                let contact = Contact(phone: senderPhone, name: senderPhone,
                                      ip: "", port: 0, addedAt: Date())
                ConversationStore.shared.addContact(contact)
            }
        }
 
        do {
            try kad.start()
        } catch {
            status = "❌ UDP failed: \(error)"
            isBootstrapped = true
            return
        }
 
        // Bonjour discovery
        let bonjour = BonjourDiscovery()
        self.bonjour = bonjour
 
        bonjour.onPeerFound = { [weak self] peer in
            guard let self, let node = self.node else { return }
            let kadPeer = KadPeer(id: NodeID.from(phone: peer.phone),
                                  ip: peer.ip,
                                  port: peer.port,
                                  phone: peer.phone)
            node.addPeer(kadPeer)
            // Store with the port Bonjour gave us (which is their real port)
            Task { await node.store(key: "user-\(peer.phone)", value: "\(peer.ip):\(peer.port)") }
            Task { @MainActor in self.connectedPeers = node.connectedPeers }
            print("🔗 Bonjour peer: \(peer.phone) @ \(peer.ip):\(peer.port)")
        }
 
        bonjour.publish(phone: phone, port: port)
        bonjour.startBrowsing()
 
        // Announce ourselves
        await kad.store(key: "user-\(phone)", value: "\(ip):\(port)")
 
        isBootstrapped = true
        connectedPeers = kad.connectedPeers
        status = "🟢 Online (\(ip):\(port))"
    }
 
    // MARK: - Send a message
 
    func send(body: String, toPhone: String) async {
        guard let node else { return }
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return }
 
        let chatID    = UUID().uuidString
        let timestamp = Date()
        let msg = StoredMessage(id: chatID,
                                fromPhone: myPhone,
                                toPhone: toPhone,
                                body: body,
                                timestamp: timestamp,
                                delivered: false,
                                isFromMe: true)
        ConversationStore.shared.appendMessage(msg)
 
        Task {
            let sentID = await node.sendChat(toPhone: toPhone, body: body)
            if sentID != nil {
                ConversationStore.shared.markDelivered(chatID: chatID,
                                                      peerPhone: toPhone,
                                                      myPhone: myPhone)
            }
        }
    }
 
    // MARK: - Connect to a new contact
 
    func connectTo(phone: String) async -> Bool {
        guard let node else { return false }
        status = "🔗 Connecting to \(phone)…"
 
        // First check if Bonjour already gave us the peer directly
        if let existingPeer = node.routingTable.allPeers.first(where: { $0.phone == phone }) {
            print("✅ Peer found directly in routing table: \(existingPeer.address)")
            if ConversationStore.shared.contact(for: phone) == nil {
                let contact = Contact(phone: phone, name: phone,
                                      ip: existingPeer.ip, port: existingPeer.port,
                                      addedAt: Date())
                ConversationStore.shared.addContact(contact)
            }
            // Send connect request directly
            let msg = KademliaTransport.makeConnectRequest(from: node.localPeer, toPhone: phone)
            let reply = await node.sendAndWait(msg, to: existingPeer)
            let ok = reply?.type == KadMessageType.connectAccept.rawValue
            status = ok ? "✅ Connected to \(phone)" : "❌ No reply from \(phone)"
            return ok
        }
 
        // Fall back to DHT lookup
        let ok = await node.requestConnect(toPhone: phone)
        if ok {
            status = "✅ Connected to \(phone)"
            if ConversationStore.shared.contact(for: phone) == nil {
                let address = await node.findValue(key: "user-\(phone)") ?? ":"
                let parts   = address.split(separator: ":").map(String.init)
                let contact = Contact(phone: phone, name: phone,
                                      ip:   parts.first ?? "",
                                      port: UInt16(parts.last ?? "0") ?? 0,
                                      addedAt: Date())
                ConversationStore.shared.addContact(contact)
            }
        } else {
            status = "❌ Could not reach \(phone)"
        }
        return ok
    }
 
    // MARK: - Stop
 
    func stop() {
        bonjour?.stop()
        node?.transport.stop()
        node = nil
        bonjour = nil
        status = "Offline"
        isBootstrapped = false
    }
 
    // MARK: - Helpers
 
    /// Derives a stable UDP port from the phone number in range 4001-4999.
    /// This ensures two simulators on the same IP don't collide on port 4001.
    private func stablePort(for phone: String) -> UInt16 {
        let hash = abs(phone.hashValue)
        return UInt16(4001 + (hash % 999))
    }
}
 
