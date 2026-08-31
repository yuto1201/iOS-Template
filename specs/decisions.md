# 決定ログ

この文書は追記型です。過去の決定を変更するときは、古い項目を消さず、新しいDecisionで置き換えを記録します。

## D-001: 主開発環境はCodexとする

- Date: 2026-08-21
- Status: 確定
- Decision: 個人iOS開発の主環境はCodexとする。Claudeも実装・修正・ローカル検証に使用できる。
- Consequence: テンプレートは両モデル向けのスキルと評価エージェントを持つ。

## D-002: 認証済み外部操作はCodexだけが行う

- Date: 2026-08-21
- Status: 確定
- Context: ClaudeのGitHub、Supabase、Cloudflareは会社用、Codexは個人用アカウントに紐づく。
- Decision: GitHub remote、Supabase、Cloudflare、ElevenLabs、App Store Connectを含む認証済み外部操作はCodexが行う。ClaudeはCodexへ委託する。
- Consequence: `docs/AUTHORITY.md` を正本とし、ClaudeのPreToolUseフックでも遮断する。

## D-003: CLAUDE.mdを作成しない

- Date: 2026-08-21
- Status: 確定
- Decision: 共通指示は `AGENTS.md` と `specs/`、`docs/` に置く。Claude固有の起動処理は `.claude/settings.json` とフックで実現する。
- Consequence: 同じ規則を2文書へ複製しない。

## D-004: スキルの正本は.agents/skillsとする

- Date: 2026-08-21
- Status: 確定
- Decision: 共有スキルは `.agents/skills/` に置き、`.claude/skills/` から相対シンボリックリンクする。
- Consequence: CodexとClaudeで手順の内容がずれない。モデル固有の形式が必要なエージェント定義だけ分ける。

## D-005: 1 Issue = 1 Branch = 1 PR

- Date: 2026-08-21
- Status: 確定
- Decision: 全実装作業をGitHub Issueにし、IssueごとにBranchとPRを1つ作る。マージはSquashとする。
- Consequence: 履歴の中心はIssueとPRになり、マージ後の作業Branchは削除する。

## D-006: AIがマージまで実行する

- Date: 2026-08-21
- Status: 確定
- Decision: 検証・反対モデルレビュー・修正・pre-merge gateの通過後、CodexがAI実行者としてマージする。
- Consequence: ユーザーは各PRの途中承認を求められず、完成したIssue群を最終確認できる。

## D-007: 反対モデルレビューを必須にする

- Date: 2026-08-21
- Status: 確定
- Decision: Codex実装はClaude、Claude実装はCodexが自動レビューする。利用不能時の自己承認は禁止する。
- Consequence: レビュー結果はBase SHA、Head SHA、Verify SHAに結び付ける。

## D-008: Simulator検証をAIの完了条件とする

- Date: 2026-08-21
- Status: 確定
- Decision: AIの完了条件はSimulatorとAI視覚評価までとする。ユーザーの実機確認は全PR通過後の最終確認とする。
- Consequence: 実機確認で見つかった問題は別のRegression Issueで修正する。

## D-009: iPhone ProとiPad Airを日英で検証する

- Date: 2026-08-21
- Status: 確定
- Decision: バッチ開始時点の最新利用可能iOS Runtime上で、最新iPhone Proと最新iPad Airを日本語・英語の4条件で検証する。
- Consequence: 解決結果をバッチ内で固定し、再現可能な証拠へ保存する。

## D-010: Supabaseは必要な場合だけ採用する

- Date: 2026-08-21
- Status: 確定
- Decision: リモートDBや認証が必要な場合の標準をSupabaseとする。不要なアプリには導入しない。
- Consequence: リモート操作はCodexだけが個人プロジェクトを対象に行う。

## D-011: Supabase migrationsをスキーマの唯一の正本にする

- Date: 2026-08-21
- Status: 確定
- Decision: `supabase/migrations/*.sql` を唯一の正本とし、手動管理の別 `schema.sql` を作らない。
- Consequence: ローカルリセットとリモートPushを同じ履歴から再現できる。

## D-012: 秘密はKeychainを基本とする

- Date: 2026-08-21
- Status: 確定
- Decision: 秘密値はmacOS Keychainを基本とし、ファイル必須の場合だけリポジトリ外の専用ディレクトリへ権限を絞って保存する。
- Consequence: 秘密値をGit、Issue、PR、ログ、プロンプトへ含めない。Claudeからの取得をガードする。

## D-013: ElevenLabsを音声素材の標準生成手段にする

- Date: 2026-08-21
- Status: 確定
- Decision: 効果音やBGMが必要なIssueでは、CodexがElevenLabsスキルを使用する。
- Consequence: 契約上利用不能なエンドポイントは反復せず、代替案を提示する。

## D-014: App Store情報を一つのルートへ集約する

- Date: 2026-08-21
- Status: 確定
- Decision: 提出文面、法的文書、審査メモ、スクリーンショット、リリースノートを `App Store/` に集約する。
- Consequence: Codexが提出前監査とApp Store Connect入力を自動化できる。

