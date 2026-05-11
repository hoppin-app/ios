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
    let senderID:      [UInt8]      // 32 bytes — SHA-256 NodeID
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
    // E2E encryption & authentication (nil on older messages → backwards-compatible)
    var senderPublicKey:  String? = nil   // base64 Curve25519 agreement public key
    var senderSigningKey: String? = nil   // base64 Curve25519 signing public key
    var signature:        String? = nil   // base64 signature over canonical payload
    var encrypted:        Bool?   = nil   // true when chatBody is AES-GCM ciphertext
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
 
// MARK: - Framing
 
/// Prepend a 4-byte big-endian length to a JSON payload.
private func frame(_ data: Data) -> Data {
    var length = UInt32(data.count).bigEndian
    var framed = Data(bytes: &length, count: 4)
    framed.append(data)
    return framed
}
 
// MARK: - TCP Transport
 
final class KademliaTransport {
 
    private let port:    UInt16
    private let queue  = DispatchQueue(label: "hopchat.tcp", qos: .userInitiated)
    private var listener: NWListener?
 
    // Pending RPC continuations: transactionID → continuation
    private var pending:    [String: CheckedContinuation<KadMessage?, Never>] = [:]
    private let pendingLock = NSLock()
 
    /// Called for every unsolicited inbound message.
    /// Parameters: (message, remoteIP, remotePort)
    var onMessage: ((KadMessage, String, UInt16) -> Void)?
 
    init(port: UInt16) { self.port = port }
 
    // MARK: - Start / Stop
 
    func startListening() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
 
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "KademliaTransport", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
 
