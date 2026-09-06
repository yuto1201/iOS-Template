# プロダクト方針

Status: 確定  
Version: 1.8
Date: 2026-09-06

## 1. 目的

個人で開発する新しい iOS アプリを、空の Xcode プロジェクトから毎回組み直すのではなく、仕様化・実装・検証・レビュー・リリースの共通部分を再利用できる状態にします。

テンプレートの価値は、機能コードの量ではなく、次の一貫性です。

- 未決事項を抱えたまま実装しない。
- アプリの目的・方向性と名前を確定した段階で、シンプルな画像生成候補からアプリアイコンを選び、最初のユーザー向けUIより先に組み込む。
- 取っ掛かりのないUIを一案の推測で作らず、必要な場合は比較可能な方向案からユーザーが選んだ後に実装する。
- Issue の塊を指定すれば、AI が独立性と依存関係を判断して止まらず進める。
- 各IssueはDelivery stageに応じた検証を完了し、`strict`または`release`では反対モデルレビューも完了してからマージする。
- 設定済みの個人用外部アカウント以外を使用しない。
- App Store 申請に必要な情報を後から探し直さない。

## 2. 想定利用者

- プロダクトオーナー: ユーザー本人
- 主開発者: Codex または Claude
- 外部操作実行者: Issueで指定されたCodexまたはClaude
- 反対モデル評価者: 主開発者ではない側のモデル
- 最終実機確認者: ユーザー本人

ClaudeとCodexは一般の仕様化、実装、検証、レビュー、設定済み外部操作を同等に担当できる。モデル固有の品質差を理由に全体を主従化せず、3D authoringだけを§5.1の限定例外として扱う。

## 3. 標準プラットフォーム

- UI: SwiftUI
- 言語: Swift
- 非同期処理: Swift Concurrency
- Unit Test: Swift Testing を優先し、既存 XCTest がある場合は併存を許可
- UI Test: XCUITest
- 対応端末: iPhone と iPad
- 対応言語: 日本語と英語
- 開発順序: 日本語iPhoneで主要機能を固め、英語・iPadの仕上げ後にリリース候補を4条件で確認する
- Xcode、Swift、iOS Deployment Target: アプリ開始時に最新の安定版と要件を確認して仕様に固定

テンプレート自体は特定の将来の Xcode や iOS バージョンを永続的に固定しません。バージョンはアプリごとの決定ログへ記録します。

### 3.1 新しいアプリの開始順序

テンプレートから新しいリポジトリを作成した後は、機能開発より先に次の順序を完了します。