## D-015: 機能がない抽象ディレクトリを先回り作成しない

- Date: 2026-08-21
- Status: 確定
- Decision: Xcode標準構成を保ち、`Features/`、`Domain/`、`Data/`、`DesignSystem/` は責務が生じた時だけ追加する。
- Consequence: テンプレート由来の空構造や不要な層を各アプリへ持ち込まない。

## D-016: 最新環境をバッチ単位で固定する

- Date: 2026-08-21
- Status: 確定
- Decision: 最新Runtimeとデバイスを毎Issueで再解決せず、Issueバッチ開始時に解決してバッチ内で固定する。
- Consequence: 最新環境追随と同一バッチの再現性を両立する。

## D-017: 同一原因の自動再試行は3回まで

- Date: 2026-08-21
- Status: 確定
- Decision: 同じ原因が3回連続したら該当Issueを適切なblocked状態にし、無限ループを止める。
- Consequence: 独立Issueは継続できるが、失敗原因を隠して完了にはしない。

## D-018: 物理端末確認は新しい作業を暗黙に再開しない

- Date: 2026-08-21
- Status: 確定
- Decision: ユーザーの実機確認で問題が見つかった場合、元Issueを履歴上書きせずRegression Issueを作る。
- Consequence: マージ時点の証拠と、その後の実機フィードバックを区別できる。

## D-019: Claude実装時も外部オーケストレーションはCodexが担当する

- Date: 2026-08-21
- Status: 確定
- Decision: ClaudeはPrimary implementerになれるが、Issue状態、GitHub remote、外部サービス、マージはCodexが実行する。Claudeからの委託は検証済みJSONと固定ラッパーだけを使う。
- Consequence: Claudeから任意のCodex CLIプロンプトを実行することは禁止し、外部操作とread-onlyレビューを別経路にする。

## D-020: 最初の2件をBootstrap Issueとして手動ゲートで進める

- Date: 2026-08-21
- Status: 確定
- Decision: FoundationとSimulator verificationは、Codexが同じ検証・レビュー・SHA照合を手動実行する。自動化スクリプトが存在しないことだけを例外とする。
- Consequence: 自動化を自動化自身の前提にする循環を避ける。

## D-021: ソース編集Issueの並行上限は2件とする

- Date: 2026-08-21
- Status: 確定
- Decision: 依存がなくファイルが重ならないソース編集Issueは最大2件まで並行化する。Simulator検証は常に直列化する。
- Consequence: 停止時間を減らしつつ、Xcode共有ファイルと検証状態の競合を抑える。

## D-022: 新規アプリのIdentity BootstrapをFeature開発前に必須化する

- Date: 2026-08-22
- Status: 確定
- Supersedes: D-020のBootstrap Issue数と対象範囲を置き換える。D-020の手動ゲート要件自体は維持する。
- Context: GitHub Templateから作成したリポジトリで`TemplateApp`のProject、Target、Scheme、Module、Bundle IDが残ったままFeature開発を始めると、後の名称変更がコード、Test、設定、提出情報の整合性を壊す。
- Decision: リポジトリ作成後に最小Identity仕様を確定し、Identity Bootstrap Issueを機能開発より先に完了する。変換ツールは将来のアプリ名をテンプレートへ固定せず、検証済み引数を使って隔離worktree内で変換を完成させた後、検証済みpatchだけを適用する。Foundation、Identity bootstrap、Simulator verificationの3件をBootstrap Issueとする。
- Consequence: 新しいアプリは一貫した名前とBundle IDからFeature開発を開始できる。リモートリポジトリ名変更やBundle ID登録などの認証済み操作はbootstrap変換へ含めず、Codexの別操作として扱う。

## D-023: ElevenLabsの条件付きメディア処理を一つの共有スキルへ統合する

- Date: 2026-08-29
- Status: 確定
- Supersedes: D-013
- Context: ElevenLabsで効果音とBGMだけでなく、テキスト読み上げ、Voice Changer、文字起こし、音声分離、画像、動画も扱い、CodexとClaudeの不足するメディア制作能力を補う必要がある。
- Decision: 承認済みIssueが必要とする場合だけ、`ios-media-assets`が8つの明示的なモードへ振り分ける。認証済み処理はCodexだけが個人アカウントで実行し、Claudeはローカル準備・検証・統合に限定する。
- Consequence: 重複する`ios-audio-assets`は廃止する。各モードは権利・同意・プライバシー・契約・課金境界を事前確認し、受理した出力とsanitized manifestだけをアプリへ統合する。

## D-024: 外部操作権限をモデルではなく設定済みアカウントへ結び付ける

