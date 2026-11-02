import Foundation

/// The first-launch onboarding (#483, D-099): the pages the app declares in the bundled
/// `OnboardingConfig.json`. Each app writes its own pages; the component shows them in the page-turn
/// direction the person chose (OB-A, D-102). A file that is missing, malformed or breaks a rule turns the
/// onboarding off instead of stopping the app, and a Debug build reports it with an assertion.
/// See docs/onboarding.md.
nonisolated struct OnboardingConfig: Equatable, Sendable {
    static let resourceName = "OnboardingConfig"
    static let pageCountRange = 3...5
    static let maximumChoicePages = 2
    static let optionCountRange = 2...6

    enum PageKind: String, Codable, Sendable {
        /// Explains one value of the app.
        case value
        /// Asks one question; the answer is used in the app (`usedFor`).
        case choice
        /// Explains a permission before the system asks for it.
        case permissionPrimer
        /// The last page: "Get Started".
        case completion
    }

    enum Selection: String, Codable, Sendable {
        case single
        case multiple
    }

    /// The permissions a primer may ask for. Only notifications for now (#483). The template does not use
    /// notifications (D-068), so an app that adopts them supplies the request; see docs/onboarding.md.
    enum Permission: String, Codable, Sendable {
        case notifications
    }

    struct Option: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var titleKey: String
        var subtitleKey: String?
        /// An image in the Asset Catalog.
        var imageName: String?
    }

    struct Page: Codable, Equatable, Identifiable, Sendable {
        /// Stable lower-case id; answers are stored under it.
        var id: String
        var kind: PageKind
        var titleKey: String
        var messageKey: String
        /// An image in the Asset Catalog; without one, the page shows a symbol for its kind.
        var imageName: String?
        var selection: Selection?
        var options: [Option]?
        /// Where the app uses the answer. A question whose answer the app does not use is not allowed.
        var usedFor: String?
        var permission: Permission?
    }

    /// One way a declaration breaks the rules (D-099).
    enum Problem: Equatable, Sendable {
        case unreadable
        case version
        case pageCount(Int)
        case tooManyChoices(Int)
        case lastPageIsNotCompletion
        case completionCount(Int)
        case invalidID(String)
        case duplicateID(String)
        case missingSelection(String)
        case optionCount(String, Int)
        case emptyUsedFor(String)
        case missingPermission(String)
        /// A primer for a permission the app does not request (it supplied no request for it).
        case permissionUnavailable(String)
        case missingKey(String)
    }

    var enabled = true
    /// Recorded with the completion, so an app can tell which declaration the person went through. 1 when
    /// the file leaves it out.
    var version = 1
    var pages: [Page] = []
    /// Completion flags of an app's earlier onboarding in `UserDefaults` (for example
    /// `hasCompletedOnboarding`). When any of them is `true`, the person has finished it already.
    var legacyCompletionKeys: [String] = []

    static let disabled = OnboardingConfig(enabled: false)

    private struct Settings: Decodable {
        let enabled: Bool
        let version: Int?
        let pages: [Page]
        let legacyCompletionKeys: [String]?
    }

    /// The bundled declaration, or `disabled` when it is missing or breaks a rule. `report` is an
    /// assertion, so a Debug build stops at a broken declaration; tests replace it.
    static func load(
        bundle: Bundle = .main,
        availablePermissions: Set<Permission> = [],
        report: (String) -> Void = { assertionFailure($0) }
    ) -> OnboardingConfig {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            report("\(resourceName).json is missing; onboarding is off.")
            return .disabled
        }
        switch decode(data, availablePermissions: availablePermissions, hasKey: { hasLocalization($0, in: bundle) }) {
        case .success(let config):
            return config
        case .failure(let invalid):
            report("\(resourceName).json breaks the onboarding rules \(invalid.problems); onboarding is off.")
            return .disabled
        }
    }

    struct Invalid: Error, Equatable {
        let problems: [Problem]
    }

    /// Decodes and checks a declaration. A declaration with `enabled: false` is accepted as off.
    static func decode(
        _ data: Data,
        availablePermissions: Set<Permission> = [],
        hasKey: (String) -> Bool
    ) -> Result<OnboardingConfig, Invalid> {
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return .failure(Invalid(problems: [.unreadable]))
        }
        let config = OnboardingConfig(
            enabled: settings.enabled,
            version: settings.version ?? 1,
            pages: settings.pages,
            legacyCompletionKeys: settings.legacyCompletionKeys ?? []
        )
        guard config.enabled else { return .success(.disabled) }
        let problems = config.problems(availablePermissions: availablePermissions, hasKey: hasKey)
        return problems.isEmpty ? .success(config) : .failure(Invalid(problems: problems))
    }

    /// Every rule the declaration breaks; empty when it may be shown. `availablePermissions` are the
    /// permissions the app supplied a request for.
    func problems(availablePermissions: Set<Permission> = [], hasKey: (String) -> Bool) -> [Problem] {
        var problems: [Problem] = []
        if version < 1 { problems.append(.version) }
        if !Self.pageCountRange.contains(pages.count) { problems.append(.pageCount(pages.count)) }
        let choices = pages.filter { $0.kind == .choice }.count
        if choices > Self.maximumChoicePages { problems.append(.tooManyChoices(choices)) }
        if pages.last?.kind != .completion { problems.append(.lastPageIsNotCompletion) }
        let completions = pages.filter { $0.kind == .completion }.count
        if completions != 1 { problems.append(.completionCount(completions)) }

        var pageIDs = Set<String>()
        var keys: [String] = []
        for page in pages {
            if !Self.isValidID(page.id) { problems.append(.invalidID(page.id)) }
            if !pageIDs.insert(page.id).inserted { problems.append(.duplicateID(page.id)) }
            keys += [page.titleKey, page.messageKey]
            switch page.kind {
            case .choice:
                if page.selection == nil { problems.append(.missingSelection(page.id)) }
                let options = page.options ?? []
                if !Self.optionCountRange.contains(options.count) {
                    problems.append(.optionCount(page.id, options.count))
                }
                var optionIDs = Set<String>()
                for option in options {
                    if !Self.isValidID(option.id) { problems.append(.invalidID("\(page.id).\(option.id)")) }
                    if !optionIDs.insert(option.id).inserted { problems.append(.duplicateID("\(page.id).\(option.id)")) }
                    keys.append(option.titleKey)
                    if let subtitleKey = option.subtitleKey { keys.append(subtitleKey) }
                }
                if (page.usedFor ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    problems.append(.emptyUsedFor(page.id))
                }
            case .permissionPrimer:
                if let permission = page.permission {
                    if !availablePermissions.contains(permission) { problems.append(.permissionUnavailable(page.id)) }
                } else {
                    problems.append(.missingPermission(page.id))
                }
            case .value, .completion:
                break
            }
        }
        for key in keys where !hasKey(key) {
            problems.append(.missingKey(key))
        }
        return problems
    }

    /// Lower-case letters and digits, joined by single hyphens, starting with a letter.
    static func isValidID(_ id: String) -> Bool {
        id.wholeMatch(of: /[a-z][a-z0-9]*(-[a-z0-9]+)*/) != nil
    }

    /// Whether the app's string catalog has the key in the current language.
    static func hasLocalization(_ key: String, in bundle: Bundle) -> Bool {
        let missing = "\u{1}missing\u{1}"
        return bundle.localizedString(forKey: key, value: missing, table: nil) != missing
    }
}
