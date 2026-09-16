# 動く形から品質を固める段階的開発

Status: 確定
Version: 3.6
Date: 2026-09-15

## 1. 原則

開発順序は、必要な場合に比較案からUI方向を確定する、操作可能な形を作る、実画面で方向性を再確認する、問題別に品質を固める、リリース候補を完全検証する、の順とする。この順序を§1.5のリリース単位の6フェーズへ配置し、最終品質は下げず、高コストな横断検証を変更が収束した後へ移す。

Delivery stageはIssue type、workflow state、危険度を表すDelivery profileとは別の一項目である。新規Issueは`shape`、`harden`、`release`のいずれか、正のTime budget、理由を持つ。

### 1.1 適用判定

現在のユーザー指示が対象範囲のHTML比較を明示的に求めた場合は、確定済み方向の有無にかかわらず最優先でUI Direction Gateを実行する。現在の指示が代わりに比較省略を明示した場合は、その指示の対象scope、現行性、権限が明確で、現在の比較指示と矛盾しないときだけ通常判定を上書きできる。cutover後のClaim前に、一つのAcceptance criterion本文の先頭（`AC-*:`の直後）を`UI-direction route: explicit-skip; Scope: <nonempty>; Reason: <nonempty>`で開始し、Reasonの後に指示の現行性、権限、比較指示との非矛盾を明記して、関連する確定済みproduct／spec／Decision anchorを`Spec anchors`へ記録する。いずれかが曖昧または矛盾する場合、依存するUI作業を`blocked:user`にする。

上記の明示指示がない通常判定では、まず確定済みUI方向／specが予定する変更のexact hierarchyとflowを覆うか確認する。覆う場合は作業名が構造変更でもconfirmed-direction reuse routeとし、cutover後のClaim前に一つのAcceptance criterion本文を`UI-direction route: confirmed-direction reuse; Scope: <nonempty>; Reason: <nonempty>`で開始する。覆われるhierarchy／flowはReasonの後へ明記し、再利用する確定済みUI方向anchorを`Spec anchors`へ記録する。

exact scopeを覆う確定方向がなく、予定する変更の**対象範囲のUI方向が確定しておらず**、かつ次のいずれかを行うときにGateを必須とする。

- 新しいアプリで最初のユーザー向けUIを作る。
- 最上位navigationまたはinformation hierarchyを新設・変更する。
- 主要flowの構造またはinteractionを大幅に再設計する。

上の必須条件を一つでも満たす場合、IssueがRegression、標準的なform、accessibility修正などに分類されていてもGateを省略しない。Issue typeや作業名ではなく、実際に変える階層・flow・interactionで判定する。

対象方向が未確定でも上の構造triggerを一つも満たさない場合は、Acceptance criteriaがhierarchy、navigation、primary-flow interactionを決めないときだけbounded direction-neutral UI routeを許可する。cutover後のClaim前に一つのAcceptance criterion本文を`UI-direction route: bounded direction-neutral; Scope: <nonempty>; Reason: <nonempty>`で開始する。この非決定境界はReasonの後へ明記し、関連する確定済みproduct／behavior spec anchorを`Spec anchors`へ記録する。受け入れ条件がいずれかの方向を決める場合はGateを実行する。

cutover後にClaimするIdentity bootstrapと純粋な非UI作業はnot-applicable routeであり、UI方向anchorを必要としない。Issueの`UI verification`本文はexact `Not applicable`だけとし、対象scopeと非UIである理由をGoal／In scope等の既存scope節へ記載し、一つのAcceptance criterion本文を`UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`で開始して、関連する確定済みproduct／spec anchorを`Spec anchors`へ記録する。Gateを評価するのは、それらに続いて方向選択へ依存するnative UI作業である。

