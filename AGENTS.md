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
- 反対モデルの承認と、現在の Head SHA に一致する検証証拠がなければマージしない。
- マージはIssueで指定されたCodexまたはClaudeが `--squash` と Head SHA 照合を使って実行する。
- ユーザーの既存変更、認証情報、生成物を上書きまたは削除しない。

## 外部操作の権限

ClaudeとCodexは同じ権限を持ち、どちらもローカル作業と認証済み外部操作を実行できます。権限はモデル名ではなく、`Config/ownership.yml`の許可済みアカウント／target、Issue contractのoperation／Executor、環境、Head SHA、ユーザー承認で決まります。

外部操作の直前に実行モデルがアクティブなアカウントと対象リソースを完全一致で確認します。指定外アカウント、未設定target、曖昧な認証sessionでは操作しません。詳細は `docs/AUTHORITY.md` を参照してください。

## 標準検証

Issue バッチ開始時に最新の利用可能な iOS Runtime を解決し、そのバッチ内で固定します。

- 最新 iPhone Pro（Pro Max を除く）、英語
- 最新 iPhone Pro（Pro Max を除く）、日本語
- 最新 iPad Air、英語
- 最新 iPad Air、日本語

ユーザーの実機確認は AI の完了条件に含めません。詳細は `docs/verification.md` を参照してください。
