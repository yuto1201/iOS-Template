import XCTest

final class AdMobBannerSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testJapaneseBannerPlacement() {
        let app = launchFixture()

        XCTAssertTrue(
            app.staticTexts["admob.fixture.home-title"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.tabBars.buttons["ホーム"].exists)
        XCTAssertTrue(app.tabBars.buttons["設定"].exists)

        let creative = app.descendants(matching: .any)[
            "admob.fixture.banner-creative"
        ].firstMatch
        XCTAssertTrue(
            creative.waitForExistence(timeout: 5),
            "The network-free banner creative should become visible."
        )

        let scrollView = app.scrollViews["admob.fixture.scroll"]
        XCTAssertTrue(scrollView.exists)
        scrollView.swipeUp()

        let contentEnd = app.staticTexts["admob.fixture.content-end"]
        XCTAssertTrue(
            contentEnd.waitForExistence(timeout: 5),
            "The scroll content should remain reachable above the inset banner."
        )

        let window = app.windows.firstMatch
        XCTAssertGreaterThanOrEqual(creative.frame.height, 50)
        XCTAssertGreaterThan(creative.frame.width, 0)
        XCTAssertLessThanOrEqual(creative.frame.maxY, window.frame.maxY)
        XCTAssertLessThanOrEqual(
            contentEnd.frame.maxY,
            creative.frame.minY + 1,
            "The safe-area inset must keep the scroll end out from under the banner."
        )
        let portraitFrame = creative.frame
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
        XCTAssertLessThanOrEqual(
            creative.frame.maxY,
            tabBar.frame.minY + 1,
            "The banner must remain above the TabView bar."
        )

        app.tabBars.buttons["設定"].tap()
        XCTAssertTrue(
            app.buttons["admob.fixture.privacy-options"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["admob.fixture.privacy-options"].isEnabled)
        XCTAssertFalse(creative.exists)

        app.tabBars.buttons["ホーム"].tap()
        XCTAssertTrue(creative.waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        let resized = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                creative.exists && creative.frame.width > portraitFrame.width
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [resized], timeout: 5),
            .completed,
            "The banner should follow a wider landscape container."
        )
        XCTAssertLessThanOrEqual(
            creative.frame.maxY,
            app.tabBars.firstMatch.frame.minY + 1
        )

        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        let failedApp = launchFixture(extraArguments: ["--fixture-banner-failure"])
        XCTAssertTrue(
            failedApp.staticTexts["admob.fixture.home-title"]
                .waitForExistence(timeout: 5)
        )

        let failedCreative = failedApp.descendants(matching: .any)[
            "admob.fixture.banner-creative"
        ].firstMatch
        let failedHost = failedApp.descendants(matching: .any)[
            "admob.fixture.banner-host"
        ].firstMatch
        XCTAssertTrue(
            failedApp.staticTexts["広告状態: 折りたたみ"]
                .waitForExistence(timeout: 5),
            "The fixture must finish the failed load before collapse is asserted."
        )
        XCTAssertFalse(failedCreative.exists)
        XCTAssertFalse(failedHost.exists)
        XCTAssertTrue(failedApp.scrollViews["admob.fixture.scroll"].exists)
    }

    private func launchFixture(
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
        ] + extraArguments
        app.launch()
        return app
    }
}
