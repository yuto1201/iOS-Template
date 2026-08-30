# プロダクト方針

Status: 確定  
Version: 1.1
Date: 2026-08-30

## 1. 目的

個人で開発する新しい iOS アプリを、空の Xcode プロジェクトから毎回組み直すのではなく、仕様化・実装・検証・レビュー・リリースの共通部分を再利用できる状態にします。

テンプレートの価値は、機能コードの量ではなく、次の一貫性です。

- 未決事項を抱えたまま実装しない。
- Issue の塊を指定すれば、AI が独立性と依存関係を判断して止まらず進める。
- 各 Issue は動作確認済み、反対モデルレビュー済み、マージ済みの状態で完了する。
- 設定済みの個人用外部アカウント以外を使用しない。
- App Store 申請に必要な情報を後から探し直さない。

## 2. 想定利用者

- プロダクトオーナー: ユーザー本人
- 主開発者: Codex または Claude
- 外部操作実行者: Issueで指定されたCodexまたはClaude
- 反対モデル評価者: 主開発者ではない側のモデル
- 最終実機確認者: ユーザー本人

## 3. 標準プラットフォーム

- UI: SwiftUI
- 言語: Swift
- 非同期処理: Swift Concurrency
- Unit Test: Swift Testing を優先し、既存 XCTest がある場合は併存を許可
- UI Test: XCUITest
- 対応端末: iPhone と iPad
- 対応言語: 日本語と英語
- Xcode、Swift、iOS Deployment Target: アプリ開始時に最新の安定版と要件を確認して仕様に固定

テンプレート自体は特定の将来の Xcode や iOS バージョンを永続的に固定しません。バージョンはアプリごとの決定ログへ記録します。

### 3.1 新しいアプリの開始順序

テンプレートから新しいリポジトリを作成した後は、機能開発より先に次の順序を完了します。

1. Identity入力として、アプリの表示名、Swift モジュール名、アプリ Slug、Bundle IDの4値を確定する。Deployment TargetはIdentity入力とは別のアプリ仕様として確定する。
2. Identity Bootstrap Issue と専用 Branch/worktree を作成する。
3. 共有 bootstrap ツールで、Xcode project、Target、Scheme、ソース、Test、設定、アプリ固有文書を一貫したIdentityへ変換する。
4. Build、Test、標準Simulatorマトリクス、反対モデルレビュー、Squash Mergeを完了する。
5. 変換済みIdentityを基準にFeature Issueを開始する。

アプリ固有の`specs/product.md`と`specs/acceptance.md`がともに**確定**するまでは、Feature Issueを実行に移さない。両仕様のいずれかが未作成、提案、未決、またはIssueの受け入れ条件と矛盾する場合、CodexはIssueを`blocked:user`にし、Branch/worktree作成と実装を始めずにユーザーの確定を求める。

テンプレートリポジトリ自身には将来の実アプリ名を固定しません。GitHub上のリポジトリ名はテンプレートからリポジトリを作成するときに決め、bootstrapツールは認証済みリモート名変更を行いません。

## 4. データ方針

データベースが不要なアプリに外部データベースを導入しません。

- 端末内だけで成立する場合: SwiftData、UserDefaults、Keychain、ファイル保存から要件に合うものを選ぶ。
- 認証、同期、共有、サーバー側データが必要な場合: Supabase を標準とする。
- Supabase のリモート操作: 実行モデルが設定済みOrganization／Projectを確認したうえで行う。
- Supabase のスキーマ正本: `supabase/migrations/*.sql`。
- iOS アプリに渡せる鍵: Project URL と Publishable Key のみ。
- Secret Key、旧 `service_role`、管理権限のある鍵: iOS アプリへ入れない。

## 5. 音声素材方針

テキスト読み上げ、スピーチ変換・文字起こし、効果音、音声分離、音楽、画像、動画が受け入れ条件に必要な場合、CodexまたはClaudeが共有のElevenLabsメディアスキルを使用します。

- 外部生成の実行前に、実行モデルが設定済みAccount／Workspaceとentitlementを照合する。
- 処理前に用途、入出力、長さ・寸法、言語・Voice、ループ、権利・同意、保持方針、ライセンス記録先をモードに応じて仕様化する。
- 音声は試聴・内容・音量・ループ境界、文字起こしは内容・話者・時刻、画像・動画は寸法・時間・表示品質を検証する。
- `paid_plan_required`、権限拒否、moderation、著作権拒否、課金成否が曖昧な要求は自動再試行せず、`blocked:ops` または `blocked:user` として止める。
- 生成・変換・アップロードに使う素材の権利または同意が確認できない場合は処理しない。
- メディアが不要なアプリにはElevenLabs SDKやメディア生成パイプラインを追加しない。

## 6. App Store 方針

ルートの `App Store/` に、申請時に必要な情報を一括管理します。

- `metadata/`: アプリ名、サブタイトル、説明、キーワード、カテゴリ、年齢区分メモ
- `legal/`: プライバシーポリシー、利用規約、サポート情報
- `review/`: App Review 向け説明、テストアカウント手順、審査上の注意点
- `screenshots/`: 端末・言語別の最終素材
- `release-notes/`: バージョン別更新内容
- `submission/`: 申請前チェックと提出結果。秘密値は含めない

申請文面と画像はCodexまたはClaudeが作成・検証し、App Store Connectへの認証済み入力もIssueで指定された実行モデルが行います。法的文書はテンプレートの雛形をそのまま公開せず、アプリのデータ利用実態に合わせて確定します。

## 7. 自動化の範囲

AI は、承認済み仕様を前提として次を止まらず進めます。

1. Issue の分解と依存関係整理
2. GitHub Issue 起票
3. Branch と worktree 作成
4. 実装とテスト
5. Simulator 検証と視覚評価
6. 反対モデルレビュー
7. 指摘修正と再検証
8. PR 作成
9. Squash Merge
10. Branch と worktree の後片付け

ユーザーへの確認は、仕様を変える判断、認証・課金・公開範囲を変える判断、本番の破壊的操作、法的主張の確定に限定します。

## 8. 対象外

- `Config/ownership.yml`にないアカウントまたは未設定targetで認証済み外部操作を行うこと
- ユーザーの実機をAIの自動完了条件に含めること
- 全アプリへ Supabase、課金、通知、分析、音声を先回り導入すること
- プロジェクト固有の Feature や Core ディレクトリを空のまま量産すること
- 反対モデルが利用できない場合の自己承認
- App Store の法的文面をアプリの実態確認なしで公開すること
