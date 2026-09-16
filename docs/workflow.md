# Issue-to-merge workflow

## 1. 作業単位

- 1 Issue = 1 Branch = 1 PR
- Codex Branch: `codex/${issueNumber}-${slug}`
- Claude Branch: `claude/${issueNumber}-${slug}`
- Worktree: `.worktrees/${issueNumber}-${slug}`
- Base Branch: `main`
- Merge method: Squash

Primary implementerとExternal orchestratorはCodexまたはClaudeです。各認証済み外部操作はIssue contractの`Executor`へ実行モデルを明示し、`docs/AUTHORITY.md`の共通account／target preflightを通します。

BranchはIssue作成後に作ります。Issue番号を推測して先にBranchを作りません。

## 2. Issueの塊

ユーザーは単一Issue、既存Issue群、または機能の塊を指定できます。機能の塊の場合、`plan-issue-batch` が次を行います。

1. 仕様の確定・提案・未決を分類する。
2. 受け入れ条件を変える未決があれば相談する。
3. 最小のレビュー可能単位へIssueを分ける。
4. 依存グラフを作る。
5. 同じファイルやXcode設定を触るIssueを直列化する。
6. 独立した文書、App Store文面、局所機能だけを並行化する。
7. 各IssueへDefinition of Readyを記載する。

Issue数を増やすこと自体を目的にしません。セットアップとその成果物が独立して価値を持たない場合、同じIssueへ含めます。

[段階的開発仕様](../specs/development-stages.md)に従い、release unitはPhase 1〜6で進め、個々のIssueでは最初の操作可能な成果を`shape`、承認後の問題別改善を`harden`、完全検証を`release`へ分けます。一つのharden Issueへ無関係な品質項目を束ねません。Release Phase、変更の危険度、Issue成果物の成熟段階、端末・言語範囲を別々に記載します。

### 2.1 shape前のUI Direction Gate

現在のユーザーが対象範囲のHTML比較を明示した場合は、確定済み方向の有無にかかわらず最優先で[UI Direction skill](../.agents/skills/ui-direction/SKILL.md)を実行します。明示省略は現行性、scope、権限、理由が明確で比較指示と矛盾しないときだけ通常判定を上書きします。

それ以外の通常判定では、exact hierarchy／flowを覆う確定方向があればconfirmed-direction reuse routeを使います。覆う方向がなく対象範囲のUI方向が未確定で、最初のユーザー向けUI、ルートnavigation／information hierarchyの新設・変更、主要flowの大幅な再設計のいずれかに該当するときは、dependentなSwiftUI `shape`より先にGateを実行します。方向未確定かつ構造triggerなしなら、Acceptance criteriaがhierarchy、navigation、primary-flow interactionを決めない範囲だけbounded direction-neutral routeを許可します。Issue分類ではなくexact scopeで判定し、coverage／trigger／neutralityが曖昧ならGateへfail closedします。

