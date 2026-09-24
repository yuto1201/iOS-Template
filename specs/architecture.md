# テンプレート構成

Status: 確定  
Version: 1.9
Date: 2026-09-17

## 1. 設計原則

- Xcode の標準構成から大きく離れない。
- 共通運用は厚く、アプリ固有コードは薄く保つ。
- ディレクトリは責務が発生した時点で追加し、空の抽象層を作らない。
- 仕様、運用、実行手順、生成証拠を混在させない。
- Codex と Claude の機能名は揃え、ネイティブ形式だけを分ける。
- 一般開発のClaude／Codex同等性を維持し、3D asset authoringだけをCodex `gpt-6-astra`へ固定する。モデル固有routeは共有skillへ閉じ込め、アプリ本体のarchitectureを実行モデルへ依存させない。

## 2. 完成時のルート構成

```text
iOS-Template/
├── AGENTS.md
├── README.md
├── TemplateApp/
├── TemplateAppTests/
├── TemplateAppUITests/
├── TemplateApp.xcodeproj/
├── specs/
├── docs/
│   ├── agent-contracts/
│   └── superpowers/plans/
├── tools/
├── Config/
│   ├── Public.xcconfig
│   ├── Local.xcconfig.example
│   └── ownership.yml
├── App Store/
├── .agents/skills/
├── .codex/agents/
├── .claude/
│   ├── agents/
│   ├── skills/
│   ├── hooks/
│   └── settings.json
├── .github/
│   ├── ISSUE_TEMPLATE/
│   └── pull_request_template.md
└── supabase/                 # データベースが必要なアプリだけ
```

`TemplateApp` は最小の SwiftUI アプリ、Unit Test、UI Test だけを持ちます。サンプル機能、ダミー課金、ダミーAPI、使われないサービス層は含めません。

### 2.1 Identity Bootstrap境界

新しいアプリ用リポジトリでは、`TemplateApp`をFeature実装のまま残しません。共有bootstrapは、検証済みの入力と`Config/template-identity.json`を正本として、次のアプリ固有Identityだけを変換します。

- `.xcodeproj`、Target、Product、共有Scheme
- App、Unit Test、UI Testのディレクトリ、Swift型、Module import、Bundle ID
- `README.md`の実行例、`AGENTS.md`のリポジトリ見出し、現行仕様のアプリ固有パス
- `Config/ownership.yml`の将来のApp Store対象Bundle ID
- 変換結果を固定する`Config/app-identity.json`

履歴として残すFoundation実装計画、汎用スキル名、`iOS-Template`の秘密保存namespace、Simulator管理prefixなど、テンプレートの運用Identityは一括置換しません。変換はクリーンな非default Branchから開始し、隔離された一時worktreeで全変更を検証してから、検証済みpatchだけを呼び出し元へ適用します。

### 2.2 App Icon境界

テンプレート自身には将来のアプリ固有アイコンを同梱しない。Identity bootstrap後の専用App Icon Issueで画像生成候補を作り、ユーザーが明示選択した1案を次へ保存する。

```text
${ModuleName}/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
Config/app-icon.json
```

`Config/app-icon.json`はdisplay name、stable concept ID、sanitized prompt summary、generator、寸法、format、asset path、exact SHA-256を持つ非秘密の採用recordとする。preselection／rejected候補、prompt revision、small-size previewは`.artifacts/app-icon/`へ置きGit管理しない。installerは`Config/app-identity.json`からmodule pathを解決し、caller指定pathから別Targetへ書かない。

Asset Catalogへはsystem mask前の正方形かつ不透明な1024 x 1024 PNGをdefault iconとして設定し、既存のdark／tinted appearance entryを削除・置換しない。App Icon Issueは画面階層、navigation、primary-flow interactionを決めないため、その選択はUI Direction Gateの代わりにならない。

## 3. iOS ソースの初期構成

```text
TemplateApp/
├── TemplateAppApp.swift
├── ContentView.swift
├── Assets.xcassets/
├── Localizable.xcstrings
└── Preview Content/          # Xcode が作成した場合だけ保持
```

