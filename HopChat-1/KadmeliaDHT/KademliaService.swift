//
//  KademliaService.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 25/02/2026.
//

import Foundation
import SwiftUI
import Combine
 
let BOOTSTRAP_IP:   String = "34.14.80.215"
let BOOTSTRAP_PORT: UInt16 = 4001
 
@MainActor
final class KademliaService: ObservableObject {
    static let shared = KademliaService()
 
    @Published var isBootstrapped = false
    @Published var connectedPeers = 0
    @Published var status         = "Offline"
    @Published var myPhone: String = ""
 
    private(set) var node:    KademliaProtocol?
    private      var bonjour: BonjourDiscovery?
    private      var keepAliveTask: Task<Void, Never>?
 
    // MARK: - Register
 
    func register(phone: String) async {
        myPhone = phone
        status  = "Starting…"
 
        let ip   = localWiFiIP() ?? "0.0.0.0"
        let port = stablePort(for: phone)
        print("📶 Local: \(ip):\(port)")
 
        let kad = KademliaProtocol(phone: phone, ip: ip, port: port)
        self.node = kad
 
        kad.onChatMessage = { [weak self] senderPhone, body, chatID, timestamp in
            guard let self else { return }
            let msg = StoredMessage(id: chatID, fromPhone: senderPhone,
                                   toPhone: self.myPhone, body: body,
                                   timestamp: timestamp, delivered: true, isFromMe: false)
            ConversationStore.shared.appendMessage(msg)
            if ConversationStore.shared.contact(for: senderPhone) == nil {
                ConversationStore.shared.addContact(
                    Contact(phone: senderPhone, name: senderPhone,
                            ip: "", port: 0, addedAt: Date())
                )
            }
        }
 
        do { try kad.start() } catch {
            status = "❌ UDP failed: \(error)"
            isBootstrapped = true
            return
        }
 
        // LAN discovery via Bonjour
        startBonjour(phone: phone, port: port, node: kad)
 
        // ── Bootstrap ──────────────────────────────────────────────────────
        //
        // NAT problem and fix:
        //
        // When the phone sends a UDP packet through its router, the router
        // creates a NAT mapping:
        //
        //   phone_LAN:port  →  phone_public_ip:RANDOM_PORT  →  bootstrap:4001
        //
        // The public port is assigned by the router and is almost never the
        // same as our local port.  We don't know what it is until a reply
        // arrives from outside.
        //
        // The bootstrap server echoes our public address back in the PONG:
        //   key   = "public-addr-<phone>"
        //   value = "<public_ip>:<public_port>"
        //
        // So the correct sequence is:
        //   1. PING bootstrap  →  PONG arrives with our public address
        //   2. Only THEN announce "user-<phone>" with the public address
        //
        // Previously the store() happened before (or concurrently with) the
        // PONG, so the LAN address was announced instead of the public one.
        // Now bootstrap() waits for the PONG before returning, so by the time
        // we call store() the public address is already in storage.
        //
        // The bootstrap server also has a STORE override (see _handle_store)
        // that corrects the address to the public one it observed, so this is
        // belt-and-suspenders — both sides independently ensure the right
        // address ends up in the DHT.
        // ──────────────────────────────────────────────────────────────────
 
        status = "Connecting to network…"
        let bootstrapPeer = KadPeer(id: NodeID.from(phone: "bootstrap"),
                                    ip: BOOTSTRAP_IP, port: BOOTSTRAP_PORT,
                                    phone: "bootstrap")
 
        // bootstrap() now returns only after the PONG (and thus the public
        // address) has been received and stored.
        await kad.bootstrap(peers: [bootstrapPeer])
 
        // At this point storage["public-addr-<phone>"] is populated by the
        // PONG handler in KademliaProtocol.  publicAddress(for:) reads it.
        if let publicAddr = kad.publicAddress(for: phone) {
            await kad.store(key: "user-\(phone)", value: publicAddr)
            print("📢 Announced public address: user-\(phone) = \(publicAddr)")
        } else {
            // Bootstrap was unreachable (the node may be offline or the network
            // restricted).  Announce the LAN address so at least local peers
            // on the same WiFi can find us via the DHT.
            let lanAddr = "\(ip):\(port)"
            await kad.store(key: "user-\(phone)", value: lanAddr)
            print("⚠️ Bootstrap unreachable — announced LAN address: user-\(phone) = \(lanAddr)")
        }
 
        isBootstrapped = true
        connectedPeers = kad.connectedPeers
        status = "🟢 Online"
 
        // ── Keep-alive ─────────────────────────────────────────────────────
        //
        // Sends a PING to bootstrap every 60 s to:
        //   (a) keep the NAT mapping alive (most routers time out at ~120 s)
        //   (b) learn our current public port if it changed (some routers
        //       reassign the external port after a period of inactivity)
        //
        // After each PONG we re-announce with the fresh public address.
        // ──────────────────────────────────────────────────────────────────
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, let node = self.node else { break }
 
                let ping = KademliaTransport.makePing(from: node.localPeer)
                node.transport.send(ping, to: BOOTSTRAP_IP, port: BOOTSTRAP_PORT)
 
                // Wait 2 s for the PONG to arrive and update storage.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
 
                if let addr = node.publicAddress(for: phone) {
                    await node.store(key: "user-\(phone)", value: addr)
                    print("🔄 Re-announced: user-\(phone) = \(addr)")
                }
 
                await MainActor.run { self.connectedPeers = node.connectedPeers }
            }
        }
    }
 
    // MARK: - Send
 
    func send(body: String, toPhone: String) async {
        guard let node, !body.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let chatID = UUID().uuidString
        ConversationStore.shared.appendMessage(
            StoredMessage(id: chatID, fromPhone: myPhone, toPhone: toPhone,
                          body: body, timestamp: Date(), delivered: false, isFromMe: true)
        )
        Task {
            let sent = await node.sendChat(toPhone: toPhone, body: body)
            if sent != nil {
                ConversationStore.shared.markDelivered(chatID: chatID,
                                                      peerPhone: toPhone, myPhone: myPhone)
            }
        }
    }
 
    // MARK: - Connect
 
    func connectTo(phone: String) async -> Bool {
        guard let node else { return false }
        status = "🔗 Connecting to \(phone)…"
        let ok = await node.requestConnect(toPhone: phone)
        if ok {
            status = "✅ Connected to \(phone)"
            if ConversationStore.shared.contact(for: phone) == nil {
                let addr: String
                if let direct = node.routingTable.allPeers.first(where: { $0.phone == phone }) {
                    addr = "\(direct.ip):\(direct.port)"
                } else {
                    addr = await node.findValue(key: "user-\(phone)") ?? ":"
                }
                let parts = addr.split(separator: ":").map(String.init)
                ConversationStore.shared.addContact(
                    Contact(phone: phone, name: phone,
                            ip:   parts.first ?? "",
                            port: UInt16(parts.last ?? "0") ?? 0,
                            addedAt: Date())
                )
            }
        } else {
            status = "❌ Could not reach \(phone)"
        }
        return ok
    }
 
    // MARK: - Bonjour
 
    private func startBonjour(phone: String, port: UInt16, node: KademliaProtocol) {
        let b = BonjourDiscovery()
        self.bonjour = b
        b.onPeerFound = { [weak node] peer in
            guard let node else { return }
            node.addPeer(KadPeer(id: NodeID.from(phone: peer.phone),
                                 ip: peer.ip, port: peer.port, phone: peer.phone))
            Task { await node.store(key: "user-\(peer.phone)", value: "\(peer.ip):\(peer.port)") }
        }
 
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            b.publish(phone: phone, port: port)
            b.startBrowsing()
        }
    }
 
    // MARK: - Stop
 
    func stop() {
        keepAliveTask?.cancel()
        bonjour?.stop()
        node?.transport.stop()
        node = nil; bonjour = nil
        status = "Offline"; isBootstrapped = false
    }
 
    private func stablePort(for phone: String) -> UInt16 {
        let n = phone.unicodeScalars.reduce(0) { $0 &+ UInt32($1.value) }
        return UInt16(4100 + (n % 900))
    }
}