cutover後のClaim前に、既存のAcceptance criteria全体でexactly oneの有効なroute宣言を記録します。一つのAcceptance criterion本文の先頭（`AC-*:`の直後）をexact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`で開始し、`<route>`は`comparison`、`explicit-skip`、`confirmed-direction reuse`、`bounded direction-neutral`、`not-applicable`のいずれかだけとします。route固有の適用事実はReasonの後へ続け、prefix外のroute語は宣言として数えません。`confirmed-direction reuse`は再利用するUI方向anchor、`bounded direction-neutral`は関連product／behavior anchor、`explicit-skip`は関連product／spec／Decision anchorを`Spec anchors`へ置きます。`comparison`では選択spec／Decisionを`Spec anchors`、完了済み専用IssueをDependenciesへ置きます。明示省略の現行性、scope、権限、理由または比較指示との関係が曖昧なら依存UIを`blocked:user`にします。沈黙や曖昧な同意を選択またはskipに読み替えません。

cutover後にClaimするIdentity bootstrapと純粋な非UI作業はnot-applicable routeであり、UI方向anchorを必要としません。`UI verification`本文はexact `Not applicable`だけとし、対象scopeと非UI理由をGoal／In scope等の既存scope節へ記録し、一つのAcceptance criterion本文を`UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`で開始して、関連する確定済みproduct／spec anchorを`Spec anchors`へ記録します。それらに続く方向選択依存のnative UIだけをGate判定します。

UI Issueの`UI verification`は`Target screens/states`、`English expectations`、`Japanese expectations`のexact 3 fieldをこの順で持つlive guidanceです。routeを補助的に示してよいもののIssue contractへ封印されず、review packetにも入りません。最終reviewはrouteをAC本文先頭の有効な宣言だけから識別し、Goal、Acceptance criteria、`Spec anchors`、Dependencies、リンク済み確定spec／Decisionとcurrent-Head差分／証拠でScope、Reasonとroute固有事実を検証できるようにします。新しいfieldは追加しません。

D-030 cutoverは置き換え後のIssue #47の`createdAt`である`2026-09-06T00:31:41Z`です。封印済みIssue contractの`fetchedAt`をUTC instantとして比較し、cutoverより前でAcceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補がゼロの場合だけpre-D-030 legacyとします。legacy contractへrouteを推測・追記・再封印せず、HTML比較を遡及要求せず、元の封印済みAC、spec anchors、Dependencies、current-Head evidenceで継続します。cutoverより前でも候補が一つ以上あれば通常検証へ進み、候補がexactly oneかつ許可routeと非空Scope／Reasonを持つ完全な宣言でなければrejectします。cutoverと同時刻以降のcontractにも同じexactly-one／完全性を必須とします。Issue番号、Issue更新時刻、file mtime、live `UI verification`、prefix外のroute語は互換判定に使いません。

gateは次の順で進めます。

1. 確定仕様から、目的、対象ユーザーとjob、画面／状態、主要task、content／data、platform／accessibility制約、対象外、仕様anchorを一つのrequirements briefへまとめる。受け入れ条件を変える未決事項は案で補完せず`blocked:user`にする。
2. 同じviewport、content、合成data、対象state、task、同等の完成度を使い、画面階層、navigationまたは主要interactionの仮説が実質的に異なるstable ID付き2〜3案を、一つの自己完結HTMLへ作る。色や角丸だけの案分けは行わない。
3. 各案へ仮説、trade-off、iOSへの翻訳方針、accessibility上の考慮、静的HTMLでは確認できない制約を記載する。秘密、実個人情報、tracking、remote script／font／image、network requestを含めない。
4. `.artifacts/ui-direction/<flow-slug>/<revision>/comparison.html` の提示bytesをSHA-256とrevision IDへ固定する。提示済みrevisionを上書きせず、brief、HTML、concept IDまたはscopeを変更した場合は新revisionを発行する。
5. ユーザーから一つのconcept ID、または全採用要素からsource concept IDへのexhaustive mappingを持つexact hybridを受け取る。hybridのselected／base concept IDはユーザーがbaseを明示した場合だけ求める。称賛、順位、部分的感想、無回答、曖昧または非網羅なhybridは承認ではない。必要なら組合せ案を新revisionとして再提示する。
6. scope、artifact path／revision ID、提示bytesのexact SHA-256、採用・不採用要素、対象画面／状態、native adaptation範囲を共通して確定仕様と追記型Decisionへ記録する。単一案ではselected concept ID、hybridでは全採用要素からsource concept IDへのexhaustive mappingを加え、ユーザーがbaseを明示した場合だけselected／base concept IDも加える。その仕様変更を独立Issue／Branch／PRでmergeしてからdependent UI Issueを`approved`またはClaimへ進める。

選択待ちは`blocked:user`、記録PRの未mergeは`blocked:dependency`です。gateに依存しないIdentity bootstrapや非UIレーンは継続できます。HTMLとdigestはdecision-support artifactであり、仕様の正本、SwiftUI source、pixel仕様、canonical iOS evidenceではありません。

### 2.2 App Icon Gate

新しいアプリでは目的・方向性と4つのIdentity入力を確定し、Identity bootstrapをマージした後、最初のユーザー向けUI `shape`より先にApp Icon Issueを作ります。このIssueはIdentity bootstrapへ依存し、画面階層、navigation、primary-flow interactionを決めない`bounded direction-neutral` routeとして扱います。アプリアイコン選択はUI Direction Gateの代用になりません。

[`app-icon`](../.agents/skills/app-icon/SKILL.md)は同じ確定briefから、built-in画像生成によるsimpleかつ意味の異なるexactly 2候補をimmutable revisionへ作ります。ユーザーがstable concept IDを一つ明示選択した場合だけ、選択済みPNGとsanitized recordをIssue worktreeへ組み込みます。組合せまたは重要な変更は新revisionを生成して再選択し、提示済みcandidateを上書きしません。選択待ちは`blocked:user`ですが、独立した非UI Issueは続行できます。

installerは`Config/app-identity.json`からmodule pathを解決し、1024 x 1024、不透明、system mask前の正方形PNGとdefault AppIcon entryを検証します。現在のApple公式ガイダンスを生成直前に再確認し、選択済みasset、`Contents.json`、`Config/app-icon.json`だけをcommitします。候補、provider response、previewは`.artifacts/app-icon/`へ置き、canonical iOS evidenceや製品assetとして扱いません。

### 2.2.1 System Experiences Planning Gate

Identity bootstrap後、主要Feature Issueの計画またはClaimより前に、[`ios-system-experiences`](../.agents/skills/ios-system-experiences/SKILL.md)で専用のSystem Experiences Planning Issueを完了します。`widget`、`live-activities`、`dynamic-island`、`controls`、`siri-app-intents`の5面を最新のApple公式sourceで確認し、テンプレートにある[計画record](../.agents/skills/ios-system-experiences/templates/system-experiences-plan.md)へ`adopt-now`、`defer`、`not-applicable`、`blocked:user`のいずれかを記録します。

全5面の評価は必須ですが、採用は任意で、最終判断はユーザーが行います。計画Issueではframework、Extension target、entitlementを追加しません。`adopt-now`面だけを共有domain action／data、extension process、capability、privacy、日英localization、accessibility、fallback、検証、release依存が分かる専用Issueへ分解します。App Icon IssueはIdentity bootstrap後に並行でき、system UIの方向選択はこの計画で代替せず、必要なdependent IssueをUI Direction Gateへ接続します。

一面の判断待ちは、その面へ依存するIssueだけを`blocked:user`または`blocked:dependency`にする部分blockingです。確定済み面、App Icon、独立したdomain／data／非UI作業は継続できます。主要FeatureのIssue graphを変更する採否変更はPhase 1またはPhase 2の影響箇所だけを再gateし、過去のrecordを上書きせず追記します。

### 2.3 3D authoring route

ClaudeとCodexは通常のIssueを同じworkflowで担当します。3Dモデル、mesh、material、rig、animationの作成・生成・形状変更だけは[`ios-3d-assets`](../.agents/skills/ios-3d-assets/SKILL.md)へrouteし、Codexのexact model `gpt-6-astra`がauthoringします。Claudeまたは別のCodex modelがIssueを担当している場合も、3D asset bytesのauthoring部分だけを同モデルへ依頼します。

`gpt-6-astra`を利用できない場合は`blocked:environment`とし、Claudeや別modelへfallbackしません。要件整理、受領済みassetの統合、決定論的なformat validation、RealityKit実装、Build／Test、視覚確認、reviewはClaudeまたはCodexが継続できます。Issue／PR証拠へexact authoring modelを記録し、確認できない生成物を承認済み3D成果として扱いません。

### 2.4 リリース単位の6Phase gate

アプリ開発を始めるときは、一つのMVPまたは公開目標をrelease unitとして識別し、[6開発フェーズ](../specs/development-stages.md#15-リリース単位の6開発フェーズ)へ配置します。PhaseはIssue stateやDelivery stageではありません。同じPhaseで複数Issueを順次mergeでき、Issueごとのstage、profile、Verification scope、Head証拠を維持します。

計画時はrelease identifier、revision、目的、scope、対象外、現在Phase、前Phaseの出口、依存Issue、ユーザー承認、証拠、既知不具合、テスト省略、未検証、繰越を追跡します。Phase 1のscope承認、Phase 3の日本語iPhone主要機能完了、Phase 4の英語／iPad対応完了、Phase 5の残件許容は、ユーザーが対象revisionを明示判断するまで完了にしません。

前Phaseが未完了なら依存実装を開始しませんが、read-only調査、選択肢、Issue草案、依存しない作業は進められます。軽微変更は同じPhaseで継続し、目的、MVP、主要flow／hierarchy、採用system、data互換性、重大riskが変わる場合だけ、変更記録を追加して影響する最も早いPhaseへ戻します。影響しないIssueは止めません。

Phase 5で問題を見つけた場合は、問題別のRegression／harden Issueへ戻して修正し、その変更で失効した証拠だけを再取得します。Phase 6では同じcandidate、Head、config、SDK／signing context、scopeへ適用可能なPhase 5証拠を参照し、重複実行を避けます。適用判断は[`evidence-applicability.json`](verification.md#12-phase-5から6への証拠適用)へno-replaceで固定し、同じrecordをreview、PR、pre-merge、提出前preflightまで引き継ぎます。既知不具合、意図的な省略、未検証を別々に記録し、重大blockerが残る候補は公開しません。

既存アプリの緊急修正は、現在も適用可能な目的、Identity、UI方向、基盤を理由付きで再利用し、影響するPhaseから開始します。毎回App IconやHTML比較をやり直しませんが、Issue／Branch／PR、対象Test、安全確認、必要review、外部操作承認は省略しません。

AI検証用Simulatorは必要時に作成し、使用後にdeviceとdataを削除します。同じMac全体でiPhone／iPad合計最大4台、sessionごと原則1台とし、一つのsessionのmatrixは作成、検証、証拠保存、削除確認、枠返却を逐次行います。#93の共有枠、所有lease、異常終了回収、容量preflightをrunner、検証skill、App Store撮影へ共通接続します。#89は#93への移植元履歴として保持します。手動deviceや不明なdeviceを削除せず、resource managerを通らない旧経路を共通上限対応済みと報告しません。

#### Phase recordとIssue binding

Phase-awareなIssueは、Git管理下の`Config/releases/<release-id>/phase-records/<record-id>.json`を参照するexactly oneのAcceptance criterion宣言を持ちます。recordはschema v1のcanonical JSONで、release identifier、current revision、current scopeと、sequence順の追記履歴を保持します。新しいrecordは直前recordのhistoryをbyte-equivalentなprefixとして一件だけ追加した別pathへno-replaceで作り、提示済みrecordを上書きしません。

```markdown
- AC-N: Release-phase binding: {"phase":4,"reason":"Phase 4 consumes the approved Phase 3 result.","recordDigest":"sha256:<64 lowercase hex>","recordPath":"Config/releases/example-v1/phase-records/record-0008.json","releaseIdentifier":"example-v1","revision":3,"route":"standard","scope":["core","settings"],"workKind":"implementation"}
```

prefix後は上例と同じ9 keyを辞書順に並べた空白なしcanonical JSON objectとします。`scope`はsortedで重複のないnonempty string arrayです。`workKind`は`implementation`、`research`、`draft`、`independent`、`route`は`standard`、`existing-app`、`emergency`のいずれかです。宣言は既存のsealed `acceptanceCriteria`へそのまま保存されるため、新しいmutable contract fieldやlive guidanceへ依存しません。ClaimはBranchやworktreeを作る前に、exact Base commitのregular Git blobを読み、record digest、release、revision、scope、work kind、routeと前Phase出口を同じvalidatorで照合します。workspace上の未commit fileや別revisionの承認へ読み替えません。

`implementation`は要求Phaseより前の全出口を必要とし、Phase 1、3、4、5の完了eventは`authority: user`とnonempty approval referenceを必須にします。したがってPhase 3のAI作業完了だけではPhase 4実装を開始できません。`research`と`draft`は前Phase未完了でもread-only成果として進められます。`independent`は理由を明記した非依存laneだけを許可し、依存成果の実装を迂回する分類には使いません。

履歴eventは次の意味を持ちます。

- `release-created`: release identity、初期revision、goal、scopeを作る。Phase出口の承認にはしない。
- `phase-completed`: 同一revision/scopeの出口、承認主体、根拠、evidence、known defects、omitted tests、unverified、carryoversを記録する。
- `change-classified`: `minor`はrevisionとscopeを変えず既存出口を維持する。`major`はユーザー承認、変更前後、影響spec/Issue、失効・保持証拠を記録してrevisionを一つ進め、`reopenFromPhase`以降だけを無効化する。`unclassified`は依存implementationを停止する。
- `phase-reused`: `existing-app`または`emergency`について、現在も適用可能なpurpose／identity／ui-direction／data、対象scope、再利用理由、ユーザー承認を記録し、指定Phaseまでを再利用する。

record producer／validatorは次の固定入口を使います。`append`の`--event-json`は上記eventのsequence以外を含み、producerが次sequenceとderived current revision/scopeを決定します。

```sh
ruby tools/lib/workflow-release-phase-cli.rb init \
  --release example-v1 --revision 1 --scope-json '["core"]' \
  --goal 'Ship the first usable flow.' --actor codex \
  --reason 'Create the approved release unit.' --recorded-at 2026-09-14T00:00:00Z \
  --output Config/releases/example-v1/phase-records/record-0001.json

