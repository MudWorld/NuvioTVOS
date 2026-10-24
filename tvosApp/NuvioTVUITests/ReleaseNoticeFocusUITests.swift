import XCTest

@MainActor
final class ReleaseNoticeFocusUITests: XCTestCase {
    func testReleaseNoticeFocusQRReturnDismissAndSkip() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Run with announcements disabled or an empty feed and a valid cached newer release.
        app.launchArguments = ["-nuvio.auth.skippedLogin", "YES"]
        app.launch()

        let viewRelease = app.buttons["release-notice-view-release"]
        guard viewRelease.waitForExistence(timeout: 25) else {
            throw XCTSkip("This UI flow requires a valid cached release newer than the installed app.")
        }
        XCTAssertTrue(waitForFocus(viewRelease), "The banner should focus View Release on insertion.")
        attachScreenshot(named: "floating-banner-focus")

        XCUIRemote.shared.press(.select)
        let qrDone = app.buttons["release-qr-done"]
        XCTAssertTrue(qrDone.waitForExistence(timeout: 10), "View Release should present the QR sheet.")
        XCTAssertTrue(waitForFocus(qrDone), "The QR sheet Done control should receive focus.")
        attachScreenshot(named: "release-qr-sheet")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(viewRelease), "Closing the QR sheet should restore banner focus.")

        let dismiss = app.buttons["release-notice-dismiss"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(dismiss), "Right from View Release should focus Dismiss.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForNonExistence(viewRelease), "Dismiss should hide the banner for this launch.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "Dismissing should return focus to Home.")

        XCUIRemote.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5), "Home should background the app.")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The app should return to the foreground.")
        XCTAssertTrue(waitForFocus(viewRelease, timeout: 25), "Returning from background should show and focus the dismissed release again.")

        app.terminate()
        app.launch()
        XCTAssertTrue(waitForFocus(viewRelease, timeout: 25), "The banner should auto-focus again after relaunch.")

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForNonExistence(viewRelease), "Menu should dismiss the visible banner.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "Menu dismissal should return focus to Home.")

        app.terminate()
        app.launch()
        XCTAssertTrue(waitForFocus(viewRelease, timeout: 25), "A launch-local Menu dismissal should not persist.")

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(dismiss), "The first Right press should focus Dismiss.")
        XCUIRemote.shared.press(.right)
        let skip = app.buttons["release-notice-skip"]
        XCTAssertTrue(waitForFocus(skip), "The second Right press should focus Skip This Version.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForNonExistence(viewRelease), "Skip should hide the banner.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "Skipping should return focus to Home.")

        XCUIRemote.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5), "Home should background the skipped app.")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The skipped app should return to the foreground.")
        XCTAssertTrue(waitForNonExistence(viewRelease), "Foregrounding must not restore a skipped release.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "A skipped release should leave Home focused after foregrounding.")

        app.terminate()
        app.launch()
        XCTAssertTrue(waitForNonExistence(viewRelease), "Skip This Version should persist across launches.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "A skipped release should leave Home focused after relaunch.")
    }

    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForHomeCardFocus(in app: XCUIApplication, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND hasFocus == true",
            "poster-card-"
        )
        return waitForFocus(app.buttons.matching(predicate).firstMatch, timeout: timeout)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