機能が生まれたら、機能単位で View、Model、Service、Repository を近くに置きます。次のディレクトリは必要になった時だけ追加します。

- `Features/${FeatureName}/`: 複数ファイルを持つ独立機能
- `Shared/`: アプリと Extension が共有するコード
- `DesignSystem/`: 3画面以上で反復利用する視覚トークンや部品
- `Data/`: 複数機能で共有する永続化・Repository実装
- `Domain/`: 複数機能で共有し、UIや永続化に依存しない規則
- `Extensions/`: Widget、Share Extension などのターゲット別ソース

View から Supabase SDK、SwiftData の複雑な問い合わせ、外部生成APIを直接呼びません。テスト可能な境界を設けますが、1画面だけのアプリに過剰な層を導入しません。

UI Direction Gateで選択したHTML conceptをアプリへ同梱せず、`WKWebView`を製品UIの代替にしません。SwiftUIは選択済みspecのinformation hierarchy、flow、state intentをnative componentへ翻訳し、Safe Area、可変layout、Dynamic Type、VoiceOver、keyboard、navigationとsheetのplatform semanticsを実装側で満たします。HTMLのCSS pixel値はsource architectureではありません。

### 3.1 System Experiences設計境界

Identity bootstrap後、主要Feature Issueの計画またはClaimより前に、`widget`、`live-activities`、`dynamic-island`、`controls`、`siri-app-intents`の5面をSystem Experiences Planning Gateで評価する。評価は全アプリで必須だが、framework、Extension target、entitlementをテンプレートへ先行導入しない。各面を`adopt-now`、`defer`、`not-applicable`、`blocked:user`へ分類し、採用範囲はユーザーが最終決定する。

`adopt-now`の面だけを専用Issueへ分け、必要になった責務だけを追加する。

```text
Shared/
├── Domain/                  # appとsystem surfaceが共有するdomain action／value
└── Data/                    # 必要な場合だけ共有するsnapshot／repository境界
Extensions/
└── ${SurfaceName}/          # WidgetKit等のextension process固有UIとtimeline
AppIntents/                  # App Intent、entity、query、shortcut定義
```

system surfaceはアプリ本体とは別のextension processまたはsystem hostで実行され得るため、Viewやscene stateを共有せず、共有domain action、source of truth、staleness、offline／error／recoveryを計画時に固定する。App Group、deep link、background update、push、Siri、associated domainなどのcapability／entitlementは、採用面が要求する最小範囲だけを専用Issueで追加し、Bundle ID、signing、privacy、lock-state redaction、日英localization、accessibility、fallback、release依存を同じ設計記録へ含める。

Dynamic IslandはLive Activityと実装依存を共有しても、表示面として独立に価値と適用範囲を評価する。複数面が同じactionやdataを使う場合は共有domain contractを先行依存にし、Extension間の直接結合や重複したbusiness ruleを作らない。System Experiences PlanningはUI Direction Gateの代わりではなく、採用したsystem UIのhierarchy／interactionが未確定ならdependent Issueで別途UI Direction Gateを通す。

## 4. 仕様と運用の責務

| 場所 | 正本となる内容 |
| --- | --- |
| `specs/` | 目的、機能、技術設計、受け入れ条件、決定 |
| `docs/` | 作業手順、権限、セキュリティ、検証方法 |
| `.agents/skills/` | Codex と Claude が共有する反復可能な手続き |
| `.codex/agents/` | Codex のカスタムエージェント定義 |
| `.claude/agents/` | Claude のカスタムサブエージェント定義 |
| `tools/` | 人間とスキルの双方が呼べる決定論的スクリプト |
| `.artifacts/` | 名前空間を分けたローカル生成物。検証証拠とUI方向比較は混同せず、Git管理外 |
| GitHub Issue/PR | 作業状態、受け入れ条件、レビューと検証の永続的な要約 |

