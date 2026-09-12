# iOS verification

## 1. 目的

AIが「コード上は正しそう」ではなく、Build、Test、操作、見た目を実測したうえでIssueを完了できるようにします。物理端末の最終判断はユーザーが後から行います。

検証コストはDelivery stageと危険度に合わせます。`shape`は動く主要導線、`harden`は一つの品質問題、`release`は完全品質を証明します。高コスト検証を後段へ移しますが、コンパイル、重要ロジック、データ非破壊、秘密非露出は全stageで維持します。

### 1.1 Stage別の境界

検証範囲は`shape`の`iphone-ja`（1条件）、`harden`の`targeted`（非空canonical部分集合）、`release`の`full`（4条件）です。Delivery profileは危険度を決める別軸です。`strict`なshape／hardenは対象安全確認と正式reviewを維持しますが、無関係なrelease matrixは要求しません。

`shape`はBuild、重要Unit Test、主要導線の日本語iPhone Smokeを実行し、Screenshotやvisual reviewなしでcanonical `verify.json`を発行します。理由は`Delivery stage shape passed; not release-ready.`です。`harden`もvisual checkを明示しない限り同じ非visual経路を使います。`release`とvisual checkを持つhardenだけがdraft、Screenshot、visual result、finalizeの二段階経路を使います。

stage未指定のClaim済みcontractは旧release-level gateを維持します。未実行は`deferred / unverified`であり成功ではありません。shape／hardenをrelease readyと報告しません。

[UI Direction Gate](../.agents/skills/ui-direction/SKILL.md)は、現在のユーザーが対象範囲のHTML比較を明示した場合に方向の有無を問わず最優先で適用します。現在の明示省略は、現行性、exact scope、権限、理由、比較指示との非矛盾が明確な場合だけ`explicit-skip` routeとして通常判定を上書きし、曖昧または矛盾する場合は依存UIを`blocked:user`にします。それ以外は、exact hierarchy／flowを覆う確定方向があれば`confirmed-direction reuse`、対象方向が未確定で最初のユーザー向けUI、ルートnavigation／information hierarchyの新設・変更、主要flowの大幅な再設計のいずれかなら`comparison`、方向未確定かつ3 triggerのいずれもなくAcceptance criteriaがhierarchy、navigation、primary-flow interactionを決めない場合だけ`bounded direction-neutral`とします。coverage、triggerまたはneutralityが曖昧ならGateを実行します。Identity bootstrapと純非UIは`not-applicable`で、Gateを評価するのは依存する後続native UIだけです。

比較HTMLは、実装前に情報階層や操作仮説を比較するdecision-support artifactです。revision IDやSHA-256は「ユーザーがどの提示bytesを選択したか」を固定しますが、SwiftUIの動作、Safe Area、Dynamic Type、VoiceOver、keyboard、sheet、navigation、見た目のcanonical evidenceにはなりません。liveな`UI verification`もIssue contract／review packetへ封印されないため、検証・最終reviewは封印済みGoal／Acceptance criteria／Spec anchors／Dependencies、リンク済み確定spec／Decision、current-Head差分と証拠から、有効なroute宣言またはpre-D-030 legacy適用を判断します。Gate後もこの文書のcurrent-Head Build／Test／Simulator経路を省略しません。