- Date: 2026-08-30
- Status: 確定
- Supersedes: D-001のモデル間の主従、D-002、D-019、D-014とD-023のCodex専用外部操作部分
- Context: このMacではClaudeとCodexの外部サービス接続をすべて個人用アカウントへ統一でき、会社用接続との分離はクラウド同期ではなく端末単位で管理できる。モデル名による拒否は個人アカウント混同を防ぐための代理制約であり、現在の運用には不要になった。
- Decision: ClaudeとCodexはローカル作業、認証済み外部操作、秘密取得、Issue状態操作、PR作成、Squash Mergeについて同じ権限を持つ。権限はモデル名ではなく、`Config/ownership.yml`の安定識別子、Issue contractのoperation／Executor、対象、環境、Head SHA、ユーザー承認によって決める。Claude固有の外部操作拒否hookとCodex委託専用transportは廃止する。
- Consequence: どちらのモデルも指定外アカウント、未設定target、曖昧な認証sessionではfail closedになる。評価エージェントのread-only制限、秘密非露出、課金・破壊・法的操作のユーザー承認は維持する。

## D-025: 日常開発を速度優先のリスクベースゲートへ変更する

- Date: 2026-08-30
- Status: 確定
- Supersedes: D-007、D-008、D-009の全Issue一律適用。D-005、D-012、D-017、D-018、D-024の安全境界は維持する。
- Context: 全Headへ4条件Simulator、画像評価、反対モデルreview、exact evidence closureを適用すると、非UIのドメイン／永続化Issueでも小さな修正ごとに完全検証が失効し、実装時間より検証反復が長くなる。実運用では同一Issueに複数Head分の完全証拠が生成され、個人開発の進行速度を大きく落とした。
- Decision: 新規Issueは`fast`、`standard`、`strict`のdelivery profileと理由を明示する。`fast`は非UI・低リスク変更を現在HeadのBuild、対象Test、必要なrepository testだけで完了でき、4条件Simulator、画像評価、blockingな反対モデルreviewを要求しない。`standard`は通常UI変更に使用し、開発中は対象Testを優先して、安定した最終候補Headにだけ4条件Simulator、画像評価、反対モデルreviewを実行する。`strict`は認証・認可、秘密、DB migration、本番データ、破壊的操作、課金、privacy・法務、App Store／TestFlight、署名、delivery gate自体へ現在の完全ゲートを適用する。未指定の既存Issueは`strict`として扱う。
- Consequence: 日常の実装ループは短くなる一方、外部アカウント完全一致、秘密非露出、必要なユーザー承認、main直接変更禁止、1 Issue = 1 Branch = 1 PR、Squash Merge、Merge直前のHead SHA照合は全profileで維持される。strict対象operationを低いprofileへ指定した場合はfail closedになる。

## D-026: AppLibraryのアプリサイトを法務ページの公開先とする

- Date: 2026-08-31
- Status: 確定
- Supersedes: None。D-014の申請原稿集約を補足し、D-024の外部操作権限とD-025の検証方針は維持する。
- Context: ユーザーは、開発中のAppLibraryの一覧から各アプリWebサイトへ案内し、そのサイト内へ利用規約・プライバシーポリシーを設ける方針を指定した。Cloudflareはドメイン・DNS管理、Web公開はVercelへ統一し、app.yutodev.comの移行は別途進行中である。
- Decision: 申請準備で法務ページが必要になったら、[プロダクト方針 §6.1](product.md#61-applibraryでの法務ページ公開方針)に従い、各アプリのApp Store原稿を基にAppLibraryから案内されるアプリサイトへ公開する。Cloudflare Pagesは使わない。具体的な配置・パス・公開URL・Vercel projectはユーザーの後日指定事項として残し、今回確定しない。
- Consequence: 方針の文書化と独立したアプリ開発・原稿準備は進められる。公開先が必要な作業だけを確認待ちにし、ユーザー指定後に配置を確定する。法務本文の実態照合・初回承認・公開到達性の確認を維持し、サイト移行・デプロイ・DNS変更・App Store提出はこの決定だけでは実行しない。
- Related Issue: #27

## D-027: 日本語iPhoneで機能を固めてから英語とiPadを仕上げる

- Date: 2026-08-31
- Status: 確定
- Supersedes: D-009とD-025の通常UI Issueにおける4条件一律適用。D-025の危険度分類とレビュー、安全・account・Head照合の境界は維持する。
- Context: 実際にテンプレートで開発すると、日本語・英語、iPhone・iPadを毎機能で同時に完成させる作業が反復し、主要機能の進行を遅らせた。ユーザーは日本語iPhoneを先に作り、英語・iPadを最後に仕上げる方針を承認した。
- Decision: [段階的開発仕様](development-stages.md)に従い、通常機能開発は日本語iPhone、主要機能と画面遷移が安定したら英語・iPad仕上げ、リリース候補は4条件で確認する。delivery profileと検証範囲を分離し、localization・可変レイアウト・accessibilityの土台とデータ・権限・課金の正しさは初期から維持する。
- Consequence: 翻訳・iPad最適化を仕上げIssueへ集約し、リリースIssueの依存にする。既存snapshotを縮小せず、未検証の言語・端末を成功扱いしない。実行ツールは現在4条件固定なので、#19・#29の既存修正に続く#32で1条件経路を実装するまで現行canonicalゲートを維持する。方針記載だけでツール対応済みとは報告しない。
- Related Issue: #31、#32
