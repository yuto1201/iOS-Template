# 動く形から品質を固める段階的開発

Status: 確定
Version: 2.2
Date: 2026-09-13

## 1. 原則

開発順序は、必要な場合に比較案からUI方向を確定する、操作可能な形を作る、実画面で方向性を再確認する、問題別に品質を固める、リリース候補を完全検証する、の順とする。最終品質は下げず、高コストな横断検証を変更が収束した後へ移す。

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

`shape`と`harden`の`standard`はblockingな反対モデルレビューを要求しない。`strict`または`release`は現在Headの正式な反対モデルレビューを必須とする。shape/hardenのPRと完了報告は必ずnot release-readyを明記する。`release`は`type:release`の実際のアプリrelease candidateだけに使用し、Feature／Regression／workflow変更を完全検証へ迂回させない。

Claim済みで`deliveryStage`を持たない既存contractはcanonical bytesを変更せず、従来のprofile／scope gateを維持する。すなわちlegacy standard／strictはfullと正式review、legacy explicit fastは従来どおりfocused evidenceを使う。新しいIssue validatorはstage未指定を拒否する。既存Issueを縮小したい場合は、暗黙変換せずユーザー承認の上で新しいIssueへ分離する。

## 8. 依存関係

Issue #44がこの仕様、Issue forms、skills、validator、runner、repository tests、bootstrap後repositoryを同じ契約へ揃える。以後のアプリではshapeの実画面承認後に必要なharden Issueを作り、それらを依存にしたrelease Issueで完全検証する。
