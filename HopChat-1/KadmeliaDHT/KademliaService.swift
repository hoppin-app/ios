//
//  KademliaService.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 25/02/2026.
//

import Foundation
import SwiftUI
import Combine

// MARK: - Presence

enum PresenceStatus: String {
    case online   = "Online"
    case recently = "Recently active"
    case offline  = "Offline"
}

// MARK: - Service

@MainActor
final class KademliaService: ObservableObject {
    static let shared = KademliaService()

    @Published var isBootstrapped = false
    @Published var connectedPeers = 0
    @Published var status         = "Offline"
    @Published var myPhone: String = ""
    @Published var lastError: String?
    @Published var presenceMap: [String: PresenceStatus] = [:]

    private(set) var node:    KademliaProtocol?
    private      var bonjour: BonjourDiscovery?
    private      var keepAliveTask: Task<Void, Never>?

    // MARK: - Register

    func register(phone: String) async {
        myPhone = phone
        status  = "Starting…"
        NotificationService.shared.requestPermission()

        let ip   = localWiFiIP() ?? "0.0.0.0"
        let port = stablePort(for: phone)
        print("📶 Local: \(ip):\(port)")

        let kad = KademliaProtocol(phone: phone, ip: ip, port: port)
        self.node = kad

        // Load persisted peers before bootstrap for faster startup
        loadPersistedPeers(into: kad)

        kad.onChatMessage = { [weak self] senderPhone, body, chatID, timestamp in
            guard let self else { return }
            Task { @MainActor in
                let translated = await TranslationService.shared.autoTranslate(body: body)
                var msg = StoredMessage(id: chatID, fromPhone: senderPhone,
                                       toPhone: self.myPhone, body: body,
                                       timestamp: timestamp, delivered: true, isFromMe: false)
                msg.translatedBody = translated
                ConversationStore.shared.appendMessage(msg)
                NotificationService.shared.post(from: senderPhone, body: body)
                if ConversationStore.shared.contact(for: senderPhone) == nil {
                    ConversationStore.shared.addContact(
                        Contact(phone: senderPhone, name: senderPhone,
                                ip: "", port: 0, addedAt: Date())
                    )
                }
            }
        }

        do { try kad.start() } catch {
            status = "❌ Failed to start: \(error.localizedDescription)"
            isBootstrapped = true
            return
        }

        startBonjour(phone: phone, port: port, node: kad)

        status = "Connecting to network…"
        let bootstrapPeer = KadPeer(id: NodeID.from(phone: "bootstrap"),
                                    ip: AppConfig.bootstrapIP,
                                    port: AppConfig.bootstrapPort,
                                    phone: "bootstrap")

        await kad.bootstrap(peers: [bootstrapPeer])

        if let publicAddr = kad.publicAddress(for: phone) {
            await kad.store(key: "user-\(phone)", value: publicAddr)
            print("📢 Announced public address: user-\(phone) = \(publicAddr)")
        } else {
            let lanAddr = "\(ip):\(port)"
            await kad.store(key: "user-\(phone)", value: lanAddr)
            print("⚠️ Bootstrap unreachable — announced LAN address: user-\(phone) = \(lanAddr)")
        }

        // When bootstrap tells us a peer came online, retry any messages we couldn't deliver.
        kad.onPeerOnline = { [weak self] phone, _, _ in
            guard let self else { return }
            Task { await self.retryUndelivered(for: phone) }
        }

        isBootstrapped = true
        connectedPeers = kad.connectedPeers
        status = "🟢 Online"

        persistPeers(from: kad)

        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, let node = self.node else { break }

                let ping = KademliaTransport.makePing(from: node.localPeer)
                node.transport.send(ping, to: AppConfig.bootstrapIP, port: AppConfig.bootstrapPort)

                try? await Task.sleep(nanoseconds: 2_000_000_000)

                if let addr = node.publicAddress(for: phone) {
                    await node.store(key: "user-\(phone)", value: addr)
                    print("🔄 Re-announced: user-\(phone) = \(addr)")
                }

                await MainActor.run {
                    self.connectedPeers = node.connectedPeers
                    self.updatePresenceMap(from: node)
                    self.persistPeers(from: node)
                }
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
            } else {
                await MainActor.run {
                    self.lastError = "Couldn't reach \(toPhone). Will deliver when they reconnect."
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await MainActor.run { self.lastError = nil }
                    }
                }
                // Notify bootstrap so it can alert us when the peer comes back online.
                if let bs = node.routingTable.allPeers.first(where: { $0.phone == "bootstrap" }) {
                    let notify = KademliaTransport.makeOfflineNotify(from: node.localPeer,
                                                                      targetPhone: toPhone)
                    node.transport.send(notify, to: bs.ip, port: bs.port)
                    print("📭 Registered offline-notify for \(toPhone) with bootstrap")
                }
            }
        }
    }

    // MARK: - Offline Retry

    private func retryUndelivered(for phone: String) async {
        guard let node else { return }
        let undelivered = ConversationStore.shared
            .thread(with: phone, myPhone: myPhone)
            .filter { $0.isFromMe && !$0.delivered }
        guard !undelivered.isEmpty else { return }
        print("🔄 Retrying \(undelivered.count) undelivered message(s) for \(phone)")
        for msg in undelivered {
            let sent = await node.sendChat(toPhone: phone, body: msg.body)
            if sent != nil {
                ConversationStore.shared.markDelivered(chatID: msg.id,
                                                       peerPhone: phone, myPhone: myPhone)
                print("✅ Offline-queued message delivered to \(phone): \(msg.id.prefix(8))")
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

    // MARK: - Presence

    func presenceStatus(for phone: String) -> PresenceStatus {
        guard let node else { return .offline }
        guard let peer = node.routingTable.allPeers.first(where: { $0.phone == phone })
        else { return .offline }
        let age = Date().timeIntervalSince(peer.lastSeen)
        if age < 5 * 60   { return .online }
        if age < 60 * 60  { return .recently }
        return .offline
    }

    private func updatePresenceMap(from node: KademliaProtocol) {
        var map: [String: PresenceStatus] = [:]
        for peer in node.routingTable.allPeers where peer.phone != "bootstrap" {
            map[peer.phone] = presenceStatus(for: peer.phone)
        }
        presenceMap = map
    }

    // MARK: - Routing Table Persistence

    private let peersKey = "hopchat.routingTable.v1"

    private func persistPeers(from node: KademliaProtocol) {
        let peers = node.routingTable.allPeers
            .filter { $0.phone != "bootstrap" && !$0.ip.isEmpty }
            .map { $0.toCodable() }
        if let data = try? JSONEncoder().encode(peers) {
            UserDefaults.standard.set(data, forKey: peersKey)
        }
    }

    private func loadPersistedPeers(into node: KademliaProtocol) {
        guard let data = UserDefaults.standard.data(forKey: peersKey),
              let peers = try? JSONDecoder().decode([KadPeerCodable].self, from: data)
        else { return }
        for peer in peers {
            node.addPeer(peer.toKadPeer())
        }
        print("📂 Loaded \(peers.count) persisted peers")
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
