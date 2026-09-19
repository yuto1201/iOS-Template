import Combine
import Foundation
import UIKit

@MainActor
final class OfflineConsentCoordinator: AdMobConsentCoordinating {
    private let initialSnapshot: AdMobConsentSnapshot
    private let privacySnapshot: AdMobConsentSnapshot
    private(set) var updateCount = 0
    private(set) var privacyOptionsCount = 0

    init(
        initialSnapshot: AdMobConsentSnapshot,
        privacySnapshot: AdMobConsentSnapshot? = nil
    ) {
        self.initialSnapshot = initialSnapshot
        self.privacySnapshot = privacySnapshot ?? initialSnapshot
    }

    func updateAndPresentIfRequired(
        from viewController: UIViewController?
    ) async throws -> AdMobConsentSnapshot {
        updateCount += 1
        return initialSnapshot
    }

    func presentPrivacyOptions(
        from viewController: UIViewController?
    ) async throws -> AdMobConsentSnapshot {
        privacyOptionsCount += 1
        return privacySnapshot
    }
}

@MainActor
final class OfflineMobileAdsStarter: AdMobSDKStarting {
    private(set) var privacyConfiguration: AdMobPrivacyConfiguration?
    private(set) var startCount = 0

    func configurePrivacy(_ configuration: AdMobPrivacyConfiguration) {
        privacyConfiguration = configuration
    }

    func start() async {
        startCount += 1
    }
}

@MainActor
final class OfflineBannerRenderer: AdMobBannerRendering, ObservableObject {
    private struct RequestKey: Equatable {
        let adUnitID: String
        let pixelWidth: Int
        let requestGeneration: Int
    }

    private let shouldFail: Bool
    private var creativeView: UIView?
    private var lastRequestKey: RequestKey?
    @Published private(set) var lastState: AdMobBannerState = .idle

    private(set) var loadCount = 0

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func attach(
        to containerView: UIView,
        context: AdMobPlacementContext,
        containerWidth: CGFloat,
        requestGeneration: Int,
        rootViewController: UIViewController?,
        stateDidChange: @escaping @MainActor (AdMobBannerState) -> Void
    ) {
        let width = floor(containerWidth)
        guard width > 0 else {
            stateDidChange(.collapsed(.invalidContainerWidth))
            return
        }

        let scale = containerView.window?.screen.scale ?? 1
        let requestKey = RequestKey(
            adUnitID: context.adUnitID,
            pixelWidth: Int((width * scale).rounded()),
            requestGeneration: requestGeneration
        )
        guard requestKey != lastRequestKey else {
            if let creativeView {
                mount(creativeView, in: containerView)
            }
            stateDidChange(lastState)
            return
        }

        lastRequestKey = requestKey
        loadCount += 1
        creativeView?.removeFromSuperview()
        creativeView = nil

        guard !shouldFail else {
            lastState = .collapsed(.loadFailed)
            stateDidChange(lastState)
            return
        }

        let size = adaptiveSize(for: width)
        let creative = makeCreativeView()
        creativeView = creative
        mount(creative, in: containerView)
        lastState = .visible(size: size)
        stateDidChange(lastState)
    }

    func detach(from containerView: UIView) {
        guard creativeView?.superview === containerView else { return }
        creativeView?.removeFromSuperview()
    }

    private func adaptiveSize(for width: CGFloat) -> CGSize {
        CGSize(
            width: width,
            height: min(90, max(50, width / 6.4)).rounded(.up)
        )
    }

    private func makeCreativeView() -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "admob.fixture.banner-creative"
        view.accessibilityLabel = "テスト広告、オフライン表示"

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .headline)
        label.text = "テスト広告  •  オフライン表示"
        label.textAlignment = .center
        label.textColor = .label
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    private func mount(_ view: UIView, in containerView: UIView) {
        guard view.superview !== containerView else { return }
        view.removeFromSuperview()
        containerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            view.topAnchor.constraint(equalTo: containerView.topAnchor),
            view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }
}

@MainActor
final class AdMobFixtureSystem: ObservableObject {
    let runtime: AdMobRuntimeCoordinator
    let renderer: OfflineBannerRenderer

    init(runtime: AdMobRuntimeCoordinator, renderer: OfflineBannerRenderer) {
        self.runtime = runtime
        self.renderer = renderer
    }
}

@MainActor
enum AdMobFixtureRuntimeFactory {
    static func makeSystem(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AdMobFixtureSystem {
        let consentDenied = arguments.contains("--fixture-consent-denied")
        let shouldFail = arguments.contains("--fixture-banner-failure")
        let consent = OfflineConsentCoordinator(
            initialSnapshot: AdMobConsentSnapshot(
                canRequestAds: !consentDenied,
                isPrivacyOptionsRequired: true
            )
        )
        let sdk = OfflineMobileAdsStarter()
        let renderer = OfflineBannerRenderer(shouldFail: shouldFail)
        let runtime = AdMobRuntimeCoordinator(
            consent: consent,
            eligibility: ConfiguredAdMobEligibilityChecker(
                includedScreens: ["home"],
                excludedScreens: ["settings"],
                hasAdFreeEntitlement: { false }
            ),
            sdk: sdk
        )
        return AdMobFixtureSystem(runtime: runtime, renderer: renderer)
    }
}
