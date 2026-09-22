//
//  BLETransport.swift
//  HopChat-1
//
//  The Bluetooth radio under the mesh: every phone advertises the hoppin
//  service *and* scans for it, so whichever side sees the other first opens the
//  connection. Each connected phone becomes a `MeshLink` handed to `MeshRouter`;
//  everything above this file is radio-agnostic.
//
//  Nothing identifying is exchanged here (contract §9.7). A link says hello with
//  a random node id that rotates every 15 minutes, and that is all a stranger
//  ever learns about us at this layer — authentication stays end-to-end, inside
//  the sealed envelope.
//
//  Roles:
//   • peripheral — advertises the service, owns the TX characteristic and
//     notifies subscribed centrals;
//   • central — scans, connects, writes to the peer's RX characteristic.
//
//  A pair of phones can connect in both directions at once; the duplicate link
//  is dropped once the hellos reveal both node ids (lower id keeps its outbound
//  link), so the router never sees two links to the same phone.
//

import Foundation
import CoreBluetooth
import os

@MainActor
final class BLETransport: NSObject {

    // Contract §9.7.
    static let serviceUUID = CBUUID(string: "F51978CD-5FDF-4C93-923B-0B71C67A7650")
    static let rxUUID = CBUUID(string: "F000660C-5018-4E6F-885B-AF99D7F4D0F1")
    static let txUUID = CBUUID(string: "C251B2FC-C83A-49A0-8C33-E1C49B8DDB60")

    /// How long a link may stay silent before we assume it is dead.
    static let helloTimeout: TimeInterval = 5
    /// Node id rotation (contract §9.7).
    static let nodeIDLifetime: TimeInterval = 15 * 60
    /// iOS gets unhappy well before this; the mesh doesn't need more.
    static let maxLinks = 8
    /// Conservative default until a peer's hello says what it can take.
    static let defaultFrameBytes = 512

