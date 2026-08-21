//
//  TemplateAppTests.swift
//  TemplateAppTests
//
//  Created by 上杉侑斗 on 2026/08/21.
//

import Foundation
import Testing
@testable import TemplateApp

struct TemplateAppTests {

    @Test("Welcome message is localized in English and Japanese")
    func welcomeMessageLocalizations() {
        #expect(localizedValue(for: "template.welcome", language: "en") == "Ready to build")
        #expect(localizedValue(for: "template.welcome", language: "ja") == "開発を始められます")
    }

    private func localizedValue(for key: String, language: String) -> String? {
        guard let localizationURL = Bundle.main.url(
            forResource: language,
            withExtension: "lproj"
        ), let localizationBundle = Bundle(url: localizationURL) else {
            return nil
        }

        return localizationBundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
