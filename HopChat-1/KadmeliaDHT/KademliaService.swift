//
//  KademliaService.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 25/02/2026.
//

import Foundation
import SwiftUI
import Combine

@MainActor
class KademliaService: ObservableObject {
    static let shared = KademliaService()
    
    @Published var isBootstrapped = false
    @Published var connectedPeers = 0
    @Published var status = "Offline"
    
    private var node: KademliaProtocol?
    
    // MARK: - Join the network with your phone number
    func register(phone: String) async {
        status = "Fetching your IP..."
        
        guard let ip = await fetchPublicIP() else {
            status = "❌ Could not get public IP"
            return
        }
        
        print("🌍 Public IP: \(ip)")
        status = "Starting node..."
        
        let kad = KademliaProtocol(phone: phone, ip: ip, port: 4001)
        self.node = kad
        
        do {
            try kad.start()
        } catch {
            status = "❌ Failed to start UDP: \(error)"
            return
        }
        
        status = "Bootstrapping..."
        
        // These are YOUR bootstrap nodes
        // For now using a placeholder — Phase 5 we'll set up a real one
        let bootnodes: [(ip: String, port: UInt16, phone: String)] = [
            // ("YOUR_BOOTSTRAP_IP", 4001)  ← we'll fill this in Phase 5
        ]
        
        await kad.bootstrap(bootnodes: bootnodes)
        
        // Announce yourself: store phone -> ip:port in DHT
        await kad.store(key: phone, value: "\(ip):4001")
        
        isBootstrapped = true
        connectedPeers = kad.routingTable.buckets.flatMap { $0.peers }.count
        status = "🟢 Online"
        
    }
    
    // MARK: - Find a peer by phone number
    func findPeer(phone: String) async -> String? {
        guard let node else { return nil }
        status = "🔍 Looking up \(phone)..."
        let result = await node.findValue(key: phone)
        status = result != nil ? "✅ Found \(phone)" : "❌ \(phone) not found"
        return result
    }
    
    // MARK: - Get public IP via stun-like HTTP
    private func fetchPublicIP() async -> String? {
        let urls = [
            "https://api.ipify.org",
            "https://icanhazip.com",
            "https://ifconfig.me/ip"
        ]
        
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            if let ip = try? await URLSession.shared.data(from: url).0,
               let str = String(data: ip, encoding: .utf8) {
                let clean = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return clean }
            }
        }
        return nil
    }
}
