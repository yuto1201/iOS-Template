import StoreKit
import SwiftUI

extension View {
    /// Adds the review prompt (#383) to a root view: counts the launch and asks when the rules allow it.
    /// An app that reports moments of success calls `recordSignificantEvent()` on the same center.
    func reviewPrompt(_ center: ReviewPromptCenter) -> some View {
        modifier(ReviewPromptModifier(center: center))
    }
}

struct ReviewPromptModifier: ViewModifier {
    @Environment(\.feedbackSender) private var feedbackSender
    @Environment(\.requestReview) private var requestReview
    @Bindable var center: ReviewPromptCenter
    @State private var handledLaunch = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $center.isPresented, onDismiss: center.sheetDidDismiss) {
                ReviewPromptSheet(center: center, feedbackSender: feedbackSender)
            }
            .task {
                center.feedbackAvailable = feedbackSender != nil
                center.requestReview = { requestReview() }
                guard !handledLaunch else { return }
                handledLaunch = true
                center.recordLaunch()
                await center.presentIfEligible(force: ReviewPromptCenter.forcesShow())
            }
    }
}

/// The small question sheet, and after "Not great" the gentle follow-up.
struct ReviewPromptSheet: View {
    @Bindable var center: ReviewPromptCenter
    let feedbackSender: (any FeedbackSending)?
    @Environment(\.openURL) private var openURL
    @State private var showsFeedback = false

    var body: some View {
        VStack(spacing: 16) {
            switch center.phase {
            case .question:
                question
            case .followUp:
                followUp
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showsFeedback, onDismiss: {
            if center.feedbackWasSent { center.close() }
        }) {
            if let feedbackSender {
                FeedbackView(sender: feedbackSender, onSent: center.feedbackSent)
            }
        }
    }

    private var question: some View {
        VStack(spacing: 16) {
            Text("review-prompt.question \(center.appName)")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("review-prompt.question")
            HStack(spacing: 12) {
                promptButton("review-prompt.negative", identifier: "review-prompt.negative", prominent: false) {
                    center.answerNegative()
                }
                promptButton("review-prompt.positive", identifier: "review-prompt.positive", prominent: true) {
                    center.answerPositive()
                }
            }
            Button("review-prompt.later") { center.close() }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
                .accessibilityIdentifier("review-prompt.later")
        }
    }

    private var followUp: some View {
        VStack(spacing: 16) {
            Text(followUpMessage)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("review-prompt.follow-up")
            ForEach(Array(center.followUpActions.enumerated()), id: \.offset) { _, action in
                switch action {
                case .sendFeedback:
                    promptButton("feedback.entry", identifier: "review-prompt.send-feedback", prominent: true) {
                        showsFeedback = true
                    }
                case .openSupport(let url):
                    promptButton("review-prompt.support", identifier: "review-prompt.support", prominent: true) {
                        openURL(url)
                        center.close()
                    }
                case .close:
                    promptButton("review-prompt.close", identifier: "review-prompt.close", prominent: false) {
                        center.close()
                    }
                }
            }
        }
    }

    private var followUpMessage: LocalizedStringKey {
        center.followUpActions == [.close] ? "review-prompt.thanks" : "review-prompt.feedback-invitation"
    }

    /// Full width and at least 44pt tall, so each answer is easy to hit.
    @ViewBuilder
    private func promptButton(
        _ title: LocalizedStringKey,
        identifier: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityIdentifier(identifier)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
