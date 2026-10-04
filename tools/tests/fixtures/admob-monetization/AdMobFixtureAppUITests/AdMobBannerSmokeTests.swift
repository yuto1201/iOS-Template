import UIKit
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
        XCTAssertEqual(UIDevice.current.userInterfaceIdiom, .phone, "This case must run on the dedicated iPhone.")
        assertVisibleBanner()
        assertCollapsedBanners()
    }

    @MainActor
    func testJapanesePadBannerPlacement() {
        XCTAssertEqual(UIDevice.current.userInterfaceIdiom, .pad, "This case must run on the dedicated iPad.")
        assertVisibleBanner()
        assertCollapsedBanners()
    }

    /// Success, safe area, TabView reselection, scroll end, and a wider landscape container.
    @MainActor
    private func assertVisibleBanner() {
        let app = launchFixture()

        XCTAssertTrue(
            app.staticTexts["admob.fixture.home-title"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(tabButton(app, "ホーム").exists)
        XCTAssertTrue(tabButton(app, "設定").exists)

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
        XCTAssertLessThanOrEqual(creative.frame.height, 90, "The adaptive height must stay within the anchored banner range.")
        XCTAssertGreaterThan(creative.frame.width, 0)
        XCTAssertLessThanOrEqual(creative.frame.width, window.frame.width + 1)
        XCTAssertLessThanOrEqual(creative.frame.maxY, window.frame.maxY)
        XCTAssertLessThanOrEqual(
            contentEnd.frame.maxY,
            creative.frame.minY + 1,
            "The safe-area inset must keep the scroll end out from under the banner."
        )
        assertBannerClearsTabBar(app, creative)
        let portraitFrame = creative.frame

        tabButton(app, "設定").tap()
        XCTAssertTrue(
            app.buttons["admob.fixture.privacy-options"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["admob.fixture.privacy-options"].isEnabled)
        XCTAssertFalse(creative.exists, "The excluded settings screen must not show the banner.")

        tabButton(app, "ホーム").tap()
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
        XCTAssertLessThanOrEqual(creative.frame.maxY, app.windows.firstMatch.frame.maxY)
        assertBannerClearsTabBar(app, creative)

        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    /// Load failure, missing consent, and an ad-free entitlement leave no banner region behind.
    @MainActor
    private func assertCollapsedBanners() {
        for argument in ["--fixture-banner-failure", "--fixture-consent-denied", "--fixture-ad-free"] {
            let app = launchFixture(extraArguments: [argument])
            XCTAssertTrue(
                app.staticTexts["admob.fixture.home-title"]
                    .waitForExistence(timeout: 5)
            )
            XCTAssertTrue(
                app.staticTexts["同意確認: 完了"].waitForExistence(timeout: 5),
                "Consent must be gathered before a collapse is asserted (\(argument))."
            )
            if argument == "--fixture-banner-failure" {
                XCTAssertTrue(
                    app.staticTexts["広告状態: 折りたたみ"].waitForExistence(timeout: 5),
                    "The fixture must finish the failed load before collapse is asserted."
                )
            } else {
                // An ineligible host never requests a creative; give it time to (wrongly) appear.
                _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle \(argument)")], timeout: 2)
            }

            let creative = app.descendants(matching: .any)[
                "admob.fixture.banner-creative"
            ].firstMatch
            let host = app.descendants(matching: .any)[
                "admob.fixture.banner-host"
            ].firstMatch
            XCTAssertFalse(creative.exists, "No creative may appear (\(argument)).")
            if host.exists {
                XCTAssertFalse(host.isHittable, "A collapsed banner must not be hittable (\(argument)).")
                XCTAssertLessThanOrEqual(
                    host.frame.height,
                    1,
                    "A collapsed banner must not reserve visible space (\(argument))."
                )
            }

            let scroll = app.scrollViews["admob.fixture.scroll"]
            XCTAssertTrue(scroll.exists)
            scroll.swipeUp()
            let contentEnd = app.staticTexts["admob.fixture.content-end"]
            XCTAssertTrue(contentEnd.waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(
                contentEnd.frame.maxY,
                bottomLimit(app),
                "The collapsed banner must leave the scroll end reachable (\(argument))."
            )
            app.terminate()
        }
    }

    /// On iPhone the TabView bar sits below the banner; on iPad it may sit at the top of the window.
    private func assertBannerClearsTabBar(
        _ app: XCUIApplication,
        _ creative: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.exists else { return }
        if tabBar.frame.minY > creative.frame.midY {
            XCTAssertLessThanOrEqual(
                creative.frame.maxY,
                tabBar.frame.minY + 1,
                "The banner must remain above a bottom TabView bar.",
                file: file,
                line: line
            )
        } else {
            XCTAssertGreaterThanOrEqual(
                creative.frame.minY,
                tabBar.frame.maxY - 1,
                "The banner must not overlap a top TabView bar.",
                file: file,
                line: line
            )
        }
    }

    private func bottomLimit(_ app: XCUIApplication) -> CGFloat {
        let window = app.windows.firstMatch.frame
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists && tabBar.frame.minY > window.midY {
            return tabBar.frame.minY + 1
        }
        return window.maxY
    }

    private func tabButton(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let tabBarButton = app.tabBars.buttons[name]
        return tabBarButton.exists ? tabBarButton : app.buttons[name].firstMatch
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
