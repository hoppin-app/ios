//
//  ClockSkewTests.swift
//  HopChat-1Tests
//
//  App Review signed in on an iPad whose clock was 16 days ahead. The relay
//  refused the request as stale, and the app then refused the relay's signed
//  refusal for being "stale" by the iPad's clock: "unexpected reply", and no
//  way in. The app now runs on relay time (`ServerClock`).
//
//  These move the process-wide device clock, so every test restores it, and
//  the suites are serialized (scripts/run_tests.sh also disables parallel
//  testing).
//

import Testing
import Foundation
@testable import HopChat_1

private let sixteenDays: TimeInterval = 16 * 86_400

@Suite("Relay time", .serialized)
struct ServerClockTests {

    @Test("a second or two of difference is ignored, a real offset is kept")
    func learnsOnlyRealOffsets() {
        let device = Date(timeIntervalSince1970: 1_790_000_000)
        ServerClock.setDeviceClockForTesting { device }
        defer { ServerClock.setDeviceClockForTesting(nil) }

        ServerClock.learn(serverTimestamp: 1_790_000_002)
        #expect(ServerClock.offset == 0)
        #expect(ServerClock.now() == device)

        ServerClock.learn(serverTimestamp: 1_790_000_000 - Int64(sixteenDays))
        #expect(ServerClock.offset == -sixteenDays)
        #expect(ServerClock.now() == device.addingTimeInterval(-sixteenDays))
    }

    @Test("wire messages are stamped and judged in relay time")
    func wireMessagesUseRelayTime() {
        let device = Date(timeIntervalSince1970: 1_790_000_000 + sixteenDays)
        ServerClock.setDeviceClockForTesting { device }
        defer { ServerClock.setDeviceClockForTesting(nil) }
        ServerClock.learn(serverTimestamp: 1_790_000_000)

        let message = WireMessage(type: .ping, senderPhone: "+351912345678")
        #expect(message.timestamp == 1_790_000_000)
        #expect(message.isFresh())
    }
}

@MainActor
@Suite("Integration — a device clock that is wrong", .serialized)
struct ClockSkewIntegrationTests {

    @Test("a phone 16 days fast can still sign in")
    func signInWithFastClock() async throws {
        guard let world = try World.make() else { return }
        ServerClock.setDeviceClockForTesting { Date().addingTimeInterval(sixteenDays) }
        defer { ServerClock.setDeviceClockForTesting(nil) }

        // A number used only here, so the shared roles keep their rate budget.
        let phone = "+351913160016"
        let harness = ServiceHarness.connected(info: world.info)
        defer { harness.stop() }

        _ = try await harness.service.requestVerificationCode(phone: phone)
        try await harness.service.confirmVerification(phone: phone, code: world.info.fixedCode)

        let cert = try #require(harness.crypto.certificate)
        #expect(cert.phone == phone)
        #expect(harness.service.isRegistered)
        // Judged in relay time, the fresh certificate is valid.
        #expect(cert.isValid(serverKeyBase64: world.info.serverKey))
        #expect(abs(ServerClock.offset + sixteenDays) < 60)
    }

    @Test("a registered phone 16 days slow still reaches the relay")
    func requestsWithSlowClock() async throws {
        guard let world = try World.make() else { return }
        let harness = try await world.party("alice", phone: alicePhone)
        defer { harness.stop() }

        ServerClock.setDeviceClockForTesting { Date().addingTimeInterval(-sixteenDays) }
        defer { ServerClock.setDeviceClockForTesting(nil) }

        let client = world.client(for: harness.crypto)
        #expect(try await client.ping())
        #expect(abs(ServerClock.offset - sixteenDays) < 60)
        // Once learned, the next request goes through on the first try.
        _ = try await client.lookupCertificate(phone: alicePhone)
    }
}
