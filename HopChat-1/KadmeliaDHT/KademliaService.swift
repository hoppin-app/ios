//
//  KademliaService.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 25/02/2026.
//


import Foundation
import SwiftUI
import Combine


#if targetEnvironment(simulator)
let BOOTSTRAP_IP: String = "127.0.0.1"
#else
let BOOTSTRAP_IP: String = "192.168.1.241"
#endif

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

        // LAN discovery
        startBonjour(phone: phone, port: port, node: kad)

        // Connect to bootstrap
        status = "Connecting to network…"
        let bootstrapPeer = KadPeer(id: NodeID.from(phone: "bootstrap"),
                                    ip: BOOTSTRAP_IP, port: BOOTSTRAP_PORT, phone: "bootstrap")
        await kad.bootstrap(peers: [bootstrapPeer])

        // Announce public address (bootstrap told us via PONG)
        let publicAddr = kad.publicAddress(for: phone) ?? "\(ip):\(port)"
        await kad.store(key: "user-\(phone)", value: publicAddr)
        print("📢 Announced: user-\(phone) = \(publicAddr)")

        isBootstrapped = true
        connectedPeers = kad.connectedPeers
        status = "🟢 Online"

        // Keep-alive ping every 60s
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, let node = self.node else { break }
                let ping = KademliaTransport.makePing(from: node.localPeer)
                node.transport.send(ping, to: BOOTSTRAP_IP, port: BOOTSTRAP_PORT)
                if let addr = node.publicAddress(for: phone) {
                    await node.store(key: "user-\(phone)", value: addr)
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
                    // Resolve address — try routing table first, then DHT
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
        b.publish(phone: phone, port: port)
        b.startBrowsing()
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
        UInt16(4001 + (abs(phone.hashValue) % 999))
    }
}