ruby tools/lib/workflow-release-phase-cli.rb append \
  --previous Config/releases/example-v1/phase-records/record-0001.json \
  --event-json "$EVENT_JSON" \
  --output Config/releases/example-v1/phase-records/record-0002.json

ruby tools/lib/workflow-release-phase-cli.rb validate \
  --record Config/releases/example-v1/phase-records/record-0002.json \
  --previous Config/releases/example-v1/phase-records/record-0001.json
```

`Release-phase binding:`宣言を持たない既存Issueは`legacy-unbound`として従来のIssue state／stage／profile gateを維持し、phase recordを合成・補完・再封印しません。新規Issue form、planning、Claim、batch、bootstrap、verification、App Store skillsは同じbindingを標準入力として扱います。#86の証拠適用resolverと#87の不具合許容判断もこのrecordだけから推測しません。

#### Phase consumer routing

計画時はPhase recordを将来のClaim Baseへ先にmergeし、新規phase-aware Issueの既存AC一つへbindingを記載します。Claimは`implementation`の前Phase出口を検証し、batchは同じrelease／revision内でPhase順とIssue依存を両方守ります。`research`／`draft`はread-only、`independent`は理由付き非依存laneに限定します。Minor修正は同Phase、major変更はユーザー承認付きの新revisionと最も早い影響Phaseへの部分再gateです。

実行と検証では、Phase 3を日本語iPhone主要機能と軽量証拠、Phase 4を英語／iPadの対象拡張、Phase 5を完全品質、Phase 6を証拠適用判断と公開準備へrouteします。Phase 6のiPhone 6.9-inch画像はGoldieのlocale別config／import／renderを標準とし、iPadは`tools/capture-appstore-screenshots.sh`を使います。両経路とも共通Simulator session、全画像監査、package seal、upload／submitの独立gateを維持します。

既存Issueの移行はstateごとに扱います。

- `proposed`／未Claimの`approved`: 現行spec、successor依存、phase record、expected write-setを本文へ反映し、`validate-issue-body.sh`、GitHub更新、readbackの順で確認してからClaimする。
- `claimed`／`in-progress`／検証以降: sealed contractを直接編集しない。既存契約のまま完了するか、目的を変えない許可範囲だけ#38の追記型revision経路を使う。`Release-phase binding:` identityは保護対象なので後付けせず、phase-awareな続きは新Issueへ分ける。
- `paused`／`blocked:*`: 移行だけを理由に無断再開しない。所有者の明示判断と記録済み`resumeState`に従い、旧contractを保持して再開するか、履歴を残してsuccessorへ置き換える。
- `superseded`／`done`: immutable historyとして保持する。旧Issueを再利用せず、successor番号と理由をactive IssueのDependenciesへ記録する。

optionalな非公開機能をrelease全体のblockerへ昇格させません。successorへ置換した依存は旧Issueをcloseし直したり完了扱いせず、履歴として明記します。

#### Phase 5から6への証拠適用

Phase 6 `implementation`では、安定した候補Headに対して次の順で一度だけ適用判断を発行します。入力JSONはscratch fileであり、canonical成果物は`.artifacts/issues/<phase6-issue>/<phase6-head>/evidence-applicability.json`です。

```sh
tools/evaluate-evidence-applicability.sh \
  --issue "${PHASE6_ISSUE}" \
  --base-sha "${PHASE6_BASE_SHA}" \
  --head-sha "${PHASE6_HEAD_SHA}" \
  --input "${INPUT_JSON}"
```

入力はschema v1で、`sourceVerify`、`sourceContext`、`targetContext`、`impact`、`reason`、`evaluatedAt`だけを持ちます。各contextはcandidate artifact、configuration、SDK、signingのSHA-256とcanonical scopeを持ち、`impact`はPhase 5 source HeadからPhase 6 target Headまでのsorted changed pathをexactに一件ずつ覆います。各pathへ`unaffected`、`affected`、`unknown`、影響scope、現在Headでのdependency path／presence／digest、nonempty reasonを記録します。

同一Head、同一context、空diffなら`reuse`、Head／context／影響pathの変更なら`targeted-reverify`、unknown、missing dependency、scope拡張なら`expanded-verification`です。後二つは判定時刻より後のPhase 6 passed verificationが必要です。Phase 6 review packet、PR renderer、pre-merge gate、release/package preflightはrecordとPhase 5元証拠をdescriptor-boundで再検証し、別候補、古い承認、改ざん、未検証を拒否します。提出固有のpackage、privacy、legal、外部操作権限、provider readbackは毎回実行します。

source Headとtarget Headは同じGit系譜である必要はありません。source Base→source Headとtarget Base→target Headをそれぞれ検証し、squash merge等で分岐した両commit objectが参照可能ならactual source..target diffを封印します。Headが異なる候補はdiffが空でも`reuse`せず`targeted-reverify`とし、source objectを取得できない場合は停止します。release phase recordのblob検証はRelease-phase Claim gateが担当し、適用recordはcontract bindingに封印済みのpath／digest参照を引き継ぎます。

D-049のrelease-phase binding互換cutoff `2026-09-14T00:00:00Z`より前に封印されたPhase 5 source contractは、元bytesを変更せずlegacy sourceとして参照できます。この場合もPhase 6 target bindingがrelease／revision／scopeを固定し、recordは`sourceLegacy: true`と`sourceRecord: null`を明示して架空のPhase 5 recordを合成せず、元のpassed full verification、contract、Git identityを検証します。cutoff以後のPhase 5 sourceにはPhase 5 `implementation` bindingが必須です。Phase 6 bindingのない既存／legacy Issueは従来の直接`verify.json`経路を維持し、新recordを合成しません。

#### Release dispositionと停止後判断

D-050 cutover `2026-09-15T11:00:00Z`以後のPhase 5／6 `implementation`は、stable Headでrepository testsと必要な証拠適用判断を終えた後、review packetより前に一度だけrelease dispositionを発行します。

```sh
tools/record-release-disposition.sh \
  --issue "${ISSUE}" \
  --base-sha "${BASE_SHA}" \
  --head-sha "${HEAD_SHA}" \
  --input "${INPUT_JSON}"
