//
//  ServiceHarness.swift
//  HopChat-1Tests
//
//  Builds `KademliaService` instances for tests.
//
//  `offline(...)` produces a *registered* service that never reaches a server:
//  it is pointed at a closed loopback port, so every outbound request fails
//  immediately. That is enough to drive `processIncoming` — the whole inbound
//  validation pipeline — without a network.
//
//  `connected(...)` points a service at the real development bootstrap server
//  described by `/tmp/hopchat-test-server.json`.
//

import Foundation
import CryptoKit
@testable import HopChat_1

/// A service plus everything injected into it, kept alive for the test's
/// lifetime (the temp directory is deleted when this is released).
@MainActor
final class ServiceHarness {

    let service: KademliaService
    let crypto: CryptoManager
    let trust: TrustStore
    let store: ConversationStore
    let phone: String
    let secureStore: KeyValueSecureStore
    let trustBacking: KeyValueSecureStore
    private let temp: TempDirectory

    private(set) var certificate: IdentityCertificate?

    init(service: KademliaService,
         crypto: CryptoManager,
         trust: TrustStore,
         store: ConversationStore,
         phone: String,
         secureStore: KeyValueSecureStore,
         trustBacking: KeyValueSecureStore,
         temp: TempDirectory,
         certificate: IdentityCertificate?) {
        self.service = service
        self.crypto = crypto
        self.trust = trust
        self.store = store
        self.phone = phone
        self.secureStore = secureStore
        self.trustBacking = trustBacking
        self.temp = temp
        self.certificate = certificate
    }

    func setCertificate(_ cert: IdentityCertificate) { certificate = cert }

    func stop() { service.stop() }

    // MARK: - Offline (no server)

    /// A port nothing listens on, so outbound requests fail fast with
    /// "connection refused" rather than timing out.
    static let deadPort: UInt16 = 9

    /// A registered service wired to a certificate signed by `serverKey`.
    ///
    /// `KademliaService.myPhone` is `private(set)`, so registration is driven
    /// the way the app does it: `start()` adopts the stored certificate. The
    /// background loops are then stopped, leaving a quiet, registered service.
    static func offline(phone: String,
                        serverKey: Curve25519.Signing.PrivateKey,
                        now: Date = Date(),
                        trustBacking: KeyValueSecureStore = InMemorySecureStore(),
                        secureStore: KeyValueSecureStore = InMemorySecureStore())
    async throws -> ServiceHarness {
        let serverKeyB64 = serverKey.publicKey.rawRepresentation.base64EncodedString()
        let temp = TempDirectory("hopchat-service")

        let (crypto, certificate) = try IdentityFactory.makeLocal(phone: phone,
                                                                  serverKey: serverKey,
                                                                  now: now,
                                                                  store: secureStore)
        let trust = TrustStore(store: trustBacking)
        trust.now = { now }
        let store = ConversationStore(directory: temp.url,
                                      legacyDefaults: nil,
                                      debounce: .milliseconds(1),
                                      now: { now })

        let service = KademliaService(
            crypto: crypto,
            trust: trust,
            store: store,
            serverFactory: { crypto in
                ServerClient(crypto: crypto,
                             host: "127.0.0.1",
                             port: deadPort,
                             useTLS: false,
                             pins: [],
                             serverKeyBase64: serverKeyB64)
            },
            enableLAN: false)
        service.clock = { now }

        await service.start()
        service.stop()                     // registered, but no loops running

        return ServiceHarness(service: service, crypto: crypto, trust: trust,
                              store: store, phone: phone, secureStore: secureStore,
                              trustBacking: trustBacking, temp: temp,
                              certificate: certificate)
    }

    // MARK: - Connected (real development server)

    /// A service pointed at the development bootstrap server. It is *not*
    /// registered yet — call `register(code:)`.
    static func connected(info: ServerInfo,
                          trustBacking: KeyValueSecureStore = InMemorySecureStore(),
                          secureStore: KeyValueSecureStore = InMemorySecureStore(),
                          enableLAN: Bool = false) -> ServiceHarness {
        let temp = TempDirectory("hopchat-service")
        let crypto = CryptoManager(store: secureStore)
        let trust = TrustStore(store: trustBacking)
        let store = ConversationStore(directory: temp.url,
                                      legacyDefaults: nil,
                                      debounce: .milliseconds(1))

        let service = KademliaService(
            crypto: crypto,
            trust: trust,
            store: store,
            serverFactory: { crypto in
                ServerClient(crypto: crypto,
                             host: info.host,
                             port: info.port,
                             useTLS: false,
                             pins: [],
                             serverKeyBase64: info.serverKey)
            },
            enableLAN: enableLAN)

        return ServiceHarness(service: service, crypto: crypto, trust: trust,
                              store: store, phone: "", secureStore: secureStore,
                              trustBacking: trustBacking, temp: temp,
                              certificate: nil)
    }
}

// MARK: - Envelope construction for inbound tests

@MainActor
enum EnvelopeFactory {

    /// Seals a payload from `sender` to `recipient` exactly as the app would.
    static func seal(_ payload: ChatPayload,
                     from sender: ServiceHarness,
                     to recipient: ServiceHarness,
                     id: String = UUID().uuidString,
                     timestamp: Date = Date())
    throws -> Envelope {
        let recipientCert = try requireCertificate(recipient)
        return try sender.crypto.seal(try payload.encoded(),
                                      envelopeID: id,
                                      recipientPhone: recipient.phone,
                                      recipientCert: recipientCert,
                                      timestamp: Int64(timestamp.timeIntervalSince1970))
    }

    /// A text message, the common case.
    static func text(_ body: String,
                     from sender: ServiceHarness,
                     to recipient: ServiceHarness,
                     id: String = UUID().uuidString,
                     timestamp: Date = Date())
    throws -> Envelope {
        try seal(ChatPayload(kind: .text, text: body,
                             sentAt: Int64(timestamp.timeIntervalSince1970)),
                 from: sender, to: recipient, id: id, timestamp: timestamp)
    }

    /// Rebuilds an envelope with one field replaced, for tamper tests.
    static func mutate(_ envelope: Envelope,
                       id: String? = nil,
                       senderPhone: String? = nil,
                       recipientPhone: String? = nil,
                       timestamp: Int64? = nil,
                       senderAgreementKey: String? = nil,
                       recipientAgreementKey: String? = nil,
                       ephemeralKey: String? = nil,
                       ciphertext: String? = nil,
                       senderCertificate: String? = nil,
                       signature: String? = nil) -> Envelope {
        Envelope(id: id ?? envelope.id,
                 senderPhone: senderPhone ?? envelope.senderPhone,
                 recipientPhone: recipientPhone ?? envelope.recipientPhone,
                 timestamp: timestamp ?? envelope.timestamp,
                 senderAgreementKey: senderAgreementKey ?? envelope.senderAgreementKey,
                 recipientAgreementKey: recipientAgreementKey ?? envelope.recipientAgreementKey,
                 ephemeralKey: ephemeralKey ?? envelope.ephemeralKey,
                 ciphertext: ciphertext ?? envelope.ciphertext,
                 senderCertificate: senderCertificate ?? envelope.senderCertificate,
                 signature: signature ?? envelope.signature)
    }

    static func requireCertificate(_ harness: ServiceHarness) throws -> IdentityCertificate {
        guard let cert = harness.certificate ?? harness.crypto.certificate else {
            throw CryptoError.noCertificate
        }
        return cert
    }
}