宣言候補はAcceptance criterion本文がexact `UI-direction route:` prefixで始まる場合だけです。完全なroute宣言は、候補がexactly oneで、その本文先頭（`AC-*:`の直後）がexact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`を満たす場合だけです。`<route>`は`comparison`、`explicit-skip`、`confirmed-direction reuse`、`bounded direction-neutral`、`not-applicable`のいずれかとし、route固有の適用事実はReasonの後へ続けます。prefix外のroute語は候補として数えません。D-030 cutover `2026-09-06T00:31:41Z`より封印済みIssue contractの`fetchedAt`が前で候補がゼロの場合だけpre-D-030 legacyです。routeを推測せず、HTMLやroute宣言を遡及要求せず、contractを変更・再封印せず、元の封印済みAC／spec／Dependencies／current-Head evidenceを検証します。cutover前でも候補が一つ以上あれば通常のroute検証へ進み、malformed、unknown、multipleをrejectします。cutoverと同時刻以降にも同じexactly-one／完全性を要求し、候補ゼロもrejectします。

## 2. 環境の解決

`tools/resolve-simulator-matrix.sh` はIssueバッチ開始時に一度だけ実行します。

1. 使用するXcodeを確認する。必要な場合は `DEVELOPER_DIR` をコマンド単位で指定する。
2. Xcode versionとbuildを記録する。
3. 利用可能かつ最新のiOS Runtimeを選ぶ。
4. Runtime内の利用可能なDevice TypeからiPhone Proを選ぶ。`Pro Max` は除外する。
5. scopeがiPad caseを含む場合だけ、同じRuntime向けの最新世代iPad Airを選ぶ。同世代に11-inchと13-inchがあれば13-inchを選ぶ。
6. `full`は4行、`iphone-ja`は日本語iPhoneの1行、`targeted`はIssueで宣言したcanonical部分集合を作る。
7. `.artifacts/batches/${batchId}/simulator-matrix.json` へ保存する。

Claim／Resume後のIssue worktreeから、[ios-verifyのlocked command](../.agents/skills/ios-verify/SKILL.md#application-verification)をそのまま実行します。resolverとrunnerはいずれもそのworktreeの実装を使います。matrix IOはraw `../../.artifacts`、primary直下の`.worktrees`配置、Git metadataの往復参照を照合し、primaryの物理artifact storeを`O_NOFOLLOW`付きdescriptorで開きます。親directoryとmetadataを操作終了まで保持・再照合するため、任意linkや途中の差し替えは拒否します。clean detached test worktreeの物理的なprivate storeも維持します。凍結済みの完全なmatrixの再利用では、そのbyte列を変更しません。

名前に合う端末が見つからない場合、別端末へ自動フォールバックしません。`blocked:environment` として、利用可能な候補一覧を報告します。

### 2.1 Repository test prerequisites

`tools/tests/test-*.sh` はmacOSのBashと標準コマンド（`cat`、`cp`、`dirname`、`grep`、`mktemp`、`sed`、`tar`、`shasum`など）が使える開発環境を前提とします。追加・開発用コマンドは各entrypoint先頭の`require_test_commands`に宣言し、直接呼ぶものだけでなくfixtureや子toolが使うものも含めます。

| 依存 | 使用範囲・準備 |
| --- | --- |
| `rg`（ripgrep） | foundation、bootstrap、Claim／state／workflow、App Store screenshots／skills、runner回帰等の検索・assertion・fake-gh分岐。PATH上の実行ファイルが必須。未導入なら例として`brew install ripgrep`で導入する |
| `git`、`ruby`、`jq` | repository／contract／JSON／fixture操作。各testが使うものを宣言。Rubyの標準ライブラリを含む。`jq`もPATH上の実行ファイルが必要 |
| `swift`、`swiftc`、`/usr/bin/swiftc`、`/usr/bin/xcrun` | Swift validator、画像／動画inspection、bootstrap、evidence等。Xcodeの開発ツールが利用可能なこと。runner／premergeがabsolute pathで使うコンパイラも個別に確認する |
| `python3` | app-icon、mediaのfixtureとbootstrap。foundationは`tomllib`を使うためPython 3.11以上が必要。foundationを子として実行するbootstrapも同じ条件を開始前に確認する |
| `${CC:-cc}` | `test-cross-model-review.sh`と`test-review-shared-artifacts.sh`のnative reviewer fixtureコンパイル。`CC`は単一の実行ファイル名またはパスとし、flagsを混ぜない |
| `codex` | `test-cross-model-review.sh`だけが実際のnative Mach-O Codex sandboxを使用。他のtestには一律要求しない。既存のMach-O／sandbox検査も維持する |

`tools/tests/lib/prerequisites.sh`はfixture作成・assertion前に外部実行ファイルの有無を確認します。shell alias／関数だけでは満たしません。不足時は`test prerequisite unavailable`、test名、不足コマンドをstderrへ出し、exit 69で停止します。skipや成功ではなく環境不足であり、assertionが製品の不具合を検出した結果とも区別します。Pythonのversion／module不足も同じ扱いです。PATH全体や認証情報は出力しません。

テスト内でmockする`gh`、`claude`、`security`、`xcodebuild`、`xcrun`やprovider接続を、本物のアカウント／認証要件へ置き換えません。上表の実コンパイル／inspectionとは区別します。各testの開始前チェックはコマンド存在確認であり、実行成功やXcode／Simulator／外部サービスの検証を代用しません。

不足環境の回帰は`bash tools/tests/test-prerequisites.sh`で実行します。private PATHを使い、ホストからコマンドを削除せず、実際の入口がfixture作成前に止まることを確認します。依存が揃った状態の正式な全件成功は、引き続き`tools/run-repository-tests.sh`によるcurrent-Head証拠で確認します。

## 3. 固定されるmatrix

```json
{
  "schemaVersion": 1,
  "batchId": "2026-08-21-settings",
  "resolvedAt": "2026-08-21T12:00:00+09:00",
  "xcode": {
    "path": "/Applications/Xcode.app/Contents/Developer",
    "version": "26.5",
    "build": "17F42"
  },
  "runtime": {
    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    "version": "26.5"
  },
  "cases": [
    {"id": "iphone-en", "family": "iPhone", "deviceType": {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "name": "iPhone 17 Pro"}, "locale": "en_US", "language": "en"},
    {"id": "iphone-ja", "family": "iPhone", "deviceType": {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "name": "iPhone 17 Pro"}, "locale": "ja_JP", "language": "ja"},
    {"id": "ipad-en", "family": "iPad", "deviceType": {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "name": "iPad Air 13-inch (M3)"}, "locale": "en_US", "language": "en"},
    {"id": "ipad-ja", "family": "iPad", "deviceType": {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "name": "iPad Air 13-inch (M3)"}, "locale": "ja_JP", "language": "ja"}
  ]
}
```

この値は形式例です。実際のversionとDevice Typeはそのバッチで取得した値を使います。

### 3.1 Simulatorのシステム言語と地域

matrixの`language` / `locale`は、アプリ起動引数とUI Testだけでなく、各caseの専用Simulatorのシステム設定にも適用します。runnerは封印済みmatrixの`en` / `en_US`から`AppleLanguages = [en-US]`と`AppleLocale = en_US`、`ja` / `ja_JP`から`[ja-JP]`と`ja_JP`を導出します。呼出し元の環境変数や追加引数でこの値を置き換えません。

アプリをインストールする前に、所有権を照合したBootedデバイスへ設定を書き込み、その専用デバイスだけをshutdown／bootしてSpringBoardへ反映します。この再起動では設定を消すeraseを行いません。再起動後と各caseの撮影直前（画像を作らないstageでは操作検査の終了時）にglobal preferencesを読み戻し、言語配列・地域が宣言と完全一致しなければcaseを失敗にします。書込み、再起動、読取りの失敗や不正なplistも成功へ読み替えません。個人用Simulator、別batchのデバイス、Macの言語設定は変更しません。

画像評価ではアプリ本文に加えてステータスバー等のsystem chromeを確認します。特にiPadの日付が英語caseでは英語、日本語caseでは日本語で表示されることを実際の画像から確認し、アプリ起動引数だけをシステム言語の証拠にしません。case終了時の既存の専用デバイス回収は維持します。

`tools/tests/test-ios-runner-system-locale.sh`は、4条件の値・再起動順序・環境変数の非採用と、言語／地域不一致、欠落・型違い・不正plist、書込み／読取り失敗、再起動後の設定消失、UI操作後の設定変化を検査します。fake Simulatorによる回帰テストは実Simulatorの表示確認とは別の証拠です。

## 4. 実行段階

### Fast route: focused Build and Test

`fast`は安定した現在Headで次を実行します。

```bash
tools/verify-fast-issue.sh \
  --issue "$ISSUE" \
  --expected-base "$BASE_SHA" \
  --project ExampleApp.xcodeproj \
  --scheme ExampleApp \
  --test-identifier ExampleAppTests/DomainAcceptanceTests/allAcceptanceCriteria \
  --destination-udid "$IPHONE_UDID"
