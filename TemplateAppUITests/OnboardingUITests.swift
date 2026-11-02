import XCTest

/// The first-launch onboarding (#483) on a Japanese iPhone: the capture arguments, `-OnboardingSkip`, and
/// the sample flow with Skip, Back, the question and "Get Started". No app-specific identifiers here:
/// Identity bootstrap does not rewrite this file, so the root screen's title is found by the end of its
/// identifier. The device is erased before the run, so the first launch below is the app's first.
final class OnboardingUITests: XCTestCase {
    private let japanese = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
    private let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testJapaneseOnboardingFlowSkipBackAndChoice() {
        let app = XCUIApplication()

        // The App Store capture starts on the root screen and records nothing.
        launch(app, japanese + ["--appstore-screenshot", "--fixture", "primary"])
        XCTAssertTrue(rootTitle(app).waitForExistence(timeout: 10), "The capture should start on the root screen.")
        XCTAssertFalse(app.buttons["onboarding.skip"].exists, "The capture should not show the onboarding.")

        // A capture of the onboarding itself shows the named page.
        launch(app, japanese + ["--appstore-screenshot", "--onboarding-page", "purpose"])
        let position = app.descendants(matching: .any)["onboarding.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), "The named page should be shown.")
        XCTAssertEqual(position.label, "3ページ中2ページ目")
        XCTAssertEqual(app.staticTexts["onboarding.page.purpose.title"].label, "まず何をしますか？")

        // -OnboardingSkip starts on the root screen, in Japanese and in English.
        for language in [japanese, english] {
            launch(app, language + ["-OnboardingSkip"])
            XCTAssertTrue(rootTitle(app).waitForExistence(timeout: 10), "\(language): the root screen")
            XCTAssertFalse(app.buttons["onboarding.skip"].exists, "\(language): no onboarding")
        }

        // Nothing above recorded a completion, so a plain launch is still the first one.
        launch(app, japanese)
        XCTAssertTrue(position.waitForExistence(timeout: 10), "The first launch should show the onboarding.")
        XCTAssertEqual(position.label, "3ページ中1ページ目")

        // The flow, through -OnboardingForceShow.
        launch(app, japanese + ["-OnboardingForceShow"])
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        XCTAssertEqual(position.label, "3ページ中1ページ目")
        XCTAssertEqual(app.staticTexts["onboarding.page.welcome.title"].label, "アプリの土台がそろっています")
        XCTAssertEqual(
            app.staticTexts["onboarding.page.welcome.message"].label,
            "フィードバック、評価の依頼、法務のリンクなど、どのアプリにも要る部品が入っています。"
        )
        let skip = app.buttons["onboarding.skip"]
        let primary = app.buttons["onboarding.primary"]
        let back = app.buttons["onboarding.back"]
        XCTAssertTrue(skip.exists)
        XCTAssertEqual(skip.label, "オンボーディングをスキップ")
        XCTAssertGreaterThanOrEqual(skip.frame.height, 44, "Skip should be at least 44pt tall")
        XCTAssertGreaterThanOrEqual(skip.frame.width, 44, "Skip should be at least 44pt wide")
        XCTAssertEqual(primary.label, "次へ")
        XCTAssertGreaterThanOrEqual(primary.frame.height, 44, "Next should be at least 44pt tall")
        XCTAssertFalse(back.exists, "The first page has no Back.")

        // The question: "Next" waits for an answer, Back returns, Skip stays available.
        primary.tap()
        waitForLabel(position, "3ページ中2ページ目")
        XCTAssertEqual(app.staticTexts["onboarding.page.purpose.title"].label, "まず何をしますか？")
        XCTAssertTrue(back.waitForExistence(timeout: 3), "The second page has Back.")
        XCTAssertEqual(back.label, "前のページへ戻る")
        XCTAssertGreaterThanOrEqual(back.frame.height, 44, "Back should be at least 44pt tall")
        XCTAssertTrue(skip.exists)
        XCTAssertFalse(primary.isEnabled, "Next waits for an answer.")

        back.tap()
        waitForLabel(position, "3ページ中1ページ目")
        primary.tap()
        waitForLabel(position, "3ページ中2ページ目")

        let build = app.buttons["onboarding.option.purpose.build"]
        XCTAssertTrue(build.waitForExistence(timeout: 3))
        XCTAssertTrue(build.label.contains("新しいアプリを作る"), build.label)
        XCTAssertGreaterThanOrEqual(build.frame.height, 44, "An option should be at least 44pt tall")
        build.tap()
        XCTAssertTrue(build.isSelected, "The chosen option carries the selected state.")
        XCTAssertTrue(primary.isEnabled, "An answer enables Next.")

        // The last page: Back but no Skip, and "Get Started" opens the root screen with the answer.
        primary.tap()
        waitForLabel(position, "3ページ中3ページ目")
        XCTAssertEqual(app.staticTexts["onboarding.page.done.title"].label, "準備ができました")
        XCTAssertFalse(skip.exists, "The last page has no Skip.")
        XCTAssertTrue(back.exists, "The last page has Back.")
        XCTAssertEqual(primary.label, "はじめる")
        XCTAssertGreaterThanOrEqual(primary.frame.height, 44)
        primary.tap()

        let purposeLine = app.staticTexts["onboarding.sample.purpose-line"]
        XCTAssertTrue(purposeLine.waitForExistence(timeout: 10), "The root screen should use the answer.")
        XCTAssertEqual(purposeLine.label, "最初の画面から作り始めましょう。")
        XCTAssertTrue(rootTitle(app).exists)
        XCTAssertFalse(app.buttons["onboarding.primary"].exists, "The onboarding has closed.")
    }

    @MainActor
    private func launch(_ app: XCUIApplication, _ arguments: [String]) {
        app.launchArguments = arguments
        app.launch()
    }

    /// The root screen's title; its identifier is `<slug>.welcome-title` in every app.
    @MainActor
    private func rootTitle(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier ENDSWITH %@", ".welcome-title")).firstMatch
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected \(label), found \(element.label)", file: file, line: line)
    }
}
