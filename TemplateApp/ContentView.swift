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

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "app.dashed")
                .font(.largeTitle)
                .accessibilityHidden(true)

            Text("template.welcome")
                .font(.headline)
                .accessibilityIdentifier("template.welcome-title")

            FeedbackEntryButton()

            LegalLinksView()
        }
        .padding()
        .reviewPrompt(reviewPrompt)
    }
}

#Preview {
    ContentView()
}
