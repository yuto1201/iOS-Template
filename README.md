# iOS-Template

Codex を中心に、Claude を実装担当または反対モデルの評価者として併用する個人向け iOS 開発テンプレートです。仕様、Issue、ブランチ、検証、反対モデルレビュー、PR、Squash Merge までを一貫したワークフローとして扱います。

現在は設計確定段階です。テンプレート本体の自動化は [実装計画](./docs/superpowers/plans/2026-08-21-ios-template-foundation.md) に従って段階的に追加します。

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
