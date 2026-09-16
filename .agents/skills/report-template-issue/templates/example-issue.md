## Goal

派生アプリで確認した共有スキル参照の不整合を、テンプレートのportableな構成として再発防止する。この本文は構造検証用の合成例であり、実在Issueとして投稿しない。

## In scope

- `.agents/skills/example-skill/` と `.claude/skills/example-skill` の参照関係を確認する。
- portable symlinkと関連文書の整合を対象testで検証する。
- Expected write-set: 共有skill、Claude参照、専用test、関連仕様文書。

## Out of scope

- アプリ画面または製品機能の変更。
- 実在する外部Issueの作成。
- 認証、provider、merge gateの変更。

## Acceptance criteria

- AC-1: UI-direction route: not-applicable; Scope: 共有スキル参照と運用文書; Reason: アプリUI、画面階層、navigation、主要操作を変更しない。正本と共有参照が同じskillへ解決される。
- AC-2: Repository-test scope: targeted; Reason: 共有スキル参照の既知domainだけを検証する。portable symlinkと文書anchorの回帰testが通る。

## Spec anchors

- [テンプレートの目的](specs/product.md#1-目的)
- [共有スキル構成](specs/architecture.md#5-スキル構成)
- [Issue Definition of Ready](specs/acceptance.md#2-issue-definition-of-ready)

## Dependencies

None

## UI verification

Not applicable

## Delivery stage

- Stage: harden
- Time budget: 60 minutes
- Reason: 既存の共有スキル参照を狭く改善するworkflow-only変更。

## Delivery profile

- Profile: strict
- Reason: 複数agentが利用するdelivery workflowの参照境界を変更するため、現在Headの反対モデルレビューを行う。

## External operations

- Operation: github.read_issue
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

- Operation: github.update_issue
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

- Operation: github.push_branch
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

- Operation: github.create_pr
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

- Operation: github.merge_pr
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

- Operation: github.delete_branch
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

## User approvals

No additional approval
