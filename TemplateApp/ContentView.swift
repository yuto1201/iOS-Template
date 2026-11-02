//
//  ContentView.swift
//  TemplateApp
//
//  Created by 上杉侑斗 on 2026/08/21.
//

import SwiftUI

struct ContentView: View {
    /// Asks now and then how the app is doing (#383). The template has no moment of success, so only the
    /// launch count and the days since the first launch decide; an app calls `recordSignificantEvent()`.
    @State private var reviewPrompt = ReviewPromptCenter.live()
    /// The first-launch onboarding (#483). An app declares its own pages in `OnboardingConfig.json`.
    @State private var onboarding = OnboardingCenter.live()
    /// The sample question's answer (`purpose`), used for one line on this screen: how an app uses an answer
    /// through `answers(for:)` and the `onCompleted` hook.
    @State private var purpose: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "app.dashed")
                .font(.largeTitle)
                .accessibilityHidden(true)

            Text("template.welcome")
                .font(.headline)
                .accessibilityIdentifier("template.welcome-title")

            if let line = Self.purposeLine(purpose) {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("onboarding.sample.purpose-line")
            }

            FeedbackEntryButton()

            RateAppButton()

            LegalLinksView()
        }
        .padding()
        .onAppear {
            purpose = onboarding.answers(for: "purpose").first
            onboarding.onCompleted = { answers in
                purpose = answers.optionIDs(for: "purpose").first
            }
        }
        .onboarding(onboarding, reviewPrompt: reviewPrompt)
        .reviewPrompt(reviewPrompt)
    }

    /// The line for each option of the sample question; nothing when it was not answered.
    static func purposeLine(_ optionID: String?) -> LocalizedStringKey? {
        switch optionID {
        case "build": "onboarding.sample.purpose-line.build"
        case "explore": "onboarding.sample.purpose-line.explore"
        case "learn": "onboarding.sample.purpose-line.learn"
        default: nil
        }
    }
}

#Preview {
    ContentView()
}
