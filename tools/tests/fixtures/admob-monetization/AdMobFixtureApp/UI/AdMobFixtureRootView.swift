import SwiftUI

struct AdMobFixtureRootView: View {
    @StateObject private var system = AdMobFixtureRuntimeFactory.makeSystem()

    var body: some View {
        TabView {
            Tab("ホーム", systemImage: "house") {
                FixtureHomeView(system: system)
            }

            Tab("設定", systemImage: "gearshape") {
                FixtureSettingsView(runtime: system.runtime)
            }
        }
        .accessibilityIdentifier("admob.fixture.tabs")
        .task {
            await system.runtime.bootstrapConsent(from: nil)
        }
    }
}

private struct FixtureHomeView: View {
    let system: AdMobFixtureSystem

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    FixtureHeader()
                    FixtureBannerStatus(renderer: system.renderer)
                    FixtureInformationCard(
                        title: "オフライン検証",
                        detail: "通信せずに広告枠の配置と状態遷移を確認します。",
                        systemImage: "wifi.slash"
                    )
                    FixtureInformationCard(
                        title: "同意を先に確認",
                        detail: "広告リクエストより前に同意情報と対象条件を評価します。",
                        systemImage: "checkmark.shield"
                    )
                    FixtureInformationCard(
                        title: "重複リクエストを防止",
                        detail: "再描画やタブ再選択でも同じ広告を再要求しません。",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    FixtureInformationCard(
                        title: "Safe area を確保",
                        detail: "コンテンツの末尾を広告枠の下へ隠しません。",
                        systemImage: "rectangle.inset.filled"
                    )
                    FixtureInformationCard(
                        title: "表示幅へ追従",
                        detail: "画面から提案された幅でバナーの高さを更新します。",
                        systemImage: "arrow.left.and.right"
                    )
                    FixtureContentEnd()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier("admob.fixture.scroll")
            .navigationTitle("広告配置テスト")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AdaptiveBannerHost(
                    runtime: system.runtime,
                    renderer: system.renderer,
                    placement: AdMobPlacementContext(
                        screenID: "home",
                        adUnitID: "offline-banner"
                    )
                )
                .accessibilityIdentifier("admob.fixture.banner-host")
            }
        }
    }
}

private struct FixtureBannerStatus: View {
    @ObservedObject var renderer: OfflineBannerRenderer

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("admob.fixture.banner-state")
    }

    private var label: String {
        switch renderer.lastState {
        case .visible:
            "広告状態: 表示中"
        case .collapsed:
            "広告状態: 折りたたみ"
        case .idle, .loading:
            "広告状態: 準備中"
        }
    }
}

private struct FixtureHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日本語 iPhone フィクスチャ")
                .font(.title2.bold())
                .accessibilityIdentifier("admob.fixture.home-title")

            Text("TabView、ScrollView、safe area と可変幅バナーを一つの決定論的な画面で検証します。")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct FixtureInformationCard: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }

            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct FixtureContentEnd: View {
    var body: some View {
        Text("コンテンツの末尾")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
            .accessibilityIdentifier("admob.fixture.content-end")
    }
}

private struct FixtureSettingsView: View {
    @ObservedObject var runtime: AdMobRuntimeCoordinator

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("このフィクスチャは非トラッキング構成です。ATT は起動せず、Publisher first-party ID を無効にします。")
                    .font(.body)

                Button(
                    "プライバシー設定を開く",
                    action: {
                        Task {
                            _ = try? await runtime.presentPrivacyOptions(
                                from: nil
                            )
                        }
                    }
                )
                .buttonStyle(.borderedProminent)
                .disabled(!runtime.isPrivacyOptionsRequired)
                .accessibilityIdentifier("admob.fixture.privacy-options")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .navigationTitle("設定")
        }
    }
}
