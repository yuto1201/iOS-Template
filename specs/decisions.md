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
- Decision: Phase 6 `implementation`ごとに、Phase 5 passed full verification、source／target contractとphase record、release／revision／scope、source..target Git diff、candidate artifact／configuration／SDK／signing context、全changed pathのimpact／dependency／reasonを`.artifacts/issues/<issue>/<head>/evidence-applicability.json`へcanonical no-replaceで封印する。exact同一Head／contextかつ差分、unknown、missing dependency、scope拡張なしだけを`reuse`とし、Head／context／affected pathの変更を`targeted-reverify`、unknown／missing dependency／scope拡張を`expanded-verification`とする。後二者は判定後のtarget passed evidenceを必須とし、review packet、PR renderer、pre-merge、release/package preflightは同じrecordと元証拠をdescriptor-boundで再検証する。release-phase binding互換cutoffを`2026-09-14T00:00:00Z`とする。
- Consequence: config、signing、SDKを一律に影響なしとは扱わず、別candidate、旧review、改ざん、未検証をfail closedにできる。cutoff前のbindingなしPhase 5 contractは元bytesを変更せず`sourceLegacy: true`、`sourceRecord: null`のlegacy sourceとして参照できるが、target bindingとsource full proof／Git identityを必須とし、cutoff後のsourceにはPhase 5 bindingを要求する。Phase 6 bindingのないlegacy Issueは直接full `verify.json`経路を維持する。package、privacy、legal、公開権限、provider readbackなど提出固有checkは再利用せず毎回実行する。
- Related Issue: #86
