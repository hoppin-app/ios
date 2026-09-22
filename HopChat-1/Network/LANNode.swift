//
//  LANNode.swift
//  HopChat-1
//
//  The LAN TCP listener. Accepts one framed request per connection and hands
//  it to a handler together with the **observed TCP source IP** — the only
//  address the app ever trusts (contract §3).
//
//  Hardening versus v1:
//   • at most 32 concurrent inbound connections
//   • 10 s read timeout per connection, then the connection is cancelled
//   • per-source-IP token bucket (30 messages / minute)
//   • decoding and verification happen off the main actor; only state updates
//     hop to `@MainActor`
//   • binds an OS-assigned port instead of a phone-derived (and therefore
//     phone-revealing, collision-prone) one
//

import Foundation
import Network
import os

nonisolated final class LANNode: @unchecked Sendable {

    static let maxConcurrentInbound = 32
    static let readTimeout: TimeInterval = 10
    static let inboundPerMinute = 30

    /// `(request, sourceIP) -> optional reply`. Runs off the main actor.
    typealias Handler = @Sendable (WireMessage, String) async -> WireMessage?

    private let queue = DispatchQueue(label: "hoppin.lan", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections = 0
    private var boundPort: UInt16 = 0
    private let bucket = TokenBucket(capacity: inboundPerMinute, per: 60)

    /// Set before `start()`.
    var onRequest: Handler?
    /// Called on the networking queue once the listener has a port.
    var onReady: (@Sendable (UInt16) -> Void)?
    /// Called on the networking queue when the listener fails.
    var onFailure: (@Sendable (Error) -> Void)?

    init() {}

    /// The bound listening port, or 0 when not listening.
    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    var isListening: Bool { port != 0 }

    // MARK: - Lifecycle

    func start() throws {
        stop()

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true

        // Port 0 → the OS picks a free ephemeral port, which is then advertised
        // over Bonjour and carried in the signed `senderPort` field.
        let listener = try NWListener(using: parameters)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                self.lock.lock(); self.boundPort = port; self.lock.unlock()
                Log.net.info("LAN listener ready on port \(port, privacy: .public)")
                self.onReady?(port)
            case .failed(let error):
                self.lock.lock(); self.boundPort = 0; self.lock.unlock()
                Log.net.error("LAN listener failed: \(error.localizedDescription, privacy: .public)")
                self.onFailure?(error)
            case .cancelled:
                self.lock.lock(); self.boundPort = 0; self.lock.unlock()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        lock.lock()
        boundPort = 0
        activeConnections = 0
        lock.unlock()
        bucket.removeAll()
    }

    // MARK: - Outbound

    /// Sends a request to a LAN peer and awaits the reply. `ip` is a string as
    /// reported by this node (`sourceIP` / `remoteIP`); IPv6 link-local
    /// addresses carry their scope ("fe80::1%awdl0"), which
    /// `NWEndpoint.Host(_:)` parses into the address's interface, so the
    /// connection goes out on the right link. Outbound parameters include
    /// peer-to-peer Wi-Fi (see `Transport.makeParameters`).
    func send(_ message: WireMessage,
              to ip: String,
              port: UInt16,
              timeout: TimeInterval = 3) async -> WireMessage? {
        await Transport.request(message, to: ip, port: port, tls: false, timeout: timeout,
                                connectTimeout: min(timeout, Transport.defaultConnectTimeout))
    }

    /// Sends a request to a Bonjour endpoint, reporting the resolved peer IP.
    func send(_ message: WireMessage,
              to endpoint: NWEndpoint,
              timeout: TimeInterval = 5) async -> Transport.Response? {
        await Transport.exchange(message, with: endpoint, tls: false, timeout: timeout,
                                 connectTimeout: min(timeout, Transport.defaultConnectTimeout))
    }

    // MARK: - Inbound

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let count = activeConnections
        if count >= LANNode.maxConcurrentInbound {
            lock.unlock()
            Log.net.debug("LAN listener at capacity — dropping inbound connection")
            connection.cancel()
            return
        }
        activeConnections = count + 1
        lock.unlock()

        // Once-only guard: timeout, state changes, read errors and the reply
        // path can all race to close; exactly one of them wins.
        let finished = OSAllocatedUnfairLock(initialState: false)
        let close: @Sendable () -> Void = { [weak self] in
            let first = finished.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            guard first else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
            guard let self else { return }
            self.lock.lock()
            self.activeConnections = max(0, self.activeConnections - 1)
            self.lock.unlock()
        }

        let deadline = DispatchWorkItem {
            Log.net.debug("LAN inbound read timeout")
            close()
        }
        queue.asyncAfter(deadline: .now() + LANNode.readTimeout, execute: deadline)

        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                deadline.cancel()
                close()
            default:
                break
            }
        }

        connection.start(queue: queue)

        let sourceIP = Transport.remoteIP(of: connection) ?? "0.0.0.0"

        // Rate limit per source IP before doing any parsing work. The bucket is
        // keyed on the address *without* the `%scope` suffix: the scope only
        // names our receiving interface, so one link-local host reachable over
        // both en0 and awdl0 shares a single budget.
        let bucketKey = sourceIP.split(separator: "%", maxSplits: 1).first.map(String.init) ?? sourceIP
        guard bucket.consume(bucketKey) else {
            Log.net.debug("LAN inbound rate limited from \(sourceIP, privacy: .private)")
            deadline.cancel()
            close()
            return
        }

        Transport.readFrame(from: connection) { [weak self] result in
            switch result {
            case .failure(let error):
                Log.net.debug("LAN inbound read error: \(error.localizedDescription, privacy: .public)")
                deadline.cancel()
                close()

            case .success(let data):
                guard let self else { deadline.cancel(); close(); return }
                // Re-read the peer address now that the connection is
                // established; this is the address we trust.
                let ip = Transport.remoteIP(of: connection) ?? sourceIP
                guard let message = WireMessage.decode(data) else {
                    Log.net.debug("LAN inbound frame did not decode")
                    deadline.cancel()
                    close()
                    return
                }
                guard let handler = self.onRequest else {
                    deadline.cancel()
                    close()
                    return
                }
                // Verification and handling run off the main actor; the handler
                // hops to @MainActor only where it mutates state.
                Task.detached(priority: .userInitiated) {
                    let reply = await handler(message, ip)
                    deadline.cancel()
                    guard let reply, let framed = try? WireFrame.frame(reply) else {
                        close()
                        return
                    }
                    connection.send(content: framed, completion: .contentProcessed { error in
                        if let error {
                            Log.net.debug("LAN reply send failed: \(error.localizedDescription, privacy: .public)")
                        }
                        close()
                    })
                }
            }
        }
    }
}

