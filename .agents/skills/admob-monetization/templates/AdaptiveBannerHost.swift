import SwiftUI
import UIKit

struct AdaptiveBannerHost: View {
    @ObservedObject var runtime: AdMobRuntimeCoordinator
    let renderer: any AdMobBannerRendering
    let placement: AdMobPlacementContext

    @State private var state: AdMobBannerState = .idle

    var body: some View {
        GeometryReader { proxy in
            AdaptiveBannerContainer(
                runtime: runtime,
                renderer: renderer,
                placement: placement,
                containerWidth: proxy.size.width,
                consentRevision: runtime.consentRevision,
                state: $state
            )
        }
        .frame(height: state.renderedHeight)
        .clipped()
        .modifier(BannerAccessibilityModifier(isVisible: state.isVisible))
    }
}

private struct BannerAccessibilityModifier: ViewModifier {
    let isVisible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 14.0, *) {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel("広告")
                .accessibilityHidden(!isVisible)
        } else {
            content
                .accessibilityElement(children: .contain)
                .accessibility(label: Text("広告"))
                .accessibility(hidden: !isVisible)
        }
    }
}

private struct AdaptiveBannerContainer: UIViewRepresentable {
    let runtime: AdMobRuntimeCoordinator
    let renderer: any AdMobBannerRendering
    let placement: AdMobPlacementContext
    let containerWidth: CGFloat
    let consentRevision: Int
    @Binding var state: AdMobBannerState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: $state)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(parent: self, containerView: view)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.dismantle(containerView: view)
    }

    @MainActor
    final class Coordinator {
        private struct PreparationKey: Equatable {
            let placement: AdMobPlacementContext
            let pixelWidth: Int
            let rendererID: ObjectIdentifier
            let consentRevision: Int
        }

        private var state: Binding<AdMobBannerState>
        private var task: Task<Void, Never>?
        private var lastKey: PreparationKey?
        private weak var renderer: (any AdMobBannerRendering)?

        init(state: Binding<AdMobBannerState>) {
            self.state = state
        }

        func update(parent: AdaptiveBannerContainer, containerView: UIView) {
            state = parent.$state
            renderer = parent.renderer

            let width = max(parent.containerWidth, 0)
            let key = PreparationKey(
                placement: parent.placement,
                pixelWidth: Int((width * 2).rounded()),
                rendererID: ObjectIdentifier(parent.renderer),
                consentRevision: parent.consentRevision
            )
            guard key != lastKey else { return }
            lastKey = key
            task?.cancel()

            let rootViewController = topViewController(from: containerView.window?.rootViewController)
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                let preparedState = await parent.runtime.prepare(
                    context: parent.placement,
                    containerWidth: width,
                    presentingViewController: rootViewController
                )
                guard !Task.isCancelled else { return }
                self.state.wrappedValue = preparedState

                guard preparedState == .loading else {
                    parent.renderer.detach(from: containerView)
                    return
                }

                parent.renderer.attach(
                    to: containerView,
                    context: parent.placement,
                    containerWidth: width,
                    requestGeneration: parent.consentRevision,
                    rootViewController: rootViewController
                ) { [weak self] nextState in
                    self?.state.wrappedValue = nextState
                }
            }
        }

        func dismantle(containerView: UIView) {
            task?.cancel()
            task = nil
            renderer?.detach(from: containerView)
        }

        private func topViewController(from root: UIViewController?) -> UIViewController? {
            if let presented = root?.presentedViewController {
                return topViewController(from: presented)
            }
            if let navigation = root as? UINavigationController {
                return topViewController(from: navigation.visibleViewController)
            }
            if let tabs = root as? UITabBarController {
                return topViewController(from: tabs.selectedViewController)
            }
            return root
        }
    }
}
