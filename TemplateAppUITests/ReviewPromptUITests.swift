import XCTest

/// The review prompt (#383) on a Japanese iPhone: the question, its answers, and the gentle follow-up after
/// "Not great". No app-specific identifiers here: Identity bootstrap does not rewrite this file, so the app
/// name is read from the question rather than written down.
final class ReviewPromptUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testJapaneseReviewPromptShowsAndGuidesToFeedback() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP", "-ReviewPromptForceShow",
                               "-FeedbackStub", "success"]
        app.launch()

        let question = app.staticTexts["review-prompt.question"]
        XCTAssertTrue(question.waitForExistence(timeout: 10), "The forced launch should show the question.")
        XCTAssertTrue(question.label.hasSuffix("はどうですか？"), question.label)
        XCTAssertGreaterThan(question.label.count, "はどうですか？".count, "The question should name the app.")

        let answers: [(identifier: String, title: String)] = [
            ("review-prompt.positive", "良い"), ("review-prompt.negative", "いまいち"), ("review-prompt.later", "あとで")
        ]
        for answer in answers {
            let button = app.buttons[answer.identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 3), answer.identifier)
            XCTAssertEqual(button.label, answer.title)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(answer.identifier) should be at least 44pt tall")
        }

        app.buttons["review-prompt.negative"].tap()
        let invitation = app.staticTexts["review-prompt.follow-up"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 5))
        XCTAssertEqual(invitation.label, "よろしければ、改善のためにご意見をお聞かせください。")
        let sendFeedback = app.buttons["review-prompt.send-feedback"]
        let close = app.buttons["review-prompt.close"]
        XCTAssertTrue(sendFeedback.waitForExistence(timeout: 3))
        XCTAssertEqual(sendFeedback.label, "フィードバックを送る")
        XCTAssertEqual(close.label, "閉じる")
        XCTAssertGreaterThanOrEqual(sendFeedback.frame.height, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        XCTAssertFalse(app.buttons["review-prompt.positive"].exists, "The question is gone after an answer.")

        // "Send Feedback" opens the existing feedback sheet.
        sendFeedback.tap()
        XCTAssertTrue(app.buttons["feedback.send"].waitForExistence(timeout: 5))
    }
}