// MARK: - Local address

/// Best available local IPv4 address; prefers Wi-Fi/Ethernet over cellular.
/// Used only to detect interface changes (contract §7: reconnect debouncing) —
/// it is never put on the wire.
nonisolated func localWiFiIP() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }

    let preferred = ["en0", "en1", "en2", "en3", "bridge100", "pdp_ip0", "pdp_ip1", "pdp_ip2"]
    var candidates: [(priority: Int, ip: String)] = []

    var ptr = ifaddr
    while let ifa = ptr {
        defer { ptr = ifa.pointee.ifa_next }
        let flags = Int32(ifa.pointee.ifa_flags)
        guard (flags & IFF_UP) != 0,
              (flags & IFF_RUNNING) != 0,
              (flags & IFF_LOOPBACK) == 0,
              let addrPtr = ifa.pointee.ifa_addr,
              addrPtr.pointee.sa_family == UInt8(AF_INET),
              let name = ifa.pointee.ifa_name else { continue }

        let interface = String(cString: name)
        guard let priority = preferred.firstIndex(of: interface) else { continue }

        var addr = addrPtr.pointee
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(&addr, socklen_t(addr.sa_len),
                          &hostname, socklen_t(hostname.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { continue }

        let ip = String(cString: hostname)
        guard !ip.hasPrefix("169.254") else { continue }
        candidates.append((priority, ip))
    }

    return candidates.min { $0.priority < $1.priority }?.ip
}