```

この経路はBuildを1回、指定Unit Testを1回実行し、警告・失敗・Skipがないことを確認して`focused-code`のcanonical `verify.json`を発行します。4条件matrixの解決、アプリ操作、Screenshot、視覚評価は行いません。Issue contractがexplicit `fast`でない場合、またはBase..HeadにUI source、security／service import、migration、ownership、release、delivery gateなどの高リスクpathが含まれる場合は拒否します。

文書だけの変更は、従来どおりXcode自体を起動しないdocumentation-only経路を使用できます。

### Stage A: 静的確認

- 変更ファイルとIssue Scopeの対応
- 追跡対象への秘密混入スキャン
- 日本語の文字列、localization可能な管理、既存翻訳の破壊がないこと。新規英訳の完成確認は仕上げ範囲で行い、延期箇所は記録する
- Compile-time warningの差分
- pre-D-030 legacy以外では、封印済みAcceptance criteria全体でexactly oneの有効なroute宣言があり、一つのAC本文先頭がexact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`で開始し、許可済みroute、非空Scope／Reason、Reason後の適用事実を満たすこと。prefix外のroute語を数えず、確定anchorが`Spec anchors`、選択前提がDependenciesにあること。qualifying legacyでは宣言を要求せず、元の封印済みAC／spec／Dependenciesを検証すること
- `comparison`では、scope、artifact path／revision、提示bytesのexact SHA-256、採用・不採用要素、対象screen／state、native adaptation範囲という共通記録が確定仕様と追記型Decisionへmergeされ、Issueのsealed `Spec anchors`から到達できること。単一案はselected concept IDを持ち、hybridは全採用要素からsource concept IDへのexhaustive mappingを持つ。hybridのselected／base concept IDはユーザーがbaseを明示した場合だけ持つこと
- `confirmed-direction reuse`では、route宣言のScope／Reason、Reason後の覆われるhierarchy／flowと、再利用する確定済みUI方向anchorが一致すること
- `bounded direction-neutral`では、対象方向が未確定でも3 triggerのいずれもなく、Acceptance criteriaと実装がhierarchy、navigation、primary-flow interactionを決めないこと。route宣言のScope／ReasonとReason後の非決定境界、関連する確定済みproduct／behavior anchorが一致すること
- 現在の明示的な比較省略では、`explicit-skip`宣言のScope／ReasonとReason後の指示の現行性、権限、比較指示との非矛盾が封印済みAcceptance criterionから裏付けられ、関連する確定済みproduct／spec／Decision anchorが`Spec anchors`にあること
- Identity bootstrapまたは純非UIでは、封印済みGoal／Acceptance criteriaとcurrent-Head差分から非UI scope／理由が裏付けられ、関連する確定済みproduct／spec anchorがある一方、UI方向anchorを要求していないこと。live bodyの`UI verification` exact `Not applicable`形式はClaim前に検証し、最終証拠として代用しないこと。Gateを評価するのは依存する後続native UIであること
- App Icon Issueでは、ユーザーが明示選択したstable concept IDと確定brief、選択済みPNG、default AppIcon entry、`Config/app-icon.json`のprompt summary／generator／dimensions／asset path／exact SHA-256が一致し、`tools/validate-app-icon.sh`が成功すること。候補やpreviewを製品assetまたはcanonical iOS evidenceとして扱わず、この選択でUI Direction Gateを満たしたと推測しないこと
- 3D asset authoringを含むIssueでは、共有`ios-3d-assets` routeが使われ、Issue／PR証拠のauthoring modelがexact `gpt-6-astra`であること。Claudeや別のCodex modelが作成・形状変更した3D bytesへfallbackしていないこと。統合・format validation・RealityKit実装・Build／Test・reviewは一般のClaude／Codex経路で検証してよい

### Stage B: Build and unit tests

- 現在のHead SHAを取得
- current Headと信頼済みBaseのrangeを検証し、filterを起動しないplumbingとdescriptor readでtracked inventory、index flag、mode、bytesがexact Headに一致することを確認する
- Issueが影響するschemeをBuild
- Unit Testを実行
- 失敗、Skip、件数を記録
- worktreeごとのDerivedDataを使用

BuildとUnit Testは同じHead SHAにつき一度実行し、4つのlocaleごとに重複実行しません。

Issueの受け入れ条件がRepositoryのdelivery tool、guard、workflow、evidence producer自体へ依存する場合は、iOSのUnit Testだけで代用しません。`tools/run-repository-tests.sh` を使い、current Headのtracked `tools/tests/test-*.sh` 全件をrunner所有のclean detached worktreeで実行します。各ACへ関連test pathをexactに一度対応付け、成功した全testのexit status、sanitized output digest、時刻、runner bytesを `.artifacts/issues/${ISSUE}/${HEAD_SHA}/repository-tests.json` へno-replaceで保存します。test本文のstdout/stderrはartifactへ保存しません。失敗、Head変更、dirty caller、contract不一致、mapping不足、既存artifact衝突のどれかがあればcanonical evidenceは発行しません。

iOS runner回帰は、共通の`tools/tests/lib/ios-runner-fixture.sh`と独立した16個のtracked entrypointへ分けています。引数なしの`bash tools/tests/test-ios-runner.sh`はshape／scope／timeout群だけを実行します。`scoped`も同じ群、`stubborn`は従来のTERM無視probe診断です。残る群はcleanup、startup、baseline、identity、inputs、publication、resources、recovery、recovery-before-rename、recovery-after-rename、recovery-final、locking、finalization、finalization-integrity、system-localeで、`tools/tests/test-ios-runner-<群名>.sh`を実行します。各群は自身のtemporary repository、fake Xcode／Simulator、adapter stateを作り、終了時に自身のscratchだけを回収します。

全runner回帰だけをローカル診断する場合は`bash tools/tests/test-ios-runner.sh all`を使います。このコマンドは各群を900秒上限で順番に実行し、一つでも失敗すれば失敗します。canonical repository runnerも既存の`test-*.sh`探索で全16群を実行し、群ごとの結果と開始・終了時刻を記録します。単一群の成功を全suiteの成功として扱わず、正式証拠には引き続き`tools/run-repository-tests.sh`を使います。productionの検証、case、assertion、timeout、証拠公開条件は変更しません。

```bash
tools/run-repository-tests.sh \
  --issue "${ISSUE}" \
  --expected-base "${BASE_SHA}" \
  --map AC-1=tools/tests/test-provider-ownership.sh \
  --map AC-2=tools/tests/test-provider-preflight.sh
```

`prepare-review-packet.sh` はこのcanonical evidenceが存在する場合だけ検証してpacket内の `repositoryTests` へ封印します。したがってreviewerとpre-merge gateは、iOS smoke testとは別に、現在Headで実際に通過したRepository test suiteと各ACの対応を評価できます。

#### BaseとHeadの全repository tests

Claim前に一つのAC本文をexact `Repository-test scope: base-and-head; `で開始し、その後に非空の条件を置く。runnerと全review consumerはsealed contractのこの宣言から新形式を必須と判断する。重複・未知scope・不完全な宣言は拒否し、宣言なしの既存contractは旧Head-only recordのまま扱う。`--base-map`を渡しただけでは新形式へ切り替えられない。

全ACへ`--map AC-N=TEST[,TEST...]`でHeadの実装／回帰testを対応付ける。Baseの結果を引用するACにだけ`--base-map AC-N=TEST[,TEST...]`を追加する。scopeを宣言したACには、BaseとHeadそれぞれ自身の全tracked test pathを対応付ける。Baseにはまだ存在しないHeadの新testを要求しない。Base mappingなしは空配列となり、Baseが新機能を証明したとは記録しない。

```bash
tools/run-repository-tests.sh --issue "${ISSUE}" --expected-base "${BASE_SHA}" \
  --map AC-1=tools/tests/test-feature.sh \
  --map "AC-2=${ALL_HEAD_TEST_PATHS_COMMA_SEPARATED}" \
  --base-map "AC-2=${ALL_BASE_TEST_PATHS_COMMA_SEPARATED}"
```

上はAC-2にscope宣言がある場合の形式例であり、各revisionの実在する全inventoryを使用する。現在HeadのproducerがBase、Headの順で別々のclean detached worktreeを作り、各revisionの全tracked testを実行する。各testの既定900秒、process groupの回収、既存の引数規則は維持し、新形式は900秒超を許可しない。失敗・timeout・不足したmappingなら成功recordを発行しない。対象fixtureの成功は実repository全suiteの成功とは別である。

canonical pathは同じ`repository-tests.json`だが、新recordは`schemaVersion: 2`、`scope: base-and-head`とし、以下を持つ。

