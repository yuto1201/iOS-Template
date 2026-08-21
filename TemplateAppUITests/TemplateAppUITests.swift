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
    func testWelcomeTitleAppears() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.staticTexts["template.welcome-title"].waitForExistence(timeout: 5),
            "The deterministic welcome title should be visible after launch."
        )
    }
}
