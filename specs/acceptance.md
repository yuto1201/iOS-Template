# 受け入れ条件

Status: 確定  
Version: 2.0
Date: 2026-09-02

## 1. テンプレート完成条件

- [ ] 最小のSwiftUIアプリがiPhoneとiPadで起動する。
- [ ] Identity bootstrapがXcode project、Target、Scheme、Module、Test、Bundle ID、設定を一貫して変換できる。
- [ ] Unit TestとUI Testのサンプルが実行できる。
- [ ] 日本語と英語を切り替えて主要画面を検証できる。
- [ ] CodexとClaudeが同じ外部操作権限を持ち、設定済みアカウント／targetを照合する。
- [ ] IssueからSquash Merge・Branch削除までのdry-run testが通る。
- [ ] Delivery stageに応じて1条件、targeted部分集合、4条件を固定できる。
- [ ] Head SHAが異なる古い検証・レビューではpre-merge gateが失敗する。
- [ ] 秘密値が追跡ファイル、ログ、Issue／PR本文へ混入していない。
- [ ] `App Store/`に提出情報の構造と検証scriptがある。
- [ ] README、仕様、運用文書、skill、tool間のlink検証が通る。

## 2. Issue Definition of Ready

次が揃うまでIssueを`in-progress`にしない。

- Goal、In scope、Out of scope、検証可能な`AC-1..n`、仕様anchor、依存／blockerがある。
- UI変更は対象画面・状態、今回確認する言語／端末、延期する範囲を記載する。
- Delivery stageが`shape`、`harden`、`release`のいずれかで、正のTime budgetと理由がある。
- Delivery profileが`fast`、`standard`、`strict`のいずれかで、危険度の理由がある。
- Verification scopeとstageが一致する。`shape`は`iphone-ja`、applicationを検証する`harden`は`targeted`、`release`は`full`。
- `shape`はBuild、重要Unit Test、日本語iPhone Smoke TestへACを対応付け、完全4条件やvisual evidenceを必須にしなくてよい。
- `harden`は一つの品質問題と必要なcaseだけを対象にし、無関係な品質項目を束ねない。
- `release`は`strict`、完全4条件、全caseのvisual evidenceを持つ。
- 外部サービスはservice、environment、Executorを指定し、法務、課金、本番破壊操作は必要なユーザー承認を明示する。
- Feature Issueではアプリ固有の`specs/product.md`と`specs/acceptance.md`が確定し、Issueと矛盾しない。受け入れ条件を変える未決事項は`blocked:user`。

stage未導入のClaim済みIssueはcanonical contractを変更せず、旧profile／scope gateを維持する。legacy standard／strictはfullと正式review、legacy explicit fastはfocused evidenceのままとする。新規Issueではstage省略を許さない。

## 3. Issue Definition of Done

全stage共通で次を満たす。

1. Issue Scope内で受け入れ条件を満たす。
2. コンパイル、重要な金額・日付・保存ロジックのTest、データ非破壊、秘密非露出を確認する。
3. stageとprofileが要求するBuild／Test／Simulatorを現在Headで実行し、未実行を成功と報告しない。
4. canonical evidenceのCommit SHAが現在Headと一致する。
5. profileまたはstageが要求するレビューが現在Headへ承認済みである。
6. PR本文にIssue、仕様、stage、検証、レビュー要否、release readinessを記載する。
7. 指定ExecutorがSquash Mergeし、remote Branch、local Branch、worktreeを安全に片付け、Issueが完了状態である。

`shape`と`harden`の完了はアプリ全体のrelease readyを意味しない。必ず`not release-ready`と報告し、未確認の英語、iPad、visual／accessibility範囲を成功と推測しない。ユーザーの実機確認はAIのDefinition of Done後に行い、発見した問題は狭いRegression／harden Issueへ分ける。

### 3.1 Delivery stage gate

| Stage | 必須 | この段階では原則不要 |
| --- | --- | --- |
| `shape` | Build、重要Unit Test、日本語iPhone 1条件の主要導線Smoke、起動／保存／crash確認。既定Time budget 120分 | 4条件、全Light/Dark、全Dynamic Type、完全VoiceOver、全44pt境界、全画像、正式反対モデル承認、App Store証拠、長時間統合UI Test |
| `harden` | 対象Test、関連回帰、明示した`targeted` caseと対象品質確認 | 無関係な品質監査、毎回の4条件matrix |
| `release` | §4の4条件、Light/Dark、Dynamic Type、VoiceOver、44pt、未翻訳／切れ／重なりの目視、完全統合UI Test、同一Head証拠、反対モデルreview、premerge、提出前確認 | なし |