- 共通identity: Issue、Base SHA、Head SHA、exact contract path/digest、開始／完了時刻、`status: passed`。
- `producer`: 実行を統括した現在の`headSha`と、二つのrunner fileのexact Head bytes digestを持つ`files`。Baseに新producerがあるとは仮定しない。
- `revisions`: `base`、`head`のexact順序で`role`、`testedSha`、全`suite`／`tests`、開始／完了時刻を記録する。各testは`path`、そのrevisionの`sourceDigest`、`arguments`、完全な`command`、`status`、`exitStatus`、sanitized `outputDigest`、`timeoutSeconds`、`elapsedSeconds`、開始／完了時刻を持つ。
- `acceptanceEvidence`: 全AC順の`id`、`status`、`baseTests`、`headTests`。scope宣言ACは両側の全inventoryに一致し、他ACのBase mappingは省略できる。

validatorはrecordの自己申告ではなく、callerが信頼済みBase／Headのimmutable Git objectから独立に取得した全inventoryとsource／producer digestへ照合する。packetは値`repositoryTests`に加え、canonical recordのpath/digestを`repositoryTestsFile`として封印する。この新形式ではrecordがないとpacketを作れず、packet-only検証、result検証、publication、premergeでも同じclosureを要求する。古いschema v1 recordとそれを含むpacketのbytesは変更しない。

### Stage C: UI and acceptance matrix

contractで指定されたexact 1条件／targeted部分集合／4条件それぞれで次を行います。

1. Simulatorを対象RuntimeとDevice Typeで準備する。
2. LocaleとLanguageを明示してアプリを起動する。
3. Issueの受け入れ操作を実行する。
4. 期待するUI要素と状態を機械判定する。
5. visual checkを要求する場合だけ主要状態のスクリーンショットを保存する。
6. crash、freeze、操作不能を確認し、要求stageの範囲だけを判定する。

shapeは`testIdentifier`による主要導線Smokeを必須とし、単なるlaunch assertionだけでは完了しません。`fast`と純粋な文書変更はSimulator検証を`not-applicable`とします。

UI Direction Gateを通したshapeでは、HTMLのDOMやCSSではなく、確定仕様に採用した情報階層、主要task、navigation、代表stateをnative画面とSmoke Testで確認します。HTMLを開けること、HTML screenshotが似ていること、digestが一致することだけではcase成功にしません。

### Stage D: AI visual evaluation（visual-requiredのみ）

AIはスクリーンショットごとに次を評価します。

- 受け入れ条件との一致
- 切れ、重なり、意図しない余白
- iPhoneとiPadの情報階層
- 日本語と英語の文字量差
- Dynamic Typeとタップ領域への明白な問題
- Sheet、alert、keyboard、orientationなど対象状態
- 参照デザインがある場合の差異。UI Direction Gate由来の場合は確定仕様に採用した階層・導線・状態を比較し、CSS pixel一致は要求しない

releaseでは主開発モデルが一次評価し、反対モデルレビューへ画像を含めます。visual checkを明示したhardenは対象画像だけを評価します。shapeではこの段階を実行しません。

すべての必須画像は確認しますが、評価する完成度はIssueのACと開発段階に合わせます。通常機能で延期を明示した英訳・iPad最適化を、画像があるという理由だけで完成必須にしません。仕上げ・リリースでは日英・端末間の完成度を確認し、延期を残したままfull対応済みとは判定しません。

### Stage D.1: 二段階の証拠公開

visual-required application検証は実行と視覚承認を分けます。非visualのshape／hardenは同じrunnerがBuild、Unit、mechanical caseを完了後、`executionRoute: xcodebuild-stage`、`visualEvaluation.status: not-applicable`のfinal evidenceを直接atomic publishします。visual-requiredのharden／releaseだけがScreenshotとdraftを公開し、visual承認後にfinalizeします。
historical evidence表記の`tests:TemplateAppTests/NotificationSettingsTests`はbootstrapのlive identity anchorとしてだけ保持します。Task 4 contractの`acceptanceMappings.checks`ではこの表記を許可せず、`stage:unit-tests`と実行済みcase referenceを使います。

```bash
tools/verify-ios-issue.sh \
  --issue 42 \
  --expected-base "${BASE_SHA}" \
  --issue-contract .artifacts/issues/42/issue-contract.json \
  --matrix .artifacts/batches/settings-2026-08-21/simulator-matrix.json \
  --project ExampleApp.xcodeproj \
  --scheme ExampleApp
```

runnerは `/tmp/ios-template-verify/${physicalWorktreeName}-${sha256OfPhysicalRoot}/issue-42/${headSha}/Attempts/attempt-${uuid}/` の `DerivedData`、`Build.xcresult`、`Tests.xcresult`、`Cases/${caseId}.xcresult`、一時Screenshotだけを使い、Repository内へDerivedDataやresult bundleを作りません。`/tmp` の各directoryは現在のuid所有、mode `0700`、symlinkなしをdescriptor-boundに確認します。成功時はcanonical draft／stage finalの公開完了後、失敗時は`.artifacts/issues/<issue>/<head>/failures/failure-*.json`の記録後に、Issue/Head lockを保持したままsealed configのidentityとdigestを再照合して当該attemptを削除します。所有directoryをdescriptor-boundに再確認して`0700`へ戻し、再帰unlinkと各directory fsyncを完了してからlockを解放します。lock取得前に作成されたlock loserのprivate attemptもdescriptor-boundに回収します。Issue/Head単位のkernel advisory lockはrunner lifetime中だけ保持され、正常終了、signal、crashでkernelが解放します。

起動時はIssue/Head lock取得後、Build前に同じ`${physicalWorktreeName}-${sha256OfPhysicalRoot}`だけを走査します。`issue-*/<40hex>/Attempts/attempt-<uuid>`のうち、各Headの`.verify.lock`を`LOCK_EX|LOCK_NB`で保持できる場合だけ孤児を回収します（現在Headは取得済みlockを使用）。`O_NOFOLLOW|O_DIRECTORY`で開き、自uid所有、`fstatat`と`fstat`のdev/ino一致、内部のmode `0400`のsealed runner configとexact `attemptRoot`／worktree identityを確認します。symlink、別uid、config欠落・不正、識別不能、活動中のHeadはskipし、個別回収失敗も実行を失敗させずstderrへ件数だけを出します。名前や経過時間だけでは削除しません。

`.verify.lock` fileと空のHead／Issue／worktree／Attempts directoryは残します。lock fileをunlinkすると、既にopen済みの別runnerと新規runnerが別inodeをlockするsplit-lockを招くためです。別repository／別worktree ID、ユーザーfile、canonical `.artifacts`とfailure artifactは回収対象外です。failure保持期間とDerivedData配置は変更しません。finalizeとpublication recoveryは公開済みdraft・Screenshot・journalを使い、削除済みattemptのxcresult／DerivedDataを再読しません。

