//
//  WiFiDiscovery.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 04/04/2026.
//
//
//  WiFiDiscovery.swift
//  HopChat-1
//

import Foundation
import Network

// MARK: - Local WiFi IP

/// Returns the device's current WiFi (en0) IPv4 address, or nil if not on WiFi.
func localWiFiIP() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }

    var ptr = ifaddr
    while let ifa = ptr {
        let flags     = Int32(ifa.pointee.ifa_flags)
        let isUp      = (flags & IFF_UP)      != 0
        let isRunning = (flags & IFF_RUNNING)  != 0
        let isLoopback = (flags & IFF_LOOPBACK) != 0

        if isUp && isRunning && !isLoopback,
           ifa.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET),
           let name = ifa.pointee.ifa_name,
           String(cString: name).hasPrefix("en") {
            var addr = ifa.pointee.ifa_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(&addr, socklen_t(addr.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: hostname)
            }
        }
        ptr = ifa.pointee.ifa_next
    }
    return nil
}

// MARK: - Bonjour peer discovery

struct DiscoveredPeer {
    let ip:    String
    let port:  UInt16
    let phone: String
}

/// Publishes this node on mDNS and discovers other HopChat nodes on the LAN.
final class BonjourDiscovery: NSObject {

    static let serviceType = "_hopchat._udp"
    static let domain      = "local."

    var onPeerFound: ((DiscoveredPeer) -> Void)?
    var onPeerLost:  ((DiscoveredPeer) -> Void)?

    private var netService: NetService?
    private var browser:    NetServiceBrowser?
    private var resolving:  [NetService] = []

    // MARK: Publish own service
    func publish(phone: String, port: UInt16) {
        let txtData = NetService.data(fromTXTRecord: ["phone": Data(phone.utf8)])

        let svc = NetService(domain: BonjourDiscovery.domain,
                             type:   BonjourDiscovery.serviceType,
                             name:   "HopChat-\(phone)",
                             port:   Int32(port))
        svc.delegate = self
        svc.setTXTRecord(txtData)
        svc.publish()
        self.netService = svc
        print("📡 Bonjour published as HopChat-\(phone) on port \(port)")
    }

    // MARK: Browse for peers
    func startBrowsing() {
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: BonjourDiscovery.serviceType,
                            inDomain: BonjourDiscovery.domain)
        self.browser = b
        print("🔍 Bonjour browsing for peers…")
    }

    func stop() {
        netService?.stop()
        browser?.stop()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
    }
}

// MARK: - NetServiceDelegate

extension BonjourDiscovery: NetServiceDelegate {

    func netServiceDidPublish(_ sender: NetService) {
        print("✅ Bonjour published: \(sender.name)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("❌ Bonjour publish failed: \(errorDict)")
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else { return }

        // Parse phone from TXT record
        var phone = "unknown"
        if let txtData = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txtData)
            if let phoneData = dict["phone"] as? Data,
               let p = String(data: phoneData, encoding: .utf8) {
                phone = p
            }
        }

        // Find IPv4 address
        for data in addresses {
            var storage = sockaddr_storage()
            (data as NSData).getBytes(&storage, length: data.count)
            guard storage.ss_family == UInt8(AF_INET) else { continue }

            var addr4 = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr4.sin_addr, &hostBuf, socklen_t(INET_ADDRSTRLEN))
            let ip   = String(cString: hostBuf)
            let port = UInt16(bigEndian: addr4.sin_port)

            print("📬 Bonjour resolved: \(phone) @ \(ip):\(port)")
            onPeerFound?(DiscoveredPeer(ip: ip, port: port, phone: phone))
            resolving.removeAll { $0 === sender }
            return
        }

        resolving.removeAll { $0 === sender }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("❌ Bonjour resolve failed: \(errorDict)")
        resolving.removeAll { $0 === sender }
    }
}

// MARK: - NetServiceBrowserDelegate

extension BonjourDiscovery: NetServiceBrowserDelegate {

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        // Skip our own service
        if let ownName = netService?.name, service.name == ownName { return }
        service.delegate = self
        service.resolve(withTimeout: 5)
        resolving.append(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        print("👋 Bonjour peer left: \(service.name)")
        resolving.removeAll { $0 === service }
    }
}