`shape`がTime budgetを超えそうな場合、Scope縮小、harden分離、`blocked:environment`、受け入れ条件判断が必要なら`blocked:user`のいずれかを選ぶ。

### 3.2 Delivery profile

| Profile | 使用条件 | 追加ゲート |
| --- | --- | --- |
| `fast` | 非UI、local、低リスク | Build、対象Unit Test、workflow toolならrepository tests。UI matrix／画像／blocking reviewなし |
| `standard` | 通常UI、localization、accessibility、性能 | stage別検証。shape／hardenではblocking reviewなし、releaseではreviewあり |
| `strict` | 認証・認可、秘密、migration、本番／破壊的データ、課金、privacy／法務、App Store／TestFlight、署名、delivery gate | 重要失敗経路Test、account／target preflight、必要な承認、現在Headの反対モデルreview |

profileを下げてstage要件を回避しない。`shape`はUIを含むので`fast`にしない。strict対象operationを`fast`／`standard`へ指定したIssueは開始前に拒否する。

## 4. Simulator scope

| Case | Device | Locale | Language |
| --- | --- | --- | --- |
| `iphone-en` | 最新の利用可能なiPhone Pro。Pro Maxを除く | `en_US` | `en` |
| `iphone-ja` | 同上 | `ja_JP` | `ja` |
| `ipad-en` | 最新の利用可能なiPad Air | `en_US` | `en` |
| `ipad-ja` | 同上 | `ja_JP` | `ja` |

`iphone-ja`は1行だけ、`targeted`は表の非空canonical部分集合、`full`は4行すべてを固定順で使う。「最新」はバッチ開始時にインストール済みXcodeから解決して固定し、条件に合うdeviceがなければ`blocked:environment`とする。Claim済みscopeを暗黙に縮小せず、別scope／別Headのmatrixや証拠を流用しない。

## 5. 常設品質ゲート

- Build warningを新規に増やさず、失敗Testを削除／Skipして成功扱いにしない。
- ユーザーデータ、保存互換性、重要な金額／日時／認証／課金ロジックをstageに関係なく守る。
- String Catalog等の安定したkey、可変layout、iPad target、既存英語resourceを初期から壊さない。
- 認証情報、個人情報、設定外account識別子を証拠へ含めない。
- 外部操作の成功は実応答から確認し、推測で記録しない。
- ユーザー所有fileを削除／上書きせず、Issue Scope外へ実装を広げない。

## 6. Timeout、失敗、再試行

- `xcodebuild`、Unit Test、UI Test、Simulator／Swift操作は有限timeoutで実行する。
- timeout時は当該呼び出しのprocess groupだけを停止し、現在attemptが所有するSimulatorとlockだけを回収する。別Issue、別repository、ユーザーのXcode／Simulatorへglobal kill／shutdownを行わない。
- failure recordへ停止stage、elapsed、timeoutを残し、成功形式の`verify.json`を生成しない。
- 同じ原因は最大2回で停止する。自動で同じ長時間検証を繰り返さない。
- 再実行は対象Test、関連回帰Test、stage標準検証、release完全検証の順に広げる。
- 正式証拠へ別attemptの部分結果を混ぜないが、診断用の成功結果は修正判断に利用する。
- review不能は`blocked:review`、外部認証／rate limitは`blocked:ops`、Xcode／Runtime／Simulator不足は`blocked:environment`、仕様判断不足は`blocked:user`、依存未完了は`blocked:dependency`。

## 7. Bootstrap Issue

Foundation、Identity bootstrap、Simulator verificationなどテンプレート全体のgateを変更するIssueは`strict`で扱う。自動化tool自身が未実装の間だけ手動実行を許すが、Build、Test、要求stageのSimulator、必要な反対モデルreview、Head一致を免除しない。生成後の使い捨てrepositoryでもshapeとreleaseの契約／runnerを確認する。