```

inputのexact top-level fieldは`schemaVersion: 1`、`entries`、`executionDecisions`、`recordedAt`です。canonical成果物は`.artifacts/issues/${ISSUE}/${HEAD_SHA}/release-disposition.json`へno-replaceで発行されます。producerはcurrent Head／Base祖先関係、sealed contract、Base commitのphase record、同じHead directoryに存在するfailure attempt 1〜2を独立に読み、inputが参照しなかったfailure、存在しないfailure、digest差異を拒否します。cutover前のcontractへ成果物を合成しませんが、明示的に作られた正しいrecordは同じvalidatorで検証できます。

`entries`はID順かつ一意とし、次のtypeを混ぜずに使います。

- `accepted-defect`: `classification`、exact `low` severity、title／impact／workaround／fixCost、`approval`、`expiresAt`、`followUpIssue`、`reevaluationCondition`。approvalは`authority: user`、actor、同じrepositoryのGitHub Issue comment URL、同一Issue／Base／Head、`approvedAt`を持ちます。
- `deferred-defect`: classification／severity／title／impact／reason、follow-up Issue、resume condition。これはproduct defectのacceptではありません。critical／high／unknownまたは公開blocker分類はmerge／releaseを止めます。
- `omitted-test`: 実行しないtest path、reason、risk、follow-up Issue。passed testへ数えません。
- `unverified`: 未確認scope、reason、risk、follow-up Issue。verifiedへ数えません。

`executionDecisions`は同一Issue／Headの`repository-test-failure-attempt-N.json`をexact path／digestで一件ずつ参照し、ID、action、reason、actor／authority、follow-up Issueまたはnull、resume condition、failure後の`decidedAt`を持ちます。`shrink`は診断後に対象を狭める判断、`split`はuser authorityで別Issueへ分割する判断、`defer`はuser authorityで追跡Issueへ延期する判断、`wait`は追加ユーザー判断まで停止する状態です。`wait`はrelease readinessを通しません。failure／timeout／未実行testは、後で別のbounded実行が成功しても履歴上のpassedへ書き換えません。

review packetは`releaseDisposition`と`releaseDispositionFile`を対で封印し、各failure recordもdescriptor-bound closureへ含めます。packet producer、result validator／publisher、PR renderer、pre-merge、release preflightはrecordが列挙した参照だけを信用せず、同じIssue／Headのattempt 1／2を独立取得してexact coverageを再検証します。取得時に存在しなかった候補もabsence witnessとして保持し、処理中の追加を拒否します。approved reviewのlow findingだけから`accepted-defect`を作らず、`evidenceApplicability`だけから残件なしを推測しません。PR本文はaccepted／deferred／omitted／unverified／failed-timeoutとfollow-upを別々に表示し、pre-mergeとrelease preflightは期限、candidate identity、critical blocker、`wait`を再検証します。

D-050対象ではDelivery profileが通常ならreview省略可能な値でも`verify-passed -> approved-for-merge`の直接経路を使わず、正式な反対モデルreviewを経由します。これによってdispositionを持たないreview packetやpacket自体の省略をstate、PR renderer、pre-mergeの共通判定で拒否します。

## 3. Issue contract snapshot

cutover後にClaimする新規Issue本文にはDelivery stageとVerification scopeを別々に記載します。Feature formの既定は`shape / 120 minutes / standard / iphone-ja`です。UI変更の3 field `UI verification`はClaim前のlive guidanceに限ります。既存のAcceptance criteria全体でexactly oneの有効なroute宣言を持たせ、AC本文先頭を`UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`で開始し、適用事実をReasonの後へ、確定anchorを`Spec anchors`、選択前提をDependenciesへ記載します。Identity bootstrapと純非UIの`UI verification`はexact `Not applicable`だけとし、scope／非UI理由をGoal／In scope等と`not-applicable`宣言へ、関連product／spec anchorを`Spec anchors`へ分けます。新しいmutable contract fieldは追加しません。選択の正本は、Issue contractへ封印される`Spec anchors`が参照する確定仕様と追記型Decisionです。pre-D-030 legacy contractにはこの新規要件を補完しません。

workflow-only Issueは`harden + strict`とし、`Verification`／`Verification scope`を省略します。application、Xcode、asset、localization、Bundle設定、App Store metadata／signing／provider実装、TestFlight、external release operationを含む場合はこの分類を使えません。App Store関連で許可するのはexact allowlistのlocal guidance、非認証capture producer、直接regression testだけです。`release` stageは`type:release`の実アプリrelease candidateだけに予約します。

```markdown
## Delivery stage

- Stage: shape
- Time budget: 120 minutes
- Reason: 主要導線を実画面で確認できる状態にする。

## Verification scope

