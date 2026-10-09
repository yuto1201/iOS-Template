//
//  TemplateAppApp.swift
//  TemplateApp
//
//  Created by 上杉侑斗 on 2026/08/21.
//

import SwiftUI

@main
struct TemplateAppApp: App {
    /// Nil until the build has a feedback endpoint (D-076).
    private let feedbackSender = FeedbackSenderFactory.make()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.feedbackSender, feedbackSender)
        }
    }
}
