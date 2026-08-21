# iOS-Template

Codex を中心に、Claude を実装担当または反対モデルの評価者として併用する個人向け iOS 開発テンプレートです。仕様、Issue、ブランチ、検証、反対モデルレビュー、PR、Squash Merge までを一貫したワークフローとして扱います。

Foundation は利用可能です。最小の SwiftUI アプリ、Unit/UI Test、英語・日本語、iPhone・iPad、共有仕様スキル、Codex/Claude 共通責務の read-only 評価エージェントを含みます。運用自動化は [実装計画索引](./docs/superpowers/plans/README.md) に従って段階的に追加します。

## Foundation の検証

リポジトリ方針は次で検証します。

```sh
tools/tests/test-foundation.sh
```

Build と Test は、インストール済み Xcode から [標準 Simulator マトリクス](./docs/verification.md#3-固定されるmatrix)を解決し、Issue バッチ内で固定して実行します。次は Foundation 検証で使うコマンド形です。`TEMPLATE_IPHONE_UDID` と `TEMPLATE_IPAD_UDID` には、同じ最新 iOS Runtime の iPhone Pro（Pro Max を除く）と13-inch iPad Airを指定します。

```sh
TEMPLATE_IPHONE_UDID="<resolved-iPhone-Pro-UDID>"
TEMPLATE_IPAD_UDID="<resolved-iPad-Air-13-inch-UDID>"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPHONE_UDID}" \
  -derivedDataPath .artifacts/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test -only-testing:TemplateAppTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPHONE_UDID}" \
  -derivedDataPath .artifacts/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testEnglishWelcomeTitle

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPHONE_UDID}" \
  -derivedDataPath .artifacts/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testJapaneseWelcomeTitle

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPAD_UDID}" \
  -derivedDataPath .artifacts/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testEnglishWelcomeTitle

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPAD_UDID}" \
  -derivedDataPath .artifacts/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testJapaneseWelcomeTitle
```

証拠の形式、画像評価、Head SHA 一致条件は [iOS verification](./docs/verification.md) を正とします。Simulator のUDIDと結果ファイルは環境固有なのでGitへ追加しません。

## 新しいアプリとして使い始めるとき

- Xcodeが生成した個人のSigning Teamは初期値として残しています。別の所有者が利用する場合は、XcodeのSigning & Capabilitiesで自分のTeamへ変更します。`Config/ownership.yml` のApp Store Team IDとBundle IDは、アプリ固有の提出先が決まるまで`null`のままにします。
- Deployment Targetはテンプレート生成時のXcode既定値です。対象ユーザーと必要APIを決め、実装Issueを始める前にアプリ固有の最小OSを仕様とXcode設定へ固定します。
- ローカル設定は `Config/Local.xcconfig.example` を参考に、Git管理外の `Config/Local.xcconfig` へ置きます。秘密値はxcconfigへも保存せず、Keychainまたは各サービスの秘密管理を使います。

### Identity bootstrap

機能開発より先に、表示名、Swiftモジュール名、lowercase kebab-caseのアプリSlug、逆DNS形式のBundle IDという4つのIdentity入力を確定します。Deployment Targetはこれらと分けてアプリ仕様とXcode設定へ確定します。承認済みのIdentity Bootstrap Issueに対応するクリーンな非default Branch/worktreeで、リポジトリルートから次を実行します。

```sh
tools/bootstrap-app.sh \
  --display-name 'Garden Notes' \
  --module-name GardenNotes \
  --app-slug garden-notes \
  --bundle-id com.yuto.GardenNotes
```

コマンドは、Xcode project、Target、Scheme、Swift Module、Test、Bundle ID、設定、現行文書を一つのIdentityへ変換し、確認用の変更をunstagedで残します。標準出力は`applied`と結果パスを含むsanitized JSONで、非秘密の完全な結果は`Config/app-identity.json`へschema version 1として保存されます。`git diff`を確認してからFoundation、Xcode、4条件Simulator、反対モデルレビューを実行してください。共通の手順は[App Bootstrap skill](./.agents/skills/app-bootstrap/SKILL.md)を正とします。

同じ4入力で再実行すると`already-complete`を返して何も変更しません。1値でも異なる再実行は、既存結果と競合するため変更前に失敗します。GitHub上のリポジトリ名変更とApple側のBundle ID登録はこのコマンドに含まれず、それぞれCodexが個人アカウントを確認して別操作として行います。

### Feature開発開始ゲート

Feature IssueのBranch/worktreeを作る前に、アプリ固有の`specs/product.md`と`specs/acceptance.md`がともに`Status: 確定`で、そのIssueの受け入れ条件と一致していることを確認します。未作成、確定前、または不一致なら、CodexがIssueを`blocked:user`へ遷移させ、Branch/worktree作成と実装を開始しません。

## 最初に読む文書

1. [仕様索引](./specs/README.md)
2. [プロダクト方針](./specs/product.md)
3. [テンプレート構成](./specs/architecture.md)
4. [受け入れ条件](./specs/acceptance.md)
5. [決定ログ](./specs/decisions.md)
6. [権限境界](./docs/AUTHORITY.md)
7. [Issue からマージまでの運用](./docs/workflow.md)
8. [秘密管理](./docs/security.md)
9. [Simulator 検証](./docs/verification.md)
10. [公式資料](./docs/references.md)

## 設計の由来

- `Flower`: Issue 単位の証拠管理、視覚評価、作業完了ゲート
- `Elsefolk`: 仕様の確定・提案・未決の分離、決定ログ、実測を伴う完了報告
- `CafLog`: 日本語・英語対応、iPhone・iPad、App Store 用素材の管理
- 今回の確定方針: Codex の個人アカウントだけが認証済み外部操作を担当し、Claude はローカルの実装・修正・検証に限定する

参照プロジェクト固有の画面、データモデル、アーキテクチャ、`CLAUDE.md` は継承しません。

## 基本原則

- 仕様が未決のまま実装を開始しない。
- 1 Issue = 1 Branch = 1 PR とする。
- AI が Simulator 検証、反対モデルレビュー、修正、PR、Squash Merge まで進める。
- ユーザーによる実機確認は、AI の Definition of Done の後に行う最終確認とする。
- 外部アカウント操作は常に Codex が行う。
- 秘密値は Git、Issue、PR、ログ、スクリーンショット、AI プロンプトに残さない。