- Scope: iphone-ja
- Reason: 日本語iPhone 1条件で主要導線をSmoke確認する。
```

shapeのVerification JSONは`iphone-ja`のSmoke Test 1件とBuild／重要Unit Test mappingを持ち、visual checkを持ちません。hardenは`targeted`なcanonical case部分集合、releaseは固定4件と全visual checkを持ちます。Stage／Time budget／Reason、Scope／Reasonの順序、未知値、重複、矛盾を共通producerで拒否します。App Store操作は`release / strict / full`だけに許可します。

Claim済みで`deliveryStage`を持たない旧snapshotへfieldを補完せず、従来のprofile／scope gateを維持します。新規Issueのstage省略は拒否します。理由・scope・stageのClaim後変更もlive再照合で拒否します。

選択された実行モデルはClaim時にGitHub Issueを読み、共通producerで`.artifacts/issues/${issueNumber}/issue-contract.json`へ次のsanitized snapshotを保存します。Bootstrapも同じproducerを使い、canonical contractを手書きで生成・縮小しません。

`type:feature`、`type:docs`、`type:release`は同じ基本contract schemaを使い、`type:regression`だけ`Original PR`と`Reproduction steps`を追加必須にします。4種類のうちexact 1 labelが必要で、複数または未知のtypeはClaimとGateで拒否します。

```json
{
  "schemaVersion": 1,
  "issue": 42,
  "repository": "yuto1201/example-ios-app",
  "goal": "通知時刻を変更できるようにする",
  "specAnchors": ["specs/features/settings.md#notification-time"],
  "acceptanceCriteria": [
    {"id": "AC-1", "text": "UI-direction route: confirmed-direction reuse; Scope: 通知時刻設定行; Reason: リンク済み仕様が同じhierarchyとflowを確定済み。 Covered hierarchy/flow: settings list > notification-time row > time picker."},
    {"id": "AC-2", "text": "通知時刻を保存して日本語で表示できる"}
  ],
  "dependencies": [],
  "externalOperations": ["github.push_branch", "github.create_pr", "github.merge_pr"],
  "externalOperationDetailsDigest": "sha256:948c57dcd48bcede8fc5ad4707bd140ab260564f2c1960891e00959a4236c92c",
  "fetchedAt": "2026-09-06T00:31:41Z"
}
```

新規snapshotには、たとえば次を追加します。

```json
{
  "deliveryStage": {"name":"shape","timeBudgetMinutes":120,"reason":"主要導線を確認する。"},
  "deliveryProfile": {"name":"standard","reason":"通常UI変更。"},
  "verificationScope": {"name":"iphone-ja","reason":"代表的な日本語iPhone Smoke。"}
}
```

`externalOperations` は順序付きの操作ID配列です。`externalOperationDetailsDigest` はIssue本文の各五field blockを `operation`、`service`、`environment`、`executor`、`approvalRequired`、正規化したnullまたはstringの`approvalReference`へ変換し、同じ順序のcanonical JSONへ計算したSHA-256です。したがってIDが同じでもservice、environment、executor、承認条件または承認参照が変わればsnapshot bytesとdigestが変わります。

新規Issueは`Delivery profile`節へ`Profile`と`Reason`を記載し、snapshotへ次を追加します。

```json
{"deliveryProfile":{"name":"fast","reason":"Local non-UI logic covered by targeted tests."}}
```

`name`は`fast`、`standard`、`strict`だけを許可します。profile未導入の既存snapshotは`strict`です。`fast`はUI verificationが`Not applicable`で、追加承認やstrict対象operationがない場合だけ有効です。Supabase migration、Cloudflare deploy、メディア生成、App Store upload／metadata／submissionなどを低いprofileへ指定するとClaim前に拒否します。

検証、視覚評価、反対モデルレビュー、pre-merge gateは同じsnapshot pathとdigestを使用します。実行モデルがGitHubから取得して生成したsnapshotをローカル入力として読みます。Head SHAが変わってもIssue本文が変わらない限りsnapshotは再利用できます。Claimの再実行ではlive本文からの再生成bytesが既存契約と一致しなければ拒否し、古い契約・証拠を自動上書きしません。

application検証を実行するIssueは任意の`Verification`節へ、次の例のように完全なJSON objectを記載します。生のJSONまたは単一の`json` code fenceを使い、外側の`verification` wrapperは書きません。`tools/validate-issue-body.sh`とClaimが同じ`tools/lib/issue-contract.rb`で入力を検証し、canonical snapshotの`verification`へ格納します。Feature／Regression formにも入力欄があります。Configや環境変数から暗黙の既定値を補わず、このIssue本文だけを入力の正本とします。

許可するkeyは`bundleIdentifier`、`unitTestIdentifier`、scopeで定まるfixed 1件／targeted部分集合／fixed 4件の`cases`、受け入れ条件と同じ順の`acceptanceMappings`だけです。`shape`のcaseは操作を確認する`testIdentifier`を必須とします。各caseは`testIdentifier`またはexact `{"kind":"launch-succeeded"}`の一方だけを持ちます。

documentation-only Issueでは節を省略するか、`Not applicable`／GitHub空欄の`_No response_`にします。この場合、従来のsnapshot bytesに`verification`を追加しません。空のJSON、空節、部分設定を「省略」には読み替えません。`fast`へapplication Verificationを指定することも拒否します。application実行時のobject不在は、引き続きBuild前に失敗します。

`acceptanceMappings` は全 `AC-*` をexactに一度ずつ含め、各 `checks` は空でなく重複せず、次のcanonical順を守ります: `stage:build`、`stage:unit-tests`、4つの `case:<case-id>`、4つの `visual:<case-id>`。少なくとも1つのstageまたはcase checkが必要です。runnerは実行したstage/caseだけをdraftへ記録し、finalizeはAIが承認したvisual checkを加えたexact mappingをfinal evidenceへ記録します。未知または未実行の参照は許可しません。

````markdown
## Verification

```json
{
    "bundleIdentifier": "com.example.ExampleApp",
    "unitTestIdentifier": "ExampleAppTests/UnitSmokeTests/testUnit",
    "cases": [
      {"id": "iphone-en", "testIdentifier": "ExampleAppUITests/SmokeTests/testLaunch"},
      {"id": "iphone-ja", "assertion": {"kind": "launch-succeeded"}},
      {"id": "ipad-en", "testIdentifier": "ExampleAppUITests/SmokeTests/testLaunch"},
      {"id": "ipad-ja", "assertion": {"kind": "launch-succeeded"}}
    ],
    "acceptanceMappings": [
      {"id": "AC-1", "checks": ["stage:build", "stage:unit-tests", "case:iphone-en", "case:iphone-ja"]},
      {"id": "AC-2", "checks": ["case:ipad-en", "case:ipad-ja", "visual:iphone-en", "visual:iphone-ja", "visual:ipad-en", "visual:ipad-ja"]}
    ]
}
```
````

各ACのchecksは実際にそのACを確認するものだけを明示し、未指定のACへ全checkを自動割当しません。例のidentifierやmappingをそのまま根拠として使わず、実在TestとACへ置き換えます。Repository toolのACはapplication smokeだけでは証明できないため、§5.3のcanonical repository testとAC別mappingも必須です。application runnerが受け付けるUnit Testは単一の`unitTestIdentifier`だけです。複数の確認は一つの統合XCTestへ集約するか、下記の正式revisionでAcceptance criteria本文／mappingを直し、CLIや環境変数から複数identifierを差し込みません。

このobjectはIssue contractのdigestへ含まれます。runnerは開始時にbytesをdescriptor-boundなsealed snapshotへ固定し、各caseとScreenshot/draftのno-replace publication境界でGit Head、tracked Head inventory/bytes/flags、canonical contract/matrixのexact bytes/digestを再照合します。trusted Git `ls-tree`/`cat-file blob`からcontained relative symlinkを含むprivate raw-Head source snapshotを構築してXcodeへ渡し、project pathをlength-prefixしたfull source digestを`build.sourceTree`、project subtree digestを`build.project`としてdraft/finalへ固定し、両者のproject path exact一致を要求します。Build productはprivate attemptへ再帰copyしてlength-prefixしたtree digestを固定し、各install直前に再検証します。Task 5はcanonical draftからdescriptor-bound `visual-packet.json`をno-replace生成し、primaryと追加stateを含む全PNGを順序、path、SHA-256、dimensionへ固定します。`visual-result.json`とfinal `visualEvaluation`はpacket exact bytesと全reviewed imageをattestし、finalizeとstandalone validatorはcurrent bytesまで再照合します。Screenshot/draft publicationはIssue/Head lock下のdurable journalからSIGKILL後のpartial transactionをrollbackし、complete transactionをidempotent successとして回収します。finalもexact既存bytesだけをidempotent successとします。CLI引数や環境変数でBundle ID、test identifier、assertionを差し替えません。

### 3.1 Claim後の監査付きcontract revision

Claim済みIssueの本文を直接編集してcanonical contractとの差を放置しません。Issueがexact `in-progress`で、同じIssueの`github.read_issue`と`github.update_issue`がsealed contractに宣言されている場合だけ、`tools/revise-issue-verification.sh`を使います。許可fieldは`Verification`、既存と同一ID・同一順序のAcceptance criteria本文、更新時の`fetchedAt`だけです。ただしAC本文先頭の`UI-direction route:`はcriterion位置・route・Scope、`Repository-test scope:`はcriterion位置・scope、`Opposite-review route:`はcriterion位置・route／primary／reviewer／approval、`Release-phase binding:`はcriterion位置・宣言全文を固定し、追加・削除・移動・保護値変更を拒否します。Goal、MVP、Spec anchors、Dependencies、stage、profile、scope、type、external operation／approvalを変える提案は拒否し、意味的に別の目的・MVPとなる場合は別Issueと現在ユーザー判断へ戻します。

現在ユーザーが自分で改訂を明示する場合、まず候補本文からexact markerを生成します。

```bash
tools/revise-issue-verification.sh marker \
  --repo OWNER/REPO --issue ISSUE --body revised-body.md \
  --trigger user-explicit --reason 'exact reason'