production entrypointはprivileged modeのabsolute `/bin/bash -p` で起動し、entrypoint directoryはshell parameter expansion、`builtin cd`、absolute `/bin/pwd`だけで解決します。その後はabsolute `/usr/bin/git`、`/usr/bin/xcode-select`、`/usr/bin/xcrun` を使います。Gitは全呼び出しでRepository localのfsmonitorを無効化し、hooks pathを`/dev/null`へ固定します。`/Applications/Xcode.app/Contents/Developer` が有効なら優先し、それ以外はtrusted `xcode-select -p` のphysical pathを使います。そこからnon-symlinkの `usr/bin/xcodebuild` と同じDeveloper directory内へ解決されるSwift toolchainを固定し、`xcodebuild -version` が成功した場合だけ採用します。Git、Ruby、Swift、XcodeBuild、xcrunはvalidated HOME/TMPDIR/user/localeと固定PATHだけを入れた`env -i`から実行します。Xcode commandだけへ同じcommand-scoped `DEVELOPER_DIR` を追加し、Git、Ruby/Gem/Bundler、DYLD、Swift driver、SDK/toolchain、compiler/build-setting環境を継承しません。callerの `PATH`、`BASH_ENV`、export済みshell function、環境変数でproduction executableを差し替えるinterfaceは持ちません。

`--project` はRepository-relativeなcommitted `.xcodeproj` directoryだけを許可します。runnerはtrusted Gitの`ls-tree` exact inventoryと各object IDへの`cat-file blob`だけからprivate `Source`をdescriptor-relatively構築します。regular blobは実行bitを保存し、mode `120000` はUTF-8のrelative targetがsnapshot内のcommitted file/directoryへ解決される場合だけexact symlinkとしてmaterializeします。absolute/escaping/missing target、ancestor loop、symlink chain cycleはBuild前に拒否し、snapshot全体をseal/fsyncします。Xcodeはmutable worktreeではなくこのraw-Head snapshotだけを物理cwdとしてBuild/unit/UI Testします。worktree側は`git status`やcheckoutを使わず、index inventory、assume-unchanged/skip-worktree flag、tracked mode/bytesをdescriptor-boundでHeadへ照合します。ignored/untracked fileやconversion filterはBuild入力になりません。source digestはversion label、Head、project-relative path、full Head tuple/blobをlength-prefixし、`build.sourceTree.projectPath`は`build.project.path`とexact一致させます。project subtree digestは`build.project`としてdraft/finalへ固定します。Buildはsingle destination、`-parallel-testing-enabled NO`の`build-for-testing`を1回だけ実行します。その後、contractのexact `unitTestIdentifier`を同じdestinationで`test-without-building -only-testing:`し、各`testIdentifier` caseも同じbuildを使います。Build、unit test、caseのdiagnostics/test countsはhuman-readable logをgrepせず、trusted `xcrun xcresulttool` schema `0.1.0` の`devicesAndConfigurations`とtest treeから判定します。Build/unit test/caseのwarning、analyzer warning、errorはすべて0でなければ失敗します。unit stageと各UI stageはsummary、configuration、test treeのすべてで指定した1件だけがexpected target/class/method、exact matrix UDIDとconfigurationでpassedし、failed/skipped/expected failureが0でなければ失敗します。UI caseではcontractのlocale/language引数もcommandに固定します。

Build productはlocked attempt内のDerivedData `Build/Products` 配下にあるregular app directoryだけを候補にし、Bundle IDとBundle executableを検証します。runnerはbundle tree全体をdescriptor-boundに再帰走査し、symlink、special file、別uid、複数hardlinkを拒否してprivate `StagedApp`へcopy、seal、fsyncします。tree digestはrecord type、path、content length/contentをlength-prefixして構造とbytesを一意に固定します。各install直前にstaged tree、Bundle ID、executableを再読してdigest一致を要求するため、Build productやstaged pathの置換をinstallへ持ち込めません。

sealed configはbatch ID、Runtime identifier/version、要求scopeの1case／targeted部分集合／4caseのexact UDID、Device Type identifier/name、および`iOS-Template-${batchId}-${caseId}`形式の専用device名を固定します。runnerは最初のXcode Build前にfresh `simctl list devices --json`で要求された全caseのidentityとglobal name uniquenessを一括検証します。検証済みの専用deviceだけをshutdown-if-Bootedしてeraseし、ユーザー作成device、別batch、別IssueのUDIDを操作しません。`simctl shutdown all`は使用しません。runnerはUDIDをdelete/createせず、別deviceへ代替しません。

各case直前にlive Git Head、tracked Head inventory/bytes/flags、sealed config、canonical contract/matrix、source/project digestを再検証します。その後matrixのexact UDIDをbootし、bootstatus、install、exact language/localeでlaunch、bounded liveness、contractの機械checkを直列実行します。visual-requiredのcaseだけScreenshotを取得します。`testIdentifier`はunique case xcresultを使うexact `-only-testing`です。shapeでは主要導線のSmoke Testを必須とし、`launch-succeeded`だけでは代用しません。

case成功はexact UI結果、locale relaunch、process identity/liveness、visual-requiredならdecodable PNGを確認し、対象Bundle IDだけをterminateして専用deviceを回収した後に確定します。通常failure／TERMは記録したactive caseだけを回収します。失敗時はsanitized failure recordを残し、成功形式の証拠を公開しません。正式証拠へpartial attemptをmergeしません。

visual-required成功時はScreenshotとcanonical `verify-draft.json`を一つのno-replace transactionで公開します。非visual shape／hardenはdraftを作らず、mechanical case、Build、Test、`not release-ready`理由を持つcanonical `verify.json`を検証後にatomic publishします。どちらもcontract順序とcurrent Headをpublication直前に再検証します。以下のdraft schema例はvisual-required release用です。

