//
//  HopChatService.swift
//  HopChat-1
//
//  `KademliaService` — the only networking API the views use (contract §7).
//
//  What changed versus v1, and why:
//   • Nothing inbound is trusted on its word any more. Every message must carry
//     a certificate signed by the pinned server key, a valid wire/envelope
//     signature, be fresh (±300 s) and not a replay. `senderPhone`, `senderID`
//     and self-reported IPs no longer grant anything.
//   • The open DHT (`store` / `findValue` / hole punching / `peerOnline` /
//     relay / `offlineNotify` / `cameOnline` / auto-accepted `connectRequest`)
//     is gone. Internet delivery is an encrypted store-and-forward relay;
//     direct TCP happens only between authenticated LAN peers.
//   • There is no plaintext fallback in either direction.
//

import Foundation
import Combine
import Network
import UIKit
import os

// MARK: - Public state types

nonisolated enum ConnectionState: Equatable {
    case offline
    case connecting
    case online
    case error(String)
}

nonisolated enum PresenceStatus: String {
    case online = "Online"
    case recently = "Recently active"
    case offline = "Offline"

    /// Text shown to the user. The raw values above are stable identifiers and
    /// are deliberately left untranslated.
    var label: String {
        switch self {
        case .online:   return String(localized: "Online")
        case .recently: return String(localized: "Recently active")
        case .offline:  return String(localized: "Offline")
        }
    }
}

nonisolated enum ServiceError: LocalizedError, Equatable {
    case notRegistered
    case invalidPhone
    case notOnHopChat
    case blocked
    case keyChangeUnacknowledged
    case tooManyMembers
    case server(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notRegistered:
            return String(localized: "You need to verify your phone number first.")
        case .invalidPhone:
            return String(localized: "That doesn't look like a valid phone number.")
        case .notOnHopChat:
            return String(localized: "That number isn't on HopChat yet.")
        case .blocked:
            return String(localized: "You've blocked this contact.")
        case .keyChangeUnacknowledged:
            return String(localized: "This contact's security code changed. Review it before sending.")
        case .tooManyMembers:
            return String(localized: "A group can have at most \(AppConfig.maxGroupMembers) members.")
        case .server(let message):
            return message
        case .unavailable:
            return String(localized: "HopChat can't reach the network right now.")
        }
    }
}

/// What happened to one inbound envelope. This drives the relay ack decision:
/// an envelope is only deleted from the server once we are *finished* with it.
nonisolated enum IngestOutcome: Equatable {
    /// Stored (or already stored) — safe to ack.
    case accepted
    /// Permanently unusable: forged or invalid certificate, bad signature,
    /// wrong recipient, too old, malformed or undecryptable payload, blocked
    /// sender. It will never become valid, so ack it.
    case rejected
    /// Transiently unusable: the Keychain is unreadable, or the sender's key
    /// changed and the user hasn't accepted it yet. **Do not ack** — leave it
    /// on the relay so it can be delivered once the condition clears.
    case retryLater
}

// MARK: - Service

@MainActor
final class KademliaService: ObservableObject {

    // MARK: Shared instance

    static let shared = KademliaService(crypto: .shared,
                                        trust: .shared,
                                        store: .shared)

    /// BGAppRefresh identifier. Registration and scheduling live in the app
    /// layer; this service only supplies `performBackgroundFetch()`.
    nonisolated static let backgroundTaskIdentifier = "com.hopchat.relay-fetch"

    // MARK: Dependencies (injected — no hidden singletons in the pipeline)

    private let crypto: CryptoManager
    private let trust: TrustStore
    private let store: ConversationStore
    /// Rebuilt on `reconnect()` so DEBUG host/key/port changes take effect
    /// without relaunching the app.
    private var server: ServerClient
    private let makeServer: (CryptoManager) -> ServerClient
    private let enableLAN: Bool

    init(crypto: CryptoManager,
         trust: TrustStore,
         store: ConversationStore,
         serverFactory: ((CryptoManager) -> ServerClient)? = nil,
         enableLAN: Bool = true) {
        self.crypto = crypto
        self.trust = trust
        self.store = store
        let makeServer = serverFactory ?? { ServerClient.makeDefault(crypto: $0) }
        self.makeServer = makeServer
        self.server = makeServer(crypto)
        self.enableLAN = enableLAN
        self.routing = RoutingTable(localID: NodeID.from(phone: crypto.certificate?.phone ?? "unregistered"))
    }

    // MARK: Published state

    @Published private(set) var connectionState: ConnectionState = .offline
    /// `""` until registered.
    @Published private(set) var myPhone: String = ""
    @Published private(set) var isRegistered: Bool = false
    /// Conversation IDs where someone is typing.
    @Published private(set) var typingPeers: Set<String> = []
    @Published private(set) var presenceMap: [String: PresenceStatus] = [:]
    @Published var lastError: String?

    /// Legacy v1 phone number found in UserDefaults, kept only as a prefill
    /// hint for the SMS verification screen. The key is removed once the user
    /// verifies successfully.
    private(set) var legacyPhoneHint: String?

    // MARK: Internal state

    private var routing: RoutingTable
    private var lanNode: LANNode?
    private var bonjour: BonjourDiscovery?
    private let replayCache = ReplayCache(ttl: 600)

    private var relayTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var pathDebounce: Task<Void, Never>?

    private var isRunning = false
    private var lanPort: UInt16 = 0
    private var lastLocalIP: String?
    private var relayBackoff = Backoff(base: 1, cap: 60)

    /// phone → last time we refreshed their certificate.
    private var certificateRefreshedAt: [String: Date] = [:]
    /// phone → last time we received anything from them (presence fallback).
    private var lastHeardFrom: [String: Date] = [:]
    /// Contacts we already announced our profile to this launch.
    private var profileAnnouncedTo: Set<String> = []
    private var typingTimers: [String: Task<Void, Never>] = [:]
    private var lastTypingSentAt: [String: Date] = [:]

