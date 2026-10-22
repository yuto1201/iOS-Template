# 決定ログ

この文書は追記型です。過去の決定を変更するときは、古い項目を消さず、新しいDecisionで置き換えを記録します。

## D-001: 主開発環境はCodexとする

- Date: 2026-08-21
- Status: 確定
- Decision: 個人iOS開発の主環境はCodexとする。Claudeも実装・修正・ローカル検証に使用できる。
- Consequence: テンプレートは両モデル向けのスキルと評価エージェントを持つ。

## D-002: 認証済み外部操作はCodexだけが行う

- Date: 2026-08-21
- Status: 確定
- Context: ClaudeのGitHub、Supabase、Cloudflareは会社用、Codexは個人用アカウントに紐づく。
- Decision: GitHub remote、Supabase、Cloudflare、ElevenLabs、App Store Connectを含む認証済み外部操作はCodexが行う。ClaudeはCodexへ委託する。
- Consequence: `docs/AUTHORITY.md` を正本とし、ClaudeのPreToolUseフックでも遮断する。

## D-003: CLAUDE.mdを作成しない

- Date: 2026-08-21
- Status: 確定
- Decision: 共通指示は `AGENTS.md` と `specs/`、`docs/` に置く。Claude固有の起動処理は `.claude/settings.json` とフックで実現する。
- Consequence: 同じ規則を2文書へ複製しない。

## D-004: スキルの正本は.agents/skillsとする

- Date: 2026-08-21
- Status: 確定
- Decision: 共有スキルは `.agents/skills/` に置き、`.claude/skills/` から相対シンボリックリンクする。
- Consequence: CodexとClaudeで手順の内容がずれない。モデル固有の形式が必要なエージェント定義だけ分ける。

## D-005: 1 Issue = 1 Branch = 1 PR

- Date: 2026-08-21
- Status: 確定
- Decision: 全実装作業をGitHub Issueにし、IssueごとにBranchとPRを1つ作る。マージはSquashとする。
- Consequence: 履歴の中心はIssueとPRになり、マージ後の作業Branchは削除する。

## D-006: AIがマージまで実行する

- Date: 2026-08-21
- Status: 確定
- Decision: 検証・反対モデルレビュー・修正・pre-merge gateの通過後、CodexがAI実行者としてマージする。
- Consequence: ユーザーは各PRの途中承認を求められず、完成したIssue群を最終確認できる。

## D-007: 反対モデルレビューを必須にする

- Date: 2026-08-21
- Status: 確定
- Decision: Codex実装はClaude、Claude実装はCodexが自動レビューする。利用不能時の自己承認は禁止する。
- Consequence: レビュー結果はBase SHA、Head SHA、Verify SHAに結び付ける。

## D-008: Simulator検証をAIの完了条件とする

- Date: 2026-08-21
- Status: 確定
- Decision: AIの完了条件はSimulatorとAI視覚評価までとする。ユーザーの実機確認は全PR通過後の最終確認とする。
- Consequence: 実機確認で見つかった問題は別のRegression Issueで修正する。

## D-009: iPhone ProとiPad Airを日英で検証する

- Date: 2026-08-21
- Status: 確定
- Decision: バッチ開始時点の最新利用可能iOS Runtime上で、最新iPhone Proと最新iPad Airを日本語・英語の4条件で検証する。
- Consequence: 解決結果をバッチ内で固定し、再現可能な証拠へ保存する。

## D-010: Supabaseは必要な場合だけ採用する

- Date: 2026-08-21
- Status: 確定
- Decision: リモートDBや認証が必要な場合の標準をSupabaseとする。不要なアプリには導入しない。
- Consequence: リモート操作はCodexだけが個人プロジェクトを対象に行う。

## D-011: Supabase migrationsをスキーマの唯一の正本にする

- Date: 2026-08-21
- Status: 確定
- Decision: `supabase/migrations/*.sql` を唯一の正本とし、手動管理の別 `schema.sql` を作らない。
- Consequence: ローカルリセットとリモートPushを同じ履歴から再現できる。

## D-012: 秘密はKeychainを基本とする

- Date: 2026-08-21
- Status: 確定
- Decision: 秘密値はmacOS Keychainを基本とし、ファイル必須の場合だけリポジトリ外の専用ディレクトリへ権限を絞って保存する。
- Consequence: 秘密値をGit、Issue、PR、ログ、プロンプトへ含めない。Claudeからの取得をガードする。

## D-013: ElevenLabsを音声素材の標準生成手段にする

- Date: 2026-08-21
- Status: 確定
- Decision: 効果音やBGMが必要なIssueでは、CodexがElevenLabsスキルを使用する。
- Consequence: 契約上利用不能なエンドポイントは反復せず、代替案を提示する。

## D-014: App Store情報を一つのルートへ集約する

- Date: 2026-08-21
- Status: 確定
- Decision: 提出文面、法的文書、審査メモ、スクリーンショット、リリースノートを `App Store/` に集約する。
- Consequence: Codexが提出前監査とApp Store Connect入力を自動化できる。

## D-015: 機能がない抽象ディレクトリを先回り作成しない

- Date: 2026-08-21
- Status: 確定
- Decision: Xcode標準構成を保ち、`Features/`、`Domain/`、`Data/`、`DesignSystem/` は責務が生じた時だけ追加する。
- Consequence: テンプレート由来の空構造や不要な層を各アプリへ持ち込まない。

## D-016: 最新環境をバッチ単位で固定する

- Date: 2026-08-21
- Status: 確定
- Decision: 最新Runtimeとデバイスを毎Issueで再解決せず、Issueバッチ開始時に解決してバッチ内で固定する。
- Consequence: 最新環境追随と同一バッチの再現性を両立する。

## D-017: 同一原因の自動再試行は3回まで

- Date: 2026-08-21
- Status: 確定
- Decision: 同じ原因が3回連続したら該当Issueを適切なblocked状態にし、無限ループを止める。
- Consequence: 独立Issueは継続できるが、失敗原因を隠して完了にはしない。

## D-018: 物理端末確認は新しい作業を暗黙に再開しない

- Date: 2026-08-21
- Status: 確定
- Decision: ユーザーの実機確認で問題が見つかった場合、元Issueを履歴上書きせずRegression Issueを作る。
- Consequence: マージ時点の証拠と、その後の実機フィードバックを区別できる。

## D-019: Claude実装時も外部オーケストレーションはCodexが担当する

- Date: 2026-08-21
- Status: 確定
- Decision: ClaudeはPrimary implementerになれるが、Issue状態、GitHub remote、外部サービス、マージはCodexが実行する。Claudeからの委託は検証済みJSONと固定ラッパーだけを使う。
- Consequence: Claudeから任意のCodex CLIプロンプトを実行することは禁止し、外部操作とread-onlyレビューを別経路にする。

## D-020: 最初の2件をBootstrap Issueとして手動ゲートで進める

- Date: 2026-08-21
- Status: 確定
- Decision: FoundationとSimulator verificationは、Codexが同じ検証・レビュー・SHA照合を手動実行する。自動化スクリプトが存在しないことだけを例外とする。
- Consequence: 自動化を自動化自身の前提にする循環を避ける。

## D-021: ソース編集Issueの並行上限は2件とする

- Date: 2026-08-21
- Status: 確定
- Decision: 依存がなくファイルが重ならないソース編集Issueは最大2件まで並行化する。Simulator検証は常に直列化する。
- Consequence: 停止時間を減らしつつ、Xcode共有ファイルと検証状態の競合を抑える。

## D-022: 新規アプリのIdentity BootstrapをFeature開発前に必須化する

- Date: 2026-08-22
- Status: 確定
- Supersedes: D-020のBootstrap Issue数と対象範囲を置き換える。D-020の手動ゲート要件自体は維持する。
- Context: GitHub Templateから作成したリポジトリで`TemplateApp`のProject、Target、Scheme、Module、Bundle IDが残ったままFeature開発を始めると、後の名称変更がコード、Test、設定、提出情報の整合性を壊す。
- Decision: リポジトリ作成後に最小Identity仕様を確定し、Identity Bootstrap Issueを機能開発より先に完了する。変換ツールは将来のアプリ名をテンプレートへ固定せず、検証済み引数を使って隔離worktree内で変換を完成させた後、検証済みpatchだけを適用する。Foundation、Identity bootstrap、Simulator verificationの3件をBootstrap Issueとする。
- Consequence: 新しいアプリは一貫した名前とBundle IDからFeature開発を開始できる。リモートリポジトリ名変更やBundle ID登録などの認証済み操作はbootstrap変換へ含めず、Codexの別操作として扱う。

## D-023: ElevenLabsの条件付きメディア処理を一つの共有スキルへ統合する

- Date: 2026-08-29
- Status: 確定
- Supersedes: D-013
- Context: ElevenLabsで効果音とBGMだけでなく、テキスト読み上げ、Voice Changer、文字起こし、音声分離、画像、動画も扱い、CodexとClaudeの不足するメディア制作能力を補う必要がある。
- Decision: 承認済みIssueが必要とする場合だけ、`ios-media-assets`が8つの明示的なモードへ振り分ける。認証済み処理はCodexだけが個人アカウントで実行し、Claudeはローカル準備・検証・統合に限定する。
- Consequence: 重複する`ios-audio-assets`は廃止する。各モードは権利・同意・プライバシー・契約・課金境界を事前確認し、受理した出力とsanitized manifestだけをアプリへ統合する。

## D-024: 外部操作権限をモデルではなく設定済みアカウントへ結び付ける

- Date: 2026-08-30
- Status: 確定
- Supersedes: D-001のモデル間の主従、D-002、D-019、D-014とD-023のCodex専用外部操作部分
- Context: このMacではClaudeとCodexの外部サービス接続をすべて個人用アカウントへ統一でき、会社用接続との分離はクラウド同期ではなく端末単位で管理できる。モデル名による拒否は個人アカウント混同を防ぐための代理制約であり、現在の運用には不要になった。
- Decision: ClaudeとCodexはローカル作業、認証済み外部操作、秘密取得、Issue状態操作、PR作成、Squash Mergeについて同じ権限を持つ。権限はモデル名ではなく、`Config/ownership.yml`の安定識別子、Issue contractのoperation／Executor、対象、環境、Head SHA、ユーザー承認によって決める。Claude固有の外部操作拒否hookとCodex委託専用transportは廃止する。
- Consequence: どちらのモデルも指定外アカウント、未設定target、曖昧な認証sessionではfail closedになる。評価エージェントのread-only制限、秘密非露出、課金・破壊・法的操作のユーザー承認は維持する。

## D-025: 日常開発を速度優先のリスクベースゲートへ変更する

- Date: 2026-08-30
- Status: 確定
- Supersedes: D-007、D-008、D-009の全Issue一律適用。D-005、D-012、D-017、D-018、D-024の安全境界は維持する。
- Context: 全Headへ4条件Simulator、画像評価、反対モデルreview、exact evidence closureを適用すると、非UIのドメイン／永続化Issueでも小さな修正ごとに完全検証が失効し、実装時間より検証反復が長くなる。実運用では同一Issueに複数Head分の完全証拠が生成され、個人開発の進行速度を大きく落とした。
- Decision: 新規Issueは`fast`、`standard`、`strict`のdelivery profileと理由を明示する。`fast`は非UI・低リスク変更を現在HeadのBuild、対象Test、必要なrepository testだけで完了でき、4条件Simulator、画像評価、blockingな反対モデルreviewを要求しない。`standard`は通常UI変更に使用し、開発中は対象Testを優先して、安定した最終候補Headにだけ4条件Simulator、画像評価、反対モデルreviewを実行する。`strict`は認証・認可、秘密、DB migration、本番データ、破壊的操作、課金、privacy・法務、App Store／TestFlight、署名、delivery gate自体へ現在の完全ゲートを適用する。未指定の既存Issueは`strict`として扱う。
- Consequence: 日常の実装ループは短くなる一方、外部アカウント完全一致、秘密非露出、必要なユーザー承認、main直接変更禁止、1 Issue = 1 Branch = 1 PR、Squash Merge、Merge直前のHead SHA照合は全profileで維持される。strict対象operationを低いprofileへ指定した場合はfail closedになる。

## D-026: AppLibraryのアプリサイトを法務ページの公開先とする

