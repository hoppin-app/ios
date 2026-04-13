//
//  KademliaTransport.swift
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
    case holePunch      = 0x0D
    case relay          = 0x0E
}
 
// MARK: - Wire Message
 
struct KadMessage: Codable {
    let type:          UInt8
    /// SHA-256 NodeID — 32 bytes (previously 20 bytes / SHA-1).
    let senderID:      [UInt8]
    let senderIP:      String
    let senderPort:    UInt16
    let senderPhone:   String
    /// SHA-256 NodeID — 32 bytes, optional (FIND_NODE messages only).
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
    /// SHA-256 NodeID — 32 bytes.
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
 
// MARK: - UDP Transport (single bound socket)
 
final class KademliaTransport {
 
    private let port:  UInt16
    private let queue = DispatchQueue(label: "hopchat.udp", qos: .userInitiated)
 
    private var sock: Int32 = -1
 
    private var pending:    [String: CheckedContinuation<KadMessage?, Never>] = [:]
    private let pendingLock = NSLock()
 
    var onMessage: ((KadMessage, String, UInt16) -> Void)?
 
    init(port: UInt16) { self.port = port }
 
    // MARK: - Start / Stop
 
    func startListening() throws {
        print("🔧 Using BSD socket transport on port \(port)")
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw NSError(domain: "KademliaTransport",
                          code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed: \(errno)"])
        }
 
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
 
        var addr          = sockaddr_in()
        addr.sin_family   = sa_family_t(AF_INET)
        addr.sin_port     = port.bigEndian
        addr.sin_addr     = in_addr(s_addr: INADDR_ANY)
        addr.sin_len      = UInt8(MemoryLayout<sockaddr_in>.size)
 
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: "KademliaTransport",
                          code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed on port \(port): \(errno)"])
        }
 
        self.sock = fd
        print("🟢 UDP listening on port \(port)")
        startReceiveLoop()
    }
 
    func stop() {
        if sock >= 0 { close(sock); sock = -1 }
        pendingLock.lock()
        let all = pending
        pending.removeAll()
        pendingLock.unlock()
        for (_, cont) in all { cont.resume(returning: nil) }
    }
 
    // MARK: - Receive loop
 
