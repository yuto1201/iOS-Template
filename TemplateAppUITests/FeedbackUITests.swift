import XCTest

/// In-app feedback (D-076) in English and Japanese on iPhone and iPad, with the scripted sender instead of
/// the network.
final class FeedbackUITests: XCTestCase {

    /// The words one language shows in the flow.
    private struct Language {
        let launchArguments: [String]
        let entry: String
        let request: String
        let offline: String
        let success: String
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishFeedbackKeepsMessageAndRetries() {
        runFeedbackFlow(Language(
            launchArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
            entry: "Send Feedback", request: "Request", offline: "Check your connection", success: "Thank you"
        ))
    }

    @MainActor
    func testJapaneseFeedbackKeepsMessageAndRetries() {
        runFeedbackFlow(Language(
            launchArguments: ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"],
            entry: "フィードバックを送る", request: "要望", offline: "接続できませんでした", success: "ありがとうございます"
        ))
    }

    @MainActor
    func testFeedbackEntryIsHiddenWithoutAnEndpoint() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()

        // No app-specific identifiers here: Identity bootstrap does not rewrite this file.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertFalse(app.buttons["feedback.entry"].waitForExistence(timeout: 3),
                       "The template ships no feedback host, so no entry.")
    }

    @MainActor
    private func runFeedbackFlow(_ language: Language) {
        let app = XCUIApplication()
        app.launchArguments = language.launchArguments + ["-FeedbackStub", "offline-then-success"]
        app.launch()

        let entry = app.buttons["feedback.entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "The entry should show when the build has a sender.")
        XCTAssertEqual(entry.label, language.entry)
        entry.tap()

        // An empty message is not sent.
        let send = app.buttons["feedback.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(element("feedback.validation", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("feedback.success", in: app).exists)
        // VoiceOver focus moves only to a send result, not to the validation message. VoiceOver cannot
        // run here, so the Debug sheet reports where it moved focus.
        let resultFocus = element("feedback.result-focus", in: app)
        XCTAssertTrue(resultFocus.waitForExistence(timeout: 3))
        XCTAssertEqual(resultFocus.label, "result-focus:none")

        let request = app.segmentedControls["feedback.category"].buttons[language.request]
        request.tap()
        let body = app.textViews["feedback.body"]
        body.tap()
        body.typeText("Template feedback check")

        // No connection: the reason shows and takes VoiceOver focus, and the message and type are kept
        // for another try.
        send.tap()
        let error = element("feedback.error", in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains(language.offline), error.label)
        XCTAssertTrue(waitForLabel("result-focus:error", of: resultFocus), resultFocus.label)
        XCTAssertEqual(body.value as? String, "Template feedback check")
        XCTAssertTrue(request.isSelected)

        // Sending again succeeds, the result takes VoiceOver focus, and Close returns to the root screen.
        send.tap()
        let success = element("feedback.success", in: app)
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertTrue(success.label.contains(language.success), success.label)
        XCTAssertTrue(waitForLabel("result-focus:success", of: resultFocus), resultFocus.label)
        app.buttons["feedback.close"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertFalse(success.exists)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func waitForLabel(_ label: String, of element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
