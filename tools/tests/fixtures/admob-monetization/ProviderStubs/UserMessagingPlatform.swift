import UIKit

public struct RequestParameters: Sendable {
    public init() {}
}

public enum PrivacyOptionsRequirementStatus: Sendable {
    case required
    case notRequired
}

@MainActor
public final class ConsentInformation {
    public static let shared = ConsentInformation()
    public var canRequestAds = true
    public var privacyOptionsRequirementStatus:
        PrivacyOptionsRequirementStatus = .required

    private init() {}

    public func requestConsentInfoUpdate(
        with parameters: RequestParameters,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
public enum ConsentForm {
    public static func loadAndPresentIfRequired(
        from viewController: UIViewController?
    ) async throws {}

    public static func presentPrivacyOptionsForm(
        from viewController: UIViewController?
    ) async throws {}
}