    private func startReceiveLoop() {
        queue.async { [weak self] in
            guard let self, self.sock >= 0 else { return }
 
            let bufSize = 65_536
            let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
            defer { buf.deallocate() }
 
            while self.sock >= 0 {
                print("👂 recvfrom waiting...")
 
                var srcAddr    = sockaddr_in()
                var srcAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
 
                let n = withUnsafeMutablePointer(to: &srcAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(self.sock, buf, bufSize, 0, $0, &srcAddrLen)
                    }
                }
                guard n > 0 else { break }
                if n < 0 { print("❌ recvfrom error: errno=\(errno)"); break }
                if n == 0 { continue }
 
                let data = Data(bytes: buf, count: n)
 
                var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addr4   = srcAddr
                inet_ntop(AF_INET, &addr4.sin_addr, &hostBuf, socklen_t(INET_ADDRSTRLEN))
                let srcIP   = String(cString: hostBuf)
                let srcPort = UInt16(bigEndian: srcAddr.sin_port)
 
                guard let msg = try? JSONDecoder().decode(KadMessage.self, from: data) else {
                    let raw = String(data: data, encoding: .utf8) ?? "<binary \(n)b>"
                    print("⚠️ Failed to decode UDP from \(srcIP):\(srcPort): \(raw.prefix(200))")
                    continue
                }
 
                print("📩 [\(msg.senderPhone)] type=\(msg.type) tx=\(msg.transactionID.prefix(8)) from \(srcIP):\(srcPort)")
 
                // Resolve pending RPC continuation first (time-critical).
                self.pendingLock.lock()
                if let cont = self.pending[msg.transactionID] {
                    self.pending.removeValue(forKey: msg.transactionID)
                    self.pendingLock.unlock()
                    cont.resume(returning: msg)
                    continue
                }
                self.pendingLock.unlock()
 
                // Unsolicited inbound — dispatch to protocol handler.
                let ip = srcIP; let p = srcPort
                DispatchQueue.main.async { self.onMessage?(msg, ip, p) }
            }
        }
    }
 
    // MARK: - Send
 
    func send(_ message: KadMessage, to ip: String, port: UInt16) {
        guard let data = try? JSONEncoder().encode(message), sock >= 0 else {
            print("⚠️ send: sock=\(sock) data=\(message.type)")
            return
        }
 
        print("📤 Queuing send type=\(message.type) to \(ip):\(port) [\(data.count)b]")
 
        var dst          = sockaddr_in()
        dst.sin_family   = sa_family_t(AF_INET)
        dst.sin_port     = port.bigEndian
        dst.sin_len      = UInt8(MemoryLayout<sockaddr_in>.size)
        inet_pton(AF_INET, ip, &dst.sin_addr)
 
        queue.async { [weak self] in
            guard let self, self.sock >= 0 else { return }
            data.withUnsafeBytes { ptr in
                withUnsafePointer(to: dst) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        let sent = sendto(self.sock, ptr.baseAddress, data.count,
                                         0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        if sent < 0 {
                            print("⚠️ sendto \(ip):\(port) failed: errno=\(errno)")
                        } else {
                            print("✅ sendto \(ip):\(port) sent \(sent)b")
                        }
                    }
                }
            }
        }
    }
 
    // MARK: - RPC send-and-wait (10 s timeout)
 
    func sendAndWait(_ message: KadMessage, to peer: KadPeer) async -> KadMessage? {
        await withCheckedContinuation { cont in
            pendingLock.lock()
            pending[message.transactionID] = cont
            pendingLock.unlock()
 
            send(message, to: peer.ip, port: peer.port)
 
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
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
 
    // MARK: - Relay helper
 
    static func makeRelay(from sender: KadPeer, toPhone: String,
                          wrapping inner: KadMessage) -> KadMessage? {
        guard let innerData = try? JSONEncoder().encode(inner),
              let innerJSON = String(data: innerData, encoding: .utf8) else { return nil }
        return KadMessage(type: KadMessageType.relay.rawValue,
                          senderID: sender.id.bytes, senderIP: sender.ip,
                          senderPort: sender.port, senderPhone: sender.phone,
                          targetID: nil, peers: nil,
                          key: toPhone, value: innerJSON,
                          transactionID: UUID().uuidString,
                          chatBody: nil, chatID: nil, chatTimestamp: nil)
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
 
    static func makeFoundNode(from sender: KadPeer, peers: [KadPeer],
                              replyTo txID: String) -> KadMessage {
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
 
    static func makeFoundValue(from sender: KadPeer, key: String, value: String,
                               replyTo txID: String) -> KadMessage {
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
 
    static func makeChatMessage(from sender: KadPeer, body: String,
                                chatID: String = uuid()) -> KadMessage {
        KadMessage(type: KadMessageType.chatMessage.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: nil, peers: nil,
                   key: nil, value: nil, transactionID: uuid(),
                   chatBody: body, chatID: chatID,
                   chatTimestamp: Date().timeIntervalSince1970)
    }
 
    static func makeChatAck(from sender: KadPeer, chatID: String,
                            replyTo txID: String) -> KadMessage {
        KadMessage(type: KadMessageType.chatAck.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: nil, peers: nil,
                   key: nil, value: nil, transactionID: txID,
                   chatBody: nil, chatID: chatID, chatTimestamp: nil)
    }
 
    static func uuid() -> String { UUID().uuidString }
 
    private static func base(type: KadMessageType, sender: KadPeer,
                             txID: String) -> KadMessage {
        KadMessage(type: type.rawValue,
                   senderID: sender.id.bytes, senderIP: sender.ip,
                   senderPort: sender.port, senderPhone: sender.phone,
                   targetID: nil, peers: nil,
                   key: nil, value: nil, transactionID: txID,
                   chatBody: nil, chatID: nil, chatTimestamp: nil)
    }
}
