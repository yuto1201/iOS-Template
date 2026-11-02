//
//  TemplateAppTests.swift
//  TemplateAppTests
//
//  Created by 上杉侑斗 on 2026/08/21.
//

import Foundation
import Testing
@testable import TemplateApp

struct TemplateAppTests {

    @Test("Welcome message is localized in English and Japanese")
    func welcomeMessageLocalizations() {
        #expect(localizedValue(for: "template.welcome", language: "en") == "Ready to build")
        #expect(localizedValue(for: "template.welcome", language: "ja") == "開発を始められます")
    }

    private func localizedValue(for key: String, language: String) -> String? {
        guard let localizationURL = Bundle.main.url(
            forResource: language,
            withExtension: "lproj"
        ), let localizationBundle = Bundle(url: localizationURL) else {
            return nil
        }

        return localizationBundle.localizedString(forKey: key, value: nil, table: nil)
    }
}

/// Answers every request from the test's closure and records what was sent.
nonisolated final class FeedbackURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest) throws -> Int)?
    nonisolated(unsafe) static var request: URLRequest?
    nonisolated(unsafe) static var body: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.request = request
        Self.body = request.httpBodyStream.map(Self.read)
        do {
            let status = try Self.respond?(request) ?? 201
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// In-app feedback (D-076). The canonical run executes `payloadMatchesWorkerContract()`, so it covers the
/// whole client contract: the payload, the bundled host setting, the status mapping, and the privacy manifest.
@Suite(.serialized)
@MainActor
struct FeedbackTests {
    private let endpoint = URL(string: "https://feedback.example.dev/v1/feedback")!
    private let environment = FeedbackEnvironment(
        appVersion: "1.0", build: "1", osVersion: "27.0", deviceModel: "iPhone18,2", locale: "ja-JP"
    )

    private func stubbedClient() -> FeedbackClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackURLProtocol.self]
        return FeedbackClient(endpoint: endpoint, session: URLSession(configuration: configuration))
    }

    @Test("Screenshots can open the feedback sheet at launch, and only when asked")
    func feedbackOpensOnLaunchOnlyWhenAsked() {
        #expect(FeedbackEntryButton.opensOnLaunch(arguments: ["App", "-FeedbackOpen"]))
        #expect(!FeedbackEntryButton.opensOnLaunch(arguments: ["App", "-FeedbackStub", "offline-then-success"]))
    }

    @Test("Feedback matches the Worker's contract, endpoint setting, status mapping and privacy manifest")
    func payloadMatchesWorkerContract() async throws {
        // The payload carries exactly the seven fields the Worker accepts, within its limits.
        var draft = FeedbackDraft()
        draft.body = "  \n "
        #expect(!draft.isValid)
        draft.body = "  Crash on launch \n"
        #expect(draft.validatedBody() == "Crash on launch")
        draft.body = String(repeating: "a", count: 2001)
        #expect(!draft.isValid)
        #expect(FeedbackCategory.allCases.map(\.rawValue) == ["bug", "request", "other"])
        let payload = FeedbackPayload(category: .request, body: "Crash on launch", environment: environment)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: String])
        #expect(Set(object.keys) == ["category", "body", "appVersion", "build", "osVersion", "deviceModel", "locale"])
        #expect(object["category"] == "request")
        // One family emoji is one character but 25 bytes, so 2000 of them pass the character limit
        // and still exceed the Worker's 8KB request cap.
        draft.body = String(repeating: "👨‍👩‍👧‍👦", count: 2000)
        #expect(draft.isValid)
        let emoji = FeedbackPayload(category: .bug, body: draft.body, environment: environment)
        #expect(!emoji.fitsRequestLimit, "2000 family emoji exceed the Worker's 8KB request cap")
        let current = FeedbackEnvironment.current(processEnvironment: ["SIMULATOR_MODEL_IDENTIFIER": "iPhone18,2"])
        for value in [current.appVersion, current.build, current.osVersion, current.deviceModel, current.locale] {
            #expect(value.wholeMatch(of: /[A-Za-z0-9 ._,()+-]{1,64}/) != nil, "\(value)")
        }
        #expect(FeedbackEnvironment.sanitized("<@mention>`x`") == "mentionx")
        #expect(FeedbackEnvironment.sanitized("!!!") == "unknown")
        #expect(FeedbackEnvironment.sanitized(String(repeating: "a", count: 80)).count == 64)

        // The host is a plain lower-case host name from the bundled setting; the template ships it empty,
        // so a fresh app hides the entry until the provisioning tool writes the host.
        for host in [nil, "", "https://feedback.example.dev", "feedback", "Feedback.Example.dev", "feedback.example.dev/v1"] {
            #expect(FeedbackConfiguration.endpoint(host: host) == nil, "\(String(describing: host))")
        }
        #expect(FeedbackConfiguration.endpoint(host: "garden-notes-feedback.example.workers.dev")
            == URL(string: "https://garden-notes-feedback.example.workers.dev/v1/feedback"))
        #expect(FeedbackConfiguration.host() == "")
        #expect(FeedbackConfiguration.endpoint() == nil)
        #expect(FeedbackSenderFactory.make(arguments: []) == nil)
        #expect(FeedbackSenderFactory.make(arguments: ["-FeedbackStub", "rate-limited"]) is ScriptedFeedbackSender)

        // Sending: no shared cookies, a JSON POST with a 15 second timeout, and the status mapping.
        let session = FeedbackClient(endpoint: endpoint).session
        #expect(session.configuration.httpCookieStorage !== HTTPCookieStorage.shared)
        #expect(session.configuration.httpShouldSetCookies == false)
        FeedbackURLProtocol.respond = { _ in 201 }
        try await stubbedClient().send(payload)
        let request = try #require(FeedbackURLProtocol.request)
        #expect(request.url == endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 15)
        let sent = try #require(FeedbackURLProtocol.body)
        #expect((try JSONSerialization.jsonObject(with: sent) as? [String: String])?.count == 7)
        FeedbackURLProtocol.respond = { _ in 429 }
        await #expect(throws: FeedbackSendError.rateLimited) { try await stubbedClient().send(payload) }
        for status in [400, 404, 500, 502, 503] {
            FeedbackURLProtocol.respond = { _ in status }
            await #expect(throws: FeedbackSendError.server) { try await stubbedClient().send(payload) }
        }
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost] {
            FeedbackURLProtocol.respond = { _ in throw URLError(code) }
            await #expect(throws: FeedbackSendError.offline) { try await stubbedClient().send(payload) }
        }
        FeedbackURLProtocol.respond = { _ in throw URLError(.badServerResponse) }
        await #expect(throws: FeedbackSendError.server) { try await stubbedClient().send(payload) }
        let scripted = ScriptedFeedbackSender(script: "offline-then-success")
        await #expect(throws: FeedbackSendError.offline) { try await scripted.send(payload) }
        try await scripted.send(payload)

        // The privacy manifest declares the message as Customer Support and the device details as
        // Other Diagnostic Data, unlinked, untracked, for app functionality.
        let manifestURL = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: manifestURL), format: nil) as? [String: Any]
        )
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }) == [
            "NSPrivacyCollectedDataTypeCustomerSupport", "NSPrivacyCollectedDataTypeOtherDiagnosticData",
        ])
        for entry in collected {
            #expect(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == false)
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            #expect(entry["NSPrivacyCollectedDataTypePurposes"] as? [String] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
    }
}

