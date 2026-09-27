//
//  TransportFailureTests.swift
//  HopChat-1Tests
//
//  "No connection to hoppin" used to cover everything that can go wrong
//  before a reply: no network, a server that's down, a certificate that
//  matches no pin, a build with no server at all. On 25/09/2026 a phone that
//  could reach the relay fine said exactly that for an afternoon. Each cause
//  now carries its own name up to the screen.
//

import Testing
import Foundation
import Network
@testable import HopChat_1

@Suite("Transport — why a request failed")
struct TransportFailureTests {

    @Test("network errors are classified by what the user can do about them")
    func classification() {
        #expect(Transport.Failure.classify(.tls(errSSLBadCert)) == .untrusted)
        #expect(Transport.Failure.classify(.posix(.ECONNREFUSED)) == .refused)
        #expect(Transport.Failure.classify(.posix(.ENETDOWN)) == .offline)
        #expect(Transport.Failure.classify(.posix(.ENETUNREACH)) == .offline)
        #expect(Transport.Failure.classify(.posix(.ETIMEDOUT)) == .unreachable)
        #expect(Transport.Failure.classify(.posix(.EHOSTUNREACH)) == .unreachable)
    }

    @Test("each transport failure becomes a distinct server error")
    func serverErrorMapping() {
        #expect(ServerError(.offline) == .offline)
        #expect(ServerError(.refused) == .refused)
        #expect(ServerError(.untrusted) == .untrustedServer)
        #expect(ServerError(.badRequest) == .notConfigured)
        #expect(ServerError(.unreachable) == .timeout)
        #expect(ServerError(.noReply) == .timeout)
    }

    @Test("port 0 is a configuration problem, not a timeout")
    func portZero() async {
        let message = WireMessage(type: .ping, senderPhone: "+351912345678")
        let result = await Transport.requestResult(message, to: "127.0.0.1", port: 0, tls: false)
        #expect(result == .failure(.badRequest))
    }

    @Test("a closed port reports the server as down")
    func closedPort() async {
        let message = WireMessage(type: .ping, senderPhone: "+351912345678")
        let result = await Transport.requestResult(message, to: "127.0.0.1",
                                                   port: ServiceHarness.deadPort, tls: false,
                                                   timeout: 4, connectTimeout: 2)
        #expect(result == .failure(.refused))
    }

    @Test("the screen names the cause")
    func copyIsDistinct() {
        let texts = [ServerError.offline, .refused, .untrustedServer, .notConfigured, .timeout]
            .map(VerificationErrorText.text(for:))
        #expect(Set(texts).count == texts.count)
        #expect(texts[1].contains("isn't answering"))
    }
}

extension Result where Success == WireMessage, Failure == Transport.Failure {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.failure(let a), .failure(let b)): return a == b
        case (.success(let a), .success(let b)): return a.txID == b.txID
        default: return false
        }
    }
}
