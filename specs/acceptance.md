# 受け入れ条件

Status: 確定  
Version: 3.3
Date: 2026-09-17

## 1. テンプレート完成条件

- [ ] 最小のSwiftUIアプリがiPhoneとiPadで起動する。
- [ ] Identity bootstrapがXcode project、Target、Scheme、Module、Test、Bundle ID、設定を一貫して変換できる。
- [ ] アプリの目的・方向性とIdentity確定後、シンプルな画像生成候補2案からユーザーが選んだアプリアイコンを検証済みAsset Catalogへ組み込める。
- [ ] Identity bootstrap後、主要Feature Issueより前にSystem Experiences Planning Gateで5面を評価し、採用面だけを依存Issueへ分けられる。
- [ ] Unit TestとUI Testのサンプルが実行できる。
- [ ] 日本語と英語を切り替えて主要画面を検証できる。
- [ ] CodexとClaudeが同じ外部操作権限を持ち、設定済みアカウント／targetを照合する。
- [ ] ClaudeとCodexの一般開発を同等に許可しつつ、3D asset authoringは共有`ios-3d-assets` skillによりCodexのexact model `gpt-6-astra`だけへrouteされ、利用不能時に別modelへfallbackしない。
- [ ] IssueからSquash Merge・Branch削除までのdry-run testが通る。
- [ ] Delivery stageに応じて1条件、targeted部分集合、4条件を固定できる。
- [ ] 条件付きUI Direction Gateが、必要なUI作業だけを明示選択まで停止し、Identity bootstrapと独立した非UI作業を停止しない。
- [ ] Head SHAが異なる古い検証・レビューではpre-merge gateが失敗する。
- [ ] 反対モデルレビューは既定pairを維持し、ユーザー承認をsealed contractへ明示したCodex-primary Issueだけがexact `cursor-grok-4.6-xhigh`の固定read-only fallbackを使える。
- [ ] 秘密値が追跡ファイル、ログ、Issue／PR本文へ混入していない。
- [ ] `App Store/`に提出情報の構造と検証scriptがある。
- [ ] README、仕様、運用文書、skill、tool間のlink検証が通る。
- [ ] 一つのリリース目標をPhase 1〜6で追跡し、Phase、Delivery stage、Delivery profile、Verification scopeを別軸として扱える。
- [ ] Claim後の同一Issue contractで許可されたVerification／Acceptance criteria改訂を、明示authority、immutable revision chain、証拠失効を伴う専用経路として監査できる。

## 2. Issue Definition of Ready

次が揃うまでIssueを`in-progress`にしない。

### 2.1 System Experiences Planning Gate

新しいアプリまたはSystem Experiencesの新規採用を含むreleaseでは、Identity bootstrap後かつ主要Feature Issueの計画・Claimより前に、専用のSystem Experiences Planning Issueを完了する。`widget`、`live-activities`、`dynamic-island`、`controls`、`siri-app-intents`の5面すべてについて、最新のApple公式sourceを確認し、`adopt-now`、`defer`、`not-applicable`、`blocked:user`のいずれか、理由、提供価値、data／action境界、privacy、accessibility、日英localization、fallback、検証、release依存、再評価条件を記録する。

評価は必須だが採用は任意であり、ユーザーが最終判断する。`adopt-now`だけを実装Issueへ分け、計画だけでframework、Extension target、entitlementを追加しない。一面が`blocked:user`でも、その判断に依存するIssueだけを部分blockingとし、確定済み面や独立した非UI作業は進める。App IconはIdentity bootstrap後に並行でき、採用するsystem UIの方向選択は別途UI Direction Gateへ依存する。

