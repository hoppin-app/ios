//
//  ReverificationTests.swift
//  HopChat-1Tests
//
//  A certificate the pinned relay key does not vouch for is a dead one.
//
//  The regression: the relay's identity key was rotated on 25/09/2026 and every
//  certificate it had issued stopped being accepted. The phones kept their old
//  certificates, looked registered, and retried the relay forever while the
//  app said "Offline". Nothing crossed the relay for two days; only LAN and
//  Bluetooth still worked, which read as "mobile data is broken".
//
//  The app now notices on launch and asks for the number to be verified again,
//  keeping the identity keys so contacts see no key change.
//

import Testing
import Foundation
import CryptoKit
@testable import HopChat_1

@MainActor
struct ReverificationTests {

    private let phone = "+351912345678"

    /// A service that trusts `pinned`, holding a certificate signed by `issuer`.
    private func service(pinned: Curve25519.Signing.PrivateKey,
                         issuer: Curve25519.Signing.PrivateKey,
                         temp: TempDirectory) throws -> (KademliaService, CryptoManager) {
        let (crypto, _) = try IdentityFactory.makeLocal(phone: phone, serverKey: issuer)
        let pinnedB64 = pinned.publicKey.rawRepresentation.base64EncodedString()
        let service = KademliaService(
            crypto: crypto,
            trust: TrustStore(store: InMemorySecureStore()),
            store: ConversationStore(directory: temp.url, legacyDefaults: nil,
                                     debounce: .milliseconds(1)),
            serverFactory: { crypto in
                ServerClient(crypto: crypto, host: "127.0.0.1",
                             port: ServiceHarness.deadPort, useTLS: false,
                             pins: [], serverKeyBase64: pinnedB64)
            },
            enableLAN: false)
        return (service, crypto)
    }

    @Test("A certificate from a rotated relay key sends the user back to verification")
    func rotatedKeyAsksToVerifyAgain() async throws {
        let temp = TempDirectory("hoppin-reverify")
        let retired = Curve25519.Signing.PrivateKey()
        let current = Curve25519.Signing.PrivateKey()
        let (service, crypto) = try service(pinned: current, issuer: retired, temp: temp)
        let keysBefore = try crypto.publicKeys()

        await service.start()
        defer { service.stop() }

        #expect(service.isRegistered == false)
        #expect(service.reverifyPhone == phone)
        #expect(service.connectionState == .offline)
        // Verifying again must reuse these keys, or every contact would see a
        // key change and have to accept it.
        let keysAfter = try crypto.publicKeys()
        #expect(keysAfter.signing == keysBefore.signing)
        #expect(keysAfter.agreement == keysBefore.agreement)
    }

    @Test("A certificate from the pinned key starts normally")
    func currentKeyStaysRegistered() async throws {
        let temp = TempDirectory("hoppin-reverify")
        let key = Curve25519.Signing.PrivateKey()
        let (service, _) = try service(pinned: key, issuer: key, temp: temp)

        await service.start()
        defer { service.stop() }

        #expect(service.isRegistered)
        #expect(service.reverifyPhone == nil)
        #expect(service.myPhone == phone)
    }
}