- Date: 2026-08-31
- Status: 確定
- Supersedes: None。D-014の申請原稿集約を補足し、D-024の外部操作権限とD-025の検証方針は維持する。
- Context: ユーザーは、開発中のAppLibraryの一覧から各アプリWebサイトへ案内し、そのサイト内へ利用規約・プライバシーポリシーを設ける方針を指定した。Cloudflareはドメイン・DNS管理、Web公開はVercelへ統一し、app.yutodev.comの移行は別途進行中である。
- Decision: 申請準備で法務ページが必要になったら、[プロダクト方針 §6.1](product.md#61-applibraryでの法務ページ公開方針)に従い、各アプリのApp Store原稿を基にAppLibraryから案内されるアプリサイトへ公開する。Cloudflare Pagesは使わない。具体的な配置・パス・公開URL・Vercel projectはユーザーの後日指定事項として残し、今回確定しない。
- Consequence: 方針の文書化と独立したアプリ開発・原稿準備は進められる。公開先が必要な作業だけを確認待ちにし、ユーザー指定後に配置を確定する。法務本文の実態照合・初回承認・公開到達性の確認を維持し、サイト移行・デプロイ・DNS変更・App Store提出はこの決定だけでは実行しない。
- Related Issue: #27

## D-027: 日本語iPhoneで機能を固めてから英語とiPadを仕上げる

- Date: 2026-08-31
- Status: 確定
- Supersedes: D-009とD-025の通常UI Issueにおける4条件一律適用。D-025の危険度分類とレビュー、安全・account・Head照合の境界は維持する。
- Context: 実際にテンプレートで開発すると、日本語・英語、iPhone・iPadを毎機能で同時に完成させる作業が反復し、主要機能の進行を遅らせた。ユーザーは日本語iPhoneを先に作り、英語・iPadを最後に仕上げる方針を承認した。
- Decision: [段階的開発仕様](development-stages.md)に従い、通常機能開発は日本語iPhone、主要機能と画面遷移が安定したら英語・iPad仕上げ、リリース候補は4条件で確認する。delivery profileと検証範囲を分離し、localization・可変レイアウト・accessibilityの土台とデータ・権限・課金の正しさは初期から維持する。
- Consequence: 翻訳・iPad最適化を仕上げIssueへ集約し、リリースIssueの依存にする。既存snapshotを縮小せず、未検証の言語・端末を成功扱いしない。実行ツールは現在4条件固定なので、#19・#29の既存修正に続く#32で1条件経路を実装するまで現行canonicalゲートを維持する。方針記載だけでツール対応済みとは報告しない。
- Related Issue: #31、#32

## D-028: 検証範囲をIssue契約と実行・リリース証拠へ接続する

- Date: 2026-09-01
- Status: 確定
- Supersedes: D-027の移行中という実装境界。危険度・安全・account・Head・反対モデル承認は変更しない。
- Context: 日本語iPhone優先の承認済み方針を、固定4条件の実行経路でも実現する必要がある。
- Decision: 任意のVerification scope節を共通producerがname・stage・reasonとして封印する。通常UIはstandard + iphone-ja / feature、仕上げはfull / adaptation、リリースはstrict + full / release。未指定の既存contractはbyte互換のfull。case集合はexact 1件／4件のみで、scope改変・別範囲のmatrixや証拠流用を拒否する。
- Consequence: 日本語iPhoneの機能Issueで英訳・iPad最適化を毎回完成させない。共通の仕上げIssueをリリース依存にし、申請準備・提出再開では同じ候補HeadとBundle IDのfull証拠を再検証する。提出画像の専用matrix、法務承認、指定アカウントの確認は維持する。既存アプリには自動適用しない。
- Related Issue: #32

## D-029: 動く形から品質を固めるDelivery stageを導入する

- Date: 2026-09-02
- Status: 確定
- Supersedes: D-017の3回上限、D-025のstandard一律review、D-027／D-028のfeature／adaptation stage。危険度profile、全stageの安全境界、release品質、account／Head照合は維持する。
- Context: PayCycle Issue #11ではアプリ追加約1,152行に対してTest追加約1,714行となり、操作可能なMVP後の4条件、visual、accessibility、統合UI、同一Head証拠、正式reviewを一つのIssueへ集中させた結果、単純な成果物に数十時間を要した。
- Decision: 新規Issueへ`shape`、`harden`、`release`のDelivery stageとTime budgetを導入する。shapeは既定120分でBuild、重要Unit Test、日本語iPhone Smokeだけ、hardenは一つの品質問題とtargeted caseだけ、releaseは従来の4条件、Light/Dark、Dynamic Type、VoiceOver、44pt、visual、統合UI、同一Head証拠、反対モデルreview、premerge、提出前確認を必須にする。shape／hardenはrelease-readyと報告しない。同じ原因は最大2回で停止する。
- Consequence: 実装中は対象Test、関連回帰、stage標準、release完全検証の順に広げる。全Xcode／Simulator操作はfinite timeoutとinvocation-owned process group、owned Simulator cleanupを使い、他Issueやユーザーprocessを終了しない。stage未指定のClaim済みcontractはbyte互換の従来profile／scope gateを維持する。
- Related Issue: #44

## D-030: 方向未確定の主要UIに条件付きHTML比較を導入する

- Date: 2026-09-06
- Status: 確定
- Cutover: `2026-09-06T00:31:41Z`。置き換え後のIssue #47の`createdAt`を採用し、この時刻より前に封印されたcontractを新しいroute宣言で遡及的に無効化しないための境界とする。
- Supersedes: D-029でUI方向の確認を最初の`shape`実画面後だけに置いていた開発順序を補正する。D-029のDelivery stage、段階別検証、release品質、有界実行の境界は維持する。
- Context: 新しいアプリの最初のUIなど、視覚・情報設計の取っ掛かりも確定方向もない状態で一案をSwiftUI実装すると、ユーザーの意図を確認する前に構造を固定し、実装後の大幅な手戻りを招く。一方、回帰、標準的なform、localizationや小さな拡張へ一律に比較を課すと、既に承認された方向内の作業まで遅くなる。
- Decision: [UI Direction Gate](development-stages.md#11-適用判定)を条件付きで導入する。現在のユーザーが対象範囲のHTML比較を明示した場合は既存方向の有無にかかわらず最優先で実行し、明示省略は現行性、scope、権限、理由が明確で比較指示と矛盾しないときだけ通常判定を上書きする。通常判定は、(1) exact hierarchy／flowを覆う確定方向があればconfirmed-direction reuse、(2) 対象方向が未確定で最初のUI、最上位navigation／information hierarchyの新設・変更、主要flowの大幅な再設計のいずれかならGate、(3) 方向未確定かつ構造triggerなしならAcceptance criteriaがhierarchy、navigation、primary-flow interactionを決めない範囲だけbounded direction-neutral、の順とし、coverage／trigger／neutralityが曖昧ならGateへfail closedする。cutoverと同時刻以降にClaimするcontractは、既存のAcceptance criteria全体でexactly oneの有効なroute宣言を持つ。宣言は一つのAcceptance criterion本文の先頭（`AC-*:`の直後）にexact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`で置き、`<route>`は`comparison`、`explicit-skip`、`confirmed-direction reuse`、`bounded direction-neutral`、`not-applicable`のいずれかだけとする。route固有の適用事実はReasonの後へ続けてよく、prefix外のroute語は宣言として数えない。確定anchorを`Spec anchors`、選択前提をDependenciesへ記録する。一つの確定briefから同条件・同fidelityで実質的に異なる2–3案をself-contained HTMLとして提示し、immutable pathと提示bytesのexact SHA-256で同定する。共通の選択記録はscope、path／revision、exact SHA-256、採用・不採用要素、screen／state、native適応を持つ。単一案はselected concept IDを、hybridは全採用要素からsource concept IDへのexhaustive mappingを持ち、selected／base concept IDはユーザーがbaseを明示した場合だけ持つ。この確定specと追記型Decisionの専用Issueを依存UI `shape`より先にマージする。
- Consequence: Gateは依存するUI実装だけを止め、Identity bootstrapと独立した非UI作業は継続できる。cutoverと同時刻以降にClaimするこれらの作業はnot-applicable routeとしてUI方向anchorを要求せず、`UI verification`本文はexact `Not applicable`だけとし、対象scopeと非UI理由をGoal／In scope等へ記録し、Acceptance criterion本文を`UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`で開始して、関連する確定済みproduct／spec anchorを`Spec anchors`へ記録する。UI Issueの`UI verification`は既存3 fieldのlive guidanceであり封印されないため、非legacy contractの宣言と根拠はGoal、Acceptance criteria、`Spec anchors`、Dependenciesまたは確定spec／Decisionからreview packetだけで復元可能にする。封印済みcontractの`fetchedAt`がcutoverより前で、Acceptance criterion本文がexact `UI-direction route:` prefixで始まる宣言候補がゼロの場合だけpre-D-030 legacyとし、routeやHTMLを遡及要求せず、contractを変更・再封印しない。cutoverより前でも候補が一つ以上あれば通常検証へ進み、候補がexactly oneかつ許可routeと非空Scope／Reasonを持つ完全な宣言でなければrejectする。cutoverと同時刻以降にも同じexactly-one／完全性を必須とし、prefix外のroute語は候補に数えない。選択待ちは`blocked:user`、選択記録のspec PR待ちは`blocked:dependency`とし、記録がマージされるまで依存Issueを`approved`／Claimしない。HTMLは判断補助に限定し、製品仕様、pixel仕様、SwiftUI source、native verification evidenceにはしない。SwiftUIは選択したhierarchy、flow、state intentをnative semanticsへ翻訳し、現在HeadのBuild、Test、Simulator証拠で検証する。生成済みアプリへ自動適用せず、新しいIssue-contract fieldやHTML用canonical evidence schemaも追加しない。
- Related Issue: #47

## D-031: Identity確定後にシンプルな画像生成アプリアイコンを必須化する

- Date: 2026-09-06
- Status: 確定
- Supersedes: None。D-022のIdentity bootstrap完了境界とD-030のUI Direction Gateを補足し、両者の責務は置き換えない。
- Context: アプリの目的・方向性と名前を決めても、アプリアイコンを後回しにすると仮の空Asset Catalogが最初のUI実装以後も残り、ブランド判断と組み込み確認がリリース直前へ集中する。ユーザーは名前などを決める段階で画像生成によるできるだけシンプルなアイコンも作成する方針を指定した。
- Decision: [アプリアイコン方針](product.md#32-アプリアイコン)に従い、Identity bootstrap後、最初のユーザー向けUI `shape`より前に専用App Icon Issueを完了する。一つの確定briefからbuilt-in画像生成でstable ID付きのシンプルな2案を作り、ユーザーが明示選択した1案だけを1024 x 1024の不透明PNGとしてAsset Catalogへ統合する。組合せや重要な変更は提示済みrevisionを上書きせず再生成する。選択済みassetとsanitized recordだけをGit管理し、現在のApple公式要件を実行時に再確認する。
- Consequence: アプリ名と目的に整合する識別可能なiconを早期に確定できる。選択待ちは`blocked:user`だが独立した非UI作業は続行できる。アプリアイコンは画面階層、navigation、primary-flow interactionを承認しないため、D-030のUI Direction Gateを満たしたことにはならない。テンプレート自身にはアプリ固有iconを追加せず、既存生成済みrepositoryへ自動適用しない。
- Related Issue: #49

## D-032: 3D asset authoringをCodex GPT-6 Astraへ固定する

- Date: 2026-09-06
- Status: 確定
- Supersedes: None。D-024のClaude／Codex同等権限を一般開発で維持し、3D authoringだけに限定したmodel routeを追加する。
- Context: ClaudeとCodexはどちらもアプリ開発を進められる一方、3Dモデル制作ではCodexのGPT-6 Astraが特に優れているため、一般開発を一方へ固定せず制作能力の差を狭い責務境界として明示する必要がある。あわせて、このiOS templateでは第三の開発経路を考慮しないことがユーザーから指定された。
- Decision: [3Dモデル制作方針](product.md#51-3dモデル制作方針)に従い、3Dモデル、mesh、material、rig、animationの作成・生成・形状変更は共有`ios-3d-assets` skillへrouteし、Codexのexact model `gpt-6-astra`だけがauthoringする。Claudeまたは別のCodex modelが作業を開始した場合もauthoring部分を同モデルへ依頼し、利用不能時は別modelへfallbackせず`blocked:environment`とする。ClaudeとCodexはそれ以外の仕様化、実装、検証、レビュー、設定済み外部操作を同等に担当できる。
- Consequence: Claudeや別のCodex modelは3D要件、参照、受領済みassetの統合、GLB／USDZ等の形式検証、RealityKit実装、Build／Test、視覚確認、reviewを担当できるが、3D asset bytesのauthoring主体にはならない。3Dを含むIssue／PR証拠へexact authoring modelを記録する。現行tracked repositoryから第三の開発経路への参照を除去し、unsupported executorの拒否テストはprovider-neutralな値で維持する。
- Related Issue: #51（元の依頼）、#59（実装の引き継ぎ）

## D-033: App Store原稿の確認状態と新規登録準備を分離する

- Date: 2026-09-09
- Status: 確定
- Supersedes: None。D-014の原稿集約を具体化し、D-024の権限、D-026の未決公開先、D-029のrelease gateを維持する。
- Context: Identity変換後もApp Store原稿に仮Bundleや下書きが残り、SDK追加後のprivacy申告や一時文案と正本が乖離しうる。App未作成、Team未設定、契約、名前重複を一つの登録失敗として扱うと、安全な再開ができない。
- Decision: [原稿の正本と登録準備](architecture.md#91-原稿の正本と登録準備)に従い、fieldごとの導出元、確認根拠、未決理由、draft/confirmed/remote-savedを記録する。登録前には個人TeamとBundleによる既存App照合を行い、名前・SKU・access等の判断と契約・法務・価格のhandoffを分ける。一時原稿はレビュー後にApp Storeへ昇格し、SDKと実装変更で関連申告を再監査する。
- Consequence: 独立欄の準備は継続できるが、部分準備を完全packageや提出承認にしない。既存schema/validatorと封印済み証拠をこの文書変更で書き換えず、自動検出・登録operationは依存する後続実装Issueへ分離する。公開先や実アプリの値は捏造せず、スクリーンショットは別途確定前に生成しない。
- Related Issue: #53

## D-034: BaseとHeadの全repository test証拠を明示契約へ束縛する

- Date: 2026-09-09
- Status: 確定
- Supersedes: None。D-029のstage／profileと既存の封印済みcontract・証拠の互換性を維持する。
- Context: BaseとHeadの両方で全repository testsを要求するIssueを、Headだけの記録で完了させてはいけない。#60のAC-1とAC-6が新形式の選択条件と、このIssue自身での両revisionの実行を要求する。
- Decision: Claim前の一つのAC本文先頭をexact `Repository-test scope: base-and-head; `で開始し、その後に非空の受け入れ条件を続ける。この宣言だけが新しいschema v2 repository recordを要求する。重複・不完全・未知のscope宣言は拒否し、宣言なしの既存sealed contractには旧Head-only経路を維持する。新しいcontract fieldや任意のCLI modeで選択しない。
- Consequence: 現在Headのproducerが各revision自身の全tracked testをclean detached worktreeで実行し、BaseとHeadのinventory、tested SHA、有限timeout、argv、結果、時刻、digestを別々に記録する。宣言ACは両方の全suiteへ対応付ける。Base mappingはbaseline／regressionの証拠であり、Headで追加した機能の実装証拠ではない。packet内の値とcanonical recordのexact bytesを束縛し、reviewerへの引き渡し、result／receipt publication、premergeで欠落・改ざん・差し替えを拒否する。旧record／packet／receiptを変換・再封印しない。
- Related Issue: #60

## D-035: App Store原稿の先行保存と正式提出を別モードにする

- Date: 2026-09-09
- Status: 確定
- Supersedes: None。D-033のfield inventoryと確認状態を拡張し、D-024の権限、D-026の未決公開先、D-029のrelease gateを維持する。
- Context: 画像を保留して確認済み原稿だけ先に入力したい依頼を、全素材とbuildの完成を要求する提出入口では表現できない。一方、Saveの公開影響、locale別の部分成功、remote driftを無視すると未許可の公開や誤った再開を招く。
- Decision: [保存と提出の分離](architecture.md#92-原稿保存と正式提出の分離)に従い、offline draft、認可済みの選択的save、完全packageのready、明示許可されたsubmitを区別する。保存はsourceと正しいremote identityに束縛し、form全体の差分・公開影響を確認した後に行い、再読取で結果を検証する。未確定画像・build・法務は独立した一般原稿を止めないが、それら自体の更新やrelease readinessを許可しない。
- Consequence: 部分保存の別形式journalはpackage外に置き、既存package/result/checklistを変更・流用しない。#52は仕様と薄いroutingのみで、専用save実装は後続Issueへ分離する。未実装の間は既存提出scriptや手動操作で代用しない。正式提出の全素材、申告、法務承認、audit、明示提出許可は維持する。
- Related Issue: #52

## D-036: 非application workflow変更をXcode不要のharden経路へ分離する

- Date: 2026-09-13
- Status: 確定
- Supersedes: D-025のdelivery gateを一律strict完全検証へ結び付ける部分と、D-029のworkflow変更にapplication検証の例外がなかった部分。D-029の段階別品質、D-034の明示的Base／Head契約、account・Head・review・pre-merge境界は維持する。
- Context: delivery tool、schema、validator、review、evidence producerだけの変更でもXcode Build、Simulator 4条件、visual確認を行うと、アプリ挙動を一切変えないIssueの検証が実装より長くなり、英語／iPad仕上げを最後へ寄せる方針も機械的に実現できない。
- Decision: application source、Xcode project、asset、localization、Bundle設定、App Store／TestFlight経路へ触れない非UI workflow変更は`harden + strict`のworkflow-only経路で検証する。application `Verification`／`Verification scope`は持たず、Xcode、Build、Unit、Simulator、Screenshot、visual evaluationを正当な`not-applicable`とする。対象repository tests、仕様整合、contract、current-Head、strict review、blocking finding、pre-merge gateは維持する。`release`は`type:release`の実アプリrelease candidateだけに限定する。
- Consequence: workflow gateの安全性を下げずに、無関係なiPhone／iPad・日本語／英語matrixを起動しない。allowlist外path、application／release path、App Store operation、Verification混入、repository evidence欠落またはidentity不一致はfail closedになる。#82のcutover前に封印されたworkflow-only contractは全AC mappingのexact unionを対象testとして維持し、それ以外の従来Head-only contractは全tracked testを維持する。cutover後の対象選定はD-037のimmutable planへ移行する。
- Related Issue: #77

## D-037: Repository testの要求scopeと実行計画を二段階で封印する

- Date: 2026-09-13
- Status: 確定
- Cutover: `2026-09-13T13:03:38Z`。Issue #82の`createdAt`を採用し、それより前のsealed contractとschema v1／v2 evidenceを遡及変更しない。
- Supersedes: D-036のimpact manifest未導入境界と、D-034の新規contract向け宣言形式。D-034の既存Base／Head証拠、旧contract、account・Head・review・pre-merge境界は維持する。
- Context: workflow変更のたびに全repository testsを反復すると、実装と無関係な検証が所要時間の大半を占める。一方、Issue作成時には最終Head差分が存在しないため、exact test pathを先に固定すると過不足や恣意的な選択が生じる。
- Decision: cutover以後のworkflow-only `harden + strict` contractは、一つのAC本文先頭にexact `Repository-test scope: targeted|head-all|base-and-head; Reason: <nonempty>`を宣言する。contractは要求scopeと理由だけを封印し、実装後のimmutable Base、Head、contract bytes、Headの`Config/repository-tests.json`、Base..Head changed pathsからrunnerがresolved scopeとexact ordered test pathsを決定する。`targeted`は全changed pathが一つの既知domainへ解決した場合だけ許可し、unmatched path、複数domain、manifest／runner／test inventory変更は`head-all`へ昇格する。`head-all`はHead全件、`base-and-head`は両revision全件を実行する。
- Consequence: exact test一覧、manifest／diff digest、要求／解決理由、全ACのordered mappingをimmutable `repository-test-plan.json`へno-replaceで保存し、schema v3 `repository-tests.json`、review packet/result/receipt、PR本文、pre-merge gateが同じplan bytesを再計算・照合する。開発中は関連testだけを使い、canonical全件は最終候補Headで必要な場合に一度実行する。旧schema v1／v2とcutover前contractは変換しない。
- Related Issue: #82

## D-038: リリース目標ごとに6開発フェーズと部分再承認を適用する

- Date: 2026-09-14
- Status: 確定
- Supersedes: D-027の日本語iPhoneから英語／iPadへ進む二段階を、目的・基盤・開発・適応・品質・公開の6フェーズへ一般化する。D-029のDelivery stage、段階別検証、安全境界は維持し、Phaseとは別軸にする。
- Context: 前工程を完了してから次へ進む規律を保ちつつ、Phase 1〜3の軽微な仕様修正や後段で見つかった問題まで全面的な巻き戻しにすると、個人開発の速度と意思決定履歴の両方を損なう。開発中の全条件テストを減らして英語／iPadと完全品質確認を後段へ分ける一方、証拠の付替えや重大不具合の安易な許容を防ぐ必要がある。並列検証ではSimulatorの競合とdata蓄積もMac全体で管理する必要がある。
- Decision: 一つのMVPまたは公開目標をrelease unitとし、Phase 1 目的・リリース仕様、Phase 2 基盤・UI方向、Phase 3 日本語iPhone開発、Phase 4 英語・iPad対応、Phase 5 品質保証、Phase 6 リリースを適用する。依存する次Phase実装は前Phase完了まで開始しないが、read-only調査、草案、依存しない作業は先行できる。Phase 1〜3の軽微変更は委任範囲で継続し、目的、MVP、主要flow、採用system、data、重大riskの変更だけを影響する最も早いPhaseへ部分的に戻す。最終判断はユーザーとし、特にPhase 1、3、4、5の出口と公開範囲をrelease revisionへ束縛する。変更、証拠適用、不具合許容、テスト省略、未検証を追記型で区別し、重大な安全／認証／課金／privacy／法務違反は公開blockerとする。Phase 5〜6の同一候補では適用可能な証拠を重複実行しないが、#86の実装前にcanonical証拠の再利用・改訂を許可しない。AI検証用Simulatorは必要時作成・使用後削除、Mac全体でiPhone／iPad合計最大4台、sessionごと原則1台とし、枠取得、逐次matrix、証拠保全、所有確認、異常終了回収、容量停止を要求する。
- Consequence: PhaseはDelivery stage／profile／verification scope／workflow stateを置き換えず、各Issueは従来どおり現在Headの必要検証とreviewを持つ。既存アプリと緊急修正は適用可能な確定基盤を再利用して影響Phaseから開始できる。SimulatorのMac共通lease、削除、孤児回収と既存固定UDID移行は#89、Phase記録／再gateは#85、証拠適用は#86、不具合判断は#87、skills／既存Issue移行は#88で実装し、この仕様だけを稼働証拠にしない。既存sealed contractと過去のDecisionは変更しない。
- Related Issue: #83、#84、#85、#86、#87、#88、#89

## D-039: 通常検証を5分／15分のtargeted実行へ制限する

- Date: 2026-09-14
- Status: 確定
- Supersedes: D-037の`targeted`を未知path、複数domain、manifest／runner／test変更から自動`head-all`へ昇格する部分。D-037のimmutable planとexact-byte evidence、D-038の6フェーズ、安全・Head・review・pre-merge境界は維持する。
- Context: Issue #82では変更のたびに54件のrepository suiteへ自動昇格し、約103分の実行を4回、合計約6時間55分繰り返した。通常開発の目的は変更箇所を短時間で確認することであり、英語／iPadと全件回帰を毎回実行することではない。
- Decision: 実装中の対象testは1 command 300秒、通常のIssue完了用`targeted` repository suiteはaggregate 900秒を上限とする。`targeted`は既知の単一または複数domainに属するtestの決定論的unionを選び、manifest、runner、tracked test変更を理由に自動`head-all`へ昇格しない。未知pathは全件実行せずplan生成を拒否する。`head-all`／`base-and-head`、英語／日本語×iPhone／iPadの4条件はrelease、nightly相当の明示実行、またはユーザーがIssue contractで明示要求した場合だけ使う。同一Issue／Head／scopeの失敗・timeout後は直接再実行を拒否し、選択済み対象testの診断成功後に1回だけ再試行できる。
- Consequence: `shape`は日本語iPhone、`harden`はtargeted subsetを維持し、strict対象も認証・課金・privacy・migration等の関連安全testだけを追加して無関係な全件へ拡大しない。runnerは実行前にscope、ordered tests、件数、child／aggregate上限を表示し、上限到達時は未実行testを報告して成功証拠を発行しない。未検証条件は延期・未検証として残し、release-readyとは報告しない。
- Related Issue: #79

## D-040: Simulator条件と使い捨て実行UDIDを分離する

- Date: 2026-09-14
- Status: 確定
- Supersedes: D-016のbatch固定対象から実行UDIDを除外し、D-021のrepository単位直列化をMac共通capacityで補強する。D-016のRuntime／Device Type固定、D-038の最大4台・sessionごと1台・使用後削除は維持する。
- Context: 旧schema v1 matrixは4条件のUDIDを事前作成して封印し、runnerはeraseして再利用していた。この方式では複数repositoryの並行実行をMac全体で制限できず、検証後のdevice dataが累積する一方、単にdeleteを追加すると再試行と削除後finalizationが旧UDIDへ依存して破綻する。
- Decision: 新規matrix producerはschema v2としてbatch内のXcode、Runtime、Device Type、locale、language、case順だけをimmutableに固定する。runnerはstable session identityを子processへ継承し、repository lockの内側でMac共通の原子的leaseを取得する。iPhone／iPad合計4枠、sessionごと1枠、作成前の空き容量確認を強制し、caseごとに新規UDIDを作成、検証、sanitized allocation receipt保全、exact UDIDのshutdown/delete、一覧とdata path消失確認を終えてから枠を返す。owner processが消えた予約／deviceはPID start identityとlive device identityを照合して次回起動時に回収し、管理外・改ざん・symlink・identity不一致は保護する。
- Consequence: 4条件も一台ずつ順次実行され、4台を常設するpoolは作らない。最終証拠はmatrix digestに加えてcase順のallocation ID、UDID、session／attempt、receipt path／digest、削除結果、作成前／削除後の空き容量を固定するため、device削除後もreviewとfinalizationが可能になる。旧schema v1 matrix／contract／verifyは書き換えずlegacy経路で受理し、新しいattemptは旧UDIDの証拠へ付け替えない。inventoryはdurable owner recordと管理外保護対象を区別し、`simctl delete unavailable`や全件削除を代替にしない。
- Related Issue: #89

## D-041: 明示承認したCodex-primary IssueだけGrok review fallbackを許可する

- Date: 2026-09-14
- Status: 確定
- Supersedes: D-007の固定Codex→Claude pairを、Claude利用不能かつIssue単位のユーザー明示承認がある場合だけ拡張する。D-007の独立review、D-025のcurrent-Head証拠、D-038〜D-040の段階・時間・Simulator境界は維持する。
- Context: #89のSimulator lifecycle実装はtargeted testsを通過したが、Claude reviewerの認証不能により正式reviewを完了できなかった。Grokによる助言は不足していたtimeout cleanupを発見した一方、既存schemaではadvisory結果を正式approvalへ昇格できず、無断fallbackや手書きreviewを許すと独立性とprovenanceを失う。
- Decision: reviewerの既定pairはCodex primary→Claude、Claude primary→Codexのままとする。例外はAcceptance criterion本文先頭のexact `Opposite-review route: grok-fallback; Primary: codex; Reviewer: cursor-grok-4.6-xhigh; Approval: user-explicit; Reason: <nonempty>`がsealed contract全体でexactly one存在するIssueだけとし、Codex primaryからexact model `cursor-grok-4.6-xhigh`を固定launcherで呼ぶ。launcherはCursorの`ask` mode、非対話、read-only指示、閉じたstdin、600秒以下のtimeoutとprocess-group回収を強制し、ambient provider／repository credentialを子processへ継承しない。packet、result、receipt、PR renderer、premerge gateは同じroute、reviewer model、launcher bytes、Issue／contract／Base／Head／Verifyとdigestを照合する。
- Consequence: silent／automatic fallback、Claude primary→Grok、任意Grok alias、primary自身の承認、旧contractへの遡及適用はできない。起動失敗、timeout、空／不正JSON、schema／evidence不一致、repository／artifact write検出はreview／receiptを公開せず`blocked:review`にする。provider envelopeはvalidな内側Resultだけを正規化し、認証identityやtelemetryをartifactへ保存しない。#89のcommitは#93へ移植してcurrent-Head evidenceを作り直し、#93完了後も#89を削除せずsuperseded履歴として保持する。
- Related Issue: #93（#89を移植して完了）

## D-042: 独立した長時間repository testを専用domainへ分離する

- Date: 2026-09-14
- Status: 確定
- Supersedes: None。D-039の1件300秒／targeted全体900秒と、D-037のimmutable plan／全changed-path coverageを維持する。
- Context: #93の初回canonical planでは、変更したfoundation testが未変更のbootstrap asset群を、merge testが未変更のworkflow state群をそれぞれ広いdomain経由で選び、37件の決定論的unionが18件目の実行中に900秒へ到達した。active testの単体診断は成功しており、実装不良ではなくdomain粒度が時間上限と一致していなかった。
- Decision: 独立したfoundation entrypointとmerge publication entrypoint／producerをそれぞれ専用domainへ分離する。変更されたtest自身は必ず選択し、merge producer変更も同じmerge domainへ解決する。bootstrap asset producer、workflow state producer、provider、review、Simulator、repository-test producer等の実変更は従来どおり各domainのunionへ解決し、未知pathや失敗testを除外しない。
- Consequence: #93の新Headは初回timeout artifactを保持したままplanを再生成し、未変更のbootstrap／workflow全体だけを除いたtargeted集合を一度実行する。時間短縮のために受け入れ条件、変更path、失敗結果を隠さず、同じHeadの失敗を無条件再実行しない。旧Headのplan／failure artifactと既存sealed contractは書き換えない。
- Related Issue: #93

## D-043: Workflow evidence publisherをreview contractから分離する

- Date: 2026-09-14
- Status: 確定
- Supersedes: None。D-042の専用domain原則をworkflow evidence publisherへ適用し、D-039の900秒上限とD-037のchanged-path coverageを維持する。
- Context: #93の25件へ縮小したcanonical planは全対象を開始したものの、最後のworkflow evidence publisher test実行中に900秒へ到達した。このtestは単体で約41秒後に成功し、#93はpublisher本体を変更していないため、review contract変更から一律に選ぶ結合が時間超過の残因だった。
- Decision: `tools/publish-workflow-verify.sh`とその専用testを`workflow-evidence` domainへ移し、review packet／result／receipt／renderer／premergeの変更だけでは選択しない。publisherまたはtest自身を変更した場合は両方を同じdomainから必ず選択する。
- Consequence: #93の次HeadではGrok reviewとSimulator lifecycleに対応する24件を維持し、未変更publisher testだけを除く。旧Headのtimeoutと単体診断成功を保持し、失敗を成功へ読み替えたり同一Headで無条件再実行したりしない。
- Related Issue: #93

## D-044: Authority policyとUI directionの回帰domainを分離する

- Date: 2026-09-14
- Status: 確定
- Supersedes: None。D-042の専用domain原則を補足し、provider実装変更時のprovider-security testsとUI direction変更時の専用testは維持する。
- Context: `docs/AUTHORITY.md`の反対モデルreview節だけを変更しても、secret-storeとSupabaseを含むprovider-security全体が選ばれていた。また一般的な仕様変更だけで未変更のUI Direction skill testが選ばれ、#93の受け入れ範囲と一致しない小さな実行が累積していた。
- Decision: authority文書は`authority-policy`へ分離し、account／target所有規則を検査するprovider ownership testを対応付ける。`Config/ownership.yml`、provider preflight、security／secret実装は従来の`provider-security`へ残す。UI Direction skillと専用testは`ui-direction`へ分離し、一般仕様の`specification`変更だけでは選択しない。
- Consequence: #93ではGrok review authorityの回帰を保持しつつ、変更していないprovider実装3件とUI Direction testを除く。将来それらのproducer／skill／testを変更した場合は各専用domainから再び選択され、未知pathを黙って省略しない。
- Related Issue: #93

## D-045: Grok正式reviewを外側timeoutより短いbounded passへ固定する

- Date: 2026-09-14
- Status: 確定
- Supersedes: None。D-041のexact model、read-only、600秒以下のwatchdog、完全Result検証、timeout時blockedを維持する。
- Context: #93の約300KBのcanonical diffに対する初回Grok正式reviewは、transport自体が約9秒で応答可能な環境でも、探索が600秒まで完了せずtimeoutした。review／receiptは正しく未発行となったが、外側watchdogと同じ時間まで探索を許すだけではvalid Resultを返す余地がなかった。
- Decision: 固定Grok launcherは、packetとsealed evidence、exact diffの変更production code／対応test、具体的不一致がある場合だけの追加source、という順で一回のbounded passを480秒以内に終えるよう指示する。launcherがpacket bytesからresult identityと全ACのexact evidence reference scaffoldを決定論的に提示するが、verdict、finding、supported／unsupportedはreviewerだけが決める。時間内に支持できないACは探索継続ではなくvalidなchanges-requestedと具体的findingで返す。
- Consequence: 外側600秒watchdogには結果の返却・検証余地が残る。scaffoldの改ざん、誤った判断、schema不一致、timeout、writeは従来どおり承認にならず、ユーザー承認済みGrok以外へfallbackしない。#93は新Headでcanonical targeted evidenceを作り直してから一度だけ正式reviewを再実行する。
- Related Issue: #93

## D-046: Device消失後もdata path消失までSimulator枠を保持する

- Date: 2026-09-14
- Status: 確定
- Supersedes: D-040の`already-absent`を、device一覧だけでなく記録済みdata pathの消失確認まで明確化する。他の所有identity、最大4台、session 1台、逐次実行境界は維持する。
- Context: #93のGrok正式reviewは、owned UDIDが`simctl list`から消えた一方で記録済みdata pathが残ると、`cleanup_record!`が`finish_release!`を呼び、`dataPathAbsent: false`のままcleanup passed／releasedとして枠を返せることを指摘した。通常のdelete直後だけはdata pathを確認していたため、二重releaseと孤児回収のalready-absent経路に欠落があった。
- Decision: `finish_release!`自体がno-followのpath存在確認を行い、data pathが残る、symlink等が存在する、またはabsenceを確認できない場合は`cleanup-failed`として枠を保持する。device一覧から消えている場合も同じ確認を通し、path消失後だけ`already-absent`の冪等成功を許可する。
- Consequence: releaseとorphan recoveryの両方へ「device不在かつdata残留」のproduction-entry testを追加し、失敗中のactive count保持、残留理由、path消失後の安全な再開を確認する。device名や一覧だけでdata削除を推測しない。
- Related Issue: #93

## D-047: Cursor進捗prefixから唯一の末尾Resultだけを正規化する

- Date: 2026-09-14
- Status: 確定
- Supersedes: D-041のprovider envelope正規化を、Cursorが`result`先頭へ進捗文を集約する実挙動に限定して補足する。完全schema、finding非改変、receipt、失敗時blockedは維持する。
- Context: #93のbounded Grok reviewは時間内に具体的なchanges-requested Resultを返したが、その前へ日本語の進捗文が連結され、内側文字列全体のJSON parseに失敗した。手作業でsuffixをコピーするとreview provenanceを失う一方、完全な最終objectを機械的に一意抽出できる境界が必要だった。
- Decision: provider envelopeの`result`全体がJSONでない場合、各`{`から末尾までをparseし、16 KiB以下のvalid UTF-8 prefixがbrace／NULを含まず、末尾に完全なJSON object候補がexactly oneだけ存在するときに限りそのobjectを正規化する。その後は既存のIssue／Base／Head／digest／reviewer／finding／全AC evidence validatorを一切省略しない。
- Consequence: progress prefix、raw envelope、telemetryはartifactへ保存しない。複数object、途中object、trailing prose、不正UTF-8、過大prefix、schema不一致はcanonical review／receiptを発行せず`blocked:review`のままとし、主agentがverdictやfindingを修正しない。
- Related Issue: #93

## D-048: Claim後のIssue contract改訂を追記型authority chainへ限定する

- Date: 2026-09-15
- Status: 確定
- Supersedes: `fetchedAt`を含むsealed contract全体がClaim後immutableである従来境界を、目的と権限を維持した検証調整だけに限定して拡張する。既存contract bytes、D-025のcurrent-Head evidence、D-037のtest plan、D-038のrelease revision／Phase authorityは維持する。
- Context: 実装後の反対モデルfindingやユーザー判断によりVerificationまたはAcceptance criteriaの説明を狭く直す場合、既存Issueを捨てて履歴を分断するか、live本文とsealed snapshotを非正規にずらすしかなかった。一方、任意の再封印を許すとGoal、MVP、外部権限、古い証拠を同じIssueの承認として置換できる。
- Decision: exact `in-progress`の同一Issueだけに専用revision経路を設け、変更fieldを`verification`、同一ID・同一順序のAcceptance criteria本文、単調増加する`fetchedAt`へ限定する。AC本文先頭のUI方向、repository-test scope、opposite-review authority、release-phase bindingの宣言identityは改訂前後で固定し、追加・削除・移動・保護値変更を許可しない。authorityは、同じcontract／source Headのcanonical blocking `review-finding`、設定済みGitHub ownerのexact markerによる`user-explicit`、同markerで現在executorを指定する`user-delegated`の三つだけとする。各revisionは旧／新body・contract、旧／新state、changed fields、reason、authority、前record digest、失効対象、Base／Branch／worktree／source Headをimmutable no-replace chainへ保存する。Goal、MVP、spec／dependency、Phase、stage、profile、scope、type、external operation／approvalの変更と、許可field内でも目的を別物へする意味変更は別Issueと現在ユーザー判断へ戻す。
- Consequence: activationは以前のHead bindingを外し、旧verification／reviewを削除せず履歴へ残す。pending中またはchain／state／contract不一致ではstate transition、resume、external authorization、review packet、pre-mergeをfail closedにし、exact同一requestだけを再開する。改訂後は最新contract digestと新Headで対象検証・反対モデルreview・pre-mergeを再取得する。application runnerの単一`unitTestIdentifier`制約を維持し、複数確認を非正規なidentifier注入で回避しない。
- Related Issue: #38

## D-049: Phase 5証拠のPhase 6適用判断を候補Headごとに封印する

- Date: 2026-09-15
- Status: 確定
- Supersedes: D-038で再利用候補としてだけ定義したPhase 5から6への証拠移行を、canonical producer、判定、consumer、legacy境界まで具体化する。Phase出口、current-Head evidence、提出固有preflightは維持する。
- Context: Phase 5とPhase 6でcandidateと検証条件が同じ場合にfull verificationを繰り返すと時間とSimulator資源を浪費する一方、旧証拠のpathだけをPhase 6へ貼ると、Head、artifact、configuration、SDK、signing、scopeまたは依存関係の変化を見落とし、実行していない再検証を成功と表現できる。
- Decision: Phase 6 `implementation`ごとに、Phase 5 passed full application verification、source／target contract、Release-phase Claim gateで検証済みのbindingが封印するphase-record path／digest参照、release／revision／scope、source..target Git diff、candidate artifact／configuration／SDK／signing context、全changed pathのimpact／dependency／reasonを`.artifacts/issues/<issue>/<head>/evidence-applicability.json`へcanonical no-replaceで封印する。source Base→source Headとtarget Base→target Headはそれぞれ祖先関係を必須とするが、squash後の分岐を扱うためsource Head→target Headの祖先関係は要求せず、参照可能な両commit object間のactual diffを固定する。exact同一Head／contextかつ差分、unknown、missing dependency、scope拡張なしだけを`reuse`とし、Head／context／affected pathの変更を`targeted-reverify`、unknown／missing dependency／scope拡張を`expanded-verification`とする。後二者は判定後のtarget passed evidenceを必須とし、review packet、PR renderer、pre-merge、release/package preflightは同じrecordと元証拠をdescriptor-boundで再検証する。release-phase binding互換cutoffを`2026-09-14T00:00:00Z`とする。
- Consequence: config、signing、SDKを一律に影響なしとは扱わず、別candidate、旧review、改ざん、未検証をfail closedにできる。cutoff前のbindingなしPhase 5 contractは元bytesを変更せず`sourceLegacy: true`、`sourceRecord: null`のlegacy sourceとして参照できるが、target bindingとsource full proof／Git identityを必須とし、cutoff後のsourceにはPhase 5 bindingを要求する。Phase 6 bindingのないlegacy Issueは直接full `verify.json`経路を維持する。package、privacy、legal、公開権限、provider readbackなど提出固有checkは再利用せず毎回実行する。
- Related Issue: #86

## D-050: Phase 5〜6の残件と停止後判断を候補Headごとに封印する

- Date: 2026-09-15
- Status: 確定
- Supersedes: D-038のPhase出口にあるfree-formな既知不具合・省略・未検証と、D-039の停止後選択を、候補単位のcanonical recordとconsumer gateへ具体化する。D-049の証拠適用判断とD-047／#97のreview low finding保持は独立したまま維持する。
- Context: Phase 5〜6で時間を区切って品質を判断するには軽微残件や未検証を許容できる一方、plain textだけでは別release／revision／Headの承認流用、期限切れ承認、重大blockerの軽微扱い、timeout／未実行の成功化、failure後の無制限再実行をreview、PR、pre-merge、releaseで一貫して拒否できない。
- Decision: cutoverを`2026-09-15T11:00:00Z`とし、同時刻以後に封印されたPhase 5／6 `implementation` contractごとに`.artifacts/issues/<issue>/<head>/release-disposition.json`をcanonical no-replaceで必須化する。recordはrelease identifier／revision／phase／scope／Base phase-record path／digest、Issue／Base／Head／Issue-contract path／digestを固定し、`accepted-defect`、`deferred-defect`、`omitted-test`、`unverified`と停止後`executionDecisions`を別配列で保持する。軽微不具合acceptはsafe classificationとlow severity、影響、回避策、修正費用、同一candidateへ束縛したuser approval、承認時刻、期限、follow-up Issue、再評価条件を必須とする。データ消失、秘密漏洩、課金、重大な金額／日時計算、主要導線crash、認証、privacy、法務、unknownをacceptしない。current Headにある全repository failure recordをexact path／digestで一件ずつ`shrink`、`split`、`defer`、`wait`へ対応付け、reason、actor／authority、follow-upまたは再開条件、時刻を要求する。packet、result publication、PR renderer、pre-merge、release preflightは同じrecordとfailure bytesを保持・再検証する。
- Consequence: accepted、deferred、omitted、unverified、failed／timeout、review low finding、evidence applicabilityを別概念として表示・判定できる。critical／high／unknownのdeferred defectと`wait`はrelease readinessをblockし、failure／timeout／未実行はpassedへ昇格しない。cutover前のcontractは元bytesを変更せず従来gateを維持し、recordを推測・遡及生成しない。`split`／`defer`はuser authorityとfollow-up Issueを必要とし、承認待ち時間を実行budgetへ加算しない。
- Related Issue: #87

## D-051: 全アプリでSystem Experiencesの評価を必須化する

- Date: 2026-09-15
- Status: 確定
- Supersedes: None。D-038のPhase gate、D-031のApp Icon Gate、D-030のUI Direction Gate、D-029のDelivery stage契約を補足し、それぞれの独立した判断と依存関係を維持する。
- Context: Widget、Live Activities、Dynamic Island、Controls、Siri／App Intentsは、アプリの主要機能を実装した後で検討すると、共有data、domain action、extension process、capability、privacy、localization、release構成の手戻りが大きくなる。一方、全アプリへframeworkやentitlementを先行導入すると、不要な複雑性と検証負担を増やす。
- Decision: Identity bootstrap後、主要Feature Issueの計画またはClaimより前に、専用System Experiences Planning Issueで`widget`、`live-activities`、`dynamic-island`、`controls`、`siri-app-intents`の5面を最新のApple公式sourceに基づいて評価する。各面を`adopt-now`、`defer`、`not-applicable`、`blocked:user`へ分類し、提供価値、対象task／system space、開始点と成功結果、source of truthとstaleness、offline／error／recovery、lock-state redaction、accessibility、日英localization、fallback、telemetry privacy境界、検証、release依存、再評価条件を記録する。評価はmandatory、採用はoptionalとし、最終判断はユーザーへ留保する。計画だけでframework、Extension target、entitlementを導入せず、`adopt-now`だけを依存Issueへ分ける。一面の未決は依存scopeだけを部分blockingとする。App IconはIdentity bootstrap後に並行でき、採用するsystem UIは別途UI Direction Gateを通す。既存アプリへ現在の依頼または機能上のtriggerなしに遡及適用しない。
- Consequence: Phase 1でsystem experienceの価値と採否方針をrelease scopeへ含め、Phase 2で採用面のaction／data／process／capability設計とIssue graphを確定する。主要Featureは完了済み計画matrixを参照し、採用面の前提をDependenciesへ置く。D-029の既存Delivery stage契約は置き換えず、planning IssueとそのIssue graphの各Issueは従来どおり`shape`／`harden`／`release`、正のTime budget、stage別検証を持つ。後から採否を変える場合は理由、影響、失効する判断、再評価条件を追記し、影響する最も早いPhaseだけを再gateする。共有Claude参照は既存contractどおり相対symlinkとし、workflow-only evidenceは同一Headのregular shared `SKILL.md`へ名前一致で向く新規linkだけを受理する。
- Related Issue: #73

## D-052: 派生アプリの共通改善を明示的なテンプレートIssueへ変換する

- Date: 2026-09-16
- Status: 確定
- Supersedes: None。D-004の共有skill正本、D-007の外部操作境界、D-029のDelivery stage、D-037のtargeted repository testを維持する。
- Context: 派生アプリでテンプレート由来の問題を見つけても、発見元のoriginを誤って報告先にする、古いtemplate snapshotだけで現行不具合と断定する、既存Issueを重複作成する、または問題発見を外部投稿の承認として扱う危険があった。一方、報告手順がないと共通修正が各アプリへ閉じ、同じ調査と修正を繰り返す。
- Decision: 共有`report-template-issue` skillを追加し、発見元repositoryと明示的な報告先`yuto1201/iOS-Template`を分離する。current templateとの比較、`app-specific`／`template-common`／`environment-only`の根拠付き分類、open／closed Issueの本文と解決内容を含む重複確認、現行Issue形式とvalidatorによるdraft検証、`external-ops`によるaccount／target／operation／Executor確認、作成後readbackを順に必須化する。upstream remoteやローカルcheckoutがなくてもfixed targetを検証できるが、由来、target、共通性、権限を推測しない。曖昧な作成応答は検索で照合し、無条件に再実行しない。
- Consequence: 共通問題は追跡可能なIssueへ集約でき、アプリ固有または環境だけの問題、既存Issue、現行版で修正済みの問題を新規投稿から除外できる。skillは報告だけを完了し、template修正、PR／merge、派生アプリへの反映を完了扱いしない。新規派生アプリは共有skillとportable Claude symlinkを含み、既存アプリには正本、symlink、依存skill、validatorを明示して個別導入する。
- Related Issue: #67

## D-053: 6フェーズをIssue consumerとApp Store画像経路へ統合する

- Date: 2026-09-16
- Status: 確定
- Supersedes: None。D-038の6フェーズ、D-040／D-046のSimulator資源境界、D-049のPhase 5→6証拠適用をconsumerへ接続し、各producerとlegacy互換は維持する。
- Context: Phase record、Claim gate、証拠適用、残件判断は実装済みでも、Issue formとplanning／shipping／verification／App Store skillsがbindingを標準入力として案内しなければ、新しいIssueが旧運用へ戻る余地があった。またApp Store撮影はdisplay familyを先に複数作成し、独立Goldie skillはPhase 6、locale分離、iPad代替、共通Simulator枠と接続されていなかった。
- Decision: release unitに属する新規Issueは既存AC一つのexact `Release-phase binding:`からBase commit上のimmutable recordを参照し、planning、Claim、batch、bootstrap、verification、preparation、submissionが同じrelease／revision／Phase／scopeを消費する。bindingのないsealed Issueは`legacy-unbound`として遡及変更しない。Phase 3を日本語iPhone、Phase 4を英語／iPad、Phase 5を完全品質、Phase 6を証拠適用と公開準備へrouteする。Phase 6のiPhone 6.9-inch画像はlocale別Goldie config／import／renderを標準とし、iPadはrepository撮影経路を使う。新規raw撮影はMac共通resource managerで一session一台を逐次allocate／deleteし、画像とreceiptをdevice外へ保存する。
- Consequence: proposed IssueはClaim前にsuccessor依存とbindingをvalidate/readbackでき、claimed／paused／superseded historyはsealed contractとstate authorityを保つ。Goldieの成功はfull verification、visual／release audit、package seal、upload／submitを代替しない。tracked regressionはconsumer guidance、phase engine、locale分離、iPad routing、成功／失敗cleanup、最大同時保持1台をfake `xcrun`で確認し、実Simulator検証とは区別する。
- Related Issue: #88

## D-054: workflow-onlyでlocal App Store delivery toolだけをexact allowlistする

- Date: 2026-09-16
- Status: 確定
- Supersedes: D-033のworkflow-only path境界を、App Store関連pathの用途別判定について限定的に補足する。application、asset、provider operation、strict review境界は維持する。
- Context: #88は`harden + strict`の非application Issueとして、Phase 6のApp Store guidanceと認証を行わないSimulator capture producerを変更する一方、従来validatorはpath名に`appstore`または`App Store/`が含まれるだけでmetadata／asset／provider実装と同一に拒否した。そのためcanonical targeted repository evidenceが成功してもworkflow verifyを発行できなかった。
- Decision: workflow-only path判定は、Phase 6のlocal guidance、`tools/capture-appstore-screenshots.sh`、その直接regression testをexact path allowlistで許可する。App Store metadata、採用画像、package内容、signing、provider実装、TestFlight、App Store external operationは引き続き拒否し、contractも`appstore.*` operationを許可しない。exact list外を名前やdirectoryだけからlocal toolと推測しない。
- Consequence: delivery-tool契約はXcode／Simulator実行を捏造せずrepository evidenceで検証できる一方、公開内容と認証操作はrelease経路からworkflow-onlyへ流入しない。publisher regressionは許可された全path群の成功と`App Store/Metadata.md`の拒否を同時に固定する。
- Related Issue: #88

## D-055: AppLibrary法務ページのIssue引き継ぎと公開検証を固定する

- Date: 2026-09-16
- Status: 確定
- Supersedes: None。D-026の公開先方針、D-007の外部操作境界、D-054のworkflow-only用途別判定、既存の法務承認・release gateを維持する。
- Context: 派生アプリの法務原稿からWeb-AppLibrary実装へ移る際、事実、言語、原稿、route、承認、返却値が会話だけに残ると、別repositoryへの誤投稿、重複Issue、未承認本文や仮URLの公開、deployを承認とみなす誤り、公開URLと正本のdriftが起きる。PayCycleのpilotではWeb Issueへ引き継げた一方、公開ページの一部未到達もあり、Issue作成と公開検証を別々の成功条件にする必要がある。
- Decision: confirmedな英語／日本語support・privacy・terms正本、digest／approval、source Issue／Head、app facts、ユーザー承認済みhost／route、返却契約から、exact `yuto1201/Web-AppLibrary`向けcopy-ready Markdownを決定的に生成する。作成はsource contractのoperation／executor、open／closed重複検索、account／target preflight、一度だけのdispatch、exact readbackに従う。ユーザーがprompt転送と法務・公開承認を保持する。返却後はrequest／prompt／Web Issue／deployment／user actions／source digests／URLを結び、HTTPS exact route、redirectなし、unauthenticated HTTP 200、本文・locale、同一locale相互linkをlive検証する。fixtureは`appStoreEligible: false`とし、live `verified`だけをApp Store準備・提出へ渡す。
- Consequence: Web実装や公開をこのrepositoryから暗黙実行せず、Issue作成完了、ユーザー承認、ページ公開、App Store利用可否を別々に追跡できる。source／route／approval／pageが変われば再生成または再検証が必要になる。workflow-onlyではこの非認証producer、guidance、README、直接testだけをexact allowlistし、法務本文、metadata、採用asset、provider実装、外部公開操作は拒否し続ける。
- Related Issue: #101

## D-056: App Storeのsource準備を読取専用のversioned表現で検証する

- Date: 2026-09-17
- Status: 確定
- Supersedes: D-054のworkflow-only exact allowlist境界を、認証を行わないsource-preparation用途について限定的に拡張する。D-033のsource／confirmation要件、D-035のsave／release分離、D-055のAppLibrary境界は維持する。
- Context: 既存のexact-key YAMLだけではSKU、質問票、確認根拠を表現できない。台帳のラベルやsource分類を承認またはApple保存欄と解釈すると、未回答やローカル専用値まで保存済みとして扱う危険がある。一方、旧#62の準備実装は現行workflow-only policyより前に作られ、App Store pathを用途別に限定許可する現在のrepository evidenceへ統合されていなかった。
- Decision: [構成 §9.1](architecture.md#91-原稿の正本と登録準備)と[preparation format](<../App Store/metadata/preparation-format.md>)に従い、追加sourceをversioned JSON、確認または提供された観察証拠をpackage外artifactへ分離する。読取専用入口で実sourceとXcode／コードinventoryを照合し、derive／user／public／accountの根拠からfield状態を計算する。旧台帳は保全して明示転記し、未知値・状態ラベルを承認へ変換しない。保存済み判定は対応resourceのID、locale、source、ユーザー承認と完全なbaseline／readbackへ束縛する。workflow-onlyではこの入口、format、enumerated helpers、直接testsだけをexact allowlistし、directory名やprefixから未知pathを許可しない。
- Consequence: `prepared`でもnetwork、live Apple照会、登録、save、画像生成、署名、upload、submit、release-ready判定は未実行のままとする。アプリ固有metadata、採用画像、signing、provider実装、TestFlight、`appstore.*` operation、秘密実値の永続化は引き続き拒否する。private fieldの保全比較は明示された一時pipeだけに限定し、値や値hashを保存しない。既存YAML／checklist／package／result、完全release gate、法務・外部操作の承認境界は変更しない。#110の完了にはimmutable targeted repository evidence、workflow-only verify、current-Head strict review、pre-merge gateを要求し、native／Simulator／live Apple検証を実行済みとは主張しない。
- Related Issue: #110（#62は移植元履歴として保持）

## D-057: 広告収益化を非trackingの条件付きAdMob統合として採用する

- Date: 2026-09-17
- Status: 確定
- Supersedes: None。D-010の外部サービスを必要なアプリだけに導入する原則を広告収益化へ適用し、D-030のUI Direction Gate、D-033／D-035／D-056のApp Store準備・外部保存境界、D-038／D-053のRelease Phaseは維持する。
- Context: 派生アプリで広告収益化を再利用する一方、全アプリへSDK、identifier、consent／広告sourceを先行導入すると、不要な依存、privacy／App Store申告、network変動と外部account操作を発生させる。Debug demo、UI Test fixture、production identifier、AdMob Console状態を区別しない場合、テストの非決定化、本番広告の誤request、ローカル成功のremote完了への読み替えが起きる。ユーザーは親Issue #80の方針を採用し、仕様、実装、品質／release readinessを依存順に分離することを承認した。
- Decision: [条件付きAdMob収益化](product.md#41-条件付きadmob収益化)と[統合境界](architecture.md#71-条件付きadmob統合境界)に従い、AdMobを派生アプリが明示採用した場合だけ有効化できるoptional capabilityとする。既定はUMPと非trackingのanchored adaptive bannerだけとし、ATTは表示せず、Publisher first-party IDは無効化する。tracking／personalization／IDFAと他の広告形式は別Decision／Issueの明示承認なしに含めない。有効化はアプリIdentity／Deployment Target、実行時に公式sourceで再確認したSDK条件／exact version、Debug demo／Release production identifier、配置、eligibility／広告非表示権利、privacy options、data use／App Store申告を入力とし、未決／欠落／矛盾を変更前に拒否する。未採用のTemplateApp／bootstrap outputはSDK／package／設定／identifier／広告sourceを持たず不変とする。DebugはGoogle demo、UI Testはnetwork-free fixture、Releaseはapp固有productionに分離し、欠落と混在を拒否する。
- Consequence: 共有`admob-monetization` skill／activation tool、注入可能なconfiguration／consent／eligibility／banner境界、adaptive banner runtime、構成／privacy／release validator、Build／Test／Simulator／release evidenceは後続Issueで実装・検証する。このDecisionと仕様Issue #112の完了だけでそれらを実装済みとしない。offline fixture、Google demo smoke、AdMob remote state、production App Store readiness／配信は独立証拠とし、ローカル成功をremote完了／収益／審査通過にしない。AdMob Consoleのaccount／app／ad unit作成、契約・支払・税務、consent message／app-ads.txt公開、production identifier取得、App Store Connect保存／提出は別Issueの操作権限と必要なユーザー承認を要する。#110はread-only source preparation、#101は法務引き継ぎの既存境界を維持し、AdMob provider実装やremote operationの権限にはならない。
- Related Issue: #80、#112

## D-058: 条件付きprovider実装をsealed tracked fixtureでapplication検証する

- Date: 2026-09-17
- Status: 確定
- Supersedes: D-033のapplication scoped-diff境界を、Claim前に封印した専用fixtureについて限定的に補足する。D-029のstage別検証、D-037／D-039のtargeted repository tests、D-040／D-046のSimulator資源管理、D-057のAdMob採用境界は維持する。
- Context: 条件付きprovider integrationをtemplate本体やroot Xcode projectへ常設すると、未採用アプリまでSDK／設定／sourceを持つ。一方、provider implementationをworkflow-onlyとして先にmergeすると、Buildされていないapplication codeを成功扱いする。従来のapplication scoped-diffはfixture、shared skill、provider固有toolを同じHeadで追加する意図的なisolated検証を区別できず、#113を安全にBuild／Testする経路がなかった。
- Decision: application Issueの既存AC最大一つへexact `Application-fixture binding: <canonical JSON>`を置き、schema 1の`fixtureRoot`、`project`、`route: tracked-fixture-v1`、`schemaVersion`、`skillRoot`、sorted unique `toolPaths`をClaim前に検証・封印する。許可するのは`shape / strict / iphone-ja`またはapplication `harden / strict / targeted`と完全かつ`visual:` mappingを持たないVerificationの組合せだけとする。fixture rootは`tools/tests/fixtures/`配下、projectはその中のcommitted `.xcodeproj`でCLI／final evidenceとexact一致させる。`skillRoot/application-fixture.json`をcanonical binding JSONと改行なしでexact一致するregular `100644` ownership markerとし、Baseにmarker以外のfixture／skill／tool／Claude alias surfaceがあれば同じmarkerもBaseに存在すること、新規surfaceならBaseにmarkerがなくHeadで同時追加されることを検証する。Headの`SKILL.md`、全tool、Claude aliasの実体も常時検証する。`Config/repository-tests.json`はBaseの`schemaVersion`、`headAllPaths`、`headAllPrefixes`、既存rule／testをexact保持し、canonical domain名とsafe path／prefixを持つprovider固有rule／testだけを追加できる。provider namespace、allowed path／mode、Claude symlinkをfail closedで検証し、live app、root project／workspace、別provider、core workflow／review／merge／security／authority、delete、rename、gitlink、不正symlinkを拒否する。bindingなしのcontractは従来挙動を維持し、Claim後revisionでは宣言の位置と全文を不変とする。
- Consequence: provider skill、tool、runtime、専用fixtureを一つのapplication Headで実際にBuild／Testできる一方、TemplateAppと未採用bootstrap outputは不変に保てる。path名だけで既存coreをprovider所有へ移したり、manifest変更で既存repository testを弱めたりできない。証拠は既存の`application-code`、`xcodebuild-stage`、source／project digest、Build、Unit、case、Simulator cleanupを使い、別schemaやworkflow-only擬装を作らない。shape／hardenの結果はrelease-ready、production identifier、remote provider state、App Store readinessを証明しない。routeの確定仕様とClaim封印を実装する#121、scoped validator／runner／evidence consumerを有効化する#122はworkflow-onlyとし、provider実装を含む#113と分離する。#121だけの完了をruntime routeの稼働証拠にせず、利用するIssueは#121と#122の双方を`state:done`依存とする。#116と#117はsealed Baseまたは実行上限により置換された履歴としてsupersededを保持し、contractを書き換えない。
- Related Issue: #80、#113、#116、#117、#119、#121、#122

## D-059: App Store Connect API操作を固定版ascのguarded adapterへ集約する

- Date: 2026-09-23
- Status: 確定
- Supersedes: D-014のApp Store Connect入力手段と、D-035の完全release sectionのうち公開App Store Connect APIで扱える入力・readbackを、authenticated browserから固定版`asc` adapterへ置き換える。D-054／D-056のworkflow-only exact allowlistは、後続Issueが追加するasc adapterのexact pathについてだけ限定拡張する。D-024の権限、D-033／D-035のsave／release分離、D-055の法務handoff、D-056のread-only source準備、完全release gateは維持する。
- Context: App Store Connectのproduction preflightは未実装で意図的に失敗し、build uploadの処理もmetadata save入口も存在しない。完全release sectionはauthenticated browser入力を前提とし、入力・保存・readbackの再現性とsecret分離がUI操作に依存していた。ユーザーは2026-09-23に、rorkai/App-Store-Connect-CLI（`asc`）をbrowser経路より優先するadapterとして採用した。あわせて、移行範囲をmetadata save、正式提出、build upload、TestFlight配信の全四領域とし、公開APIで扱えないApp Privacy申告を既存browser sectionに残し、`asc`を公式releaseのexact pinで導入し、API keyをTeam keyのApp Manager roleとすることを選択した。
- Decision: [構成 §7.2](architecture.md#72-app-store-connect-api-adapter)に従い、公開APIで扱えるApp Store Connect／TestFlight操作をguarded runner経由の`asc`だけで行う。公式GitHub releaseのmacOS arm64 assetをexact versionとSHA-256でpin recordへ固定し、公開checksum fileとpin recordの双方に一致したbytesだけをrepository外へno-replaceで配置する。起動ごとにversionとdigestを再照合し、Homebrew、install script、自動update、`asc install-skills`、未固定versionを使わない。runnerはoperationごとのsubcommand／flag allowlist、JSON出力、有限timeout、redaction、telemetry無効、`asc`自身のKeychain／config／profile／web sessionを読まない隔離設定を強制し、`asc web`、`--deep`、`auth login`／`auth logout`、`apps wall`、`install-skills`、`signing`系、`workflow run`、telemetry有効化、allowlist外subcommandを拒否する。認証はTeam keyのApp Manager roleとし、Key ID／Issuer IDはKeychain、`.p8`は専用file-secret directoryから子process envへだけ渡す。operationは既存の`appstore.inspect_app`、`appstore.update_metadata`、`appstore.upload_build`、`appstore.submit_review`に`appstore.distribute_testflight`を加え、同じIssueが同一providerの複数operationを宣言でき、preflightを宣言済みoperationごとに発行する。build署名はautomatic signingと同じAPI key認証によるprovisioning更新だけとする。App Privacyは既存browser sectionで入力・readbackし、readback sourceを区別して記録する。
- Consequence: live `appstore.*` operationは従来どおり`release` stage、`full` scope、`strict`、宣言済みoperation／Executor、必要なユーザー承認を要し、このDecisionで緩和しない。テンプレート内の実装Issueはfake `asc`とfake `xcodebuild`だけで検証し、live API、実upload、実提出、実配信、Apple審査の成功を主張しない。API readbackはsanitized digestと`asc://` remote referenceだけを記録し、field値、秘密、tester個人情報を保存しない。新規App record作成、契約、税務、銀行、価格、証明書／profileの作成・失効・同期、manual signing、Apple ID sign-inは対象外のままとする。実装は#130（pinned installerとguarded runner）、#131（production preflightとoperation model）、#132（selective save）、#133（build upload）、#134（release sectionのAPI移行）、#135（TestFlight配信）へ分割する。#134が完了するまでは既存のauthenticated browser section workflowだけが完全releaseの実行経路であり、#132が完了するまでsave入口は使用できない。このDecisionと#142（#129の後継）だけでadapterのinstall、実装、検証を完了扱いにしない。
- Related Issue: #128、#129（superseded）、#142、#130、#131、#132、#133、#134、#135

## D-060: App Store review informationをbrowser sectionに残す

- Date: 2026-09-24
- Status: 確定
- Supersedes: D-059の「App Privacyだけをbrowser sectionに残す」範囲を限定的に補足する。D-059本文および他のAPI移行判断は変更しない。
- Context: 固定版`asc` 5.4.0の`review details-update`はdemo account password、連絡先email、電話をコマンド引数でしか受け取らない。[秘密を引数へ置かない規則](../docs/security.md#3-実行時の取扱い)を満たせず、ユーザーは2026-09-24に#134の着手とreview informationのbrowser維持を承認した。
- Decision: review informationをApp Privacyと同じauthenticated browser sectionに残し、executorがsealed packageとの照合後にsanitized readback digestとremote referenceだけを記録する。app information、localization、screenshots、build選択、submissionは固定版`asc` guarded runnerのAPI sectionとする。将来`asc`が秘密を引数以外で受け取れるようになった場合は別Issueで再評価する。
- Consequence: 完全releaseのsection順序、sealed package、release verification、operation別preflight、ユーザーの明示提出承認、再開時の全section再readbackを維持する。結果schemaはAPIとbrowserのreadback sourceを区別し、秘密や連絡先実値を保存しない。テンプレート内のfake runner検証はlive入力・審査提出・Apple承認の証拠ではない。
- Related Issue: #128、#134

## D-061: TestFlight What to Testをguarded配信operationへ含める

- Date: 2026-09-25
- Status: 確定
- Supersedes: D-059のoperation modelを限定的に補足する。D-059本文は変更しない。
- Context: #135のreviewではWhat to Testがsealed contractの範囲外と判定された。ユーザーは2026-09-25に#166を含む後続Issueへの着手を承認した。
- Decision: [構成 §7.2](architecture.md#72-app-store-connect-api-adapter)に従い、readback済みbuildのWhat to Test（beta build localization）の設定とreadbackを`appstore.distribute_testflight`の責務へ含める。新しいoperationは作らない。
- Consequence: live操作は従来どおり`release` stage、`full` scope、`strict`、宣言済みoperationとExecutor、必要なユーザー承認を要する。本文は非秘密の公開テキストとして単一argvで渡し、journalにはdigestだけを残す。4000文字はテンプレート側の上限であり、Appleの上限とは主張しない。D-059のConsequenceにある#131のoperation modelとproduction preflight／premergeは、それぞれ#145と#146で実現済みである。
- Related Issue: #135、#166

## D-062: 停止中の管理外SimulatorをMac共通枠から除外する

- Date: 2026-09-27
- Status: 確定
- Supersedes: D-040の管理外の`iOS-Template-` deviceがあると新規作成を一律に止める運用と、§1.5.6の管理外Shutdown deviceの数え方。D-040の管理外deviceを削除しない保護、D-038の最大4台・sessionごと1台・使用後削除は維持する。
- Context: 派生アプリの旧runnerが残す停止中のdeviceのために、2026-09-22、09-25、09-26、09-27にnative検証が止まった。管理外deviceがShutdownでも一律の拒否が続いていた。
- Decision: active durable recordを持たない管理外の`iOS-Template-` deviceは保護対象のまま削除・停止・変更しない。状態がexactに`Shutdown`ならMac共通の4枠へ数えず、新規作成を止めない。停止中はCPU／memoryを使わず、disk使用量は作成前の空き容量確認が扱う。`Shutdown`以外の状態は、管理下の予約、active、削除待ち、cleanup-failedと合算して4枠へ数え、到達時は既存の上限messageで新規作成を拒否する。
- Consequence: 旧runnerはこのallocatorとは無関係に自分のdeviceを起動できるため、起動中の管理外deviceだけを数えるのが強制できる上限である。各派生アプリが共通lifecycleを採用するまでは、一時的な4枠超過があり得る。session 1台、作成前の空き容量確認、所有identityに基づく回収規則は維持する。
- Related Issue: #178

## D-063: AI検証とApp Store撮影をrepository専用の2台に限定する

- Date: 2026-09-28
- Status: 確定
- Supersedes: D-009の最新iPhone Pro／最新iPad Air、D-016のbatch開始時の最新Runtime／device解決、D-040が維持した「caseごとに作成し最終使用後に削除する」資源契約、`specs/architecture.md` §9のApp Store撮影端末を公式要件から別に解決する規則。D-009の日英4条件、D-040のstable session identity・repository lock内のMac共通lease・有限待機・空き容量確認・管理外device保護、D-062の停止中管理外deviceの扱い、schema v1／v2のlegacy受理は維持する。
- Context: 2026-09-28、他repositoryの並列testがclone deviceを作り続け、Macの1分平均負荷は最大966、swapはほぼ上限に達し、#182のnative検証が失敗して再試行もできなかった。caseごとの作成・削除と他repositoryの残存deviceにより、device数と負荷を予測できない。ユーザーはSimulatorを初期化し、このrepository専用のiOS 27 iPhone 17とiPad (A16)だけを使うことを厳守するよう指示した。あわせて、各検証前のeraseと、派生アプリも各自専用の2台を持つことを選んだ。
- Decision: 各repositoryはAI検証とApp Store撮影に、専用のiPhone 1台とiPad 1台だけを使う。Templateは`iOS-Template iPhone 17`（Device Type iPhone 17、Runtime iOS 27.0）と`iOS-Template iPad (A16)`（Device Type iPad (A16)、Runtime iOS 27.0）、派生アプリは表示名を前置した同じDevice Type／Runtimeの2台（例：`PayCycle iPhone 17`）とする。UDIDはcommitせず、実行時にexact name、Device Type、Runtimeが一致するdeviceがちょうど1台であることを確認し、0台または2台以上なら`blocked:environment`とする。`iphone-en`／`iphone-ja`は専用iPhone、`ipad-en`／`ipad-ja`は専用iPadを使い、同じdeviceのcaseは一件ずつ実行する。各caseの前に専用deviceを停止・eraseし、caseのlocale／languageを設定して起動し、証拠をdevice外へ保存してから停止する。専用deviceの排他はMac共通resource managerのleaseで取り、起動中のAI検証用deviceはMac全体で最大4台・sessionごと1台とする。`xcodebuild`のtestは常に`-parallel-testing-enabled NO`で実行する。検証とApp Store撮影はdeviceを作成・clone・rename・削除せず、専用device以外を起動・erase・install・test対象にしない。専用deviceの作成は、後続Issueが定める明示的な初期設定手順だけで行う。App Store用画像も専用2台だけで撮影し、公式の必須サイズは確定済みの合成経路で規定canvasへ仕上げる。満たせないサイズがあればupload前に`blocked:user`とする。
- Consequence: 検証とApp Store撮影のtool（matrix、resource manager、runner、validator、撮影、bootstrap）は後続Issueで専用device契約へ移し、それまでcanonical native検証とApp Store撮影を実行しない。専用device契約を実装していないBaseで封印済みのcontractはnative検証を行えないため、native証拠が必要な場合はsuccessor Issueへ移す（#182を含む）。既存のschema v1／v2 matrix、sealed contract、証拠はimmutable legacyとして受理し、変換や付け替えをしない。device数はrepositoryごとに2台で一定になり、disk消費はeraseで上限が保たれる。
- Related Issue: #183

## D-064: 非消耗型の買い切り権利を条件付きStoreKit 2境界として定める

- Date: 2026-09-29
- Status: 確定
- Supersedes: None。D-057の条件付きAdMob統合と、広告非表示権利をAdMob外のsource of truthから受け取る前提、D-059のApp Store Connect操作境界を維持する。
- Context: 派生アプリでは広告非表示などの買い切り商品が想定されるが、テンプレートには購入、復元、Offer Code、権利判定の契約がなかった。条件付きAdMob統合は広告非表示権利を外部から注入される値として受け取るだけで、その正本を定めていない。
- Decision: 派生アプリの確定仕様が買い切りの非消耗型商品を明示採用した場合だけ、StoreKit 2の権利境界を有効化する。採用前に商品種別、付与する権利、product ID命名、価格tier、対象storefront、Family Sharing、対象年齢、Offer Code採否を確定し、未決なら`blocked:user`とする。権利はverifiedで失効していないtransactionだけから解決し、pending、取消、unverified、失効済み、アプリ独自の保存値からは付与しない。起動時とforeground復帰時に再確認し、transaction updatesを監視してverified transactionをfinishする。復元とOffer Code redemptionは利用者の明示操作だけで起動し、曖昧な結果から権利を推測しない。広告非表示に使う場合、StoreKit側はAdMobの`adFreeEntitlement`入力と`hasAdFreeEntitlement`注入点へ権利の値だけを渡し、consent、eligibility、広告requestはAdMob側に残す。Debug／UI TestはStoreKit configuration fileとnetwork-free fixtureで検証し、StoreKit Testing、sandbox購入、App Store Connectのproduct状態、審査結果を別の証拠とする。
- Consequence: 派生アプリは、広告非表示などの買い切り商品を共通の権利判定と責務分離で追加できる。テンプレート本体とbootstrap outputは変えず、StoreKit code、skill、activation tool、validator、StoreKit configuration fileは後続Issueで実装する。source preparationのcode inventoryはStoreKitの使用を検出しないため、その検出は後続Issueとし、それまでIAP項目は利用者の確定値とreadbackで扱う。自動更新subscription、消耗型、server-side検証、独自purchase server、App Store Connectでのproduct作成・価格・税務・契約・IAP審査提出・Offer Code発行は含めない。
- Related Issue: #159

## D-065: 採用済みアプリアイコンを明示replace modeだけで差し替える

- Date: 2026-09-29
- Status: 確定
- Supersedes: None。D-031の初回App Icon Gate、exactly 2案の生成、明示選択、選択済みassetとsanitized recordだけのcommit、UI Direction Gateとの独立性を維持する。
- Context: D-031は初回の採用だけを定め、採用後の差し替えを定めていなかった。`tools/install-app-icon.sh`は採用済みrecordと異なる入力を常に拒否するため、派生アプリPayCycleは初回release前にユーザー提供画像の編集結果へ差し替える際、installerを迂回して独自のselection記録で対応した。
- Decision: 採用済みアイコンの差し替えは、初回App Icon Issueとは別のIssueで、installerの明示replace modeだけを使う。callerは現行採用SHA-256を宣言し、新しいimmutable revisionの候補からユーザーが明示選択した`selection.json`と、その選択候補のbytesを渡す。宣言digestの不一致、明示選択でない記録、選択候補以外のsource、過去に採用したrevision（recordのGit履歴に残るものを含む）の再利用、変化のない差し替え、dirty worktreeは、変更前に停止する。差し替え後のrecordはschema 2とし、新しい採用値、`selectionRevision`、直前の採用concept ID／generator／SHA-256を持つ`supersedes`を記録する。ユーザー提供の参照画像を編集入力にする場合は、権利のユーザー確認を必須とし、参照画像をGitへ入れず、SHA-256と`builtin-imagegen-reference-edit`だけを記録する。第三者mark、識別可能な人物の顔、文字を含めない既定条件を維持する。
- Consequence: 派生アプリはinstallerを迂回せずに後のreleaseでアイコンを変えられ、直前の採用記録をrecordとGit履歴で追跡できる。初回installと同一入力再実行のschema 1出力は変わらない。rejected候補、prompt履歴、参照画像はGitへ入れない。外部サイトやApp Store Connectの掲載アイコンは別Issueで更新する。custom dark／tinted variant、alternate icon、既存派生アプリの実差し替えは対象外とする。
- Related Issue: #158

## D-066: App Store Connectの認証情報をApple teamごとの名前空間へ置く

- Date: 2026-09-30
- Status: 確定
- Supersedes: D-059の認証の置き場所のうち、App Store Connectに限りappSlugごとのKeychainとfile secretの場所を置き換える。App Manager roleのTeam key、固定版`asc`のguarded runner、`run-with-secret.sh`／`run-with-private-key.sh`による子processだけへの受け渡し、Admin role・Individual key・Apple ID・`asc`自身の認証保存を使わないことは維持する。
- Context: ユーザーは2026-09-29、このMacの全アプリで共通に使うTeam API key（team `AUZ2MV247A`、App Manager role）を一つだけ用意し、その置き場所をユーザースキル`app-store-connect-api`に記録した。これまでのrunnerは`Config/app-identity.json`の`appSlug`から置き場所を計算していたため、共通の一本を読めなかった。
- Decision: App Store Connectの認証情報は、Apple teamごとの名前空間`apple-team-<teamId>`に置く。Key IDとIssuer IDはKeychain service `ios-template/apple-team-<teamId>/app-store-connect/production/key-id`と`issuer-id`（account `apple-team-<teamId>`）、`.p8`は`~/Library/Application Support/iOS-Template/secrets/apple-team-<teamId>/app-store-connect-production.p8`（directory `0700`、file `0600`）とする。`<teamId>`は`Config/ownership.yml`の`appStore.teamId`（10文字の大文字英数字）から決め、callerの引数や環境変数からは受け取らない。`appStore.apiKeyType`は`team-app-manager`だけを許し、名前空間の解決にはteam IDとこの種類の両方を必須とする。secret wrapperは、この名前空間をApp Store Connectのserviceに限って受理する。appSlugの旧い場所は読まない。
- Consequence: 同じteamの全アプリが、鍵を複製せずに一本のkeyを使える。Keychainへの値の登録、keyの発行・再発行・失効はユーザーが行う。App Store Connectが表示するkeyのroleがApp Managerと確認されるまで、live認証は行わない。テンプレートの`Config/ownership.yml`への値の記入と、それを検証できるworkflow-onlyのallowlistの拡張は#214で行う。
- Related Issue: #213

## D-067: SwiftDataを選んだ派生アプリのデータ非破壊境界を定める

- Date: 2026-10-01
- Status: 確定
- Supersedes: なし。`specs/product.md` §4のデータ方針と、`specs/development-stages.md` §4の「ユーザーデータを破壊せず、保存形式の互換性を守る」を、SwiftDataについて具体化する。
- Context: 端末内だけで成立する派生アプリはSwiftDataを選べるが、storeを開けないときの扱い、保存失敗の表面化、schema変更の順序が決まっていなかった。storeを開けないときに削除、別fileへの置換、空storeでの起動をすると、利用者のデータが黙って失われる。最初の公開後にversioned schemaなしでmodelを変えると、既存のstoreを開けない、または誤変換する。
- Decision: SwiftDataを採用する派生アプリは、stageに関係なく次を守る。
  - container: store URLを明示する。同期の採用が確定するまでCloudKit連携を明示的に無効にする。同期が必要ならSupabaseを標準とする既存方針に従う。Unit／UI Testはin-memoryまたは一時directoryのcontainerを使い、利用者のstoreを開かない。
  - store open失敗: 自動削除、別fileへの置換、空storeでの黙った起動をしない。再試行できる復旧画面を表示し、失敗原因の分類だけをsanitizedに記録する。store内容、個人情報、file pathは記録しない。
  - 保存: 保存する時機を明示し、保存失敗を利用者へ表面化する。失敗時はその操作だけを取り消せる単位を持ち、context全体を無差別にrollbackしない。保存失敗を注入できるtest境界を持つ。
  - schema変更: 最初の公開（TestFlightまたはApp Store）後に初めてmodelを変更する前に、versioned schemaとmigration planを導入する。旧schemaの永続化fixtureから開くmigration testを、そのIssueの完了条件にする。
  - 検証: 重要な保存logicは、永続化storeへ保存し、containerを閉じて再openした後に内容を確かめるtestで検証する。Delivery stageの`shape`でも省略しない。
  - データ消失と誤変換は、既存の公開blockerであるデータ消失と同じ扱いにする。
- Consequence: TemplateAppへSwiftData、service layer、sample modelを追加しない（使われない層を作らない既存方針を維持する）。Supabase同期、backup／export、CloudKit同期の設計と、既存派生アプリのmigration実装はこのDecisionの対象外とし、必要になった時点で別Issueとする。
- Related Issue: #161

## D-068: ローカル通知を派生アプリの明示採用時だけ使う条件付き能力として定める

- Date: 2026-10-02
- Status: 確定
- Supersedes: なし。全アプリへ通知を先回り導入しない方針（`specs/product.md` §8）は維持し、明示採用した派生アプリが守る境界だけを加える。D-051のSystem Experiences Planningの5面は変更しない。
- Context: 期日リマインダーなど端末内のローカル通知を使う派生アプリでは、起動直後のpermission要求、拒否状態の誤表示、所有外のrequestの一括削除、OSのpending上限の見落とし、lock screenへの金額や個人情報の表示、実OS permission dialogに依存するtestといった誤りが繰り返されやすい。
- Decision: ローカル通知は全アプリの標準依存にせず、派生アプリの確定仕様が明示採用した場合だけ使う条件付き能力とする。採用するアプリは次を守る。
  - 採用条件: 通知の目的、発火条件、既定のon／off、permissionを求める画面と操作、表示してよい情報を確定する。未決または矛盾する間はsourceを変更せず`blocked:user`とする。
  - permission: 起動直後には要求せず、利用者が通知を有効にする操作をしたときだけ要求する。未決定（notDetermined）、拒否（denied）、許可（authorized等）を区別して表示し、拒否された後はシステム設定のアプリ通知画面への導線だけを出す。要求の失敗を成功に読み替えない。
  - 予約管理: アプリが所有するrequest identifierのprefixだけを削除・再登録し、所有外のrequestに触れない。pending requestのOS上限はApple公式の現行値を作業時に確認し、所有外のrequestを差し引いた範囲で予約する。入りきらない分は部分予約として報告する。同時に起きた再予約要求は一つに結合し、進行中の登録を中断しない。時刻と、timezone／calendarの変更時に予約を再計算する規則を持つ。
  - 表示内容: lock screenに出る通知の本文へ、金額、個人情報、秘密を含めない。
  - test: 通知centerをprotocolにし、Unit／UI Testはnetwork-freeでOS permissionに依存しないfixture centerを使う。実OS permission dialogの成功を通常フローの合格条件にしない。
  - System Experiences Planningとの関係: ローカル通知は、Widget、Live Activities、Dynamic Island、Controls、Siri／App Intentsの5面に含めない独立した条件付き能力とする。D-051の対象は変更しない。
- Consequence: 通知code、skill、tool、TemplateAppは変更しない。remote push（APNs）、通知service extension、Live Activities／Widgetの設計は対象外とし、必要になった時点で別のDecisionとIssueで扱う。
- Related Issue: #160

## D-069: 派生アプリのDecisionを`specs/app-decisions.md`の`A-###`に分ける

- Date: 2026-10-02
- Status: 確定
- Supersedes: なし。既存のテンプレートDecision（`D-001`以降）の番号と本文は変更しない。
- Context: テンプレートと派生アプリは、どちらも同じ`specs/decisions.md`へ`D-###`を連番で追記してきた。そのため派生アプリの生成後は、同じIDが別の決定を指す（例: 派生アプリPayCycleの`D-030`〜`D-039`は、テンプレートの同じ番号と全件が別内容）。テンプレートの`AGENTS.md`やtoolは「D-030 cutover」「D-059」などを規則として参照し、その文書は派生アプリへ引き継がれる。
- Decision:
  - テンプレートのDecisionは、`specs/decisions.md`の`D-###`だけとする。テンプレート所有の文書とtool（`AGENTS.md`、`docs/`、`specs/`の既存節、`.agents/skills/`、`tools/`）が`D-###`で参照するのは、派生アプリの中でも常にテンプレートDecisionである。
  - 派生アプリ固有のDecisionは、`specs/app-decisions.md`へ`A-###`（`A-001`から連番）で追記する。派生アプリは`specs/decisions.md`へ新しいDecisionを追加しない。
  - 候補の別prefixと別fileのうち別fileを選び、そのfileの中では別prefixの`A-###`を使う。理由は二つある。テンプレート更新の取り込みで`specs/decisions.md`の末尾へテンプレートDecisionを足しても、アプリ固有の追記と同じfileの上で衝突しない。IDのprefixが違うので、本文やIssueの参照からどちらのDecisionかが一意に分かる。
  - 書式は`spec-workflow`の`templates/decision.md`と同じとし、各Decisionの`- Status:`をそのDecisionの状態とする。spec state checkerは、Issueが`specs/decisions.md`の`D-###`または`specs/app-decisions.md`の`A-###`へ張ったリンクを、そのDecisionの`- Status:`で判定する。fileとprefixの取り違えは拒否する。Issueのapproval参照は`D-###`と`A-###`の両方を受け付ける。
  - テンプレート更新を取り込むときは、テンプレート側で増えた`D-###`を、番号を変えずに追記順のまま`specs/decisions.md`の末尾へ加える。`specs/app-decisions.md`には触れない。
- Consequence: Identity bootstrap後の派生アプリは、最初のアプリ固有Decisionを記録するときに`specs/app-decisions.md`を作り、`A-001`から始める。既に`specs/decisions.md`へアプリ固有の`D-###`を追記した派生アプリのrenumberや移行はこのDecisionでは行わず、各アプリのテンプレート同期Issueで扱う。テンプレート更新を自動で同期するtoolは追加しない。
- Related Issue: #162

## D-070: 専用SimulatorをApp Storeの必須画像サイズの機種にする

- Date: 2026-10-03
- Status: 確定
- Supersedes: D-063のうち専用deviceの機種の選択だけを置き換える。専用はiPhone 1台とiPad 1台だけ、AI検証とApp Store撮影の両方に使う、exact name・Device Type・Runtimeでちょうど1台を確認する、作成・clone・rename・削除をしない、各caseの前にeraseする、`-parallel-testing-enabled NO`で実行する、派生アプリは表示名を前置した同じ機種を持つ、という規則は維持する。
- Context: D-063の専用device（iPhone 17、iPad (A16)）の画面は1206×2622と1640×2360で、App Storeの必須画像サイズ（iPhone 6.9-inch、iPad 13-inch）と一致しない。そのため専用deviceで撮ったApp Store用画像は、合成なしでは提出できず、画像判定でも撮影元の機種がApp Store要件の端末にないとして弾かれた（#192）。
- Decision: Templateの専用deviceを、`iOS-Template iPhone 17 Pro Max`（Device Type iPhone 17 Pro Max、1320×2868）と`iOS-Template iPad Pro 13-inch (M5)`（Device Type iPad Pro 13-inch (M5)、2064×2752）に置き換える。Runtimeはどちらも iOS 27.0 とする。派生アプリは表示名を前置した同じ機種（例：`PayCycle iPhone 17 Pro Max`）とする。AI検証もこの2台で行うため、標準サイズのiPhoneでの検証は行わない。
- Consequence: App Store用画像を専用deviceから合成なしで撮影できる。新しい2台は`tools/setup-dedicated-simulators.sh`で作成し、旧2台（`iOS-Template iPhone 17`、`iOS-Template iPad (A16)`）はAIが削除せず、ユーザーが削除する。派生アプリへの適用は各アプリのテンプレート同期Issueで行う。App Store撮影toolと画像判定の対応は#192で行う。
- Related Issue: #233

## D-071: 3DモデルはTripoで作り、簡単なものはClaudeまたはCodex gpt-6-astraに依頼する

- Date: 2026-10-04
- Status: 確定
- Supersedes: D-032のうち、3D asset bytesのauthoringをCodexの`gpt-6-astra`だけに限る部分、Claudeをauthoring主体にしない部分、`gpt-6-astra`が使えないときに`blocked:environment`で止める部分を置き換える。3D作業を共有の`ios-3d-assets` skillへrouteすること、ClaudeとCodexの一般開発での同等権限、3Dを含むIssue／PR証拠へauthoringの経路を記録することは維持する。
- Context: D-032は3Dモデル制作をCodexの`gpt-6-astra`だけに任せていた。ユーザーは2026-10-04に、3Dモデルを使う場合の標準をブラウザで操作するTripoとし、簡単なモデルや即効性を求める場合はClaudeまたは`gpt-6-astra`に依頼する方針を決めた。
- Decision:
  - 3Dモデルを使う場合は、ユーザーまたはClaudeがブラウザでTripoを操作して作成する。ログイン、プランや課金の変更、認証情報の入力はユーザーが行う。Claudeはユーザーのログイン済みsessionで生成とダウンロードの操作だけを行い、購入やアカウント設定の変更はしない。
  - 簡単なモデルや即効性を求める場合は、ClaudeまたはCodexの`gpt-6-astra`（reasoning effort `xhigh`）に依頼する。
  - どの経路で作ったassetも、形式検証、アプリへの統合、Build／Test、視覚確認は従来どおり行い、Issue／PR証拠にauthoringの経路（Tripo、Claude、`gpt-6-astra`）を記録する。
- Consequence: `AGENTS.md`の3Dの規則と`ios-3d-assets` skillは、後続のIssueで改める。D-032の経路を前提にした手順は、そのIssueまで新しい方針と食い違ったまま残る。
- Related Issue: #240

## D-072: 法務ページを`app.yutodev.com/apps/<appSlug>/`の下に置く

- Date: 2026-10-04
- Status: 確定
- Supersedes: product.md 6.1節の「配置は未決・ユーザー指定待ち」を置き換える。D-026の公開先方針、D-055のIssue引き継ぎと公開後の検証、初回の法務本文へのユーザー承認、既存のrelease gateは維持する。
- Context: product.md 6.1節は、各アプリサイトと法務ページのURLパス、言語別の公開URLを、ユーザーが詳細を伝えるまで未決としていた。ユーザーは2026-10-04に、プライバシーポリシーのURLを`https://app.yutodev.com/apps/<アプリ名>/privacy/`とし、利用規約とサポートも同じ形で置き、日本語と英語を同じページ内で切り替える方針を決めた。
- Decision:
  - プライバシーポリシーは`https://app.yutodev.com/apps/<appSlug>/privacy/`、利用規約は`/apps/<appSlug>/terms/`、サポートは`/apps/<appSlug>/support/`に置く。`<appSlug>`は`Config/app-identity.json`の`appSlug`（例：`sublog`）とする。
  - 日本語と英語は同じページ内で切り替え、言語ごとに別のURLを作らない。
  - 各ページの作成は、掲載する内容（確定した日本語と英語の原稿、digest、アプリの事実、期待する返却値）を記載した作成依頼Issueを`yuto1201/Web-AppLibrary`へ起票して行う。
- Consequence: 法務handoff toolは、言語ごとに別のrouteを要求して重複を拒否する現在の規則を、後続のIssueで改める。公開後の検証は、同じページで日本語と英語の両方の本文を確認する。Web側の実装、deploy、DNSは、このrepositoryから行わない。
- Related Issue: #240

## D-073: 新しいアプリは、このMacで`iOS-Template`を履歴ごとコピーして作る

- Date: 2026-10-04
- Status: 確定
- Supersedes: product.md 3.1節の、GitHubのテンプレート機能で新しいリポジトリを作る前提を置き換える。Identity bootstrap、App Icon、System Experiences Planning、UI Direction Gateの順序と、専用Simulatorの規則（D-063、D-070）は維持する。
- Context: これまでの派生アプリは、GitHubのテンプレート機能で作られたため、テンプレートと共通の履歴を持たず、どのテンプレートの版から作られたかも記録されていない。そのため、テンプレートの更新をどこから取り込めばよいかを特定できない。ユーザーは2026-10-04に、GitHubのテンプレート機能を想定せず、このMacから設計書や仕様書を渡して、`iOS-Template`をコピーして新しいアプリを作る方針を決めた。
- Decision:
  - 新しいアプリのリポジトリは、このMacで`iOS-Template`をGitの履歴ごとコピーして作る。GitHubのテンプレート機能（generate）は想定しない。
  - ユーザーが渡す設計書と仕様書を基に、アプリ固有の仕様を確定する。
  - 作成時に、コピー元のテンプレートの基準commitを記録し、Identity bootstrapを行い、そのリポジトリ専用のSimulator（`<表示名> iPhone 17 Pro Max`と`<表示名> iPad Pro 13-inch (M5)`）を`tools/setup-dedicated-simulators.sh`で作成する。
  - GitHubへのリポジトリ作成とpushは、設定済みのアカウントで、そのアプリのIssueの外部操作として行う。
  - 作成手順は、このMacのユーザースキルとして用意し、テンプレートのrepositoryには置かない。
- Consequence: 履歴ごとコピーしたアプリは、テンプレートとの共通の履歴と基準commitを持つので、テンプレート更新の取り込み（D-074）で基準からの差分を正確に追える。GitHubのテンプレート機能で作った既存の派生アプリは共通の履歴を持たないため、取り込みでは基準が不明として扱う。基準commitの記録形式はD-074の実装Issueで確定し、ユーザースキルはその後に作る。
- Related Issue: #240

## D-074: テンプレート更新を、差分レポートと承認済みの計画で取り込む

- Date: 2026-10-04
- Status: 確定
- Supersedes: D-069のうち「テンプレート更新を自動で同期するtoolは追加しない」の部分を置き換える。派生アプリ固有の決定事項を`specs/app-decisions.md`の`A-###`へ分けること、テンプレートの`D-###`を番号を変えずに`specs/decisions.md`の末尾へ加えること、既存の`D-###`を使う派生アプリの移行を各アプリのテンプレート同期Issueで扱うことは維持する。
- Context: 2026-10-04時点の派生アプリ（`iOS-PayCycle`、`iOS-HinokoPocket`、`iOS-SimplePomo`、`iOS-GoshuinPocket`）は、テンプレートから91〜96コミット遅れ、テンプレートのファイルの157〜174個を持っていない。手作業の取り込みでは、Identity変換された名前が戻る、テンプレート用の専用Simulatorを指す、アプリ固有の変更を上書きする、決定事項の番号が衝突する、といった誤りが起きやすい。ユーザーは、テンプレート更新を取り込む機能を作り、差分レポートと適用計画を見てから承認する方針を決めた。
- Decision:
  - 取り込みの対象は、テンプレートから作った既存のリポジトリと、テンプレートを未適用のリポジトリとする。
  - テンプレートの全trackedファイルを、テンプレートが持つもの、Identity変換されるもの、アプリが持つもの、両方が混ざるもの、テンプレート専用、に分類して記録し、取り込み先が基づくテンプレートの基準commitを記録する。
  - 取り込みは次の順に行う。
    1. 取り込み先へ書き込まずに、差分レポートと適用計画を作る。
    2. 適用計画の承認を得る。原則はユーザーが承認する。ユーザーが指定したときだけ、Codexが計画を確認して承認する。
    3. 承認された項目だけを、取り込み先の作業ブランチへ適用する。
  - Identity変換されるファイルは、取り込み先のIdentityで変換を再適用してから比べて書き込み、元の名前が残らないことを検査する。アプリ側で変えたファイルとアプリが持つファイルは上書きしない。
  - 取り込み先の専用Simulatorは、そのリポジトリ専用の2台（D-063、D-070）を厳守し、テンプレート用の端末を指す変更を入れない。
  - 取り込み先は、差分レポート、計画の承認、適用、検証、mergeを、そのリポジトリの1つのテンプレート同期Issueとして進める。
- Consequence: 所有区分、基準commitの記録、差分レポートと計画は一つ目の実装Issue、承認と適用は二つ目の実装Issueで作る。実在する派生アプリへの取り込みは、各アプリのテンプレート同期Issueで行う。
- Related Issue: #240

## D-075: ルートには`AGENTS.md`だけを置き、`AGENTS.md`の書き換えには承認を得る

- Date: 2026-10-04
- Status: 確定
- Supersedes: architecture.mdのルート構成のうち、ルートに`README.md`を置く部分を置き換える。`CLAUDE.md`を作らないこと（D-003）は維持する。
- Context: ルートの`README.md`と`AGENTS.md`に、似た説明が分かれて書かれていた。`AGENTS.md`はCodexとClaudeの共通規則であり、意図しない書き換えはすべての作業へ影響する。ユーザーは2026-10-04に、ルート文書の配置と`AGENTS.md`の書き換えの扱いを決めた。
- Decision:
  - リポジトリのルートには`AGENTS.md`を置き、`README.md`は置かない。`README.md`は、フォルダ内で説明が必要な場合（例：`docs/README.md`）だけに使う。
  - `AGENTS.md`を書き換えるときは、変更する文面をユーザーに示し、merge前に必ず承認を得て、その承認をIssueに記録する。
- Consequence: ルートの`README.md`を`docs/README.md`へ移し、その参照を揃える作業と、`AGENTS.md`へこの規則を書く作業は、後続のIssueで行う。そのIssueでの`AGENTS.md`の変更も、この規則に従ってユーザーの承認を得る。
- Related Issue: #240

## D-076: アプリ内フィードバックを、アプリごとのCloudflare Worker経由で非公開のGitHub Issueに登録する標準機能とする

- Date: 2026-10-05
- Status: 確定
- Supersedes: architecture.md §2の、テンプレートのアプリに使われないサービス層を含めないという記述と、§7の「Cloudflare: ドメイン、公開サイト、Workerが必要な場合だけ」、`docs/README.md`の、外部サービスをFoundationのアプリ本体へ組み込まないという記述のうち、アプリ内フィードバックの部分を置き換える。iOS-PayCycleのD-044とD-046はそのアプリの決定であり、変更しない。
- Context: iOS-PayCycleは、利用者がアプリから匿名で送った不具合や要望を、Cloudflare WorkerがGitHub Appで非公開リポジトリのIssueにする仕組みを持ち、動いている。ユーザーは2026-10-05に、同じやり方をテンプレートで実装し、新しいアプリを作ったらフィードバック用のリポジトリを作ってCloudflareで起票できるようにすると決めた。
- Decision:
  - アプリ内フィードバックを全アプリの標準機能とし、テンプレートのアプリにも入れる。
  - 送信の流れ：アプリ → アプリごとのCloudflare Worker（Worker名は`<appSlug>-feedback`、hostは`workers.dev`）→ 共通のGitHub App → 非公開リポジトリ`<GitHubのlogin>/<moduleName>-feedback`のIssue。Issueのlabelは`feedback`と種類（`bug`、`request`、`other`）とする。
  - GitHub Appは全アプリで一つを共有する。権限はIssues: Read and writeだけで、webhookはなく、フィードバック用のリポジトリだけにinstallする。App ID、installation ID、署名鍵はWorkerのsecretにだけ置き、アプリには秘密値を置かない。Workerが取るinstallation tokenは、そのアプリのフィードバック用リポジトリだけに絞る。
  - 送る内容は、種類（不具合・要望・その他）、本文（1〜2000文字）、アプリのversionとbuild、OSのversion、端末機種、言語の7項目だけとし、リクエスト全体を8KBまでとする。アプリのデータと連絡先は送らない。返信の手段は持たない。
  - 回数制限は、送信元IPごとに60秒に1件（数えられないときは通す）と、そのWorker全体で1日（UTC）100件（数えられないときは止める）とする。送信元IPごとの数は、同じCloudflare accountのほかのアプリと共有しない。IPアドレスは回数制限の鍵にだけ使い、IPアドレスと本文は保存もログもしない。
  - 画面：入口から開くsheetで、種類と本文を入れて送る。送信中、完了、失敗（通信なし、回数制限、サーバーエラー）を示し、失敗したら本文と種類を残して再送できる。完了と失敗の表示へVoiceOverのフォーカスを移す。送信先が設定されていないビルドでは入口を出さない。テンプレートのアプリには設定画面がないため入口をルート画面に置き、各アプリは自分の設定画面のサポート欄へ移す。
  - プライバシー：本文を「カスタマーサポート」、端末情報（アプリとOSのversion、端末機種、言語）を「その他の診断データ」とし、ユーザーに関連付けず、トラッキングなし、目的はアプリの機能として、`PrivacyInfo.xcprivacy`とApp Store ConnectのApp Privacyに申告する。プライバシーポリシーにも、送る内容、送らない内容、CloudflareとGitHubで扱うこと、IPアドレスの使い方を書く。
  - 新しいアプリの準備：作成時に、フィードバック用リポジトリとlabelの作成、共通GitHub Appのinstall、Workerのsecretの登録とdeploy、送信先hostの設定を行う。リポジトリの作成、secretの登録、deployは、そのアプリのIssueの外部操作として、設定済みのaccountと対象を確かめ、ユーザーの承認を得て行う。GitHub Appの作成（一度だけ）、installと、署名鍵の発行はユーザーが行う。
  - 構成：アプリ側は`Features/Feedback/`に置く。Workerのひな形はテンプレートのskillに置き、準備toolがアプリのrepositoryの`Services/feedback-worker/`へアプリの値で書き出す。
- Consequence: Workerのひな形、テンプレートのアプリの画面と送信、新しいアプリの準備toolは、後続のIssue（#249、#250、#251）で作る。既存の派生アプリへの導入は、各アプリのIssueかテンプレートの取り込み（D-074）で行う。
- Related Issue: #248

## D-077: App Store用の画像と動画を、パターン提案とユーザーの選択を経て作る`appstore-creative`スキルにする

- Date: 2026-10-12
- Status: 確定
- Supersedes: D-053のうち、Phase 6のApp Store画像の作り方（iPhone 6.9-inchはGoldieで実画面1枚と見出しを装飾し、iPadはGoldieの対象外としてrepository撮影経路の画像をそのまま使い、プレビュー動画は作らない）の部分を置き換える。新しいraw撮影を専用Simulator（D-063、D-070）とMac共通のresource managerだけで行うこと、Goldieの`capture`を使わないこと、localeごとに設定を分けること、Goldieの成功をPhase 5の証拠、監査、package seal、upload、提出の代わりにしないことは維持する。D-054のworkflow-only path判定は、下の「ワークフローだけの変更」で補足する。
- Context: 今のGoldieスキルは、実画面1枚と見出しを単色背景に置く使い方しか案内しておらず、派生アプリ（iOS-Flower #431）の画像が単調になった。調べると、固定版のGoldie 0.3.1は、11種のレイアウト、6種の並び、グラデーション背景、画像を敷く機能、録画済みのクリップから規格どおりの動画を書き出す機能を持っていた。一方で、端末のない面、iPad、専用Simulatorでの録画は持たない。ユーザーは2026-10-12に、2つの画面の組み合わせ、鮮やかな背景、イメージ画像、使用シーンなどを含むいくつかのパターンを先に見て選び、選んだものだけを作り込む流れにすること、iPadとプレビュー動画にも対応すること、このスキルを自分専用のスキルとして今後も育てることを決めた。
- Decision:
  - スキル：`.agents/skills/goldie/`を`.agents/skills/appstore-creative/`に置き換える。Goldie（固定版0.3.1）は、描画、配置の計算、字体、動画の書き出しの土台として使う。Goldieにないものは、テンプレートが持つ拡張層に足す。拡張層はGoldieが公開する部品（`compose`、`LAYOUTS`、`DEVICES`、`renderScreenshots`、`renderPreview`）を使い、Goldieの版が固定版と違うときは止まる。Goldieの内部に縛られて作れないものが出たときは、Goldie（MIT）をforkする道を別のDecisionで選べる。
  - 面の種類：次の7種とし、iPhone 6.9-inchとiPad 13-inchの両方で作る。iPadは枠なし（角を丸めた画面と影）を標準とし、使用条件を確認した枠画像を後から足せる。
    - `device`：実画面＋装飾（1台のレイアウト）
    - `pair`：2画面の組み合わせ、または同じ画面の状態の比較
    - `panorama`：2枚にまたがる面
    - `continuous`：全部の面をつなぐ1枚の背景
    - `callout`：実画面の一部の拡大
    - `scene`：生成した風景の中に、Goldieが本物の端末と実画面を描く使用シーン
    - `concept`：端末のないイメージ画像と見出し
  - 守るルール：
    - 最初の3枚には実画面が入る面を置く（`concept`を置かない）。
    - `concept`は1セットに2枚まで、かつ全体の3分の1以下とする。
    - 生成画像には、アプリの画面やUI、文字、ロゴ、Apple製品をそのまま写したもの、誰か分かる人の顔を描かない。端末と画面は、Goldieか拡張層が本物の撮影画像で描く。
    - アプリにない機能や体験を連想させる絵と見出しを使わない。評価、受賞、順位などの主張を書かない。
    - 撮影した実画面の元ファイルは加工しない。例外は`callout`の切り出しだけで、元の画像と範囲を記録する。生成画像は素材として、拡大や切り抜きをしてよい。
    - 生成画像は文字を含めず、日本語と英語で共通にする。面の構成と順番は日英で同じにする。iPhoneとiPadは同じパターンを使い、配置は機種に合わせて変えてよい。
  - 流れ：
    1. 準備：実画面の撮影画像を確かめ、なければ既存の撮影toolで撮る。
    2. 提案メモ：アプリの売り、雰囲気、色、使える実画面、枚数をまとめる。
    3. 第1段階：3〜4パターンを、日本語iPhoneの縮小版で実際に描いて示す。各パターンは代表の生成画像を1枚だけ使う。
    4. 選択：ユーザーがパターンIDを1つ選ぶか、面ごとの出どころを明示して組み合わせる。曖昧なときは、組み合わせた版を作って選び直してもらう。
    5. 第2段階：選んだパターンの全素材を生成し、日英とiPhone・iPadの全面を描いた見本で確認する。直しは新しい版で示す。
    6. 仕上げ：最終寸法で書き出して検査し、採用した画像を既存の準備手順（prepare-appstore-assets）へ渡す。
  - 提案シート：画像を埋め込んだ1つのHTMLとし、外部への通信をしない設定を入れる。`.artifacts/store-creative/<revision>/`に置いてGitに入れず、SHA-256を記録し、見せた版を上書きしない。Claudeが作業するときは、同じHTMLを非公開のArtifactとしても公開する。Codexは手元のHTMLを見せる。選択は`selection.json`（revision、シートのSHA-256、選んだパターンまたは面ごとの出どころ、`user-explicit`）に記録する。
  - 画像生成：Codexの組み込み画像生成を使う。Claudeが作業するときは、生成だけをCodexへ頼む。組み込みの生成が使えないときは止めて報告し、APIキーを使う方法はユーザーが明示したときだけ使う。生成した画像は、指示文、生成の方法、SHA-256と一緒に`.artifacts/store-creative/<revision>/generated/`へ置く。同じ原因で2回失敗したら止める。ユーザーの参考画像は、使う権利をユーザーが確認したときだけ使う。
  - 採用したものの置き場（各アプリ）：Goldieの設定は`goldie/<locale>/`（iPad用も同じ場所）、採用した生成画像は`goldie/assets/`、その由来（指示文、生成の方法、SHA-256、採用したrevision）は`goldie/assets/provenance.json`に置いてcommitする。不採用の画像と提案シートはcommitしない。
  - プレビュー動画：
    1. 絵コンテを2案、静止画のシートで示し、ユーザーが1案を選ぶ。
    2. 専用Simulatorで1場面だけ試し録りし、解像度、30fps、長さ、コマ落ちや止まり、真っ黒なコマ、ステータスバーの固定を機械で確かめる。不合格なら「動画なし」と記録して終える。
    3. 合格したら全場面を録画し、Goldieの書き出し（iPhone 886×1920、iPad 1200×1600、15〜30秒）で下書きを作る。ユーザーが「採用」か「動画なし」を決める。
    - 録画は、既存の撮影toolと同じ専用Simulatorの専有の中で、消去、Releaseビルドのinstall、ステータスバーの固定、状態を指定した起動、決めた秒数の録画を行い、映像と記録を端末の外に保存する。
    - ユーザーが実機で画面収録した映像を素材として受け取り、編集と書き出しだけを行う方法も持つ。その由来は`user-supplied`と記録する。AIは実機を操作しない。
    - 音は標準で無音とし、BGMはユーザーが頼んだときだけ別に用意する。
  - 提出の前に、Appleの最新の画像と動画の規格、審査ガイドラインを確かめる。
  - ワークフローだけの変更：`appstore-creative`スキル、拡張層、提案シートのtool、録画と品質確認のtool、それらの直接のregression testは、認証を行わないlocalのproducerとする。各実装Issueが自分のHeadで正確なpathを列挙したものだけを、D-054のexact allowlistへ加えられる。実アプリの見出しや採用画像、package内容、upload、提出は、これまでどおりrelease経路に残す。
- Consequence: 実装は次の後続Issueに分ける。(1) スキルと提案シート、(2) 拡張層の`concept`とiPad、(3) プレビュー動画の録画と品質確認、(4) 採用した動画を提出packageとApp Store Connectへの保存に通す経路。(1)と(2)はこのDecisionの後に並行して進められ、(3)のiPadの書き出しは(2)に依存し、(4)は(3)とD-059の経路に依存する。テンプレートでのtestは、偽の`xcrun`、試験用の画像と映像、固定版のGoldieで行い、実Simulatorでの撮影、画像の品質、App Storeでの受理を主張しない。派生アプリへの導入は、テンプレートの取り込み（D-074）とそのアプリのPhase 6のIssueで行う。`~/.codex/skills/goldie`の個人用コピーは、ユーザーが扱いを決める。
- Related Issue: #280

## D-078: テンプレートの取り込みに2つの入り口を設け、ファイルごとの出どころと事前の分析で判定する

- Date: 2026-10-13
- Status: 確定
- Supersedes: D-074のうち、基準commitが記録されていない、または不正な取り込み先で、テンプレートと違うファイルをすべて手で確認する扱い（`conflict`）の部分を置き換える。ファイルの所有区分、基準commitの記録、差分レポートと計画、計画のdigestに結び付けた承認、承認された項目だけを作業ブランチへ適用すること、Identity変換の再適用、専用Simulatorの厳守、取り込み先の1つのテンプレート同期Issueで進めることは維持する。
- Context: D-074の仕組みはテンプレートのリポジトリからしか使えず、2026-10-13時点で基準commitを記録している派生アプリは`iOS-AnyGPS`だけだった。ほかの7つのアプリでは、違うファイルがすべて手で確認する扱いになり、量が多すぎて誤りやすい。差分レポートはファイルごとの判定までで、テンプレートで名前が変わったものの古い方や、アプリ独自の似たファイルが残る重複、アプリ側の改造、先に必要な整理を示さない。ユーザーは2026-10-13に、開発中のアプリからテンプレートを参照して取り込む入り口と、テンプレートから取り込み先を指定して取り込む入り口を作ること、適用の前に差分をしっかり分析すること、元のアプリを壊さないよう厳密に進めること、ほかの作業中には取り込まず取り込み先の単独の作業として行うこと、worktreeで並行する方法は変更が大きい場合にはおすすめしないと伝えることを決めた。
- Decision:
  - 入り口：
    - 入り口1：開発中のアプリのリポジトリから、このMacのテンプレートのcheckout（`/Users/uesugiyuuto/Documents/Xcode/iOS-Template`）を参照して、そのアプリへ取り込む。
    - 入り口2：テンプレートのリポジトリから、取り込み先のアプリのリポジトリを指定して取り込む。
    - どちらの入り口でも、Issue、ブランチ、PRは取り込み先のアプリに作り、取り込み先の`AGENTS.md`と規則に従う。テンプレートのリポジトリには書き込まない。
    - 取り込み元は、テンプレートのcleanな`main`で`origin/main`と一致するcommitだけとする。テンプレートで作業途中の変更は取り込まない。
  - スキル：2つの入り口を1つのスキル`ios-template-sync`にまとめる。正本はテンプレートの`.agents/user-skills/ios-template-sync/`に置き、`~/.claude/skills/ios-template-sync`と`~/.codex/skills/ios-template-sync`はその正本を指すリンクにする。リンクを張るtoolは、同じ名前のフォルダや別のリンクがあれば上書きせずに止まる。このスキルはテンプレート専用とし、取り込みでアプリへ持ち込まない。
  - ほかの作業中かの判定：取り込み先で、作業中の状態（Claim済み、作業中、検証済み、レビュー中、差し戻し、merge待ち、停止中、blocked）のIssue、Issueのworktree、`main`以外のブランチや未commitの変更がある本体のcheckout、開いているPRのいずれかがあれば、ほかの作業中とする。判定は読み取りだけで行う。
  - 変更の大きさ：基準commitが記録されていない、書き込むファイルが30を超える、手で確認するファイルが10を超える、先に必要な整理がある、`AGENTS.md`・`Config/repository-tests.json`・`specs/decisions.md`のような共有の設定に触れる、のいずれかに当たれば大きい変更とする。この数値は、実際の取り込みを見て後のDecisionで調整できる。
  - 進め方：ほかの作業中でなければ進める。ほかの作業中なら止めて作業中の内容をユーザーに伝え、終わるまで待つことを勧める。並行するならworktreeを分けて行えるが、大きい変更では並行をおすすめしないとはっきり伝え、並行するかはユーザーの明示の指示だけで決める。
  - ファイルごとの出どころ：取り込み先の各ファイルを、テンプレートの全履歴にある同じパスの全版と比べる。Identity変換されるファイルは、比べる版にも取り込み先のIdentityで変換を再適用する。どれかの版と1バイトも違わずに一致すれば、取り込み先はその版を改造せずに使っているとして、基準commitが記録されていない取り込み先でも、最新の版への更新を安全な更新として扱う。どの版とも一致しなければアプリ側で改造したものとして手で確認し、最も近い版との差分を添える。一致が最も多い版を推定の基準としてレポートに示す。基準commitが記録されている取り込み先の判定はD-074のままとする。
  - 事前の分析：取り込み先へ書き込まずに、次の4項目を分析し、ユーザーが読む日本語の`analysis.md`と、toolが読む`analysis.json`を計画と同じ場所（取り込み先の外）に書く。
    - 不足と更新：テンプレートにあって取り込み先にないもの、取り込み先が古い版のままのもの。それぞれに、変更を入れたテンプレートのcommitとIssue、関係する決定事項を添える。
    - 重複と名前の変更：テンプレートの履歴で名前が変わったものの古い方が取り込み先に残っていれば、古い方の削除と新しい方の追加を1組として示す。取り込み先だけにあるファイルのうち、テンプレートのファイルと中身が似ているもの、同じ役割の名前のものを重複の可能性として示し、扱いはユーザーが決める。
    - アプリ独自の改造：テンプレートのファイルをアプリ側で書き換えた箇所と最も近い版との差分、アプリの変更を残す・テンプレートに合わせる・両方を合わせるの候補、テンプレートへ戻す価値がありそうかの所見。テンプレートへの報告は、ユーザーが頼んだときだけ`report-template-issue`で行う。
    - 先に必要な整理：決定事項の番号の衝突（`specs/app-decisions.md`の`A-###`への移行）、Identityの未設定、専用Simulatorの宣言、基準commitの記録、検証に使う取り込み先のtoolが古すぎないか。取り込みIssueの最初の手順として、片付ける順を示す。
    - 分析の冒頭に、書き込むファイルの数、手で確認する数、重複の可能性の数、先に必要な整理、大きい変更かどうかとその理由を要約する。
  - 承認と適用：承認はD-074のとおり計画のdigestに結び付け、ユーザーが計画と分析を読んで行う。Codexの承認はユーザーが指定したときだけとする。
  - 取り込みIssueの検証：取り込んだtoolとskillのrepository test、アプリのBuild、重要なUnit Test、日本語iPhoneのSmoke Testを行い、反対モデルの承認を必須にする。受け入れ条件には、取り込みの前と後でアプリのBuildとUnit Testが同じように通ることを含める。
- Consequence: 実装は次の後続Issueに分ける。(1) ファイルごとの出どころと推定の基準を差分レポートと計画に入れる、(2) ほかの作業中かの判定と大きさの見積もり（`preflight`）、(3) 4項目の分析（`analyze`）、(4) `ios-template-sync`スキル、リンクを張るtool、`docs/template-sync.md`の更新。(1)から(3)は同じtoolを変えるため順に進め、(4)はそれらに依存する。テンプレートでのtestは、偽のテンプレートの履歴、偽の取り込み先、偽のGitHubで行い、実在するアプリへの取り込みを主張しない。実在するアプリへの取り込みは、それぞれのアプリのテンプレート同期Issueで行う。
- Related Issue: #288

## D-079: 専用iPhoneを、App Storeの必須画像サイズになったiPhone 17 Proにする

- Date: 2026-10-13
- Status: 確定
- Supersedes: D-070のうち、専用iPhoneの機種をiPhone 17 Pro Max（1320×2868）とした部分と、D-077のうちApp Store用のiPhoneの画像をiPhone 6.9-inchで作るとした部分を置き換える。専用はiPhone 1台とiPad 1台だけ、AI検証とApp Store撮影の両方に使う、exact name・Device Type・Runtimeでちょうど1台を確認する、AIは端末を作成・clone・rename・削除しない、各caseの前にeraseする、`-parallel-testing-enabled NO`で実行する、派生アプリは表示名を前置した同じ機種を持つ、専用iPadをiPad Pro 13-inch (M5)とする、という規則は維持する。
- Context: 2026-10-13にAppleのスクリーンショット仕様（App Store Connect Help「Screenshot specifications」）を確認すると、提出に必須のiPhoneの画像は「At least one screenshot for iPhone with Dynamic Island (medium display).」で、受け付ける寸法は1206×2622と1179×2556（iPhone 18 Pro、17 Pro、17、16 Pro、16、15 Pro、15、14 Pro）になっていた。D-070で選んだiPhone 17 Pro Max（1320×2868、Dynamic Island (large display)）は必須ではなくなった。iPadの必須は引き続き13-inch（2064×2752）で、プレビュー動画の寸法はiPhoneの中と大のどちらも886×1920、iPad 13-inchは1200×1600のまま変わらない。App Store Connect APIの画面種別には6.3-inchの値がなく、中サイズの画面に当たる値は`APP_IPHONE_61`と見られる。ユーザーは同日、専用iPhoneをiPhone 17 Proへ変えることを決めた。
- Decision:
  - Templateの専用iPhoneを`iOS-Template iPhone 17 Pro`（Device Type iPhone 17 Pro、1206×2622、Runtime iOS 27.0）に置き換える。専用iPadは`iOS-Template iPad Pro 13-inch (M5)`のままとする。派生アプリは表示名を前置した同じ機種（例：`Flower iPhone 17 Pro`）とする。
  - App Store用のiPhoneの画像は、Dynamic Island (medium display)の寸法（1206×2622、1179×2556）で作る。提出の要件、撮影tool、画像判定、提出packageの検査、`appstore-creative`はこの寸法を使う。
  - App Store Connectへの保存では、iPhoneの画像を`APP_IPHONE_61`の画面種別へ入れる。この対応は、最初の実際の保存で読み戻して確かめるまで、確認待ちとして扱う。
  - 提出の要件（`App Store/submission/requirements.json`）は、撮影tool、画像判定、提出packageの検査が読む非認証の設定として、後続Issueが自分のHeadで正確なpathを列挙したうえでD-054のexact allowlistへ加えて変更できる。同じ後続Issueは、その直接のtest fixture（`tools/tests/fixtures/appstore/requirements.json`）と、iPhoneのfamilyのフォルダ名を固定値で持つ提出packageの検査の直接のtest（`tools/tests/test-appstore-package.sh`）も、同じ方法でallowlistへ加えて変更できる。提出packageの検査そのもの（`tools/validate-appstore-package.sh`）、実アプリのmetadata、採用画像、package内容、upload、提出は、これまでどおりrelease経路に残す。
  - プレビュー動画の寸法（iPhone 886×1920、iPad 1200×1600）は変えない。
  - 新しい専用iPhoneは、宣言の変更がmergeされた後にユーザーが`tools/setup-dedicated-simulators.sh`で作成する。AIは作成しない。古い`iOS-Template iPhone 17 Pro Max`はAIが削除せず、ユーザーが削除する。新しい端末ができるまで、iPhoneを使うネイティブの検証は`blocked:environment`とする。
- Consequence: 実装は次の後続Issueに分ける。(1) 専用Simulatorの宣言、検証の文書とtest。(2) 提出の要件、撮影tool、画像判定、提出packageの検査、App Store Connectの画面種別の対応とtest。(2)は、`AGENTS.md`のworkflow-onlyで扱えるApp Store関連変更の文へ、この提出の要件とそのfixture／直接regression testを、ユーザーが承認した文面で加える。`appstore-creative`のiPhoneの寸法は、D-077の後続Issue（拡張層、録画と品質確認、動画の仕上げ）で、このDecisionに合わせて作る。2027年4月からiOS 27.1 SDK以降のアプリにiPhone Duoの画像が必須になるとAppleが予告しているが、このDecisionでは扱わない。派生アプリへの適用は、テンプレートの取り込み（D-074、D-078）とそれぞれのアプリのIssueで行う。
- Related Issue: #290

## D-080: Codexのレビューを、gpt-6.1-solのreasoning effort xhighで行う

- Date: 2026-10-13
- Status: 確定
- Supersedes: `docs/agent-contracts/review-packet.md`の§6で、Claude primaryからCodexを呼ぶレビューのmodelを`gpt-6-sol`、reasoning effortを`high`、時間の上限を10分とした部分と、`docs/template-sync.md`で、テンプレート取り込みの計画をCodexが確認するときのmodelを`gpt-6-sol`、reasoning effortを`high`とした部分を置き換える。modelを固定し、使えないときに別のmodelへ置き換えず`blocked:review`とすること、read-onlyで呼ぶこと、Codex primaryからClaudeを呼ぶレビューとGrokを呼ぶレビューの時間の上限（10分）は維持する。
- Context: 2026-10-13時点で、反対モデルのレビューとテンプレート取り込みの計画の確認は`gpt-6-sol`、reasoning effort `high`に固定されていた。ユーザーの個人のCodexの設定は`gpt-6.1-sol`、`xhigh`だった。ユーザーは同日、レビューのmodelを`gpt-6.1-sol`の`xhigh`へ上げることを決めた。これまでのhighのレビューは1件80〜291秒かかっており、xhighでは大きな変更で10分を超えるおそれがある。
- Decision:
  - Claude primaryからCodexを呼ぶ反対モデルのレビューは、model `gpt-6.1-sol`、reasoning effort `xhigh`に固定し、時間の上限を20分（1200秒）とする。
  - テンプレート取り込みの計画をCodexが確認するとき（D-074、D-078）も、model `gpt-6.1-sol`、reasoning effort `xhigh`、時間の上限20分とする。確認の記録に残すmodelも`gpt-6.1-sol`とする。
  - Codex primaryからClaudeを呼ぶレビューと、Grokを呼ぶレビューは変えない。
- Consequence: Codexを起動するlauncherの中身が変わるため、これからのレビューの記録は新しいlauncherのdigestに結び付く。それより前のレビューの記録は書き換えない。派生アプリへの適用は、テンプレートの取り込み（D-074、D-078）で行う。
- Related Issue: #302（#291を置き換え）

## D-081: App Storeの審査ガイドラインを、機能の計画時と提出の前の2か所で適用する

- Date: 2026-10-17
- Status: 確定
- Supersedes: なし。D-077の「提出の前に、Appleの最新の画像と動画の規格、審査ガイドラインを確かめる」のうち審査ガイドラインの部分を、確かめ方を定めて補う。checklistのschemaとkeys、封印済みpackage／resultの形式、提出packageの検査（`tools/validate-appstore-package.sh`）をrelease経路に残すこと（D-054、D-079）は変えない。
- Context: テンプレートは、画像の規格と提出の要件（`App Store/submission/requirements.json`）を機械で確かめる。一方でAppleの審査ガイドライン（https://developer.apple.com/app-store/review/guidelines/ 、2026-10-17の確認で「Last Updated: October 16, 2026」）は、`appstore-creative`が2.3.3を個別に参照し、D-077が提出の前に確かめるとするだけで、機能ごとに関わる項目を計画時に洗い出す手順も、提出の前に全項目を点検した記録もない。そのため、アカウントを作れるアプリのアプリ内でのアカウント削除（5.1.1(v)）、他社ログインを主に使うときの同等の選択肢（4.8）、デジタルの購入の復元（3.1.1）、ユーザーの投稿の通報とブロック（1.2）のような要件が、提出の直前や審査の却下で初めて見つかるおそれがある。ユーザーは2026-10-17に、審査ガイドラインをテンプレートにも適用し、機能の計画時と提出の前の両方で使うこと、TemplateApp本体は点検して不足があれば別のIssueで直すことを決めた。
- Decision:
  - 正本：Appleの審査ガイドラインのページを正本とする。テンプレートは、項目番号、日本語の短い要約、その項目が関わる機能の種類、確かめ方を持つ対応表を持つ。Appleの本文は写さない。対応表には、ページの「Last Updated」の日付、取得日、ページのURLを記録する。
  - 対応表の分類：各項目を次のどれか1つにする。
    - `always`：すべてのアプリに関わる。例：2.1 完成度とデモの用意、2.3 metadataの正確さ、1.5 連絡先、5.1.1 プライバシーポリシーへのアプリ内とApp Store Connectのリンク、2.5.1 公開APIだけを使う。
    - `triggered`：特定の機能を持つときだけ関わる。機能の種類（アカウントの作成、他社のログイン、デジタルの購入とサブスクリプション、広告とトラッキング、ユーザーの投稿と交流、子ども向け、健康と医療、位置情報、個人データや外部AIへの送信、Webの表示、拡張機能とWidget、通知、レビューの依頼、懸賞と賭け事、暗号資産、Apple Pay、VPNとMDM、ミニアプリとエミュレータなど）と結び付ける。
    - `user-judgment`：AIが機械的に判断できない。例：4.1 模倣、4.2 最低限の機能、4.3 スパム、5.2 知的財産、1.1 不適切な内容。AIは所見を示し、ユーザーが決める。
  - 計画時：機能を計画するとき（`plan-issue-batch`、`spec-workflow`、Feature Issueの作成）、その機能が対応表のどの`triggered`の種類に当たるかを調べ、当たる項目の具体的な要件をそのIssueの受け入れ条件へ入れる。例：アカウントを作れるならアプリ内で削除できる、他社のログインを主に使うなら同等の選択肢を出す、デジタルの購入には復元を用意する、ユーザーの投稿には通報とブロックを用意する、位置情報やトラッキングは事前に同意を得る。当たる種類がなければ、Issueの本文にその旨を書く。要件の扱いが受け入れ条件を変える未決事項なら、`blocked:user`とする。対応表と手順を実装する後続Issueが完了するまでは、Appleのページを直接確かめて同じことを行う。
  - 提出前：各アプリは、対応表のすべての項目を、`satisfied`（満たしていて、根拠の場所がある）、`not-applicable`（理由がある）、`user-confirmed`（`user-judgment`の項目をユーザーが確認した）のどれかにした点検表を、`App Store/review/`に持つ。点検表は、使った対応表の版（Appleの更新日と対応表のdigest）と、点検したbuildのversionに結び付ける。認証を行わないlocalの点検toolが、点検表が対応表の全項目を覆い、未解決の項目がなく、版とversionが一致することを確かめる。`prepare-appstore-assets`、`release-auditor`、`submit-appstore-release`は、この点検toolが成功したときだけ提出へ進める。
  - 鮮度：提出の前に、Appleのページの「Last Updated」を確かめる。対応表の日付と違えば提出を止め、先にテンプレートで対応表を更新するIssueを行う。派生アプリは、テンプレートの取り込み（D-074、D-078）で新しい対応表を受け取ってから点検する。対応表の取得日から30日を超えたときも、確かめ直すまで提出しない。
  - 既存の境界：checklistのschemaとkeys、封印済みpackage／resultの形式、提出packageの検査、提出の明示許可、初回の法務承認、release audit、外部操作の権限は変えない。点検表と点検toolの成功を審査通過の証拠とせず、審査の結果を推測しない。
  - TemplateApp：対応表と点検toolができたあと、TemplateAppを点検し、その結果をIssueに記録する。不足が見つかれば、それぞれ別のIssueで直す。テンプレート自身は提出しないため、`App Store/review/`の点検表をテンプレートにcommitしない。
- Consequence: 実装は次の後続Issueに分ける。(1) 対応表と`app-review-guidelines`スキル、計画時の手順（`plan-issue-batch`、`spec-workflow`、`spec-reviewer`、Feature Issueのtemplate）と、その直接のtest。(2) 提出前の点検表の形式と点検tool、`prepare-appstore-assets`、`release-auditor`、`submit-appstore-release`、`docs/agent-contracts/appstore-submission.md`からの呼び出しと、その直接のtest。(3) TemplateAppの点検。(2)は(1)に、(3)は(2)に依存する。(1)と(2)の新しいファイルはApp Storeのpathの外に置き、workflow-onlyのexact allowlistと`AGENTS.md`を変えずに進める。これができない変更が必要になった場合は、その後続Issueで`AGENTS.md`の文面をユーザーに承認してもらう（D-075）。点検で見つかった不足の修正は、(3)のあとに別のIssueにする。派生アプリへの適用は、テンプレートの取り込みとそれぞれのアプリのIssueで行い、既に提出したアプリにも次の提出から適用する。
- Related Issue: #319

## D-082: 3Dモデルの作成経路を、モデルの複雑さで選ぶ

- Date: 2026-10-18
- Status: 確定
- Supersedes: D-071のうち、Tripoをすべての3Dモデルの標準の経路とし、簡単なモデルや即効性を求める場合だけClaudeまたはCodexの`gpt-6-astra`に依頼するとした部分を置き換える。3D作業を共有の`ios-3d-assets` skillへrouteすること、Tripoのログイン、プランや課金の変更、認証情報の入力をユーザーが行うこと、Claudeはユーザーのログイン済みsessionだけで操作すること、どの経路でも形式検証、統合、Build／Test、視覚確認を行い、Issue／PR証拠にauthoringの経路を記録すること、ClaudeとCodexの一般開発での同等の権限は維持する。
- Context: 派生アプリCafLogで、単純なローポリの容器4つ（缶、カップ、ボトル、箱）を、D-071の標準の経路どおりTripoで作った。テキストから作った箱を含め、マルチビュー生成を使わず、生成数2、部分修正なしで生成とテクスチャを行い、約480クレジットを使った。ユーザーは、Tripoを使うまでもない単純なモデルで、クレジットに見合わない仕上がりだと判断した。ユーザーは2026-10-14に、モデルの複雑さで経路を選ぶことと、Tripoの操作手順を指示し、2026-10-18に、経路の判定、繰り返しの上限、クレジットの承認、画風の統一、動くモデル、アプリでの合格の目安、Codexの作り方、TripoのUIの変更への対応、Claudeが作る経路を残すことを決めた（#318）。
- Decision:
  - 経路：
    - ごく単純な形（箱、円柱、球のいくつかの組み合わせと単色）は、ClaudeがBlenderで直接作れる（`claude`）。
    - 単純なモデルと部品の単純な動き（回る、開く、滑る、伸びる）は、Codexの`gpt-6.1-sol`（reasoning effort `xhigh`）が欲しい素材の参照画像を作り、Claudeが評価して修正をやり取りする。完成した画像を添えてCodexの`gpt-6-astra`（reasoning effort `xhigh`）がモデルを作り、Claudeの評価と`gpt-6-astra`の修正を繰り返す（`codex`）。
    - 複雑で高い品質が必要なモデル（生き物、布、食べ物などの有機的な形、多くの部品、写実的なテクスチャ）と、骨格で動くモデルだけを、ユーザーまたはClaudeがブラウザでTripoを操作して作る（`tripo`）。骨格で動くモデルにはTripoのリグ機能を使う。
  - 経路の判定：形、部品の数、テクスチャの写実さ、動き（なし、部品の単純な動き、骨格）を基準に、AIが経路を提案して理由をIssueに書く。どちらとも言えないものだけ、ユーザーに確認し、選ぶまで`blocked:user`とする。ユーザーはいつでも経路を変えられる。
  - 画風の統一：一式で作るときは、最初に`gpt-6.1-sol`が画風の基準の画像を2案作り、ユーザーが1案を選んでから各モデルを作る。各モデルの参照画像はその基準に合わせ、寸法の決まりもそろえる。単独のモデルでは作らない。
  - Codexの作り方：`gpt-6-astra`はBlenderのPython（bpy）でモデルを組み立て、`.blend`の元のファイルを残し、GLBとUSDZへ書き出す。Claudeは、参照画像と同じ角度を含む複数の方向（前、横、上、斜め）のレンダリングで、参照画像、寸法、原点、向きと比べて評価する。
  - 繰り返しの上限：Codexの経路では、参照画像の評価と修正を5回、モデルの評価と修正を5回までとする。超えたら、その時点の結果をユーザーに見せ、続けるかTripoへ切り替えるかをユーザーが決める。
  - modelの固定：`gpt-6.1-sol`と`gpt-6-astra`を名前で指定し、使えないときはほかのmodelに置き換えず`blocked:environment`で止める。証拠には実際に使ったmodelを記録する。
  - Tripoの手順：
    - 必ず生成した画像を基にモデルを作り、テキストからは作らない。
    - 画像には必ずマルチビュー生成を使い、その結果を評価する。
    - トポロジーとポリゴン数を設定した後、生成数を4にする（消費するクレジットは1と同じ）。
    - 生成したモデルが完全でないときは、まず画面下部の部分修正を使う（3回まではクレジットを消費しない）。
    - その後に、テクスチャの生成とCodexの`gpt-6-astra`への細かな修正依頼を行う。
    - クレジットを使う操作（画像の生成、モデルの生成、有料の修正、テクスチャ、リグ）の前に、予想の消費量を示して毎回ユーザーの承認を得る。無料の部分修正は確認しない。
    - 画面が手順と違うときは、クレジットを使う操作をせずに止めてユーザーに報告する。手順には確かめた日付を書く。
  - アプリでの合格の目安：小物は三角形5,000以下、テクスチャ1024px、USDZ 2MB以下。主役は三角形30,000以下、テクスチャ2048px、USDZ 10MB以下。超える場合はIssueに理由を書いてユーザーが承認する。どの経路でも、GLBとUSDZの検証、RealityKitでの読み込み、アニメーションの再生、ライトとダークの両方の見え方を、別々の確認として行う。
  - 証拠の記録：経路（`claude`、`codex`、`tripo`）、使ったmodel、繰り返しの回数、生成日、指示や参照の説明、採用した参照画像、書き出しの形式を記録する。Tripoでは、ユーザーが承認したクレジットを記録する。アカウントの識別子、session、課金の情報は記録しない。
- Consequence: `ios-3d-assets` skill、`AGENTS.md`の3Dの規則（ユーザーが2026-10-18に承認した文面）、`docs/workflow.md` §2.3、`specs/product.md` §5.1、`specs/acceptance.md`、`specs/architecture.md`、`docs/README.md`、`docs/verification.md`を#318で合わせる。D-071の経路で作った既存のassetは作り直さない。派生アプリへの適用は、テンプレートの取り込み（D-074、D-078）で行う。
- Related Issue: #318

## D-083: 採用済みのアプリアイコンを、ユーザーが用意した完成済みのアイコンへそのまま差し替えられるようにする

- Date: 2026-10-19
- Status: 確定
- Supersedes: None。D-031の初回App Icon Gate（生成の候補exactly 2案と明示選択）と、D-065の生成の候補からの差し替え（新revisionの候補の明示選択、参照画像の編集）を既定の経路として維持し、差し替えに限る例外の経路を加える。
- Context: 派生アプリCafLogは2026-10-14、生成の候補から採用していたアイコンを、ユーザーが用意した完成済みのアイコン（不透明な黄色の背景の画像と、透明なdark appearance用の画像）へ、編集せずにそのまま差し替えた。今の仕様には、ユーザーの画像を編集の入力にする経路（`builtin-imagegen-reference-edit`）しかなく、`tools/validate-app-icon.sh`は`generator: "user-provided"`の記録を`generator is invalid`で拒否した（#341）。ユーザーは2026-10-19に、この経路を含むテンプレートの残りの作業を進めることを承認した。初回の採用で完成済みのアイコンを使うことは、新しいアプリの最初のアイコンを生成の2案から選ぶ`AGENTS.md`の規則の変更が必要なため、このDecisionに含めない（#343を#344で置き換えた）。
- Decision:
  - 採用済みのアイコンを差し替えるとき、ユーザーが完成済みのアイコン画像を明示的に渡し、そのまま採用すると指示した場合だけ、新しい生成の候補を作らずにその画像へ差し替えられる。指示がなければ、D-065の経路を使う。初回の採用はD-031のとおりとする。
  - 差し替えの前に、ユーザーがその画像をアプリアイコンに使う権利を持つことを明示的に確認する。installerは明示の確認の入力がなければ止まり、確認はIssueの証拠に記録する。
  - D-065と同じく、installerの明示replace mode、callerが宣言した現行採用SHA-256、clean worktreeを必須とする。生成の候補の選択記録（`selection.json`）の代わりに、ユーザーの画像と権利の確認を入力にする。過去に採用した画像への戻し、変化のない差し替えは、D-065と同じく変更前に止まる。
  - 採用記録はD-065と同じschema 2とし、`generator`は`"user-provided"`、`selectionRevision`と`supersedes`を必須にする。採用したassetはユーザーの画像をそのまま不透明なPNGとして書き出したもので、ほかに編集の入力がないため、`referenceSha256`は`null`とし、記録の`sha256`が採用したassetを指す。`supersedes`の`generator`にも`"user-provided"`を許す。`promptSummary`には生成の指示の代わりに、画像の出所と権利を確認した日をsanitizedに書く。
  - 画像は、system mask前の正方形で、実透明pixelのない1024 x 1024のPNGとする。文字、イニシャル、数字、スクリーンショット、Apple製品の複製、第三者mark、識別可能な人物の顔、watermark、焼き込んだ角丸maskを含めない条件は、生成と同じく守る。一つの主題、単純な背景、少ない形と色という構成の既定は生成の指針であり、完成済みのアイコンには求めない。
  - Asset Catalogの既存のdark／tintedのappearance entryを削除・置換せず、validatorもそれを理由に拒否しない。
- Consequence: 派生アプリは、採用済みのアイコンを、ユーザーが用意した完成済みのアイコンへ、installerを迂回せずに差し替えられ、CafLogの今の採用記録はD-083の形を満たす。validator、installer、`app-icon`スキル、その直接のtestは#341で合わせる。ユーザーの元の画像のうちGitに入れるのは採用したassetだけで、ほかの画像は`.artifacts/`などGitの外に置く。初回の採用で完成済みのアイコンを使う経路は、`AGENTS.md`の文面の承認とともに別に判断する。外部サイトやApp Store Connectに掲載したアイコンの更新は、別Issueで行う。
- Related Issue: #344

## D-084: 開発中のディスク容量を、worktreeとIssueに結び付けて際限なく増やさない

- Date: 2026-10-20
- Status: 確定
- Supersedes: None。D-063の専用device 2台と各caseの前のerase、verify runnerのattemptの削除、所有の確認、split-lockの回避（`.verify.lock`を残すこと）、lease時の空き容量の確認は維持する。`specs/acceptance.md`と`specs/development-stages.md`の「ユーザーのDerivedDataを保護する」は、Issueの後片付けが回収する範囲を除く形に読み替える。
- Context: 2026-10-20、派生アプリ6本の開発環境で、Macの空き容量が2日で51GBから14GBまで減った（ユーザーの実測）。主な原因は、runnerを通さずにエージェントがその場で実行する`xcodebuild`が作業やIssueごとに新しい`-derivedDataPath`と`.xcresult`を作り、セッションの一時フォルダに約46GBたまったこと、ある派生アプリの専用Simulatorの壁紙データ（`PRBPosterExtensionDataStore`）が約23GBになったこと、テンプレートのtestが`~/Library/Developer/Xcode/DerivedData`へ中身が`Logs`だけのフォルダを残すこと（このMacで`GardenNotes-*`が414個など）である。verify runnerは自分のattemptを消しており、`tools/cleanup-issue.sh`はbranchとworktreeだけを消す。Simulator runtimeを消す外部の掃除toolで、iOS 27のruntimeが消えたこともあった。ユーザーは2026-10-20に、#367〜#373に分けて対策することを承認した。
- Decision:
  - runnerを通さない検証のBuild／Testは、worktreeごとに1つの決まったDerivedDataを使い回し、作業やIssueごとに新しい場所を作らない。置き場所はリポジトリの外の`~/Library/Caches/ios-template/derived-data/<worktree識別子>/`とし、worktree識別子はverify runnerと同じく、worktreeの物理pathの最後の要素と物理path全体のSHA-256から作る。置き場所には、どのworktreeのものかを示す所有の印として物理pathを記録する。決まった場所を使う入口のtoolを用意し、文書から案内する（#368）。
  - `.xcresult`は、必要な情報を読み終えたら消す。明示して残す場合だけ、worktreeごとに新しい3件までとする。ミューテーション検証などで別のDerivedDataが必要な場合は、成功、失敗、signalのいずれの終了でも消す。
  - Issueの後片付け（`tools/cleanup-issue.sh`）は、worktreeを消した後に、そのworktreeの決まったDerivedData、`info.plist`の`WorkspacePath`がそのworktreeの中を指すXcode既定のDerivedData、`/tmp/ios-template-verify/<worktree識別子>/`の下の`Retained/`と残った`Attempts/`を回収する（#369）。これらはIssueが作ったデータであり、仕様が保護するユーザーのDerivedDataには含めない。`/tmp/ios-template-verify`の下は、各Headの`.verify.lock`を待たずに取れたときだけ回収し、`.verify.lock`と空のdirectoryはsplit-lockを防ぐために残す。回収は、記述子で確かめた所有者、所有の印、pathが一致するものだけとし、名前や経過時間だけでは消さない。`.artifacts`、`failures/*.json`、ほかのworktreeやrepositoryのデータ、`info.plist`のないフォルダ、ユーザーのfile、動いているセッションの一時フォルダは回収しない。
  - 専用Simulatorの壁紙データ（`data/Library/Application Support/PRBPosterExtensionDataStore`）は、このrepositoryが宣言した専用deviceについて、Mac共通のresource managerのlockの中で貸し出し中でなく、`simctl`の一覧、`device.plist`の`state`、その端末の`launchd_sim`の有無のすべてが停止を示す場合だけ、保守用のtoolで消せる（#370）。eraseとdeleteは使わない。D-063の各caseの前のeraseは変えない。壁紙データが大きくなった原因は#371で調べる。
  - テンプレートのtestとbootstrapのtoolが見本アプリへ実行する`xcodebuild`は、その実行の一時フォルダの中の`-derivedDataPath`を使い、`~/Library/Developer/Xcode/DerivedData`へフォルダを増やさない（#372）。すでにあるフォルダは名前だけでは判断できないため、テンプレートでは消さない。
  - verify runnerは、Buildとleaseの前にattemptの置き場所のvolumeの空き容量を確かめ、既定20 GiB（環境変数`IOS_TEMPLATE_MINIMUM_FREE_GIB`で変更できる）を下回れば`blocked:environment`として止め、回収の手段を案内する（#373）。lease時の既存の8 GiBの確認は変えない。
  - テンプレートのtoolと文書は、Simulator runtimeを削除する処理、`simctl delete`、`simctl delete unavailable`、新しいeraseを含めない。
- Consequence: その場の検証のDerivedDataはworktreeごとに1つとなり、Issueが終わると後片付けで回収されるため、作業の数に比例して増えない。専用Simulatorの壁紙データは停止中に小さくでき、Buildの前の確認で、空き容量が少ないまま検証を始めない。新しいtool、test、文書は既存の所有区分（D-074、D-078）で派生アプリへ取り込まれ、`Config/repository-tests.json`は従来どおり手で合わせる。すでにたまったscratchpadやDerivedDataのフォルダはこのDecisionでは消さず、ユーザーが別に扱う。端末ごとのMobileAssetは消しても再び入るため削除の対象にせず、専用deviceをrepositoryごとに2台とするD-063で増え方を抑える。
- Related Issue: #367

## D-085: App Storeの画像を、アプリの個性の正本、パターンごとのスタイル仕様、参考の調査から作り、3〜6案からおすすめを示して選んでもらう

- Date: 2026-10-21
- Status: 確定
- Supersedes: D-077のうち、第1段階で3〜4パターンを示すこと、各パターンが代表の生成画像を1枚だけ使うこと、提案メモを自由記述とし字体の既定をHiragino Sansとする案内の部分を置き換える。`specs/architecture.md`の§9の「まず3〜4パターン」も、このDecisionの3〜6案に読み替える（本文の修正は後続Issueで行う）。D-077の土台（Goldie 0.3.1と拡張層）、7種の面、パターンの提案とユーザーの明示の選択、提案シートの安全性（外部通信なし、SHA-256、上書きしない、見せた版を変えない）、最初の3枚に`concept`を置かないこと、`concept`は2枚までかつ3分の1以下、生成画像に文字・UI・ロゴ・Apple製品をそのまま写したもの・誰か分かる顔を描かないこと、実画面の元ファイルを加工しないこと（`callout`の切り出しを除く）、アプリにない機能を連想させないこと、評価・受賞・順位を書かないこと、日英で面の構成と順番を同じにすること、プレビュー動画の流れは維持する。
- Context: 2026-10-21、ユーザーは、今のストア画像が無難な背景にスクリーンショットと文字が並ぶだけで、イラストや画像がほとんど無く、何ができるのか、個性と強みは何かが分からないと指摘し、独自のやり方で個性的にしたいと求めた。参考に示されたbefore.click（デザインの評価が高いアプリの実例集）を調べると、上位のアプリは、物語でつなぐ、画面の外の世界（写真、イラスト、手、物、マスコット）、UIの一部の拡大や飛び出し、アプリ自身の字体と色を使っていた。ShotStudio（app-screenshot.app）の364種のテンプレートは、多くがグラデーション背景、見出し、端末の配色違いだった。ParthJadhav/app-store-screenshots（MIT）は、同じアプリを18のスタイルで描き分け、各スタイルを色のトークン、字体、決め手の要素、装飾の上限、言葉の調子、数値の失敗条件を持つ仕様書にし、全スタイルに共通の品質基準を持っていた。ユーザーは同日、Goldieを土台に残してParthの仕様の形式と品質基準を取り込むこと、参考サイトを見る工程を毎回の手順に入れること、最初の提案を3〜4案とし収まらないときは5〜6案まで許して、いちばん良いと思う案を示すこと、イラストや画像の生成に数の制限をかけないこと、ただしAIっぽくありきたりな画像は作らず、素材は使う前にユーザーへ見せて承認を得ることを決めた。
- Decision:
  - 流れ（D-077の流れを置き換える。撮影、第2段階、仕上げ、動画は変えない）：
    1. 準備：実画面の撮影画像を確かめる。
    2. 個性の掘り出し：各アプリの`goldie/brand.json`に、強み（実画面で示せる機能と撮影の状態に結び付ける）、使う人と場面、世界観、物語の筋（面の順に伝える流れ）、色の組（アプリの`AccentColor`とアイコンから取った色を含む）、字体と出どころとライセンス、言葉の調子（3語程度）、モチーフ、避けるものを書く。
    3. 参考の調査：同じカテゴリの上位アプリを3〜5本、before.clickなどで見て、使われている手法だけを記録する（見たURL、見た日、アプリ、手法）。デザイン、イラスト、文言、ロゴを写さない。記録は提案の版と一緒にGitの外に置く。
    4. スタイル仕様：パターンごとに1つ書く。色のトークン、字体、見出しの組み方、決め手の要素、1面の装飾の上限、面をまたぐ要素、言葉の調子、失敗条件を持ち、`brand.json`から作る。正本にない色や字体を使うときは、その理由を書く。
    5. 素材の試作と確認：パターンに使う生成素材は数を限らず作れる。使う前にユーザーへ見せ、ユーザーが明示に採用したものだけを使う（確認の関門は後続Issueで作る）。
    6. 第1段階：3〜6案を、日本語iPhoneの実際の描画で示す。いちばん良いと考える案にちょうど1つ「おすすめ」の印と理由を付ける。案の数は3〜4を基本とし、収まらないときだけ5〜6にする。
    7. 選択、第2段階、仕上げはD-077のとおり。
  - 提案シートの検査：`brand.json`、参考の調査の記録、各パターンのスタイル仕様を読み、欠けた項目、ライセンスの記録の無い字体、実画面に結び付かない強み（強みが挙げる画面の名前が、実際の撮影画像の一覧であるGoldieのraw manifestに無いもの、またはその画像が無いものを含む）、正本から外れて理由の無い色と字体、記録に無い手法を使うパターン、3〜6案の範囲外、おすすめがちょうど1案でないもの、決め手の要素が同じパターンの組、レイアウトと背景の並びが同じパターンの組を拒否する。同じレイアウトが3面以上続くもの、同じ強みを2面で伝えるもの、見出し案が長さの目安（既定は日本語16字、英語36字。提案ごとに変えられる）を超えるもの、装飾がスタイル仕様の上限を超えるものには印を付け、選択は止めない。
  - 見出し：面ごとに日英の案を2つ以上並べる。文言は仮のものとし、App Storeの文章の方針（ASOガイド、#385）ができたらそれに合わせる。
  - 品質基準：Parthの基準をApp Store用の寸法（D-079）に合わせて取り込む。端末の大きさ、層の数、クリップアートに見えないための項目、最も悪い画素でのコントラスト、面をまたぐ要素の割合、見出しの行数を、スキルの`references/patterns.md`に書く。機械で測れない項目は、ユーザーに見せる前の目視の確認項目とする。
  - 字体とツール：無料の字体（Noto Sans JP、M PLUS系、Zen系、Shippori Minchoなど）を既定の候補とする。有料の字体、クレジットを使う生成、有料のツールが必要になったら、使う前に止めてユーザーに聞き、字体は承認を`brand.json`に記録する。
  - 出典：ParthJadhav/app-store-screenshotsの仕様の形式と品質基準は、MITライセンスと出典をスキルの`references/upstream.md`に書いて取り込む。コード、編集画面、18のスタイルの本文は取り込まない。
  - 後続の方向（このDecisionにまとめ、後続Issueは`specs/decisions.md`を変えない）：
    - 素材の確認の関門（#393）：素材の試作を並べるシートとユーザーの採否の記録、未承認の素材を使うパターンの拒否、絵柄をそろえる手順、切り抜いた素材、ありきたりな画像を弾く基準。
    - 拡張層の表現（#394）：端末の前後に置くイラストや物の層、面をまたぐ要素（既定10〜30%、見出しや顔をまたがせない）、UIの飛び出し、枠の任意化、文が次の面へ続く物語の面。
    - Product page header（#391）：21:9・3840×1646の画像と、5〜30秒、無音の既定でloopする動画。safe areaは公式テンプレートで確かめた値を設定に持つ。
    - ポスターフレームと規格の照合（#392）：App previewのポスターフレームの記録と、書き出した素材をAppleの最新の規格の表と照らす検査。
- Consequence: 提案シートのtool、スキルの文書、直接のtestは#390で合わせ、ほかの方向は上の後続Issueで作る。派生アプリでは、次にストア画像を作るときに`goldie/brand.json`、参考の調査の記録、パターンごとのスタイル仕様を用意する。テンプレートのtestは試験用の画像と記録で行い、実際の画像の質や購買意欲への効果を主張しない。好みの確認は、派生アプリのPhase 6のIssueでユーザーが行う。`specs/architecture.md`の§9の本文は、bootstrapの固定fixtureに含まれるため別の小さなIssueで直す。
- Related Issue: #390

## D-086: テンプレートのリポジトリだけで、ユーザーの開発用の実機1台へビルドしてインストールできるようにする

- Date: 2026-10-22
- Status: 確定
- Supersedes: D-063と`AGENTS.md`の「専用device以外をinstall対象にしない」を、テンプレートのリポジトリでユーザーの開発用の実機1台へinstallする場合だけ除く形に読み替える。D-063の専用device 2台、各caseの前のerase、AI検証とApp Store撮影の資源契約、D-084の決まったDerivedDataは維持する。
- Context: 2026-10-21、ユーザーが、テンプレートのアプリを専用Simulator 2台と自分の開発用の実機（iPhone19）向けにビルドできるようにすることを依頼した。今の規則では、専用device以外へのinstallを許していない。ユーザーは、実機へのビルドとインストール、テンプレートだけへの導入、Xcodeの自動署名と今のTeamを使うことを選び、`AGENTS.md`の文面を承認した（#379）。
- Decision:
  - テンプレートのリポジトリだけで、`Config/development-device.json`が名前で宣言するユーザーの開発用の実機1台へ、AIが開発用の署名でビルドしてinstallできる。入口は`tools/build-for-device.sh`の`device`とする。起動、test、erase、deviceの設定の変更はしない。動作の確認はユーザーが行い、AIの検証の証拠にしない。
  - 実機は実行時に`xcrun devicectl list devices`で名前を探す。名前が一致する物理deviceがちょうど1台で、接続されている（ペアリング済みで到達できる）場合だけビルドし、0台、2台以上、未接続ならビルドの前に止まる。UDIDなどのdeviceの識別子はcommitせず、`Config/development-device.json`は名前だけを持つ。
  - 署名はprojectのXcodeの自動署名と、projectに設定された今のTeamを使う。`-allowProvisioningUpdates`を渡さず、署名の設定をコマンドで上書きせず、証明書、鍵、provisioning profile、Teamを作成・変更しない。署名が足りなければ止まり、Xcodeで用意するようユーザーへ案内する。
  - 専用Simulator 2台（`iphone-simulator`、`ipad-simulator`）へはビルドだけを行う。`Config/dedicated-simulators.json`のexact name、Device Type、Runtimeで実行時にちょうど1台を探し、`xcodebuild build -destination id=<UDID>`でビルドする。起動とinstallはしない。leaseのeraseを通らずに起動すると、データがたまるためである（D-084、#371、#380）。
  - ビルドはD-084の決まったDerivedData（`tools/xcodebuild-in-worktree.sh`）を使い、すべての`xcodebuild`、`xcrun`、`devicectl`の呼び出しに有限のtimeoutを置く。
  - 入口のtool、`Config/development-device.json`、そのtestはテンプレートだけのfile（`template-only`）とし、派生アプリへ取り込まない。
- Consequence: ユーザーは、テンプレートの変更を自分の実機ですぐに試せる。AIの検証は、これまでどおり専用Simulatorのleaseの中だけで行い、実機の結果を完了条件や証拠に使わない。派生アプリには入口がなく、派生アプリで同じことをする場合は別のIssueで決める。自動署名に必要なprovisioning profileがまだない場合、最初の1回はユーザーがXcodeで用意する。
- Related Issue: #379、#407

## D-087: AdMobの有効化で受け付ける対象年齢の下限を16歳にする

- Date: 2026-10-21
- Status: 確定
- Supersedes: D-057の有効化の入力で、テンプレートが安全側に定めていた対象年齢の下限の18歳。D-057の非trackingの既定の経路、UMP、子ども向けと同意年齢未満の扱いを別の判断とすることは維持する。
- Context: AdMobの有効化（`tools/activate-admob-integration.sh`）は`audience.minimumAge`に18以上の整数だけを受け付けていた。派生アプリCafLogはApp Storeの年齢区分が17+で、この制限のため対象を18歳以上にし、年齢区分を18+へ上げると決めていた（#376）。Googleの公式の資料にも、AppleのApp Review Guidelinesにも、非personalizedの広告の対象年齢を18歳以上とする決まりはなく、18はテンプレートの安全側の判断だった。Googleは子ども（COPPAの13歳未満）と同意年齢未満の利用者に別の扱いを定め（https://support.google.com/admob/answer/6219315 、https://developers.google.com/admob/ios/targeting ）、Appleは広告がアプリの年齢区分に合うことを求める（App Review Guidelines 2.5.18、https://developer.apple.com/app-store/review/guidelines/ ）。ユーザーは2026-10-21に、16歳以上に広げることを選んだ。
- Decision:
  - `audience.minimumAge`は16以上の整数を受け付ける。16は、EUの各国が13〜16で定めるデジタルの同意年齢の上限であり、地域ごとの場合分けを要しない。
  - `childDirected`と`underAgeOfConsent`は今までどおり`false`だけを受け付け、それ以外は変更の前に止める。
  - 18歳未満を含むアプリ（`minimumAge`が18未満）では、AdMobの共通のcoreが広告の内容のレーティングの上限をTと決め、生成するprovider（`GoogleMobileAdsProvider.swift`）がSDKへ設定する（T（teen、App Storeの12+向け）にする（`maxAdContentRating = .teen`、https://support.google.com/admob/answer/7562142 ）。18以上では、今までどおり制限しない。
- Consequence: 入力の検査、skillの文書、coreとproviderのレーティングの上限は#398で実装し、追跡済みのfixture appのBuild、Unit Test、日本語iPhoneのSmoke Testで確かめる。#398がmergeされるまで、有効化は今までどおり18以上だけを受け付ける。年齢区分が16+または17+のアプリが、年齢区分を上げずに非trackingの既定の経路で広告を有効化できる。16歳未満を対象に含むアプリは、子ども向けや同意年齢未満の扱いを別の判断として決めるまで有効化できない。実際の年齢の確認は利用者の自己申告に頼らず、アプリの仕様と年齢区分で決める。TFCD／TFUAの後継の`ageRestrictedTreatment`への移行は、このDecisionに含めない。
- Related Issue: #376、#397、#398、#408

## D-088: Supabaseを採用したアプリに、Edge Functionのdeployの経路を許可する

- Date: 2026-10-21
- Status: 確定
- Supersedes: なし。D-010のSupabaseの採用と、`docs/AUTHORITY.md` §5の`supabase.inspect_project`、`supabase.apply_migrations`に、Edge Functionのdeployの経路を加える。
- Context: Supabaseを採用した派生アプリ（発見元はiOS-CampPocket）の仕様には、写真の検証やアカウントの削除などserver側の処理があり、Edge Functionが要る。一方、`docs/AUTHORITY.md`のoperation allowlist、`tools/lib/issue-contract.rb`、`tools/provider-preflight.sh`、pre-merge gateのいずれにもEdge Functionのdeployのoperationがなく、Issue contractに書くと拒否される（#330）。2026-10-21、ユーザーが未決事項の6点を推奨どおりに決めた。
- Decision:
  - Supabaseを採用したアプリに、Edge Functionのremoteへのdeployを許可する。
  - operationの名前は`supabase.deploy_functions`とする。対象は`Config/ownership.yml`に設定済みのProject Refと、Issue contractに名前を列挙したfunctionだけとし、列挙していないfunctionや別のProjectへはdeployしない。
  - deployはIssueごとに毎回ユーザーの承認を要する（`Approval required: yes`）。Delivery profileは`strict`に限る。
  - functionが使う秘密の値は、ユーザーが`supabase secrets set`で設定する。AIは秘密の値を入力、表示、保存せず、Issue contractに列挙した秘密の名前が設定されているかどうかだけを確かめる。
  - migrationの適用（`supabase.apply_migrations`）とfunctionのdeployは、別のIssueで行う。1つのIssueのSupabaseのremote operationは1種類とし、pre-merge gateの証拠もIssueごとに1つとする。
  - `supabase/functions/<name>/`のfunctionごとに、localのtest（Supabase CLIまたはDenoで、remoteへ接続しないもの）を必須とする。testはrepository-test manifestの新しいdomainで選び、`supabase/functions/`の変更でそのdomainを選ぶ。
  - 後続のFeature Issueの分け方（このDecisionにまとめ、後続Issueは`specs/decisions.md`を変えない）:
    1. allowlistとIssue contract: `docs/AUTHORITY.md` §5への`supabase.deploy_functions`の追加、`tools/lib/issue-contract.rb`の`ALLOWED_OPERATIONS`、`Approval required: yes`と`strict`の強制、functionの名前と秘密の名前の列挙の検証、migrationとの同居の拒否。
    2. preflight: `tools/provider-preflight.sh`が、設定済みのProject Ref、列挙したfunctionの存在、秘密の名前の有無（値は読まない）を確かめ、Issue／Headに結び付いた証拠を出す。
    3. pre-merge gate: deployの証拠を、migrationの証拠と同じ形でIssueごとに1つ受け取る。
    4. skillとtest: supabase-ops skillのdeployの手順、`supabase/functions/`のmanifestのdomainと、functionごとのlocalのtestの規則。
- Consequence: Supabaseを採用したアプリは、承認のある`strict`のIssueで、列挙したfunctionだけを設定済みのProjectへdeployできる。秘密の値はユーザーの手元から出ない。実装は上の後続のFeature Issueで行い、それまでは今までどおりdeployのoperationは拒否される。
- Related Issue: #330