### 4.1 UI Direction成果物の境界

UI比較は`.artifacts/ui-direction/<flow-slug>/<revision>/comparison.html`に一つのself-contained HTMLとして置く。提示したrevisionをimmutableとし、exact SHA-256で同定する。HTMLはnetworkを拒否する制限的なContent Security Policyを持ち、remote dependency、tracking、credential、秘密、個人情報、本番dataを含めない。

このHTMLとdigestはユーザーが見た比較revisionを同定するためのdecision inputであり、`specs/`の正本でも、SwiftUI sourceでも、canonical iOS verification evidenceでもない。選択結果の正本は、対象scope、artifact path／revision、提示bytesのexact SHA-256、採用・不採用要素、対象screen／state、native適応範囲を共通して持つアプリ固有の確定specと追記型Decisionである。単一案はselected concept IDを持ち、hybridは全採用要素からsource concept IDへのexhaustive mappingを持つ。hybridのselected／base concept IDはユーザーがbaseを明示した場合だけ持つ。選択結果を保持するために新しいIssue-contract field、mutableな未封印heading、HTML用canonical evidence schemaを追加しない。

routeの正本も新しいfieldには置かない。cutover後のClaim前に、既存のAcceptance criteria全体でexactly oneの有効なroute宣言を持たせる。一つのAcceptance criterion本文の先頭（`AC-*:`の直後）をexact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`で開始し、`<route>`は`comparison`、`explicit-skip`、`confirmed-direction reuse`、`bounded direction-neutral`、`not-applicable`のいずれかだけとする。route固有の適用事実はReasonの後へ続けてよい。prefix外のroute語は宣言として数えない。`Spec anchors`が確定anchorを、Dependenciesが必要な選択前提を持つ。UI Issueの`UI verification`はexact 3 fieldのlive guidanceであり、Issue contractやreview packetには封印されない。Identity bootstrapと純非UIでは本文をexact `Not applicable`だけにし、scope／非UI理由をGoal／In scope等へ分け、route宣言を`UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`としてAcceptance criterion本文の先頭へ、関連product／spec anchorを`Spec anchors`へ置く。

互換判定は封印済みcontractの`fetchedAt`と、Acceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補、D-030 cutover `2026-09-06T00:31:41Z`だけで行う。cutoverより前で候補がゼロならpre-D-030 legacyとして元のcontractを変更・再封印せず、routeやHTMLを推測・遡及要求しない。cutover前でも候補が一つ以上あれば通常検証へ進み、候補がexactly oneで許可routeと非空Scope／Reasonを持つ完全な宣言でなければrejectする。cutoverと同時刻以降にも同じexactly-one／完全性を要求する。prefix外のroute語は候補や互換判定に使わない。review packetはlive bodyを追加せず、legacyか宣言候補を持つかを判定できる元のIssue contract descriptor／digestを保持する。

## 5. スキル構成

正本は `.agents/skills/${name}/SKILL.md` とします。`.claude/skills/${name}` は同じディレクトリへの相対シンボリックリンクにし、手作業による二重管理を避けます。

### Core

| スキル | 責務 |
| --- | --- |
| `spec-workflow` | 相談内容を確定・提案・未決へ分け、仕様と決定ログを更新する |
| `plan-issue-batch` | 指定された機能を依存関係付きIssue群へ分解する |
| `ship-issue` | 1 Issue を実装からSquash Mergeまで進める |
| `ship-issue-batch` | 独立Issueを安全に並行化し、依存Issueを順に進める |
| `ios-verify` | Delivery stageに応じてshape 1条件、harden targeted、release 4条件の有界検証を選び、現在Headの証拠を生成する |
| `cross-model-review` | `strict`または`release`で反対モデルへレビューを依頼し、Head SHA付き結果を保存する。非releaseのstandard shape/hardenと`fast`ではblocking gateにしない |
| `external-ops` | CodexとClaudeに共通のアカウント／target照合後、認証済み外部操作を実行する |
| `report-template-issue` | 派生アプリで見つかった共通改善を現行テンプレートと照合し、重複と権限を確認して明示的な報告先へIssue化する |
| `app-bootstrap` | 新規リポジトリのXcode・Swift・設定Identityを機能開発前に安全に初期化する |
| `app-icon` | Identity確定後にシンプルな画像生成候補から1案を選び、検証済みAppIconへ組み込む |
| `ios-system-experiences` | Identity確定後に5つのsystem surfaceをApple公式情報で評価し、採用面だけを依存Issueへ設計する |

### 条件付き

| スキル | 追加条件 |
| --- | --- |
| `ui-direction` | 現在のユーザーが対象範囲のHTML比較を明示したとき、または対象範囲のUI方向が未確定で、最初のユーザー向けUI、最上位navigation／information hierarchyの新設・変更、主要flowの大幅な再設計のいずれかを行うとき |
| `supabase-ops` | アプリ仕様でSupabase使用を確定したとき |
| `ios-media-assets` | 音声、文字起こし、効果音、音声分離、音楽、画像または動画が受け入れ条件になったとき |
| `ios-3d-assets` | 3Dモデル、mesh、material、rig、animationの作成・生成・形状変更が受け入れ条件になったとき。authoringはCodexのexact model `gpt-6-astra`だけが行う |
| `prepare-appstore-assets` | App Store原稿のread-only準備、登録前提の照合、または完全な提出packageを準備するとき |
| `submit-appstore-release` | CodexまたはClaudeが原稿準備／先行保存と正式提出を振り分け、監査済みpackageを明示許可の下で提出・再開するとき。先行save実装は§9.2の後続Issue、API入出力は§7.2の`asc` adapter |

## 6. エージェント構成

Codex は `.codex/agents/*.toml`、Claude は `.claude/agents/*.md` を使います。名前と責務は揃え、評価基準は `docs/agent-contracts/` を共通参照します。

| エージェント | 責務 | 書き込み |
| --- | --- | --- |
| `spec-reviewer` | 仕様の矛盾、未決、受け入れ条件不足を検出 | 不可 |
| `ios-reviewer` | Swift、SwiftUI、並行処理、状態、アクセシビリティをレビュー | 不可 |
| `acceptance-auditor` | Issue、仕様、検証証拠、Head SHAの一致を監査 | 不可 |
| `release-auditor` | App Store 文面、画像、プライバシー申告の整合性を監査 | 不可 |

実装担当エージェントは、作業IssueのBranch内だけを書き換えます。評価エージェントはread-onlyとし、マージ権限を持ちません。

## 7. 外部サービス境界

外部サービスはすべてAdapterとして扱い、アプリ本体と認証操作を分離します。

- GitHub: Issue、PR、レビュー記録、Squash Merge
- Supabase: 認証・DB・Storageが必要な場合だけ
- Cloudflare: ドメイン、公開サイト、Workerが必要な場合だけ
- Linear: Issue／Project連携が必要な場合だけ
- Vercel: Web配信または補助サービスのdeployが必要な場合だけ
- ElevenLabs: 承認済みの音声・画像・動画処理が必要な場合だけ
- Google Mobile Ads／UMP: 派生アプリの確定仕様でAdMob収益化を明示採用した場合だけ
- App Store Connect: metadata保存、build upload、TestFlight配信、提出、審査対応。公開APIで扱える操作は[固定版`asc` adapter](#72-app-store-connect-api-adapter)だけを使う

認証済み操作はCodexとClaudeのどちらも実行できます。実行モデルに関係なく、Issue contractで指定されたoperation／Executorと`Config/ownership.yml`のアカウント／targetを完全一致で検証し、未設定または不一致なら操作しません。

### 7.1 条件付きAdMob統合境界

`TemplateApp`とIdentity bootstrap直後の派生アプリに、Google Mobile Ads SDK／package reference、AdMob設定、App ID／Ad Unit ID、consent／banner sourceを含めない。[プロダクト方針 §4.1](product.md#41-条件付きadmob収益化)の入力が確定した派生アプリだけが、専用Issueの有界なactivationを行う。未採用時のbootstrap outputとXcode projectを不変とし、生成後の全アプリへprovider依存を注入しない。

後続実装Issueが追加する有効化経路は、共有`admob-monetization` skillと決定論的なactivation toolを入口とする。ツールは対象root、`Config/app-identity.json`、確定済み入力を照合し、実行時のGoogle／Apple公式sourceで必要Xcode／iOS条件、SDKのexact version、SKAdNetworkとprivacy要件を再確認したうえで公式Swift Package Manager経路を使う。参照URL、取得時刻、採用versionと判断結果をsanitizedな有効化記録へ固定する。部分適用を残さず原子的に適用し、同じ入力の再実行は冗等、異なる入力は変更前に停止する。

有効化後のapplication境界は、設定解決、consent、広告対象判定、adaptive banner hostを個別に注入可能にする。UI Testはそれらのoffline fixtureを使い、Google SDK初期化、広告request、network成功を通常フローの決定論的な合格条件にしない。実runtimeでは起動ごとにUMPのconsent infoを更新し、必要formを表示し、`canRequestAds`が確認できた後だけSDK初期化と広告要求を1回化する。要求できない、広告対象外、load失敗の場合は広告領域をcollapseし、利用可能な場合はcontainer widthからanchored adaptive sizeを解決する。配置画面、safe area／scroll／Tabとの統合、広告非表示権利のsource of truthは各派生アプリのUI／domain Issueで確定する。

設定は次の3経路を交差させない。

| Configuration | 許可する値と実行 | 拒否する状態 |
| --- | --- | --- |
| Debug | Google公式demo App ID／Banner Unit IDと有界なdemo smoke | production identifier、demoとproductionの混在 |
| UI Test | network-freeのconsent／eligibility／banner fixture | 実SDK初期化、広告request、remote配信に依存する合格判定 |
| Release | 対象Bundle／configurationと一致するapp固有production identifier | demo identifier、欠落、別アプリのidentifier、混在 |

既定のprivacy境界は非trackingであり、ATTを起動せず、Publisher first-party IDを無効化する。tracking／personalization／IDFAを将来採用する場合は、この有効化のフラグや設定変更に混ぜず、別の確定DecisionとIssueで受け入れ条件、consent、privacy／App Store申告を再設計する。

後続のrelease-readiness検証は、`Info.plist`のGoogle Mobile Ads App ID／SKAdNetworkItems、resolved SDK／privacy manifest／signature、アプリ側`PrivacyInfo.xcprivacy`、実装data useとApp Store回答を同一candidateで照合する。[#110のread-only source preparation](architecture.md#91-原稿の正本と登録準備)はSDK／privacy driftを報告できるが、provider実装、AdMob remote state、App Store Connect保存／提出、release-readyを実行または証明しない。[#101のAppLibrary引き継ぎ](../docs/agent-contracts/appstore-submission.md#legal-page-handoff-and-verified-return)も確認済み原稿の受渡しに限り、広告のremote設定や公開権限を拡張しない。

offline fixtureの成功、Google demo smokeの成功、AdMob Consoleのremote state、productionのApp Store readiness／配信状態は独立した証拠とする。ローカル成功をremote完了／収益発生／審査通過に読み替えず、remote操作は別Issue contractのoperation／Executor／account／target／ユーザー承認がある場合だけ行う。

この節と[D-057](decisions.md#d-057-広告収益化を非trackingの条件付きadmob統合として採用する)は実装契約の確定だけを行う。共有skill／activation tool／runtime source／validatorとそのBuild／Test／Simulator／release evidenceは後続Issueのcurrent-Head成果が揃うまで未実装・未検証である。

### 7.2 App Store Connect API adapter

公開App Store Connect APIで扱えるApp Store Connect／TestFlight操作は、[App Store Connect CLI](https://github.com/rorkai/App-Store-Connect-CLI)（`asc`）をguarded runner経由で呼ぶadapterだけで行う。ユーザーは2026-09-23に、移行範囲をmetadata save、正式提出、build upload、TestFlight配信の全四領域とし、公開APIで扱えないApp Privacy申告を既存のauthenticated browser sectionに残すことを採用した。

- **固定版の導入**: 公式GitHub releaseのmacOS arm64 assetをexact versionとSHA-256でrepository内のpin recordへ固定する。取得したbytesが公開checksum fileとpin recordの双方に一致した場合だけ、repository外の固定locationへno-replaceで配置する。Homebrew、`curl | bash`のinstall script、自動update、`asc install-skills`、未固定versionは使わない。version更新は新しいpin recordと回帰testを持つ別Issueで行う。
- **起動境界**: guarded runnerが唯一の起動口であり、起動ごとにpinned binaryのversionとdigestを再照合する。operationごとのsubcommand／flag allowlist、JSON出力、有限timeout、stdout／stderrのredactionを強制し、telemetryを無効化し、`asc`自身のKeychain／config／profile／web sessionを読まない隔離設定で起動する。`asc web`、`--deep`、`auth login`／`auth logout`、`apps wall`、`install-skills`、`signing`系command、`workflow run`、telemetry有効化、allowlist外subcommandは拒否する。
- **認証**: App Store Connect API keyはTeam keyのApp Manager roleとする。Key IDとIssuer IDは[Keychain命名](../docs/security.md#2-保存先)、`.p8`は専用file-secret directoryへ置き、`run-with-secret.sh`／`run-with-private-key.sh`で子process envへだけ渡す。Admin role、Individual key、Apple IDのpassword／2FA、web session、`asc`自身の認証保存、repository内`.asc/`は使わない。
- **Operation model**: `appstore.inspect_app`はidentityと状態の読取専用照会とreadback、`appstore.update_metadata`はapp information、localization、screenshot、review information、`appstore.upload_build`はarchive／export成果物のuploadとprocessing readback、`appstore.submit_review`はreadback済みbuildの選択と審査提出、新規`appstore.distribute_testflight`はTestFlight group配信と外部group向けbeta app review提出を担当する。同じIssueは同一providerの複数operationを宣言でき、preflightは宣言済みoperationごとに発行する。live operationは従来どおり`release` stage、`full` scope、`strict`、宣言済みoperation／Executor、必要なユーザー承認を要する。
- **Build署名**: archive／exportはautomatic signingと同じAPI key認証によるprovisioning更新だけを使う。証明書／profileの作成・失効・同期、manual signing、Apple ID sign-inは行わない。
- **Web専用操作**: App Privacy申告とreview informationは既存authenticated browser sectionで入力・readbackし、readback sourceをAPI sectionと区別して記録する。review informationを残すのは、固定版`asc` 5.4.0の`review details-update`がdemo account passwordと連絡先email／電話を引数でしか受け取れず、[秘密をコマンドライン引数に置かない規則](../docs/security.md#3-実行時の取扱い)を満たせないためである。秘密を引数以外で渡せる版が利用可能になった場合は別Issueで再評価する。新規App record作成、契約、税務、銀行、価格は引き続き対象外とする。
- **証拠**: API readbackはsanitized digestと`asc://` remote referenceだけを記録し、field値、秘密、tester個人情報を保存しない。テンプレート内Issueはfake `asc`とfake `xcodebuild`だけで検証し、live API、実upload、実提出、実配信の成功を主張しない。live結果は派生アプリのrelease Issueで別の証拠とする。
- **Workflow-only境界**: [受け入れ条件 §3.3](acceptance.md#33-workflow-only検証)のexact allowlistは、後続Issueが自Headでexact pathとして列挙したasc adapterのtool、helper、fixture、直接regression testだけを追加できる。directory、prefix、`asc`名の一致では許可せず、`appstore.*` operationやlive外部操作をworkflow-onlyで認可しない。

実装は#130（pinned installerとguarded runner）、#145（operation model）、#146（production preflightとpremerge）、#132（§9.2のselective save）、#133（build upload）、#134（release sectionのAPI移行）、#135（TestFlight配信）の順に分ける。#134が完了するまでは、既存のauthenticated browser section workflowだけが完全releaseの実行経路である。この節と[D-059](decisions.md#d-059-app-store-connect-api操作を固定版ascのguarded-adapterへ集約する)は契約の確定だけを行い、adapterのinstall、実装、live API成功を主張しない。

## 8. Supabase構成

Supabaseを採用したアプリだけ、次を作成します。

```text
supabase/
├── config.toml
├── migrations/
└── seed.sql
```

- `migrations/*.sql` が唯一のスキーマ正本。
- `seed.sql` は合成データのみ。
- `.temp/` と `.branches/` はGit管理外。
- 公開スキーマのテーブルはRLSを有効化する。
- ローカル検証は `--local`、リモート操作は `--linked` を明示する。
- 本番で `db reset --linked` を実行しない。

## 9. App Store構成

`App Store/` のテキストと構造はコミットします。生成途中の秘密、認証セッション、未加工の個人データは置きません。スクリーンショットは、提出対象として採用された最終版だけを管理します。

App Store用スクリーンショットの端末集合は、通常検証のiPhone Pro／iPad Airマトリクスとは別に、その時点の公式要件から解決します。提出要件が求める場合はiPhone Pro Maxも使用できます。

### 9.1 原稿の正本と登録準備

App Store準備は、原稿の確認、remote保存、release readiness、提出を区別する。アプリ共通のfield inventoryとsource→ASC対応、登録前の照合、解除条件付きreadiness reportは[App Store運用契約](../docs/agent-contracts/appstore-submission.md#source-inventory-and-registration-preparation)に従う。

- アプリ固有の表示名・module・slug・Bundle IDは`Config/app-identity.json`と確定仕様、実際のXcode設定から照合する。localized store nameは内部display nameと別の判断であり、名前衝突を理由にどちらも自動変更しない。
- `Config/template-identity.json`の現行変換対象に`App Store/metadata/`は含まれない。Bootstrap完了を原稿変換・remote Bundle登録・App作成・privacy監査完了と解釈しない。変換可能なidentity値は原稿への導出元とし、SKU、Team、公開URL、法務・価格・SDK申告は別確認する。
- 一時文案は出所と実装根拠を確認してから`App Store/`のreviewed draftへ昇格する。既存schemaで表現できる原稿は既存ファイルへ置き、追加の登録field・質問票は[versioned preparation format](<../App Store/metadata/preparation-format.md>)の`App Store/metadata/preparation.json`で表現する。人間可読の`reviewed-draft.md`は保全し、レビューした値だけを明示転記する。台帳の状態ラベルを承認へ変換せず、既存YAMLへ未知のkeyを追加しない。
- 各fieldを`draft`／`confirmed`／`remote-saved`として、source path/anchor、revision/digest、確認根拠、未決理由、対象locale/sectionへ結び付ける。`remote-saved`には同一Team/App/Bundleとsource digestに一致するreadbackが必要であり、ローカルの確認だけから昇格しない。原稿、SDK、機能、権限、公開本文が変われば影響fieldを再監査し、古い確認を流用しない。
- 未決fieldの送信だけを止め、独立fieldの下書き・確認は続ける。ただし部分準備を完全packageや提出許可とせず、現行のpackage seal、全画像、full iOS、反対モデルreview、初回法務承認を省略しない。スクリーンショット延期の指示がある場合、準備仕様を理由に生成を開始しない。
- Team ID未設定時はユーザーが個人membershipの実値を確認して設定を承認する。表示名、メール、Xcodeの自動選択から推測して設定しない。設定後の実操作はactive Teamの完全一致preflightを改めて通す。
- 新規Bundle/App作成は既存Appの更新と別のoperationである。対応するallowlist・契約・承認・再開検証を実装した後続Issueが完了するまでは実行不可。準備仕様は既存の権限を拡張しない。

読取専用入口は`tools/prepare-appstore-sources.sh --project-root /absolute/physical/app/root`とする。実際のsource bytes、Xcode設定、コード／依存inventoryと提供された確認証拠からfield状態を算出し、源泉が変化・不明・未対応なら該当欄を未確認に保つ。exit 0の`prepared`はsource準備の判定であり、包括的なSDK監査、live Apple照会、署名済みbuild、release-readyの証明ではない。exit 1は未完了／延期を含むreport、exit 2は安全に読めない入力とする。

確認証拠は`.artifacts/appstore-preparation/`へ分離する。canonical worktreeだけ共有artifact storeを使い、任意symlinkや秘密実値の保存を認めない。`remote-saved`はsource分類から推測せず、対応する実resourceとsource／identity／ユーザー承認へ束縛した既存保存記録を検証する。ローカル専用field、未対応のresource、未知・不完全なformは保存済みにしない。private coupled fieldの保全比較は明示された一時pipeだけを使い、値や値hashを保存しない。

既存checklistのschema、keys、booleanと封印済みpackage/resultは変更しない。原稿検証・read-only登録準備は#53に依存する[#110](https://github.com/yuto1201/iOS-Template/issues/110)で、[受け入れ条件 §8](acceptance.md#8-app-store原稿と登録準備)のfixture、immutable targeted repository evidence、workflow-only verification、current-Head strict reviewを満たして完了する。#62は移植元履歴として保持する。実登録mutationは含めず、別の明示契約と必要な承認を要する。AppLibraryの具体的な配置・公開URLは[未決の境界](product.md#61-applibraryでの法務ページ公開方針)のまま保持する。

### 9.2 原稿保存と正式提出の分離

§9.1のfield inventoryを再利用し、[4モードの入出力と保存・再開契約](../docs/agent-contracts/appstore-submission.md#operation-modes-and-selective-metadata-save)を適用する。原稿正本と確認根拠は`App Store/`、部分保存の実行記録はpackage外の`.artifacts/appstore-metadata/<issue>/<attempt>/`、正式releaseのpackage/resultは既存の`App Store/submission/`へ分離する。別形式の部分記録を既存recorderへ入力せず、package tree digestの除外規則も変えない。

#52で実装するのは文書と既存`submit-appstore-release`の薄いmode routingだけである。実行可能なsave modeを追加する後続Issueは#132とし、#52とread-only準備の#110に加えて§7.2の#131に依存し、次のwrite-setとTestをClaim前に確定する。remote formのbaseline、保存、readbackは§7.2のguarded runnerだけで行う。

- 専用の共有`.agents/skills/save-appstore-metadata/`、対応する`.claude/skills/`相対symlink、§5のrouting。これは予定名であり、現在使えるskillや既存scriptの新flagではない。
- そのskillのpublic entrypointと、field/locale差分・source固定・account/target照合・保存・readback・履歴公開を行うhelper。既存provider adapterで表現できない観察項目や権限は、その変更ファイルと安全確認もIssueに明示し、広い操作へ代用しない。
- 合成providerとfixture、実public entrypointを通す`tools/tests/test-appstore-metadata-save.sh`。契約の[手動検証表](../docs/agent-contracts/appstore-submission.md#selective-save-verification-plan)を正常／拒否／部分成功／曖昧応答の回帰へ変換する。実AppleアカウントをTestに使わない。
- 既存`test-appstore-skills.sh`／`test-appstore-package.sh`で完全package、法務承認、ordered result、drift検出が維持されることを検証する。封印済みpackage/result/checklistのschemaやhash除外を変えず、save記録からrelease-ready/submittedへ昇格できないことを確認する。

後続Issueにも登録、画像生成・upload、build選択、審査提出、価格・契約・法務の自動承認を混ぜない。専用entrypoint未実装中はofflineの原稿と差分計画を返し、現在のfull-release入口やブラウザ手動操作でsave gateを迂回しない。