```

設定済みGitHub ownerが、出力されたmarkerを変更せず同じIssueのcommentへ投稿します。AIへ委任する場合は`--trigger user-delegated --delegate codex|claude`で生成し、owner commentのmarkerへ現在executor、変更前contract digest、変更後body digest、source Head、変更scope、reasonを束縛します。owner以外、別Issue、古いcontract／Head、曖昧な文面、marker外の沈黙はauthorityになりません。

comment URLを得た後、同じ候補本文と引数で適用します。

```bash
tools/revise-issue-verification.sh apply \
  --repo OWNER/REPO --issue ISSUE --body revised-body.md \
  --trigger user-explicit --reason 'exact reason' \
  --authority-reference 'https://github.com/OWNER/REPO/issues/ISSUE#issuecomment-ID'
```

反対モデルのblocking findingに従う場合は、`changes-requested -> in-progress`を正規state transitionで記録した後、`--trigger review-finding`、exact `.artifacts/issues/ISSUE/HEAD/review.json#findings/INDEX`、そのfindingの`requiredChange`と完全一致する`--reason`を使います。このrouteは同一Issue／contract／source Headのcanonical resultとlauncher receiptだけを受理し、user markerやdelegateを使いません。

`apply`は改訂前後のbody／contract、改訂前後state、authority、reason、changed fields、前record digest、失効対象、維持identityを`.artifacts/issues/ISSUE/issue-contract-revisions/`へno-replaceで保存し、pendingを作成してからGitHub本文、canonical contract、durable stateを順に切り替えます。途中で停止した場合は、別requestを開始せずexact同一commandを再実行します。pendingは同じrevisionのbefore／after bytesにだけ復旧でき、通常のstate transition、resume、外部操作、review packet、pre-mergeはpending／broken chain／recordなし改変を拒否します。

改訂は古いverify／review artifactを削除しませんが、それらの現行性を失わせ、durable stateの`headSha`を外します。Base、Branch、worktree、改訂時source Headは維持・記録します。改訂後は新contract digestと新Headで対象検証、review packet、反対モデルreview、pre-mergeをやり直します。`tools/revise-issue-verification.sh validate --repo OWNER/REPO --issue ISSUE`でactive chainを確認できます。

## 4. 状態機械

```text
proposed
  -> approved
  -> claimed
  -> in-progress
  -> verify-passed
  -> approved-for-merge              # fast only
  -> review-requested
  -> changes-requested -> in-progress
  -> approved-for-merge
  -> merged
  -> done
```

### 許可された遷移

| From | To |
| --- | --- |
| `proposed` | `approved`, `blocked:user`, `superseded` |
| `approved` | `claimed`, `blocked:dependency`, `paused`, `superseded` |
| `claimed` | `in-progress`, `blocked:conflict`, `paused` |
| `in-progress` | `verify-passed`, 任意の`blocked:*`, `paused` |
| `verify-passed` | `review-requested`, `in-progress`, `blocked:review` |
| `verify-passed` | `approved-for-merge`（review不要のexplicit `fast`または非release `standard` shape／harden） |
| `review-requested` | `changes-requested`, `approved-for-merge`, `blocked:review` |
| `changes-requested` | `in-progress`, `blocked:user`, `paused` |
| `approved-for-merge` | `merged`, `in-progress`, `blocked:conflict`, `blocked:ops` |
| `merged` | `done` |
| 任意の`blocked:*` | 直前の非blocked状態、`paused`, `superseded` |
| `paused` | 停止前の状態、`superseded` |

`in-progress -> verify-passed` だけは、canonical Issue worktreeの現在値を明示する `tools/issue-state.sh transition ... --head-sha ${HEAD_SHA}` が必須です。遷移処理はdurable stateのBranch/worktreeとGit top-level/common directory、current Head、raw Branch refをGitHub mutation前、各remote step後、durable write直前に再照合し、一致したHeadを`state.json`へ保存します。Primary checkoutからHeadを推測しません。他の遷移で`--head-sha`は拒否します。

Head SHAが変わった場合、`verify-passed`、`changes-requested`、`approved-for-merge` から `in-progress` へ戻し、検証とレビューをやり直します。これらの遷移は古い`headSha`を削除し、次の`in-progress -> verify-passed`で明示した現在Headへ置き換えます。それ以降のforward遷移は同じ`headSha`を保持します。`done` と `superseded` は終端状態です。

各遷移commentには機械可読markerとして `from`、`to`、`resumeState`、executor、timestampを保存します。markerは `Config/ownership.yml` の個人GitHub loginが投稿したcommentだけを信頼し、comment author、marker timestamp、comment作成時刻、合法な遷移履歴を結び付けます。第三者または不正なmarkerを除外した最新の有効markerをtimestampで決定し、同時刻に複数の有効候補があれば推測せず失敗します。`blocked:*` または`paused`へ入るときの`resumeState`は遷移前状態です。復帰時は `issue-state.sh transition --from <current> --to <resumeState>` を明示実行してから `resume-issue.sh` でlocal stateを再構築します。`resume-issue.sh` 自体はlabelを変更しません。存在しない場合は推測せず`blocked:conflict`にします。ローカル`state.json`にも同じfieldsを保存し、失われた場合はGitHub commentから再構築します。

中断状態:

- `blocked:user`: 仕様または承認待ち
- `blocked:ops`: 外部認証、契約、API制限
- `blocked:review`: 反対モデルを利用できない
- `blocked:conflict`: 同一ファイルまたはBranchの競合
- `blocked:dependency`: 依存Issueが未完了
- `blocked:environment`: Xcode、Runtime、Simulator不足
- `blocked:repeated-failure`: 同一原因の2回連続失敗
- `paused`: ユーザーが明示的に停止
- `superseded`: 別Issueまたは決定に置き換えられた

状態はGitHub Issueのlabelとcommentを正本とします。ローカルの状態ファイルは再開を補助しますが、GitHubと矛盾する場合は実行モデルがGitHubを再確認します。

### Pending transitionの寿命と復旧

`state-transition.pending.json` は `.artifacts/issues/<Issue>/` に置く二相コミットの途中記録です。remote label変更より前に作成し、所有者markerの投稿とdurable `state.json` の書き込みが成功した後、観測済みの同一ファイルだけを削除します。削除失敗を成功として返しません。途中で停止した場合はpendingを残し、次の実行が同じ遷移を再開できます。

次の異なる遷移を要求した時にpendingが残っていれば、実行モデルのaccount／Issue操作権限を再確認してlive Issueを読み、pendingのexact schema・canonical bytes・Issue／repository／executor・遷移・時刻・Headと、durable identity／遷移履歴、現在のlabel、最新の有効な所有者markerを照合します。すべて一致する**適用済み**記録だけを回収して要求された遷移へ進みます。これは検証・reviewの免除やstateの強制変更ではありません。未適用、履歴欠落、矛盾、別identity、symlink／hardlink、途中で差し替わったfile／directoryは回収しません。

未完了のpendingが残る場合は、出力されたエラーとGitHubの状態を確認し、pendingに記録された元の `from`／`to` で同じコマンドを再実行します。例えば `verify-passed -> review-requested` が中断した場合:

```sh
tools/issue-state.sh transition --repo OWNER/REPO --issue NUMBER \
  --from verify-passed --to review-requested
```

