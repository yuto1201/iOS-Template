# 仕様索引

`specs/` は、実装内容と受け入れ条件の正本です。運用手順は `docs/`、反復可能な手続きは `.agents/skills/`、モデル固有のエージェント定義は `.codex/agents/` と `.claude/agents/` に置きます。

## 文書

| 文書 | 内容 |
| --- | --- |
| [product.md](./product.md) | テンプレートの目的、標準技術、対象・対象外 |
| [architecture.md](./architecture.md) | リポジトリ構造、責務、条件付きモジュール |
| [acceptance.md](./acceptance.md) | テンプレートとIssueの完了条件 |
| [development-stages.md](./development-stages.md) | 日本語iPhone優先の開発順序、仕上げ、検証範囲と移行境界 |
| [decisions.md](./decisions.md) | 確定した判断と変更理由 |

## 判断の状態

- **確定**: 実装可能。変更には `decisions.md` の追記が必要。
- **提案**: 比較・相談中。受け入れ条件へ影響する場合は実装不可。
- **未決**: ユーザー判断待ち。関連 Issue は `blocked:user`。
- **廃止**: 現行仕様として使用しない。

本テンプレートの初期設計には、実装を止める未決事項を残しません。新しいアプリ固有の仕様は、Issue を起票する前に確定・提案・未決へ分類します。

## 優先順位

矛盾した場合は次の順に優先します。

1. 現在のユーザー指示
2. 承認済みの Issue 受け入れ条件
3. `specs/acceptance.md`
4. `specs/architecture.md`
5. `specs/product.md`
6. `docs/`
7. 既存コードからの推測

`specs/decisions.md` は、上位の判断がなぜ存在するかを記録します。過去の決定と現行仕様が異なる場合は、最新の有効な決定を採用します。

## 仕様変更手順

1. 変更理由、影響する受け入れ条件、移行方法を整理する。
2. ユーザーと相談し、状態を確定する。
3. `decisions.md` に新しい決定を追加する。過去の行を黙って書き換えない。
4. 関連仕様と Issue を更新する。
5. 実装 Issue を開始する。
