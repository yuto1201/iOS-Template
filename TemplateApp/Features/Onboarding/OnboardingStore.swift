import Foundation

/// What the onboarding remembers, on this device only: whether and when it was finished, the version of the
/// declaration at that time, and the option ids the person chose. Nothing is sent anywhere, and nothing
/// about the person is written (App Review Guideline 5.1.1).
nonisolated struct OnboardingRecord: Codable, Equatable, Sendable {
    var completedAt: Date?
    var configVersion: Int?
    /// Page id to the chosen option ids, in the order the page declares them.
    var answers: [String: [String]] = [:]
}

/// The answers handed to the app: only option ids, never free text.
nonisolated struct OnboardingAnswers: Equatable, Sendable {
    /// Page id to the chosen option ids. A question that was not answered has no entry.
    var selections: [String: [String]] = [:]
    /// True when the person left with Skip.
    var skipped = false

    func optionIDs(for pageID: String) -> [String] {
        selections[pageID] ?? []
    }
}

protocol OnboardingStore: AnyObject {
    func load() -> OnboardingRecord
    func save(_ record: OnboardingRecord)
    /// An app's earlier completion flag (`legacyCompletionKeys`).
    func flag(_ key: String) -> Bool
    /// Debug and tests: forget the record.
    func clear()
}

/// Keeps the record as one value in `UserDefaults`.
final class UserDefaultsOnboardingStore: OnboardingStore {
    static let key = "onboarding.record"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> OnboardingRecord {
        guard let data = defaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(OnboardingRecord.self, from: data) else { return OnboardingRecord() }
        return record
    }

    func save(_ record: OnboardingRecord) {
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func flag(_ key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
