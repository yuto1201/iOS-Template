import CoreGraphics
import Combine
import Foundation
import UIKit

enum AdMobBannerCollapseReason: String, Equatable, Sendable {
    case consentUnavailable
    case excludedPlacement
    case invalidContainerWidth
    case loadFailed
    case userHasAdFreeEntitlement
}

enum AdMobBannerState: Equatable, Sendable {
    case idle
    case loading
    case visible(size: CGSize)
    case collapsed(AdMobBannerCollapseReason)

    var renderedHeight: CGFloat {
        switch self {
        case let .visible(size):
            return size.height
        case .idle, .loading, .collapsed:
            return 0
        }
    }

    var isVisible: Bool {
        if case .visible = self { return true }
        return false
    }
}

struct AdMobConsentSnapshot: Equatable, Sendable {
    let canRequestAds: Bool
    let isPrivacyOptionsRequired: Bool
}

struct AdMobPlacementContext: Hashable, Sendable {
    let screenID: String
    let adUnitID: String
}

struct AdMobPrivacyConfiguration: Equatable, Sendable {
    let publisherFirstPartyIDEnabled: Bool
    let personalizedAdsEnabled: Bool

    static let nonTracking = AdMobPrivacyConfiguration(
        publisherFirstPartyIDEnabled: false,
        personalizedAdsEnabled: false
    )
}

enum AdMobEligibilityDecision: Equatable, Sendable {
    case eligible
    case ineligible(AdMobBannerCollapseReason)
}

@MainActor
protocol AdMobConsentCoordinating: AnyObject {
    func updateAndPresentIfRequired(
        from viewController: UIViewController?
    ) async throws -> AdMobConsentSnapshot

    func presentPrivacyOptions(
        from viewController: UIViewController?
    ) async throws -> AdMobConsentSnapshot
}

@MainActor
protocol AdMobEligibilityChecking: AnyObject {
    func isEligible(context: AdMobPlacementContext) -> AdMobEligibilityDecision
}

@MainActor
final class ConfiguredAdMobEligibilityChecker: AdMobEligibilityChecking {
    private let includedScreens: Set<String>
    private let excludedScreens: Set<String>
    private let hasAdFreeEntitlement: @MainActor () -> Bool

    init(
        includedScreens: Set<String>,
        excludedScreens: Set<String>,
        hasAdFreeEntitlement: @escaping @MainActor () -> Bool
    ) {
        self.includedScreens = includedScreens
        self.excludedScreens = excludedScreens
        self.hasAdFreeEntitlement = hasAdFreeEntitlement
    }

    func isEligible(context: AdMobPlacementContext) -> AdMobEligibilityDecision {
        guard includedScreens.contains(context.screenID),
              !excludedScreens.contains(context.screenID) else {
            return .ineligible(.excludedPlacement)
        }
        guard !hasAdFreeEntitlement() else {
            return .ineligible(.userHasAdFreeEntitlement)
        }
        return .eligible
    }
}

@MainActor
protocol AdMobSDKStarting: AnyObject {
    func configurePrivacy(_ configuration: AdMobPrivacyConfiguration)
    func start() async
}

@MainActor
protocol AdMobBannerRendering: AnyObject {
    func attach(
        to containerView: UIView,
        context: AdMobPlacementContext,
        containerWidth: CGFloat,
        requestGeneration: Int,
        rootViewController: UIViewController?,
        stateDidChange: @escaping @MainActor (AdMobBannerState) -> Void
    )

    func detach(from containerView: UIView)
}

@MainActor
final class AdMobRuntimeCoordinator: ObservableObject {
    private let consent: any AdMobConsentCoordinating
    private let eligibility: any AdMobEligibilityChecking
    private let sdk: any AdMobSDKStarting
    private var consentTask: Task<AdMobConsentSnapshot, Error>?
    private var sdkStartTask: Task<Void, Never>?
    private var consentSnapshot: AdMobConsentSnapshot?