```json
{
  "schemaVersion": 1,
  "status": "awaiting-visual-review",
  "issue": 42,
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "issueContract": {"path": ".artifacts/issues/42/issue-contract.json", "digest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e"},
  "matrixFile": ".artifacts/batches/settings-2026-08-21/simulator-matrix.json",
  "matrixDigest": "sha256:490d32bf9174b57fb9b05a00e0231d22082e4a9576b0377f0df2641d96349d0b",
  "executionRoute": "xcodebuild-simctl",
  "xcode": {"path": "/Applications/Xcode.app/Contents/Developer", "version": "26.5", "build": "17F42"},
  "build": {"status": "passed", "scheme": "ExampleApp", "warningsAdded": 0, "project": {"path": "ExampleApp.xcodeproj", "digest": "sha256:c508ebb4550e3fc36666de55b2f9750e95adcbaab20421810f48d7e39b69e15e"}, "sourceTree": {"headSha": "0123456789abcdef0123456789abcdef01234567", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "projectPath": "ExampleApp.xcodeproj"}},
  "tests": {"status": "passed", "passed": 1, "failed": 0, "skipped": 0},
  "cases": [
    {"id": "iphone-en", "status": "passed", "screenshot": "iphone-en/screenshot.png", "screenshotDigest": "sha256:54808a3902e22d616104502c99f728a3b9fb8f7d00412c2d725a03580e98b6e9", "mechanicalCheck": "test:ExampleAppUITests/SmokeTests/testLaunch"},
    {"id": "iphone-ja", "status": "passed", "screenshot": "iphone-ja/screenshot.png", "screenshotDigest": "sha256:fd1a5bba126762a8aee2cbfd9816ba4983c335bad13cc170e6db5940449bb4b3", "mechanicalCheck": "assertion:launch-succeeded"},
    {"id": "ipad-en", "status": "passed", "screenshot": "ipad-en/screenshot.png", "screenshotDigest": "sha256:8f5674ac5c3bdfa4bc63bf120ee8d6a7706598557fc99b51d37de343e7091e9d", "mechanicalCheck": "test:ExampleAppUITests/SmokeTests/testLaunch"},
    {"id": "ipad-ja", "status": "passed", "screenshot": "ipad-ja/screenshot.png", "screenshotDigest": "sha256:5d173426722d981121aee0251e7c64a2b25797ea3fc154c06c4aaeb433e2ee62", "mechanicalCheck": "assertion:launch-succeeded"}
  ],
  "acceptanceEvidence": [
    {"id": "AC-1", "evidence": ["stage:build", "stage:unit-tests", "case:iphone-en", "case:iphone-ja"]},
    {"id": "AC-2", "evidence": ["case:ipad-en", "case:ipad-ja"]}
  ],
  "workspaceArtifacts": {
    "derivedDataPath": "/tmp/ios-template-verify/worktree-name-64hex-root-digest/issue-42/0123456789abcdef0123456789abcdef01234567/Attempts/attempt-uuid/DerivedData",
    "buildResultBundlePath": "/tmp/ios-template-verify/worktree-name-64hex-root-digest/issue-42/0123456789abcdef0123456789abcdef01234567/Attempts/attempt-uuid/Build.xcresult",
    "testResultBundlePath": "/tmp/ios-template-verify/worktree-name-64hex-root-digest/issue-42/0123456789abcdef0123456789abcdef01234567/Attempts/attempt-uuid/Tests.xcresult"
  },
  "executionCompletedAt": "2026-08-21T12:55:00+09:00"
}
```

Task 5のAI評価はcanonical `.artifacts/issues/42/${headSha}/visual-result.json` を次のexact schemaで書きます。`draft` と `visualPacket` は同じIssue/Headのcanonical pathとexact bytesを固定します。要求scopeの全caseの `images` はpacketのprimary/additional imageを同じ順序、state、path、digestで列挙し、承認時はtop-level、各case、各imageの `findings` が空です。

```json
{
  "schemaVersion": 1,
  "status": "approved",
  "issue": 42,
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "draft": {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/verify-draft.json", "digest": "sha256:4ae755fb899a15125dfe7db017761abe901e1de00bf266894157826c827a3f2f"},
  "visualPacket": {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/visual-packet.json", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  "cases": [
    {"id": "iphone-en", "status": "approved", "images": [{"state": "primary", "path": "iphone-en/screenshot.png", "digest": "sha256:54808a3902e22d616104502c99f728a3b9fb8f7d00412c2d725a03580e98b6e9", "findings": []}, {"state": "settings-open", "path": "iphone-en/settings-open.png", "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "findings": []}], "findings": []},
    {"id": "iphone-ja", "status": "approved", "images": [{"state": "primary", "path": "iphone-ja/screenshot.png", "digest": "sha256:fd1a5bba126762a8aee2cbfd9816ba4983c335bad13cc170e6db5940449bb4b3", "findings": []}], "findings": []},
    {"id": "ipad-en", "status": "approved", "images": [{"state": "primary", "path": "ipad-en/screenshot.png", "digest": "sha256:8f5674ac5c3bdfa4bc63bf120ee8d6a7706598557fc99b51d37de343e7091e9d", "findings": []}], "findings": []},
    {"id": "ipad-ja", "status": "approved", "images": [{"state": "primary", "path": "ipad-ja/screenshot.png", "digest": "sha256:5d173426722d981121aee0251e7c64a2b25797ea3fc154c06c4aaeb433e2ee62", "findings": []}], "findings": []}
  ],
  "findings": [],
  "reviewedAt": "2026-08-21T13:00:00+09:00"
}
```

次のfinalize commandはcurrent Headとtracked Head bytes/flags、descriptor-bound canonical path、draft/packet digest、Issue、matrix、4case、全reviewed imageのpath/digest/current bytes、承認状態、時刻順序、各mechanical checkとAC mappingのcurrent canonical contract一致を再検証します。Swift finalizerがstrict Task 3 schemaのprivate sealed candidateを完成させ、同じprocess内のvalidatorがexact Base/Issue/Headで検証します。validated candidate FD/inode/digestとinitial canonical `visual-result.json` exact bytes/digestを保持し、canonical rename直前のpublication callbackでもshared draft validator、visual packet validator、canonical visual-result validator、final `visualEvaluation` validatorをdescriptor-boundで再実行します。Git/config/project/source、packet exact bytes、canonical visual-result exact bytes/approval、全PNG bytes/setのいずれかがinitial validation後に変化した場合は公開しません。これらを再検証したまま`renameatx_np(RENAME_EXCL)`でcanonical `verify.json`をatomic no-replace公開して再照合し、fileとdirectoryをfsyncします。standalone `--candidate-file` publicationは許可しません。rename直後のprocess deathから再実行した場合は、既存`verify.json`がowned sealed regular fileでcandidateとexact digest一致するときだけidempotent successとしてfsyncし、mismatched/corrupt/unsafeな既存fileは拒否して保持します。その他の衝突時も既存winnerを保持し、失敗時にpartial `verify.json` を露出しません。

```bash
tools/verify-ios-issue.sh --finalize \
  --issue 42 \
  --expected-base "${BASE_SHA}" \
  --draft ".artifacts/issues/42/${HEAD_SHA}/verify-draft.json" \
  --visual-result ".artifacts/issues/42/${HEAD_SHA}/visual-result.json"
```

Issue/current Head identityを確立した後のrange、tracked Head不一致、その他preflightを含む各失敗は既存結果を上書きせず、`.artifacts/issues/42/${headSha}/failures/failure-${uuid}.json` へ次のexact sanitized schemaでdescriptor-boundなprivate candidateからatomic no-replace publishし、fileとdirectoryをfsyncします。failure writerはGit top-levelとcurrent Headを独立再検証しますが、失敗理由になったtracked状態やBase ancestryを成功条件にはしません。`stage` と `error` はrunnerが定める非秘密の分類だけで、command output、Token、個人pathは保存しません。

```json
{
  "schemaVersion": 1,
  "status": "failed",
  "issue": 42,
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "stage": "unit-tests",
  "error": "unit tests failed, were skipped, or reported invalid counts",
  "recordedAt": "2026-08-21T12:50:00+09:00"
}
```

### Stage E: Evidence

`.artifacts/issues/${issueNumber}/${headSha}/verify.json` を生成します。

