# 動く形から品質を固める段階的開発

Status: 確定
Version: 2.0
Date: 2026-09-02

## 1. 原則

開発順序は、操作可能な形を作る、実画面で方向性を承認する、問題別に品質を固める、リリース候補を完全検証する、の順とする。最終品質は下げず、高コストな横断検証を変更が収束した後へ移す。

Delivery stageはIssue type、workflow state、危険度を表すDelivery profileとは別の一項目である。新規Issueは`shape`、`harden`、`release`のいずれか、正のTime budget、理由を持つ。

## 2. Delivery stage

| Stage | 目的 | 標準検証 | 完了時の表現 |
| --- | --- | --- | --- |
| `shape` | 主要導線を短時間で操作可能にし、実画面で仕様とUI方向を確認する | Build、重要Unit Test、代表的な日本語iPhone 1条件のSmoke Test。コンパイル、起動、保存不能、クラッシュを確認 | 「shape完了。release-readyではない」 |
| `harden` | 承認済みの形に対し、一つの品質問題を狭く改善する | 対象Test、関連回帰、明示した`targeted` Simulator case。変更に必要な品質確認だけ | 「対象をharden済み。release-readyではない」 |
| `release` | リリース候補Headの全体品質と提出準備を確定する | §5の完全検証 | 完全検証が成功した場合だけrelease-ready |

`shape`のTime budget既定値は120分とし、Issueで変更できる。超過しそうならScopeを狭める、`harden` Issueへ分ける、環境障害で停止する、または受け入れ条件を変える判断だけを`blocked:user`にする。追加の品質項目を同じIssueへ積み増して延長しない。

`harden`では、保存失敗復旧、特定画面のDynamic Type、特定導線のVoiceOver、localization、Dark Mode、accessibility、performance、回帰不具合などを別々に扱う。無関係な品質項目を一つのIssueへ束ねない。

## 3. Delivery profileとVerification scope

Delivery profileは変更の危険度を表す。

- `fast`: 非UI・ローカル・低リスク。
- `standard`: 通常の画面・操作・品質改善。
- `strict`: 認証・認可、秘密、migration、本番データ、破壊的操作、課金、privacy・法務、App Store/TestFlight、署名、workflow gate。

Verification scopeは端末・言語の範囲を表す。

- `shape`は`iphone-ja`。最新利用可能iOSのiPhone Pro（Pro Maxを除く）、`ja_JP` / `ja`の1条件。
- applicationを検証する`harden`は`targeted`。`iphone-en`、`iphone-ja`、`ipad-en`、`ipad-ja`のうち、Issueの変更対象に必要な非空のcanonical部分集合。
- `release`は`full`。上記4条件を固定順ですべて実行する。

`shape`はUIを含むため`fast`へ偽装しない。逆に`strict`なshape/hardenでも、危険な対象の安全確認は維持しつつ、無関係なリリース全体検証は後段へ移せる。

## 4. 常に守る安全基準

Delivery stageにかかわらず、次を省略しない。

- コンパイル可能であること。
- ユーザーデータを破壊せず、保存形式の互換性を守ること。
- 金額、日付、保存など重要ロジックを対象Unit Testで確認すること。
- 認証情報や個人情報を保存・出力しないこと。
- ユーザー所有ファイルを削除・上書きしないこと。
- Issue Scope外へ実装を広げないこと。
- 実行していないBuild、Test、Simulator操作を成功と報告しないこと。

String Catalog等の安定したキー、可変レイアウト、意味のあるaccessibility情報、iPad target、既存英語リソースは初期から壊さない。ただし全翻訳、全画面のDynamic Type／VoiceOver／44pt／Light-Dark監査をshapeの完了条件にはしない。

## 5. Release完全検証

`release` Issueまたは明示的なリリース候補だけが、次を必須とする。

- iPhone／iPad × 日本語／英語の4条件。
- Light／Dark Mode。
- Dynamic Type。
- VoiceOver。
- 44pt以上の操作領域。
- 未翻訳、切れ、重なりの目視確認。
- 完全な統合UI Test。
- 同一Head SHAに束縛された証拠。
- 反対モデルレビュー。
- premerge gate。
- App Store提出前検証。

Runtime、Device Type、case集合はバッチ内で固定する。古いHead、別scope、部分attemptの結果を正式証拠へ混ぜない。

## 6. 有界実行と再実行

`xcodebuild`、Unit Test、UI Test、`simctl`、Swift検証は有限timeoutで起動する。timeout時は当該呼び出しのprocess groupだけへTERM、grace、必要時KILLを行い、現在attemptが所有するSimulatorとlockだけを回収する。別Issue、別repository、ユーザーが起動したXcodeやSimulatorへglobal shutdown／killを行わない。

失敗記録には停止stage、経過時間、timeoutを含める。timeoutや失敗時に成功形式の`verify.json`を生成しない。同じ原因の実行は最大2回で止める。

再実行の順序は、対象Test、関連回帰Test、Delivery stage標準検証、`release`完全検証とする。正式な一括証拠へ異なるattemptの部分結果を混ぜないが、診断済みの対象Test結果は修正判断に利用する。

## 7. Issue・レビュー・移行

新規Issueの`Delivery stage`節は`Stage`、`Time budget`、`Reason`をこの順で持つ。`Verification scope`節は`Scope`と`Reason`を持ち、stageを重複記載しない。Feature formは`shape / 120 minutes / standard / iphone-ja`、Regression formは`harden / targeted`、Release formは`release / strict / full`を既定とする。

`shape`と`harden`の`standard`はblockingな反対モデルレビューを要求しない。`strict`または`release`は現在Headの正式な反対モデルレビューを必須とする。shape/hardenのPRと完了報告は必ずnot release-readyを明記する。

Claim済みで`deliveryStage`を持たない既存contractはcanonical bytesを変更せず、従来のprofile／scope gateを維持する。すなわちlegacy standard／strictはfullと正式review、legacy explicit fastは従来どおりfocused evidenceを使う。新しいIssue validatorはstage未指定を拒否する。既存Issueを縮小したい場合は、暗黙変換せずユーザー承認の上で新しいIssueへ分離する。

## 8. 依存関係

Issue #44がこの仕様、Issue forms、skills、validator、runner、repository tests、bootstrap後repositoryを同じ契約へ揃える。以後のアプリではshapeの実画面承認後に必要なharden Issueを作り、それらを依存にしたrelease Issueで完全検証する。