- Goal、In scope、Out of scope、検証可能な`AC-1..n`、仕様anchor、依存／blockerがある。
- UI変更は対象画面・状態、今回確認する言語／端末、延期する範囲を記載する。
- Delivery stageが`shape`、`harden`、`release`のいずれかで、正のTime budgetと理由がある。
- Delivery profileが`fast`、`standard`、`strict`のいずれかで、危険度の理由がある。
- Verification scopeとstageが一致する。`shape`は`iphone-ja`、applicationを検証する`harden`は`targeted`、`release`は`full`。
- `shape`はBuild、重要Unit Test、日本語iPhone Smoke TestへACを対応付け、完全4条件やvisual evidenceを必須にしなくてよい。
- `harden`は一つの品質問題と必要なcaseだけを対象にし、無関係な品質項目を束ねない。
- `release`は`strict`、完全4条件、全caseのvisual evidenceを持つ。
- `release` Delivery stageは`type:release`の実際のアプリrelease candidateだけに使う。Feature、Regression、workflow-only変更は`release/full`へ分類しない。
- 外部サービスはservice、environment、Executorを指定し、法務、課金、本番破壊操作は必要なユーザー承認を明示する。
- Feature Issueではアプリ固有の`specs/product.md`と`specs/acceptance.md`が確定し、Issueと矛盾しない。受け入れ条件を変える未決事項は`blocked:user`。
- Identity bootstrap後の主要Feature Issueは、完了済みSystem Experiences Planning Issueと5面の採否matrixを参照する。`adopt-now`の面へ依存するIssueはその設計・基盤IssueをDependenciesへ置き、`defer`または`not-applicable`を実装scopeへ黙って含めない。
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
- application releaseに属するIssueは、release identifier、revision、現在Phase、依存する前Phaseの完了記録へ到達できる。Phase 1のscope承認、Phase 3のユーザー完了判断、Phase 4の独立した対応範囲、Phase 5の残件承認、Phase 6の公開権限を別々に記録する。workflow-onlyのテンプレート改善Issueへ架空のapplication Phaseを付けない。
- 前Phaseが未完了でもread-only調査、選択肢、Issue草案、依存しない作業は可能だが、その結果を次Phaseの実装開始または完了証拠にしない。依存する実装は前Phase完了と現行revisionの再照合まで開始しない。
- 反対モデルreviewerは既定でCodex primary→Claude、Claude primary→Codexとする。Claudeが利用不能でユーザーがそのIssueに限り明示承認した場合だけ、一つのAC本文先頭にexact `Opposite-review route: grok-fallback; Primary: codex; Reviewer: cursor-grok-4.6-xhigh; Approval: user-explicit; Reason: <nonempty>`を置ける。重複、不完全、別primary／model、推測承認はGrok routeを成立させず、silent／automatic fallback、Claude-primary→Grok、primary自身の承認を許可しない。

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
6. profileまたはstageが要求するレビューが、sealed contractから決まるauthorized reviewer、固定launcher、現在Headのpacket／result／receiptで承認済みである。
7. PR本文にIssue、仕様、stage、検証、レビュー要否、release readinessを記載する。
8. 指定ExecutorがSquash Mergeし、remote Branch、local Branch、worktreeを安全に片付け、Issueが完了状態である。

`shape`と`harden`の完了はアプリ全体のrelease readyを意味しない。必ず`not release-ready`と報告し、未確認の英語、iPad、visual／accessibility範囲を成功と推測しない。ユーザーの実機確認はAIのDefinition of Done後に行い、発見した問題は狭いRegression／harden Issueへ分ける。

### 3.0 リリースPhase gate

