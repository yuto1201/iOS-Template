import GoogleMobileAds
import UIKit
import UserMessagingPlatform

@MainActor
final class GoogleConsentCoordinator: AdMobConsentCoordinating {
    func updateAndPresentIfRequired(
        from viewController: UIViewController?
    ) async throws -> AdMobConsentSnapshot {
        let parameters = RequestParameters()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        try await ConsentForm.loadAndPresentIfRequired(from: viewController)
        return snapshot
    }

    func presentPrivacyOptions(
        from viewController: UIViewController?
    ) async throws -> AdMobConsentSnapshot {
        try await ConsentForm.presentPrivacyOptionsForm(from: viewController)
        return snapshot
    }

    private var snapshot: AdMobConsentSnapshot {
        AdMobConsentSnapshot(
            canRequestAds: ConsentInformation.shared.canRequestAds,
            isPrivacyOptionsRequired:
                ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        )
    }
}

@MainActor
final class GoogleMobileAdsSDKStarter: AdMobSDKStarting {
    private var didStart = false

    func configurePrivacy(_ configuration: AdMobPrivacyConfiguration) {
        precondition(!configuration.publisherFirstPartyIDEnabled)
        precondition(!configuration.personalizedAdsEnabled)

        let requestConfiguration = MobileAds.shared.requestConfiguration
        requestConfiguration.setPublisherFirstPartyIDEnabled(false)
        requestConfiguration.publisherPrivacyPersonalizationState = .disabled
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        await MobileAds.shared.start()
    }
}

@MainActor
final class GoogleMobileAdsBannerRenderer: NSObject, AdMobBannerRendering, AdSizeDelegate, BannerViewDelegate {
    private struct RequestKey: Equatable {
        let adUnitID: String
        let pixelWidth: Int
        let requestGeneration: Int
    }

    private var bannerView: BannerView?
    private var lastRequestKey: RequestKey?
    private var lastState: AdMobBannerState = .idle
    private var stateDidChange: ((AdMobBannerState) -> Void)?

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
            if let bannerView {
                bannerView.rootViewController = rootViewController
                mount(bannerView, in: containerView)
            }
            self.stateDidChange = stateDidChange
            stateDidChange(lastState)
            return
        }

        let adSize = largeAnchoredAdaptiveBanner(width: width)
        bannerView?.removeFromSuperview()
        let banner = BannerView(adSize: adSize)
        bannerView = banner
        banner.delegate = self
        banner.adSizeDelegate = self
        banner.rootViewController = rootViewController
        banner.adUnitID = context.adUnitID
        mount(banner, in: containerView)

        self.stateDidChange = stateDidChange
        lastRequestKey = requestKey
        lastState = .loading
        stateDidChange(.loading)
        banner.load(Request())
    }

    func detach(from containerView: UIView) {
        guard bannerView?.superview === containerView else { return }
        bannerView?.removeFromSuperview()
    }

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        guard bannerView === self.bannerView else { return }
        let state = AdMobBannerState.visible(size: bannerView.adSize.size)
        lastState = state
        stateDidChange?(state)
    }

    func adView(
        _ bannerView: BannerView,
        willChangeAdSizeTo size: AdSize
    ) {
        guard bannerView === self.bannerView else { return }
        let state = AdMobBannerState.visible(size: size.size)
        lastState = state
        stateDidChange?(state)
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        guard bannerView === self.bannerView else { return }
        bannerView.removeFromSuperview()
        lastState = .collapsed(.loadFailed)
        stateDidChange?(lastState)
    }

    private func mount(_ banner: BannerView, in containerView: UIView) {
        guard banner.superview !== containerView else { return }
        banner.removeFromSuperview()
        banner.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            banner.topAnchor.constraint(equalTo: containerView.topAnchor)
        ])
    }
}
