//
//  KadMessageType.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 25/02/2026.
//


import Foundation
import Network

// MARK: - Message Types
enum KadMessageType: UInt8 {
    case ping      = 0x01
    case pong      = 0x02
    case findNode  = 0x03
    case foundNode = 0x04
    case store     = 0x05
    case findValue = 0x06
    case foundValue = 0x07
}

// MARK: - Message
struct KadMessage: Codable {
    let type: UInt8
    let senderID: [UInt8]
    let senderIP: String
    let senderPort: UInt16
    let targetID: [UInt8]?       // for FIND_NODE
    let peers: [KadPeerCodable]? // for FOUND_NODE response
    let key: String?             // for STORE / FIND_VALUE
    let value: String?           // for STORE / FOUND_VALUE
    let transactionID: String    // to match requests/responses
}

struct KadPeerCodable: Codable {
    let id: [UInt8]
    let ip: String
    let port: UInt16
    
    func toKadPeer() -> KadPeer {
        KadPeer(id: NodeID(bytes: id), ip: ip, port: port)
    }
}

extension KadPeer {
    func toCodable() -> KadPeerCodable {
        KadPeerCodable(id: id.bytes, ip: ip, port: port)
    }
}

// MARK: - UDP Transport
class KademliaTransport {
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private let port: UInt16
    
    var onMessage: ((KadMessage, String, UInt16) -> Void)?
    
    init(port: UInt16 = 4001) {
        self.port = port
    }
    
    // MARK: Start listening
    func startListening() throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.receive(on: connection)
            connection.start(queue: .global())
        }
        
        listener?.start(queue: .global())
        print("🟢 Kademlia listening on UDP port \(port)")
    }
    
    // MARK: Receive
    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let data = data, !data.isEmpty else { return }
            
            // Extract sender info
            if case let .hostPort(host, port) = connection.endpoint {
                let ip = "\(host)"
                let portNum = port.rawValue
                
                if let message = try? JSONDecoder().decode(KadMessage.self, from: data) {
                    DispatchQueue.main.async {
                        self?.onMessage?(message, ip, portNum)
                    }
                }
            }
            
            // Keep listening
            self?.receive(on: connection)
        }
    }
    
    // MARK: Send
    func send(_ message: KadMessage, to ip: String, port: UInt16) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.start(queue: .global())
        
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Send error: \(error)")
            }
            connection.cancel()
        })
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
    }
}

// MARK: - Message Builder helpers
extension KademliaTransport {
    static func makePing(from sender: KadPeer) -> KadMessage {
        KadMessage(
            type: KadMessageType.ping.rawValue,
            senderID: sender.id.bytes,
            senderIP: sender.ip,
            senderPort: sender.port,
            targetID: nil,
            peers: nil,
            key: nil,
            value: nil,
            transactionID: UUID().uuidString
        )
    }
    
    static func makePong(from sender: KadPeer, replyTo txID: String) -> KadMessage {
        KadMessage(
            type: KadMessageType.pong.rawValue,
            senderID: sender.id.bytes,
            senderIP: sender.ip,
            senderPort: sender.port,
            targetID: nil,
            peers: nil,
            key: nil,
            value: nil,
            transactionID: txID
        )
    }
    
    static func makeFindNode(from sender: KadPeer, target: NodeID) -> KadMessage {
        KadMessage(
            type: KadMessageType.findNode.rawValue,
            senderID: sender.id.bytes,
            senderIP: sender.ip,
            senderPort: sender.port,
            targetID: target.bytes,
            peers: nil,
            key: nil,
            value: nil,
            transactionID: UUID().uuidString
        )
    }
    
    static func makeFoundNode(from sender: KadPeer, peers: [KadPeer], replyTo txID: String) -> KadMessage {
        KadMessage(
            type: KadMessageType.foundNode.rawValue,
            senderID: sender.id.bytes,
            senderIP: sender.ip,
            senderPort: sender.port,
            targetID: nil,
            peers: peers.map { $0.toCodable() },
            key: nil,
            value: nil,
            transactionID: txID
        )
    }
    
    static func makeStore(from sender: KadPeer, key: String, value: String) -> KadMessage {
        KadMessage(
            type: KadMessageType.store.rawValue,
            senderID: sender.id.bytes,
            senderIP: sender.ip,
            senderPort: sender.port,
            targetID: nil,
            peers: nil,
            key: key,
            value: value,
            transactionID: UUID().uuidString
        )
    }
    
    static func makeFindValue(from sender: KadPeer, key: String) -> KadMessage {
        KadMessage(
            type: KadMessageType.findValue.rawValue,
            senderID: sender.id.bytes,
            senderIP: sender.ip,
            senderPort: sender.port,
            targetID: nil,
            peers: nil,
            key: key,
            value: nil,
            transactionID: UUID().uuidString
        )
    }
    
    static func makeFoundValue(from sender: KadPeer, key: String, value: String, replyTo txID: String) -> KadMessage {
        KadMessage(
            type: KadMessageType.foundValue.rawValue,
            senderID: sender.id.bytes,
            senderIP: sender.ip,
            senderPort: sender.port,
            targetID: nil,
            peers: nil,
            key: key,
            value: value,
            transactionID: txID
        )
    }
}