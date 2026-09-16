//
//  HopChat_1UITestsLaunchTests.swift
//  HopChat-1UITests
//
//  One launch test per UI configuration, capturing a screenshot attachment.
//  Kept minimal on purpose: launch tests run for every configuration, so
//  anything slow or stateful here is paid for repeatedly.
//

import XCTest

final class HopChat_1UITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool { true }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestResetState", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-hopchat.hasSeenOnboarding", "NO",
                                "-hopchat.hasAcceptedTerms", "NO",
                                "-hopchat.appLock.enabled", "NO"]
        app.launch()

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 20),
                      "the first screen rendered no text")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