```json
{
  "schemaVersion": 1,
  "status": "passed",
  "changeClassification": "application-code",
  "reason": null,
  "issue": 42,
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "issueContract": {
    "path": ".artifacts/issues/42/issue-contract.json",
    "digest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e"
  },
  "matrixFile": ".artifacts/batches/2026-08-21-settings/simulator-matrix.json",
  "matrixDigest": "sha256:490d32bf9174b57fb9b05a00e0231d22082e4a9576b0377f0df2641d96349d0b",
  "executionRoute": "xcodebuild-simctl",
  "xcode": {
    "path": "/Applications/Xcode.app/Contents/Developer",
    "version": "26.5",
    "build": "17F42"
  },
  "build": {"status": "passed", "scheme": "TemplateApp", "warningsAdded": 0, "project": {"path": "ExampleApp.xcodeproj", "digest": "sha256:c508ebb4550e3fc36666de55b2f9750e95adcbaab20421810f48d7e39b69e15e"}, "sourceTree": {"headSha": "0123456789abcdef0123456789abcdef01234567", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "projectPath": "ExampleApp.xcodeproj"}},
  "tests": {"status": "passed", "passed": 1, "failed": 0, "skipped": 0},
  "cases": [
    {"id": "iphone-en", "status": "passed", "screenshot": "iphone-en/screenshot.png", "screenshotDigest": "sha256:54808a3902e22d616104502c99f728a3b9fb8f7d00412c2d725a03580e98b6e9"},
    {"id": "iphone-ja", "status": "passed", "screenshot": "iphone-ja/screenshot.png", "screenshotDigest": "sha256:fd1a5bba126762a8aee2cbfd9816ba4983c335bad13cc170e6db5940449bb4b3"},
    {"id": "ipad-en", "status": "passed", "screenshot": "ipad-en/screenshot.png", "screenshotDigest": "sha256:8f5674ac5c3bdfa4bc63bf120ee8d6a7706598557fc99b51d37de343e7091e9d"},
    {"id": "ipad-ja", "status": "passed", "screenshot": "ipad-ja/screenshot.png", "screenshotDigest": "sha256:5d173426722d981121aee0251e7c64a2b25797ea3fc154c06c4aaeb433e2ee62"}
  ],
  "visualEvaluation": {
    "status": "passed",
    "packet": {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/visual-packet.json", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    "cases": [
      {"id": "iphone-en", "images": [{"state": "primary", "path": "iphone-en/screenshot.png", "digest": "sha256:54808a3902e22d616104502c99f728a3b9fb8f7d00412c2d725a03580e98b6e9", "status": "passed", "findings": []}, {"state": "settings-open", "path": "iphone-en/settings-open.png", "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "status": "passed", "findings": []}]},
      {"id": "iphone-ja", "images": [{"state": "primary", "path": "iphone-ja/screenshot.png", "digest": "sha256:fd1a5bba126762a8aee2cbfd9816ba4983c335bad13cc170e6db5940449bb4b3", "status": "passed", "findings": []}]},
      {"id": "ipad-en", "images": [{"state": "primary", "path": "ipad-en/screenshot.png", "digest": "sha256:8f5674ac5c3bdfa4bc63bf120ee8d6a7706598557fc99b51d37de343e7091e9d", "status": "passed", "findings": []}]},
      {"id": "ipad-ja", "images": [{"state": "primary", "path": "ipad-ja/screenshot.png", "digest": "sha256:5d173426722d981121aee0251e7c64a2b25797ea3fc154c06c4aaeb433e2ee62", "status": "passed", "findings": []}]}
    ],
    "findings": []
  },
  "acceptanceEvidence": [
    {
      "id": "AC-1",
      "status": "passed",
      "evidence": ["stage:build", "stage:unit-tests", "case:iphone-en", "case:iphone-ja"]
    },
    {
      "id": "AC-2",
      "status": "passed",
      "evidence": ["case:ipad-en", "case:ipad-ja", "visual:iphone-en", "visual:iphone-ja", "visual:ipad-en", "visual:ipad-ja"]
    }
  ],
  "completedAt": "2026-08-21T13:00:00+09:00"
}
```

`schemaVersion: 1` のapplication変更で必須となるfieldは、上の例にある `status`、`changeClassification`、`reason`、IssueとSHA、Issue contract path/digest、matrix path/digest、execution route、Xcode、Build、Tests、cases、visual evaluation、acceptance evidence、completed timeです。GitHubとproviderのpreflightは外部操作直前の証拠なのでverify.jsonへ含めず、pre-merge gateが別artifactとして検査します。

application変更のmatrixはbatch lifecycleが完成させたexact schemaです。top-levelは`schemaVersion`、`batchId`、`resolvedAt`、`xcode`、`runtime`、`cases`と任意の`scope`だけを持ちます。省略は`full`、`scope: iphone-ja`は1件で、nullや未知値は拒否します。caseは`id`、`family`、`deviceType`、`locale`、`language`、`udid`だけを持ち、contract・Evidenceとexact順序で一致させます。

検証時はGit top-levelから、Issueの信頼済みBase/HeadをJSONとは別の引数で渡します。

```bash
swift tools/validate-verify-json.swift \
  --file ".artifacts/issues/42/${HEAD_SHA}/verify.json" \
  --expected-issue 42 \
  --expected-base "${BASE_SHA}" \
  --expected-head "${HEAD_SHA}"
```

validatorは `--expected-head` が現在のGit Headと一致し、BaseとHeadが異なるcommitで、BaseがHeadの祖先であることを先に確認します。その後、verify.jsonのBase/Headが両引数と完全一致することを確認します。verify.json自身からGit検査範囲を選びません。verify.jsonは `.artifacts/issues/${issueNumber}/${headSha}/verify.json`、Issue contractは `.artifacts/issues/${issueNumber}/issue-contract.json`、matrixは `.artifacts/batches/${batchId}/simulator-matrix.json` のcanonical pathだけを許可します。

文書だけの変更では、次のexact representationを使います。省略したidentity、Issue contract、acceptance evidence、completed timeのfieldはapplication例と同じく必須です。

```json
{
  "schemaVersion": 1,
  "status": "not-applicable",
  "changeClassification": "documentation-only",
  "reason": "Only allowlisted Markdown documentation changed",
  "issue": 42,
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "issueContract": {
    "path": ".artifacts/issues/42/issue-contract.json",
    "digest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e"
  },
  "matrixFile": null,
  "matrixDigest": null,
  "executionRoute": "none",
  "xcode": null,
  "build": {"status": "not-applicable", "scheme": null, "warningsAdded": null, "project": null, "sourceTree": null},
  "tests": {"status": "not-applicable", "passed": null, "failed": null, "skipped": null},
  "cases": [],
  "visualEvaluation": {"status": "not-applicable", "findings": []},
  "acceptanceEvidence": [
    {"id": "AC-1", "status": "passed", "evidence": ["documents:spec consistency"]},
    {"id": "AC-2", "status": "passed", "evidence": ["links:swift tools/check-markdown-links.swift"]}
  ],
  "completedAt": "2026-08-21T13:00:00+09:00"
}
```

