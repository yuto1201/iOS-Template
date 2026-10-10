import Foundation

enum FeedbackCategory: String, CaseIterable, Identifiable, Encodable {
    case bug, request, other

    var id: Self { self }
}

/// What the user typed. The feedback Worker applies the same limits (D-076).
struct FeedbackDraft: Equatable {
    static let maxBodyCount = 2000

    var category: FeedbackCategory = .bug
    var body = ""

    private var trimmedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }
    var bodyCount: Int { trimmedBody.count }
    var isValid: Bool { (1...Self.maxBodyCount).contains(bodyCount) }

    func validatedBody() -> String? { isValid ? trimmedBody : nil }
}

/// The device details sent with feedback. No identifiers, no app data, no contact details.
struct FeedbackEnvironment: Equatable {
    let appVersion: String
    let build: String
    let osVersion: String
    let deviceModel: String
    let locale: String

    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._,()+-"
    )

    static func current(
        bundle: Bundle = .main,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        locale: Locale = .current,
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Self {
        let version = operatingSystem.patchVersion == 0
            ? "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion)"
            : "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)"
        return Self(
            appVersion: sanitized(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
            build: sanitized(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
            osVersion: sanitized(version),
            deviceModel: sanitized(processEnvironment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardwareModel()),
            locale: sanitized(locale.identifier(.bcp47))
        )
    }

    /// Keeps only characters the Worker accepts, at most 64 of them.
    static func sanitized(_ value: String) -> String {
        let kept = String(String.UnicodeScalarView(value.unicodeScalars.filter { allowed.contains($0) }))
        let limited = String(kept.prefix(64))
        return limited.isEmpty ? "unknown" : limited
    }

    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The request body for `POST /v1/feedback`: exactly the seven fields of D-076.
struct FeedbackPayload: Encodable, Equatable {
    let category: FeedbackCategory
    let body: String
    let appVersion: String
    let build: String
    let osVersion: String
    let deviceModel: String
    let locale: String

    init(category: FeedbackCategory, body: String, environment: FeedbackEnvironment) {
        self.category = category
        self.body = body
        appVersion = environment.appVersion
        build = environment.build
        osVersion = environment.osVersion
        deviceModel = environment.deviceModel
        locale = environment.locale
    }

    /// The Worker's request cap. 2000 characters of emoji can exceed it, so the app checks before sending.
    static let maxRequestBytes = 8192

    var fitsRequestLimit: Bool {
        guard let encoded = try? JSONEncoder().encode(self) else { return false }
        return encoded.count <= Self.maxRequestBytes
    }
}