@MainActor
struct LegalLinksTests {
    private func localizedValue(for key: String, language: String) -> String? {
        guard let url = Bundle.main.url(forResource: language, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    @Test("Legal links follow the app slug, stay hidden in the template, and name the feedback recipient")
    func legalLinksFollowTheAppSlug() async throws {
        // D-072 pages from a slug in the same form as Config/app-identity.json.
        let links = try #require(LegalLinks(appSlug: "garden-notes"))
        #expect(links.privacyPolicy == URL(string: "https://app.yutodev.com/apps/garden-notes/privacy/"))
        #expect(links.termsOfUse == URL(string: "https://app.yutodev.com/apps/garden-notes/terms/"))
        #expect(links.support == URL(string: "https://app.yutodev.com/apps/garden-notes/support/"))
        for slug in [nil, "", "Garden", "garden_notes", "-garden", "garden-", "garden--notes", "garden/notes", "a b"] {
            #expect(LegalLinks(appSlug: slug) == nil, "\(String(describing: slug))")
        }

        // The template ships an empty slug, so a fresh app hides the links until its pages exist.
        #expect(LegalLinks.appSlug() == "")
        #expect(LegalLinks.current(arguments: ["App"]) == nil)
        #if DEBUG
        #expect(LegalLinks.current(arguments: ["App", "-LegalLinksAppSlug", "sample-app"]) == LegalLinks(appSlug: "sample-app"))
        #expect(LegalLinks.debugAppSlug(arguments: ["App", "-LegalLinksAppSlug"]) == nil)
        #else
        #expect(LegalLinks.debugAppSlug(arguments: ["App", "-LegalLinksAppSlug", "sample-app"]) == nil)
        #endif

        // Link titles and the feedback note, which names the recipient and keeps what is and is not sent.
        let expected: [String: (en: String, ja: String)] = [
            "legal.privacy-policy": ("Privacy Policy", "プライバシーポリシー"),
            "legal.terms-of-use": ("Terms of Use", "利用規約"),
            "legal.support": ("Support", "サポート")
        ]
        for (key, value) in expected {
            #expect(localizedValue(for: key, language: "en") == value.en)
            #expect(localizedValue(for: key, language: "ja") == value.ja)
        }
        let english = try #require(localizedValue(for: "feedback.disclosure", language: "en"))
        let japanese = try #require(localizedValue(for: "feedback.disclosure", language: "ja"))
        #expect(english.hasPrefix("Sent anonymously to the developer"))
        #expect(english.contains("device model") && english.contains("contact details are not sent"))
        #expect(japanese.hasPrefix("開発者へ匿名で送信します。"))
        #expect(japanese.contains("端末の機種") && japanese.contains("連絡先は送信しません"))

        // The feedback note changed, so the existing feedback checks run here as the regression.
        let feedback = FeedbackTests()
        feedback.feedbackOpensOnLaunchOnlyWhenAsked()
        try await feedback.payloadMatchesWorkerContract()
    }
}

/// Keeps the review prompt's record in memory for the tests.
final class MemoryReviewPromptStore: ReviewPromptStore {
    var record = ReviewPromptRecord()
    func load() -> ReviewPromptRecord { record }
    func save(_ record: ReviewPromptRecord) { self.record = record }
}

/// The review prompt (#383): its rules, settings, answers, wording and App Review Guideline 5.6.1. The
/// runner runs one Unit Test, so the first test calls the others and the existing feedback and legal
/// link checks, whose view the prompt opens.
@MainActor
struct ReviewPromptPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    @Test("The review prompt respects its thresholds, cool-down and stops, and only uses Apple's API")
    func promptRespectsThresholdsAndCooldowns() async throws {
        rulesBlockUntilEveryThresholdIsMet()
        try settingsComeFromTheBundledFile()
        await answersUpdateTheRecordAndOnlyGoodRequestsAReview()
        try wordingIsNeutralInBothLanguages()
        try guidelineAndIdentifiersHold()
        try await LegalLinksTests().legalLinksFollowTheAppSlug()
    }

    private func reason(
        _ record: ReviewPromptRecord,
        config: ReviewPromptConfig = ReviewPromptConfig(),
        days: Double,
        version: String = "1.0",
        suppressed: Bool = false
    ) -> ReviewPromptPolicy.Reason? {
        ReviewPromptPolicy.blockingReason(
            config: config, record: record, now: start.addingTimeInterval(days * day), appVersion: version, suppressed: suppressed
        )
    }

    func rulesBlockUntilEveryThresholdIsMet() {
        let ready = ReviewPromptRecord(launchCount: 5, firstLaunchDate: start, significantEvents: 3)
        #expect(reason(ready, days: 7) == nil)

        // Never on the first launch, even when every threshold is 0.
        let open = ReviewPromptConfig(minimumLaunchCount: 0, minimumDaysSinceFirstLaunch: 0, minimumSignificantEvents: 0)
        #expect(reason(ReviewPromptRecord(launchCount: 1, firstLaunchDate: start), config: open, days: 30) == .firstLaunch)
        #expect(reason(ReviewPromptRecord(launchCount: 2, firstLaunchDate: start), config: open, days: 0) == nil)

        // Each threshold blocks until it is reached.
        var record = ready
        record.launchCount = 4
        #expect(reason(record, days: 7) == .fewLaunches)
        #expect(reason(ready, days: 6.9) == .tooSoonAfterFirstLaunch)
        record = ready
        record.significantEvents = 2
        #expect(reason(record, days: 7) == .fewSignificantEvents)

        // Once per version, and after "Not great" or a close, not again within the cool-down.
        record = ready
        record.lastAskedDate = start.addingTimeInterval(7 * day)
        record.lastAskedVersion = "1.0"
        record.lastAnswer = .negative
        #expect(reason(record, days: 7 + 200) == .alreadyAskedThisVersion)
        #expect(reason(record, config: ReviewPromptConfig(oncePerVersion: false), days: 7 + 200) == nil)
        #expect(reason(record, days: 7 + 119, version: "1.1") == .coolingDown)
        #expect(reason(record, days: 7 + 120, version: "1.1") == nil)

        // Closed without an answer too often: never again.
        record.dismissals = 2
        #expect(reason(record, days: 7 + 200, version: "1.1") == .dismissedTooOften)
        record.dismissals = 1
        #expect(reason(record, days: 7 + 200, version: "1.1") == nil)

        // After "Good" or sent feedback, while the app says "not now", or when turned off: not at all.
        record.stopped = true
        #expect(reason(record, days: 7 + 200, version: "1.1") == .stopped)
        #expect(reason(ready, days: 7, suppressed: true) == .suppressed)
        #expect(reason(ready, config: .disabled, days: 7) == .disabled)
    }

    func settingsComeFromTheBundledFile() throws {
        let full = Data("""
        {"enabled": true, "minimumLaunchCount": 3, "minimumDaysSinceFirstLaunch": 2, "minimumSignificantEvents": 1,
         "cooldownDays": 30, "maximumDismissals": 1, "oncePerVersion": false, "presentationDelaySeconds": 0.5}
        """.utf8)
        #expect(ReviewPromptConfig.decode(full) == ReviewPromptConfig(
            minimumLaunchCount: 3, minimumDaysSinceFirstLaunch: 2, minimumSignificantEvents: 1, cooldownDays: 30,
            maximumDismissals: 1, oncePerVersion: false, presentationDelaySeconds: 0.5
        ))
        // A missing value uses its default.
        #expect(ReviewPromptConfig.decode(Data(#"{"cooldownDays": 30}"#.utf8)) == ReviewPromptConfig(cooldownDays: 30))
        #expect(ReviewPromptConfig.decode(Data("{}".utf8)) == ReviewPromptConfig())
        // A negative number, a wrong type or a broken file turns the prompt off.
        for broken in [#"{"minimumLaunchCount": -1}"#, #"{"cooldownDays": -5}"#, #"{"presentationDelaySeconds": -1}"#,
                       #"{"enabled": "yes"}"#, #"{"maximumDismissals": 1.5}"#, "not json"] {
            #expect(ReviewPromptConfig.decode(Data(broken.utf8)) == .disabled, "\(broken)")
        }
        // The template's own file: on, and with no moments of success to wait for.
        let bundled = ReviewPromptConfig.load()
        #expect(bundled.enabled && bundled.minimumSignificantEvents == 0 && bundled.minimumLaunchCount == 5)
        #expect(bundled.minimumDaysSinceFirstLaunch == 7 && bundled.cooldownDays == 120 && bundled.maximumDismissals == 2)
        #expect(bundled.oncePerVersion && bundled.presentationDelaySeconds == 1.5)
        #expect(ReviewPromptConfig.load(bundle: Bundle(for: MemoryReviewPromptStore.self)) == .disabled)
    }

    func answersUpdateTheRecordAndOnlyGoodRequestsAReview() async {
        var now = start
        let store = MemoryReviewPromptStore()
        let config = ReviewPromptConfig(minimumSignificantEvents: 1, presentationDelaySeconds: 0)
        let center = ReviewPromptCenter(config: config, store: store, appName: "Sample", appVersion: "1.0", now: { now })
        var reviewRequests = 0
        center.requestReview = { reviewRequests += 1 }

        for _ in 0..<5 { center.recordLaunch() }
        #expect(store.record.launchCount == 5 && store.record.firstLaunchDate == start)
        now = start.addingTimeInterval(8 * day)
        await center.presentIfEligible()
        #expect(!center.isPresented, "no moment of success yet")
        center.recordSignificantEvent()
        center.suppress("purchase")
        await center.presentIfEligible()
        #expect(!center.isPresented, "the app said not now")
        center.resume("purchase")
        await center.presentIfEligible()
        #expect(center.isPresented && center.phase == .question)
        #expect(store.record.lastAskedDate == now && store.record.lastAskedVersion == "1.0")

        // Closed without an answer: counted, no review request, and the cool-down starts.
        center.close()
        center.sheetDidDismiss()
        #expect(store.record.dismissals == 1 && reviewRequests == 0)
        #expect(center.blockingReason == .coolingDown)

        // "Not great" offers feedback when the build has it, else the support page, else only a thank-you.
        await center.presentIfEligible(force: true)
        center.answerNegative()
        #expect(center.phase == .followUp && store.record.lastAnswer == .negative)
        #expect(center.followUpActions == [.close])
        let support = URL(string: "https://app.yutodev.com/apps/sample/support/")!
        center.supportURL = support
        #expect(center.followUpActions == [.openSupport(support), .close])
        center.feedbackAvailable = true
        #expect(center.followUpActions == [.sendFeedback, .close])
        center.close()
        center.sheetDidDismiss()
        #expect(store.record.dismissals == 1 && reviewRequests == 0 && !store.record.stopped)

        // Sent feedback stops the prompt.
        await center.presentIfEligible(force: true)
        center.answerNegative()
        center.feedbackSent()
        #expect(store.record.stopped && center.feedbackWasSent && reviewRequests == 0)

        // "Good" closes the sheet first, then asks Apple once, and stops the prompt.
        store.record.stopped = false
        await center.presentIfEligible(force: true)
        center.answerPositive()
        #expect(!center.isPresented && reviewRequests == 0, "the request waits until the sheet has gone")
        center.sheetDidDismiss()
        #expect(reviewRequests == 1 && store.record.stopped && store.record.lastAnswer == .positive)
        center.sheetDidDismiss()
        #expect(reviewRequests == 1)
        now = start.addingTimeInterval(400 * day)
        await center.presentIfEligible()
        #expect(!center.isPresented && center.blockingReason == .stopped)

        // The forced launch argument exists only in Debug builds.
        #if DEBUG
        #expect(ReviewPromptCenter.forcesShow(arguments: ["App", "-ReviewPromptForceShow"]))
        #else
        #expect(!ReviewPromptCenter.forcesShow(arguments: ["App", "-ReviewPromptForceShow"]))
        #endif
        #expect(!ReviewPromptCenter.forcesShow(arguments: ["App"]))
    }

    private func localized(_ key: String, _ language: String) -> String? {
        guard let url = Bundle.main.url(forResource: language, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return nil }
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? nil : value
    }

    func wordingIsNeutralInBothLanguages() throws {
        let expected: [String: (en: String, ja: String)] = [
            "review-prompt.question %@": ("How do you like %@?", "%@はどうですか？"),
            "review-prompt.positive": ("Good", "良い"),
            "review-prompt.negative": ("Not Great", "いまいち"),
            "review-prompt.later": ("Not Now", "あとで"),
            "review-prompt.feedback-invitation": ("If you like, tell us how we could make it better.", "よろしければ、改善のためにご意見をお聞かせください。"),
            "review-prompt.support": ("Open Support Page", "サポートページを開く"),
            "review-prompt.close": ("Close", "閉じる"),
            "review-prompt.thanks": ("Thanks for letting us know.", "お答えいただきありがとうございました。")
        ]
        // Neither a rating nor anything in return is promised for an answer.
        let promises = ["★", "☆", "星", "評価", "レビュー", "特典", "無料", "プレゼント", "ポイント", "クーポン", "お得",
                        "rate", "rating", "review", "star", "reward", "free", "gift", "coupon", "bonus"]
        for (key, value) in expected {
            let english = try #require(localized(key, "en"), "\(key) en")
            let japanese = try #require(localized(key, "ja"), "\(key) ja")
            #expect(english == value.en && japanese == value.ja, "\(key)")
            for text in [english.lowercased(), japanese] {
                #expect(!promises.contains { text.contains($0) }, "\(key): \(text)")
            }
        }
    }

    func guidelineAndIdentifiersHold() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // App Review Guideline 5.6.1 applies to review prompts: Apple's API only.
        let map = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appending(path: ".agents/skills/app-review-guidelines/guidelines.json"))
        ) as? [String: Any]
        let guidelines = try #require(map?["guidelines"] as? [[String: Any]])
        let rule = try #require(guidelines.first { $0["id"] as? String == "5.6.1" })
        #expect(rule["class"] as? String == "triggered")
        #expect((rule["features"] as? [String])?.contains("review-prompts") == true)

        // The prompt asks through `requestReview` and draws no rating of its own; and the new files name no
        // template identifier, so Identity bootstrap needs nothing in them.
        let module = String(reflecting: ReviewPromptCenter.self).split(separator: ".")[0]
        let feature = root.appending(path: "\(module)/Features/ReviewPrompt")
        let sources = try FileManager.default.contentsOfDirectory(at: feature, includingPropertiesForKeys: nil)
        #expect(sources.count == 4)
        var swift = ""
        for file in sources + [root.appending(path: "\(module)UITests/ReviewPromptUITests.swift")] {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(module), "\(file.lastPathComponent)")
            if file.pathExtension == "swift" { swift += text }
        }
        #expect(swift.contains("requestReview()"))
        for custom in ["star.fill", "systemName: \"star", "write-review", "itms-apps"] {
            #expect(!swift.contains(custom), "\(custom)")
        }
    }
}

