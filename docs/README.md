# iOS-Template

CodexとClaudeを同等の実装・外部操作担当として使う個人向けiOS開発テンプレートです。仕様、Issue、ブランチ、リスクに応じた検証・レビュー、PR、Squash Mergeまでを一貫したワークフローとして扱います。

通常の開発はClaudeとCodexのどちらでも進められます。3Dモデルの作成・生成・形状変更は[iOS 3D assets skill](../.agents/skills/ios-3d-assets/SKILL.md)に従い、ユーザーまたはClaudeがブラウザでTripoを操作して作るのを標準とします。簡単なモデルや即効性を求める場合だけ、ClaudeまたはCodexの`gpt-6-astra`（reasoning effort `xhigh`）に依頼します。

Foundation は利用可能です。最小の SwiftUI アプリ、Unit/UI Test、英語・日本語、iPhone・iPad、共有仕様スキル、Codex/Claude 共通責務の read-only 評価エージェントを含みます。運用自動化は [実装計画索引](./superpowers/plans/README.md) に従って段階的に追加します。

開発順序は**条件に該当すればHTMLでUI方向を比較・選択する → shapeで日本語iPhoneの主要導線を動かす → hardenで必要な品質を対象別に固める → releaseで完全検証する**です。現在のユーザーによる対象範囲のHTML比較指示を最優先し、それ以外では対象範囲のUI方向が未確定で、初回のユーザー向けUI、ルートnavigation／information hierarchyの新設・変更、主要flowの大幅な再設計のいずれかに該当するときだけ比較Gateを必須にします。[段階的開発仕様](../specs/development-stages.md)に従い、通常UIのshapeは既定120分・`standard` + `iphone-ja`、hardenは`targeted`、releaseは`strict` + `full`で検証します。文字列管理・可変レイアウトと安全の土台は初期から維持します。既存のClaim済みIssueは自動で縮小せず、旧release-level契約を維持します。

## 固定版App Store Connect CLI

