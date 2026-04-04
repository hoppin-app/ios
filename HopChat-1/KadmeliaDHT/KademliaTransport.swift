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
    case ping           = 0x01
    case pong           = 0x02
    case findNode       = 0x03
    case foundNode      = 0x04
    case store          = 0x05
    case findValue      = 0x06
    case foundValue     = 0x07
    case connectRequest = 0x08
    case connectAccept  = 0x09
    case connectDecline = 0x0A
    case chatMessage    = 0x0B
    case chatAck        = 0x0C
    case holePunch      = 0x0D   // Bootstrap tells us a peer's public address
}

// MARK: - Wire Message
struct KadMessage: Codable {
    let type:          UInt8
    let senderID:      [UInt8]
    let senderIP:      String
    let senderPort:    UInt16
    let senderPhone:   String
    let targetID:      [UInt8]?
    let peers:         [KadPeerCodable]?
    let key:           String?
    let value:         String?
    let transactionID: String
    let chatBody:      String?
    let chatID:        String?
    let chatTimestamp: Double?
}

// MARK: - Peer (codable wire form)
struct KadPeerCodable: Codable {
    let id:    [UInt8]
    let ip:    String
    let port:  UInt16
    let phone: String

    func toKadPeer() -> KadPeer {
        KadPeer(id: NodeID(bytes: id), ip: ip, port: port, phone: phone)
    }
}

extension KadPeer {
    func toCodable() -> KadPeerCodable {
        KadPeerCodable(id: id.bytes, ip: ip, port: port, phone: phone)
    }
}

// MARK: - UDP Transport
final class KademliaTransport {
    private var listener:    NWListener?
    private let port:        UInt16
    private let queue = DispatchQueue(label: "hopchat.udp", qos: .userInitiated)

    var onMessage: ((KadMessage, String, UInt16) -> Void)?

    init(port: UInt16) { self.port = port }

    func startListening() throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.receive(on: conn)
            conn.start(queue: self?.queue ?? .global())
        }
        listener?.start(queue: queue)
        print("🟢 UDP listening on port \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let data, !data.isEmpty else { return }
            if case let .hostPort(host, port) = connection.endpoint,
               let msg = try? JSONDecoder().decode(KadMessage.self, from: data) {
                let ip  = "\(host)"
                let num = port.rawValue
                DispatchQueue.main.async { self?.onMessage?(msg, ip, num) }
            }
            self?.receive(on: connection)
        }
    }

    func send(_ message: KadMessage, to ip: String, port: UInt16) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let conn = NWConnection(to: endpoint, using: .udp)
        conn.start(queue: queue)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Message Builders
extension KademliaTransport {

    static func makePing(from sender: KadPeer) -> KadMessage {
        base(type: .ping, sender: sender, txID: uuid())
    }

    static func makePong(from sender: KadPeer, replyTo txID: String) -> KadMessage {
        base(type: .pong, sender: sender, txID: txID)
    }

    static func makeFindNode(from sender: KadPeer, target: NodeID) -> KadMessage {
        KadMessage(type: KadMessageType.findNode.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: target.bytes, peers: nil,
                   key: nil, value: nil, transactionID: uuid(),
                   chatBody: nil, chatID: nil, chatTimestamp: nil)
    }

    static func makeFoundNode(from sender: KadPeer, peers: [KadPeer], replyTo txID: String) -> KadMessage {
        KadMessage(type: KadMessageType.foundNode.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: nil, peers: peers.map { $0.toCodable() },
                   key: nil, value: nil, transactionID: txID,
                   chatBody: nil, chatID: nil, chatTimestamp: nil)
    }

    static func makeStore(from sender: KadPeer, key: String, value: String) -> KadMessage {
        KadMessage(type: KadMessageType.store.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: nil, peers: nil,
                   key: key, value: value, transactionID: uuid(),
                   chatBody: nil, chatID: nil, chatTimestamp: nil)
    }

    static func makeFindValue(from sender: KadPeer, key: String) -> KadMessage {
        KadMessage(type: KadMessageType.findValue.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: nil, peers: nil,
                   key: key, value: nil, transactionID: uuid(),
                   chatBody: nil, chatID: nil, chatTimestamp: nil)
    }

    static func makeFoundValue(from sender: KadPeer, key: String, value: String, replyTo txID: String) -> KadMessage {
        KadMessage(type: KadMessageType.foundValue.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: nil, peers: nil,
                   key: key, value: value, transactionID: txID,
                   chatBody: nil, chatID: nil, chatTimestamp: nil)
    }

    static func makeConnectRequest(from sender: KadPeer, toPhone: String) -> KadMessage {
        KadMessage(type: KadMessageType.connectRequest.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: nil, peers: nil,
                   key: toPhone, value: nil, transactionID: uuid(),
                   chatBody: nil, chatID: nil, chatTimestamp: nil)
    }

    static func makeConnectAccept(from sender: KadPeer, replyTo txID: String) -> KadMessage {
        base(type: .connectAccept, sender: sender, txID: txID)
    }

    static func makeConnectDecline(from sender: KadPeer, replyTo txID: String) -> KadMessage {
        base(type: .connectDecline, sender: sender, txID: txID)
    }

    static func makeChatMessage(from sender: KadPeer, body: String, chatID: String = uuid()) -> KadMessage {
        KadMessage(type: KadMessageType.chatMessage.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: nil, peers: nil,
                   key: nil, value: nil, transactionID: uuid(),
                   chatBody: body, chatID: chatID,
                   chatTimestamp: Date().timeIntervalSince1970)
    }

    static func makeChatAck(from sender: KadPeer, chatID: String, replyTo txID: String) -> KadMessage {
        KadMessage(type: KadMessageType.chatAck.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: nil, peers: nil,
                   key: nil, value: nil, transactionID: txID,
                   chatBody: nil, chatID: chatID, chatTimestamp: nil)
    }

    private static func uuid() -> String { UUID().uuidString }

    private static func base(type: KadMessageType, sender: KadPeer, txID: String) -> KadMessage {
        KadMessage(type: type.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: nil, peers: nil,
                   key: nil, value: nil, transactionID: txID,
                   chatBody: nil, chatID: nil, chatTimestamp: nil)
    }
}