元の遷移が `in-progress -> verify-passed` の場合は、同じcanonical Issue worktreeからpendingと一致する `--head-sha` が必要です。別Headの証拠へ読み替えません。適用済みであることを確証できない記録を手作業で消す、`state.json`を編集する、labelを直接付け替える方法は使いません。復旧できない場合はpendingとエラーを保持し、欠けたidentityや履歴を正規手順で確認します。終了コードとstderrを確認し、出力を捨てて成功と報告しないでください。

## 5. Issue実行フロー

### 5.1 Claim

この手順でcutover後に新しく封印するcontractは完全なroute宣言をexactly one必須とします。すでに封印済みのcontractを再開する場合は先に`fetchedAt`で互換判定し、cutoverより前かつAcceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補がゼロのpre-D-030 legacyならcontractを変更・再封印せず、元のscope／AC／spec／evidenceで再開します。cutover前でも候補が一つ以上あるcontractは通常のroute validationへ進め、malformed、unknown、multipleをrejectします。

1. 実行モデルがIssue読取の直前に設定済みGitHubアカウントとRepositoryを確認し、live Issue contractの`github.read_issue`宣言を検証する。
2. live IssueのGoal、Scope、Acceptance criteria、Dependencies、`UI verification`を読む。現在の明示的なHTML比較を最優先とし、明示省略は現行性、exact scope、権限、理由と比較指示との非矛盾が明確な場合だけ`explicit-skip`とする。明示overrideがなければ、exact hierarchy／flowを覆う確定方向は`confirmed-direction reuse`、対象方向が未確定で最初のユーザー向けUI、ルートnavigation／information hierarchyの新設・変更、主要flowの大幅な再設計のいずれかは`comparison`、方向未確定かつ3 triggerなしでAcceptance criteriaが方向を決めない場合だけ`bounded direction-neutral`とする。Identity bootstrap／純非UIは`not-applicable`とし、曖昧なUI分類はGateへfail closedする。
3. UI Issueのlive `UI verification`がexact 3 field、Identity bootstrap／純非UIがexact `Not applicable`であることを確認する。さらに既存Acceptance criteria全体でexactly oneの有効な宣言があり、AC本文の先頭をexact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`で開始し、許可済みroute、非空Scope／Reason、Reason後の適用事実を満たすこと、`Spec anchors`が確定anchorを、Dependenciesが必要な選択前提を持つことを確認する。prefix外のroute語は数えない。`comparison`のexact selection記録が確定仕様と追記型Decisionへmergeされていない場合を含め、live guidanceと封印対象fieldの両方がDefinition of Readyを満たさなければcutover後の新規contractを作成しない。
4. 通常のshippingに必要な`github.read_issue`、`github.update_issue`、`github.push_branch`、`github.create_pr`、`github.merge_pr`、`github.delete_branch`がすべてlive Issue contractへ宣言されていることを確認し、`issue-contract.json` を作成してdigestを記録する。
5. Primary agentをIssueへ記録する。
6. Branch、worktree、共有artifact link、sealed contract、durable stateを順に作成してからremoteの`claimed` labelと所有者markerを公開する。各境界はjournalで再開可能にし、同じagentとexact contractだけが続行できる。

CodexとClaudeは同じ手順で1、4、5、6とGitHub上の状態変更を実行します。

### 5.2 Implement

1. 受け入れ条件に対応する失敗テストを作る。
2. 失敗を確認する。
3. 最小の実装を行う。
4. Unit Testを成功させる。
5. 小さな意味単位でcommitする。
6. Scope外の必要作業を発見したら、勝手に含めず追跡Issue候補へ記録する。

開発中は対象Test、関連回帰Test、stage標準検証の順で広げます。対象test 1 commandは300秒で停止し、通常完了用の`targeted` repository suiteはaggregate 900秒を超えて実行しません。shapeのTime budgetを超えそうならScope縮小、harden分離、環境停止、または`blocked:user`を選び、品質項目を積み増しません。release完全検証は候補Headが安定してから一度実行します。

UI Direction Gateを通したshapeでは、確定仕様にある情報階層、主要task、navigation、代表state、accessibility意図をnative SwiftUIへ翻訳します。HTMLをWKWebViewで製品化したり、CSSのpixel一致を実装条件にしたりしません。

### 5.3 Verify

1. 非UI`fast`は`verify-fast-issue.sh`でBuildと指定Unit Testだけを実行する。
2. `shape`はBuild、重要Unit Test、`iphone-ja` 1条件のSmoke Testを実行し、Screenshot／visual reviewなしの`xcodebuild-stage`証拠を発行する。
3. `harden`は対象Test、関連回帰、宣言した`targeted` caseだけを実行する。visual checkを明示した場合だけ対象画像を評価する。
4. `release`は`full` 4条件、visual、accessibility、統合UI、同一Head evidenceを実行する。
5. IssueがRepository toolやworkflowを変更する場合、canonical repository testsをclean detached worktree上で実行する。D-037 cutover後のworkflow-only contractは要求scopeを宣言し、実装後のimmutable Base..Head差分とHead manifestからexact planを生成する。`targeted`は既知の単一または複数domainに属する関連testのunion、未知pathは実行前停止、`head-all`／`base-and-head`はrelease／明示要求だけにする。manifest、runner、tracked test変更から全件へ自動昇格しない。cutover前contractの既存Head-only／Base-and-Head経路は変更しない。
6. 同じHeadを明示して`in-progress -> verify-passed`へ遷移する。

canonical検証が失敗した場合、同一Issue／Head／scopeの直接再実行を拒否します。選択済みの対象Testが成功した記録を伴う場合だけ1回再試行し、再失敗後は停止します。別Headのcanonical evidenceを作り続けることを進捗として扱いません。

HTML、HTML screenshot、revision IDまたはHTML digestはnative検証の代用にしません。gateを通したUIは、選択を記録した確定spec anchorとcurrent-HeadのSwiftUI、Build、Test、stage別Simulator evidenceの対応で確認します。

### 5.4 Opposite-model review

- `fast`および`standard`の`shape`／`harden`: blocking reviewを行わず、`verify-passed -> approved-for-merge`へ進む
- Codex実装: Claudeへread-onlyレビューを依頼
- Claude実装: Codexへread-onlyレビューを依頼

上記が既定pairです。Claudeが利用不能で、sealed contract内の一つのAC本文先頭がexact `Opposite-review route: grok-fallback; Primary: codex; Reviewer: cursor-grok-4.6-xhigh; Approval: user-explicit; Reason: <nonempty>`の場合だけ、Codex実装をexact Grokへ固定launcherから依頼します。この宣言はIssue単位であり、別Issue、別primary、別model、旧contractへ継承しません。宣言なし／不完全／重複時の自動fallbackと自己承認は禁止です。

`strict`または`release`のレビュー対象はIssue、仕様、Base SHA、Head SHA、Verify SHA、diff、テスト結果、要求画像です。レビュー結果が`changes-requested`なら対象確認からやり直します。

レビューのタイムアウトは10分です。Grok routeはCursor `ask` mode、非対話、read-only指示、閉じたstdin、sanitized環境を使います。reviewer利用不能、nonzero exit、timeout、空／不正JSON、schema／evidence不一致、repository／artifact write検出はcanonical review／receiptを発行せず`blocked:review`とし、独立Issueを進めます。自己承認はしません。

固定launcherはchild完了後にcanonical `review.json` と `review-receipt.json` をdescriptor-boundで対として発行します。receiptはprimary/opposite model、fixed launcher bytes、exact packet/result/review digest、開始/完了時刻、exit statusを固定します。既存reviewだけ、偽造または不一致receipt、自己承認は再利用しません。review publication後のstate transitionだけが失敗した場合は、exact review/receipt pairを検証した再実行だけがreviewerを再起動せず遷移を再開できます。

### 5.5 PR and merge

1. Issueで指定された実行モデルが設定済みGitHubアカウントを再確認する。
2. durable stateのrepository、Issue、Branch、worktree、Base、Head、contract digestと、callerの `--repo`、現在のGit branch/ref/Head/Base/clean状態を一致させる。
3. `tools/premerge-gate.sh --repo ${OWNER_REPO} --issue ${ISSUE_NUMBER} --head-sha ${HEAD_SHA}` を初回実行する。
4. approvedな固定snapshotからPR本文をrenderする。`changes-requested` は本文を生成せず拒否する。
5. exact HeadをBranchへPushし、PRを作成または既存OPEN PRを再確認して、正確なPR番号をdurable stateへ保存する。
6. `github.merge_pr` のaccount preflightを現在のIssue/Headに対して更新する。
7. `tools/premerge-gate.sh --repo ${OWNER_REPO} --issue ${ISSUE_NUMBER} --head-sha ${HEAD_SHA} --merge-pr ${PR_NUMBER}` を実行する。このfinal modeが全descriptor/lockを保持したままPR identityを再取得し、exact `gh pr merge --squash --match-head-commit` まで一続きで実行する。
8. Gate外でPR identityを再取得してmergeする経路は使わない。
9. PRのマージ状態とIssueのCloseを確認する。
10. remote Branch、worktree、local Branchの順に対象を再確認して後片付けする。

`gh pr merge --delete-branch` に後片付け全体を任せません。各対象を明示して、別worktreeやユーザーBranchを削除しないようにします。

認証済みmutationはIssue contractに同じoperation IDと実行モデルの`Executor`が宣言されている場合だけ実行します。Gateとmergeには`github.merge_pr`、Push直前には`github.push_branch`、新しいPRを作る経路だけ`github.create_pr`、remote Branch削除直前には`github.delete_branch`が必要です。新規PR経路では`github.create_pr`の欠落をPushより前にも検査し、必要宣言が一つでも欠ける場合は外部mutationをゼロのまま拒否します。既存の正確なPRを再利用する経路は`github.create_pr`を要求しません。

Squash Merge後は元Branch tipが`main`の祖先にならないため、`git branch --merged` を完了判定に使いません。実行モデルは対象PRの`state == MERGED`、`headRefOid`が記録済みHead SHAと一致すること、`mergeCommit`が存在することをGitHubから確認します。必要に応じてpatch-idでSquash commitとの差分同等性も確認します。

## 6. PR本文の必須項目

```markdown
Closes #42

