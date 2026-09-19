import CoreGraphics
import UIKit
import XCTest
@testable import AdMobFixtureApp

@MainActor
final class AdMobIntegrationTests: XCTestCase {
    func testConsentEligibilityAndRequestDeduplication() async throws {
        let allowed = makeSystem()
        let launchSnapshot = await allowed.runtime.bootstrapConsent(from: nil)
        XCTAssertEqual(
            launchSnapshot,
            AdMobConsentSnapshot(
                canRequestAds: true,
                isPrivacyOptionsRequired: true
            )
        )
        XCTAssertTrue(allowed.runtime.isPrivacyOptionsRequired)

        let first = await allowed.runtime.prepare(
            context: .home,
            containerWidth: 390,
            presentingViewController: nil
        )
        let repeated = await allowed.runtime.prepare(
            context: .home,
            containerWidth: 390,
            presentingViewController: nil
        )
        let resized = await allowed.runtime.prepare(
            context: .home,
            containerWidth: 844,
            presentingViewController: nil
        )

        XCTAssertEqual(first, .loading)
        XCTAssertEqual(repeated, .loading)
        XCTAssertEqual(resized, .loading)
        XCTAssertEqual(
            allowed.events.values,
            ["consent", "eligibility", "privacy", "sdk-start", "eligibility", "eligibility"]
        )
        XCTAssertEqual(allowed.consent.updateCount, 1)
        XCTAssertEqual(allowed.sdk.startCount, 1)
        XCTAssertEqual(allowed.sdk.configuration, .nonTracking)
        XCTAssertFalse(
            allowed.sdk.configuration?.personalizedAdsEnabled ?? true
        )
        XCTAssertFalse(
            allowed.sdk.configuration?.publisherFirstPartyIDEnabled ?? true
        )

        let excluded = makeSystem()
        let excludedState = await excluded.runtime.prepare(
            context: .excluded,
            containerWidth: 390,
            presentingViewController: nil
        )
        XCTAssertEqual(excludedState, .collapsed(.excludedPlacement))
        XCTAssertEqual(excluded.consent.updateCount, 0)
        XCTAssertEqual(excluded.sdk.startCount, 0)

        let laterEligible = await excluded.runtime.prepare(
            context: .home,
            containerWidth: 390,
            presentingViewController: nil
        )
        XCTAssertEqual(laterEligible, .loading)
        XCTAssertEqual(excluded.consent.updateCount, 1)
        XCTAssertEqual(excluded.sdk.startCount, 1)

        let adFree = makeSystem(hasAdFreeEntitlement: true)
        let adFreeState = await adFree.runtime.prepare(
            context: .home,
            containerWidth: 390,
            presentingViewController: nil
        )
        XCTAssertEqual(
            adFreeState,
            .collapsed(.userHasAdFreeEntitlement)
        )
        XCTAssertEqual(adFree.consent.updateCount, 0)
        XCTAssertEqual(adFree.sdk.startCount, 0)

        let consentChanged = makeSystem(
            initialSnapshot: AdMobConsentSnapshot(
                canRequestAds: false,
                isPrivacyOptionsRequired: true
            ),
            privacySnapshot: AdMobConsentSnapshot(
                canRequestAds: true,
                isPrivacyOptionsRequired: false
            )
        )
        let denied = await consentChanged.runtime.prepare(
            context: .home,
            containerWidth: 390,
            presentingViewController: nil
        )
        XCTAssertEqual(denied, .collapsed(.consentUnavailable))
        XCTAssertEqual(consentChanged.sdk.startCount, 0)

        let privacySnapshot = try await consentChanged.runtime
            .presentPrivacyOptions(from: nil)
        XCTAssertTrue(privacySnapshot.canRequestAds)
        XCTAssertFalse(consentChanged.runtime.isPrivacyOptionsRequired)
        XCTAssertEqual(consentChanged.runtime.consentRevision, 1)
        XCTAssertEqual(consentChanged.consent.privacyOptionsCount, 1)

        let allowedAfterPrivacy = await consentChanged.runtime.prepare(
            context: .home,
            containerWidth: 390,
            presentingViewController: nil
        )
        XCTAssertEqual(allowedAfterPrivacy, .loading)
        XCTAssertEqual(consentChanged.consent.updateCount, 1)
        XCTAssertEqual(consentChanged.sdk.startCount, 1)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 50))
        let renderer = OfflineBannerRenderer(shouldFail: false)
        var rendererStates: [AdMobBannerState] = []
        renderer.attach(
            to: container,
            context: .home,
            containerWidth: 390,
            requestGeneration: 0,
            rootViewController: nil,
            stateDidChange: { rendererStates.append($0) }
        )
        renderer.detach(from: container)
        renderer.attach(
            to: container,
            context: .home,
            containerWidth: 390,
            requestGeneration: 0,
            rootViewController: nil,
            stateDidChange: { rendererStates.append($0) }
        )
        XCTAssertEqual(renderer.loadCount, 1)

        renderer.attach(
            to: container,
            context: .home,
            containerWidth: 390,
            requestGeneration: 1,
            rootViewController: nil,
            stateDidChange: { rendererStates.append($0) }
        )
        renderer.attach(
            to: container,
            context: .home,
            containerWidth: 844,
            requestGeneration: 1,
            rootViewController: nil,
            stateDidChange: { rendererStates.append($0) }
        )
        XCTAssertEqual(renderer.loadCount, 3)
        guard case .visible(let finalSize) = rendererStates.last else {
            XCTFail("A distinct consent generation and width must each replace the offline request once.")
            return
        }
        XCTAssertEqual(finalSize.width, 844)
        XCTAssertEqual(finalSize.height, 90)

        let failedRenderer = OfflineBannerRenderer(shouldFail: true)
        var failedState = AdMobBannerState.idle
        failedRenderer.attach(
            to: container,
            context: .home,
            containerWidth: 390,
            requestGeneration: 0,
            rootViewController: nil,
            stateDidChange: { failedState = $0 }
        )
        failedRenderer.attach(
            to: container,
            context: .home,
            containerWidth: 390,
            requestGeneration: 0,
            rootViewController: nil,
            stateDidChange: { failedState = $0 }
        )
        XCTAssertEqual(failedState, .collapsed(.loadFailed))
        XCTAssertEqual(failedRenderer.loadCount, 1)
    }

    private func makeSystem(
        initialSnapshot: AdMobConsentSnapshot = AdMobConsentSnapshot(
            canRequestAds: true,
            isPrivacyOptionsRequired: true
        ),
        privacySnapshot: AdMobConsentSnapshot? = nil,
        hasAdFreeEntitlement: Bool = false
    ) -> TestSystem {
        let events = EventRecorder()
        let consent = ConsentSpy(
            events: events,
            initialSnapshot: initialSnapshot,
            privacySnapshot: privacySnapshot ?? initialSnapshot
        )
        let eligibility = EligibilitySpy(
            events: events,
            hasAdFreeEntitlement: hasAdFreeEntitlement
        )
        let sdk = SDKStarterSpy(events: events)
        let runtime = AdMobRuntimeCoordinator(
            consent: consent,
            eligibility: eligibility,
            sdk: sdk
        )
        return TestSystem(
            runtime: runtime,
            events: events,
            consent: consent,
            sdk: sdk
        )
    }
}