/// Keeps the onboarding's record in memory for the tests, with an app's earlier completion flags.
final class MemoryOnboardingStore: OnboardingStore {
    var record = OnboardingRecord()
    var flags: [String: Bool] = [:]
    var saves = 0
    func load() -> OnboardingRecord { record }
    func save(_ record: OnboardingRecord) {
        self.record = record
        saves += 1
    }
    func flag(_ key: String) -> Bool { flags[key] ?? false }
    func clear() { record = OnboardingRecord() }
}

/// Stands in for the system's notification request and counts the requests.
final class NotificationRequestStub {
    var requests = 0
    var grants = false

    func request() async -> Bool {
        requests += 1
        return grants
    }
}

/// The first-launch onboarding (#483): the declaration rules, when it shows, the answers, the permission
/// primer, the review prompt, the launch arguments, the wording, and the guidelines. The runner runs one
/// Unit Test, so the first test calls the others.
@MainActor
struct OnboardingPolicyTests {
    private typealias Page = OnboardingConfig.Page
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Onboarding declarations are checked, shown once, answered on the device, and keep the review prompt quiet")
    func configValidationAndCompletion() async throws {
        declarationsBreakingTheRulesTurnItOff()
        shownOnceAndNotAfterCompletionSkipOrAnEarlierOnboarding()
        try answersAreOptionIDsOnly()
        await permissionPrimerNeverBlocksAndSkipNeverAsks()
        reviewPromptIsQuietWhileShown()
        launchArgumentsForTheCaptureAndDebug()
        try bundledDeclarationAndWordingInBothLanguages()
        try guidelinesAndIdentifiersHold()
        recordStaysInUserDefaults()
    }