リリース単位の各Phaseは[6開発フェーズ](development-stages.md#15-リリース単位の6開発フェーズ)の入口・成果物・出口を満たす。Phase完了記録にはrelease identifier、revision、scope、完了Phase、依存Issue、証拠、既知不具合、テスト省略、未検証、繰越、必要なユーザー承認を含める。Phase 3はAIの作業完了だけで閉じず、現在revisionについてのユーザー判断を必須とする。

軽微変更は承認済みAcceptance criteria、目的、MVP、主要flow、採用system、data互換性、重大riskを変えない場合だけ同じPhaseで扱う。major changeは変更前後、理由、判断者／委任根拠、影響仕様／Issue／Phase、失効証拠、再利用候補と根拠を追記し、影響する最も早いPhaseだけをreopenする。影響のないIssueを停止せず、沈黙を承認にしない。

既知不具合、テスト省略、未検証を別々に残す。非blocking残件の許容には対象release、影響、回避策、修正費用、承認者、追跡Issue、再評価時点が必要である。データ消失、秘密漏洩、誤課金、重大計算誤り、主要導線crash、認証／privacy／法務の必須条件違反が一つでもあればPhase 5の公開可判定を通さない。

D-050 cutover `2026-09-15T11:00:00Z`以後に封印されたPhase 5／6 `implementation` contractは、current candidateの`release-disposition.json`をreview packet、PR本文、pre-merge、release preflightのすべてで要求する。recordはrelease identifier／revision／phase／scope／Base phase recordとIssue／Base／Head／Issue contractを固定し、`accepted-defect`、`deferred-defect`、`omitted-test`、`unverified`を別entryとして保持する。空配列は残件なしの明示であり、record欠落から残件なしを推測しない。cutover前のcontractは元bytesのまま従来gateを使い、recordを遡及要求しない。

`accepted-defect`はsafe classificationかつ`low`だけを許し、影響・回避策・修正費用、同じcandidateに束縛した期限内のuser approval、follow-up Issue、再評価条件がすべて必要である。`deferred-defect`は承認の代替ではない。critical／high／unknownまたは公開blocker分類を延期したrecord、`wait`中の停止後判断はreview承認、pre-merge、release preflightを通さない。reviewerのlow findingとproduct defect disposition、Phase 5→6 evidence applicabilityとrelease dispositionを相互に合成しない。

D-050対象candidateはDelivery profileの通常経路にかかわらずcurrent-Headの正式な反対モデルreviewを要求し、review packetを持たない直接承認を許可しない。

Phase 5から6へ進む`implementation`は、Phase 5のpassed full verificationとPhase 6候補の適用可能性を、Phase 6のIssue／Base／Headごとのimmutable `evidence-applicability.json`へ記録する。release identifier、revision、scope、source／target phase record、元証拠とcontractのpath／digest、artifact／configuration／SDK／signing context、source..target Git diff、全changed pathの影響分類・依存関係・理由、判定時刻を固定し、review packet、PR本文、pre-merge、提出前preflightが同じrecordを検証する。

`reuse`はcandidate Headと全contextがexact一致し、差分、unknown／missing dependency、scope拡張がない場合だけ許可する。Head、contextまたは影響pathが変われば`targeted-reverify`、影響不明、dependency欠落またはscope拡張なら`expanded-verification`とし、判定後に必要範囲のpassed検証を取得する。設定、signing、SDKだけを一律に影響なしとせず、旧Head証拠を現Headの実行結果へ付け替えない。提出時固有のpackage、privacy、legal、権限、provider readbackは再利用対象外とし毎回確認する。

### 3.1 Delivery stage gate

| Stage | 必須 | この段階では原則不要 |
| --- | --- | --- |
| `shape` | Build、重要Unit Test、日本語iPhone 1条件の主要導線Smoke、起動／保存／crash確認。既定Time budget 120分 | 4条件、全Light/Dark、全Dynamic Type、完全VoiceOver、全44pt境界、全画像、正式反対モデル承認、App Store証拠、長時間統合UI Test |
| `harden` | 対象Test、関連回帰、明示した`targeted` caseと対象品質確認 | 無関係な品質監査、毎回の4条件matrix |
| `release` | §4の4条件、Light/Dark、Dynamic Type、VoiceOver、44pt、未翻訳／切れ／重なりの目視、完全統合UI Test、同一Head証拠、反対モデルreview、premerge、提出前確認 | なし |

`shape`がTime budgetを超えそうな場合、Scope縮小、harden分離、`blocked:environment`、受け入れ条件判断が必要なら`blocked:user`のいずれかを選ぶ。

通常開発は変更へ直接対応するtestから始め、1 commandを300秒で停止する。workflow-only Issueのcanonical `targeted` repository suiteはaggregate 900秒を超えて実行しない。既知の複数domain、manifest、runner、tracked test変更は関連testのunionを選び、`head-all`へ自動昇格しない。未知pathはplan生成を拒否する。全repository testsと4条件matrixはrelease、nightly相当の明示実行、またはユーザーがIssue contractで明示要求した場合だけ完了条件にする。

### 3.2 Delivery profile

| Profile | 使用条件 | 追加ゲート |
| --- | --- | --- |
| `fast` | 非UI、local、低リスク | Build、対象Unit Test、workflow toolならrepository tests。UI matrix／画像／blocking reviewなし |
| `standard` | 通常UI、localization、accessibility、性能 | stage別検証。shape／hardenではblocking reviewなし、releaseではreviewあり |
| `strict` | 認証・認可、秘密、migration、本番／破壊的データ、課金、privacy／法務、App Store／TestFlight、署名、delivery gate | 重要失敗経路Test、account／target preflight、必要な承認、現在Headの反対モデルreview |

profileを下げてstage要件を回避しない。`shape`はUIを含むので`fast`にしない。strict対象operationを`fast`／`standard`へ指定したIssueは開始前に拒否する。

### 3.3 Workflow-only検証

delivery tool、review schema、validator、evidence producerだけを変更する`harden + strict` Issueは、application `Verification`と`Verification scope`を持たないworkflow-only経路を選べる。Base..Headの全pathがworkflow allowlist内であることをcurrent Headから再判定する。App Store／TestFlightはexternal operation、実アプリmetadata内容、採用画像asset、signing、provider実装を拒否し、exact allowlistにあるlocal guidance、非認証capture producer、非認証legal-page handoff producer、非認証のread-only source-preparation producer、そのexactなversioned-format guidance／enumerated helpers／直接regression test、[D-059](decisions.md#d-059-app-store-connect-api操作を固定版ascのguarded-adapterへ集約する)に従い後続Issueが自Headでexact列挙したasc adapterのtool／helper／fixture／直接regression testだけを許可する。asc adapterの許可はfake `asc`による検証に限り、`appstore.*` operationやlive外部操作をworkflow-onlyで認可しない。canonical `verify.json`は`changeClassification: workflow-only`、`executionRoute: repository-tests`、`status: passed`を持ち、Xcode、Build、Unit、Simulator case、Screenshot、visual evaluationを`not-applicable`として固定する。

workflow-onlyでも、全ACへ対応するcanonical repository-test evidence、仕様anchor、contract digest、Base／Head、strict review、blocking finding、PR、pre-merge gateを省略しない。D-037 cutover後はsealed要求scopeとimmutable Base..Head入力からexact test planを生成し、`targeted`、`head-all`、`base-and-head`の解決結果だけを実行する。cutover前のworkflow-onlyは全ACの`--map`が参照するtracked test pathのexact unionを各1回実行し、その他の従来Head-only contractは全tracked testを維持する。application path、Xcode project、exact allowlistのformat guidanceではない実アプリApp Store metadata／画像asset、localization、Bundle設定、release operation、別Issue／Head／contract、改ざん済みplan／repository evidenceを拒否する。

### 3.4 Sealed tracked fixture検証

provider統合を`TemplateApp`またはrepository rootのXcode projectへ導入せず、Git管理下の専用application fixtureでBuild／TestするIssueは、既存Acceptance criterion一つの本文全体をexact `Application-fixture binding: <canonical JSON>`とできる。候補はこのprefixで始まるACだけで、最大一つとする。JSONはschema 1のexact key `fixtureRoot`、`project`、`route`、`schemaVersion`、`skillRoot`、`toolPaths`だけを辞書順、空白なしで持ち、`route`は`tracked-fixture-v1`だけ、`toolPaths`はsorted、unique、nonemptyとする。すべてのpathはportableなsafe relative pathで、`fixtureRoot`は`tools/tests/fixtures/`配下に置き、provider namespaceをfixture、skill、toolへ一貫して使い、`project`は`fixtureRoot`直下以下にあるcommitted `.xcodeproj`でなければならない。

bindingを持つIssueはapplication経路であり、完全な`Verification`と、`shape / strict / iphone-ja`または`harden / strict / targeted`のどちらかを必須とする。workflow-only、`release`、`fast`／`standard`、`full`、application Verification欠落、`visual:` mappingは拒否する。CLIへ渡すprojectはsealed `project`とexact一致させ、最終`verify.json`でも同じprojectを再照合する。証拠は既存の`changeClassification: application-code`、`executionRoute: xcodebuild-stage`、source tree／project digest、Build、Unit Test、case、Simulator cleanupを維持し、shape／hardenをrelease-readyへ昇格させない。

scoped application diffで許可できるのは、宣言した`fixtureRoot`、`skillRoot`、exact `toolPaths`、同名の`.claude/skills/<provider>`からexact `../../.agents/skills/<provider>`への新規symlink、およびrouteがexactに固定するrepository root `README.md`と`Config/repository-tests.json`だけである。binding外path、`TemplateApp`、root project／workspace、別provider、既存workflow／review／merge／security／authority実装、削除、rename、gitlink、許可外mode、不正symlinkを拒否する。directory名やproviderらしいpathから例外を推測しない。

`skillRoot/application-fixture.json`をprovider ownership markerとし、そのbytesはprefixを除いたcanonical binding JSONと改行なしでexact一致し、Headでregular `100644`でなければならない。Baseでmarker自身を除く`fixtureRoot`／`skillRoot`配下、宣言済み`toolPaths`、同名Claude aliasのいずれかが既に存在する場合、Baseにも同じmarkerがregular `100644`で存在し同じbindingを所有していなければ拒否する。どのsurfaceもBaseに存在しない新規providerではBase markerを拒否し、markerをHeadでprovider surfaceと同時に追加する。Headでは`skillRoot/SKILL.md`、全tool path、同名Claude aliasのmode／bytes／targetも常に検証し、宣言だけの空bindingや既存aliasの流用を許可しない。Claim時のcore名拒否は補助防御であり、このBase ownership照合を置き換えない。

`Config/repository-tests.json`を変更する場合、BaseとHeadを構造比較し、`schemaVersion`、`headAllPaths`、`headAllPrefixes`、Baseの全domain ruleと全test objectをexact保持する。追加できるのはcanonicalなprovider domain名とsafeな許可path／prefixへ閉じた新しいdomain rule、および宣言済みprovider toolを実行する対応testだけであり、各新domainに新testを対応付ける。path escape、既存rule／testの削除、置換、再分類、path拡張、既存testの引数やdomain変更を拒否する。単にmanifestが許可pathであることを、既存repository test境界を弱める権限へ読み替えない。

bindingはClaim前に検証してIssue contractへそのまま封印し、Claim後のcontract revisionではcriterion位置と宣言全文を保護する。bindingがない既存／新規application contractは従来のscoped diff判定をbyte互換で維持し、fixture例外を合成しない。workflow-only Issueはこのroute自体のguard、仕様、直接regression testを実装できるが、同じIssueへprovider fixture、provider skill、provider tool、application projectを追加してはならない。routeの正常系regressionはfake adapterで既存runner entrypointを最後まで実行し、Build、Unit、required case、cleanup、final publicationとsealed project再照合を確認する。

このrouteを利用するapplication Issueは、contractと確定仕様を追加する#121、およびscoped validator／runner／evidence consumer／Issue formを有効化する#122の双方を`state:done`の依存として持つ。#121だけの完了からruntime routeを利用可能と推測せず、#122完了前はbindingを持つprovider実装IssueをClaimしない。

### 3.5 Repository testsのBase／Head要件

cutover前のexact `Repository-test scope: base-and-head; <nonempty>`またはcutover後のexact `Repository-test scope: base-and-head; Reason: <nonempty>`を一つのAC本文先頭に宣言したIssueは、現在HeadのproducerでBaseとHeadそれぞれの全tracked `tools/tests/test-*.sh`を実行する。宣言ACは両revisionの全suiteへ対応付け、各ACのHead実装証拠とBaseのbaseline／regression証拠を区別する。cutover前のcanonical schema v2またはcutover後のplan-bound schema v3 record、packetのexact-byte参照、同じpacketに束縛したreview／receipt、premergeの再検証まで完了条件に含める。片方の欠落、subset、別SHA／Issue／contract、失敗／timeout／未完了、差し替えは成功ではない。

選択条件と互換境界は[D-034](decisions.md#d-034-baseとheadの全repository-test証拠を明示契約へ束縛する)および[D-037](decisions.md#d-037-repository-testの要求scopeと実行計画を二段階で封印する)、手順とschemaは[repository evidence](../docs/verification.md#repository-test-planと対象実行)を正とする。宣言を持たない既存sealed contractと旧Head-only record／packet／receiptのbytesを変更せず、旧証拠から新planやBase実行の証拠を作らない。

### 3.6 Claim後のIssue contract revision

Claim後に同じIssueの検証方法またはAcceptance criteriaの説明を修正する必要がある場合は、Issueがexact `in-progress`である間だけ専用revision経路を使う。変更可能なのは`verification`、既存と同一ID・同一順序の`acceptanceCriteria[].text`、再取得時刻`fetchedAt`だけである。ただしAC本文先頭の`UI-direction route:`はcriterion位置・route・Scope、`Repository-test scope:`はcriterion位置・scope、`Opposite-review route:`はcriterion位置・route／primary／reviewer／approval、`Release-phase binding:`と`Application-fixture binding:`はcriterion位置・宣言全文を保護し、追加、削除、移動、保護値の変更を許可しない。Goal、MVP、Spec anchors、Dependencies、Delivery stage／profile／scope、Issue type、外部操作と承認を変更してはならない。許可field内でも目的またはMVPを別物へ置換する意味変更は、別Issueと現在ユーザーの判断へ戻す。

authorityは次の三つだけを許可する。`review-finding`は同じIssue、現行contract digest、source Headに束縛されたcanonical `changes-requested` review／receiptのblocking findingを参照し、reasonをその`requiredChange`とexact一致させる。`user-explicit`は設定済みGitHub ownerが、変更前contract digest、変更後body digest、source Head、scope、reasonを含むcanonical markerを同じIssueへ投稿する。`user-delegated`は同じmarkerで現在executorをdelegateとして明示する。別Issue、古いcontract／Head、owner以外、silent approval、推測delegateをauthorityにしない。

各改訂はrevision 2から単調増加し、変更前後のIssue body／contract、変更前後のdurable state、変更field、reason、authority、前record digest、Base／Branch／worktree／source Head、失効対象をsingle-link・no-replace artifactとして追記する。durable stateは最新recordのpath／digest／revisionと新contract digestを指し、以前の`headSha`を外す。`verification`、`review`、Head bindingは失効するが旧artifactを削除せず、Base、Branch、worktree、source Headは履歴として保持する。pending中は通常state transition、resume、外部操作、review packet生成、pre-mergeを拒否し、同じrequestだけを冪等に再開する。recordなしのcontract／state変更、broken chain、別revisionの再開を成功扱いにしない。

改訂完了後は現行contractと新Headで対象検証、review packet、反対モデルreview、pre-mergeを作り直す。application `Verification`のrunnerは一つの`unitTestIdentifier`だけを受け付けるため、複数確認が必要なら一つの統合XCTestへ集約するか、同一ID・同一順序を保ったAcceptance criteria／mappingの正式revisionで表現し、複数identifierを非正規に注入しない。

## 4. Simulator scope

| Case | Device | Locale | Language |
| --- | --- | --- | --- |
| `iphone-en` | 最新の利用可能なiPhone Pro。Pro Maxを除く | `en_US` | `en` |
| `iphone-ja` | 同上 | `ja_JP` | `ja` |
| `ipad-en` | 最新の利用可能なiPad Air | `en_US` | `en` |
| `ipad-ja` | 同上 | `ja_JP` | `ja` |

`iphone-ja`は1行だけ、`targeted`は表の非空canonical部分集合、`full`は4行すべてを固定順で使う。「最新」はバッチ開始時にインストール済みXcodeから解決して固定し、条件に合うdeviceがなければ`blocked:environment`とする。Claim済みscopeを暗黙に縮小せず、別scope／別Headのmatrixや証拠を流用しない。

AI検証用deviceは必要時作成・最終使用後削除とし、同じMac全体でiPhone／iPad合計最大4台、一つのsessionで原則1台とする。予約、作成済み、Shutdown、削除待ちを数え、作成前にMac共通枠とsession枠を原子的に取得する。満杯時は有限・取消可能に待機し、同一sessionの4条件は作成、検証、証拠保存、削除確認、枠返却を一件ずつ行う。

成功、失敗、timeout、cancel、部分作成失敗、強制終了後の孤児をcleanup対象とする。証拠をdevice外へ保存し、exact UDIDとowner／lease／非活動状態を確認してからdeviceとdataを削除し、一覧とdata残留の確認後だけ枠を返す。停止／erase、名前一致、Shutdownだけを削除完了や所有根拠にしない。手動device、他repository／session、使用中、不明なdevice、Runtime、Xcode、共通cache、ユーザーDerivedData、canonical evidenceを保護する。

容量／memoryが不足すれば4台未満でも新規作成と長時間反復を止める。#93以後のschema v2 matrixはMac共通lease、session上限、孤児回収、容量preflightを使い、実行UDIDと削除receiptをversioned artifactへ固定する。#89は#93への移植元履歴として保持する。旧schema v1の固定UDID matrixと既存証拠はimmutable legacyとして受理し、遡及変換しない。検証／App Store skillsと既存Issue移行は#88の共通consumer境界を使う。

## 5. 常設品質ゲート

- Build warningを新規に増やさず、失敗Testを削除／Skipして成功扱いにしない。
- ユーザーデータ、保存互換性、重要な金額／日時／認証／課金ロジックをstageに関係なく守る。
- String Catalog等の安定したkey、可変layout、iPad target、既存英語resourceを初期から壊さない。
- 認証情報、個人情報、設定外account識別子を証拠へ含めない。
- 外部操作の成功は実応答から確認し、推測で記録しない。
- ユーザー所有fileを削除／上書きせず、Issue Scope外へ実装を広げない。
- Release PhaseとIssueのDelivery stageを混同せず、Phase 5〜6の証拠を再利用するときも同一candidate／Head／configへの適用可能性を確認する。D-049の適用recordだけからD-050の残件判断を合成しない。

## 6. Timeout、失敗、再試行

- `xcodebuild`、Unit Test、UI Test、Simulator／Swift操作は有限timeoutで実行する。
- timeout時は当該呼び出しのprocess groupだけを停止し、現在attemptが所有するSimulatorとlockだけを回収する。別Issue、別repository、ユーザーのXcode／Simulatorへglobal kill／shutdownを行わない。
- failure recordへ停止stage、elapsed、timeoutを残し、成功形式の`verify.json`を生成しない。
- D-050対象のfailure recordは同一Issue／Headのrelease dispositionからexact path／digestで一度だけ参照し、`shrink`、`split`、`defer`、`wait`のいずれか、理由、actor／authority、follow-upまたは再開条件、判断時刻を記録する。failure、timeout、未実行testはその後もpassed testとして数えない。
- 同一Issue／Head／scopeの失敗・timeout後は直接再実行を拒否する。選択済み対象testの診断成功後に限り1回だけ再試行し、2回目も同じ原因で失敗したら停止する。
- 再実行は対象Test、関連回帰Test、stage標準検証、release完全検証の順に広げる。
- 正式証拠へ別attemptの部分結果を混ぜないが、診断用の成功結果は修正判断に利用する。
- review不能は`blocked:review`、外部認証／rate limitは`blocked:ops`、Xcode／Runtime／Simulator不足は`blocked:environment`、仕様判断不足は`blocked:user`、依存未完了は`blocked:dependency`。

## 7. Bootstrap Issue

Foundation、Identity bootstrap、Simulator verificationなどテンプレート全体のgateを変更するIssueは`strict`で扱う。自動化tool自身が未実装の間だけ手動実行を許すが、Build、Test、要求stageのSimulator、必要な反対モデルreview、Head一致を免除しない。生成後の使い捨てrepositoryでもshapeとreleaseの契約／runnerを確認する。

## 8. App Store原稿と登録準備

[正本と登録準備](architecture.md#91-原稿の正本と登録準備)のread-only入口`tools/prepare-appstore-sources.sh`は、次を満たす。#53の設計、#110のsource検証、将来の実登録・保存を区別し、合成fixtureの成功をlive外部検証へ読み替えない。

- field inventoryがidentity、localized原稿、version、locale、SKU、category、copyright、公開URL、review contact、privacy、age rating、IAP、Team/App/accessを覆い、各値のsource・確認分類・ASC欄を追跡できる。
- Bootstrapで導出できる値と個別確認値を区別し、原稿台帳の`draft`、`confirmed`、`remote-saved`を取り違えない。source変更で影響fieldの確認を失効させ、未決理由を列挙する。
- versioned preparation JSONと確認証拠は既存YAML／封印済みpackage／resultと分離する。台帳からの明示転記は元のbytesと未知の回答を保全し、ラベルだけで承認しない。ローカル専用fieldを架空のASC formとして保存済みにせず、対応resourceのID・locale・source・承認と完全なbaseline/readbackを照合する。private実値の保全比較は一時pipeだけで行い、実値や値hashを公開・永続化しない。
- 新規登録前に正しい個人Team、同一Bundleの既存App、platform/name/primary language/Bundle/SKU/accessを確認する。成功不明時はreadbackしてから再開し、名前だけの一致で再利用したり、重複作成したりしない。
- Team未設定・別Team、Bundle未登録、App未作成、名前重複、権限不足、契約更新を区別する。契約同意、初回法務本文、価格、アクセス変更はユーザーへ引き継ぎ、秘密・連絡先実値は保存しない。
- [必須fixtureとreadiness例](../docs/agent-contracts/appstore-submission.md#readiness-report-and-required-fixtures)で、テンプレートBundle/文面、invalid・未公開URL、広告SDKとprivacyの乖離、age rating未回答、IAP本番未設定、確認済みsourceの変更、曖昧なremote応答を検出する。正常な合成アプリでは根拠付きfieldだけを確認済みとし、独立欄の準備を継続できる。
- 既存package/result/checklistの互換性、完全release gate、初回法務承認、外部operation境界を維持する。スクリーンショットは別途依頼・確定前に生成しない。文書リンクと現在Headの反対モデルレビューを完了する。

原稿先行保存は同じ基盤の拡張とし、[構成 §9.2](architecture.md#92-原稿保存と正式提出の分離)と[保存契約](../docs/agent-contracts/appstore-submission.md#operation-modes-and-selective-metadata-save)に従う。#52は仕様とroutingの完了であり、次のremote操作やTestを実装・実行済みとは報告しない。

- `draft`／`save`／`ready`／`submit`の入力、出力、禁止操作を区別する。画像・build・法務が未完でも、独立した確認済み一般原稿の保存だけを正しいTeam/App/Bundle/version/localeと操作権限の下で進められる。公開影響や必須form fieldが不明・未許可ならその保存を止める。
- package外の別形式にsource相対path・anchor・revision/digest、locale/section、remote identity、差分・保存結果・readback digest、blocked/deferred理由を記録する。片言語だけの成功を全件成功とせず、source/remote driftと認証を再確認してから再開する。
- [手動検証表](../docs/agent-contracts/appstore-submission.md#selective-save-verification-plan)の全caseを確認し、後続実装では実入口の合成fixtureへ落とす。英語／日本語、Unicode、byteと文字数、Apple公式要件の再取得を含み、未知値の空文字上書き、権限外のform同時保存、曖昧応答の盲目的再試行を拒否する。
- 部分保存記録では全素材・申告・法務・release audit・明示提出許可を満たせず、既存release journalに流用できない。実装Issueのwrite-setとTest計画は§9.2で定め、#110のread-only準備と実保存を混同しない。

App Store Connect API adapterは[構成 §7.2](architecture.md#72-app-store-connect-api-adapter)に従い、次を満たす。#142（#129の後継）は契約の確定だけであり、次の実装・install・live API成功を完了済みとは報告しない。

- `asc`は公式releaseのmacOS arm64 assetをexact versionとSHA-256で固定し、公開checksum fileとpin recordの双方に一致したbytesだけをrepository外へ配置する。起動ごとにversionとdigestを再照合し、Homebrew、install script、自動update、未固定versionを使わない。
- guarded runnerだけが`asc`を起動し、operationごとのsubcommand／flag allowlist、JSON出力、有限timeout、redaction、telemetry無効、隔離設定を強制する。web session、`--deep`、`auth login`、`apps wall`、`install-skills`、`signing`系、`workflow run`、allowlist外subcommandを拒否する。
- 認証はTeam keyのApp Manager roleとし、Key ID、Issuer ID、`.p8`を子process envへだけ渡す。値と値hashをartifact、Issue、PR、log、promptへ残さず、`asc`自身の認証保存やrepository内設定を使わない。
- production preflightは読取専用API照会でTeam、Bundle ID、App record、versionをexact照合し、宣言済みoperationごとの証拠を発行する。TestFlight配信operationを含む全`appstore.*` operationは`release`、`full`、`strict`、宣言済みExecutor、必要なユーザー承認を要する。
- metadata save、build upload、release section、TestFlight配信はそれぞれbaselineまたは固定入力、実行、readbackの一致だけを成功とし、部分成功、曖昧応答、timeout、digest不一致を成功にしない。App Privacyだけを既存browser sectionに残し、readback sourceを区別して記録する。
- テンプレート内の実装Issueはfake `asc`とfake `xcodebuild`による正常／拒否／曖昧応答の回帰で完了し、派生アプリのlive API結果、App Store審査、TestFlight beta reviewの結果とは別の証拠として扱う。

AppLibrary法務ページへの引き継ぎは、次を満たす。

- confirmedな英語／日本語のsupport・privacy・terms原稿、source path／digest／approval、source Issue／Head、app identity、実装・データ利用・広告・課金の事実、ユーザー承認済みhost／route、返却契約から、exact target `yuto1201/Web-AppLibrary`向けのcopy-ready Markdownを決定的に生成する。不足、未知field、symlink／path escape、digest不一致、秘密らしい値を拒否する。
- Web Issue作成はsource Issueの`github.create_issue`、executor、設定済みaccount／targetに従い、open／closed重複検索、直前preflight、一度だけの作成、title／body／URL／stateのexact readbackを必須とする。曖昧な応答後は検索・readbackで照合し、盲目的に再作成しない。
- promptのWeb実装AIへの転送と法務本文・公開の承認はユーザー操作として別々に参照を残す。Issue作成、AI review、PR、deploymentから承認を推測しない。
- 公開返却はrequest／prompt／Web Issue／deployment／user actions／source digests／URLsを結び、approved HTTPS host／route、redirectなし、ログイン不要HTTP 200、approved source本文とlocale、同一localeの3ページ相互linkを検証する。live `verified`だけをApp Store用URLへ引き継ぎ、`fixture-validated`は`appStoreEligible: false`としてrelease証拠にしない。
- 手順は既存の初回法務承認、release package、監査、提出権限を弱めず、Web repository編集、Vercel deploy、Cloudflare／DNS変更、App Store Connect更新・提出を認可しない。tracked regressionは正常系に加えwrong repository、401、本文不一致、link欠落、fixture非適格を固定する。

## 9. 条件付きAdMob統合

[プロダクト方針 §4.1](product.md#41-条件付きadmob収益化)と[構成 §7.1](architecture.md#71-条件付きadmob統合境界)を正本とする。この節は後続実装／品質Issueのend-state受け入れ条件を固定するものであり、仕様Issueの完了だけで下記を実装済み・検証済みとしない。各項は対応する後続Issueのcurrent-Head成果とstage別証拠が揃った場合だけ完了とする。

- [ ] 未採用の`TemplateApp`とbootstrap outputにGoogle Mobile Ads SDK／package、AdMob設定、identifier、consent／banner sourceが追加されず、有効化しない生成結果が不変である。
- [ ] 専用activationはアプリIdentity／Deployment Target、対象年齢／地域、実行時にGoogle／Apple公式sourceで再確認したSDK条件／exact version／対応Xcode・iOS／SKAdNetwork・privacy要件、Debug demo identifier、Release production identifier、配置、eligibility／広告非表示権利、privacy options入口、data use／App Store申告を入力とし、参照URL／取得時刻／判断結果を記録する。未決・欠落・矛盾は変更前に`blocked:user`または適切なblocked状態で拒否する。
- [ ] DebugはGoogle公式demo identifierのみ、UI Testはnetwork-free fixtureのみ、Releaseはapp固有production identifierのみを使い、欠落、demo／productionの混在、別アプリ／configurationのidentifierをvalidatorが拒否する。
- [ ] UMPのconsent info更新、必要form、`canRequestAds`、privacy options入口が設計どおりに接続され、SDK初期化と広告要求が一つのapplication lifecycle内で1回化される。consentとeligibilityが広告要求の先に評価される。
- [ ] 既定の非tracking経路はATT promptを表示せず、Publisher first-party IDを無効化する。personalized ads、tracking、IDFA／ATT、anchored adaptive banner以外の広告形式は別Decision／Issueの明示承認なしに追加されない。
- [ ] adaptive banner hostは実container widthからsizeを解決し、回転、safe area、Tab再選択、scroll内配置、SwiftUI再構築で不要な再requestを起こさず、広告非表示／対象外／load失敗時は領域をcollapseする。対象画面と配置は派生アプリの確定仕様／UI Issueにより、有効なUI Direction routeとnative検証へ結び付く。
- [ ] `Info.plist`のGoogle Mobile Ads App ID／SKAdNetworkItems、resolved SDK／privacy manifest／signature、アプリの`PrivacyInfo.xcprivacy`、実装data use、App Store申告の差異を同一candidateで検出する。#110のread-only source preparationはdriftを報告できるが、provider実装、remote設定、App Store Connect保存／提出、release-readyを実行または証明しない。
- [ ] offline fixture、Google demo smoke、AdMob Console remote state、productionのApp Store readiness／配信状態が個別に報告され、一つの成功から他の完了、収益発生、審査通過を推測しない。
- [ ] AdMob Consoleのaccount／app／ad unit作成、契約・支払・税務、consent message／app-ads.txt公開、production identifier取得、App Store Connect保存／提出は、個別のoperation／Executor／account／target／必要なユーザー承認／readbackなしに実行されない。#101の法務ページ引き継ぎも広告設定、公開承認、App Store操作への権限を拡張しない。
