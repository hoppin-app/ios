//
//  BonjourDiscovery.swift
//  HopChat-1
//
//  LAN peer discovery over Bonjour (`_hopchat._tcp`).
//
//  Privacy fix (v1 broadcast the user's phone number in the TXT record to the
//  whole LAN): the advertisement now carries only a **random per-launch
//  instance token**. Nothing identifying is published. The peer's phone number
//  is learned afterwards, from the certificate in an authenticated `hello`
//  exchange — see `LANNode` / `KademliaService`.
//

import Foundation
import Network
import os

@MainActor
final class BonjourDiscovery: NSObject {

    /// A discovered advertisement. It carries no identity — only somewhere to
    /// send a `hello`.
    struct Advertisement: Hashable {
        let instanceName: String
        let endpoint: NWEndpoint
    }

    /// Random, regenerated every launch. Never derived from the phone number.
    let instanceToken: String = {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    var onPeerFound: ((Advertisement) -> Void)?
    var onPeerLost: ((Advertisement) -> Void)?

    private var browser: NWBrowser?
    private var netService: NetService?
    private var published = false
    private var browsing = false
    private var known: Set<String> = []

    // MARK: - Publish

    /// Advertises the LAN listener. `port` must be the port the listener
    /// actually bound to.
    func publish(port: UInt16) {
        guard port != 0 else {
            Log.net.error("Refusing to publish Bonjour service on port 0")
            return
        }
        stopPublishing()

        let service = NetService(domain: AppConfig.bonjourDomain,
                                 type: AppConfig.bonjourServiceType,
                                 name: "hc-\(instanceToken)",
                                 port: Int32(port))
        service.delegate = self
        // NetService defaults to infrastructure only; without this, peers
        // browsing over peer-to-peer Wi-Fi (AWDL) never see us.
        service.includesPeerToPeer = true
        // TXT carries the instance token only — no phone number, no identity.
        service.setTXTRecord(NetService.data(fromTXTRecord: ["t": Data(instanceToken.utf8)]))
        service.publish()
        netService = service
        published = true
        Log.net.info("Bonjour publishing on port \(port, privacy: .public)")
    }

    // MARK: - Browse

    func startBrowsing() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: AppConfig.bonjourServiceType,
                                                      domain: AppConfig.bonjourDomain)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                Log.net.error("Bonjour browse failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor [weak self] in self?.restartBrowsingAfterFailure() }
            case .ready:
                Log.net.debug("Bonjour browsing")
                // A healthy browser earns back the full retry budget.
                Task { @MainActor [weak self] in self?.browseRestartAttempts = 0 }
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handle(results: results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
        browsing = true
    }

    private func handle(results: Set<NWBrowser.Result>) {
        var current: Set<String> = []

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            // Never hello ourselves.
            guard name != "hc-\(instanceToken)" else { continue }
            current.insert(name)
            guard !known.contains(name) else { continue }
            known.insert(name)
            onPeerFound?(Advertisement(instanceName: name, endpoint: result.endpoint))
        }

        for gone in known.subtracting(current) {
            known.remove(gone)
            // The endpoint is no longer resolvable; report the name only.
            onPeerLost?(Advertisement(instanceName: gone,
                                      endpoint: .service(name: gone,
                                                         type: AppConfig.bonjourServiceType,
                                                         domain: AppConfig.bonjourDomain,
                                                         interface: nil)))
        }
    }

    private var browseRestartAttempts = 0

    private func restartBrowsingAfterFailure() {
        guard browsing else { return }
        browseRestartAttempts += 1
        guard browseRestartAttempts <= 5 else {
            Log.net.error("Bonjour browsing gave up after repeated failures")
            return
        }
        let delay = Double(min(30, 1 << browseRestartAttempts))
        browser?.cancel()
        browser = nil
        known.removeAll()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.browsing else { return }
            self.startBrowsing()
        }
    }

    // MARK: - Stop

    private func stopPublishing() {
        netService?.stop()
        netService?.delegate = nil
        netService = nil
        published = false
    }

    func stop() {
        browsing = false
        browseRestartAttempts = 0
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        known.removeAll()
        stopPublishing()
    }

    deinit {
        // NetService/NWBrowser must be torn down explicitly via `stop()`;
        // this is a last-resort safety net for the browser only.
        MainActor.assumeIsolated {
            browser?.cancel()
            netService?.stop()
        }
    }
}

// MARK: - NetServiceDelegate

extension BonjourDiscovery: NetServiceDelegate {

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        Log.net.debug("Bonjour published")
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode] ?? 0
        Log.net.error("Bonjour publish failed (code \(code.intValue, privacy: .public))")
    }
}
