import SwiftUI

/// Where the app's legal and support pages live (D-072): `https://app.yutodev.com/apps/<appSlug>/...`.
/// The slug comes from `LegalLinks.json`, which the app bundles. The template ships it empty, so the
/// links stay hidden until the app's pages are published and the slug from `Config/app-identity.json`
/// is written there. App Review asks for an in-app link to the privacy policy (guideline 5.1.1(i)) and
/// an easy way to contact the developer (1.5); see D-081.
nonisolated struct LegalLinks: Equatable {
    static let resourceName = "LegalLinks"
    static let host = "app.yutodev.com"

    let privacyPolicy: URL
    let termsOfUse: URL
    let support: URL

    private struct Settings: Decodable {
        let appSlug: String
    }

    /// Nil unless the slug is lower-case letters and digits joined by single hyphens, like `appSlug`.
    init?(appSlug: String?) {
        guard let appSlug, appSlug.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil,
              let privacyPolicy = Self.page(appSlug, "privacy"),
              let termsOfUse = Self.page(appSlug, "terms"),
              let support = Self.page(appSlug, "support") else { return nil }
        self.privacyPolicy = privacyPolicy
        self.termsOfUse = termsOfUse
        self.support = support
    }

    private static func page(_ appSlug: String, _ kind: String) -> URL? {
        URL(string: "https://\(host)/apps/\(appSlug)/\(kind)/")
    }

    static func appSlug(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return nil }
        return settings.appSlug
    }

    /// The bundled setting, or in a Debug build the slug after `-LegalLinksAppSlug` (screenshots and UI tests).
    static func current(
        bundle: Bundle = .main,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> LegalLinks? {
        if let slug = debugAppSlug(arguments: arguments) {
            return LegalLinks(appSlug: slug)
        }
        return LegalLinks(appSlug: appSlug(bundle: bundle))
    }

    static func debugAppSlug(arguments: [String]) -> String? {
        #if DEBUG
        guard let index = arguments.firstIndex(of: "-LegalLinksAppSlug"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }
}

/// Links to the privacy policy, terms of use and support pages. Hidden until the app has its pages.
/// The template shows them under the feedback entry; an app moves them into its own Settings section.
struct LegalLinksView: View {
    private let links = LegalLinks.current()

    var body: some View {
        if let links {
            VStack(spacing: 0) {
                link("legal.privacy-policy", destination: links.privacyPolicy, identifier: "legal.privacy-policy")
                link("legal.terms-of-use", destination: links.termsOfUse, identifier: "legal.terms-of-use")
                link("legal.support", destination: links.support, identifier: "legal.support")
            }
            .font(.footnote)
        }
    }

    private func link(_ title: LocalizedStringKey, destination: URL, identifier: String) -> some View {
        Link(title, destination: destination)
            .frame(minHeight: 44)
            .accessibilityIdentifier(identifier)
    }
}
