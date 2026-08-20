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
