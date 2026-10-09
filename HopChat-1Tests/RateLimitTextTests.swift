//
//  RateLimitTextTests.swift
//  HopChat-1Tests
//
//  The relay refuses extra verification codes with `rate_limited` and a
//  lowercase developer message. Sign-in used to show that message as is.
//

import Testing
@testable import HopChat_1

@Suite("Rate-limited sign-in")
struct RateLimitTextTests {

    private func text(_ message: String) -> String {
        VerificationErrorText.text(for: ServerError.server(code: "rate_limited", message: message))
    }

    @Test("too many codes for a number or an address says to wait up to an hour")
    func tooManyCodes() {
        for message in ["too many codes requested for this number",
                        "too many codes requested from this address"] {
            let shown = text(message)
            #expect(shown != message)
            #expect(shown.contains("hour"))
        }
    }

    @Test("the wrong-code lock doesn't promise an hour")
    func wrongCodeLock() {
        let shown = text("too many attempts for this number")
        #expect(shown.contains("wrong codes"))
        #expect(!shown.contains("hour"))
    }

    @Test("any other rate limit still reads as a sentence")
    func otherLimits() {
        #expect(text("too many requests").hasPrefix("Too many attempts"))
    }
}
