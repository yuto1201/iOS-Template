# iOS-Template agent contract

このファイルは Codex と Claude に共通する、短く変更頻度の低いルールだけを定めます。詳細はリンク先を正とします。`CLAUDE.md` は作成しません。

## 読む順番

1. `specs/README.md`
2. 担当 Issue が参照する `specs/` 文書
3. `specs/decisions.md`
4. `docs/AUTHORITY.md`
5. `docs/security.md`
6. `docs/workflow.md`
7. `docs/verification.md`
8. 反対モデルレビュー時は `docs/agent-contracts/review-packet.md`

確定仕様と矛盾する実装をしないでください。未決事項が受け入れ条件を変える場合は `blocked:user` とし、実装を始めません。

## 絶対ルール

- 1 Issue = 1 Branch = 1 PR。
- `main` へ直接コミットまたは直接 Push しない。
- Issue の受け入れ条件外へ機能を広げない。
- 実行していない Build、Test、Simulator 操作を成功として報告しない。
- `standard`／`strict`は反対モデルの承認を必須とし、`fast`は現在HeadのBuild・対象Test証拠だけでマージできる。
- マージはIssueで指定されたCodexまたはClaudeが `--squash` と Head SHA 照合を使って実行する。
- ユーザーの既存変更、認証情報、生成物を上書きまたは削除しない。

## 外部操作の権限

ClaudeとCodexは同じ権限を持ち、どちらもローカル作業と認証済み外部操作を実行できます。権限はモデル名ではなく、`Config/ownership.yml`の許可済みアカウント／target、Issue contractのoperation／Executor、環境、Head SHA、ユーザー承認で決まります。

外部操作の直前に実行モデルがアクティブなアカウントと対象リソースを完全一致で確認します。指定外アカウント、未設定target、曖昧な認証sessionでは操作しません。詳細は `docs/AUTHORITY.md` を参照してください。

## 標準検証

Issueに`fast`、`standard`、`strict`のdelivery profileと理由を明示します。未指定の既存Issueは`strict`です。

- `fast`: 非UI・低リスク。Buildと対象Testだけを実行し、4条件Simulator、画像評価、blockingな反対モデルレビューは行わない。
- `standard`: 通常のUI変更。機能開発は日本語iPhoneと対象Testを優先し、安定した最終候補Headで要求範囲のSimulator・画像評価と反対モデルレビューを行う。
- `strict`: 認証・認可、秘密、migration、本番データ、課金、法務、リリース、workflow gate変更。対象別Test・安全確認・必要な承認を維持する。

[段階的開発仕様](specs/development-stages.md)に従い、通常機能は日本語iPhone、主要機能が安定したら英語・iPadを仕上げ、リリース前に4条件を確認します。文字列管理・可変レイアウトの土台は初期から保ち、翻訳・iPad最適化の延期先をIssueへ記載します。危険度と検証範囲を混同せず、UIを`fast`へ偽装しません。

**移行中:** 1条件でのcanonical完了経路は[Issue #32](https://github.com/yuto1201/iOS-Template/issues/32)の実装待ちです。それまでは`standard`／`strict`の現行4条件ゲートを維持します。未指定の既存Issueも4条件です。未確認の英語・iPadを成功扱いしません。

現行の4条件および仕上げ・リリースの`full`は、バッチ開始時に最新の利用可能なiOS Runtimeを解決し、そのバッチ内で固定します。

- 最新 iPhone Pro（Pro Max を除く）、英語
- 最新 iPhone Pro（Pro Max を除く）、日本語
- 最新 iPad Air、英語
- 最新 iPad Air、日本語

ユーザーの実機確認は AI の完了条件に含めません。詳細は `docs/verification.md` を参照してください。
