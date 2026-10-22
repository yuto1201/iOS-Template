import Foundation
import Observation

/// The review prompt (#383): now and then, after the person has used the app for a while, a small sheet
/// asks "How do you like <app>?". "Good" closes it and asks the system for its rating prompt through
/// Apple's API (App Review Guideline 5.6.1); "Not great" offers the in-app feedback (D-076) once, gently.
///
/// The app calls `recordSignificantEvent()` at its moments of success (saved a record, finished a task)
/// and `presentIfEligible()` where a short question would not interrupt. While onboarding, a purchase, a
/// full-screen ad, an error or another sheet or alert is on screen, it calls `suppress(_:)` and later
/// `resume(_:)`. See docs/review-prompt.md.
@Observable
final class ReviewPromptCenter {
    enum Phase: Equatable {
        case question
        case followUp
    }

    /// What the follow-up after "Not great" offers. There is never a rating UI of the app's own.
    enum FollowUpAction: Equatable {
        case sendFeedback
        case openSupport(URL)
        case close
    }

    let config: ReviewPromptConfig
    let appName: String
    let appVersion: String
    /// Whether the build has a feedback endpoint (`feedbackSender` is not nil).
    var feedbackAvailable = false
    var supportURL: URL?
    /// Apple's rating request (`requestReview` from the environment). The system decides whether its
    /// prompt appears, at most a few times a year, and the app cannot know, so nothing depends on it.
    var requestReview: () -> Void = {}

    var isPresented = false
    private(set) var phase = Phase.question
    private(set) var feedbackWasSent = false

    private let store: any ReviewPromptStore
    private let now: () -> Date
    private var suppressions: Set<String> = []
    private var answered = false
    private var reviewRequestPending = false

    init(
        config: ReviewPromptConfig,
        store: any ReviewPromptStore,
        appName: String,
        appVersion: String,
        now: @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.store = store
        self.appName = appName
        self.appVersion = appVersion
        self.now = now
    }

    /// The app's own settings, record, name and version.
    static func live(bundle: Bundle = .main) -> ReviewPromptCenter {
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ""
        let version = (info["CFBundleShortVersionString"] as? String) ?? ""
        let center = ReviewPromptCenter(
            config: .load(bundle: bundle), store: UserDefaultsReviewPromptStore(), appName: name, appVersion: version
        )
        center.supportURL = LegalLinks.current()?.support
        return center
    }

    var record: ReviewPromptRecord { store.load() }

    var isSuppressed: Bool { !suppressions.isEmpty }

    var blockingReason: ReviewPromptPolicy.Reason? {
        ReviewPromptPolicy.blockingReason(
            config: config, record: store.load(), now: now(), appVersion: appVersion, suppressed: isSuppressed
        )
    }

    // MARK: Signals from the app

    func recordLaunch() {
        update { record in
            record.launchCount += 1
            if record.firstLaunchDate == nil { record.firstLaunchDate = now() }
        }
    }

    func recordSignificantEvent() {
        update { $0.significantEvents += 1 }
    }

    /// "Not now" while the given reason holds (for example "onboarding", "purchase", "ad", "error", "sheet").
    func suppress(_ reason: String) {
        suppressions.insert(reason)
    }

    func resume(_ reason: String) {
        suppressions.remove(reason)
    }

    /// Shows the question after the configured pause when the rules allow it. `force` (Debug launch
    /// argument only) skips the rules and the pause, for UI tests and screenshots.
    func presentIfEligible(force: Bool = false) async {
        guard !isPresented else { return }
        if !force {
            guard blockingReason == nil else { return }
            if config.presentationDelaySeconds > 0 {
                try? await Task.sleep(for: .seconds(config.presentationDelaySeconds))
            }
            // The app may have started something during the pause.
            guard blockingReason == nil else { return }
        }
        phase = .question
        answered = false
        feedbackWasSent = false
        reviewRequestPending = false
        update { record in
            record.lastAskedDate = now()
            record.lastAskedVersion = appVersion
        }
        isPresented = true
    }

    // MARK: Answers

    /// "Good": never asked again, and after the sheet has closed, Apple's rating request.
    func answerPositive() {
        answered = true
        update { record in
            record.lastAnswer = .positive
            record.stopped = true
        }
        reviewRequestPending = true
        isPresented = false
    }

    /// "Not great": asked again only after the cool-down, and the sheet offers feedback.
    func answerNegative() {
        answered = true
        update { $0.lastAnswer = .negative }
        phase = .followUp
    }

    var followUpActions: [FollowUpAction] {
        if feedbackAvailable { return [.sendFeedback, .close] }
        if let supportURL { return [.openSupport(supportURL), .close] }
        return [.close]
    }

    /// Feedback sent from the follow-up: never asked again.
    func feedbackSent() {
        feedbackWasSent = true
        update { $0.stopped = true }
    }

    func close() {
        isPresented = false
    }

    /// Called when the sheet has gone, however it was closed. A close before any answer counts toward
    /// `maximumDismissals`; "Good" makes the rating request now that nothing covers the screen.
    func sheetDidDismiss() {
        if !answered {
            update { $0.dismissals += 1 }
        }
        answered = true
        if reviewRequestPending {
            reviewRequestPending = false
            requestReview()
        }
    }

    private func update(_ change: (inout ReviewPromptRecord) -> Void) {
        var record = store.load()
        change(&record)
        store.save(record)
    }

    /// Debug builds only: `-ReviewPromptForceShow` shows the question at launch regardless of the rules.
    static func forcesShow(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        return arguments.contains("-ReviewPromptForceShow")
        #else
        return false
        #endif
    }
}
