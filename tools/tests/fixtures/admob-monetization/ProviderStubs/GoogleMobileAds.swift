import CoreGraphics
import UIKit

public struct AdSize: Sendable {
    public let size: CGSize

    public init(size: CGSize) {
        self.size = size
    }
}

public func largeAnchoredAdaptiveBanner(width: CGFloat) -> AdSize {
    AdSize(size: CGSize(width: width, height: 50))
}

@MainActor
public protocol BannerViewDelegate: AnyObject {
    func bannerViewDidReceiveAd(_ bannerView: BannerView)
    func bannerView(
        _ bannerView: BannerView,
        didFailToReceiveAdWithError error: Error
    )
}

@MainActor
public protocol AdSizeDelegate: AnyObject {
    func adView(_ bannerView: BannerView, willChangeAdSizeTo size: AdSize)
}

public struct Request: Sendable {
    public init() {}
}

@MainActor
public final class BannerView: UIView {
    public weak var delegate: (any BannerViewDelegate)?
    public weak var adSizeDelegate: (any AdSizeDelegate)?
    public weak var rootViewController: UIViewController?
    public var adUnitID: String?
    public private(set) var adSize: AdSize

    public init(adSize: AdSize) {
        self.adSize = adSize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable in the provider contract stub")
    }

    public func load(_ request: Request) {}
}

public enum PublisherPrivacyPersonalizationState: Sendable {
    case disabled
}

@MainActor
public final class RequestConfiguration {
    public var publisherPrivacyPersonalizationState:
        PublisherPrivacyPersonalizationState = .disabled

    public func setPublisherFirstPartyIDEnabled(_ enabled: Bool) {}
}

@MainActor
public final class MobileAds {
    public static let shared = MobileAds()
    public let requestConfiguration = RequestConfiguration()

    private init() {}

    public func start() async {}
}