1. アプリの目的、対象ユーザー、中心的な価値と雰囲気をアプリ固有仕様へ確定し、Identity入力として表示名、Swift モジュール名、アプリ Slug、Bundle IDの4値を確定する。Deployment TargetはIdentity入力とは別のアプリ仕様として確定する。
2. Identity Bootstrap Issue と専用 Branch/worktree を作成する。
3. 共有 bootstrap ツールで、Xcode project、Target、Scheme、ソース、Test、設定、アプリ固有文書を一貫したIdentityへ変換する。
4. Build、Test、標準Simulatorマトリクス、反対モデルレビュー、Squash Mergeを完了する。
5. Identity Bootstrapに依存するApp Icon Issueを作成し、同じ確定briefから画像生成したシンプルな2案を提示する。ユーザーが明示選択した1案だけをAppIconへ組み込み、検証してマージする。
6. 変換済みIdentityと選択済みアプリアイコンを基準にアプリ固有仕様を確定し、続くnative UIごとに[条件付きUI Direction Gate](development-stages.md#11-適用判定)の明示指示と通常triggerを評価する。Identity bootstrapとアプリアイコン選択自体は画面階層、navigationまたは主要flowを決めない。
7. 最初のUI IssueはApp Icon Issueの完了後に進める。Gateに依存するUI Issueは選択結果を記録した仕様変更のマージ後に`approved`／Claim可能とし、依存しない非UI Issueは並行して進められる。

アプリ固有の`specs/product.md`と`specs/acceptance.md`がともに**確定**するまでは、Feature Issueを実行に移さない。両仕様のいずれかが未作成、提案、未決、またはIssueの受け入れ条件と矛盾する場合、選択された実行モデルはIssueを`blocked:user`にし、Branch/worktree作成と実装を始めずにユーザーの確定を求める。

現在のユーザーが対象範囲のHTML比較を明示的に求めた場合は、既存方向の有無にかかわらず同Gateを最優先で実行する。現在の明示省略は、その現行性、scope、権限、理由が明確で比較指示と矛盾しないときだけ通常判定を上書きし、曖昧または矛盾する場合は依存UIを`blocked:user`とする。それ以外は、exact hierarchy／flowを覆う確定方向があればconfirmed-direction reuse、覆う方向がなく対象方向が未確定かつ最初のユーザー向けUI、最上位navigation／information hierarchyの新設・変更、主要flowの大幅な再設計のいずれかならGate、方向未確定かつ構造triggerなしならAcceptance criteriaがhierarchy、navigation、primary-flow interactionを決めない範囲だけbounded direction-neutralとする。coverage、triggerまたはneutralityが曖昧ならGateを実行する。

Gateは一つの確定briefから2–3案のHTML比較を提示し、ユーザーによる単一案または正確なhybridの明示選択をアプリ固有仕様と追記型Decisionへ確定する。共通記録は対象scope、artifact path／revision、提示bytesのexact SHA-256、採用・不採用要素、対象screen／state、native適応範囲を含む。単一案はselected concept IDを、hybridは全採用要素からsource concept IDへのexhaustive mappingを含み、selected／base concept IDはユーザーがbaseを明示した場合だけ含む。HTML自体は判断補助であり、製品仕様、pixel仕様、SwiftUI実装、Simulator検証証拠の正本にはしない。

cutover後にClaimするcontractは、既存のAcceptance criteria全体でexactly oneの有効なroute宣言を持つ。一つのAcceptance criterion本文の先頭（`AC-*:`の直後）をexact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`で開始し、`<route>`は`comparison`、`explicit-skip`、`confirmed-direction reuse`、`bounded direction-neutral`、`not-applicable`のいずれかだけとする。route固有の適用事実はReasonの後へ続けてよく、prefixに一致しない偶発的なroute語は宣言として数えない。`confirmed-direction reuse`はUI方向anchor、`bounded direction-neutral`はproduct／behavior anchor、`explicit-skip`はproduct／spec／Decision anchorを`Spec anchors`へ置き、`comparison`は選択spec／Decisionを`Spec anchors`、専用IssueをDependenciesへ置く。UI Issueの3 field `UI verification`はlive guidanceであり、封印済みcontract fieldの代わりにしない。

cutover後にClaimするIdentity bootstrapと純粋な非UI作業はnot-applicable routeであり、確定済みUI方向anchorを必要としない。`UI verification`本文はexact `Not applicable`だけとし、対象scopeと非UIである理由をGoal／In scope等へ記録し、一つのAcceptance criterion本文を`UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`で開始して、関連する確定済みproduct／spec anchorを`Spec anchors`へ記録する。それらに依存する後続UIだけをGate判定する。

route宣言の導入cutoverは`2026-09-06T00:31:41Z`である。封印済みcontractの`fetchedAt`がこれより前で、Acceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補がゼロの場合だけpre-D-030 legacyとし、routeやHTMLを遡及要求せず元の封印済みAC／spec／evidenceを検証する。cutover前でも候補が一つ以上あれば通常検証へ進み、候補がexactly oneで許可routeと非空Scope／Reasonを持つ完全な宣言でなければrejectする。cutoverと同時刻以降のcontractとcutover後のpre-Claim Issueにも同じexactly-one／完全性を必須とする。legacy contractは変更・再封印せず、prefix外のroute語は候補や非legacy判定に使わない。

テンプレートリポジトリ自身には将来の実アプリ名を固定しません。GitHub上のリポジトリ名はテンプレートからリポジトリを作成するときに決め、bootstrapツールは認証済みリモート名変更を行いません。

### 3.2 アプリアイコン

アプリの目的・方向性とIdentityが確定し、Identity bootstrapが完了したら、[App Icon skill](../.agents/skills/app-icon/SKILL.md)を使う専用Issueを最初のユーザー向けUI `shape`より先に完了する。表示名、目的、対象ユーザー、中心的な価値、雰囲気、色の希望・除外、視覚的な比喩を一つの確定briefへまとめ、同じ条件で意味の異なるシンプルな画像生成候補をexactly 2案作る。

既定は、一つの認識しやすい主題、単純な背景、少ない形と色、十分な小サイズ判別性を持つ構成とする。文字、イニシャル、数字、スクリーンショット、Apple製品の複製、第三者mark、watermark、焼き込んだ角丸mask、細かい装飾を含めない。現在のApple公式ガイダンスを生成直前に確認し、正方形1024 x 1024、実透明pixelなし、system mask前提のPNGとして扱う。

ユーザーがstable concept IDを一つ明示選択した場合だけ採用する。組合せや重要な修正は提示済みbytesを上書きせず新revisionとして再生成し、再度一案を選択する。候補は`.artifacts/app-icon/<revision>/`の判断補助であり、選択済みPNG、Asset Catalogの`Contents.json`、sanitizedな`Config/app-icon.json`だけを同じcommitへ含める。選択は画面階層、navigation、主要flowを承認せず、[UI Direction Gate](development-stages.md#11-適用判定)を満たしたことにもならない。

最初のユーザー向けUIだけがApp Icon Issueの完了を依存に持つ。選択待ちは`blocked:user`とし、domain、dataその他の独立した非UI作業は継続できる。

### 3.3 日本語iPhone優先の機能開発

Identity/bootstrap完了後の通常機能開発は、まず`shape`で日本語iPhoneの主要導線と重要ロジックを操作可能にする。承認された形に必要な英訳、iPad最適化、Dark Mode、Dynamic Type、VoiceOver、44pt、復旧、性能などは、問題ごとの狭い`harden` Issueで進める。`release`で日本語・英語 × iPhone・iPadと提出前品質を完全確認する。最初から文字列管理、可変レイアウト、データ・権限・課金の安全な土台を維持し、最終的な対応範囲は減らさない。

段階別の完了条件、harden Issueへの分離、危険度と検証範囲の分離は[段階的開発仕様](development-stages.md)を正とする。shapeは明示した`iphone-ja`のcanonical検証で完了できるが、release-readyとは扱わない。hardenは`targeted`、release、stage未指定の既存Issue、Foundation・Identity/bootstrapは`full`を維持する。

## 4. データ方針

データベースが不要なアプリに外部データベースを導入しません。

- 端末内だけで成立する場合: SwiftData、UserDefaults、Keychain、ファイル保存から要件に合うものを選ぶ。
- 認証、同期、共有、サーバー側データが必要な場合: Supabase を標準とする。
- Supabase のリモート操作: 実行モデルが設定済みOrganization／Projectを確認したうえで行う。
- Supabase のスキーマ正本: `supabase/migrations/*.sql`。
- iOS アプリに渡せる鍵: Project URL と Publishable Key のみ。
- Secret Key、旧 `service_role`、管理権限のある鍵: iOS アプリへ入れない。

## 5. 音声素材方針

テキスト読み上げ、スピーチ変換・文字起こし、効果音、音声分離、音楽、画像、動画が受け入れ条件に必要な場合、CodexまたはClaudeが共有のElevenLabsメディアスキルを使用します。

新しいアプリの必須アプリアイコンはこの汎用メディア経路ではなく、§3.2のbuilt-in画像生成と`app-icon` skillを使う。アプリアイコンのためだけにElevenLabs account、SDKまたはprovider接続を有効化しない。

- 外部生成の実行前に、実行モデルが設定済みAccount／Workspaceとentitlementを照合する。
- 処理前に用途、入出力、長さ・寸法、言語・Voice、ループ、権利・同意、保持方針、ライセンス記録先をモードに応じて仕様化する。
- 音声は試聴・内容・音量・ループ境界、文字起こしは内容・話者・時刻、画像・動画は寸法・時間・表示品質を検証する。
- `paid_plan_required`、権限拒否、moderation、著作権拒否、課金成否が曖昧な要求は自動再試行せず、`blocked:ops` または `blocked:user` として止める。
- 生成・変換・アップロードに使う素材の権利または同意が確認できない場合は処理しない。
- メディアが不要なアプリにはElevenLabs SDKやメディア生成パイプラインを追加しない。

### 5.1 3Dモデル制作方針

3Dモデル、mesh、material、rig、animationの新規作成、生成、または形状・構造を変えるrevisionは、共有の[`ios-3d-assets`](../.agents/skills/ios-3d-assets/SKILL.md)を使用し、Codexのexact model `gpt-6-astra`だけがauthoringする。作業をClaudeまたは別のCodex modelが開始した場合は、authoring部分を`gpt-6-astra`へ依頼する。exact modelを利用できない場合は別modelへfallbackせず`blocked:environment`として停止する。

ClaudeとCodexの一般開発方針は維持する。Claudeや別のCodex modelは、3D要件・制約の仕様化、参照資料の整理、受領済みassetのアプリ統合、GLB／USDZ等の決定論的検証、RealityKit実装、Build／Test、視覚確認、レビューを担当できる。ただし3D asset bytesを生成・編集した主体として扱わない。3Dを含むIssue／PR証拠にはauthoring modelのexact identifierを記録し、確認できない生成物をこの経路の成果として承認しない。

## 6. App Store 方針

ルートの `App Store/` に、申請時に必要な情報を一括管理します。

- `metadata/`: アプリ名、サブタイトル、説明、キーワード、カテゴリ、年齢区分メモ
- `legal/`: プライバシーポリシー、利用規約、サポート情報
- `review/`: App Review 向け説明、テストアカウント手順、審査上の注意点
- `screenshots/`: 端末・言語別の最終素材
- `release-notes/`: バージョン別更新内容
- `submission/`: 申請前チェックと提出結果。秘密値は含めない

申請文面と画像はCodexまたはClaudeが作成・検証し、App Store Connectへの認証済み入力もIssueで指定された実行モデルが行います。法的文書はテンプレートの雛形をそのまま公開せず、アプリのデータ利用実態に合わせて確定します。

### 6.1 AppLibraryでの法務ページ公開方針

- `app.yutodev.com` はAppLibraryのアプリ一覧の入口とする。開発したアプリを一覧へ掲載し、そこから各アプリのWebサイトへ案内する。そのアプリサイト内にプライバシーポリシーと利用規約を用意し、必要なサポート情報も案内する。
- Webページの公開・デプロイ管理はVercelへ統一する。Cloudflareはドメイン・DNS管理に使用し、Cloudflare Pagesは使わない。AppLibraryのVercel移行は別作業であり、この方針の記録を移行完了の証拠にしない。
- 各アプリの `App Store/` は申請情報・法務原稿の正本として維持する。申請準備でプライバシーポリシーや利用規約の作成・更新が必要になったら、この方針に従い、実装とデータ利用実態に合う原稿をアプリサイトの公開版へ反映する。必要文書とEULAの扱いは、その時点のApple要件とアプリの機能・課金方式を確認して判断する。
- **配置は未決・ユーザー指定待ち**。AppLibraryは開発中のため、各アプリサイトと法務ページのリポジトリ内配置、URLパス、ルーティング、Vercel project、対応言語別の公開URLは、ユーザーから詳細が伝えられた後に確定する。一覧のドメインだけからこれらを推測せず、固定ディレクトリ、ファイル名、サブドメインを先回りして決めない。
- 配置が未決でも、独立した通常のアプリ開発、データ利用の棚卸し、法務原稿の下書きは継続できる。公開先の確定を必要とする公開・申請作業は、該当Issueを `blocked:user` として確認を求める。仮URL、一覧トップURL、ローカルファイルを正式な法務ページURLとして登録しない。
- 公開・申請前に、ユーザーが指定した各ページの公開URL、ログイン不要での到達性、公開本文と確認済み原稿・プライバシー申告の一致、アプリ内リンクと申請情報の整合を確認する。初回の法務内容に対するユーザー承認は引き続き必須で、この公開方針への合意を法務本文への承認として扱わない。
- この方針はAppLibraryの編集・移行・デプロイ、DNS変更、App Store提出を単独で認可しない。実操作は対象リポジトリの規則、確定した配置、設定済み個人アカウント／target、Issue contractと必要な承認に従う。既存のoperation allowlistや検証gateは変更しない。

決定の経緯は [D-026](decisions.md#d-026-applibraryのアプリサイトを法務ページの公開先とする) を参照する。

## 7. 自動化の範囲

AI は、承認済み仕様を前提として次を止まらず進めます。

1. Issue の分解と依存関係整理
2. GitHub Issue 起票
3. Branch と worktree 作成
4. 実装とテスト
5. Delivery stageとprofileに応じた有界検証と、必要な場合だけの視覚評価
6. `strict`または`release`の反対モデルレビュー
7. 指摘修正と再検証
8. PR 作成
9. Squash Merge
10. Branch と worktree の後片付け

ユーザーへの確認は、仕様を変える判断、認証・課金・公開範囲を変える判断、本番の破壊的操作、法的主張の確定に限定します。

## 8. 対象外

- `Config/ownership.yml`にないアカウントまたは未設定targetで認証済み外部操作を行うこと
- ユーザーの実機をAIの自動完了条件に含めること
- 全アプリへ Supabase、課金、通知、分析、音声を先回り導入すること
- プロジェクト固有の Feature や Core ディレクトリを空のまま量産すること
- 反対モデルが利用できない場合の自己承認
- App Store の法的文面をアプリの実態確認なしで公開すること
