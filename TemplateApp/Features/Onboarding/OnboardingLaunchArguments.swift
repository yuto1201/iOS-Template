import Foundation

/// How this launch treats the onboarding.
///
/// - `--appstore-screenshot`: the App Store capture (`tools/capture-appstore-screenshots.sh`) launches with
///   it. The onboarding is not shown and nothing is recorded, so every captured state starts on the app's
///   own screens and the capture leaves no completion behind.
/// - `--appstore-screenshot --onboarding-page <pageId>`: the onboarding itself is the captured state; that
///   page is shown and nothing is recorded.
///
/// These two work in every build configuration, not only in Debug, because they belong to the capture
/// rather than to tests: whether the capture uses a Release build is still open (#476), and a capture of
/// a Release build must neither show the onboarding over the app nor record a completion.
///
/// Debug builds only, for UI tests and checks: `-OnboardingForceShow` shows it even after it was finished,
/// and `-OnboardingSkip` treats it as finished without recording anything.
nonisolated struct OnboardingLaunchArguments: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case normal
        case appStoreScreenshot(pageID: String?)
        case forceShow
        case skip
    }

    static let appStoreScreenshot = "--appstore-screenshot"
    static let onboardingPage = "--onboarding-page"
    static let forceShow = "-OnboardingForceShow"
    static let skip = "-OnboardingSkip"

    var mode = Mode.normal

    /// Whether finishing the onboarding in this launch writes the record.
    var recordsCompletion: Bool {
        switch mode {
        case .normal, .forceShow: true
        case .appStoreScreenshot, .skip: false
        }
    }

    static var allowsDebugArguments: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    init(mode: Mode = .normal) {
        self.mode = mode
    }

    init(arguments: [String], allowsDebugArguments: Bool = Self.allowsDebugArguments) {
        if arguments.contains(Self.appStoreScreenshot) {
            var pageID: String?
            if let index = arguments.firstIndex(of: Self.onboardingPage), arguments.indices.contains(index + 1) {
                pageID = arguments[index + 1]
            }
            mode = .appStoreScreenshot(pageID: pageID)
        } else if allowsDebugArguments, arguments.contains(Self.skip) {
            mode = .skip
        } else if allowsDebugArguments, arguments.contains(Self.forceShow) {
            mode = .forceShow
        } else {
            mode = .normal
        }
    }

    static func current() -> OnboardingLaunchArguments {
        OnboardingLaunchArguments(arguments: ProcessInfo.processInfo.arguments)
    }
}