        let l = try NWListener(using: params, on: nwPort)
        self.listener = l
 
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:   print("🟢 TCP listener ready on port \(self.port)")
            case .failed(let e): print("❌ TCP listener failed: \(e)")
            default: break
            }
        }
 
        l.newConnectionHandler = { [weak self] conn in
            self?.handleIncoming(conn)
        }
 
        l.start(queue: queue)
        print("🔧 Using TCP transport on port \(port)")
    }
 
    func stop() {
        listener?.cancel()
        listener = nil
        pendingLock.lock()
        let all = pending
        pending.removeAll()
        pendingLock.unlock()
        for (_, cont) in all { cont.resume(returning: nil) }
    }
 
    // MARK: - Inbound connection handler
 
    private func handleIncoming(_ conn: NWConnection) {
        conn.start(queue: queue)
 
        readFrame(from: conn) { [weak self] result in
            guard let self else { conn.cancel(); return }
 
            switch result {
            case .failure(let err):
                print("⚠️ TCP inbound read error: \(err)")
                conn.cancel()
 
            case .success(let data):
                guard let msg = try? JSONDecoder().decode(KadMessage.self, from: data) else {
                    print("⚠️ TCP decode failed from \(conn.endpoint)")
                    conn.cancel()
                    return
                }
 
                let (srcIP, srcPort) = self.endpointAddress(conn.endpoint)
                print("📩 [\(msg.senderPhone)] type=\(msg.type) "
                    + "tx=\(msg.transactionID.prefix(8)) from \(srcIP):\(srcPort)")
 
                // Is this a reply to one of our pending RPCs?
                self.pendingLock.lock()
                if let cont = self.pending[msg.transactionID] {
                    self.pending.removeValue(forKey: msg.transactionID)
                    self.pendingLock.unlock()
                    conn.cancel()
                    cont.resume(returning: msg)
                    return
                }
                self.pendingLock.unlock()
 
                // Unsolicited message — dispatch to protocol layer.
                // The protocol layer replies via send(to: ip, port:) using
                // the senderPort from the message payload, which is the
                // peer's stable listening port — not the ephemeral source
                // port of this inbound connection.
                conn.cancel()
                DispatchQueue.main.async {
                    self.onMessage?(msg, srcIP, srcPort)
                }
            }
        }
    }
 
    // MARK: - Send (always opens a fresh outbound connection)
    //
    // We never reuse the inbound connection to send replies.  The inbound
    // connection's source port is an ephemeral OS-assigned port that the
    // peer is not listening on.  The peer's stable listening port is carried
    // in message.senderPort — that is what `port` here refers to, supplied
    // by KademliaProtocol which passes actualPort from the decoded message.
 
    func send(_ message: KadMessage, to ip: String, port: UInt16) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        let framed = frame(data)
        print("📤 TCP send type=\(message.type) to \(ip):\(port) [\(data.count)b]")
        queue.async { [weak self] in
            self?.openAndSend(framed, to: ip, port: port)
        }
    }
 
    private func openAndSend(_ framed: Data, to ip: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: .tcp)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: framed, completion: .contentProcessed { err in
                    if let err { print("⚠️ TCP send error to \(ip):\(port): \(err)") }
                    else       { print("✅ TCP sent to \(ip):\(port)") }
                    conn.cancel()
                })
            case .failed(let e):
                print("⚠️ TCP connect failed to \(ip):\(port): \(e)")
            default: break
            }
        }
        conn.start(queue: queue)
    }
 
    // MARK: - RPC send-and-wait (10 s timeout)
    //
    // Opens a connection, sends the request, and reads the reply on the
    // same connection — one round-trip, one TCP connection.
 
    func sendAndWait(_ message: KadMessage, to peer: KadPeer) async -> KadMessage? {
        guard let data = try? JSONEncoder().encode(message) else { return nil }
        let framed = frame(data)
        let txID   = message.transactionID
 
        return await withCheckedContinuation { cont in
            // Also register in the pending dict as a fallback for cases where
            // the peer replies on a separate inbound connection.
            pendingLock.lock()
            pending[txID] = cont
            pendingLock.unlock()
 
            guard let nwPort = NWEndpoint.Port(rawValue: peer.port) else {
                pendingLock.lock()
                pending.removeValue(forKey: txID)
                pendingLock.unlock()
                cont.resume(returning: nil)
                return
            }
 
            let conn = NWConnection(host: NWEndpoint.Host(peer.ip),
                                    port: nwPort, using: .tcp)
 
            // Timeout task
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                self.pendingLock.lock()
                if let c = self.pending[txID] {
                    self.pending.removeValue(forKey: txID)
                    self.pendingLock.unlock()
                    conn.cancel()
                    c.resume(returning: nil)
                } else {
                    self.pendingLock.unlock()
                }
            }
 
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    print("📤 TCP RPC type=\(message.type) to \(peer.ip):\(peer.port)")
                    conn.send(content: framed, completion: .contentProcessed { err in
                        if let err {
                            print("⚠️ TCP RPC send error: \(err)")
                            timeoutTask.cancel()
                            self.pendingLock.lock()
                            if let c = self.pending[txID] {
                                self.pending.removeValue(forKey: txID)
                                self.pendingLock.unlock()
                                conn.cancel()
                                c.resume(returning: nil)
                            } else {
                                self.pendingLock.unlock()
                            }
                            return
                        }
                        // Read reply on the same connection.
                        self.readFrame(from: conn) { result in
                            conn.cancel()
                            switch result {
                            case .failure(let e):
                                print("⚠️ TCP RPC read error — awaiting inbound reply: \(e)")
                                // The peer closes the outbound connection after sending its
                                // reply on a new inbound connection.  Leave the continuation
                                // in `pending` so handleIncoming can resolve it.  The timeout
                                // task will clean up if no reply arrives within 10 s.
                            case .success(let replyData):
                                timeoutTask.cancel()
                                self.pendingLock.lock()
                                guard let c = self.pending[txID] else {
                                    self.pendingLock.unlock()
                                    return  // already resolved (timeout or inbound)
                                }
                                self.pending.removeValue(forKey: txID)
                                self.pendingLock.unlock()
                                let reply = try? JSONDecoder().decode(KadMessage.self,
                                                                      from: replyData)
                                if let reply {
                                    print("📩 RPC reply type=\(reply.type) "
                                        + "tx=\(reply.transactionID.prefix(8))")
                                }
                                c.resume(returning: reply)
                            }
                        }
                    })
 
                case .failed(let e):
                    print("⚠️ TCP RPC connect failed to \(peer.ip):\(peer.port): \(e)")
                    timeoutTask.cancel()
                    self.pendingLock.lock()
                    if let c = self.pending[txID] {
                        self.pending.removeValue(forKey: txID)
                        self.pendingLock.unlock()
                        c.resume(returning: nil)
                    } else {
                        self.pendingLock.unlock()
                    }
 
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }
 
    // MARK: - Length-prefixed frame reader
 
    private func readFrame(from conn: NWConnection,
                           completion: @escaping (Result<Data, Error>) -> Void) {
        // Read 4-byte length prefix first.
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, err in
            if let err { completion(.failure(err)); return }
            guard let data, data.count == 4 else {
                completion(.failure(NSError(domain: "KademliaTransport", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Short length prefix"])))
                return
            }
            let length = Int(data.withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            })
            guard length > 0, length < 1_048_576 else {
                completion(.failure(NSError(domain: "KademliaTransport", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Bad frame length: \(length)"])))
                return
            }
            // Read payload.
            conn.receive(minimumIncompleteLength: length,
                         maximumLength: length) { payload, _, _, err in
                if let err { completion(.failure(err)); return }
                guard let payload, payload.count == length else {
                    completion(.failure(NSError(domain: "KademliaTransport", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Short payload"])))
                    return
                }
                completion(.success(payload))
            }
        }
    }
 
    // MARK: - Address helper
 
    private func endpointAddress(_ endpoint: NWEndpoint) -> (String, UInt16) {
        guard case .hostPort(let host, let port) = endpoint else { return ("0.0.0.0", 0) }
        let ip: String
        switch host {
        case .ipv4(let a):
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var raw = a.rawValue
            inet_ntop(AF_INET, &raw, &buf, socklen_t(INET_ADDRSTRLEN))
            ip = String(cString: buf)
        case .ipv6(let a):
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var raw = a.rawValue
            inet_ntop(AF_INET6, &raw, &buf, socklen_t(INET6_ADDRSTRLEN))
            ip = String(cString: buf)
        default:
            ip = host.debugDescription
        }
        return (ip, port.rawValue)
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
        // Note: relay wrapper intentionally omits crypto fields; inner message carries them
    }
}
 
// MARK: - Message Builders  (all unchanged)
 
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
        let crypto = CryptoManager.shared
        var msg = KadMessage(type: KadMessageType.connectRequest.rawValue,
                             senderID: sender.id.bytes, senderIP: sender.ip,
                             senderPort: sender.port, senderPhone: sender.phone,
                             targetID: nil, peers: nil,
                             key: toPhone, value: nil, transactionID: uuid(),
                             chatBody: nil, chatID: nil, chatTimestamp: nil)
        msg.senderPublicKey  = crypto.agreementPublicKeyBase64
        msg.senderSigningKey = crypto.signingPublicKeyBase64
        return msg
    }
 
    static func makeConnectAccept(from sender: KadPeer, replyTo txID: String) -> KadMessage {
        let crypto = CryptoManager.shared
        var msg = base(type: .connectAccept, sender: sender, txID: txID)
        msg.senderPublicKey  = crypto.agreementPublicKeyBase64
        msg.senderSigningKey = crypto.signingPublicKeyBase64
        return msg
    }
 
    static func makeConnectDecline(from sender: KadPeer, replyTo txID: String) -> KadMessage {
        base(type: .connectDecline, sender: sender, txID: txID)
    }
 
    static func makeChatMessage(from sender: KadPeer, body: String,
                                chatID: String = uuid(),
                                toPhone: String) -> KadMessage {
        let crypto  = CryptoManager.shared
        let txID = uuid()

        let (finalBody, isEncrypted): (String, Bool)
        if let ciphertext = crypto.encrypt(message: body, forPhone: toPhone) {
            finalBody   = ciphertext
            isEncrypted = true
        } else {
            finalBody   = body
            isEncrypted = false
        }
        // Sign the wire body (ciphertext when encrypted, plaintext otherwise)
        // so the receiver can verify against message.chatBody.
        let payload = CryptoManager.signingPayload(txID: txID, senderPhone: sender.phone, chatBody: finalBody)

        var msg = KadMessage(type: KadMessageType.chatMessage.rawValue,
                             senderID: sender.id.bytes, senderIP: sender.ip,
                             senderPort: sender.port, senderPhone: sender.phone,
                             targetID: nil, peers: nil,
                             key: nil, value: nil, transactionID: txID,
                             chatBody: finalBody, chatID: chatID,
                             chatTimestamp: Date().timeIntervalSince1970)
        msg.senderPublicKey  = crypto.agreementPublicKeyBase64
        msg.senderSigningKey = crypto.signingPublicKeyBase64
        msg.signature        = crypto.sign(payload: payload)
        msg.encrypted        = isEncrypted
        return msg
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
