import Foundation
import Observation

/// The first-launch onboarding (#483, D-099, D-102). It shows the declared pages once, at the first launch,
/// with Skip on every page but the last and Back from the second page on. Answers stay on the device and
/// reach the app through `answers(for:)` and `onCompleted`. While it is on screen, the review prompt is
/// suppressed. See docs/onboarding.md.
@Observable
final class OnboardingCenter {
    let config: OnboardingConfig
    let launch: OnboardingLaunchArguments
    /// Called once the onboarding closes, by "Get Started" or Skip. After Skip, only the questions answered
    /// with "Next" before it are included.
    var onCompleted: (OnboardingAnswers) -> Void = { _ in }

    private(set) var isPresented = false
    private(set) var currentIndex = 0
    /// Options chosen on each choice page while the onboarding is open.
    private(set) var selections: [String: Set<String>] = [:]
    /// Permission primers where the person said no to the system's request.
    private(set) var deniedPermissionPages: Set<String> = []
    /// The answers of the finished onboarding.
    private(set) var savedAnswers: [String: [String]]

    private let store: any OnboardingStore
    private let now: () -> Date
    /// The app's notification request; nil while the app does not use notifications (D-068).
    private let requestNotificationAuthorization: (() async -> Bool)?
    /// Answers confirmed with "Next".
    private var confirmed: [String: [String]] = [:]
    private var reviewPrompt: ReviewPromptCenter?

    static let reviewPromptReason = "onboarding"

    init(
        config: OnboardingConfig,
        store: any OnboardingStore,
        launch: OnboardingLaunchArguments = OnboardingLaunchArguments(),
        now: @escaping () -> Date = Date.init,
        requestNotificationAuthorization: (() async -> Bool)? = nil
    ) {
        self.config = config
        self.store = store
        self.launch = launch
        self.now = now
        self.requestNotificationAuthorization = requestNotificationAuthorization
        savedAnswers = store.load().answers
    }

    /// The app's own declaration, record and launch arguments. An app that has adopted notifications
    /// (D-068) and declares a notification primer passes its request, for example
    /// `{ (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false }`.
    /// Without one, a declared primer turns the onboarding off.
    static func live(requestNotificationAuthorization: (() async -> Bool)? = nil) -> OnboardingCenter {
        let permissions: Set<OnboardingConfig.Permission> = requestNotificationAuthorization == nil ? [] : [.notifications]
        return OnboardingCenter(
            config: .load(availablePermissions: permissions),
            store: UserDefaultsOnboardingStore(),
            launch: .current(),
            requestNotificationAuthorization: requestNotificationAuthorization
        )
    }

    // MARK: Whether to show it

    var pages: [OnboardingConfig.Page] { config.pages }

    var currentPage: OnboardingConfig.Page? {
        pages.indices.contains(currentIndex) ? pages[currentIndex] : nil
    }

    /// Finished before, now or by an app's earlier onboarding.
    var isCompleted: Bool {
        store.load().completedAt != nil || config.legacyCompletionKeys.contains { store.flag($0) }
    }

    var shouldPresent: Bool {
        guard config.enabled, !pages.isEmpty else { return false }
        switch launch.mode {
        case .appStoreScreenshot(let pageID):
            guard let pageID else { return false }
            return pages.contains { $0.id == pageID }
        case .skip:
            return false
        case .forceShow:
            return true
        case .normal:
            return !isCompleted
        }
    }

    /// Called once at launch by `.onboarding(_:reviewPrompt:)`: shows the onboarding when it should, and
    /// keeps the review prompt quiet while it is on screen.
    func start(reviewPrompt: ReviewPromptCenter?) {
        self.reviewPrompt = reviewPrompt
        guard !isPresented, shouldPresent else { return }
        currentIndex = 0
        if case .appStoreScreenshot(let pageID?) = launch.mode, let index = pages.firstIndex(where: { $0.id == pageID }) {
            currentIndex = index
        }
        selections = [:]
        confirmed = [:]
        deniedPermissionPages = []
        reviewPrompt?.suppress(Self.reviewPromptReason)
        isPresented = true
    }

    /// The answers the app reads: the option ids of the finished onboarding, empty when unanswered.
    func answers(for pageID: String) -> [String] {
        savedAnswers[pageID] ?? []
    }

