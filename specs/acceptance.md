# 受け入れ条件

Status: 確定  
Version: 1.0  
Date: 2026-08-21

## 1. テンプレート完成条件

- [ ] 最小の SwiftUI アプリが iPhone と iPad で起動する。
- [ ] 新規リポジトリのIdentity bootstrapが、検証済み入力からXcode project、Target、Scheme、Module、Test、Bundle ID、設定を一貫して変換できる。
- [ ] Unit Test と UI Test のサンプルが実行できる。
- [ ] 日本語と英語を切り替えて主要画面を検証できる。
- [ ] `.agents/skills/` のCoreスキルをCodexとClaudeの双方から利用できる。
- [ ] `.codex/agents/` と `.claude/agents/` に同等責務の評価エージェントがある。
- [ ] Claudeの認証済み外部操作がPreToolUseフックで拒否される。
- [ ] Codexの外部操作前チェックが個人アカウントと対象リソースを表示する。
- [ ] IssueからSquash Merge・Branch削除までのドライランテストが通る。
- [ ] 最新iPhone Proと最新iPad Airを日英で解決し、バッチ内で固定できる。
- [ ] Head SHAが異なる古い検証・レビューではpre-merge gateが失敗する。
- [ ] 秘密値が追跡ファイル、ログ、Issue/PR本文へ混入していない。
- [ ] `App Store/` に提出情報の構造と検証スクリプトがある。
- [ ] Supabaseと音声生成を使わない初期アプリへ、それらのSDKや設定が入っていない。
- [ ] README、仕様、運用文書、スキル、ツール間のリンク検証が通る。

## 2. Issue Definition of Ready

次が揃うまでIssueを `in-progress` にしません。

- Goal が一文で定義されている。
- 対象内と対象外が分かれている。
- 検証可能な受け入れ条件がある。
- 関連仕様のパスと節が記載されている。
- 各受け入れ条件に `AC-1` から始まる安定したIDがある。
- 依存IssueとBlockerが記載されている。
- UI変更の場合、対象画面・状態・日英の期待が記載されている。
- 外部サービスを使う場合、サービス、環境、Codex実行が指定されている。
- 法的、課金、本番破壊操作を伴う場合、必要なユーザー承認が記載されている。

## 3. Issue Definition of Done

次をすべて満たしたIssueだけを完了とします。

1. 受け入れ条件を満たす実装がある。
2. 対象BuildとTestが実行済みで成功している。
3. UIに関係する変更は標準Simulatorマトリクスで確認済み。
4. AIがスクリーンショットと操作結果を評価済み。
5. 検証証拠のCommit SHAが現在のHead SHAと一致する。
6. 反対モデルがレビューし、未解決の重大指摘がない。
7. レビュー対象のHead SHAが現在のHead SHAと一致する。
8. PR本文にIssue、仕様、検証、レビューの要約がある。
9. CodexがSquash Mergeした。
10. リモートBranch、ローカルBranch、worktreeを安全に後片付けした。
11. GitHub Issueが完了状態になっている。

ユーザーの実機確認は、このDefinition of Doneの後に行います。実機で問題が見つかった場合は、新しいRegression Issueとして扱います。

## 4. 標準Simulatorマトリクス

| Family | Device | Locale | Language |
| --- | --- | --- | --- |
| iPhone | 最新の利用可能なiPhone Pro。Pro Maxを除く | `en_US` | `en` |
| iPhone | 同上 | `ja_JP` | `ja` |
| iPad | 最新の利用可能なiPad Air | `en_US` | `en` |
| iPad | 同上 | `ja_JP` | `ja` |

「最新」はIssueバッチ開始時にインストール済みXcodeから解決し、バッチ中は固定します。条件に合うデバイスがなければ `blocked:environment` とし、黙って別モデルへ変更しません。

## 5. 品質ゲート

- Build warningを新規に増やさない。
- 失敗テストを削除・Skipして成功扱いにしない。
- ユーザー向け文字列は日本語と英語の両方を用意する。
- Dynamic Type、VoiceOverラベル、タップ領域、色コントラストを変更範囲に応じて確認する。
- iPadで単にiPhone画面を拡大せず、レイアウト破綻がないことを確認する。
- 秘密、個人情報、会社アカウント識別子を証拠へ含めない。
- 外部操作の成功はCodexが実応答から確認し、推測で記録しない。

## 6. 失敗と再試行

- 同じ原因の失敗が3回続いたら自動再試行を止める。
- レビュー不能は `blocked:review`。
- 外部認証・契約・レート制限は `blocked:ops`。
- Xcode、Runtime、Simulator不足は `blocked:environment`。
- 仕様判断不足は `blocked:user`。
- 依存Issue未完了は `blocked:dependency`。

Pre-mergeの失敗は同じIssueで修正します。マージ後に判明した不具合だけ、新しいRegression Issueを作ります。

## 7. Bootstrap Issue

自動化ツール自身を作る最初の3件だけは、まだ存在しないツールを完了条件にできません。Foundation Issue、Identity bootstrap Issue、Simulator verification IssueをBootstrap Issueとし、Codexが次を手動で実行します。

- 個人GitHubアカウント確認、Issue、Branch、Push、PR、Squash Merge、後片付け
- Head SHAを明記したBuild・Test・4条件Simulator結果のPR記録
- 反対モデルのread-onlyレビューと、対象Head SHAのPR記録
- `--match-head-commit` によるSquash Merge

Bootstrapで免除されるのは、未実装の自動スクリプトを通すことだけです。Build、Test、標準Simulatorマトリクス、反対モデルレビュー、SHA一致は免除しません。Identity bootstrapは使い捨てのテンプレート生成リポジトリでも同じ検証を行います。Simulator verification Issueがマージされた後は検証ツールを使い、Security and workflow Issueがマージされた後は全自動ゲートを使います。
