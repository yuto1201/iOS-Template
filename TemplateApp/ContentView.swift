//
//  ContentView.swift
//  TemplateApp
//
//  Created by 上杉侑斗 on 2026/08/21.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "app.dashed")
                .font(.largeTitle)
                .accessibilityHidden(true)

            Text("template.welcome")
                .font(.headline)
                .accessibilityIdentifier("template.welcome-title")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