## Summary
- 設定画面に通知時刻の選択を追加

## Specification
- specs/features/settings.md §3

## Verification
- Head SHA: 0123456789abcdef0123456789abcdef01234567
- Unit tests: 24 passed
- UI matrix: iPhone Pro en/ja, iPad Air en/ja passed
- Evidence digest: 9f42c7...

## Opposite-model review
- Reviewer: Claude
- Reviewed SHA: 0123456789abcdef0123456789abcdef01234567
- Verdict: approved

## Remaining work
- None for this Issue
```

PR本文の要約が永続的な証拠です。巨大なBuild logや秘密を貼りません。

上の例はfull検証です。`iphone-ja`のrendererは日本語iPhoneだけを確認済みとし、英語・iPadを`deferred / unverified`として表示します。`None for this Issue`をアプリ全体の完成と解釈しません。出力や証拠を手で縮小せず、共通producerを使用します。

## 7. 再試行とRegression

- Pre-mergeで見つかった問題: 元Issueで修正
- Merge後または実機確認で見つかった問題: Regression Issue
- 同じ障害を重複起票しない
- Regression IssueからさらにRegression Issueを自動連鎖させない
- 同じ原因の失敗が2回続いたら状態をblockedへ移す

## 8. 止まらず進める範囲

一つのIssueがblockedでも、依存しないIssueは継続します。次の場合だけバッチ全体を止めます。

- 共通仕様の未決が全Issueへ影響する
- 個人GitHubアカウントを確認できない
- Base Branchの状態が壊れている
- Xcodeまたは必要Runtimeがなく全Issueを検証できない
- ユーザーが明示的に停止した

ソース編集Issueは、依存がなく編集ファイルが重ならない場合に最大2件まで並行化できます。AI Simulatorは一つのsessionにつき原則1台、同じMac全体でiPhone／iPad合計最大4台です。一つのsession内の複数caseは逐次実行します。runnerとApp Store撮影はrepository排他lockの内側でMac共通resource managerを使い、旧経路を共通上限対応済みと推測しません。

## 9. Bootstrap

Foundation、Identity bootstrap、Simulator verificationの3件は、Issue自動化が未実装の段階を含むため選択された実行モデルが同じ手順を手動実行します。手動であってもIssue、Branch、PR、要求scopeのSimulator、反対モデルレビュー、Head SHA照合、Squash Merge、Branch削除を省略しません。Identity bootstrapはFoundationの後、Feature実装より前に完了します。4条件を実行する場合も、同一sessionでは一条件ずつ作成・検証・証拠保存・削除します。

Bootstrap IssueのPRには、各受け入れ条件IDと証拠、GitHub account preflightのsanitized要約、Verify対象SHA、Review対象SHAを記載します。Simulator verificationが入った後は`verify.json`を使用し、Security and workflowが入った後は全Issueを自動状態機械へ移行します。

### 9.1 手動Squash Merge後のPR記録とcleanup

Bootstrap例外は自動化tool自体がまだ使用できない場合に限ります。通常の`merge-issue.sh`やpremergeを迂回する理由にはしません。手動経路でも先に受け入れ条件、現在Headの要求検証、必要な反対モデル承認を揃え、PR本文へ証拠を記載します。

必須の順序は次のとおりです。

1. canonical Issue worktreeでBranch、Base、Head、sealed contractを確認し、指定Executorが許可されたGitHub accountでexact PRを作成・確認する。
2. 必要な手動検証・レビューを完了し、正規の状態遷移で`approved-for-merge`へ進める。PRのrepository、main向けBase、Branch、Head、唯一のclosing Issueを照合して、同じHeadを`--squash --match-head-commit`でマージする。
3. exact PRが`MERGED`、`mergeCommit`あり、Issueが`CLOSED`であることをreadbackし、`issue-state.sh transition --repo OWNER/REPO --issue NUMBER --from approved-for-merge --to merged`でmerged履歴を記録する。成功不明のマージを再実行しない。
4. durable stateの`pullRequest`が欠けている場合、元のexact-Head worktreeから[record-merged-pr.sh](../tools/record-merged-pr.sh)を実行する。

   ```sh
   tools/record-merged-pr.sh --repo "$REPO" --issue "$ISSUE" \
     --pull-request "$PR_NUMBER" --expected-head "$HEAD_SHA"
   ```

5. 記録成功後、primary checkoutの`tools/cleanup-issue.sh --repo "$REPO" --issue "$ISSUE"`を実行し、正規の`merged -> done`遷移とPR／Issue／Branch／worktreeの独立した完了確認を行う。

復旧コマンドは既にmergedのdurable identityだけを対象にし、account／read権限、live Issueの指定Executor、所有者のmerged履歴、PR番号・URL・repository・Branch・Head・closing Issueを再取得・検証します。既存の異なるPRを上書きせず、書き込む値は欠けている`pullRequest`だけです。同じPRで再開する場合もremoteを再確認します。新規マージ、PR作成、状態遷移、Branch削除、検証・レビューの免除は行いません。

不一致・未取得・timeoutでは停止し、durable stateを手編集したりcleanupの削除部分を手動転記したりしません。すでにPRが記録された通常経路は従来どおり`merge-issue.sh`／`cleanup-issue.sh`で再開します。