文書例外で許可する差分は、top-levelの `README.md` と `AGENTS.md`、`docs/` と `specs/` 以下のMarkdownだけです。NUL-safeなraw Git diffをrename検出なしで読み、追加・削除の両側を個別に検査します。Script、JSON、YAML、設定、asset、symlink、gitlink、実行bitを含むmode/type変更、allowlist外pathが一つでもあれば文書例外は使えません。文書例外はSimulatorやiOS Runtimeを必要としません。

`issueContract.fetchedAt` と `completedAt` は有効なISO 8601で、どちらも検証時刻から5分を超えて未来であってはいけません。さらに、`completedAt` は `fetchedAt` 以後でなければなりません。

PR本文にはverify.jsonの要約とdigestを記載します。shape／hardenではnot release-readyを明記します。反対モデルレビューを要求する`strict`／`release`では、`review.json`と`review-receipt.json`の対だけを正本として使います。

## 5. 実行手段

Codex環境でXcodeBuildMCPが利用できる場合、Project、scheme、Simulatorのsession defaultsを確認したうえでBuild、Test、UI操作、Screenshotを行います。利用できない場合は `xcodebuild` と `xcrun simctl` の決定論的なtoolsスクリプトを使います。

どちらの経路でも同じverify.jsonを生成し、実行経路を記録します。ツールが使えないことをTest成功へ読み替えません。

`executionRoute`は、visual-required CLIの`xcodebuild-simctl`、非visual shape／hardenの`xcodebuild-stage`、focused fastの`xcodebuild-focused`、文書例外の`none`を使います。

### 5.1 有界実行

すべての`xcodebuild`／Unit／UI Testは既定1200秒、`xcrun`／`simctl`は180秒、Swift validatorは600秒の有限timeoutを持ちます。各値は正の秒数へ明示overrideできます。timeout wrapperはcommandごとに新しいprocess groupを作り、そのgroupだけへTERM、5秒grace、必要時KILLを送ります。`killall`、Xcode終了、`simctl shutdown all`は行いません。

timeoutはexit 124と`stage`、`elapsedSeconds`、`timeoutSeconds`を返します。runnerはそのattemptのactive Simulator、private workspace、Issue／Head lockだけを回収し、成功形式の`verify.json`を発行しません。同じ原因は対象Testで診断したうえで最大2回までとし、同じ長時間検証を自動反復しません。

## 6. 排他制御

ソース実装は独立Issueなら並行化できますが、Simulatorを使う検証段階は既定で1ジョブずつ実行します。これにより、Boot状態、Locale、アプリデータ、Screenshotの取り違えを防ぎます。

各worktreeは専用DerivedDataを使います。検証中にHead SHAが変わった場合、結果を破棄して新しいSHAでやり直します。

## 7. Pre-merge条件

`tools/premerge-gate.sh --repo OWNER/REPO --issue NUMBER --head-sha SHA` は、最初にdescriptor-boundな `merge-state.rb validate-worktree` を再利用し、durable stateが `approved-for-merge` であることを確認します。その後、caller repository、Issue、Branch、symbolic ref、Head、Base ancestry、canonical worktree、clean状態が一致するまで `gh` を実行しません。

gateはprimary checkoutのartifactをpathごとに読み直しません。Issue artifact directoryを診断modeではshared lock、`--merge-pr` modeではexclusive lockしたうえで、`.artifacts`、`issues`、Issue、Head、`provider-preflights` とreview imageの各componentを `openat` と `NOFOLLOW` で開いたままにし、次のleafをregularかつsingle-linkとしてsnapshotします。

- `state.json`
- `issue-contract.json`
- `${headSha}/verify.json`
- `${headSha}/review-packet.json`
- `${headSha}/review.json`
- `${headSha}/review-receipt.json`
- `${headSha}/review.diff`
- schema v2 packetが列挙するordered review image
- `github-preflight.json`
- contractが要求する各provider preflight
- Issue worktreeの `Config/ownership.yml`

同じdescriptor bytesを最後まで使い、終了前にheld descriptor、現在のpath inode、component identity、bytesとmetadataが変わっていないことを再確認します。特に`state.json`は`validate-worktree`が返したexact bytes digestとdev、inode、size、mode、nlink、mtime、ctimeをGate helperが`gh`より前に照合し、descriptorを終了まで保持します。検証直後のinode swap、same-inode rewrite、primary implementerまたはtransition timestamp変更に加え、保持中のsame-byte rewriteによるmetadata変更も拒否します。Swift validatorは `--expected-file-digest sha256:...` を受け取り、別processであってもgateが保持した `verify.json` のexact bytesを読んだことを証明します。

そのうえで次を検査します。

- 現在のHead SHA = verify.jsonのheadSha
- review-requiredの場合、現在のHead SHA = review.jsonのheadSha
- verify status = passedまたは正当なnot-applicable
- review-requiredの場合、review verdict = approved
- review-requiredの場合、schema v2 packet／result／receiptのexact bytes、Base／Head／Verify SHA、model、Issue contract digestが一致
- review-requiredの場合、approved reviewのFinding = 0、全Acceptance criteria = supported、`reviewedAt`がverify完了後かつ未来でない
- Acceptance criteriaの証拠欠落 = 0
- `gh issue view`のfixed fieldsがcaller Issueと一致し、許可されたIssue typeがexact一つ存在
- live Issue本文をshared Issue parserで再構成したcanonical contract bytesが `issue-contract.json` と完全一致
- Provider外部操作はproviderごとに一つ以下で、exact operationとenvironmentがIssueの五field operation blockに一致し、account/target、health、timestamp、digestが安全
- Providerのexecutor/account/targetはIssue contractと`Config/ownership.yml`のexact case-sensitive値に一致する。Supabaseは`organizationId`/`projectRef`、Cloudflareは`accountId`/`target`、Linearは`workspaceSlug`/`teamKey`、Vercelは`teamId`/`teamSlug`、ElevenLabsは`accountId`/`workspaceId`、App Store Connectは`teamId`/`bundleId`へ対応し、必要なtargetがnullまたは未設定ならfail closed
- Issue contractが`github.merge_pr`を宣言し、live Issueから再構成した構造化operation details digestもcanonical snapshotと一致
- `github-preflight.json`のaccountが`Config/ownership.yml`のloginと一致し、repository owner、`main`、URL、`github.merge_pr`、Issue、Head、digestが完全一致
- GitHub preflightがverify完了、review完了、`approved-for-merge` transitionのすべてより新しく、許容未来時刻を超えない

一つでも不一致ならマージしません。

診断用の上記commandはread-onlyです。最終mergeだけは `tools/premerge-gate.sh --repo OWNER/REPO --issue NUMBER --head-sha SHA --merge-pr PR_NUMBER` を使います。このmodeは全artifact descriptorとIssue directory lockを保持した同一process内でactive personal account、repository identity、fixed-field PR identityを再取得し、再度held path/inode/bytes/metadataとactual diffを照合してから、exact `gh pr merge PR_NUMBER --repo OWNER/REPO --squash --match-head-commit SHA` を実行します。Gate成功後に別processでPRを読み直してmergeする経路は禁止です。