    // MARK: Declarations

    private func page(
        _ id: String,
        _ kind: OnboardingConfig.PageKind,
        options: [String] = ["one", "two"],
        selection: OnboardingConfig.Selection = .single,
        usedFor: String? = "The home screen's example text."
    ) -> Page {
        var page = Page(id: id, kind: kind, titleKey: "\(id).title", messageKey: "\(id).message")
        switch kind {
        case .choice:
            page.selection = selection
            page.options = options.map { OnboardingConfig.Option(id: $0, titleKey: "\(id).\($0)") }
            page.usedFor = usedFor
        case .permissionPrimer:
            page.permission = .notifications
        case .value, .completion:
            break
        }
        return page
    }

    /// Value, a single-choice question, a notification primer and the completion.
    private var sample: OnboardingConfig {
        OnboardingConfig(pages: [
            page("welcome", .value),
            page("purpose", .choice, options: ["build", "explore", "learn"]),
            page("notify", .permissionPrimer),
            page("done", .completion)
        ])
    }

    private func problems(_ pages: [Page]) -> [OnboardingConfig.Problem] {
        OnboardingConfig(pages: pages).problems(hasKey: { _ in true })
    }

    func declarationsBreakingTheRulesTurnItOff() {
        #expect(sample.problems(hasKey: { _ in true }).isEmpty)
        let welcome = page("welcome", .value)
        let done = page("done", .completion)

        // 3 to 5 pages.
        #expect(problems([welcome, done]) == [.pageCount(2)])
        let six = (1...5).map { page("value-\($0)", .value) } + [done]
        #expect(problems(six) == [.pageCount(6)])
        // At most two questions.
        let questions = [page("q-one", .choice), page("q-two", .choice), page("q-three", .choice)]
        #expect(problems([welcome] + questions + [done]) == [.tooManyChoices(3)])
        // The completion is last, and there is exactly one.
        #expect(problems([welcome, done, page("more", .value)]) == [.lastPageIsNotCompletion])
        #expect(problems([welcome, page("early", .completion), done]) == [.completionCount(2)])
        #expect(problems([welcome, page("more", .value), page("again", .value)])
            == [.lastPageIsNotCompletion, .completionCount(0)])
        // Ids are stable lower-case and do not repeat.
        #expect(problems([welcome, page("welcome", .value), done]) == [.duplicateID("welcome")])
        #expect(problems([page("Welcome", .value), page("next", .value), done]) == [.invalidID("Welcome")])
        // A question says where its answer is used, offers 2 to 6 options and says single or multiple.
        #expect(problems([welcome, page("purpose", .choice, usedFor: "  "), done]) == [.emptyUsedFor("purpose")])
        #expect(problems([welcome, page("purpose", .choice, usedFor: nil), done]) == [.emptyUsedFor("purpose")])
        #expect(problems([welcome, page("purpose", .choice, options: ["only"]), done]) == [.optionCount("purpose", 1)])
        var noSelection = page("purpose", .choice)
        noSelection.selection = nil
        #expect(problems([welcome, noSelection, done]) == [.missingSelection("purpose")])
        var noPermission = page("notify", .permissionPrimer)
        noPermission.permission = nil
        #expect(problems([welcome, noPermission, done]) == [.missingPermission("notify")])
        // Every wording key is in the string catalog.
        #expect(sample.problems(hasKey: { $0 != "purpose.explore" }) == [.missingKey("purpose.explore")])

