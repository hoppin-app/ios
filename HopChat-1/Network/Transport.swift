//
//  Transport.swift
//  HopChat-1
//
//  One-shot request/response TCP transport (contract §3: one request frame
//  and at most one response frame per connection).
//
//  Fixes the v1 transport bugs:
//   • every terminal path cancels the NWConnection (no leaks on `.failed`)
//   • `.waiting` (unreachable host) no longer hangs forever — connect timeout
//   • hard overall timeout on top of the connect timeout
//   • the continuation is resumed exactly once, guarded by a lock
//   • frame reader enforces the 1 MB cap
//   • TLS uses SPKI pinning; plaintext is DEBUG-only (see AppConfig)
//

import Foundation
import Network
import CryptoKit
import os

nonisolated enum Transport {

    // MARK: - Tunables

    static let defaultConnectTimeout: TimeInterval = 5
    static let defaultTimeout: TimeInterval = 10

    private static let queue = DispatchQueue(label: "hopchat.transport", qos: .userInitiated)
    private static let verifyQueue = DispatchQueue(label: "hopchat.tls.verify")

    // MARK: - Result

    struct Response: Sendable {
        let message: WireMessage
        /// The observed TCP peer address — the only address we ever trust.
        let remoteIP: String?
    }

    // MARK: - Public API

    /// Sends one framed request and awaits at most one framed response.
    /// Returns `nil` on any failure (connect, send, decode, timeout).
    static func request(_ message: WireMessage,
                        to host: String,
                        port: UInt16,
                        tls: Bool,
                        pins: [String] = [],
                        timeout: TimeInterval = defaultTimeout,
                        connectTimeout: TimeInterval = defaultConnectTimeout) async -> WireMessage? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        return await exchange(message, with: endpoint, tls: tls, pins: pins,
                              timeout: timeout, connectTimeout: connectTimeout)?.message
    }

    /// Full form: also reports the resolved TCP peer address, which is how a
    /// Bonjour-discovered peer's real IP is learned.
    static func exchange(_ message: WireMessage,
                         with endpoint: NWEndpoint,
                         tls: Bool,
                         pins: [String] = [],
                         timeout: TimeInterval = defaultTimeout,
                         connectTimeout: TimeInterval = defaultConnectTimeout) async -> Response? {

        let framed: Data
        do {
            framed = try WireFrame.frame(message)
        } catch {
            Log.net.error("Refusing to send oversized/empty frame: \(String(describing: error), privacy: .public)")
            return nil
        }

        let parameters = makeParameters(tls: tls, pins: pins)
        let connection = NWConnection(to: endpoint, using: parameters)
        let session = Session(connection: connection)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Response?, Never>) in
                session.attach(cont)

                // Connect timeout: `.waiting` (host unreachable, no route) would
                // otherwise leave the connection pending indefinitely.
                let connectDeadline = DispatchWorkItem {
                    guard !session.isReady else { return }
                    Log.net.debug("Transport connect timeout after \(connectTimeout, privacy: .public)s")
                    session.finish(nil)
                }
                queue.asyncAfter(deadline: .now() + connectTimeout, execute: connectDeadline)

                // Overall deadline covers connect + send + response read.
                let overallDeadline = DispatchWorkItem {
                    Log.net.debug("Transport overall timeout after \(timeout, privacy: .public)s")
                    session.finish(nil)
                }
                queue.asyncAfter(deadline: .now() + timeout, execute: overallDeadline)
                session.onFinish = {
                    connectDeadline.cancel()
                    overallDeadline.cancel()
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        session.markReady()
                        connectDeadline.cancel()
                        let remoteIP = Self.remoteIP(of: connection)
                        connection.send(content: framed, completion: .contentProcessed { error in
                            if let error {
                                Log.net.debug("Transport send failed: \(error.localizedDescription, privacy: .public)")
                                session.finish(nil)
                                return
                            }
                            readFrame(from: connection) { result in
                                switch result {
                                case .failure(let error):
                                    Log.net.debug("Transport read failed: \(error.localizedDescription, privacy: .public)")
                                    session.finish(nil)
                                case .success(let data):
                                    guard let reply = WireMessage.decode(data) else {
                                        Log.net.debug("Transport got an undecodable reply")
                                        session.finish(nil)
                                        return
                                    }
                                    session.finish(Response(message: reply, remoteIP: remoteIP))
                                }
                            }
                        })

                    case .failed(let error):
                        Log.net.debug("Transport connection failed: \(error.localizedDescription, privacy: .public)")
                        session.finish(nil)

                    case .waiting(let error):
                        // Keep waiting only until the connect deadline fires.
                        Log.net.debug("Transport waiting: \(error.localizedDescription, privacy: .public)")

                    case .cancelled:
                        session.finish(nil)

                    default:
                        break
                    }
                }

                connection.start(queue: queue)
            }
        } onCancel: {
            session.finish(nil)
        }
    }

    // MARK: - Session (exactly-once continuation + connection ownership)

    private final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Response?, Never>?
        private var connection: NWConnection?
        private var ready = false
        private var attached = false
        private var pendingResult: Response??
        var onFinish: (() -> Void)?

        init(connection: NWConnection) {
            self.connection = connection
        }

        func attach(_ cont: CheckedContinuation<Response?, Never>) {
            lock.lock()
            // A terminal state can fire before the continuation is installed
            // (e.g. an immediately-failing connection); replay it here.
            if let pending = pendingResult {
                lock.unlock()
                cont.resume(returning: pending)
                return
            }
            self.cont = cont
            attached = true
            lock.unlock()
        }

        func markReady() {
            lock.lock()
            ready = true
            lock.unlock()
        }

        var isReady: Bool {
            lock.lock()
            defer { lock.unlock() }
            return ready
        }

        func finish(_ result: Response?) {
            lock.lock()
            if !attached && pendingResult == nil {
                pendingResult = .some(result)
            }
            let c = cont
            cont = nil
            let conn = connection
            connection = nil
            let finish = onFinish
            onFinish = nil
            lock.unlock()

            conn?.stateUpdateHandler = nil
            conn?.cancel()
            finish?()
            c?.resume(returning: result)
        }
    }

    // MARK: - Framed reader (1 MB cap, contract §3)

    enum ReadError: Error {
        case closed
        case shortPrefix
        case badLength
        case shortPayload
    }

    /// Reads exactly one length-prefixed frame.
    static func readFrame(from connection: NWConnection,
                          completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, isComplete, error in
            if let error { completion(.failure(error)); return }
            guard let data, data.count == 4 else {
                completion(.failure(isComplete ? ReadError.closed : ReadError.shortPrefix))
                return
            }
            guard let length = WireFrame.parseLength(data) else {
                completion(.failure(ReadError.badLength))
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { payload, _, _, error in
                if let error { completion(.failure(error)); return }
                guard let payload, payload.count == length else {
                    completion(.failure(ReadError.shortPayload))
                    return
                }
                completion(.success(payload))
            }
        }
    }

    // MARK: - Parameters / TLS pinning

    static func makeParameters(tls: Bool, pins: [String]) -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = Int(defaultConnectTimeout)
        tcpOptions.noDelay = true

        guard tls else {
            #if !DEBUG
            Log.net.error("Plaintext transport requested in a Release build — refusing TLS downgrade is the caller's job")
            #endif
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            return params
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, secTrust, complete in
            guard !pins.isEmpty else {
                #if DEBUG
                Log.net.warning("TLS pinning skipped — no SPKI pins configured (DEBUG only)")
                complete(true)
                #else
                Log.net.error("TLS rejected — no SPKI pins configured")
                complete(false)
                #endif
                return
            }
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            let ok = validate(trust: trust, against: pins)
            if !ok { Log.net.error("TLS rejected — server SPKI does not match any pin") }
            complete(ok)
        }, verifyQueue)

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        return params
    }

    /// SHA-256 over the leaf certificate's DER SubjectPublicKeyInfo, compared
    /// against the configured pins.
    static func validate(trust: SecTrust, against pins: [String]) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let spki = spkiDER(of: leaf) else { return false }
        let digest = Data(SHA256.hash(data: spki)).base64EncodedString()
        return pins.contains(digest)
    }

    // ASN.1 SubjectPublicKeyInfo headers. `SecKeyCopyExternalRepresentation`
    // hands back the bare key (an uncompressed EC point, or a PKCS#1 RSA key),
    // so the standard header is prefixed to rebuild the DER SPKI that the
    // pin is computed over.
    private static let p256SPKIHeader: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
        0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    ]
    private static let p384SPKIHeader: [UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
        0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
    ]
    private static let rsa2048SPKIHeader: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
        0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
    ]

    static func spkiDER(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            error?.release()
            return nil
        }
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any] else { return nil }
        let type = attributes[kSecAttrKeyType as String] as? String
        let bits = (attributes[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue ?? 0

        let ecType = kSecAttrKeyTypeECSECPrimeRandom as String
        let rsaType = kSecAttrKeyTypeRSA as String
        let header: [UInt8]
        if type == ecType, bits == 256 {
            header = p256SPKIHeader
        } else if type == ecType, bits == 384 {
            header = p384SPKIHeader
        } else if type == rsaType, bits == 2048 {
            header = rsa2048SPKIHeader
        } else {
            Log.net.error("Unsupported server key type for pinning (bits: \(bits, privacy: .public))")
            return nil
        }
        return Data(header) + raw
    }

    // MARK: - Address helpers

    /// The observed TCP peer address. Contract §3: self-reported IPs are ignored.
    static func remoteIP(of connection: NWConnection) -> String? {
        guard let endpoint = connection.currentPath?.remoteEndpoint else {
            return ipString(of: connection.endpoint)
        }
        return ipString(of: endpoint)
    }

    static func ipString(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return String(describing: address).components(separatedBy: "%").first
        case .ipv6(let address):
            if let mapped = address.asIPv4 {
                return String(describing: mapped).components(separatedBy: "%").first
            }
            return String(describing: address).components(separatedBy: "%").first
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }
}
