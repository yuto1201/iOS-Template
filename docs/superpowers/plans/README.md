# Implementation plans

テンプレート本体は、次の順で4つの独立Issueとして実装します。各計画は単独でレビュー・検証・Squash Mergeでき、後続計画は前段の公開インターフェースだけへ依存します。

1. [Foundation](./2026-08-21-ios-template-foundation.md): 最小iOSアプリ、日英、iPhone/iPad、共通指示と評価エージェント
2. [Security and workflow](./2026-08-21-security-workflow-automation.md): Claudeガード、Issue/Branch/PR/Squash Merge自動化
3. [Simulator verification](./2026-08-21-ios-simulator-verification.md): 最新端末解決、4条件検証、証拠、pre-merge連携
4. [Integrations and release](./2026-08-21-integrations-appstore-release.md): Supabase、ElevenLabs、App Store資産と提出フロー

各Issueを開始する時点で、当該計画と `specs/` をIssue本文から参照します。前のIssueがマージされるまで、依存する次のIssueを開始しません。