        // A broken or out-of-range file turns the onboarding off instead of stopping the app.
        let decode = { (json: String) in OnboardingConfig.decode(Data(json.utf8), hasKey: { _ in true }) }
        #expect(decode("not json") == .failure(OnboardingConfig.Invalid(problems: [.unreadable])))
        #expect(decode(#"{"enabled": true, "pages": [{"id": "a", "kind": "story", "titleKey": "t", "messageKey": "m"}]}"#)
            == .failure(OnboardingConfig.Invalid(problems: [.unreadable])))
        #expect(decode(#"{"enabled": true, "pages": []}"#)
            == .failure(OnboardingConfig.Invalid(problems: [.pageCount(0), .lastPageIsNotCompletion, .completionCount(0)])))
        #expect(decode(#"{"enabled": false, "pages": []}"#) == .success(.disabled))
        let valid = #"""
        {"enabled": true, "version": 2, "legacyCompletionKeys": ["hasCompletedOnboarding"], "pages": [
          {"id": "welcome", "kind": "value", "titleKey": "a", "messageKey": "b"},
          {"id": "notify", "kind": "permissionPrimer", "permission": "notifications", "titleKey": "c", "messageKey": "d"},
          {"id": "done", "kind": "completion", "titleKey": "e", "messageKey": "f"}]}
        """#
        let decoded = try? decode(valid).get()
        #expect(decoded?.version == 2 && decoded?.pages.map(\.id) == ["welcome", "notify", "done"])
        #expect(decoded?.legacyCompletionKeys == ["hasCompletedOnboarding"])

        var reports: [String] = []
        let missing = OnboardingConfig.load(bundle: Bundle(for: MemoryOnboardingStore.self), report: { reports.append($0) })
        #expect(missing == .disabled && reports.count == 1)
        #expect(!OnboardingCenter(config: .disabled, store: MemoryOnboardingStore()).shouldPresent)
    }

    // MARK: When it shows

    func shownOnceAndNotAfterCompletionSkipOrAnEarlierOnboarding() {
        // Shown at the first launch, and recorded once finished.
        let store = MemoryOnboardingStore()
        let center = OnboardingCenter(config: sample, store: store, now: { self.start })
        #expect(center.shouldPresent)
        center.start(reviewPrompt: nil)
        #expect(center.isPresented && center.currentIndex == 0 && center.showsSkip && !center.showsBack)
        center.skip()
        #expect(!center.isPresented && store.record.completedAt == start && store.record.configVersion == 1)
        #expect(!center.shouldPresent && !OnboardingCenter(config: sample, store: store).shouldPresent)
        let later = OnboardingCenter(config: sample, store: store)
        later.start(reviewPrompt: nil)
        #expect(!later.isPresented)

        // "Get Started" also finishes it; the last page has Back but no Skip.
        let finished = MemoryOnboardingStore()
        let flow = OnboardingCenter(config: sample, store: finished, now: { self.start })
        flow.start(reviewPrompt: nil)
        flow.next()
        flow.select("build", on: "purpose")
        flow.next()
        flow.declinePermission()
        #expect(flow.currentPage?.kind == .completion && !flow.showsSkip && flow.showsBack)
        flow.next()
        #expect(!flow.isPresented && finished.record.completedAt == start)
        #expect(!OnboardingCenter(config: sample, store: finished).shouldPresent)

        // An app's earlier onboarding counts as finished.
        var adopted = sample
        adopted.legacyCompletionKeys = ["hasCompletedOnboarding", "onboarding.hintsShown"]
        let legacy = MemoryOnboardingStore()
        #expect(OnboardingCenter(config: adopted, store: legacy).shouldPresent)
        legacy.flags["onboarding.hintsShown"] = true
        #expect(!OnboardingCenter(config: adopted, store: legacy).shouldPresent)

        // Turned off: never shown.
        var off = sample
        off.enabled = false
        #expect(!OnboardingCenter(config: off, store: MemoryOnboardingStore()).shouldPresent)

        // reset() (Debug and tests) shows it again; -OnboardingForceShow shows it even when finished.
        center.reset()
        #expect(center.shouldPresent && store.record == OnboardingRecord() && center.answers(for: "purpose").isEmpty)
        let forced = OnboardingCenter(config: sample, store: finished, launch: OnboardingLaunchArguments(mode: .forceShow))
        #expect(forced.shouldPresent)
    }

    // MARK: Answers

    func answersAreOptionIDsOnly() throws {
        var pages = sample.pages
        pages[2] = page("topics", .choice, options: ["daily", "weekly", "monthly"], selection: .multiple)
        let config = OnboardingConfig(pages: pages)
        #expect(config.problems(hasKey: { _ in true }).isEmpty)

        let store = MemoryOnboardingStore()
        let center = OnboardingCenter(config: config, store: store, now: { self.start })
        var received: [OnboardingAnswers] = []
        center.onCompleted = { received.append($0) }
        center.start(reviewPrompt: nil)
        center.next()
        // "Next" waits for an answer.
        #expect(!center.canAdvance && center.showsSkip)
        center.next()
        #expect(center.currentIndex == 1)
        // A question stops the forward swipe; Back and the swipe back still work.
        #expect(center.swipeLimit == 1)
        center.go(to: 2)
        #expect(center.currentIndex == 1)
        center.select("explore", on: "purpose")
        center.select("learn", on: "purpose")
        center.select("unknown", on: "purpose")
        #expect(center.isSelected("learn", on: "purpose") && !center.isSelected("explore", on: "purpose"))
        #expect(center.canAdvance)
        center.go(to: 2)
        #expect(center.currentIndex == 1)
        center.next()
        center.select("weekly", on: "topics")
        center.select("daily", on: "topics")
        center.select("monthly", on: "topics")
        center.select("weekly", on: "topics")
        center.next()
        center.next()

        let expected = OnboardingAnswers(selections: ["purpose": ["learn"], "topics": ["daily", "monthly"]], skipped: false)
        #expect(received == [expected])
        #expect(store.record.answers == expected.selections)
        #expect(center.answers(for: "purpose") == ["learn"] && center.answers(for: "topics") == ["daily", "monthly"])
        #expect(center.answers(for: "welcome").isEmpty)
        #expect(OnboardingCenter(config: config, store: store).answers(for: "topics") == ["daily", "monthly"])

        // After Skip, only the questions answered with "Next" are handed over.
        let skipStore = MemoryOnboardingStore()
        let skipping = OnboardingCenter(config: config, store: skipStore)
        skipping.onCompleted = { received.append($0) }
        skipping.start(reviewPrompt: nil)
        skipping.next()
        skipping.select("build", on: "purpose")
        skipping.next()
        skipping.select("daily", on: "topics")
        skipping.skip()
        #expect(received.last == OnboardingAnswers(selections: ["purpose": ["build"]], skipped: true))
        #expect(skipStore.record.answers == ["purpose": ["build"]] && skipStore.record.completedAt != nil)

        // Skip on the first page: nothing answered.
        let early = OnboardingCenter(config: config, store: MemoryOnboardingStore())
        early.onCompleted = { received.append($0) }
        early.start(reviewPrompt: nil)
        early.skip()
        #expect(received.last == OnboardingAnswers(selections: [:], skipped: true))

        // The record holds the time, the version and option ids, and nothing else.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.record)) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["completedAt", "configVersion", "answers"])
    }

    // MARK: Permission primer

    func permissionPrimerNeverBlocksAndSkipNeverAsks() async {
        let stub = NotificationRequestStub()
        func makeCenter() -> OnboardingCenter {
            let center = OnboardingCenter(config: sample, store: MemoryOnboardingStore(), requestNotificationAuthorization: stub.request)
            center.start(reviewPrompt: nil)
            center.next()
            center.select("build", on: "purpose")
            center.next()
            return center
        }

        // "Not Now" moves on without the system's dialog.
        let later = makeCenter()
        #expect(later.currentPage?.kind == .permissionPrimer)
        later.declinePermission()
        #expect(later.currentIndex == 3 && stub.requests == 0)

        // A no to the system's request keeps the page with its note, and "Next" moves on.
        let denied = makeCenter()
        stub.grants = false
        await denied.allowPermission()
        #expect(stub.requests == 1 && denied.currentIndex == 2 && denied.isPermissionDenied(on: "notify"))
        #expect(denied.canAdvance)
        denied.next()
        #expect(denied.currentIndex == 3)

        // A yes moves on by itself.
        let allowed = makeCenter()
        stub.grants = true
        await allowed.allowPermission()
        #expect(stub.requests == 2 && allowed.currentIndex == 3 && !allowed.isPermissionDenied(on: "notify"))

        // Skip, on the primer or anywhere else, never asks.
        let skipped = makeCenter()
        skipped.skip()
        let first = OnboardingCenter(config: sample, store: MemoryOnboardingStore(), requestNotificationAuthorization: stub.request)
        first.start(reviewPrompt: nil)
        first.skip()
        #expect(stub.requests == 2 && !skipped.isPresented && !first.isPresented)
    }

    // MARK: Review prompt

    func reviewPromptIsQuietWhileShown() {
        let review = ReviewPromptCenter(
            config: ReviewPromptConfig(), store: MemoryReviewPromptStore(), appName: "Sample", appVersion: "1.0"
        )
        let center = OnboardingCenter(config: sample, store: MemoryOnboardingStore())
        center.start(reviewPrompt: review)
        #expect(center.isPresented && review.isSuppressed && review.blockingReason == .suppressed)
        center.skip()
        #expect(!review.isSuppressed)

        // Another reason the app gave stays in place.
        review.suppress("purchase")
        let again = OnboardingCenter(config: sample, store: MemoryOnboardingStore())
        again.start(reviewPrompt: review)
        finishFromCurrentPage(again)
        #expect(!again.isPresented && review.isSuppressed)
        review.resume("purchase")

        // Not shown: the review prompt is not touched.
        let finished = MemoryOnboardingStore()
        finished.record.completedAt = start
        OnboardingCenter(config: sample, store: finished).start(reviewPrompt: review)
        #expect(!review.isSuppressed)
    }

    private func finishFromCurrentPage(_ center: OnboardingCenter) {
        center.next()
        center.select("explore", on: "purpose")
        center.next()
        center.declinePermission()
        center.next()
    }

    // MARK: Launch arguments

    func launchArgumentsForTheCaptureAndDebug() {
        typealias Arguments = OnboardingLaunchArguments
        // The capture's arguments work in every build configuration.
        for debug in [true, false] {
            #expect(Arguments(arguments: ["App", "--appstore-screenshot", "--fixture", "primary"], allowsDebugArguments: debug).mode
                == .appStoreScreenshot(pageID: nil))
            #expect(Arguments(arguments: ["App", "--appstore-screenshot", "--onboarding-page", "purpose"], allowsDebugArguments: debug).mode
                == .appStoreScreenshot(pageID: "purpose"))
            #expect(Arguments(arguments: ["App", "--appstore-screenshot", "-OnboardingForceShow"], allowsDebugArguments: debug).mode
                == .appStoreScreenshot(pageID: nil))
        }
        // -OnboardingSkip and -OnboardingForceShow only in Debug builds.
        #expect(Arguments(arguments: ["App", "-OnboardingSkip"], allowsDebugArguments: true).mode == .skip)
        #expect(Arguments(arguments: ["App", "-OnboardingForceShow"], allowsDebugArguments: true).mode == .forceShow)
        #expect(Arguments(arguments: ["App", "-OnboardingSkip"], allowsDebugArguments: false).mode == .normal)
        #expect(Arguments(arguments: ["App", "-OnboardingForceShow"], allowsDebugArguments: false).mode == .normal)
        #expect(Arguments(arguments: ["App", "--onboarding-page", "purpose"]).mode == .normal)
        #expect(Arguments(arguments: ["App"]).mode == .normal)
        #if DEBUG
        #expect(Arguments.allowsDebugArguments)
        #else
        #expect(!Arguments.allowsDebugArguments)
        #endif

        // The capture: not shown and nothing recorded.
        let store = MemoryOnboardingStore()
        let capture = OnboardingCenter(config: sample, store: store, launch: Arguments(mode: .appStoreScreenshot(pageID: nil)))
        #expect(!capture.shouldPresent)
        capture.start(reviewPrompt: nil)
        #expect(!capture.isPresented && store.saves == 0)

        // The capture of a page: that page, and still nothing recorded.
        var handed: OnboardingAnswers?
        let page = OnboardingCenter(config: sample, store: store, launch: Arguments(mode: .appStoreScreenshot(pageID: "purpose")))
        page.onCompleted = { handed = $0 }
        page.start(reviewPrompt: nil)
        #expect(page.isPresented && page.currentIndex == 1)
        page.select("learn", on: "purpose")
        page.next()
        page.declinePermission()
        page.next()
        #expect(!page.isPresented && store.saves == 0 && store.record == OnboardingRecord())
        #expect(handed?.optionIDs(for: "purpose") == ["learn"])
        #expect(!OnboardingCenter(config: sample, store: store, launch: Arguments(mode: .appStoreScreenshot(pageID: "missing"))).shouldPresent)

        // -OnboardingSkip: treated as finished, nothing recorded.
        let skipping = OnboardingCenter(config: sample, store: store, launch: Arguments(mode: .skip))
        skipping.start(reviewPrompt: nil)
        #expect(!skipping.isPresented && store.saves == 0)
    }

    // MARK: Wording

    private func localized(_ key: String, _ language: String) -> String? {
        guard let url = Bundle.main.url(forResource: language, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return nil }
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? nil : value
    }

    func bundledDeclarationAndWordingInBothLanguages() throws {
        // The template's sample: welcome, one single-choice question used on the root screen, done.
        var reports: [String] = []
        let bundled = OnboardingConfig.load(report: { reports.append($0) })
        #expect(reports.isEmpty)
        #expect(bundled.enabled && bundled.version == 1 && bundled.legacyCompletionKeys.isEmpty)
        #expect(bundled.pages.map(\.id) == ["welcome", "purpose", "done"])
        #expect(bundled.pages.map(\.kind) == [.value, .choice, .completion])
        let purpose = try #require(bundled.pages.first { $0.id == "purpose" })
        #expect(purpose.selection == .single && purpose.options?.map(\.id) == ["build", "explore", "learn"])
        #expect(!(purpose.usedFor ?? "").isEmpty)
        for option in purpose.options ?? [] {
            #expect(ContentView.purposeLine(option.id) != nil, "\(option.id)")
        }

        // Every key of the declaration, the controls and VoiceOver, in English and Japanese.
        var keys = bundled.pages.flatMap { [$0.titleKey, $0.messageKey] + ($0.options ?? []).map(\.titleKey) }
        keys += purpose.options?.map { "onboarding.sample.purpose-line.\($0.id)" } ?? []
        let expected: [String: (en: String, ja: String)] = [
            "onboarding.skip": ("Skip", "スキップ"),
            "onboarding.skip.accessibility": ("Skip onboarding", "オンボーディングをスキップ"),
            "onboarding.back": ("Back", "戻る"),
            "onboarding.back.accessibility": ("Go back to the previous page", "前のページへ戻る"),
            "onboarding.next": ("Next", "次へ"),
            "onboarding.start": ("Get Started", "はじめる"),
            "onboarding.permission.allow": ("Allow Notifications", "通知を許可する"),
            "onboarding.permission.later": ("Not Now", "今はしない"),
            "onboarding.sample.purpose.title": ("What will you do first?", "まず何をしますか？"),
            "onboarding.sample.done.title": ("You're all set", "準備ができました")
        ]
        for key in keys + Array(expected.keys) + ["onboarding.permission.denied"] {
            let english = try #require(localized(key, "en"), "\(key) en")
            let japanese = try #require(localized(key, "ja"), "\(key) ja")
            if let value = expected[key] {
                #expect(english == value.en && japanese == value.ja, "\(key)")
            }
        }
        // VoiceOver reads the page position as text.
        let position = "onboarding.position %lld %lld"
        let english = try #require(localized(position, "en"))
        let japanese = try #require(localized(position, "ja"))
        #expect(String(format: english, 2, 4) == "Page 2 of 4")
        #expect(String(format: japanese, 2, 4) == "4ページ中2ページ目")
    }

    // MARK: Guidelines and identifiers

    func guidelinesAndIdentifiersHold() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // App Review Guidelines 5.1.1(iii), (iv), (vi) and 4.5.4 apply to the permission primer and the answers.
        let map = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appending(path: ".agents/skills/app-review-guidelines/guidelines.json"))
        ) as? [String: Any]
        let guidelines = try #require(map?["guidelines"] as? [[String: Any]])
        for id in ["5.1.1(iii)", "5.1.1(iv)", "5.1.1(vi)", "4.5.4"] {
            #expect(guidelines.contains { $0["id"] as? String == id }, "\(id)")
        }

        // The component asks only for notifications, sends nothing anywhere, and names no template identifier,
        // so Identity bootstrap needs nothing in its files.
        let module = String(reflecting: OnboardingCenter.self).split(separator: ".")[0]
        let feature = root.appending(path: "\(module)/Features/Onboarding")
        let sources = try FileManager.default.contentsOfDirectory(at: feature, includingPropertiesForKeys: nil)
        #expect(Set(sources.map(\.lastPathComponent)) == [
            "OnboardingCenter.swift", "OnboardingConfig.json", "OnboardingConfig.swift", "OnboardingLaunchArguments.swift",
            "OnboardingStore.swift", "OnboardingView.swift"
        ])
        var swift = ""
        for file in sources + [root.appending(path: "\(module)UITests/OnboardingUITests.swift")] {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(module), "\(file.lastPathComponent)")
            #expect(!text.contains("template."), "\(file.lastPathComponent)")
            if file.pathExtension == "swift" { swift += text }
        }
        #expect(swift.components(separatedBy: "requestAuthorization(").count == 2)
        for other in ["URLSession", "URLRequest", "http://", "https://", "CLLocationManager", "AVCaptureDevice",
                      "PHPhotoLibrary", "CNContactStore", "ATTrackingManager", "EKEventStore"] {
            #expect(!swift.contains(other), "\(other)")
        }

        // Derived apps find the guide, and the repository tests own it.
        let guide = try String(contentsOf: root.appending(path: "docs/onboarding.md"), encoding: .utf8)
        #expect(guide.contains("OnboardingConfig.json") && guide.contains("legacyCompletionKeys") && guide.contains("usedFor"))
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appending(path: "Config/repository-tests.json"))
        ) as? [String: Any]
        let rules = try #require(manifest?["domainRules"] as? [[String: Any]])
        #expect(rules.contains { ($0["paths"] as? [String])?.contains("docs/onboarding.md") == true })
    }

    // MARK: Store

    func recordStaysInUserDefaults() {
        let suite = "onboarding-policy-tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsOnboardingStore(defaults: defaults)
        #expect(store.load() == OnboardingRecord())
        let record = OnboardingRecord(completedAt: start, configVersion: 3, answers: ["purpose": ["build"]])
        store.save(record)
        #expect(UserDefaultsOnboardingStore(defaults: defaults).load() == record)
        defaults.set(true, forKey: "hasCompletedOnboarding")
        #expect(store.flag("hasCompletedOnboarding") && !store.flag("onboarding.hintsShown"))
        store.clear()
        #expect(store.load() == OnboardingRecord())
    }
}
