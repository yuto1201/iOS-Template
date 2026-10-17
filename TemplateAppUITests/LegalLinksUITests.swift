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
            XCTAssertGreaterThanOrEqual(link.frame.height, 44, "\(identifier) is shorter than 44pt")
        }
    }
}
