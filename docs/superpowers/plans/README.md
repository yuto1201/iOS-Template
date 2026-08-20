# Implementation plans

テンプレート本体は、次の順で4つの逐次Issueとして実装します。各計画は単独でレビュー・検証・Squash Mergeできますが、後続計画は前段の公開インターフェースへ依存します。

1. [Foundation](./2026-08-21-ios-template-foundation.md): 最小iOSアプリ、日英、iPhone/iPad、共通指示と評価エージェント
2. [Simulator verification](./2026-08-21-ios-simulator-verification.md): 最新端末解決、4条件検証、証拠
3. [Security and workflow](./2026-08-21-security-workflow-automation.md): Claudeガード、Issue/Branch/PR/Squash Merge自動化と検証証拠のゲート統合
4. [Integrations and release](./2026-08-21-integrations-appstore-release.md): Supabase、ElevenLabs、App Store資産と提出フロー

各Issueを開始する時点で、当該計画と `specs/` をIssue本文から参照します。前のIssueがマージされるまで、依存する次のIssueを開始しません。

FoundationとSimulator verificationはBootstrap Issueです。CodexがIssue、Branch、Push、PR、4条件検証、反対モデルレビュー、Head SHA照合、Squash Merge、後片付けを手動で行います。自動化スクリプトが未実装であること以外は通常の完了条件を省略しません。Security and workflowがマージされた後、すべてのIssueを自動状態機械へ移行します。