    @Published private(set) var isPrivacyOptionsRequired = false
    @Published private(set) var consentRevision = 0
    @Published private(set) var eligibilityRevision = 0

    /// A consent or eligibility change starts a new banner request generation.
    var requestGeneration: Int { consentRevision + eligibilityRevision }

    init(
        consent: any AdMobConsentCoordinating,
        eligibility: any AdMobEligibilityChecking,
        sdk: any AdMobSDKStarting
    ) {
        self.consent = consent
        self.eligibility = eligibility
        self.sdk = sdk
    }

    @discardableResult
    func bootstrapConsent(
        from viewController: UIViewController?
    ) async -> AdMobConsentSnapshot? {
        if let consentSnapshot {
            return consentSnapshot
        }

        let task: Task<AdMobConsentSnapshot, Error>
        if let consentTask {
            task = consentTask
        } else {
            let createdTask = Task { @MainActor [consent] in
                try await consent.updateAndPresentIfRequired(from: viewController)
            }
            consentTask = createdTask
            task = createdTask
        }

        do {
            let snapshot = try await task.value
            apply(snapshot, refreshBannerHosts: false)
            return snapshot
        } catch {
            return nil
        }
    }

    /// Call when an eligibility input changes, such as a verified ad-free entitlement. Banner hosts that
    /// are visible or still preparing prepare again and collapse when the placement is no longer eligible.
    func invalidateEligibility() {
        eligibilityRevision += 1
    }

    func prepare(
        context: AdMobPlacementContext,
        containerWidth: CGFloat,
        presentingViewController: UIViewController?
    ) async -> AdMobBannerState {
        guard containerWidth > 0 else {
            return .collapsed(.invalidContainerWidth)
        }

        if let reason = ineligibility(for: context) {
            return .collapsed(reason)
        }

        guard let snapshot = await bootstrapConsent(
            from: presentingViewController
        ) else {
            return .collapsed(.consentUnavailable)
        }

        guard snapshot.canRequestAds else {
            return .collapsed(.consentUnavailable)
        }

        // Eligibility can change while consent was being gathered; check again before the SDK starts.
        if let reason = ineligibility(for: context) {
            return .collapsed(reason)
        }

        if sdkStartTask == nil {
            sdk.configurePrivacy(.nonTracking)
            sdkStartTask = Task { @MainActor [sdk] in
                await sdk.start()
            }
        }
        await sdkStartTask?.value

        // And once more after the SDK start, immediately before the caller requests an ad.
        if let reason = ineligibility(for: context) {
            return .collapsed(reason)
        }
        return .loading
    }

    private func ineligibility(for context: AdMobPlacementContext) -> AdMobBannerCollapseReason? {
        switch eligibility.isEligible(context: context) {
        case .eligible:
            return nil
        case let .ineligible(reason):
            return reason
        }
    }

    func presentPrivacyOptions(
        from viewController: UIViewController?
    ) async throws -> AdMobConsentSnapshot {
        let snapshot = try await consent.presentPrivacyOptions(
            from: viewController
        )
        apply(snapshot, refreshBannerHosts: true)
        return snapshot
    }

    private func apply(
        _ snapshot: AdMobConsentSnapshot,
        refreshBannerHosts: Bool
    ) {
        consentSnapshot = snapshot
        isPrivacyOptionsRequired = snapshot.isPrivacyOptionsRequired
        if refreshBannerHosts {
            consentRevision += 1
        }
    }
}

/// Accepts banner states only from a host's active request generation, so a late SDK callback cannot
/// reopen a banner that consent or eligibility already suppressed.
@MainActor
final class AdMobBannerStateGate {
    private var activeToken = 0
    private var isOpen = false

    /// Starts a new generation and returns the token its callbacks must present.
    func open() -> Int {
        activeToken += 1
        isOpen = true
        return activeToken
    }

    /// Ends the current generation. Callbacks holding an earlier token are rejected from now on.
    func close() {
        activeToken += 1
        isOpen = false
    }

    func accepts(_ token: Int) -> Bool {
        isOpen && token == activeToken
    }
}
