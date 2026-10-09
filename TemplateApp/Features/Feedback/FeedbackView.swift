import SwiftUI

extension EnvironmentValues {
    /// Nil when the build has no feedback endpoint; the entry is then hidden.
    @Entry var feedbackSender: (any FeedbackSending)? = nil
}

/// The entry that opens the feedback sheet. Hidden until the build has a feedback endpoint (D-076).
/// The template shows it on its root screen; an app moves it into its own Settings support section.
struct FeedbackEntryButton: View {
    @Environment(\.feedbackSender) private var feedbackSender
    @State private var showsFeedback = false
    @State private var handledLaunchOpen = false

    var body: some View {
        if let feedbackSender {
            Button("feedback.entry", systemImage: "envelope") { showsFeedback = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("feedback.entry")
                .sheet(isPresented: $showsFeedback) {
                    FeedbackView(sender: feedbackSender)
                }
                .onAppear {
                    guard !handledLaunchOpen else { return }
                    handledLaunchOpen = true
                    if Self.opensOnLaunch() { showsFeedback = true }
                }
        }
    }

    /// Screenshots only (`-FeedbackOpen` in a Debug build): the sheet opens once at launch.
    static func opensOnLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        return arguments.contains("-FeedbackOpen")
        #else
        return false
        #endif
    }
}

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    let sender: any FeedbackSending

    @State private var draft = FeedbackDraft()
    @State private var phase = Phase.editing
    @State private var sendError: FeedbackSendError?
    @State private var showsValidation = false
    @State private var tooLong = false
    @AccessibilityFocusState private var focusesResult: Bool
    #if DEBUG
    /// UI tests only: the result VoiceOver focus was last moved to ("none", "error" or "success").
    @State private var requestedResultFocus = "none"
    #endif
    @FocusState private var editsBody: Bool

    private enum Phase { case editing, sending, sent }

    var body: some View {
        NavigationStack {
            Form {
                if phase == .sent {
                    sentSection
                } else {
                    editingSections
                }
            }
            .navigationTitle("feedback.title")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled(phase == .sending)
            .toolbar {
                if phase != .sent {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("feedback.cancel") { dismiss() }
                            .disabled(phase == .sending)
                            .accessibilityIdentifier("feedback.cancel")
                    }
                }
            }
        }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) { resultFocusProbe }
        #endif
    }

    #if DEBUG
    /// UI tests only (the scripted sender): the result the sheet last moved VoiceOver focus to. XCUITest
    /// cannot run VoiceOver, and SwiftUI keeps the focus state false while VoiceOver is off, so the
    /// sheet records each focus request here for the test to read.
    @ViewBuilder private var resultFocusProbe: some View {
        if sender is ScriptedFeedbackSender {
            Text(verbatim: "result-focus:\(requestedResultFocus)")
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("feedback.result-focus")
        }
    }
    #endif

    private var sentSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                messageLabel("feedback.success.title", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focusesResult)
                    .accessibilityIdentifier("feedback.success")
                Text("feedback.success.message")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
            Button("feedback.close") { dismiss() }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("feedback.close")
        }
    }

    @ViewBuilder
    private var editingSections: some View {
        Section("feedback.category") {
            Picker("feedback.category", selection: $draft.category) {
                ForEach(FeedbackCategory.allCases) { category in
                    Text(category.titleKey).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("feedback.category")
        }
        Section {
            TextEditor(text: $draft.body)
                .focused($editsBody)
                .frame(minHeight: 160)
                .accessibilityLabel("feedback.body")
                .accessibilityIdentifier("feedback.body")
            HStack(alignment: .firstTextBaseline) {
                if showsValidation && !draft.isValid {
                    validationMessage("feedback.validation.body")
                } else if tooLong {
                    validationMessage("feedback.validation.too-long")
                }
                Spacer(minLength: 8)
                Text("feedback.body.count \(draft.bodyCount)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(draft.bodyCount > FeedbackDraft.maxBodyCount ? .red : .secondary)
                    .accessibilityIdentifier("feedback.count")
            }
        } header: {
            Text("feedback.body")
        } footer: {
            Text("feedback.disclosure")
                .accessibilityIdentifier("feedback.disclosure")
        }
        Section {
            // Right above Send, so the reason is where the user just tapped.
            if let sendError {
                messageLabel(sendError.messageKey, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($focusesResult)
                    .accessibilityIdentifier("feedback.error")
            }
            Button(action: send) {
                HStack(spacing: 8) {
                    Spacer()
                    if phase == .sending {
                        ProgressView()
                        Text("feedback.sending")
                    } else {
                        Text("feedback.send")
                    }
                    Spacer()
                }
                .frame(minHeight: 44)
            }
            .disabled(phase == .sending)
            .accessibilityIdentifier("feedback.send")
        }
    }

    /// A message with a decorative icon. VoiceOver and UI tests see one element that reads only the text,
    /// so the icon's own name ("Selected" for a checkmark) is never read or matched instead.
    private func messageLabel(_ key: LocalizedStringKey, systemImage: String) -> some View {
        Label(key, systemImage: systemImage)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(key))
    }

    private func validationMessage(_ key: LocalizedStringKey) -> some View {
        messageLabel(key, systemImage: "exclamationmark.circle")
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("feedback.validation")
    }

    /// Moves VoiceOver focus to the shown result: the success title, or the error above Send.
    private func moveFocusToResult() {
        focusesResult = true
        #if DEBUG
        requestedResultFocus = phase == .sent ? "success" : (sendError == nil ? "none" : "error")
        #endif
    }

    private func send() {
        guard let body = draft.validatedBody() else {
            showsValidation = true
            return
        }
        showsValidation = false
        let payload = FeedbackPayload(category: draft.category, body: body, environment: .current())
        tooLong = !payload.fitsRequestLimit
        guard !tooLong else { return }
        sendError = nil
        editsBody = false
        // Cleared while sending, so focus moves again to this attempt's result.
        focusesResult = false
        #if DEBUG
        requestedResultFocus = "none"
        #endif
        phase = .sending
        Task {
            do {
                try await sender.send(payload)
                phase = .sent
            } catch let error as FeedbackSendError {
                sendError = error
                phase = .editing
            } catch {
                sendError = .server
                phase = .editing
            }
            // One run-loop turn later, once the result row exists, so VoiceOver can move to it.
            DispatchQueue.main.async { moveFocusToResult() }
        }
    }
}

private extension FeedbackCategory {
    var titleKey: LocalizedStringKey {
        switch self {
        case .bug: "feedback.category.bug"
        case .request: "feedback.category.request"
        case .other: "feedback.category.other"
        }
    }
}

private extension FeedbackSendError {
    var messageKey: LocalizedStringKey {
        switch self {
        case .offline: "feedback.error.offline"
        case .rateLimited: "feedback.error.rate-limited"
        case .server: "feedback.error.server"
        }
    }
}