`tools/install-asc-cli.sh`は`Config/asc-cli.json`の固定版ascをchecksum照合後にrepository外へ配置します。利用時は`tools/asc-run.sh --operation appstore.inspect_app -- apps list`を入口とし、起動ごとにversion／digestを確認、JSON出力と120秒上限を強制します。operationは`appstore.inspect_app`、`appstore.update_metadata`、`appstore.upload_build`、`appstore.submit_review`、`appstore.distribute_testflight`の5種類で、operationごとに許可するsubcommandとflagを固定しています。一覧は[security手順](./security.md#固定版ascの利用)を正とします。

秘密は[security手順](./security.md#固定版ascの利用)に従い、Key ID／Issuer IDをApple teamごとのKeychainへ、Team keyの`.p8`をteamの専用ディレクトリ直下の`app-store-connect-production.p8`へ、teamごとに一度だけ置きます。runnerは既存wrapperから子process envへだけ渡し、ascのHOME／configを隔離して出力をredactします。`tools/tests/test-asc-cli.sh`はfake binaryによるoffline回帰です。基盤の検証成功は実install、live API、release readinessを証明せず、production preflightとlive実行の権限確認は別途必要です。

TestFlight group配信とbeta app review提出の条件は[TestFlight配信契約](./agent-contracts/testflight-distribution.md)を参照してください。

## Foundation の検証

リポジトリ方針は次で検証します。

```sh
tools/tests/test-foundation.sh
```

Issueには、成熟度を表す`shape`／`harden`／`release`のDelivery stageとTime budget、危険度を表す`fast`／`standard`／`strict`のdelivery profileを別々に指定します。shapeはBuild・重要Unit Test・日本語iPhone 1条件のSmoke、hardenは対象Testと指定caseだけ、releaseは従来の完全検証です。`strict`または`release`だけがblockingな反対モデルレビューを要求します。stage未指定の既存contractは従来のprofile／scope gateを維持し、profile未指定はstrict、検証範囲未指定はfullとして扱います。以下はrelease/full検証の手順例です。

Foundationやdelivery gate自体は`strict`です。Build と Test は、インストール済み Xcode から [標準 Simulator マトリクス](./verification.md#3-固定されるmatrix)を解決し、Issue バッチ内で固定して実行します。次は Foundation 検証で使うコマンド形です。`TEMPLATE_IPHONE_UDID` と `TEMPLATE_IPAD_UDID` には、`Config/dedicated-simulators.json`が宣言するrepository専用の2台（iOS 27.0のiPhone 17 Pro MaxとiPad Pro 13-inch (M5)）のUDIDを指定します。Templateでは`iOS-Template iPhone 17 Pro Max`と`iOS-Template iPad Pro 13-inch (M5)`、派生アプリでは表示名を前置した同じ機種です。

```sh
TEMPLATE_IPHONE_UDID="<dedicated-iPhone-17-Pro-Max-UDID>"
TEMPLATE_IPAD_UDID="<dedicated-iPad-Pro-13-inch-M5-UDID>"
TEMPLATE_DERIVED_DATA=$(mktemp -d /tmp/ios-template-derived-data.XXXXXX)
TEMPLATE_RESULT_BUNDLES=$(mktemp -d /tmp/ios-template-result-bundles.XXXXXX)
trap 'rm -rf "$TEMPLATE_DERIVED_DATA" "$TEMPLATE_RESULT_BUNDLES"' EXIT
source tools/lib/xcode.sh
resolve_xcode_environment

run_xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPHONE_UDID}" \
  -derivedDataPath "${TEMPLATE_DERIVED_DATA}" \
  -resultBundlePath "${TEMPLATE_RESULT_BUNDLES}/unit-tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test -only-testing:TemplateAppTests

run_xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPHONE_UDID}" \
  -derivedDataPath "${TEMPLATE_DERIVED_DATA}" \
  -resultBundlePath "${TEMPLATE_RESULT_BUNDLES}/iphone-english.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testEnglishWelcomeTitle

run_xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPHONE_UDID}" \
  -derivedDataPath "${TEMPLATE_DERIVED_DATA}" \
  -resultBundlePath "${TEMPLATE_RESULT_BUNDLES}/iphone-japanese.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testJapaneseWelcomeTitle

run_xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPAD_UDID}" \
  -derivedDataPath "${TEMPLATE_DERIVED_DATA}" \
  -resultBundlePath "${TEMPLATE_RESULT_BUNDLES}/ipad-english.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testEnglishWelcomeTitle

run_xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPAD_UDID}" \
  -derivedDataPath "${TEMPLATE_DERIVED_DATA}" \
  -resultBundlePath "${TEMPLATE_RESULT_BUNDLES}/ipad-japanese.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testJapaneseWelcomeTitle
```

### canonical検証

Issueの完了判定に使う検証は、上の手作業のコマンドではなく`tools/verify-ios-issue.sh`がrepository専用の2台で実行します。各caseの前に専用deviceをeraseし、testは`-parallel-testing-enabled NO`で実行します（D-063、D-070）。

証拠の形式、画像評価、Head SHA 一致条件は [iOS verification](./verification.md) を正とします。Simulator のUDIDと結果ファイルは環境固有なのでGitへ追加しません。

## 新しいアプリとして使い始めるとき

- Xcodeが生成した個人のSigning Teamは初期値として残しています。別の所有者が利用する場合は、XcodeのSigning & Capabilitiesで自分のTeamへ変更します。`Config/ownership.yml` のApp Store Team IDとBundle IDは、アプリ固有の提出先が決まるまで`null`のままにします。
- Deployment Targetはテンプレート生成時のXcode既定値です。対象ユーザーと必要APIを決め、実装Issueを始める前にアプリ固有の最小OSを仕様とXcode設定へ固定します。
- ローカル設定は `Config/Local.xcconfig.example` を参考に、Git管理外の `Config/Local.xcconfig` へ置きます。秘密値はxcconfigへも保存せず、Keychainまたは各サービスの秘密管理を使います。

### GitHub workflow initialization

テンプレートから新しいアプリのリポジトリを作成した直後、最初のIssueを起票する前にCodexまたはClaudeが`Config/ownership.yml`のGitHubアカウントと対象リポジトリを確認し、workflow labelsを一度同期します。この操作は冪等で、既存の正しいlabelは変更しません。

```sh
REPO='OWNER/REPO'
tools/sync-github-labels.sh --repo "$REPO" --executor codex # または claude
```

その後、アプリ固有の目的・方向性と最小仕様を`specs/`で確定し、Foundation、Identity bootstrap、Simulator verificationの3つのBootstrap Issueを依存順に起票します。Issue作成後にだけ各Branch/worktreeを作り、Identity bootstrapが完了するまでFeature実装を開始しません。Identity bootstrap後はApp Icon IssueとSystem Experiences Planning Issueを作成でき、前者は最初のユーザー向けUIより先に、後者は主要Feature Issueの計画・Claim前に完了します。両者は独立なら並行できます。

### Identity bootstrap

機能開発より先に、表示名、Swiftモジュール名、lowercase kebab-caseのアプリSlug、逆DNS形式のBundle IDという4つのIdentity入力を確定します。Deployment Targetはこれらと分けてアプリ仕様とXcode設定へ確定します。承認済みのIdentity Bootstrap Issueに対応するクリーンな非default Branch/worktreeで、リポジトリルートから次を実行します。

```sh
tools/bootstrap-app.sh \
  --display-name 'Garden Notes' \
  --module-name GardenNotes \
  --app-slug garden-notes \
  --bundle-id com.yuto.GardenNotes
```

コマンドは、Xcode project、Target、Scheme、Swift Module、Test、Bundle ID、設定、現行文書を一つのIdentityへ変換し、確認用の変更をunstagedで残します。標準出力は`applied`と結果パスを含むsanitized JSONで、非秘密の完全な結果は`Config/app-identity.json`へschema version 1として保存されます。

通常の`git diff`だけでは新しいuntracked fileを表示しないため、次のread-only手順でstatus、tracked diff、untracked fileをすべて確認します。`git diff --no-index`の終了値`1`は差分を表示した正常結果として扱い、それ以外の非zeroだけを失敗にします。この確認ではbootstrap出力をstageせず、indexを変更しません。

```sh
git status --short --untracked-files=all
git diff --
while IFS= read -r -d '' path; do
  git diff --no-index -- /dev/null "$path" || {
    status=$?
    [[ "$status" -eq 1 ]] || exit "$status"
  }
done < <(git ls-files --others --exclude-standard -z)
```

Identity Bootstrapはdelivery gateを変えるrelease/strict Issueなので、すべての差分と結果recordを確認してからFoundation、bounded Xcode検証、4条件Simulator、反対モデルレビューを実行してください。共通の手順は[App Bootstrap skill](../.agents/skills/app-bootstrap/SKILL.md)を正とします。

同じ4入力で再実行すると`already-complete`を返して何も変更しません。1値でも異なる再実行は、既存結果と競合するため変更前に失敗します。GitHub上のリポジトリ名変更とApple側のBundle ID登録はこのコマンドに含まれず、Issueで指定された実行モデルが設定済みアカウントを確認して別操作として行います。

### App icon

アプリの目的・方向性と4つのIdentity入力が確定し、Identity bootstrapがマージされたら、最初のユーザー向けUI `shape`より前に[App Icon skill](../.agents/skills/app-icon/SKILL.md)を使います。同じ確定briefから画像生成した、意味が異なるシンプルな2案をstable concept ID付きで提示し、ユーザーが明示選択した1案だけを採用します。組合せや重要な修正は新しいimmutable revisionとして再生成し、提示済み候補を上書きしません。

既定のデザインは一つの認識しやすい主題、単純な背景、少ない形と色、十分な小サイズ判別性を持ち、文字、イニシャル、数字、スクリーンショット、Apple製品の複製、第三者mark、watermark、焼き込んだ角丸、細かい装飾を避けます。生成直前に[Apple公式App icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons)を再確認します。

選択後、App Icon Issueのクリーンな非default Branch/worktreeで次を実行します。

```sh
tools/install-app-icon.sh \
  --root "$PWD" \
  --source "/absolute/path/to/selected-concept.png" \
  --concept-id concept-a \
  --prompt-file "/absolute/path/to/selected-prompt.txt" \
  --generator builtin-imagegen

tools/validate-app-icon.sh --root "$PWD"
```

installerは`Config/app-identity.json`から対象moduleを解決し、1024 x 1024、実透明pixelなし、system mask前の正方形PNGだけをdefault AppIconへ設定します。選択済みPNG、Asset Catalogの`Contents.json`、sanitizedな`Config/app-icon.json`だけを同じcommitへ含め、候補やpreviewは`.artifacts/app-icon/`へ残してGit管理しません。アプリアイコン選択は画面階層、navigation、主要flowの承認ではなく、UI Direction Gateを満たしたことにもなりません。選択待ちでも独立した非UI作業は続行できます。

### System Experiences Planning Gate

Identity bootstrap後、主要Feature Issueを計画・Claimする前に[System Experiences Planning skill](../.agents/skills/ios-system-experiences/SKILL.md)を使います。Widget、Live Activities、Dynamic Island、Controls、Siri／App Intentsの5面をそれぞれ`adopt-now`、`defer`、`not-applicable`、`blocked:user`へ分類し、空欄や暗黙の非対応を残しません。評価は必須ですが採用は任意で、最終判断はユーザーが行います。

実行時にApple公式資料を再取得し、確認日時、URL、availability、constraintsをplanning recordへ記録します。採用する面だけを共有foundation／surface別実装／harden／release Issueへ分け、Xcode project、extension、entitlement、App Group、signingの重複write-setを直列化します。App Icon Issueとは並行できますが、採用するsystem UIはplanning Issueへ依存し、別途UI Direction Gateとnative検証を通します。`blocked:user`は判断に依存するIssueだけを止め、独立した非UI作業を止めません。テンプレートAppへsystem framework、target、entitlementを先行追加しません。

### Feature開発開始ゲート

Feature IssueのBranch/worktreeを作る前に、アプリ固有の`specs/product.md`と`specs/acceptance.md`がともに`Status: 確定`で、そのIssueの受け入れ条件と一致していることを確認します。Identity bootstrap後の主要Featureでは、完了済みSystem Experiences Planning Issueと確定した5面のdecision matrixも確認します。未作成、確定前、または不一致なら、実行モデルがIssueを`blocked:user`へ遷移させ、Branch/worktree作成と実装を開始しません。最初のユーザー向けUI `shape`は完了済みApp Icon Issueにも依存し、採用するsystem UIはplanning Issueにも依存しますが、独立した非UI Featureはこれらの選択を待たずに進められます。

現在のユーザーが対象範囲のHTML比較を明示した場合は、確定済み方向の有無にかかわらず[UI Direction skill](../.agents/skills/ui-direction/SKILL.md)を最優先で使用します。明示省略は現行性、scope、権限、理由が明確で比較指示と矛盾しないときだけ通常判定を上書きします。それ以外は、exact hierarchy／flowを覆う確定方向があればconfirmed-direction reuse、覆う方向がなく対象方向が未確定かつ最初のユーザー向けUI、ルートnavigation／information hierarchyの新設・変更、主要flowの大幅な再設計のいずれかならGate、方向未確定かつ構造triggerなしならAcceptance criteriaがhierarchy、navigation、primary-flow interactionを決めない範囲だけbounded direction-neutralとします。coverage／trigger／neutralityが曖昧ならGateを実行します。

比較では同じ要件と合成dataで2〜3個の自己完結HTML案を作ります。共通選択記録はscope、artifact path／revision、提示bytesのexact SHA-256、採用・不採用要素、screen／state、native適応範囲を持ち、単一案はselected concept ID、hybridは全採用要素からsource concept IDへのexhaustive mappingを持ちます。selected／base concept IDはhybridのbaseをユーザーが明示した場合だけ記録します。この確定仕様と追記型DecisionをmergeしてからdependentなSwiftUI `shape` IssueをClaimします。

cutover後にClaimするcontractは、既存のAcceptance criteria全体でexactly oneの有効なroute宣言を持ちます。一つのAcceptance criterion本文の先頭（`AC-*:`の直後）をexact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`で開始し、`<route>`には`comparison`、`explicit-skip`、`confirmed-direction reuse`、`bounded direction-neutral`、`not-applicable`だけを使います。route固有の事実はReasonの後へ続け、prefix外のroute語は宣言として数えません。確定anchorを`Spec anchors`、選択前提をDependenciesへ置きます。UI Issueの3 field `UI verification`はlive guidanceであり封印されないため、routeの正本にはしません。cutover後のIdentity bootstrapと純粋な非UI作業は`not-applicable`を宣言してUI方向anchorを必要とせず、`UI verification`本文をexact `Not applicable`だけとし、scope／非UI理由をGoal／In scope等と宣言へ、関連する確定済みproduct／spec anchorを`Spec anchors`へ記録して、後続UIだけをGate判定します。

D-030 cutoverは`2026-09-06T00:31:41Z`です。封印済みcontractの`fetchedAt`がこれより前で、Acceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補がゼロの場合だけpre-D-030 legacyとし、routeやHTMLを遡及要求せず元の封印済みAC／spec／evidenceをreviewします。cutover前でも候補が一つ以上あれば通常検証へ進み、候補がexactly oneで許可routeと非空Scope／Reasonを持つ完全な宣言でなければrejectします。cutoverと同時刻以降のcontractとcutover後のpre-Claim Issueにも同じexactly-one／完全性を要求します。legacy contractは変更・再封印せず、prefix外のroute語は候補として数えません。

HTMLは情報階層や操作仮説を早く比較するための資料です。製品の正本、CSS pixel仕様、WKWebView実装、またはnativeなBuild／Test／Simulator証拠として扱いません。

### 派生アプリからテンプレートへの改善報告

派生アプリで共通化できる不具合や改善を見つけた場合は、[Template Issue reporting skill](../.agents/skills/report-template-issue/SKILL.md)を使います。発見元と報告先`yuto1201/iOS-Template`を分け、current templateとの比較、open／closed Issueの重複確認、現行本文validator、外部操作権限の順に確認します。共通性や権限を確認できない場合はlocal draftまでに留め、Issue作成をテンプレート修正や派生アプリへの反映完了とは扱いません。

## 条件付き統合と秘密管理

Supabase、AdMob、ElevenLabs、Cloudflare、分析、StoreKit、通知などは Foundation のアプリ本体へ組み込まれていません。必要性を確定仕様と Issue の受け入れ条件に明記した場合だけ、別 Issue で有効化します。テンプレートの状態では root `supabase/`、外部 SDK、認証済み接続を持たず、不要なサービスの保守や権限を発生させません。

- データベース、認証、同期、Storageが必要なアプリでは [Supabase operations skill](../.agents/skills/supabase-ops/SKILL.md)を使用します。`Status: 確定`かつ`Supabase: required`の仕様だけが有効化でき、`supabase/migrations/`を唯一のスキーマ履歴としてRLSとPolicyを同時に追加します。CodexとClaudeのどちらもlocal／remote作業を実行できますが、remoteではOrganization IDとProject Refを照合します。
- 広告収益化を確定した派生アプリだけが、[AdMob monetization skill](../.agents/skills/admob-monetization/SKILL.md)と[条件付きAdMob契約](../specs/product.md#41-条件付きadmob収益化)に従ってUMPと非trackingのanchored adaptive bannerを有効化できます。`tools/activate-admob-integration.sh --root <app-root> --input <confirmed-input.json>`は未決入力を変更前に拒否し、公式SPMのexact version、Debug demo／UI Test offline／Release固有ID、consent／eligibility／banner境界を派生アプリだけへ原子的に追加します。適用後は`tools/validate-admob-integration.sh --root <app-root>`でdriftを検査します。未採用出力にSDK／設定／広告sourceを追加せず、shapeのoffline成功をrelease-readyやlive配信成功へ読み替えません。AdMob Console、契約／支払／税務、app-ads.txt、App Store Connectは別の外部操作です。
- 買い切りの非消耗型商品（例: 広告非表示）を確定した派生アプリだけが、[条件付きStoreKit契約](../specs/product.md#42-条件付きstorekit非消耗型権利)に従ってStoreKit 2の購入、復元、Offer Code入力を有効化できます。権利はverifiedかつ未失効のtransactionだけから判定し、広告非表示ではAdMobの`adFreeEntitlement`へ権利の値だけを渡します。契約の確定だけで実装済みと扱わず、実装とその証拠は後続Issueのcurrent-Head成果を要求します。App Store Connectのproduct作成、価格、税務、契約、IAP審査提出、Offer Code発行は別の外部操作です。
- 読み上げ、Voice Changer、文字起こし、効果音、音声分離、音楽、一般画像、動画が必要な場合は [iOS media assets skill](../.agents/skills/ios-media-assets/SKILL.md)を使用します。実行モデルが設定済みElevenLabs Account／Workspaceとmode別entitlementを先に確認し、受理した出力とsanitized manifestだけを統合します。必須アプリアイコンだけは前述の`app-icon`とbuilt-in画像生成を使い、そのためにElevenLabsを有効化しません。
- 3Dモデル、mesh、material、rig、animationの作成・生成・形状変更が必要な場合は [iOS 3D assets skill](../.agents/skills/ios-3d-assets/SKILL.md)を使用します。標準はユーザーまたはClaudeがブラウザでTripoを操作して作る経路で、Tripoのログイン、プランや課金の変更、認証情報の入力はユーザーが行います。簡単なモデルや即効性を求める場合は、ClaudeまたはCodexの`gpt-6-astra`（reasoning effort `xhigh`）に依頼します。どの経路でも形式検証、組み込み、RealityKit側の実装、Build／Test、視覚確認を行い、Issue／PR証拠にauthoringの経路を記録します。
- GitHub、Supabase、Cloudflare、Linear、Vercel、ElevenLabs、App Store Connectを含む認証済み外部操作は、CodexとClaudeが同じ [external operations skill](../.agents/skills/external-ops/SKILL.md)を使い、実行直前に設定済みアカウントと対象を照合します。
- 一行の秘密値はmacOS Keychainへ保存し、`tools/run-with-secret.sh`が子プロセスの環境だけへ渡します。App Store Connectの`.p8`はApple teamごとに一つだけ`~/Library/Application Support/iOS-Template/secrets/apple-team-<teamId>/app-store-connect-production.p8`へ置き、`0700`ディレクトリ／`0600`ファイルだけを`tools/run-with-private-key.sh`で使用します（D-066）。取得値を表示するコマンドはなく、`.secrets/`と`secret-staging/`もGit管理外です。

## App Store リリース素材

`App Store/`は、英語・日本語metadata、privacy宣言、privacy policyとtermsの原稿、review notes、release notes、最終screenshots、提出チェックリストを一括管理する非秘密の正本です。テンプレートのURLと法務文書は未確定、画像は未生成なので、そのまま提出可能という意味ではありません。現在の公開要件は`App Store/submission/requirements.json`へ取得日時・参照元とともに固定し、準備時に期限切れなら実行モデルがApple公式資料から更新します。

リリース候補がBuild/Test済みになったら [prepare-appstore-assets skill](../.agents/skills/prepare-appstore-assets/SKILL.md)で、実際の仕様から文面を生成し、repository専用の2台（App Storeの必須画像サイズで撮影できるiPhone 17 Pro MaxとiPad Pro 13-inch (M5)）で英日・iPhone/iPad画像を撮影します。全画像とprivacy/legal/metadataを`release-auditor`が同一SHA・同一build digestで承認し、初回公開時はユーザーがprivacy policyとtermsを確認した後だけ、変更検知可能なpackage manifestを作ります。

提出は [submit-appstore-release skill](../.agents/skills/submit-appstore-release/SKILL.md)をIssueで指定されたCodexまたはClaudeが実行します。実行モデルが設定済みTeam、App、Bundle ID、version、buildを確認し、App Store Connectへセクション単位で入力・保存・再読込します。

## 最初に読む文書

1. [仕様索引](../specs/README.md)
2. [プロダクト方針](../specs/product.md)
3. [テンプレート構成](../specs/architecture.md)
4. [受け入れ条件](../specs/acceptance.md)
5. [決定ログ](../specs/decisions.md)
6. [権限境界](./AUTHORITY.md)
7. [Issue からマージまでの運用](./workflow.md)
8. [秘密管理](./security.md)
9. [Simulator 検証](./verification.md)
10. [公式資料](./references.md)

## 設計の由来

- `Flower`: Issue 単位の証拠管理、視覚評価、作業完了ゲート
- `Elsefolk`: 仕様の確定・提案・未決の分離、決定ログ、実測を伴う完了報告
- `CafLog`: 日本語・英語対応、iPhone・iPad、App Store 用素材の管理
- 現行の確定方針: CodexとClaudeは同じ外部操作権限を持ち、`Config/ownership.yml`の設定済みアカウントだけを使用する

参照プロジェクト固有の画面、データモデル、アーキテクチャ、`CLAUDE.md` は継承しません。

## 基本原則

- 仕様が未決のまま実装を開始しない。
- 1 Issue = 1 Branch = 1 PR とする。
- AI がDelivery stageとdelivery profileに必要な検証・レビュー、修正、PR、Squash Mergeまで進める。
- ユーザーによる実機確認は、AI の Definition of Done の後に行う最終確認とする。
- 外部アカウント操作はIssueで指定されたCodexまたはClaudeが、設定済みidentityのpreflight後に行う。
- 秘密値は Git、Issue、PR、ログ、スクリーンショット、AI プロンプトに残さない。

## Issue 自動運用とリカバリー

次のコマンドは `OWNER/REPO`、Issue番号、担当モデルを確定してから実行します。Claim は承認済みIssueに正規Branch/worktreeと共有証拠領域を一度だけ作り、同じ担当者による再実行は Resume になります。明示的な再開だけを行う場合は `resume-issue.sh` を使います。

```sh
REPO='OWNER/REPO'
ISSUE=42

tools/issue-state.sh get --repo "$REPO" --issue "$ISSUE"
tools/claim-issue.sh --repo "$REPO" --issue "$ISSUE" --agent codex
tools/resume-issue.sh --repo "$REPO" --issue "$ISSUE"
```

Issue worktreeで対象確認を終え、差分が安定してから現在のcommitを直接解決し、その同じSHAへcanonical Verifyを結び付けます。shapeは日本語iPhone 1条件、hardenはtargeted部分集合、releaseは完全Simulator matrixを使用します。非releaseのstandard shape/hardenとexplicit fastは`verify-passed`から直接`approved-for-merge`へ進み、strictまたはreleaseだけがreview packetと反対モデルreviewを使用します。ドキュメントだけの変更は`publish-documentation-verify.sh`を使い、Simulator成功を意味しません。

```sh
HEAD_SHA="$(git rev-parse HEAD)"
BASE_SHA="$(jq -r '.baseSha' ".artifacts/issues/$ISSUE/state.json")"

tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" \
  --from in-progress --to verify-passed --head-sha "$HEAD_SHA"

# review不要: explicit fast、または非releaseのstandard shape/harden
tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" \
  --from verify-passed --to approved-for-merge

# review必須: strict、release、またはstage未導入のlegacy contract
tools/prepare-review-packet.sh --primary codex --issue "$ISSUE" \
  --base-sha "$BASE_SHA" --head-sha "$HEAD_SHA"
tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" \
  --from verify-passed --to review-requested
tools/cross-model-review.sh --primary codex \
  --packet ".artifacts/issues/$ISSUE/$HEAD_SHA/review-packet.json" \
  --output ".artifacts/issues/$ISSUE/$HEAD_SHA/review.json"
```

マージ診断はmutationを行わないGateを先に実行します。strict／releaseでは承認済みreview、すべてのcontractでは現在Headのstage別Verifyと最新のaccount preflightが揃った後、Issueで指定された実行モデルがPR作成、Squash Merge、正確なBranch/worktree cleanup、`done`遷移まで行います。shape/hardenのPRは必ずnot release-readyと明記します。

```sh
tools/github-account-preflight.sh --repo "$REPO" --issue "$ISSUE" \
  --intended-operation github.merge_pr --expected-head "$HEAD_SHA"
tools/premerge-gate.sh --repo "$REPO" --issue "$ISSUE" --head-sha "$HEAD_SHA"
tools/merge-issue.sh --repo "$REPO" --issue "$ISSUE"

# primary checkoutで実行
tools/cleanup-issue.sh --repo "$REPO" --issue "$ISSUE"
tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" \
  --from merged --to done
```

`blocked:*` または `paused` は失敗の隠蔽ではなく、直前状態を `resumeState` としてmarkerへ残す停止状態です。原因を直した後は担当者を変えず、まず `issue-state.sh get` が返すexact `resumeState`へ `issue-state.sh transition --from <current> --to <resumeState>` で明示的に復帰し、その後 `resume-issue.sh` でlocal stateを再構築して同じstateを再dispatchします。`resume-issue.sh` 自体はGitHub labelを変えません。成功が不明な外部操作は別コマンドへ進まず同じコマンドを再実行します。Headを変更した場合は `approved-for-merge`、`changes-requested`、または `verify-passed` から `in-progress` へ戻し、新しいHeadのVerifyとreviewを両方作り直します。

## Goldieでストア用スクショを作る

Codexに「Goldieでストア用スクショを作って」と依頼できます。
[使い方](./goldie.md)と[スキル](../.agents/skills/goldie/SKILL.md)を参照してください。
日本語・英語の原稿と実際のアプリ画像を使い、背景・見出し・端末枠を調整します。
導入のみ、既存画像の装飾、撮影、動画を依頼に合わせて実行します。
