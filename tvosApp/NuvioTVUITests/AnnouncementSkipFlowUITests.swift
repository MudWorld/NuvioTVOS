import XCTest

@MainActor
final class AnnouncementSkipFlowUITests: XCTestCase {
    func testSkippingFirstMessageAdvancesAndSecondSkipPersists() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Prepared fixture: release already skipped, two active announcements unskipped.
        app.launchArguments = ["-nuvio.auth.skippedLogin", "YES"]
        app.launch()

        let readMessage = app.buttons["announcement-notice-view-details"]
        guard readMessage.waitForExistence(timeout: 20) else {
            throw XCTSkip("This flow requires the prepared release-skipped, two-announcement QA fixture.")
        }
        XCTAssertTrue(waitForFocus(readMessage), "The first announcement should receive focus.")

        let dismiss = app.buttons["announcement-notice-dismiss"]
        let skip = app.buttons["announcement-notice-skip"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(dismiss), "Right from Read Message should focus Dismiss.")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(skip), "The next Right should focus Don't Show Again.")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(waitForFocus(readMessage), "Skipping the first ID should hand off to the second announcement.")
        let secondTitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "viewers")).firstMatch
        XCTAssertTrue(secondTitle.waitForExistence(timeout: 5), "The second feed item should now be visible.")

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(dismiss), "Right from the second Read Message should focus Dismiss.")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(skip), "The next Right should focus Skip for the second ID.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForNonExistence(readMessage), "Skipping both IDs should hide announcements.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "Skipping the final message should restore Home focus.")

        XCUIRemote.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5), "Home should background the skipped app.")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The app should return to the foreground.")
        XCTAssertTrue(waitForNonExistence(readMessage), "Foregrounding must not restore either skipped ID.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "Home should remain focused after foregrounding.")

        app.terminate()
        app.launch()
        XCTAssertTrue(waitForNonExistence(readMessage), "Announcement skips should persist across process relaunch.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "Home should remain focused after relaunch.")
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
}