`UI verification`はClaim前に参照できるlive guidanceだがIssue contractへ封印されない。UI Issueでは既存の3 fieldをexactな順序で保ち、`comparison`、`explicit-skip`、`confirmed-direction reuse`、`bounded direction-neutral`のrouteを補助的に示してよいが、最終レビューの根拠をこの節だけに置かない。cutover後にClaimするcontractは、既存のAcceptance criteria全体でexactly oneの有効なroute宣言を持つ。宣言は一つのAcceptance criterion本文の先頭（`AC-*:`の直後）にexact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`で置き、`<route>`は`comparison`、`explicit-skip`、`confirmed-direction reuse`、`bounded direction-neutral`、`not-applicable`のいずれかだけを使う。route固有の適用事実はReasonの後へ続けてよい。別の位置に現れるroute名や全routeを説明する文など、prefixに一致しない偶発的な語は宣言として数えない。`Spec anchors`と必要なDependenciesを揃え、review packetだけから宣言と根拠を復元可能にする。`comparison`では単一案のselected concept IDまたはhybridのexhaustive mappingが到達可能な確定spec／Decisionと、完了済みの選択前提を記録する。新しいIssue fieldは追加しない。

D-030のcutoverは`2026-09-06T00:31:41Z`（置き換え後のIssue #47の`createdAt`）とする。封印済みIssue contractの`fetchedAt`をUTC instantとして比較し、cutoverより前かつAcceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補がゼロの場合だけpre-D-030 legacyとして扱う。そのcontractへrouteを推測・追記・再封印せず、遡及的なHTML比較も要求せず、元の封印済みAcceptance criteria、spec anchors、Dependenciesと証拠をそのまま検証する。cutoverより前でも候補が一つ以上あれば通常のroute規則へ進み、候補がexactly oneで完全な`UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`宣言になっているかを検証する。候補の複数、許可外route、空のScope／Reasonはrejectする。`fetchedAt`がcutoverと同時刻または後にも同じexactly-one／完全性を要求し、候補ゼロもrejectする。cutover後のpre-Claim workflowは必ず完全な宣言を作ってからClaimする。Issue番号、Issue更新時刻、file mtime、live `UI verification`、またはprefix外の偶発的なroute語からcutoverやlegacy状態を推測しない。

方向のcoverage、trigger該当性、direction-neutral境界が曖昧な場合は自動で省略したり質問待ちにしたりせず、Gateを実行する側へfail closedする。明示的な省略指示の対象scope、現行性、権限、理由またはspec anchorが曖昧な場合や、比較実行と省略を同時に求めるなど現在の指示が矛盾する場合だけ、依存するUI作業を`blocked:user`にして確認する。

Gateが止めるのは方向選択に依存するUI作業だけである。Identity bootstrapと、選択結果に依存しない仕様化・domain・data・その他の非UI作業は進めてよい。

### 1.2 確定brief

比較案を作る前に、アプリ固有の確定仕様とユーザー指示から一つのrequirements briefを作る。briefは少なくとも次を固定する。

- プロダクトの目的、対象ユーザー、ユーザーが完了したいtask。
- primary flow、対象screen、開始・成功・空・読み込み・失敗など必要なstate。
- 表示するcontent、合成data、主要actionと優先順位。
- iOS／端末／言語／accessibility上の制約、技術・法務・privacy上の制約。
- 今回のnon-goalと参照する確定spec anchor。

比較により決めるUI構造以外に、受け入れ条件を変える不確定事項を残さない。briefの差が受け入れ条件を変える場合は案を作る前に`blocked:user`とし、ユーザーが仕様を確定してから再開する。

### 1.3 HTML比較revision

一つの確定briefから、同じtask、viewport、content、合成data、state集合を使う2–3案を、一つのself-contained HTMLへ同じfidelityで収録する。各案は安定したconcept IDを持ち、information hierarchy、navigationまたはinteraction hypothesisの少なくとも一つが実質的に異ならなければならない。色、角丸、影、余白だけを変えた案は比較案として扱わない。

各案には、hypothesis、trade-off、想定するnative iOSへの翻訳、accessibility上の考慮、およびstatic prototypeでは確認できない事項を併記する。比較には合成dataだけを使い、credential、秘密、個人情報、本番data、tracking、remote script／font／image／asset、`fetch`／XHR／WebSocket、送信先を持つform、`iframe`／`object`／`embed`、CSS import／remote URLなどのnetwork依存を含めない。

提示するHTMLは次のrevision pathへ保存し、提示したbytesのexact SHA-256を算出する。

```text
.artifacts/ui-direction/<flow-slug>/<revision>/comparison.html
```

提示済みrevisionを上書きしない。brief、案、注記またはHTML bytesが変わった場合は新しいrevisionとdigestを作り、変更後の比較に対する選択を改めて得る。

### 1.4 明示選択とnative実装への引き渡し

承認として受理できるのは、ユーザーが一つのconcept IDを明示するか、採用する全要素をそれぞれsource concept IDへ対応付けたexhaustiveなhybridを明示した場合だけである。hybridにselected／base concept IDを要求するのは、ユーザーがそのbaseを明示選択した場合だけとする。好意的な感想、順位、沈黙、「A寄り」などの曖昧な表現を選択として扱わない。hybridの対応が曖昧または非網羅の場合は確認するか、組み合わせた新しい比較revisionを提示して明示選択を得る。

選択後は共通して、対象scope、comparison path／revision、提示bytesのexact SHA-256、採用・不採用の要素、影響するscreen／state、native実装で許容する適応を、アプリ固有の確定specと追記型Decisionへ記録する。単一案なら選択したconcept IDを記録する。hybridなら採用する全要素からsource concept IDへのexhaustive mappingを記録し、ユーザーがbaseを明示選択した場合だけselected／base concept IDも記録する。既存方向を変える場合は過去のDecisionを書き換えず、新しいDecisionで置き換えを記録する。

選択待ちは`blocked:user`とする。選択後、この記録は専用Issue、Branch、PRでマージする。記録PRが未マージなら依存するUI Issueは`blocked:dependency`であり、`approved`への移行、Claim、`in-progress`への移行を禁止する。選択前に依存Issueを下書きすることはできるが、実装開始の根拠にはできない。

HTML、screenshot、concept IDは判断補助であり、製品仕様、pixel仕様、SwiftUI source、またはcanonical iOS検証証拠ではない。SwiftUI実装は選択されたinformation hierarchy、flow、state intentをnative component、Safe Area、可変layout、Dynamic Type、VoiceOver、keyboard、navigation／sheet semanticsへ翻訳し、HTMLを`WKWebView`で組み込んだりCSS pixelを転記したりしない。動作と表示の完了は、引き続き現在HeadのBuild、Test、SimulatorおよびDelivery stageに応じたnative証拠で判断する。

## 1.5 リリース単位の6開発フェーズ

開発フェーズはアプリ全体へ一度だけ適用する工程ではなく、MVPまたは「この能力を利用可能にして公開する」という一つのリリース目標ごとに適用する。各リリース単位は、安定した識別子、目的、対象利用者、成功条件、対象／対象外、現在revision、現在phase、依存Issue、ユーザー承認、証拠参照、未解決事項と繰越先を追跡する。

Phaseはリリース目標の進捗を表す。個々のIssueに付けるDelivery stage、危険度を表すDelivery profile、端末・言語のVerification scope、GitHub workflow stateとは別軸である。同じPhase内に複数の`shape`／`harden` Issueを持て、Phase 5〜6の実候補を扱う`type:release` Issueは両Phaseをまたいでよい。Phase番号だけからIssueの検証範囲やrelease readinessを推測しない。

### 1.5.1 Phaseの入口・作業・出口

| Phase | 入口 | 作業と成果物 | 出口 |
| --- | --- | --- | --- |
| 1 目的・リリース仕様 | リリース候補となる課題または到達目標がある | 対象利用者、課題、MVP／成功条件、対象／対象外、主要導線、データ方針、収益化・外部連携の採否、安全・法務上の制約、未決事項、依存／候補Issueを一つのrelease briefへ記録する。5つのsystem experience候補を`adopt-now`、`defer`、`not-applicable`、`blocked:user`へ仮分類する | 受け入れ条件を変える未決事項がなく、ユーザーが対象scope、目標revision、system experienceの評価方針を明示承認する |
| 2 基盤・UI方向 | Phase 1が完了し、承認済みrelease briefを参照できる | Identity bootstrap後、専用System Experiences Planning Issueで5面の採否と共有action／data／process／capability境界を確定する。App Iconは同時に進められる。`adopt-now`面の設計・依存Issueを整え、対象system UIを含むUI Direction Gate対象は同一briefのHTML 2〜3案から方向を確定し、仕様とDecisionを先にmergeする | 必要な基盤と依存が完了し、5面の判断、対象UIのroute、確定anchor、未実装範囲が明示される。計画だけでframeworkやentitlementを導入せず、HTML選択だけをnative検証済みとは扱わない |
| 3 日本語iPhone開発 | Phase 2が完了し、日本語iPhoneで実装するIssueがDefinition of Readyを満たす | 小さなIssue単位で主要機能を実装し、Build、重要Unit Test、日本語iPhoneの主要導線Smokeを行う。安定した文字列key、可変layout、iPad target、既存英語resourceを壊さず、英語／iPadの完成作業はPhase 4へ残せる | AIが主要タスク、現在Headの実行証拠、既知不具合、未検証、繰越を提示し、ユーザーが対象release revisionのPhase 3完了を明示判断する |
| 4 英語・iPad対応 | Phase 3についてユーザーの完了判断が記録されている | 英訳、locale／日付／数値、iPadのlayout／navigation、対象範囲のaccessibility適応を独立したIssueで仕上げる。Phase 3の機能追加と混ぜず、必要な対象Testとcaseだけを実行する | 承認済みscopeの英語・iPad対応と残件が揃い、ユーザーが品質確認へ進むrevisionを明示判断する |
| 5 品質保証 | Phase 4が完了し、評価する候補artifact、source Head、config、対象scopeを同定できる | 日本語／英語×iPhone／iPad、回帰、Light／Dark、Dynamic Type、VoiceOver、44pt、目視、主要性能、保存復旧、個人情報、反対モデルreviewを適用可能な範囲で実行する。時間を区切り、既知不具合、テスト省略、未検証を別々に分類する | 必須公開blockerがなく、失敗・省略・未検証が可視化され、非blocking残件と回避策をユーザーが対象releaseについて承認する |
| 6 リリース | Phase 5の承認済み候補と、提出／公開の対象・権限・必要な明示承認が揃う | artifactとsource／config／SDK／signingの対応、提出固有の検証、素材、metadata、privacy／法務、公開操作を確認する。同じ候補へ適用可能なPhase 5証拠は再実行せず参照する | 許可された提出／公開操作の実応答をreadbackし、成功、部分成功、失敗、未実行と次releaseへの繰越を記録する |

前Phaseが未完了なら、その成果に依存する次Phaseの実装を開始しない。ただしread-only調査、選択肢整理、Issue草案、依存しない作業は先行できる。先行結果は完了証拠や承認として扱わず、依存が満たされた時点で現行revisionへ再照合する。Phase 4はPhase 3の一部ではなく独立した仕上げPhaseであり、英語／iPad実装はPhase 3完了判断より前に先取りしない。

### 1.5.2 ユーザー判断と委任

最終決定権は常にユーザーにある。ユーザー承認を必須とするのは、少なくともPhase 1、3、4、5の出口、公開範囲、目的・MVP・主要flow・採用system・重大riskを変えるrevisionである。承認はrelease identifier、revision、scope、判断内容、時刻へ束縛し、沈黙や別revisionへの承認を転用しない。

AIは承認済みscope内で、文言の微修正、余白、同一flow内の小さな操作改善、内部実装、対象Testの選定、狭い不具合修正、Issue分割を判断できる。判断根拠と結果はhandoffへ残す。外部公開、法務、課金、破壊的変更、契約で別承認を要求する操作を委任と推測しない。

### 1.5.3 アジャイル修正と部分再gate

Phase 1〜3の軽微な修正は、目的、MVP境界、主要hierarchy／flow、採用system、data互換性、重大riskを変えず、既存Acceptance criteria内に収まる場合に同じPhaseで継続できる。例として、承認済み文言の明確化、余白調整、同じ保存契約内の内部refactor、既存主要導線の局所的なcrash修正は全面的なPhase巻き戻しを要求しない。

目的、対象利用者、MVPの追加／削除、主要navigation／information hierarchy、primary flow、永続化形式、認証／課金／外部systemの採否、privacy／法務、安全上の重大riskが変わる場合はmajor changeである。変更前後と影響範囲を記録し、影響する最も早いPhaseだけをreopenedとしてユーザー判断へ戻す。影響しないPhase／Issueは停止しない。

具体例として、Phase 3でラベル文言だけを直す場合はPhase 3内で継続する。必須onboardingを追加する場合はPhase 1のMVP範囲とPhase 2のUI方向を再承認し、依存するPhase 3実装だけを戻す。Phase 5で保存不具合を発見した場合は狭い実装／harden Issueへ戻り、修正で失効した証拠だけを再取得してPhase 5を再開する。全Phaseを機械的に未完了へ戻さない。

### 1.5.4 Revision、証拠、不具合

release revisionを変える記録は追記型とし、少なくとも変更前、変更後、理由、判断者または委任根拠、影響する仕様／Issue／Phase、失効する証拠、再利用する証拠と根拠、繰越、記録時刻を持つ。過去のDecisionとsealed Issue contractを上書きしない。同一Issue contractの改訂は[受け入れ条件 §3.5](acceptance.md#35-claim後のissue-contract-revision)の専用経路に限定し、release revisionやPhase承認の代替にしない。

同一Issue contract revisionは`verification`、同一ID・同一順序のAcceptance criteria本文、`fetchedAt`だけを変更でき、現行contract／source Headに束縛した`review-finding`、設定済みownerの`user-explicit`、同ownerが現在executorを指定する`user-delegated`のいずれかを必要とする。旧／新body、旧／新contract、state、authority、前record digestをimmutable chainへ残し、以前のverification／review／Head bindingを失効させる。Goal、MVP、Phase、stage、profile、scope、外部authorityの変更はこの経路で吸収せず、影響する最も早いPhaseと別Issueへ戻す。

品質証拠は同一candidate artifact、source Head、config、SDK／signing context、scopeに対してだけ適用可能性を評価する。Head変更時に旧証拠を現Headの実行結果として付け替えない。changed pathsと依存関係から影響がないことを説明できる証拠だけを再利用候補とし、不明なら検証範囲を拡大する。設定や署名変更を一律に無害としない。squash後などsource／target Headが分岐しても両commit object間のactual diffを評価できるが、異なるHeadは再利用せず対象再検証へ進める。Phase 5と6で同じ候補を扱う場合は、[Phase 5から6への証拠適用](../docs/verification.md#12-phase-5から6への証拠適用)のimmutable判定をreview、PR、pre-merge、提出前preflightまで共有し、適用可能な元証拠を参照して重複実行を避ける。

既知不具合の許容、既知不具合の延期、意図的なテスト省略、未検証は別の状態として記録し、成功へ読み替えない。D-050 cutover以後のPhase 5／6 `implementation`は、Issue contractが封印したrelease identifier／revision／phase／scope／Baseのphase recordと、現在Issue／Base／Head／contractへ束縛したcanonical `.artifacts/issues/<issue>/<head>/release-disposition.json`を必須とする。cutover前のcontractには記録を推測生成せず、従来gateを維持する。

軽微不具合の許容にはclassification、low severity、影響、回避策、修正費用、同じIssue／Base／Headへのユーザー承認者・GitHub Issue comment参照・承認時刻、有効期限、追跡Issue、再評価条件を要求する。期限切れや別candidateの承認、approved reviewのlow finding、evidence applicabilityを不具合承認へ転用しない。延期した不具合も許容済みとは呼ばず、critical／high／unknownまたはデータ消失、秘密漏洩、誤課金、重大な金額／日時計算誤り、主要導線crash、認証／privacy／法務分類ならpre-merge／releaseをblockする。

D-050対象candidateはDelivery profileによる通常のreview省略経路を使わず、current-Headの正式な反対モデルreviewを必須とする。Phase番号から他の検証範囲を拡大せず、disposition、対象検証、必要なevidence applicabilityだけを同じpacketへ固定する。

品質確認は有限のTime budgetで行う。時間超過時は同じ長時間検証を自動反復せず、対象縮小、Issue分割、延期、未検証の明示、またはユーザー判断へ移る。安全条件を失敗した状態で時間節約を理由に公開へ進まない。

### 1.5.5 既存アプリと緊急修正

既存アプリの緊急修正は、確定済みの目的、Identity、UI方向、基盤を現在も適用可能と説明できる範囲で再利用し、影響する最も早いPhaseから開始できる。毎回Phase 1からやり直したり、変更と無関係なApp Icon／HTML比較を繰り返したりしない。一方、Issue、Branch、PR、現在Headの対象Test、安全確認、必要なreview／外部操作承認は省略しない。修正後に得た一般的な改善は、次releaseのPhase 1またはテンプレート改善Issueへ戻す。

### 1.5.6 AI検証用Simulatorの資源契約

全PhaseのAI検証用iPhone／iPad Simulatorは必要時に作成し、最終使用後にdeviceとそのdataを削除する使い捨て資源とする。停止またはeraseだけを削除完了とせず、device一覧とdata残留を確認してから利用枠を返す。成功、失敗、timeout、cancel、部分作成失敗をcleanup対象とし、強制終了で回収できなかったowned deviceはdurable記録から次回起動時に回収する。

同じMacの全application、repository、worktree、AI sessionを合計して、作成中の予約、作成済み、一時Shutdown、削除待ちを含むiPhone／iPad Simulatorを最大4台とする。4台は上限であって常設poolや稼働目標ではない。一つのsessionが同時に作成・保持できるdeviceは原則1台であり、子process／test workerは親sessionの枠を継承する。例外は対象と理由についてユーザーの明示判断を得るが、Mac全体の4台上限は引き上げない。

作成前にMac共通枠とsession枠を原子的に取得する。5台目または同一sessionの2台目は作成せず、取消可能かつ有限の待機にする。空き容量／memoryが不足する場合は4台未満でも新規作成と長時間検証を止め、現在のユーザー資源を削除して枠を作らない。同一sessionの日本語／英語×iPhone／iPad条件は、device作成、検証、必要証拠のdevice外保存、削除確認、枠返却を一条件ずつ行う。

削除対象は作成記録、exact UDID、repository／worktree／session／run owner、lease、非活動状態を照合できるdeviceだけとする。手動device、他owner、使用中、不明なdeviceを削除せず、名前やShutdown状態だけで所有を推測しない。蓄積済みdeviceはinventoryとdry-runで候補を示し、所有と未使用を証明できる対象だけを回収する。Runtime、Xcode、共通cache、ユーザーのDerivedData、canonical evidenceを一括削除しない。検証前後の空き容量と残留数を記録し、削除失敗は未回収として報告する。

#93以後の新規matrixはschema v2としてRuntime／Device Type／locale／case順だけを封印し、実行UDIDはcaseごとのversioned allocation記録へ分離する。runnerはrepository lockの内側でMac共通枠を取得し、一台ずつ作成・検証・証拠保全・削除する。旧schema v1の固定UDID matrix、sealed contract、既存証拠は書き換えずlegacy consumerとして維持する。#89は移植元の履歴として保持する。skills、App Store撮影、既存Issue移行も同じ#93 consumerへ接続し、未移行の旧証拠をschema v2の実行結果へ付け替えない。

## 2. Delivery stage

| Stage | 目的 | 標準検証 | 完了時の表現 |
| --- | --- | --- | --- |
| `shape` | 主要導線を短時間で操作可能にし、実画面で仕様とUI方向を確認する | Build、重要Unit Test、代表的な日本語iPhone 1条件のSmoke Test。コンパイル、起動、保存不能、クラッシュを確認 | 「shape完了。release-readyではない」 |
| `harden` | 承認済みの形に対し、一つの品質問題を狭く改善する | 対象Test、関連回帰、明示した`targeted` Simulator case。変更に必要な品質確認だけ | 「対象をharden済み。release-readyではない」 |
| `release` | リリース候補Headの全体品質と提出準備を確定する | §5の完全検証 | 完全検証が成功した場合だけrelease-ready |

アプリsource、Xcode project、asset、localization、Bundle設定、App Store／TestFlight経路へ触れないdelivery tool、schema、validator、review、evidence producerの変更は`harden + strict`のworkflow-only経路を使う。application `Verification`と`Verification scope`を持たず、Build、Unit Test、Simulator、Screenshot、visual evaluationは`not-applicable`とする。一方で対象repository tests、仕様整合、current-Head、strict review、pre-merge gateは省略しない。allowlist外pathまたはApp Store operationが混ざればworkflow-onlyを拒否する。

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

workflow-only `harden + strict`のRepository test範囲はapplicationのVerification scopeとは別に扱う。D-037 cutover後はClaim時に`targeted`、`head-all`、`base-and-head`の要求scopeと理由だけを封印し、exact test pathsは実装後のimmutable Base..Head差分とversioned manifestから決定する。D-039以後の`targeted`は既知の単一または複数domainに属するtestの決定論的unionを選び、manifest、runner、tracked test変更を理由に`head-all`へ自動昇格しない。未知pathは全件を実行せずplan生成を拒否する。

通常開発の対象testは1 command 300秒、Issue完了用`targeted` repository suiteはaggregate 900秒を上限とする。`head-all`／`base-and-head`はrelease、nightly相当の明示実行、またはユーザーがIssue contractで明示要求した場合だけ使う。`strict`なshape／hardenも対象安全testを維持するが、無関係な全repository testsや4条件matrixへ拡大しない。

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

失敗記録には停止stage、経過時間、timeout、未実行testを含める。timeoutや失敗時に成功形式の`verify.json`を生成しない。同一Issue／Head／scopeの長時間実行は直接反復せず、選択済み対象testの診断成功後に1回だけ再試行できる。2回目も同じ原因で失敗した場合は停止する。

D-050対象では、同じHead directoryに存在する`repository-test-failure-attempt-1.json`／`-2.json`を一件ずつexact path／digestでrelease dispositionの停止後判断へ対応付ける。producerだけでなくpacket、result publication、PR renderer、pre-merge、release preflightの各consumerも、record内の参照集合から推測せずHead directoryの2候補をdescriptor-boundで独立取得し、欠落状態も処理終了まで再照合する。許可するactionは`shrink`、`split`、`defer`、`wait`だけとし、reason、actor、authority、再開条件、判断時刻を必須にする。`split`／`defer`はユーザーauthorityとfollow-up Issueを要求し、`shrink`／`wait`はfollow-up Issueをnullにする。`wait`はrelease readinessをblockする。失敗記録があるのに判断がない、判断の参照先がない／改ざんされた、検証中に新しいfailureが出現した、`rerun`等の無制限反復action、別Issue／Headへの流用を拒否する。判断待ち時間はrunnerの実行budgetを延長した時間として扱わない。

再実行の順序は、対象Test、関連回帰Test、Delivery stage標準検証、`release`完全検証とする。Repository testも開発中は関連testだけを直接使い、canonical plan／evidenceは安定した最終候補Headで一度生成する。正式な一括証拠へ異なるattemptの部分結果を混ぜないが、診断済みの対象Test結果は修正判断に利用する。

## 7. Issue・レビュー・移行

新規Issueの`Delivery stage`節は`Stage`、`Time budget`、`Reason`をこの順で持つ。`Verification scope`節は`Scope`と`Reason`を持ち、stageを重複記載しない。Feature formは`shape / 120 minutes / standard / iphone-ja`、Regression formは`harden / targeted`、Release formは`release / strict / full`を既定とする。

D-037 cutover後のworkflow-only `harden + strict` Issueは、既存Acceptance criterionの一つをexact `Repository-test scope: targeted|head-all|base-and-head; Reason: <nonempty>`で開始する。宣言は実行結果ではなく要求方針であり、Claim後にexact test一覧へ書き換えない。plan、evidence、review、PR、premergeが同じIssue／Base／Headへ束縛されなければ完了しない。

`shape`と`harden`の`standard`はblockingな反対モデルレビューを要求しない。`strict`または`release`は現在Headの正式な反対モデルレビューを必須とする。shape/hardenのPRと完了報告は必ずnot release-readyを明記する。`release`は`type:release`の実際のアプリrelease candidateだけに使用し、Feature／Regression／workflow変更を完全検証へ迂回させない。

既定のreviewer pairはCodex primary→Claude、Claude primary→Codexである。Claudeが利用不能な場合も自動置換せず、ユーザー承認を一つのsealed ACへexact形式で記録したCodex-primary Issueだけが`cursor-grok-4.6-xhigh`を固定・非対話・read-only・有限timeoutのlauncherで使える。packet、result、receipt、PR、premergeは同じrouteとlauncher bytesを照合し、利用不能、不正出力、write検出はcanonical approvalを発行せず`blocked:review`とする。

Release PhaseはこのIssue分類から独立して記録する。Phase 3の完了を`shape` Issueのmergeだけから推測せず、Phase 5に`harden`、Phase 6に`release`を機械的に割り当てない。対象release revisionのPhase出口、Issueごとのstage証拠、必要なユーザー判断をそれぞれ確認する。

Claim済みで`deliveryStage`を持たない既存contractはcanonical bytesを変更せず、従来のprofile／scope gateを維持する。すなわちlegacy standard／strictはfullと正式review、legacy explicit fastは従来どおりfocused evidenceを使う。新しいIssue validatorはstage未指定を拒否する。既存Issueを縮小したい場合は、暗黙変換せずユーザー承認の上で新しいIssueへ分離する。

## 8. 依存関係

Issue #44がDelivery stage、Issue forms、skills、validator、runner、repository tests、bootstrap後repositoryを同じ契約へ揃えた。D-038のPhase記録／部分再gateは#85、証拠適用は#86、D-050の不具合許容／停止後判断は#87、Simulator資源契約と明示承認Grok review fallbackは#93が実装する。#88はIssue forms、planning／shipping／verification／App Store skillsと既存Issue移行を同じconsumer境界へ接続し、未移行範囲を新contractとして推測しない。#89は#93の移植元履歴として保持する。
