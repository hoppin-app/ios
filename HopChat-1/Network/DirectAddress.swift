//
//  DirectAddress.swift
//  HopChat-1
//
//  Reaching a contact directly across the internet, over IPv6.
//
//  Bonjour only works inside one broadcast domain, so two phones on different
//  Wi-Fi networks fall back to the relay. Where both have a globally routable
//  IPv6 address there is no NAT in the way: each side tells the other where it
//  can be reached — inside a normal sealed envelope, so only that contact
//  learns it — and delivery is attempted directly before the relay.
//
//  A firewall may still drop the first inbound packet, so a direct attempt is
//  always opportunistic: it is tried once with a short timeout and the relay
//  carries the message when it fails. IPv4 is deliberately not attempted here;
//  that needs STUN and hole punching (contract §10.3).
//
//  What this costs: the contact learns the sender's IP address, i.e. roughly
//  their ISP and city. That is why it is a setting, and why the address is
//  never put on the wire unsealed.
//

import Foundation

// MARK: - A place a contact can dial

/// Somewhere a peer said it can be reached, and until when.
nonisolated struct DirectCandidate: Equatable, Sendable {
    let address: String
    let port: UInt16
    let expiresAt: Date

    func isFresh(at now: Date = ServerClock.now()) -> Bool { expiresAt > now }
}

// MARK: - Addresses of this device

nonisolated enum DirectAddress {

    /// How long a published address is worth trying. iOS rotates temporary
    /// IPv6 addresses roughly daily and networks change far more often, so
    /// this is deliberately short: a stale address costs a 3 s timeout on
    /// every send until it expires.
    static let lifetime: TimeInterval = 30 * 60

    /// Longest lifetime accepted from a peer, whatever it claims.
    static let maxAcceptedLifetime: TimeInterval = 60 * 60

    /// At most this many addresses are published at once.
    static let maxAddresses = 2

    /// Interfaces worth publishing, best first. Cellular is included: an
    /// IPv6-only carrier network is one of the places this works best.
    static let interfaces = ["en0", "en1", "en2", "en3", "pdp_ip0", "pdp_ip1", "pdp_ip2"]

    /// True when `address` is a global unicast IPv6 address — `2000::/3`.
    ///
    /// Everything else is unreachable from another network and must never be
    /// published: loopback (`::1`), link-local (`fe80::/10`, which is what the
    /// LAN path already uses), unique-local (`fc00::/7`), multicast
    /// (`ff00::/8`) and IPv4-mapped (`::ffff:0:0/96`).
    static func isGloballyRoutable(_ address: String) -> Bool {
        // A scope suffix ("%en0") only ever belongs to a link-local address.
        guard !address.contains("%") else { return false }
        var parsed = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &parsed) }) == 1 else { return false }
        let first = withUnsafeBytes(of: &parsed) { $0[0] }
        return (first & 0xE0) == 0x20
    }

    /// This device's globally routable IPv6 addresses, best interface first.
    ///
    /// A phone usually has several (a stable one and a rotating temporary
    /// one); both are published, since either may be the one a firewall has
    /// seen traffic from.
    static func local(interfaces preferred: [String] = interfaces) -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var found: [(priority: Int, address: String)] = []
        var pointer = ifaddr
        while let ifa = pointer {
            defer { pointer = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addrPointer = ifa.pointee.ifa_addr,
                  addrPointer.pointee.sa_family == UInt8(AF_INET6),
                  let name = ifa.pointee.ifa_name else { continue }

            guard let priority = preferred.firstIndex(of: String(cString: name)) else { continue }

            var storage = sockaddr_storage()
            memcpy(&storage, addrPointer, Int(addrPointer.pointee.sa_len))
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let resolved = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, socklen_t(addrPointer.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            guard resolved == 0 else { continue }

            let address = String(cString: host)
            guard isGloballyRoutable(address) else { continue }
            found.append((priority, address))
        }

        return found
            .sorted { $0.priority < $1.priority }
            .map(\.address)
            .reduced(to: maxAddresses)
    }

    /// The candidate to dial for a peer: the first address that is still
    /// fresh, or nil when there is nothing worth trying.
    /// `isDialable` decides which addresses are worth keeping; it is a
    /// parameter only so tests can dial loopback, which the real rule refuses.
    static func candidate(from addresses: [String],
                          port: UInt16,
                          expiresAt: Date,
                          now: Date = ServerClock.now(),
                          isDialable: (String) -> Bool = isGloballyRoutable) -> DirectCandidate? {
        guard port != 0, expiresAt > now else { return nil }
        guard let address = addresses.first(where: isDialable) else { return nil }
        // However long the peer claims, we keep it at most an hour.
        let capped = min(expiresAt, now.addingTimeInterval(maxAcceptedLifetime))
        return DirectCandidate(address: address, port: port, expiresAt: capped)
    }
}

private extension Array where Element == String {
    /// First `limit` elements, without duplicates.
    func reduced(to limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in self where seen.insert(value).inserted {
            result.append(value)
            if result.count == limit { break }
        }
        return result
    }
}
