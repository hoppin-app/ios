//
//  SuspensionTests.swift
//  HopChat-1Tests
//
//  The relay answers `suspended` for a number the operator banned after a
//  report. Nothing on the phone can fix that, so the app has to say so plainly
//  rather than "try again".
//

import Testing
@testable import HopChat_1

@Suite("Suspended numbers")
struct SuspensionTests {

    @Test("sign-in names the suspension, whichever error type carries it")
    func signInCopy() {
        let expected = ServiceError.suspended.errorDescription
        #expect(expected?.contains("suspended") == true)
        #expect(VerificationErrorText.text(for: ServiceError.suspended) == expected)
        #expect(VerificationErrorText.text(
            for: ServerError.server(code: "suspended",
                                    message: "this number has been suspended")) == expected)
    }

    @Test("it isn't mistaken for the relay being unreachable")
    func notUnreachable() {
        #expect(!ServiceError.suspended.isUnreachable)
    }
}