    // MARK: Moving between pages

    var showsSkip: Bool { currentPage?.kind != .completion }
    var showsBack: Bool { currentIndex > 0 }

    /// "Next" on a choice page waits for an answer; Skip is always possible.
    var canAdvance: Bool {
        guard let page = currentPage else { return false }
        if page.kind == .choice { return !(selections[page.id] ?? []).isEmpty }
        return true
    }

    /// The last page a swipe may reach: a choice page stops forward swipes, so its answer is confirmed
    /// with "Next".
    var swipeLimit: Int {
        pages.indices.first { $0 >= currentIndex && pages[$0].kind == .choice } ?? max(pages.count - 1, 0)
    }

    /// A swipe to another page.
    func go(to index: Int) {
        guard index != currentIndex, (0...swipeLimit).contains(index) else { return }
        currentIndex = index
    }

    /// "Next", or "Get Started" on the completion page.
    func next() {
        guard isPresented, let page = currentPage, canAdvance else { return }
        switch page.kind {
        case .choice:
            confirmed[page.id] = orderedSelection(on: page)
        case .completion:
            complete(skipped: false)
            return
        case .value, .permissionPrimer:
            break
        }
        if currentIndex + 1 < pages.count { currentIndex += 1 }
    }

    func back() {
        guard isPresented, currentIndex > 0 else { return }
        currentIndex -= 1
    }

    func skip() {
        complete(skipped: true)
    }

    // MARK: Choices

    func isSelected(_ optionID: String, on pageID: String) -> Bool {
        selections[pageID]?.contains(optionID) ?? false
    }

    /// One answer on a single-choice page; on a multiple-choice page each tap turns an option on or off.
    func select(_ optionID: String, on pageID: String) {
        guard let page = pages.first(where: { $0.id == pageID }), page.kind == .choice,
              (page.options ?? []).contains(where: { $0.id == optionID }) else { return }
        if page.selection == .multiple {
            var chosen = selections[pageID] ?? []
            if chosen.contains(optionID) { chosen.remove(optionID) } else { chosen.insert(optionID) }
            selections[pageID] = chosen
        } else {
            selections[pageID] = [optionID]
        }
    }

    private func orderedSelection(on page: OnboardingConfig.Page) -> [String] {
        let chosen = selections[page.id] ?? []
        return (page.options ?? []).map(\.id).filter { chosen.contains($0) }
    }

    // MARK: Permission primer

    func isPermissionDenied(on pageID: String) -> Bool {
        deniedPermissionPages.contains(pageID)
    }

    /// "Allow Notifications": only here does the system ask, through the app's request. A yes moves on; a no
    /// stays on the page with a note and "Next", so the person goes on either way (App Review Guidelines
    /// 5.1.1(iv), 4.5.4).
    func allowPermission() async {
        guard isPresented, let page = currentPage, page.kind == .permissionPrimer else { return }
        let pageID = page.id
        let granted = await requestNotificationAuthorization?() ?? false
        guard isPresented, currentPage?.id == pageID else { return }
        if granted {
            next()
        } else {
            deniedPermissionPages.insert(pageID)
        }
    }

    /// "Not Now": moves on without the system's dialog.
    func declinePermission() {
        guard currentPage?.kind == .permissionPrimer else { return }
        next()
    }

    // MARK: Finishing

    /// Closes the onboarding. It records the completion (unless this launch records nothing), hands the
    /// confirmed answers to `onCompleted`, and lets the review prompt ask again. Skip never asks for a
    /// permission.
    func complete(skipped: Bool) {
        guard isPresented else { return }
        let answers = OnboardingAnswers(selections: confirmed.filter { !$0.value.isEmpty }, skipped: skipped)
        if launch.recordsCompletion {
            store.save(OnboardingRecord(completedAt: now(), configVersion: config.version, answers: answers.selections))
            savedAnswers = answers.selections
        }
        isPresented = false
        reviewPrompt?.resume(Self.reviewPromptReason)
        onCompleted(answers)
    }

    /// Debug and tests: forget the completion and the answers, so the next start shows it again.
    func reset() {
        store.clear()
        savedAnswers = [:]
        selections = [:]
        confirmed = [:]
        deniedPermissionPages = []
        currentIndex = 0
    }
}
