import XCTest

/// The legal and support links on the root screen (D-072, D-081), shown through the Debug launch argument
/// because the template ships without an app slug.
final class LegalLinksUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testJapaneseLegalLinksAppearOnTheRootScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP", "-LegalLinksAppSlug", "sample-app"]
        app.launch()

        let expected = [
            ("legal.privacy-policy", "プライバシーポリシー"),
            ("legal.terms-of-use", "利用規約"),
            ("legal.support", "サポート")
        ]
        for (identifier, title) in expected {
            let link = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(link.waitForExistence(timeout: 10), "\(identifier) is missing")
            XCTAssertEqual(link.label, title)
            // Layout can land a hair under 44 (43.99999999999994), so allow 0.01pt of floating-point error.
            XCTAssertGreaterThanOrEqual(link.frame.height + 0.01, 44, "\(identifier) is shorter than 44pt")
        }
    }
}
