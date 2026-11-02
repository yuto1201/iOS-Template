import SwiftUI

/// "Rate This App" (D-103): opens the App Store's "Write a Review" page for this app, so a person can rate it
/// whenever they like. Apple's own prompt (`requestReview`) appears only a few times a year and the app cannot
/// tell whether it did, so the button never uses it, and it draws no rating of its own (Guideline 5.6.1).
/// The button is hidden until `appStoreId` in `ReviewPromptConfig.json` holds the app's App Store ID.
struct RateAppButton: View {
    @Environment(\.openURL) private var openURL
    private let destination = RateAppButton.bundledWriteReviewURL()

    var body: some View {
        if let destination {
            // The 44pt height is on the label, so the tappable area and the accessibility frame both get it.
            Button {
                Self.open(destination, with: openURL.callAsFunction)
            } label: {
                Label("review-prompt.rate-app", systemImage: "square.and.pencil")
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("review-prompt.rate-app")
        }
    }

    /// The button's whole action: open the page, nothing else.
    static func open(_ destination: URL, with open: (URL) -> Void) {
        open(destination)
    }

    /// The "Write a Review" page for an App Store ID, or nil when the ID is empty or not all ASCII digits.
    static func writeReviewURL(appStoreId: String) -> URL? {
        guard !appStoreId.isEmpty, appStoreId.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appStoreId)?action=write-review")
    }

    /// The page for the bundled `appStoreId`. Debug builds only: `-ReviewPromptAppStoreID <digits>` stands in
    /// for an ID the template does not have yet (UI Tests and screenshots).
    static func bundledWriteReviewURL(
        config: ReviewPromptConfig = .load(),
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL? {
        #if DEBUG
        if let flag = arguments.firstIndex(of: "-ReviewPromptAppStoreID"), arguments.indices.contains(flag + 1) {
            return writeReviewURL(appStoreId: arguments[flag + 1])
        }
        #endif
        return writeReviewURL(appStoreId: config.appStoreId)
    }
}
