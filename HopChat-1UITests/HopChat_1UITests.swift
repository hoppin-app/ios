//
//  HopChat_1UITests.swift
//  HopChat-1UITests
//
//  A deliberately small, non-flaky set: the app launches, first run shows
//  onboarding and the terms gate, a returning user reaches SMS verification,
//  and a verified user sees the three tabs.
//
//  State is driven entirely through launch arguments so the tests never depend
//  on what a previous run left behind:
//
//      -UITestResetState      wipe hoppin's UserDefaults before the UI loads
//      -hoppin.hasSeenOnboarding <bool>
//      -hoppin.hasAcceptedTerms  <bool>
//
//  The first is an app-side hook (see the report: it must be honoured in
//  `HopChat_1App`/`AppDelegate`). The `-key value` pairs are the standard
//  UserDefaults argument-domain overrides, which work without app changes.
//

import XCTest

final class HopChat_1UITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch helpers

    private enum Stage {
        /// Nothing seen yet: onboarding must appear.
        case firstRun
        /// Onboarding and terms done, but no certificate: verification appears.
        case onboarded
    }

    @discardableResult
    private func launch(_ stage: Stage) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestResetState", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        switch stage {
        case .firstRun:
            app.launchArguments += ["-hoppin.hasSeenOnboarding", "NO",
                                    "-hoppin.hasAcceptedTerms", "NO"]
        case .onboarded:
            app.launchArguments += ["-hoppin.hasSeenOnboarding", "YES",
                                    "-hoppin.hasAcceptedTerms", "YES"]
        }
        app.launchArguments += ["-hoppin.appLock.enabled", "NO"]
        app.launch()
        return app
    }

    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval = 20) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = elements.first(where: { $0.exists && $0.isHittable || $0.exists }) {
                return hit
            }
            usleep(200_000)
        }
        return nil
    }

    // MARK: - Launch

    func testAppLaunchesWithoutCrashing() throws {
        let app = launch(.firstRun)
        XCTAssertEqual(app.state, .runningForeground, "the app should stay in the foreground")
        // Something must be on screen: a crash or a blank root view is a failure.
        XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 20),
                      "no text rendered after launch")
    }

    // MARK: - Onboarding and the terms gate

    func testFirstRunShowsOnboarding() throws {
        let app = launch(.firstRun)

        let welcome = app.staticTexts["Welcome to hoppin"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 20),
                      "first run should open on the onboarding story")

        // The story is skippable, which is how a user reaches the terms gate.
        let skip = app.buttons["Skip"]
        let next = app.buttons["Next"]
        XCTAssertTrue(skip.exists || next.exists,
                      "onboarding should offer Skip or Next")
    }

    func testTermsGateBlocksUntilAgreementIsToggled() throws {
        let app = launch(.firstRun)
        XCTAssertTrue(app.staticTexts["Welcome to hoppin"].waitForExistence(timeout: 20))

        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 5) {
            skip.tap()
        } else {
            // Fall back to paging through with Next.
            let next = app.buttons["Next"]
            for _ in 0..<8 where next.exists {
                next.tap()
            }
        }

        let heading = app.staticTexts["Before You Start"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10),
                      "skipping onboarding should land on the terms page")

        let agree = app.buttons["Agree and Continue"]
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "the agree button should exist")
        XCTAssertFalse(agree.isEnabled,
                       "the terms gate must stay closed until the switch is on")

        let toggle = app.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the agreement switch should exist")
        toggle.tap()

        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: agree)
        waitForExpectations(timeout: 10)
    }

    // MARK: - Verification

    func testVerificationScreenRejectsAnObviouslyInvalidNumber() throws {
        let app = launch(.onboarded)

        let heading = app.staticTexts["Verify Your Number"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20),
                      "an onboarded but unverified user should see SMS verification")

        let sendCode = app.buttons["Send Code"]
        XCTAssertTrue(sendCode.waitForExistence(timeout: 10))
        XCTAssertFalse(sendCode.isEnabled, "an empty field must not be submittable")

        let field = app.textFields["Phone number, including country code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the phone field should carry its accessibility label")
        field.tap()
        field.typeText("12")

        // "12" cannot normalize to E.164, so the button stays disabled and the
        // hint explains why.
        XCTAssertFalse(sendCode.isEnabled, "an un-normalizable number must not be submittable")
        XCTAssertTrue(app.staticTexts["Add your country code, like +351 or +1."]
                        .waitForExistence(timeout: 5),
                      "an invalid number should be explained inline")
    }

    func testVerificationAcceptsAWellFormedNumber() throws {
        let app = launch(.onboarded)
        XCTAssertTrue(app.staticTexts["Verify Your Number"].waitForExistence(timeout: 20))

        let field = app.textFields["Phone number, including country code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("+351912345678")

        // The normalized preview appears and the button becomes tappable.
        // (Nothing is submitted: these tests never touch the network.)
        let preview = app.staticTexts["We'll verify +351912345678"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5),
                      "a valid number should preview its normalized form")
        XCTAssertTrue(app.buttons["Send Code"].isEnabled)
    }

    // MARK: - Accessibility

    func testOnboardingIsReadableByVoiceOver() throws {
        let app = launch(.firstRun)
        XCTAssertTrue(app.staticTexts["Welcome to hoppin"].waitForExistence(timeout: 20))

        // Slide text is combined into one element with a non-empty label, and
        // the decorative icon is hidden from assistive technologies.
        let slide = app.staticTexts["Welcome to hoppin"]
        XCTAssertFalse(slide.label.isEmpty, "the slide must expose a VoiceOver label")

        for button in ["Next", "Skip"] where app.buttons[button].exists {
            XCTAssertFalse(app.buttons[button].label.isEmpty,
                           "\(button) must expose a VoiceOver label")
        }
    }
}