private extension AdMobPlacementContext {
    static let home = AdMobPlacementContext(
        screenID: "home",
        adUnitID: "offline-banner"
    )
    static let excluded = AdMobPlacementContext(
        screenID: "settings",
        adUnitID: "offline-banner"
    )
}

@MainActor
private struct TestSystem {
    let runtime: AdMobRuntimeCoordinator
    let events: EventRecorder
    let consent: ConsentSpy
    let sdk: SDKStarterSpy
}

@MainActor
private final class EventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class ConsentSpy: AdMobConsentCoordinating {
    private let events: EventRecorder
    private let initialSnapshot: AdMobConsentSnapshot
    private let privacySnapshot: AdMobConsentSnapshot
    private(set) var updateCount = 0
    private(set) var privacyOptionsCount = 0

    init(
        events: EventRecorder,
        initialSnapshot: AdMobConsentSnapshot,
        privacySnapshot: AdMobConsentSnapshot
    ) {
        self.events = events
        self.initialSnapshot = initialSnapshot
        self.privacySnapshot = privacySnapshot
    }

    func updateAndPresentIfRequired(
        from viewController: UIViewController?
    ) async throws -> AdMobConsentSnapshot {
        updateCount += 1
        events.append("consent")
        return initialSnapshot
    }

    func presentPrivacyOptions(
        from viewController: UIViewController?
    ) async throws -> AdMobConsentSnapshot {
        privacyOptionsCount += 1
        events.append("privacy-options")
        return privacySnapshot
    }
}

@MainActor
private final class EligibilitySpy: AdMobEligibilityChecking {
    private let events: EventRecorder
    private let hasAdFreeEntitlement: Bool

    init(events: EventRecorder, hasAdFreeEntitlement: Bool) {
        self.events = events
        self.hasAdFreeEntitlement = hasAdFreeEntitlement
    }

    func isEligible(context: AdMobPlacementContext) -> AdMobEligibilityDecision {
        events.append("eligibility")
        guard context.screenID == "home" else {
            return .ineligible(.excludedPlacement)
        }
        guard !hasAdFreeEntitlement else {
            return .ineligible(.userHasAdFreeEntitlement)
        }
        return .eligible
    }
}

@MainActor
private final class SDKStarterSpy: AdMobSDKStarting {
    private let events: EventRecorder
    private(set) var configuration: AdMobPrivacyConfiguration?
    private(set) var startCount = 0

    init(events: EventRecorder) {
        self.events = events
    }

    func configurePrivacy(_ configuration: AdMobPrivacyConfiguration) {
        self.configuration = configuration
        events.append("privacy")
    }

    func start() async {
        startCount += 1
        events.append("sdk-start")
    }
}
