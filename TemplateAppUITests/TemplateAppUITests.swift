//
//  TemplateAppUITests.swift
//  TemplateAppUITests
//
//  Created by 上杉侑斗 on 2026/08/21.
//

import XCTest

final class TemplateAppUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishWelcomeTitle() {
        assertWelcomeTitle(
            language: "en",
            locale: "en_US",
            expectedText: "Ready to build"
        )
    }

    @MainActor
    func testJapaneseWelcomeTitle() {
        assertWelcomeTitle(
            language: "ja",
            locale: "ja_JP",
            expectedText: "開発を始められます"
        )
    }

    @MainActor
    private func assertWelcomeTitle(
        language: String,
        locale: String,
        expectedText: String
    ) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
        app.launch()

        let welcomeTitle = app.staticTexts["template.welcome-title"]
        XCTAssertTrue(
            welcomeTitle.waitForExistence(timeout: 5),
            "The deterministic welcome title should be visible after launch."
        )
        XCTAssertEqual(welcomeTitle.label, expectedText)
    }
}
