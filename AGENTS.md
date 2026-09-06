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
- 現在のユーザーが対象範囲のHTML比較を明示した場合は確定方向の有無にかかわらず最優先で[UI Direction skill](.agents/skills/ui-direction/SKILL.md)を使い、明示省略は現行性、scope、権限、理由が明確で比較指示と矛盾しないときだけ通常判定を上書きする。それ以外は、exact hierarchy／flowを覆う確定方向があればconfirmed-direction reuse、覆う方向がなく対象方向が未確定かつ最初のユーザー向けUI、ルートnavigation／information hierarchyの新設・変更、主要flowの大幅な再設計のいずれかならGate、方向未確定かつその3 triggerなしならAcceptance criteriaがhierarchy／navigation／primary-flow interactionを決めない範囲だけbounded direction-neutralとし、曖昧ならGateを実行する。
- cutover後にClaimするcontractは、既存Acceptance criteria全体でexactly oneの有効な宣言を持つ。一つのAC本文先頭（`AC-*:`直後）をexact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`で開始し、routeは`comparison`、`explicit-skip`、`confirmed-direction reuse`、`bounded direction-neutral`、`not-applicable`だけを許可する。固有事実はReason後へ続け、prefix外のroute語は数えない。確定anchorを`Spec anchors`、選択前提をDependenciesへ置く。cutover後のIdentity bootstrapと純非UIは`not-applicable`を宣言し、`UI verification`はexact `Not applicable`だけ、scope／非UI理由はGoal／In scope等と宣言、関連product／spec anchorは`Spec anchors`へ分け、UI方向anchorを要求しない。UI Issueの3 field `UI verification`はlive guidanceであり、最終reviewの正本にしない。
- D-030 cutoverは`2026-09-06T00:31:41Z`。封印済みcontractの`fetchedAt`がこれより前で、Acceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補がゼロの場合だけpre-D-030 legacyとし、routeを推測せず、HTMLやroute宣言を遡及要求せず、contractを変更・再封印しない。cutover前でも候補が一つ以上あれば通常検証へ進み、候補がexactly oneで許可routeと非空Scope／Reasonを持つ完全な宣言でなければrejectする。cutoverと同時刻以降とcutover後のpre-Claim Issueにも同じexactly-one／完全性を必須とする。prefix外のroute語は候補に数えない。
- 実行していない Build、Test、Simulator 操作を成功として報告しない。
- `release`または`strict`は反対モデルの承認を必須とする。`shape`／`harden`の`standard`は、現在Headの段階別証拠でマージできる。
- マージはIssueで指定されたCodexまたはClaudeが `--squash` と Head SHA 照合を使って実行する。
- ユーザーの既存変更、認証情報、生成物を上書きまたは削除しない。

## 外部操作の権限

ClaudeとCodexは同じ権限を持ち、どちらもローカル作業と認証済み外部操作を実行できます。権限はモデル名ではなく、`Config/ownership.yml`の許可済みアカウント／target、Issue contractのoperation／Executor、環境、Head SHA、ユーザー承認で決まります。

外部操作の直前に実行モデルがアクティブなアカウントと対象リソースを完全一致で確認します。指定外アカウント、未設定target、曖昧な認証sessionでは操作しません。詳細は `docs/AUTHORITY.md` を参照してください。

## Delivery stageと標準検証

新規Issueに`shape`、`harden`、`release`のDelivery stage、Time budget、理由を明示します。Delivery profileは危険度、Delivery stageは成果物の成熟度を表し、混同しません。stage未指定のClaim済みIssueはbyte互換のため従来のprofile／scope gateを維持します。

- `shape`: 操作可能な主要導線を短時間で作る。標準は120分、Build、重要Unit Test、日本語iPhone 1条件のSmoke Test。画像評価、4条件、正式反対モデルレビューを要求せず、`release ready`と報告しない。
- `harden`: 承認済みの形に対し、保存復旧、特定画面のDynamic Type、VoiceOver、localization、Dark Mode、性能、回帰など一つの問題を狭く改善する。`targeted`なcaseだけを検証し、無関係な品質項目を同じIssueへ集めない。
- `release`: リリース候補Headへ従来の完全品質ゲートを適用する。4条件、Light/Dark、Dynamic Type、VoiceOver、44pt、目視、統合UI Test、同一Head証拠、反対モデルレビュー、premerge、提出前確認を必須にする。

すべてのstageで、コンパイル可能性、重要な金額・日付・保存ロジック、データ非破壊、秘密・個人情報の非保存、ユーザー所有ファイル保護、Scope境界、実行結果の正確な報告を省略しません。`strict`対象の認証・migration・本番データ・課金・法務・workflow gateは、stageが早くても対象別安全確認と必要な承認を維持します。

検証は対象Test、関連回帰、stage標準、release完全検証の順に広げます。Xcode、Test、Simulator操作は必ず有限timeoutで実行し、timeout時は当該呼び出しのprocess groupと所有Simulatorだけを回収します。同じ原因は最大2回で停止し、長時間検証を自動反復しません。

`shape`は`iphone-ja`、applicationを検証する`harden`はcanonical部分集合の`targeted`、`release`は`full`を使用します。いずれもバッチ開始時に最新の利用可能なiOS Runtimeを解決し、そのバッチ内で固定します。未確認の条件は延期・未検証として報告します。

UI方向比較のHTMLは選択を助ける作業artifactであり、仕様の正本、pixel仕様、Build／Test／Simulator／画像評価の証拠にはしません。実装は選択した情報階層、主要導線、状態とaccessibility意図をnative SwiftUIへ翻訳します。

- 最新 iPhone Pro（Pro Max を除く）、英語
- 最新 iPhone Pro（Pro Max を除く）、日本語
- 最新 iPad Air、英語
- 最新 iPad Air、日本語

ユーザーの実機確認は AI の完了条件に含めません。詳細は `docs/verification.md` を参照してください。
