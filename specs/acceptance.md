# 受け入れ条件

Status: 確定  
Version: 2.3
Date: 2026-09-09

## 1. テンプレート完成条件

- [ ] 最小のSwiftUIアプリがiPhoneとiPadで起動する。
- [ ] Identity bootstrapがXcode project、Target、Scheme、Module、Test、Bundle ID、設定を一貫して変換できる。
- [ ] アプリの目的・方向性とIdentity確定後、シンプルな画像生成候補2案からユーザーが選んだアプリアイコンを検証済みAsset Catalogへ組み込める。
- [ ] Unit TestとUI Testのサンプルが実行できる。
- [ ] 日本語と英語を切り替えて主要画面を検証できる。
- [ ] CodexとClaudeが同じ外部操作権限を持ち、設定済みアカウント／targetを照合する。
- [ ] ClaudeとCodexの一般開発を同等に許可しつつ、3D asset authoringは共有`ios-3d-assets` skillによりCodexのexact model `gpt-6-astra`だけへrouteされ、利用不能時に別modelへfallbackしない。
- [ ] IssueからSquash Merge・Branch削除までのdry-run testが通る。
- [ ] Delivery stageに応じて1条件、targeted部分集合、4条件を固定できる。
- [ ] 条件付きUI Direction Gateが、必要なUI作業だけを明示選択まで停止し、Identity bootstrapと独立した非UI作業を停止しない。
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
- UIを変更するIssueは、[UI Direction Gateの適用判定](development-stages.md#11-適用判定)をClaim前に行う。現在のユーザーが対象範囲のHTML比較を明示した場合は方向の有無にかかわらずGateが必須であり、明示省略は現行性、scope、権限、理由が明確で比較指示と矛盾しない場合だけ通常判定を上書きする。
- 明示指示がない通常判定は、exact hierarchy／flowを覆う確定方向があればconfirmed-direction reuse、覆う方向がなく対象方向が未確定かつ最初のユーザー向けUI、最上位navigation／information hierarchyの新設・変更、主要flowの大幅な再設計のいずれかならGate、方向未確定かつ構造triggerなしならAcceptance criteriaがhierarchy、navigation、primary-flow interactionを決めない範囲だけbounded direction-neutralとする。coverage、triggerまたはneutralityが曖昧ならGateを実行する。
- cutover後にClaimするcontractは、既存のAcceptance criteria全体でexactly oneの有効なroute宣言を持つ。一つのAcceptance criterion本文の先頭（`AC-*:`の直後）をexact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`で開始し、`<route>`は`comparison`、`explicit-skip`、`confirmed-direction reuse`、`bounded direction-neutral`、`not-applicable`のいずれかだけとする。route固有の適用事実はReasonの後へ続けてよく、prefix外のroute語は宣言として数えない。`confirmed-direction reuse`は再利用するUI方向anchor、`bounded direction-neutral`は関連product／behavior anchor、`explicit-skip`は関連product／spec／Decision anchorを`Spec anchors`へ置き、`comparison`は選択spec／Decisionを`Spec anchors`、完了済み専用IssueをDependenciesへ置く。
- UI Issueの`UI verification`は`Target screens/states`、`English expectations`、`Japanese expectations`のexact 3 fieldをこの順で持つlive guidanceであり、Issue contractやreview packetへ封印されない。pre-Claimはlive guidanceと封印対象の有効なroute宣言の両方を確認する。最終reviewはrouteをAC本文先頭の宣言だけから識別し、Goal、Acceptance criteria、`Spec anchors`、Dependencies、リンク済み確定spec／Decision、current-Head差分／証拠でScope、Reasonとroute固有事実を検証する。
- cutover後にClaimするIdentity bootstrapと純粋な非UI Issueはnot-applicable routeであり、UI方向anchorを必要としない。`UI verification`本文はexact `Not applicable`だけとし、対象scopeと非UIである理由をGoal／In scope等へ記録し、一つのAcceptance criterion本文を`UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`で開始して、関連する確定済みproduct／spec anchorを`Spec anchors`へ記録し、依存する後続native UIだけをGate判定する。
- Gateが必須の場合、一つの確定briefから作成された同条件・同fidelityの2–3案がimmutable revisionとexact SHA-256で提示され、ユーザーが一つのconcept IDまたは全採用要素をsource concept IDへ対応付けたexhaustive hybridを明示している。hybridのselected／base concept IDはユーザーがbaseを明示選択した場合だけ必要とする。
- Gateに依存するUI Issueは、対象scope、artifact path／revision、提示bytesのexact SHA-256、採用・不採用要素、対象screen／state、native適応範囲という共通記録に加え、単一案ならselected concept ID、hybridなら全採用要素からsource concept IDへのexhaustive mappingを記録したアプリ固有の確定specと追記型Decisionが専用Issueでマージ済みである。HTML単体、感想、順位、沈黙、曖昧または非網羅なhybridはDefinition of Readyを満たさない。
- App Icon IssueはIdentity bootstrapに依存し、確定済みの目的・方向性とIdentityから同条件・同fidelityのシンプルな画像生成候補をexactly 2案作る。提示済み候補を上書きせず、ユーザーがstable concept IDを一つ明示選択するまで`blocked:user`とする。組合せや重要な変更は新revisionへ再生成して再選択する。
- App Icon Issueは`bounded direction-neutral` routeで、App Home Screen／Settings等のicon表示をlive UI verificationに記録し、選択が画面階層、navigation、primary-flow interactionを決めずUI Direction Gateを満たさないことをReasonと関連product anchorから復元可能にする。最初のユーザー向けUI `shape`は完了済みApp Icon Issueへ依存し、独立した非UI作業は依存しない。
- 選択済みアプリアイコンは1024 x 1024の不透明PNGで、system masking前の正方形、単一の認識しやすい主題、単純な背景、少ない形と色を基本とする。`tools/validate-app-icon.sh`が`Config/app-identity.json`、default AppIcon entry、PNGの寸法・透明性、`Config/app-icon.json`のasset path／prompt summary／generator／exact SHA-256を一致検証する。
- 3Dモデル、mesh、material、rig、animationの作成・生成・形状変更を含むIssueは`ios-3d-assets`を使い、authoring modelをexact `gpt-6-astra`としてIssue／PR証拠へ記録する。Claudeまたは別のCodex modelは要件整理、既存asset統合、形式検証、RealityKit実装、Build／Test、レビューを担当できるが、3D asset bytesをauthoringしない。exact modelが利用不能なら`blocked:environment`とし、別modelの成果へ置換しない。

D-030 cutoverは`2026-09-06T00:31:41Z`である。封印済みIssue contractの`fetchedAt`がcutoverより前で、Acceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補がゼロの場合はpre-D-030 legacyとして、routeを推測せず、遡及的なHTML比較やroute宣言を要求せず、contractを変更・再封印せずに元の封印済みAC、spec anchors、Dependencies、current-Head evidenceを検証する。cutoverより前でも候補が一つ以上あれば通常規則へ進み、候補がexactly oneで許可routeと非空Scope／Reasonを持つ完全な宣言でなければrejectする。`fetchedAt`がcutoverと同時刻または後のcontractにも同じexactly-one／完全性を必須とし、cutover後のpre-Claim Issueも完全な宣言なしではDefinition of Readyを満たさない。prefix外のroute語は候補として数えない。

Gate必須で選択を待つ間は`blocked:user`、選択後にspec／Decisionの記録PRを待つ間は`blocked:dependency`とする。記録PRがマージされるまで、依存するUI Issueを`approved`にせず、Claimまたは`in-progress`へ移行しない。

stage未導入のClaim済みIssueはcanonical contractを変更せず、旧profile／scope gateを維持する。legacy standard／strictはfullと正式review、legacy explicit fastはfocused evidenceのままとする。このDelivery-stage legacy判定と上記pre-D-030 UI-direction legacy判定は別々に適用する。新規Issueではstage省略を許さない。

## 3. Issue Definition of Done

全stage共通で次を満たす。

1. Issue Scope内で受け入れ条件を満たす。
2. UI Direction Gateを通過したUI変更は、選択済みのinformation hierarchy、flow、state intentをnative SwiftUIへ翻訳し、HTML／CSSのpixel転記や`WKWebView`組み込みを行っていない。
3. コンパイル、重要な金額・日付・保存ロジックのTest、データ非破壊、秘密非露出を確認する。
4. stageとprofileが要求するBuild／Test／Simulatorを現在Headで実行し、未実行を成功と報告しない。
5. canonical evidenceのCommit SHAが現在Headと一致する。HTML比較をnative iOS証拠として代用しない。
6. profileまたはstageが要求するレビューが現在Headへ承認済みである。
7. PR本文にIssue、仕様、stage、検証、レビュー要否、release readinessを記載する。
8. 指定ExecutorがSquash Mergeし、remote Branch、local Branch、worktreeを安全に片付け、Issueが完了状態である。

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

## 8. App Store原稿と登録準備

[正本と登録準備](architecture.md#91-原稿の正本と登録準備)の実装は、次を満たす。#53は設計・文書の完了であり、以下の自動検出・登録経路を実装済みとは報告しない。

- field inventoryがidentity、localized原稿、version、locale、SKU、category、copyright、公開URL、review contact、privacy、age rating、IAP、Team/App/accessを覆い、各値のsource・確認分類・ASC欄を追跡できる。
- Bootstrapで導出できる値と個別確認値を区別し、原稿台帳の`draft`、`confirmed`、`remote-saved`を取り違えない。source変更で影響fieldの確認を失効させ、未決理由を列挙する。
- 新規登録前に正しい個人Team、同一Bundleの既存App、platform/name/primary language/Bundle/SKU/accessを確認する。成功不明時はreadbackしてから再開し、名前だけの一致で再利用したり、重複作成したりしない。
- Team未設定・別Team、Bundle未登録、App未作成、名前重複、権限不足、契約更新を区別する。契約同意、初回法務本文、価格、アクセス変更はユーザーへ引き継ぎ、秘密・連絡先実値は保存しない。
- [必須fixtureとreadiness例](../docs/agent-contracts/appstore-submission.md#readiness-report-and-required-fixtures)で、テンプレートBundle/文面、invalid・未公開URL、広告SDKとprivacyの乖離、age rating未回答、IAP本番未設定、確認済みsourceの変更、曖昧なremote応答を検出する。正常な合成アプリでは根拠付きfieldだけを確認済みとし、独立欄の準備を継続できる。
- 既存package/result/checklistの互換性、完全release gate、初回法務承認、外部operation境界を維持する。スクリーンショットは別途依頼・確定前に生成しない。文書リンクと現在Headの反対モデルレビューを完了する。
