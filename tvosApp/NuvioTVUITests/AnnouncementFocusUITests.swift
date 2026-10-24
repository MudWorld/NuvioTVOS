import XCTest

@MainActor
final class AnnouncementFocusUITests: XCTestCase {
    func testReleaseHandoffAnnouncementDetailsDismissAndIndependentSkip() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The dedicated simulator needs a newer cached release, then exactly two
        // active announcements in order: linked first, no-link second.
        app.launchArguments = ["-nuvio.auth.skippedLogin", "YES"]
        app.launch()

        let viewRelease = app.buttons["release-notice-view-release"]
        guard viewRelease.waitForExistence(timeout: 25) else {
            throw XCTSkip("This UI flow requires the documented newer-release and announcement simulator fixture.")
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

        let dismissRelease = app.buttons["release-notice-dismiss"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(dismissRelease), "Right from View Release should focus Dismiss.")
        XCUIRemote.shared.press(.select)
        let readMessage = app.buttons["announcement-notice-view-details"]
        XCTAssertTrue(readMessage.waitForExistence(timeout: 10), "Dismissing the release should hand off to the announcement.")
        XCTAssertTrue(waitForFocus(readMessage), "The announcement should receive focus during the release handoff.")
        attachScreenshot(named: "announcement-handoff-focus")

        XCUIRemote.shared.press(.select)
        let announcementDone = app.buttons["announcement-details-done"]
        XCTAssertTrue(announcementDone.waitForExistence(timeout: 10), "Read Message should present announcement details.")
        XCTAssertTrue(app.images["announcement-details-qr-code"].waitForExistence(timeout: 5), "The fixture announcement should include its QR link.")
        let linkedParagraphs = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "announcement-details-message-paragraph-")
        ).allElementsBoundByIndex
        XCTAssertFalse(linkedParagraphs.first?.label.isEmpty ?? true, "Linked announcement details should expose the message.")
        XCTAssertTrue(waitForFocus(announcementDone), "Announcement details should focus Done.")
        attachScreenshot(named: "announcement-details")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(readMessage), "Closing announcement details should restore its primary focus.")

        let dismissAnnouncement = app.buttons["announcement-notice-dismiss"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(dismissAnnouncement), "Right from Read Message should focus announcement Dismiss.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(readMessage), "Dismissing the first message should hand off to the next feed item.")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(announcementDone.waitForExistence(timeout: 10), "Read Message should open the no-link announcement.")
        XCTAssertTrue(waitForNonExistence(app.images["announcement-details-qr-code"]), "A no-link announcement should show plain message details without a QR.")
        let titleParagraphs = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "announcement-details-title-paragraph-")
        ).allElementsBoundByIndex
        let messageParagraphs = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "announcement-details-message-paragraph-")
        ).allElementsBoundByIndex
        XCTAssertEqual(titleParagraphs.map(\.label).joined(separator: "\n"), "Update\nfrom\nNuvioTV\nfor\nall\nviewers")
        let reconstructedMessage = messageParagraphs.map(\.label).joined(separator: "\n")
        XCTAssertEqual(messageParagraphs.count, 29)
        XCTAssertEqual(reconstructedMessage.count, 227)
        XCTAssertEqual(messageParagraphs.last?.label, "END")
        XCTAssertTrue(waitForFocus(announcementDone), "The no-link details should focus Done.")
        attachScreenshot(named: "announcement-no-link-details")

        let detailsScroll = app.scrollViews["announcement-details-scroll"]
        XCTAssertTrue(detailsScroll.exists, "Long announcement details should expose a native scroll region.")
        let firstTitleParagraph = try XCTUnwrap(titleParagraphs.first)
        let allParagraphs = titleParagraphs + messageParagraphs
        let initialTitleY = firstTitleParagraph.frame.minY
        XCUIRemote.shared.press(.up)
        let paragraphReceivedFocus = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in allParagraphs.contains(where: { $0.hasFocus }) },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [paragraphReceivedFocus], timeout: 5), .completed, "Up from Done should focus an announcement paragraph.")
        for _ in 0..<40 where !firstTitleParagraph.hasFocus {
            XCUIRemote.shared.press(.up)
            let firstTitleFocused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasFocus == true"),
                object: firstTitleParagraph
            )
            _ = XCTWaiter.wait(for: [firstTitleFocused], timeout: 0.2)
        }
        XCTAssertTrue(waitForFocus(firstTitleParagraph), "Remote focus should traverse back through the title paragraphs.")
        for paragraph in allParagraphs.dropFirst() {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(waitForFocus(paragraph, timeout: 2), "Remote Down should traverse each title and message paragraph.")
        }
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(announcementDone), "Done should remain reachable after scrolling the full message.")
        XCTAssertNotEqual(firstTitleParagraph.frame.minY, initialTitleY, "Remote traversal should scroll the long details content.")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(readMessage), "Closing no-link details should restore Read Message focus.")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(dismissAnnouncement), "Right from Read Message should focus announcement Dismiss.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForNonExistence(readMessage), "Dismissing the second message should return to Home.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "Dismissing the announcement feed should restore Home focus.")

        XCUIRemote.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5), "Home should background the app.")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The app should return to the foreground.")
        XCTAssertTrue(waitForFocus(viewRelease, timeout: 25), "Foregrounding should restore the higher-priority release.")

        // Skip the release to expose the announcement independently for lifecycle checks.
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(dismissRelease), "The first Right press should focus release Dismiss.")
        XCUIRemote.shared.press(.right)
        let skipRelease = app.buttons["release-notice-skip"]
        XCTAssertTrue(waitForFocus(skipRelease), "The second Right press should focus Skip This Version.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForNonExistence(viewRelease), "Skipping the release should hand off to the announcement.")
        XCTAssertTrue(waitForFocus(readMessage), "The announcement should receive focus after the release is skipped.")

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(dismissAnnouncement), "Right from Read Message should focus announcement Dismiss.")
        XCUIRemote.shared.press(.right)
        let skipAnnouncement = app.buttons["announcement-notice-skip"]
        XCTAssertTrue(waitForFocus(skipAnnouncement), "The next Right press should focus Don't Show Again.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(readMessage), "Skipping the first message should leave the next active message eligible.")

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(dismissAnnouncement), "Right from the second message should focus Dismiss.")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(skipAnnouncement), "The next Right press should focus Don't Show Again for the second message.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForNonExistence(readMessage), "Skipping the second message should hide all announcements.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "Skipping all messages should restore Home focus.")

        XCUIRemote.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5), "Home should background the skipped messages.")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The skipped-announcement app should return to the foreground.")
        XCTAssertTrue(waitForNonExistence(readMessage), "Foregrounding must not restore skipped announcements.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "Skipped announcements should leave Home focused.")

        app.terminate()
        app.launch()
        XCTAssertTrue(waitForNonExistence(readMessage), "Announcement skip should persist across launches.")
        XCTAssertTrue(waitForHomeCardFocus(in: app), "A skipped announcement should leave Home focused after relaunch.")
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
