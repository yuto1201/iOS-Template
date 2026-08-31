# 日本語iPhone優先の段階的開発

Status: 確定
Version: 1.0
Date: 2026-08-31

## 1. 方針

通常の機能開発は日本語iPhoneを主対象とし、主要機能・画面遷移が安定してから英語・iPadを仕上げる。最終的な対応範囲は日本語・英語、iPhone・iPadのまま変更しない。これは開発順序と検証範囲の変更であり、安全性やリリース品質を下げる決定ではない。

この方針は確定済みだが、1条件でcanonical検証を完了する実行経路は[Issue #32](https://github.com/yuto1201/iOS-Template/issues/32)で実装する。**現在のツールは4条件固定**である。実装前に1件の証拠を4件として扱ったり、検証を省略してマージしたりしない。移行中の扱いは§6を正とする。

## 2. 開発の順序

| 段階 | 主な作業 | 検証範囲と終了条件 |
| --- | --- | --- |
| 機能開発 | 日本語iPhoneの主要機能、画面遷移、保存・復元、エラー表示を固める | 実行経路の対応後は `iphone-ja`。IssueのACと対象Testを満たす。英訳・iPad最適化の完成は求めない |
| 仕上げ | 英訳、文字量差、iPadレイアウト、回転・サイズ変更などをまとめて調整する | `full`。主要機能とナビゲーションが安定した時点で開始し、対応範囲の不足を解消する |
| リリース確認 | 同じ候補Headの回帰確認、提出情報・法務・スクリーンショットを整合させる | `full`。iPhone/iPad × 日本語/英語を確認する。App Store用画像の専用matrixは別途維持する |

「最後」は申請直前の残り時間で処理するという意味ではない。主要なユーザーフローが日本語iPhoneで通り、画面構成の大きな変更が収束した時点で仕上げへ移る。新機能を際限なく追加して仕上げを先送りしない。

機能開発中も、変更が英語・iPad固有の不具合、共通レイアウト、複数端末の状態管理などに直接及ぶ場合は、そのIssueを `full` とする。既に動いている英語・iPadの機能を削除・破壊して日本語iPhoneを早く完成させることはしない。

## 3. 危険度と検証範囲は別に決める

- Delivery profile (`fast` / `standard` / `strict`) は変更の危険度と必要な安全確認・レビューを決める。
- 検証範囲 (`iphone-ja` / `full`) は確認する端末・言語を決める。実行経路の対応後、通常の新規UI Issueは `standard` + `iphone-ja` を標準とする。
- `iphone-ja` は最新利用可能iOS上のiPhone Pro（Pro Maxを除く）、`ja_JP` / `ja` の1条件。
- `full` は既存順の `iphone-en`、`iphone-ja`、`ipad-en`、`ipad-ja` の4条件。Runtime・deviceのバッチ内固定を維持する。
- 日本語iPhoneだけで作るUIも `fast` にはしない。`fast` の非UI・低リスク条件を変えない。
- 認証・認可、秘密、永続化・migration、破壊的操作、課金、個人情報の確認は開発初期から行う。`strict` でも通常機能のUI範囲を限定できるが、重要な失敗経路のTestや追加承認を省略しない。日時・通貨・複数形などロケールで変わるドメインロジックのTestはUI範囲とは別に必要な条件を確認する。
- 仕上げ、Foundation・Identity/bootstrapの全体整合、検証gate自体、App Store/TestFlight向けリリース作業は `full`。提出権限、署名、法務・privacy承認、設定済みアカウントの照合は引き続き `strict` の境界に従う。
- `standard` / `strict` の反対モデルレビュー、現在Headと証拠の一致、1 Issue = 1 Branch = 1 PR、Squash Mergeは維持する。
- scope未指定の既存Issue・snapshotは `full`、profile未指定は `strict`。Claim済みの範囲を暗黙に縮小しない。

## 4. 最初から残す土台と後送りする作業

最初から行うこと:

- ユーザー向け文字列を既存のString Catalog等で管理し、安定したキーと文脈を保つ。表示文言を識別子や永続化値として使わず、文字列の継ぎ足しで翻訳困難な文を組み立てない。
- 固定画面サイズに依存しないレイアウト、Dynamic Type、VoiceOverの意味づけ、基本的なタップ領域を日本語iPhoneの変更範囲で確認する。
- 日時・数値・通貨の適切なフォーマット、保存形式と表示の分離、データ・状態管理とViewの責務分離を保つ。
- iPad targetや既存の英語リソースを削除しない。テンプレートの開発言語設定を、作業言語が日本語という理由だけで変更しない。
- 重要な共通画面では既存Previewや短い確認で大画面・長い文言の破綻を早く見つけてもよい。ただし毎Issueの全端末・全言語検証を別名で復活させない。

仕上げでまとめて行うこと:

- 新規文言の英訳、用語統一、英語の自然さと文字量差の調整。
- iPad向けの列構成、余白、ナビゲーション、sheet/popover、回転・サイズ変更、キーボード表示の最適化。
- 日英・iPhone/iPadの横断UI確認、提出用メタデータ・スクリーンショットの最終整合。

未翻訳箇所を仮の英訳で完成扱いにしない。翻訳しやすい土台を保つために、将来不要かもしれない抽象化や独自localization基盤を先回りして作ることも不要。

## 5. Issue・レビュー・リリースの扱い

新しいアプリの計画時に「英語・iPad仕上げ」Issueを用意する。画面ごとに細かい延期Issueを大量作成せず、仕上げIssueに未翻訳箇所・対象画面・注意点をまとめる。リリースIssueはその完了に依存させる。配置・仕様が未確定なら、実装を先に始めず必要な判断だけを確認する。

各機能Issueでは、Goal / In scope / Out of scope / UI verificationに段階、今回の対象範囲、後送り先を記載する。英語・iPadを後送りしたこと自体を今回のAC不足にせず、対象範囲の実装と証拠で判定する。既存ACが英語・iPadを明示要求するIssueは、自動的に対象外へ書き換えない。

レビューとPRでは「今回確認済み」と「仕上げへ延期・未検証」を区別する。日本語iPhoneの成功から英語やiPadの成功を推測せず、`not-applicable` を全対応済みという意味で使わない。`Remaining work: None for this Issue` はアプリ全体の完成を意味しない。

リリース候補では仕上げIssueの完了だけでなく、候補Headそのものの4条件検証を要求する。古いHeadの画像・成功結果や日本語iPhoneだけの成功では、日英・iPhone/iPad対応済みと判定しない。App Store用の表示ファミリー・画像要件、metadata、privacy/legalは別途確認する。

## 6. 現行ツールからの移行

[Issue #31](https://github.com/yuto1201/iOS-Template/issues/31)はこの方針の文書化だけを行う。実行ツール、Issue form、共有スキル、エージェント設定、Xcode projectは変更しない。`iphone-ja` の新しいCLI引数やsnapshot fieldが既に使えるとは扱わない。

移行中も機能実装と対象Testは日本語iPhoneを中心に進めてよい。既存Issue formが要求するEnglish expectationsには、翻訳完成を仕上げへ延期することと、現行の4条件smokeで実際に確認する動作を記載する。後送りを成功と記載せず、4件の画像はすべて確認する。現行のcanonical完了ゲートは省略しない。

1条件でのIssue完了は、#32がcontract生成からmatrix、runner、visual、review、PR、pre-mergeまで一貫して対応した後に開始する。既存の固定4件schemaを手作業で書き換えたり、不足したcaseの証拠を生成したりしない。同一batch内でscopeを変えず、別scope・別Headの証拠を流用しない。

この変更を既にテンプレートから作成済みのアプリへ自動適用したとは報告しない。各アプリの現行仕様・ツールとの差分を確認し、別Issueで移行する。

## 7. 実装の依存関係

| Issue | 成果 / AC | Spec anchors | 主な変更先 | 依存 | 実装開始条件 |
| --- | --- | --- | --- | --- | --- |
| [#31](https://github.com/yuto1201/iOS-Template/issues/31) | 方針・移行境界 / AC-1〜5 | 本文§1〜6、acceptance.md §3〜5 | AGENTS・README・specs・docsのMarkdown | なし | ユーザー承認済み |
| [#19](https://github.com/yuto1201/iOS-Template/issues/19) | 検証設定のIssue contract生成 / 既存AC | acceptance.md §3・5 | contract・Issue form・tests・docs | 既存Issueに従う | 既存担当の進行を維持 |
| [#29](https://github.com/yuto1201/iOS-Template/issues/29) | live Issue改変検出 / 既存AC | acceptance.md §3・5 | pre-merge・tests | #19との入力経路を整合 | 既存Issueに従う |
| [#32](https://github.com/yuto1201/iOS-Template/issues/32) | 1条件／4条件の実行・証拠・review / AC-1〜7 | 本文§2〜6、acceptance.md §3〜5 | tools・tests・Issue form・共有スキル・reviewer・関連文書 | #31・#19・#29 | 依存の完了後 |

依存辺は `#31 -> #32`、`#19 -> #32`、`#29 -> #32`。contract・Issue form・workflow文書・gateを触る作業は直列化し、#19や#29を重複実装しない。#32ではlegacy fullと新しい1条件経路、不正scope・改変・リリース縮小の拒否を検証し、移行注記と共有スキルを同時に更新する。
