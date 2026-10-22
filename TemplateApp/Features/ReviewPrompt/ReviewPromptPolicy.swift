import Foundation

/// When the app may ask "How do you like <app>?" (#383). Every value comes from the bundled
/// `ReviewPromptConfig.json`, so each app tunes it; a missing value uses the default below, and a file
/// that is missing, malformed or has a negative value turns the prompt off.
nonisolated struct ReviewPromptConfig: Equatable, Sendable {
    static let resourceName = "ReviewPromptConfig"

    var enabled = true
    /// Asked only from this launch on, and never on the first launch.
    var minimumLaunchCount = 5
    var minimumDaysSinceFirstLaunch = 7
    /// Moments of success the app reports; 0 when the app reports none (the template).
    var minimumSignificantEvents = 3
    /// After "Not great" without feedback, or a close without an answer.
    var cooldownDays = 120
    /// After this many closes without an answer, never asked again.
    var maximumDismissals = 2
    var oncePerVersion = true
    /// The pause between the moment of success and the question.
    var presentationDelaySeconds = 1.5

    static let disabled = ReviewPromptConfig(enabled: false)

    private struct Settings: Decodable {
        let enabled: Bool?
        let minimumLaunchCount: Int?
        let minimumDaysSinceFirstLaunch: Int?
        let minimumSignificantEvents: Int?
        let cooldownDays: Int?
        let maximumDismissals: Int?
        let oncePerVersion: Bool?
        let presentationDelaySeconds: Double?
    }

    static func load(bundle: Bundle = .main) -> ReviewPromptConfig {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .disabled }
        return decode(data)
    }

    static func decode(_ data: Data) -> ReviewPromptConfig {
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return .disabled }
        var config = ReviewPromptConfig()
        config.enabled = settings.enabled ?? config.enabled
        config.minimumLaunchCount = settings.minimumLaunchCount ?? config.minimumLaunchCount
        config.minimumDaysSinceFirstLaunch = settings.minimumDaysSinceFirstLaunch ?? config.minimumDaysSinceFirstLaunch
        config.minimumSignificantEvents = settings.minimumSignificantEvents ?? config.minimumSignificantEvents
        config.cooldownDays = settings.cooldownDays ?? config.cooldownDays
        config.maximumDismissals = settings.maximumDismissals ?? config.maximumDismissals
        config.oncePerVersion = settings.oncePerVersion ?? config.oncePerVersion
        config.presentationDelaySeconds = settings.presentationDelaySeconds ?? config.presentationDelaySeconds
        let counts = [config.minimumLaunchCount, config.minimumDaysSinceFirstLaunch, config.minimumSignificantEvents,
                      config.cooldownDays, config.maximumDismissals]
        guard counts.allSatisfy({ $0 >= 0 }), config.presentationDelaySeconds.isFinite,
              config.presentationDelaySeconds >= 0 else { return .disabled }
        return config
    }
}

/// What the prompt remembers, on this device only: counts and dates, never the app's data or anything
/// about the person.
nonisolated struct ReviewPromptRecord: Codable, Equatable, Sendable {
    enum Answer: String, Codable, Sendable {
        case positive
        case negative
    }

    var launchCount = 0
    var firstLaunchDate: Date?
    var significantEvents = 0
    var lastAskedDate: Date?
    var lastAskedVersion: String?
    var dismissals = 0
    var lastAnswer: Answer?
    /// Set after "Good" or sent feedback: never asked again.
    var stopped = false
}

protocol ReviewPromptStore: AnyObject {
    func load() -> ReviewPromptRecord
    func save(_ record: ReviewPromptRecord)
}

/// Keeps the record as one value in `UserDefaults`.
final class UserDefaultsReviewPromptStore: ReviewPromptStore {
    static let key = "reviewPrompt.record"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ReviewPromptRecord {
        guard let data = defaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(ReviewPromptRecord.self, from: data) else { return ReviewPromptRecord() }
        return record
    }

    func save(_ record: ReviewPromptRecord) {
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// The rules, as a pure function of the settings, the record, the time, the app version and whether the
/// app says "not now": nil means the question may be shown.
nonisolated enum ReviewPromptPolicy {
    enum Reason: Equatable, Sendable {
        case disabled
        case stopped
        case suppressed
        case firstLaunch
        case fewLaunches
        case tooSoonAfterFirstLaunch
        case fewSignificantEvents
        case dismissedTooOften
        case coolingDown
        case alreadyAskedThisVersion
    }

    private static let day: TimeInterval = 24 * 60 * 60

    static func blockingReason(
        config: ReviewPromptConfig,
        record: ReviewPromptRecord,
        now: Date,
        appVersion: String,
        suppressed: Bool
    ) -> Reason? {
        guard config.enabled else { return .disabled }
        guard !record.stopped else { return .stopped }
        guard !suppressed else { return .suppressed }
        guard record.launchCount > 1 else { return .firstLaunch }
        guard record.launchCount >= config.minimumLaunchCount else { return .fewLaunches }
        guard let firstLaunch = record.firstLaunchDate,
              now.timeIntervalSince(firstLaunch) >= TimeInterval(config.minimumDaysSinceFirstLaunch) * day else {
            return .tooSoonAfterFirstLaunch
        }
        guard record.significantEvents >= config.minimumSignificantEvents else { return .fewSignificantEvents }
        guard record.dismissals < config.maximumDismissals else { return .dismissedTooOften }
        if let lastAsked = record.lastAskedDate, now.timeIntervalSince(lastAsked) < TimeInterval(config.cooldownDays) * day {
            return .coolingDown
        }
        if config.oncePerVersion, record.lastAskedVersion == appVersion { return .alreadyAskedThisVersion }
        return nil
    }
}
