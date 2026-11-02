import SwiftUI

extension View {
    /// Adds the first-launch onboarding (#483) to a root view. While it is on screen, `reviewPrompt` is
    /// suppressed with the reason "onboarding", and it resumes once the onboarding closes.
    func onboarding(_ center: OnboardingCenter, reviewPrompt: ReviewPromptCenter?) -> some View {
        modifier(OnboardingModifier(center: center, reviewPrompt: reviewPrompt))
    }
}

struct OnboardingModifier: ViewModifier {
    let center: OnboardingCenter
    let reviewPrompt: ReviewPromptCenter?
    @State private var handledLaunch = false

    func body(content: Content) -> some View {
        let isPresented = center.isPresented
        content
            .onAppear {
                guard !handledLaunch else { return }
                handledLaunch = true
                // The onboarding is there from the start, so it does not slide in over the app.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    center.start(reviewPrompt: reviewPrompt)
                }
            }
            // Only the onboarding closes itself; there is no interactive dismissal of a full-screen cover.
            .fullScreenCover(isPresented: Binding(get: { isPresented }, set: { _ in })) {
                OnboardingView(center: center)
            }
    }
}

/// The page-turn onboarding (OB-A, D-102, `specs/product.md` §4.6): full-screen pages of the same shape in
/// a row. Back and Skip at the top, a picture, a heading and a short text in the middle, the page dots and
/// the main button at the bottom. Pages move by a horizontal swipe and by the buttons, except that a
/// question stops the forward swipe until "Next". One page is on screen at a time, so what VoiceOver and
/// UI tests find is always the current page.
struct OnboardingView: View {
    let center: OnboardingCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The direction of the last move, for the page transition.
    @State private var forward = true

    /// Wide enough for a phone; on iPad the same order sits in a narrower centered column.
    private static let maximumColumnWidth: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                if let page = center.currentPage {
                    OnboardingPageContent(center: center, page: page)
                        .id(page.id)
                        .transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(.rect)
            .simultaneousGesture(swipe)
            bottomBar
        }
        .frame(maxWidth: Self.maximumColumnWidth)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }

    private func move(forward: Bool = true, _ change: () -> Void) {
        self.forward = forward
        withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 0.3), change)
    }

    /// Pages slide in from the side they come from; with Reduce Motion they only cross-fade, without moving.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading),
            removal: .move(edge: forward ? .leading : .trailing)
        )
    }

    /// A clearly horizontal swipe: to the left goes on (not past a question), to the right goes back.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            let width = value.translation.width
            guard abs(width) > 60, abs(width) > abs(value.translation.height) * 1.5 else { return }
            if width < 0 {
                move { center.go(to: center.currentIndex + 1) }
            } else {
                move(forward: false) { center.go(to: center.currentIndex - 1) }
            }
        }
    }

    // MARK: Top: Back and Skip

    private var topBar: some View {
        HStack {
            if center.showsBack {
                Button { move(forward: false, center.back) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .fontWeight(.semibold)
                        Text("onboarding.back")
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                }
                .accessibilityLabel(Text("onboarding.back.accessibility"))
                .accessibilityIdentifier("onboarding.back")
            }
            Spacer(minLength: 16)
            if center.showsSkip {
                Button { center.skip() } label: {
                    Text("onboarding.skip")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel(Text("onboarding.skip.accessibility"))
                .accessibilityIdentifier("onboarding.skip")
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: Bottom: page dots and the main button

    private var bottomBar: some View {
        VStack(spacing: 16) {
            pageDots
            if let page = center.currentPage {
                if page.kind == .permissionPrimer, center.isPermissionDenied(on: page.id) {
                    Text("onboarding.permission.denied")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.permission.denied")
                }
                buttons(for: page)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    /// Decoration only; VoiceOver reads the position as text, for example "Page 2 of 4".
    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(center.pages.indices, id: \.self) { index in
                Circle()
                    .fill(index == center.currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("onboarding.position \(center.currentIndex + 1) \(center.pages.count)"))
        .accessibilityIdentifier("onboarding.position")
    }

    @ViewBuilder
    private func buttons(for page: OnboardingConfig.Page) -> some View {
        switch page.kind {
        case .value, .choice:
            primaryButton("onboarding.next") { move(center.next) }
                .disabled(!center.canAdvance)
        case .permissionPrimer:
            if center.isPermissionDenied(on: page.id) {
                primaryButton("onboarding.next") { move(center.next) }
            } else {
                primaryButton("onboarding.permission.allow") {
                    Task { await center.allowPermission() }
                }
                Button { move(center.declinePermission) } label: {
                    Text("onboarding.permission.later")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("onboarding.secondary")
            }
        case .completion:
            primaryButton("onboarding.start") { center.next() }
        }
    }

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(.rect)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("onboarding.primary")
    }
}

/// One page's picture, heading, text and, on a question, its options. The page scrolls when large text
/// makes it long, so the main button below always stays on screen.
struct OnboardingPageContent: View {
    let center: OnboardingCenter
    let page: OnboardingConfig.Page
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                artwork
                Text(LocalizedStringKey(page.titleKey))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("onboarding.page.\(page.id).title")
                Text(LocalizedStringKey(page.messageKey))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.page.\(page.id).message")
                if page.kind == .choice {
                    options
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Smaller with large text, so the words keep the room.
    private var artworkHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 64 }
        return page.kind == .choice ? 88 : 150
    }

    @ViewBuilder
    private var artwork: some View {
        Group {
            if let imageName = page.imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
                    .padding(artworkHeight * 0.22)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
        }
        .frame(height: artworkHeight)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch page.kind {
        case .value: "sparkles"
        case .choice: "list.bullet"
        case .permissionPrimer: "bell.fill"
        case .completion: "checkmark"
        }
    }

    /// Rows with a selection mark; the chosen row carries the selected state for VoiceOver.
    private var options: some View {
        VStack(spacing: 10) {
            ForEach(page.options ?? []) { option in
                let selected = center.isSelected(option.id, on: page.id)
                Button { center.select(option.id, on: page.id) } label: {
                    HStack(spacing: 12) {
                        if let imageName = option.imageName {
                            Image(imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 32, height: 32)
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(option.titleKey))
                                .font(.body)
                                .foregroundStyle(.primary)
                            if let subtitleKey = option.subtitleKey {
                                Text(LocalizedStringKey(subtitleKey))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .imageScale(.large)
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .contentShape(.rect)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("onboarding.option.\(page.id).\(option.id)")
            }
        }
    }
}
