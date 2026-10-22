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