    /// Injectable clock. Tests drive the fixed-timestamp fixtures through
    /// `processIncoming` by moving this, rather than by faking the system time.
    var clock: () -> Date = { Date() }
    private var now: Date { clock() }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }

        AppConfig.registerDefaults()
        migrateLegacyPhoneIfNeeded()

        guard isServerKeyUsable else {
            Log.net.error("Pinned server key is missing or invalid — refusing to start")
            connectionState = .error(String(localized: "Server key not configured"))
            return
        }

        do {
            try crypto.ensureKeysLoaded()
        } catch {
            Log.crypto.error("Identity keys unavailable: \(String(describing: error), privacy: .public)")
            connectionState = .error(String(localized: "Keychain unavailable — unlock the device and try again."))
            return
        }

        guard let certificate = crypto.certificate else {
            isRegistered = false
            myPhone = ""
            connectionState = .offline
            Log.net.info("No identity certificate yet — waiting for SMS verification")
            return
        }

        isRunning = true
        myPhone = certificate.phone
        isRegistered = true
        routing = RoutingTable(localID: NodeID.from(phone: certificate.phone))
        connectionState = .connecting

        startLAN()
        startPathMonitor()

        relayTask = Task { [weak self] in await self?.relayLoop() }
        retryTask = Task { [weak self] in await self?.retryLoop() }
        maintenanceTask = Task { [weak self] in await self?.maintenanceLoop() }
    }

    func stop() {
        isRunning = false

        relayTask?.cancel(); relayTask = nil
        retryTask?.cancel(); retryTask = nil
        maintenanceTask?.cancel(); maintenanceTask = nil
        pathDebounce?.cancel(); pathDebounce = nil
        pathMonitor?.cancel(); pathMonitor = nil

        for (_, task) in typingTimers { task.cancel() }
        typingTimers.removeAll()

        stopLAN()
        routing.removeAll()
        presenceMap = [:]
        typingPeers = []
        connectionState = .offline
    }

    func reconnect() async {
        stop()
        server = makeServer(crypto)
        await start()
    }

    /// Awaits any queued disk writes. Phase-2 should call this when the app
    /// moves to the background or terminates.
    func flushPendingWrites() async {
        await store.flush()
    }

    private var isServerKeyUsable: Bool {
        let key = server.serverKeyBase64
        guard key != AppConfig.serverKeyPlaceholder,
              let raw = Data(base64Encoded: key), raw.count == 32 else { return false }
        return true
    }

    // MARK: - Legacy migration (contract §18)

    private func migrateLegacyPhoneIfNeeded() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: AppConfig.Keys.legacyPhone),
              !legacy.isEmpty else { return }
        if crypto.certificate == nil {
            // v1 stored the phone with no proof of ownership. The user has to
            // re-verify over SMS; the old number is only a prefill hint.
            legacyPhoneHint = PhoneNumber.normalize(legacy) ?? legacy
            Log.app.info("Legacy phone found — SMS re-verification required")
        } else {
            defaults.removeObject(forKey: AppConfig.Keys.legacyPhone)
        }
    }

    // MARK: - Registration

    func requestVerificationCode(phone rawPhone: String) async throws -> (normalizedPhone: String, retryAfter: Int) {
        guard isServerKeyUsable else { throw ServiceError.server("Server key not configured") }
        guard let phone = PhoneNumber.normalize(rawPhone) else { throw ServiceError.invalidPhone }
        do {
            let retryAfter = try await server.verifyStart(phone: phone)
            return (phone, retryAfter)
        } catch let error as ServerError {
            throw map(error)
        }
    }

    func confirmVerification(phone: String, code: String) async throws {
        guard let phone = PhoneNumber.normalize(phone) else { throw ServiceError.invalidPhone }
        do {
            let certificate = try await server.verifyConfirm(phone: phone, code: code)
            guard certificate.isValid(serverKeyBase64: server.serverKeyBase64, now: now),
                  certificate.phone == phone,
                  certificate.signingKey == crypto.signingPublicKeyBase64 else {
                throw ServiceError.server(String(localized: "The server issued a certificate we can't verify."))
            }
            try crypto.setCertificate(certificate)

            // Verification succeeded — the v1 key has served its purpose.
            UserDefaults.standard.removeObject(forKey: AppConfig.Keys.legacyPhone)
            legacyPhoneHint = nil

            myPhone = phone
            isRegistered = true
            await reconnect()
        } catch let error as ServerError {
            throw map(error)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.server(error.localizedDescription)
        }
    }

    // MARK: - Number change (contract §13)

    func startNumberChange(newPhone raw: String) async throws -> (normalizedPhone: String, retryAfter: Int) {
        guard isRegistered else { throw ServiceError.notRegistered }
        guard let phone = PhoneNumber.normalize(raw) else { throw ServiceError.invalidPhone }
        do {
            let retryAfter = try await server.changeNumberStart(newPhone: phone)
            return (phone, retryAfter)
        } catch let error as ServerError {
            throw map(error)
        }
    }

    func confirmNumberChange(newPhone: String, code: String) async throws {
        guard isRegistered else { throw ServiceError.notRegistered }
        guard let phone = PhoneNumber.normalize(newPhone) else { throw ServiceError.invalidPhone }
        let oldPhone = myPhone
        do {
            let certificate = try await server.changeNumberConfirm(newPhone: phone, code: code)
            guard certificate.isValid(serverKeyBase64: server.serverKeyBase64, now: now),
                  certificate.phone == phone,
                  certificate.signingKey == crypto.signingPublicKeyBase64 else {
                throw ServiceError.server(String(localized: "The server issued a certificate we can't verify."))
            }
            try crypto.setCertificate(certificate)
            myPhone = phone
            routing = RoutingTable(localID: NodeID.from(phone: phone))

            // Tell every contact, carrying the new certificate so they can
            // migrate their pin without a TOFU warning.
            let payload = ChatPayload(kind: .numberChange,
                                      newPhone: phone,
                                      newCertificate: certificate.encodedJSON())
            let contacts = store.contacts.filter { !$0.isBlocked }.map(\.phone)
            for contact in contacts {
                _ = await sendPayload(payload, to: contact, envelopeID: UUID().uuidString)
            }
            Log.net.info("Number change complete from \(PhoneNumber.masked(oldPhone), privacy: .private) to \(PhoneNumber.masked(phone), privacy: .private)")
            await reconnect()
        } catch let error as ServerError {
            throw map(error)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.server(error.localizedDescription)
        }
    }

    // MARK: - Contacts

    @discardableResult
    func addContact(phone raw: String, name: String?) async throws -> Contact {
        guard isRegistered else { throw ServiceError.notRegistered }
        guard let phone = PhoneNumber.normalize(raw), phone != myPhone else {
            throw ServiceError.invalidPhone
        }

        if let existing = store.contact(for: phone) {
            if let name, !name.isEmpty, existing.name != name {
                store.renameContact(phone: phone, newName: name)
            }
            _ = await ensureCertificate(for: phone, force: true)
            await announceProfileIfNeeded(to: phone)
            return store.contact(for: phone) ?? existing
        }

        guard await ensureCertificate(for: phone, force: true) != nil else {
            throw ServiceError.notOnHopChat
        }

        let contact = Contact(phone: phone,
                              name: (name?.isEmpty == false ? name! : phone),
                              addedAt: Date())
        store.addContact(contact)
        await announceProfileIfNeeded(to: phone)
        return contact
    }

    // MARK: - Sending

    func sendText(_ text: String, to conversationID: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, isRegistered else { return }

        let messageID = UUID().uuidString
        let message = StoredMessage(id: messageID,
                                    conversationID: conversationID,
                                    fromPhone: myPhone,
                                    toPhone: recipientLabel(for: conversationID),
                                    kind: .text,
                                    body: body,
                                    status: .pending,
                                    isFromMe: true)
        guard store.appendMessage(message) else { return }
        await deliverStoredMessage(messageID: messageID, conversationID: conversationID)
    }

    func sendImage(_ jpeg: Data, to conversationID: String) async {
        guard isRegistered, !jpeg.isEmpty else { return }
        guard jpeg.count <= ChatPayload.maxImageBytes else {
            lastError = String(localized: "That image is too large to send.")
            return
        }

        let messageID = UUID().uuidString
        let filename: String
        do {
            filename = try store.saveImage(jpeg, id: messageID)
        } catch {
            Log.store.error("Could not save outgoing image: \(String(describing: error), privacy: .public)")
            lastError = String(localized: "Couldn't save that image.")
            return
        }

        let message = StoredMessage(id: messageID,
                                    conversationID: conversationID,
                                    fromPhone: myPhone,
                                    toPhone: recipientLabel(for: conversationID),
                                    kind: .image,
                                    body: "",
                                    imageFilename: filename,
                                    status: .pending,
                                    isFromMe: true)
        guard store.appendMessage(message) else { return }
        await deliverStoredMessage(messageID: messageID, conversationID: conversationID)
    }

    /// Builds the payload for a stored message and fans it out to every
    /// recipient. Status becomes `.sent` when at least one recipient accepted
    /// it; otherwise it stays `.pending` for the retry loop.
    private func deliverStoredMessage(messageID: String, conversationID: String) async {
        guard let message = store.thread(conversationID).first(where: { $0.id == messageID }) else { return }

        let isGroup = ConversationStore.groupID(from: conversationID) != nil
        let groupID = ConversationStore.groupID(from: conversationID)

        var payload: ChatPayload
        switch message.kind {
        case .text:
            payload = ChatPayload(kind: isGroup ? .groupText : .text,
                                  text: message.body,
                                  groupID: groupID)
        case .image:
            guard let filename = message.imageFilename,
                  let data = try? Data(contentsOf: store.imageURL(filename)) else {
                store.updateStatus(messageID: messageID, conversationID: conversationID, to: .failed)
                return
            }
            payload = ChatPayload(kind: isGroup ? .groupImage : .image,
                                  imageJPEGBase64: data.base64EncodedString(),
                                  groupID: groupID)
        case .system:
            return
        }

        let recipients = self.recipients(for: conversationID)
        guard !recipients.isEmpty else {
            store.updateStatus(messageID: messageID, conversationID: conversationID, to: .failed)
            return
        }

        store.recordAttempt(messageID: messageID, conversationID: conversationID)

        var deliveredToAny = false
        for recipient in recipients {
            if await sendPayload(payload, to: recipient, envelopeID: messageID) {
                deliveredToAny = true
            }
        }

        if deliveredToAny {
            store.updateStatus(messageID: messageID, conversationID: conversationID, to: .sent)
        } else {
            Log.net.debug("Message \(messageID.prefix(8), privacy: .public) still pending — will retry")
        }
    }

    /// Seals `payload` for one recipient and delivers it: LAN direct when the
    /// peer is an authenticated LAN peer, otherwise the encrypted relay.
    /// Never sends anything that isn't sealed against a pinned, valid cert.
    @discardableResult
    private func sendPayload(_ payload: ChatPayload,
                             to phone: String,
                             envelopeID: String) async -> Bool {
        guard isRegistered, phone != myPhone else { return false }
        guard !store.isBlocked(phone) else { return false }

        // Never sign or seal with a degraded (empty) key: the non-throwing
        // accessors return "" while the Keychain is locked.
        guard crypto.isReady else {
            Log.crypto.error("Refusing to send — identity keys unavailable")
            lastError = ServiceError.unavailable.errorDescription
            return false
        }

        guard let recipientCert = await ensureCertificate(for: phone) else { return false }

        guard !trust.pendingKeyChanges.contains(phone), !trust.hasPendingKeyChange(phone) else {
            Log.net.error("Refusing to send to \(PhoneNumber.masked(phone), privacy: .private) — unacknowledged key change")
            lastError = ServiceError.keyChangeUnacknowledged.errorDescription
            return false
        }

        let envelope: Envelope
        do {
            let data = try payload.encoded()
            envelope = try crypto.seal(data,
                                       envelopeID: envelopeID,
                                       recipientPhone: phone,
                                       recipientCert: recipientCert,
                                       timestamp: Int64(now.timeIntervalSince1970))
        } catch {
            Log.crypto.error("Seal failed: \(String(describing: error), privacy: .public)")
            return false
        }

        // 1. Authenticated LAN peer — direct, no server involved.
        if let peer = routing.peer(for: phone), peer.isOnline() {
            var wire = WireMessage(type: .directEnvelope,
                                   senderPhone: myPhone,
                                   senderPort: lanPort,
                                   certificate: crypto.certificate?.encodedJSON(),
                                   recipientPhone: phone,
                                   envelope: envelope)
            wire.signature = crypto.sign(wire.signedFields)
            if let reply = await lanNode?.send(wire, to: peer.ip, port: peer.port, timeout: 3),
               isAuthenticLANReply(reply, from: phone, txID: wire.txID),
               reply.wireType == .directAck {
                touchPeer(phone)
                return true
            }
        }

        // 2. Typing indicators are LAN-only — never relayed (contract §4).
        guard !payload.isLANOnly else { return false }

        // 3. Encrypted store-and-forward relay.
        do {
            try await server.deposit(envelope)
            connectionState = .online
            return true
        } catch let error as ServerError {
            Log.net.debug("Relay deposit failed: \(String(describing: error), privacy: .public)")
            guard case .server(let code, _) = error else {
                connectionState = .offline
                return false
            }
            if code == "blocked" { return false }
            if code == "recipient_not_registered" {
                // They deleted their account (or changed number). Forget the
                // cached freshness so the next attempt re-checks the server
                // instead of re-sealing to a dead certificate.
                certificateRefreshedAt[phone] = nil
                return false
            }
            // The server only accepts the phone's *current* serial, so a cert we
            // superseded stops working immediately. Renew and retry exactly once.
            if code == "cert_invalid" || code == "not_registered" {
                await renewCertificateIfPossible(force: true)
                guard let resealed = try? reseal(envelope, payload: payload, to: phone) else { return false }
                do {
                    try await server.deposit(resealed)
                    connectionState = .online
                    return true
                } catch {
                    connectionState = .offline
                    return false
                }
            }
            // The server answered, so we are online — the deposit was simply
            // refused (queue_full, too_large, rate_limited, …). Retry later.
            return false
        } catch {
            return false
        }
    }

    /// Re-seals a payload after our certificate was renewed, so the envelope
    /// carries the certificate the server will now accept.
    private func reseal(_ original: Envelope, payload: ChatPayload, to phone: String) throws -> Envelope {
        guard let recipientCert = trust.pinnedCertificate(for: phone) else {
            throw CryptoError.noCertificate
        }
        return try crypto.seal(try payload.encoded(),
                               envelopeID: original.id,
                               recipientPhone: phone,
                               recipientCert: recipientCert,
                               timestamp: Int64(now.timeIntervalSince1970))
    }

    // MARK: - Certificates

    /// Returns a valid, pinned certificate for `phone`, refreshing it from the
    /// server when it is older than 24 h, missing, or expired.
    /// Returns `nil` when the contact isn't on HopChat or has an unacknowledged
    /// key change.
    private func ensureCertificate(for phone: String, force: Bool = false) async -> IdentityCertificate? {
        if trust.hasPendingKeyChange(phone) {
            lastError = ServiceError.keyChangeUnacknowledged.errorDescription
            return nil
        }

        let pinned = trust.pinnedCertificate(for: phone)
        let refreshedAt = certificateRefreshedAt[phone]
        let isFresh = refreshedAt.map { now.timeIntervalSince($0) < 24 * 3600 } ?? false

        if !force, let pinned, isFresh,
           pinned.isValid(serverKeyBase64: server.serverKeyBase64, now: now) {
            return pinned
        }

        do {
            guard let fetched = try await server.lookupCertificate(phone: phone) else {
                // Not registered. Fall back to a still-valid pin if we have one.
                if let pinned, pinned.isValid(serverKeyBase64: server.serverKeyBase64, now: now) { return pinned }
                return nil
            }
            guard fetched.isValid(serverKeyBase64: server.serverKeyBase64, now: now),
                  fetched.phone == phone else {
                Log.crypto.error("Certificate for \(PhoneNumber.masked(phone), privacy: .private) failed validation")
                return nil
            }
            certificateRefreshedAt[phone] = now
            return applyTrust(fetched, for: phone)
        } catch {
            Log.net.debug("Certificate lookup failed: \(String(describing: error), privacy: .public)")
            // Offline: a valid pin is still good enough to send.
            if let pinned, pinned.isValid(serverKeyBase64: server.serverKeyBase64, now: now) { return pinned }
            return nil
        }
    }

    /// A TOFU evaluation, keeping a *permanent* refusal distinct from a
    /// *transient* one. Collapsing the two is what lets transient failures ack
    /// and destroy mail, so the distinction is load-bearing.
    private enum TrustDecision {
        case ok(IdentityCertificate)
        case keyChanged
        case unavailable

        var certificate: IdentityCertificate? {
            if case .ok(let certificate) = self { return certificate }
            return nil
        }
    }

    private func decideTrust(_ certificate: IdentityCertificate, for phone: String) -> TrustDecision {
        switch trust.evaluate(certificate) {
        case .trusted:
            trust.updatePinnedCertificate(certificate)
            return .ok(certificate)
        case .newContact:
            return .ok(certificate)
        case .keyChanged(let previous):
            Log.crypto.error("Signing key changed for \(PhoneNumber.masked(phone), privacy: .private) (was \(previous.prefix(8), privacy: .private))")
            lastError = ServiceError.keyChangeUnacknowledged.errorDescription
            return .keyChanged
        default:
            // `.unavailable` — the Keychain could not be read (device locked).
            // TrustStore deliberately refuses to pin here; treating it as a new
            // contact would pin whatever key happens to be on the wire. This is
            // transient: don't send, don't accept, retry later.
            Log.crypto.error("Trust evaluation unavailable for \(PhoneNumber.masked(phone), privacy: .private) — retry later")
            lastError = ServiceError.unavailable.errorDescription
            return .unavailable
        }
    }

    /// Send-path convenience: the certificate, but only when it is safe to use.
    @discardableResult
    private func applyTrust(_ certificate: IdentityCertificate, for phone: String) -> IdentityCertificate? {
        decideTrust(certificate, for: phone).certificate
    }

    func acceptKeyChange(phone: String) async {
        trust.acceptKeyChange(for: phone)
        certificateRefreshedAt[phone] = nil
        _ = await ensureCertificate(for: phone, force: true)
        // Messages held while the key change was pending were refused, not
        // failed — send them now rather than making the user wait out the
        // backoff, including group messages that include this contact.
        await retryPending(involving: phone, ignoringBackoff: true)
    }

    func refreshCertificate(for phone: String) async {
        _ = await ensureCertificate(for: phone, force: true)
    }

    func isEncryptionReady(for conversationID: String) -> Bool {
        let recipients = self.recipients(for: conversationID)
        guard !recipients.isEmpty else { return false }
        return recipients.allSatisfy { phone in
            guard !trust.hasPendingKeyChange(phone),
                  let cert = trust.pinnedCertificate(for: phone) else { return false }
            return cert.isValid(serverKeyBase64: server.serverKeyBase64, now: now)
        }
    }

    // MARK: - Relay loop (contract §7)

    private func relayLoop() async {
        while !Task.isCancelled && isRunning {
            do {
                let envelopes = try await server.fetch(wait: AppConfig.relayFetchWait, max: 50)
                connectionState = .online
                if envelopes.isEmpty {
                    relayBackoff.reset()
                    continue
                }
                let result = await ingest(envelopes)
                if result.settled > 0 {
                    relayBackoff.reset()
                } else {
                    // Every envelope was deferred (locked Keychain, or an
                    // unacknowledged key change), so they are all still queued
                    // on the server. Re-fetching immediately would spin on the
                    // same envelopes — back off first.
                    let delay = relayBackoff.next()
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if case ServerError.server(let code, let message) = error {
                    Log.net.error("Relay fetch rejected: \(code, privacy: .public)")
                    if code == "cert_invalid" || code == "not_registered" {
                        // Our cert was superseded (or the server forgot us).
                        // Renew and let the loop retry rather than parking offline.
                        connectionState = .connecting
                        _ = message
                        await renewCertificateIfPossible(force: true)
                    } else {
                        connectionState = .offline
                    }
                } else {
                    connectionState = .offline
                }
                let delay = relayBackoff.next()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Processes, persists, flushes, then acks — never ack before the data is
    /// safely on disk, and never ack an envelope that failed for a *transient*
    /// reason. Acking deletes it from the server, so a deferred envelope is
    /// left queued (the relay holds it for 7 days and redelivers; our persisted
    /// seen-set makes redelivery idempotent).
    @discardableResult
    private func ingest(_ envelopes: [Envelope]) async -> (accepted: Int, settled: Int, deferred: Int) {
        var settledIDs: [String] = []
        var accepted = 0
        var deferred = 0

        for envelope in envelopes {
            switch await processIncoming(envelope) {
            case .accepted:
                accepted += 1
                settledIDs.append(envelope.id)
            case .rejected:
                settledIDs.append(envelope.id)
            case .retryLater:
                deferred += 1
            }
        }

        await store.flush()

        if !settledIDs.isEmpty {
            do {
                try await server.ack(settledIDs)
            } catch {
                // The server will redeliver; the persisted seen-set makes that
                // a no-op on our side.
                Log.net.debug("Relay ack failed: \(String(describing: error), privacy: .public)")
            }
        }
        if deferred > 0 {
            Log.net.info("\(deferred, privacy: .public) envelope(s) deferred — left on the relay for redelivery")
        }
        return (accepted, settledIDs.count, deferred)
    }

    /// One-shot fetch for `BGAppRefreshTask`. Returns `true` when something
    /// arrived (so the app layer can report `.newData`).
    func performBackgroundFetch() async -> Bool {
        guard isRegistered, isServerKeyUsable else { return false }
        do {
            let envelopes = try await server.fetch(wait: 3, max: 50)
            guard !envelopes.isEmpty else { return false }
            let result = await ingest(envelopes)
            NotificationService.shared.setBadge(store.totalUnreadCount)
            if result.settled == 0 && result.deferred > 0 {
                // Typically a background refresh before the first unlock after
                // reboot: nothing could be decrypted, and it is all still on the
                // relay. Report "no new data" so the system doesn't treat this
                // as a productive wake-up.
                return false
            }
            return result.accepted > 0
        } catch {
            Log.net.debug("Background fetch failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Inbound envelopes (contract §4 validation order)

    /// Validates, decrypts and applies one envelope. `internal` so tests can
    /// drive the pipeline without a network.
    @discardableResult
    func processIncoming(_ envelope: Envelope, viaLAN: Bool = false) async -> IngestOutcome {
        // 1. Sender certificate valid and bound to the claimed phone.
        guard let senderCert = IdentityCertificate.decode(envelope.senderCertificate),
              senderCert.isValid(serverKeyBase64: server.serverKeyBase64, now: now),
              senderCert.phone == envelope.senderPhone else {
            Log.net.error("Envelope dropped: sender certificate invalid")
            return .rejected
        }
        let sender = senderCert.phone

        // 2. The agreement key used is the current one, or a recently pinned one.
        guard senderCert.agreementKey == envelope.senderAgreementKey
                || trust.isRecentAgreementKey(envelope.senderAgreementKey, for: sender) else {
            Log.net.error("Envelope dropped: unknown sender agreement key")
            return .rejected
        }

        // 3. Signature over the envelope's signed fields.
        guard CryptoManager.verify(envelope.signedFields,
                                   signature: envelope.signature,
                                   signingKeyBase64: senderCert.signingKey) else {
            Log.net.error("Envelope dropped: bad signature")
            return .rejected
        }

        // 4. Addressed to us, not too old, not already seen.
        guard envelope.recipientPhone == myPhone else {
            Log.net.error("Envelope dropped: wrong recipient")
            return .rejected
        }
        let age = abs(Int64(now.timeIntervalSince1970) - envelope.timestamp)
        guard age <= 7 * 86_400 else {
            Log.net.error("Envelope dropped: outside the 7-day window")
            return .rejected
        }
        // Already stored — finished with it, so it can be acked.
        guard !store.hasSeenEnvelope(envelope.id) else { return .accepted }

        // 5. TOFU / key-change evaluation. Both refusals here are *transient*:
        //    the envelope stays on the relay instead of being destroyed.
        switch decideTrust(senderCert, for: sender) {
        case .ok:
            break
        case .keyChanged:
            // The contact reinstalled or changed device. Keep the mail queued
            // until the user accepts the new key on the banner; acking here
            // would lose it even after they accept. (Ceiling: the relay's
            // 7-day TTL.)
            Log.net.error("Envelope deferred: unacknowledged key change for the sender")
            return .retryLater
        case .unavailable:
            // Keychain unreadable — e.g. a background fetch before the first
            // unlock after reboot.
            Log.net.error("Envelope deferred: trust store unavailable")
            return .retryLater
        }

        // 6. Blocked senders are dropped before decryption and never get receipts.
        guard !store.isBlocked(sender) else {
            store.recordSeenEnvelope(envelope.id)
            return .rejected
        }

        // 7. Decrypt and decode.
        let payload: ChatPayload
        do {
            let plaintext = try crypto.open(envelope, senderCert: senderCert)
            guard let decoded = ChatPayload.decode(plaintext), decoded.isWellFormed else {
                Log.net.error("Envelope dropped: payload malformed")
                return .rejected
            }
            payload = decoded
        } catch {
            Log.crypto.error("Envelope dropped: decryption failed (\(String(describing: error), privacy: .public))")
            return .rejected
        }

        lastHeardFrom[sender] = now
        updatePresence()

        let outcome = await apply(payload, from: sender, envelopeID: envelope.id, viaLAN: viaLAN)
        // Mark seen only once we're actually done with it: a deferred envelope
        // must still be accepted when the relay redelivers it.
        if outcome != .retryLater {
            store.recordSeenEnvelope(envelope.id)
        }
        return outcome
    }

    private func apply(_ payload: ChatPayload,
                       from sender: String,
                       envelopeID: String,
                       viaLAN: Bool) async -> IngestOutcome {
        switch payload.kind {
        case .text, .image:
            return await receiveMessage(payload, from: sender, envelopeID: envelopeID,
                                        conversationID: ConversationStore.conversationID(peer: sender))

        case .groupText, .groupImage:
            guard let groupID = payload.groupID,
                  let group = store.group(id: groupID),
                  group.members.contains(sender) else {
                Log.net.error("Group message dropped: sender is not a member")
                return .rejected
            }
            return await receiveMessage(payload, from: sender, envelopeID: envelopeID,
                                        conversationID: ConversationStore.conversationID(group: groupID))

        case .deliveryReceipt:
            applyReceipt(payload, from: sender, status: .delivered)

        case .readReceipt:
            applyReceipt(payload, from: sender, status: .read)

        case .typing:
            // Typing is only believed over an authenticated LAN link.
            guard viaLAN else { return .rejected }
            let conversationID = payload.groupID.map(ConversationStore.conversationID(group:))
                ?? ConversationStore.conversationID(peer: sender)
            markTyping(conversationID)

        case .deleteForEveryone:
            for id in payload.refIDs ?? [] {
                let conversationID = payload.groupID.map(ConversationStore.conversationID(group:))
                    ?? ConversationStore.conversationID(peer: sender)
                _ = store.markDeletedForEveryone(messageID: id,
                                                 conversationID: conversationID,
                                                 requestedBy: sender)
            }

        case .profile:
            applyProfile(payload, from: sender)

        case .groupCreate, .groupUpdate, .groupLeave:
            applyGroupChange(payload, from: sender)

        case .numberChange:
            applyNumberChange(payload, from: sender)
        }
        return .accepted
    }

    private func receiveMessage(_ payload: ChatPayload,
                                from sender: String,
                                envelopeID: String,
                                conversationID: String) async -> IngestOutcome {
        ensureContactExists(sender)

        var imageFilename: String?
        var body = payload.text ?? ""
        let kind: MessageKind

        if payload.kind == .image || payload.kind == .groupImage {
            kind = .image
            guard let b64 = payload.imageJPEGBase64, let data = Data(base64Encoded: b64) else {
                Log.net.error("Image message dropped: payload is not decodable JPEG data")
                return .rejected
            }
            do {
                imageFilename = try store.saveImage(data, id: envelopeID)
            } catch {
                // Disk problem, not a bad message: keep it on the relay.
                Log.store.error("Could not save incoming image: \(String(describing: error), privacy: .public)")
                return .retryLater
            }
            body = ""
        } else {
            kind = .text
        }

        let message = StoredMessage(id: envelopeID,
                                    conversationID: conversationID,
                                    fromPhone: sender,
                                    toPhone: myPhone,
                                    kind: kind,
                                    body: body,
                                    imageFilename: imageFilename,
                                    timestamp: Date(timeIntervalSince1970: TimeInterval(payload.sentAt)),
                                    status: .delivered,
                                    isFromMe: false,
                                    isRead: false)

        // Persist first — never block receipt or storage on translation.
        // A duplicate id means we already have it: finished, safe to ack.
        guard store.appendMessage(message) else { return .accepted }

        // Notification.
        let title = store.contact(for: sender)?.name ?? sender
        let preview = kind == .image ? String(localized: "Photo") : body
        NotificationService.shared.postIncoming(conversationID: conversationID,
                                                title: title,
                                                body: preview)
        NotificationService.shared.setBadge(store.totalUnreadCount)

        // Delivery receipt, after the message is safely stored.
        await sendDeliveryReceipt(for: envelopeID, to: sender, groupID: payload.groupID)

        // Translation runs afterwards, with a 10 s ceiling.
        if kind == .text, !body.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                let translated = await self.translate(body)
                guard let translated, !translated.isEmpty else { return }
                self.store.setTranslation(messageID: envelopeID,
                                          conversationID: conversationID,
                                          text: translated)
            }
        }
        return .accepted
    }

    private func translate(_ body: String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await TranslationService.shared.autoTranslate(body: body) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func applyReceipt(_ payload: ChatPayload, from sender: String, status: MessageStatus) {
        let conversationID = payload.groupID.map(ConversationStore.conversationID(group:))
            ?? ConversationStore.conversationID(peer: sender)
        for id in payload.refIDs ?? [] {
            // `updateStatus` never downgrades.
            store.updateStatus(messageID: id, conversationID: conversationID, to: status)
        }
    }

    private func applyProfile(_ payload: ChatPayload, from sender: String) {
        let avatar = payload.avatarJPEGBase64.flatMap { Data(base64Encoded: $0) }
        store.setProfile(phone: sender, profileName: payload.displayName, avatarJPEG: avatar)

        // Keep the v1 rule: only auto-name a contact the user never named.
        if let announced = payload.displayName, !announced.isEmpty,
           let contact = store.contact(for: sender), contact.name == sender {
            store.renameContact(phone: sender, newName: announced)
        }
    }

    private func applyGroupChange(_ payload: ChatPayload, from sender: String) {
        guard let groupID = payload.groupID else { return }
        let existing = store.group(id: groupID)

        switch payload.kind {
        case .groupCreate:
            if existing == nil {
                guard let members = payload.groupMembers,
                      members.contains(myPhone),
                      (payload.groupAdmins ?? []).contains(sender) else { return }
                let group = ChatGroup(id: groupID,
                                      name: payload.groupName ?? "Group",
                                      members: Array(members.prefix(AppConfig.maxGroupMembers)),
                                      admins: payload.groupAdmins ?? [sender],
                                      createdAt: Date())
                store.upsertGroup(group)
                for member in group.members where member != myPhone {
                    ensureContactExists(member)
                }
            }

        case .groupUpdate:
            guard var group = existing, group.admins.contains(sender) else {
                Log.net.error("Group update dropped: sender is not an admin")
                return
            }
            if let name = payload.groupName { group.name = name }
            if let members = payload.groupMembers {
                group.members = Array(members.prefix(AppConfig.maxGroupMembers))
                group.isActive = members.contains(myPhone)
            }
            if let admins = payload.groupAdmins { group.admins = admins }
            store.upsertGroup(group)

        case .groupLeave:
            guard var group = existing, group.members.contains(sender) else { return }
            group.members.removeAll { $0 == sender }
            group.admins.removeAll { $0 == sender }
            store.upsertGroup(group)

        default:
            break
        }
    }

    private func applyNumberChange(_ payload: ChatPayload, from sender: String) {
        guard let newPhone = payload.newPhone,
              PhoneNumber.isValidE164(newPhone),
              let json = payload.newCertificate,
              let newCert = IdentityCertificate.decode(json),
              newCert.isValid(serverKeyBase64: server.serverKeyBase64, now: now),
              newCert.phone == newPhone else {
            Log.net.error("Number change dropped: new certificate invalid")
            return
        }
        // The new certificate must carry the same signing key we already pinned
        // for the old number — otherwise this is an impersonation attempt.
        guard let pinnedKey = trust.pinnedSigningKey(for: sender),
              pinnedKey == newCert.signingKey else {
            Log.crypto.error("Number change dropped: signing key does not match the pinned one")
            return
        }

        trust.migratePin(from: sender, to: newPhone)
        trust.updatePinnedCertificate(newCert)
        store.renameConversation(from: sender, to: newPhone)
        certificateRefreshedAt[newPhone] = now
        certificateRefreshedAt[sender] = nil
        Log.net.info("Contact migrated to a new number")
    }

    private func ensureContactExists(_ phone: String) {
        guard store.contact(for: phone) == nil, phone != myPhone else { return }
        store.addContact(Contact(phone: phone, name: phone, addedAt: Date()))
    }

    // MARK: - Receipts

    private func sendDeliveryReceipt(for messageID: String, to sender: String, groupID: String?) async {
        let payload = ChatPayload(kind: .deliveryReceipt, refIDs: [messageID], groupID: groupID)
        _ = await sendPayload(payload, to: sender, envelopeID: UUID().uuidString)
    }

    func markRead(conversationID: String) {
        let newlyRead = store.markConversationRead(conversationID)
        NotificationService.shared.setBadge(store.totalUnreadCount)
        NotificationService.shared.clearNotifications(for: conversationID)

        guard UserDefaults.standard.bool(forKey: AppConfig.Keys.sendReadReceipts),
              !newlyRead.isEmpty else { return }

        let groupID = ConversationStore.groupID(from: conversationID)
        let bySender = Dictionary(grouping: newlyRead, by: \.fromPhone)
        Task { [weak self] in
            guard let self else { return }
            for (sender, messages) in bySender where sender != self.myPhone {
                let payload = ChatPayload(kind: .readReceipt,
                                          refIDs: messages.map(\.id),
                                          groupID: groupID)
                _ = await self.sendPayload(payload, to: sender, envelopeID: UUID().uuidString)
            }
        }
    }

    // MARK: - Typing

    func userIsTyping(in conversationID: String) {
        guard UserDefaults.standard.bool(forKey: AppConfig.Keys.sendTypingIndicators),
              isRegistered else { return }

        // Throttle: at most one indicator every 3 s per conversation.
        if let last = lastTypingSentAt[conversationID], now.timeIntervalSince(last) < 3 { return }
        lastTypingSentAt[conversationID] = now

        let groupID = ConversationStore.groupID(from: conversationID)
        let payload = ChatPayload(kind: .typing, groupID: groupID)
        // LAN peers only — `sendPayload` refuses to relay a typing payload.
        let peers = recipients(for: conversationID).filter { phone in
            routing.peer(for: phone)?.isOnline() == true
        }
        guard !peers.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for peer in peers {
                _ = await self.sendPayload(payload, to: peer, envelopeID: UUID().uuidString)
            }
        }
    }

    private func markTyping(_ conversationID: String) {
        typingTimers[conversationID]?.cancel()
        typingPeers.insert(conversationID)
        typingTimers[conversationID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.typingPeers.remove(conversationID)
        }
    }

    // MARK: - Delete for everyone / retry

    func deleteForEveryone(messageID: String, conversationID: String) async {
        guard store.markDeletedForEveryone(messageID: messageID,
                                           conversationID: conversationID,
                                           requestedBy: myPhone) else { return }
        let payload = ChatPayload(kind: .deleteForEveryone,
                                  refIDs: [messageID],
                                  groupID: ConversationStore.groupID(from: conversationID))
        for recipient in recipients(for: conversationID) {
            _ = await sendPayload(payload, to: recipient, envelopeID: UUID().uuidString)
        }
    }

    func retry(messageID: String, conversationID: String) async {
        // `.failed → .pending` is the one allowed downgrade.
        store.updateStatus(messageID: messageID, conversationID: conversationID, to: .pending)
        await deliverStoredMessage(messageID: messageID, conversationID: conversationID)
    }

    private func retryLoop() async {
        while !Task.isCancelled && isRunning {
            await retryPending()
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    /// Retries pending outgoing messages with per-message backoff; anything
    /// older than 7 days is marked `.failed`.
    private func retryPending(for conversationID: String? = nil,
                              involving phone: String? = nil,
                              ignoringBackoff: Bool = false) async {
        guard isRegistered else { return }
        var pending = store.pendingOutgoing()
        if let conversationID {
            pending = pending.filter { $0.conversationID == conversationID }
        }
        if let phone {
            pending = pending.filter { recipients(for: $0.conversationID).contains(phone) }
        }
        guard !pending.isEmpty else { return }

        for message in pending {
            if now.timeIntervalSince(message.timestamp) > 7 * 86_400 {
                store.updateStatus(messageID: message.id,
                                   conversationID: message.conversationID,
                                   to: .failed)
                continue
            }
            // Backoff per message: 30 s, 1 m, 2 m … capped at 1 h.
            if !ignoringBackoff, let last = message.lastAttemptAt {
                let wait = min(3600, 30 * pow(2, Double(min(message.attempts, 8))))
                guard now.timeIntervalSince(last) >= wait else { continue }
            }
            await deliverStoredMessage(messageID: message.id,
                                       conversationID: message.conversationID)
        }
    }

    // MARK: - Groups (client-side fan-out)

    func createGroup(name: String, members: [String]) async throws -> ChatGroup {
        guard isRegistered else { throw ServiceError.notRegistered }
        var normalized = Set<String>()
        for raw in members {
            guard let phone = PhoneNumber.normalize(raw) else { throw ServiceError.invalidPhone }
            guard phone != myPhone else { continue }
            normalized.insert(phone)
        }
        let all = ([myPhone] + normalized.sorted())
        guard all.count <= AppConfig.maxGroupMembers else { throw ServiceError.tooManyMembers }

        let group = ChatGroup(id: UUID().uuidString,
                              name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              members: all,
                              admins: [myPhone],
                              createdAt: Date())
        store.upsertGroup(group)
        await broadcastGroup(group, kind: .groupCreate, to: normalized.sorted())
        return group
    }

    func renameGroup(_ groupID: String, name: String) async throws {
        var group = try requireAdminGroup(groupID)
        group.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.upsertGroup(group)
        await broadcastGroup(group, kind: .groupUpdate)
    }

    func addMembers(_ phones: [String], to groupID: String) async throws {
        var group = try requireAdminGroup(groupID)
        var members = Set(group.members)
        for raw in phones {
            guard let phone = PhoneNumber.normalize(raw) else { throw ServiceError.invalidPhone }
            members.insert(phone)
        }
        guard members.count <= AppConfig.maxGroupMembers else { throw ServiceError.tooManyMembers }
        let existingMembers = Set(group.members)
        group.members = members.sorted()
        store.upsertGroup(group)

        // Existing members get an update; newcomers get a create so they can
        // materialise the group locally.
        let newcomers = members.subtracting(existingMembers)
        await broadcastGroup(group, kind: .groupUpdate,
                             to: existingMembers.filter { $0 != myPhone }.sorted())
        await broadcastGroup(group, kind: .groupCreate, to: newcomers.sorted())
    }

    func removeMember(_ phone: String, from groupID: String) async throws {
        var group = try requireAdminGroup(groupID)
        guard let normalized = PhoneNumber.normalize(phone) else { throw ServiceError.invalidPhone }
        let removed = group.members.contains(normalized)
        group.members.removeAll { $0 == normalized }
        group.admins.removeAll { $0 == normalized }
        store.upsertGroup(group)
        await broadcastGroup(group, kind: .groupUpdate)
        if removed {
            // Tell the removed member too, so their copy goes inactive.
            var payload = groupPayload(group, kind: .groupUpdate)
            payload.groupMembers = group.members
            _ = await sendPayload(payload, to: normalized, envelopeID: UUID().uuidString)
        }
    }

    func leaveGroup(_ groupID: String) async {
        guard var group = store.group(id: groupID) else { return }
        let others = group.members.filter { $0 != myPhone }
        group.members.removeAll { $0 == myPhone }
        group.admins.removeAll { $0 == myPhone }
        group.isActive = false
        store.upsertGroup(group)

        let payload = ChatPayload(kind: .groupLeave, groupID: groupID)
        for member in others {
            _ = await sendPayload(payload, to: member, envelopeID: UUID().uuidString)
        }
    }

    private func requireAdminGroup(_ groupID: String) throws -> ChatGroup {
        guard isRegistered else { throw ServiceError.notRegistered }
        guard let group = store.group(id: groupID) else { throw ServiceError.unavailable }
        guard group.admins.contains(myPhone) else { throw ServiceError.unavailable }
        return group
    }

    private func groupPayload(_ group: ChatGroup, kind: ChatPayload.Kind) -> ChatPayload {
        ChatPayload(kind: kind,
                    groupID: group.id,
                    groupName: group.name,
                    groupMembers: group.members,
                    groupAdmins: group.admins)
    }

    private func broadcastGroup(_ group: ChatGroup,
                                kind: ChatPayload.Kind,
                                to explicit: [String]? = nil) async {
        let payload = groupPayload(group, kind: kind)
        let targets = (explicit ?? group.members).filter { $0 != myPhone }
        for member in Set(targets) {
            _ = await sendPayload(payload, to: member, envelopeID: UUID().uuidString)
        }
    }

    // MARK: - Profile

    func updateProfile(displayName: String, avatarJPEG: Data?) async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: AppConfig.Keys.displayName)

        if let avatarJPEG, avatarJPEG.count > ChatPayload.maxAvatarBytes {
            lastError = String(localized: "That profile photo is too large.")
            return
        }

        let payload = ChatPayload(kind: .profile,
                                  displayName: trimmed,
                                  avatarJPEGBase64: avatarJPEG?.base64EncodedString())
        for contact in store.contacts where !contact.isBlocked {
            if await sendPayload(payload, to: contact.phone, envelopeID: UUID().uuidString) {
                profileAnnouncedTo.insert(contact.phone)
            }
        }
    }

    /// Sends our profile to a contact the first time we talk to them.
    private func announceProfileIfNeeded(to phone: String) async {
        guard !profileAnnouncedTo.contains(phone) else { return }
        let name = UserDefaults.standard.string(forKey: AppConfig.Keys.displayName) ?? ""
        guard !name.isEmpty else { return }
        profileAnnouncedTo.insert(phone)
        let payload = ChatPayload(kind: .profile, displayName: name)
        _ = await sendPayload(payload, to: phone, envelopeID: UUID().uuidString)
    }

    // MARK: - Block / report / delete account

    func block(phone: String) {
        store.setBlocked(phone, true)
        routing.remove(phone: phone)
        updatePresence()
    }

    func unblock(phone: String) {
        store.setBlocked(phone, false)
    }

    func report(phone: String, reason: String, includeRecentMessages: Bool) async throws {
        guard isRegistered else { throw ServiceError.notRegistered }
        var evidence: [(id: String, timestamp: Int64, text: String)] = []
        if includeRecentMessages {
            evidence = store.recentMessages(with: phone, limit: 20)
                .filter { $0.kind == .text && !$0.isDeleted }
                .map { (id: $0.id,
                        timestamp: Int64($0.timestamp.timeIntervalSince1970),
                        text: $0.body) }
        }
        do {
            try await server.report(reportedPhone: phone, reason: reason, evidence: evidence)
        } catch let error as ServerError {
            throw map(error)
        }
    }

    func deleteAccountAndWipe() async throws {
        // Best effort, but the caller is told when the server could not be
        // reached so they can decide whether to wipe locally anyway.
        do {
            try await server.deleteAccount()
        } catch let error as ServerError {
            Log.net.error("Server-side account deletion failed: \(String(describing: error), privacy: .public)")
            throw map(error)
        }

        wipeLocalState()
    }

    /// Local half of account deletion — also used after a server-side delete
    /// the user chose to force through.
    func wipeLocalState() {
        stop()
        try? crypto.wipeAll()
        trust.wipe()
        store.wipeAll()
        let defaults = UserDefaults.standard
        for key in AppConfig.allUserDefaultsKeys { defaults.removeObject(forKey: key) }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("hopchat.") {
            defaults.removeObject(forKey: key)
        }
        replayCache.removeAll()
        certificateRefreshedAt.removeAll()
        lastHeardFrom.removeAll()
        profileAnnouncedTo.removeAll()
        myPhone = ""
        isRegistered = false
        legacyPhoneHint = nil
        NotificationService.shared.clearBadge()
    }

    // MARK: - Certificate maintenance (contract §15)

    private func maintenanceLoop() async {
        while !Task.isCancelled && isRunning {
            await renewCertificateIfPossible()
            try? await Task.sleep(nanoseconds: 24 * 3600 * 1_000_000_000)
        }
    }

    private func renewCertificateIfPossible(force: Bool = false) async {
        guard let certificate = crypto.certificate else { return }
        let needsRotation = crypto.needsAgreementRotation
        guard force || certificate.expiresSoon || needsRotation else { return }

        do {
            let agreementKey = needsRotation
                ? try crypto.prepareAgreementRotationOrThrow()
                : try crypto.publicKeys().agreement
            let renewed = try await server.renewCertificate(agreementKey: agreementKey)
            guard renewed.isValid(serverKeyBase64: server.serverKeyBase64, now: now),
                  renewed.phone == certificate.phone,
                  renewed.signingKey == certificate.signingKey else {
                Log.crypto.error("Renewed certificate failed validation — keeping the old one")
                return
            }
            if needsRotation {
                try crypto.commitAgreementRotation(certificate: renewed)
            } else {
                try crypto.setCertificate(renewed)
            }
            Log.crypto.info("Certificate renewed (rotated agreement key: \(needsRotation, privacy: .public))")
        } catch {
            Log.crypto.error("Certificate renewal failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - LAN

    private func startLAN() {
        guard enableLAN, lanNode == nil else { return }

        let node = LANNode()
        let serverKey = server.serverKeyBase64
        let cache = replayCache

        node.onRequest = { [weak self] message, sourceIP in
            // Verification happens off the main actor.
            guard let cert = KademliaService.verifyInbound(message,
                                                           serverKeyBase64: serverKey,
                                                           replay: cache) else { return nil }
            guard let self else { return nil }
            return await self.handleVerifiedLAN(message, certificate: cert, sourceIP: sourceIP)
        }

        node.onReady = { [weak self] port in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lanPort = port
                self.bonjour?.publish(port: port)
            }
        }

        node.onFailure = { _ in
            Task { @MainActor [weak self] in self?.lanPort = 0 }
        }

        do {
            try node.start()
            lanNode = node
        } catch {
            Log.net.error("LAN listener could not start: \(String(describing: error), privacy: .public)")
            lanNode = nil
            return
        }

        let discovery = BonjourDiscovery()
        discovery.onPeerFound = { [weak self] advertisement in
            Task { @MainActor [weak self] in
                await self?.sayHello(to: advertisement)
            }
        }
        discovery.startBrowsing()
        bonjour = discovery
        lastLocalIP = localWiFiIP()
    }

    private func stopLAN() {
        bonjour?.stop()
        bonjour = nil
        lanNode?.stop()
        lanNode = nil
        lanPort = 0
    }

    /// Stateless, off-main verification of an inbound wire message.
    /// Returns the sender's certificate when everything checks out.
    nonisolated private static func verifyInbound(_ message: WireMessage,
                                                  serverKeyBase64: String,
                                                  replay: ReplayCache) -> IdentityCertificate? {
        guard message.v == 2, message.wireType != nil else { return nil }
        guard message.isFresh() else {
            Log.net.debug("LAN message dropped: stale")
            return nil
        }
        guard replay.record(message.txID) else {
            Log.net.debug("LAN message dropped: replay")
            return nil
        }
        guard let json = message.certificate,
              let certificate = IdentityCertificate.decode(json),
              certificate.isValid(serverKeyBase64: serverKeyBase64),
              certificate.phone == message.senderPhone else {
            Log.net.debug("LAN message dropped: certificate invalid")
            return nil
        }
        guard message.hasValidSignature(signingKeyBase64: certificate.signingKey) else {
            Log.net.debug("LAN message dropped: bad signature")
            return nil
        }
        return certificate
    }

    /// Handles an inbound LAN request whose signature and certificate already
    /// verified. `sourceIP` is the TCP source address — the only address we
    /// record; `senderPort` is trusted only because it is inside the signature.
    private func handleVerifiedLAN(_ message: WireMessage,
                                   certificate: IdentityCertificate,
                                   sourceIP: String) async -> WireMessage? {
        let sender = certificate.phone
        guard sender != myPhone else { return nil }
        guard !store.isBlocked(sender) else { return nil }

        // TOFU / key change before anything else is believed.
        guard applyTrust(certificate, for: sender) != nil else { return nil }

        switch message.wireType {
        case .hello:
            recordLANPeer(phone: sender,
                          ip: sourceIP,
                          port: message.senderPort,
                          certificateJSON: certificate.encodedJSON())
            return signedHello()

        case .ping:
            touchPeer(sender)
            return sign(WireMessage(type: .pong,
                                    txID: message.txID,
                                    senderPhone: myPhone,
                                    senderPort: lanPort,
                                    certificate: crypto.certificate?.encodedJSON()))

        case .directEnvelope:
            guard let envelope = message.envelope,
                  envelope.senderPhone == sender,
                  message.recipientPhone == myPhone else { return nil }
            touchPeer(sender)
            let outcome = await processIncoming(envelope, viaLAN: true)
            // No ack on a transient failure — the peer must keep it and retry
            // rather than consider it delivered.
            guard outcome != .retryLater else { return nil }
            return sign(WireMessage(type: .directAck,
                                    txID: message.txID,
                                    senderPhone: myPhone,
                                    senderPort: lanPort,
                                    certificate: crypto.certificate?.encodedJSON(),
                                    key: envelope.id))

        default:
            // Every removed v1 verb (store, findValue, holePunch, relay,
            // offlineNotify, cameOnline, peerOnline, connectRequest) lands here.
            Log.net.debug("Unsupported LAN message type \(message.type, privacy: .public)")
            return nil
        }
    }

    private func sign(_ message: WireMessage) -> WireMessage {
        var message = message
        message.signature = crypto.sign(message.signedFields)
        return message
    }

    private func signedHello(txID: String = UUID().uuidString) -> WireMessage {
        sign(WireMessage(type: .hello,
                         txID: txID,
                         senderPhone: myPhone,
                         senderPort: lanPort,
                         certificate: crypto.certificate?.encodedJSON()))
    }

    /// Bonjour told us *something* is there. Identity comes from the signed
    /// hello reply, never from the advertisement.
    private func sayHello(to advertisement: BonjourDiscovery.Advertisement) async {
        guard isRegistered, let node = lanNode else { return }
        let hello = signedHello()
        guard let response = await node.send(hello, to: advertisement.endpoint, timeout: 5) else { return }

        let reply = response.message
        guard let certificate = KademliaService.verifyInbound(reply,
                                                              serverKeyBase64: server.serverKeyBase64,
                                                              replay: replayCache),
              reply.wireType == .hello,
              certificate.phone != myPhone else { return }

        guard !store.isBlocked(certificate.phone) else { return }
        guard applyTrust(certificate, for: certificate.phone) != nil else { return }
        guard let ip = response.remoteIP else { return }

        recordLANPeer(phone: certificate.phone,
                      ip: ip,
                      port: reply.senderPort,
                      certificateJSON: certificate.encodedJSON())

        // A peer just became reachable — flush anything queued for them.
        await retryPending(for: ConversationStore.conversationID(peer: certificate.phone))
    }

    /// Routing entries exist only for peers that completed an authenticated
    /// hello (contract issue 1).
    private func recordLANPeer(phone: String, ip: String, port: UInt16, certificateJSON: String) {
        guard port != 0, !ip.isEmpty, phone != myPhone else { return }
        let peer = LANPeer(phone: phone, ip: ip, port: port,
                           certificateJSON: certificateJSON, lastSeen: Date())
        routing.add(peer)
        store.updateLAN(phone: phone, ip: ip, port: port)
        lastHeardFrom[phone] = now
        updatePresence()
        Log.net.debug("Authenticated LAN peer recorded at \(ip, privacy: .private)")
    }

    private func touchPeer(_ phone: String) {
        guard let peer = routing.peer(for: phone) else { return }
        routing.add(LANPeer(phone: peer.phone, ip: peer.ip, port: peer.port,
                            certificateJSON: peer.certificateJSON, lastSeen: Date()))
        lastHeardFrom[phone] = now
        updatePresence()
    }

    /// Checks that a LAN reply really came from the peer we addressed.
    private func isAuthenticLANReply(_ reply: WireMessage, from phone: String, txID: String) -> Bool {
        guard reply.txID == txID,
              let certificate = KademliaService.verifyInbound(reply,
                                                              serverKeyBase64: server.serverKeyBase64,
                                                              replay: replayCache),
              certificate.phone == phone else { return false }
        return true
    }

    // MARK: - Presence (contract §17 — nothing is reported to the server)

    private func updatePresence() {
        var map: [String: PresenceStatus] = [:]
        for contact in store.contacts {
            map[contact.phone] = presence(for: contact.phone)
        }
        for peer in routing.allPeers where map[peer.phone] == nil {
            map[peer.phone] = presence(for: peer.phone)
        }
        presenceMap = map
    }

    private func presence(for phone: String) -> PresenceStatus {
        if let peer = routing.peer(for: phone), peer.isOnline() { return .online }
        if let heard = lastHeardFrom[phone] ?? store.lastMessage(ConversationStore.conversationID(peer: phone))
            .flatMap({ $0.isFromMe ? nil : $0.timestamp }) {
            if now.timeIntervalSince(heard) < 3600 { return .recently }
        }
        return .offline
    }

    // MARK: - Network path monitoring (contract §7 — debounced, no storms)

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.schedulePathChange(satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    /// v1 tore the whole node down on every path callback. Now: 2 s debounce,
    /// the LAN listener restarts only when the interface/IP actually changed,
    /// and the relay loop simply retries with its own backoff.
    private func schedulePathChange(satisfied: Bool) {
        pathDebounce?.cancel()
        pathDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            await self.applyPathChange(satisfied: satisfied)
        }
    }

    private func applyPathChange(satisfied: Bool) async {
        guard satisfied else {
            connectionState = .offline
            return
        }

        let currentIP = localWiFiIP()
        if currentIP != lastLocalIP {
            Log.net.info("Local interface changed — restarting the LAN listener")
            lastLocalIP = currentIP
            stopLAN()
            routing.removeAll()
            startLAN()
        }

        relayBackoff.reset()
        await retryPending()
    }

    // MARK: - Helpers

    /// The phones a conversation is addressed to (excluding us).
    private func recipients(for conversationID: String) -> [String] {
        if let groupID = ConversationStore.groupID(from: conversationID) {
            guard let group = store.group(id: groupID) else { return [] }
            return group.members.filter { $0 != myPhone }
        }
        return conversationID == myPhone ? [] : [conversationID]
    }

    /// `toPhone` for an outgoing message: the peer's phone, or the group
    /// conversation ID for a fan-out message.
    private func recipientLabel(for conversationID: String) -> String {
        conversationID
    }

    private func map(_ error: ServerError) -> ServiceError {
        switch error {
        case .server(let code, let message):
            switch code {
            case "not_registered", "recipient_not_registered": return .notOnHopChat
            case "invalid_phone": return .invalidPhone
            case "blocked": return .blocked
            case "cert_invalid": return .notRegistered
            default: return .server(message.isEmpty ? code : message)
            }
        case .timeout, .transport:
            return .unavailable
        case .badServerSignature:
            return .server(String(localized: "The server's response could not be verified."))
        case .badResponse:
            return .server(String(localized: "Unexpected response from the server."))
        }
    }
}