    /// Called when a link is ready (after hello) and when it goes away.
    var onLinkUp: ((MeshLink) -> Void)?
    var onLinkDown: ((UUID) -> Void)?
    /// Assembled link messages of kind `.packet`.
    var onPacket: ((Data, UUID) -> Void)?
    /// Bluetooth is off, unauthorised, or unsupported.
    var onUnavailable: ((CBManagerState) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var txCharacteristic: CBMutableCharacteristic?

    /// Outbound links (we are the central).
    private var outbound: [UUID: OutboundLink] = [:]
    /// Inbound links (the peer is the central and writes to our RX).
    private var inbound: [UUID: InboundLink] = [:]
    /// Node ids we already have a link for, so duplicates can be dropped.
    private var nodeIDs: [UUID: Data] = [:]

    private var nodeID = BLEHello.randomNodeID()
    private var nodeIDRotatedAt = Date()
    private var isRunning = false
    private var sweepTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        rotateNodeIDIfNeeded()

        // Restoration identifiers let iOS hand the managers back after the app
        // is relaunched in the background with a live connection.
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "hoppin.mesh.central",
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
        peripheral = CBPeripheralManager(delegate: self, queue: .main, options: [
            CBPeripheralManagerOptionRestoreIdentifierKey: "hoppin.mesh.peripheral",
        ])

        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isRunning else { return }
                self.sweep()
            }
        }
        Log.net.info("BLE mesh transport starting")
    }

    func stop() {
        isRunning = false
        sweepTask?.cancel(); sweepTask = nil

        for link in outbound.values {
            central?.cancelPeripheralConnection(link.peripheral)
            onLinkDown?(link.id)
        }
        outbound.removeAll()
        for id in inbound.keys { onLinkDown?(id) }
        inbound.removeAll()
        nodeIDs.removeAll()

        central?.stopScan()
        central = nil
        peripheral?.stopAdvertising()
        peripheral?.removeAllServices()
        peripheral = nil
        txCharacteristic = nil
        Log.net.info("BLE mesh transport stopped")
    }

    var linkCount: Int { outbound.count + inbound.count }

    // MARK: - Sending

    /// Queues one link message on a link; chunking and flow control are
    /// handled per link.
    private func send(kind: BLEFrame.Kind, payload: Data, to id: UUID) {
        if let link = outbound[id] {
            link.enqueue(kind: kind, payload: payload)
            drain(link)
        } else if let link = inbound[id] {
            link.enqueue(kind: kind, payload: payload)
            drainInbound(link)
        }
    }

    // MARK: - Node id

    private func rotateNodeIDIfNeeded() {
        guard Date().timeIntervalSince(nodeIDRotatedAt) >= Self.nodeIDLifetime else { return }
        nodeID = BLEHello.randomNodeID()
        nodeIDRotatedAt = Date()
        // Re-advertising under a new id costs nothing and keeps us unlinkable
        // across the day.
        if isRunning, peripheral?.state == .poweredOn { startAdvertising() }
    }

    private func hello(maxFrameBytes: Int) -> Data {
        BLEHello(nodeID: nodeID, maxFrameBytes: maxFrameBytes).encoded()
    }

    // MARK: - Housekeeping

    private func sweep() {
        rotateNodeIDIfNeeded()
        let now = Date()
        for link in outbound.values where link.isStale(now: now) {
            Log.net.debug("BLE link timed out before hello")
            central?.cancelPeripheralConnection(link.peripheral)
            tearDown(link.id)
        }
        for link in inbound.values where link.isStale(now: now) {
            tearDown(link.id)
        }
        for link in outbound.values { link.reassembler.sweep() }
        for link in inbound.values { link.reassembler.sweep() }
        if isRunning, central?.state == .poweredOn, linkCount < Self.maxLinks { startScanning() }
    }

    private func tearDown(_ id: UUID) {
        guard outbound.removeValue(forKey: id) != nil || inbound.removeValue(forKey: id) != nil else { return }
        nodeIDs.removeValue(forKey: id)
        onLinkDown?(id)
    }

    /// Both phones may connect at once, giving two links to the same peer.
    /// The rule has to be symmetric, or both sides drop their link and the pair
    /// ends up with none: the phone with the lower node id keeps the link it
    /// opened (outbound), the other keeps the one it accepted (inbound).
    private func isDuplicate(nodeID peerID: Data, on id: UUID) -> Bool {
        guard nodeIDs.contains(where: { $0.value == peerID && $0.key != id }) else { return false }
        let weGoFirst = nodeID.lexicographicallyPrecedes(peerID)
        let isOutbound = outbound[id] != nil
        return weGoFirst ? !isOutbound : isOutbound
    }

    private func linkUp(id: UUID, peerNodeID: Data) {
        guard !isDuplicate(nodeID: peerNodeID, on: id) else {
            Log.net.debug("Dropping a duplicate BLE link to the same peer")
            if let link = outbound[id] { central?.cancelPeripheralConnection(link.peripheral) }
            tearDown(id)
            return
        }
        nodeIDs[id] = peerNodeID
        onLinkUp?(MeshLink(id: id) { [weak self] data in
            self?.send(kind: .packet, payload: data, to: id)
        })
    }

    private func handle(_ assembled: BLEFrame.Assembled, from id: UUID) {
        switch assembled.kind {
        case .hello:
            guard let hello = BLEHello.decode(assembled.payload) else {
                Log.net.debug("BLE hello was malformed — closing the link")
                tearDown(id)
                return
            }
            if let link = outbound[id] {
                link.peerFrameBytes = hello.maxFrameBytes
                link.sawHello = true
            } else if let link = inbound[id] {
                link.peerFrameBytes = hello.maxFrameBytes
                link.sawHello = true
            }
            linkUp(id: id, peerNodeID: hello.nodeID)

        case .packet:
            onPacket?(assembled.payload, id)
        }
    }

    // MARK: - Central role (we connect out)

    private func startScanning() {
        // Scanning without duplicate reports is the battery-friendly mode and
        // is also all iOS allows in the background.
        central?.scanForPeripherals(withServices: [Self.serviceUUID],
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func drain(_ link: OutboundLink) {
        guard let rx = link.rx else { return }
        while let chunk = link.nextChunk() {
            guard link.peripheral.canSendWriteWithoutResponse else {
                link.requeue(chunk)
                return
            }
            link.peripheral.writeValue(chunk, for: rx, type: .withoutResponse)
        }
    }

    // MARK: - Peripheral role (they connect to us)

    private func startAdvertising() {
        peripheral?.stopAdvertising()
        // No local name: the advertisement must say nothing about the user.
        peripheral?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }

    private func publishService() {
        guard let peripheral, txCharacteristic == nil else { return }
        let tx = CBMutableCharacteristic(type: Self.txUUID,
                                         properties: [.notify],
                                         value: nil,
                                         permissions: [.readable])
        let rx = CBMutableCharacteristic(type: Self.rxUUID,
                                         properties: [.writeWithoutResponse, .write],
                                         value: nil,
                                         permissions: [.writeable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [tx, rx]
        peripheral.removeAllServices()
        peripheral.add(service)
        txCharacteristic = tx
    }

    private func drainInbound(_ link: InboundLink) {
        guard let peripheral, let tx = txCharacteristic else { return }
        while let chunk = link.nextChunk() {
            if !peripheral.updateValue(chunk, for: tx, onSubscribedCentrals: [link.central]) {
                // The queue is full; `peripheralManagerIsReady` will call back.
                link.requeue(chunk)
                return
            }
        }
    }
}

// MARK: - Link state

/// Shared queueing and reassembly for both link directions.
@MainActor
private class LinkState {
    let id = UUID()
    let reassembler: BLEReassembler
    var peerFrameBytes = BLETransport.defaultFrameBytes
    var sawHello = false
    let openedAt = Date()

    private var outQueue: [Data] = []
    private var nextFrameID: UInt16 = 0

    init(now: @escaping () -> Date = { Date() }) {
        reassembler = BLEReassembler(now: now)
    }

    func enqueue(kind: BLEFrame.Kind, payload: Data) {
        nextFrameID &+= 1
        guard let chunks = BLEFrame.chunks(kind: kind, payload: payload,
                                           maxChunk: writeLimit, frameID: nextFrameID) else {
            Log.net.error("A mesh message could not be chunked for BLE")
            return
        }
        outQueue.append(contentsOf: chunks)
    }

    func nextChunk() -> Data? {
        outQueue.isEmpty ? nil : outQueue.removeFirst()
    }

    func requeue(_ chunk: Data) {
        outQueue.insert(chunk, at: 0)
    }

    var hasQueuedWork: Bool { !outQueue.isEmpty }

    /// Silent and still no hello — treat as dead.
    func isStale(now: Date) -> Bool {
        !sawHello && now.timeIntervalSince(openedAt) > BLETransport.helloTimeout
    }

    var writeLimit: Int { BLETransport.defaultFrameBytes }
}

@MainActor
private final class OutboundLink: LinkState {
    let peripheral: CBPeripheral
    var rx: CBCharacteristic?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
    }

    override var writeLimit: Int {
        min(peripheral.maximumWriteValueLength(for: .withoutResponse), peerFrameBytes)
    }
}

@MainActor
private final class InboundLink: LinkState {
    let central: CBCentral

    init(central: CBCentral) {
        self.central = central
        super.init()
    }

    override var writeLimit: Int {
        min(central.maximumUpdateValueLength, peerFrameBytes)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        MainActor.assumeIsolated {
            switch manager.state {
            case .poweredOn:
                startScanning()
            default:
                Log.net.info("BLE central unavailable (state \(manager.state.rawValue, privacy: .public))")
                onUnavailable?(manager.state)
            }
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard linkCount < Self.maxLinks else {
                manager.stopScan()
                return
            }
            guard !outbound.values.contains(where: { $0.peripheral.identifier == peripheral.identifier }) else { return }
            let link = OutboundLink(peripheral: peripheral)
            outbound[link.id] = link
            peripheral.delegate = self
            manager.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            if let link = link(for: peripheral) { tearDown(link.id) }
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            if let link = link(for: peripheral) { tearDown(link.id) }
            if isRunning, manager.state == .poweredOn { startScanning() }
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager,
                                    willRestoreState state: [String: Any]) {
        MainActor.assumeIsolated {
            // Relaunched in the background with live connections: adopt them.
            let restored = state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            for peripheral in restored where peripheral.state == .connected {
                let link = OutboundLink(peripheral: peripheral)
                outbound[link.id] = link
                peripheral.delegate = self
                peripheral.discoverServices([Self.serviceUUID])
            }
        }
    }

    private func link(for peripheral: CBPeripheral) -> OutboundLink? {
        outbound.values.first { $0.peripheral.identifier == peripheral.identifier }
    }
}

// MARK: - CBPeripheralDelegate (outbound links)

extension BLETransport: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let link = link(for: peripheral) else { return }
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case Self.rxUUID:
                    link.rx = characteristic
                case Self.txUUID:
                    peripheral.setNotifyValue(true, for: characteristic)
                default:
                    break
                }
            }
            guard link.rx != nil else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            // We opened the link, so we say hello first.
            send(kind: .hello, payload: hello(maxFrameBytes: link.writeLimit), to: link.id)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let link = link(for: peripheral), let chunk = characteristic.value else { return }
            if let assembled = link.reassembler.accept(chunk) {
                handle(assembled, from: link.id)
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard let link = link(for: peripheral) else { return }
            drain(link)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate (inbound links)

extension BLETransport: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        MainActor.assumeIsolated {
            switch manager.state {
            case .poweredOn:
                publishService()
            default:
                onUnavailable?(manager.state)
            }
        }
    }

    nonisolated func peripheralManager(_ manager: CBPeripheralManager,
                                       didAdd service: CBService,
                                       error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil else {
                Log.net.error("BLE service could not be published: \(String(describing: error), privacy: .public)")
                return
            }
            startAdvertising()
        }
    }

    nonisolated func peripheralManager(_ manager: CBPeripheralManager,
                                       central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            guard inbound.values.first(where: { $0.central.identifier == central.identifier }) == nil,
                  linkCount < Self.maxLinks else { return }
            let link = InboundLink(central: central)
            inbound[link.id] = link
            send(kind: .hello, payload: hello(maxFrameBytes: link.writeLimit), to: link.id)
        }
    }

    nonisolated func peripheralManager(_ manager: CBPeripheralManager,
                                       central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            guard let link = inbound.values.first(where: { $0.central.identifier == central.identifier }) else { return }
            tearDown(link.id)
        }
    }

    nonisolated func peripheralManager(_ manager: CBPeripheralManager,
                                       didReceiveWrite requests: [CBATTRequest]) {
        MainActor.assumeIsolated {
            for request in requests {
                guard request.characteristic.uuid == Self.rxUUID, let chunk = request.value else { continue }
                let link = inbound.values.first { $0.central.identifier == request.central.identifier }
                    ?? {
                        let new = InboundLink(central: request.central)
                        inbound[new.id] = new
                        return new
                    }()
                if let assembled = link.reassembler.accept(chunk) {
                    handle(assembled, from: link.id)
                }
            }
            if let first = requests.first, first.characteristic.properties.contains(.write) {
                manager.respond(to: first, withResult: .success)
            }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers manager: CBPeripheralManager) {
        MainActor.assumeIsolated {
            for link in inbound.values where link.hasQueuedWork { drainInbound(link) }
        }
    }

    nonisolated func peripheralManager(_ manager: CBPeripheralManager,
                                       willRestoreState state: [String: Any]) {
        MainActor.assumeIsolated {
            // Services come back with the restored state; re-advertise.
            if manager.state == .poweredOn { startAdvertising() }
        }
    }
}
