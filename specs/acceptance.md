# 受け入れ条件

Status: 確定  
Version: 1.3
Date: 2026-08-31

## 1. テンプレート完成条件

- [ ] 最小の SwiftUI アプリが iPhone と iPad で起動する。
- [ ] 新規リポジトリのIdentity bootstrapが、検証済み入力からXcode project、Target、Scheme、Module、Test、Bundle ID、設定を一貫して変換できる。
- [ ] Unit Test と UI Test のサンプルが実行できる。
- [ ] 日本語と英語を切り替えて主要画面を検証できる。
- [ ] `.agents/skills/` のCoreスキルをCodexとClaudeの双方から利用できる。
- [ ] `.codex/agents/` と `.claude/agents/` に同等責務の評価エージェントがある。
- [ ] CodexとClaudeが同じ外部操作権限を持ち、モデル固有の拒否経路が存在しない。
- [ ] 外部操作前チェックが実行モデル、設定済みアカウント、対象リソースを照合する。
- [ ] IssueからSquash Merge・Branch削除までのドライランテストが通る。
- [ ] 最新iPhone Proと最新iPad Airを日英で解決し、バッチ内で固定できる。
- [ ] Head SHAが異なる古い検証・レビューではpre-merge gateが失敗する。
- [ ] 秘密値が追跡ファイル、ログ、Issue/PR本文へ混入していない。
- [ ] `App Store/` に提出情報の構造と検証スクリプトがある。
- [ ] Supabaseと外部メディア処理を使わない初期アプリへ、それらのSDKや設定が入っていない。
- [ ] README、仕様、運用文書、スキル、ツール間のリンク検証が通る。

## 2. Issue Definition of Ready

次が揃うまでIssueを `in-progress` にしません。

- Goal が一文で定義されている。
- 対象内と対象外が分かれている。
- 検証可能な受け入れ条件がある。
- 関連仕様のパスと節が記載されている。
- 各受け入れ条件に `AC-1` から始まる安定したIDがある。
- 依存IssueとBlockerが記載されている。
- UI変更の場合、対象画面・状態、開発段階、今回確認する言語・端末、延期する範囲と仕上げIssueが記載されている。現行Issue formで必須の日英期待欄の扱いは[移行手順](development-stages.md#6-現行ツールからの移行)に従う。
- Delivery profileが`fast`、`standard`、`strict`のいずれかで、選定理由が記載されている。profile未導入の既存Issueは`strict`として扱う。
- 検証範囲は危険度とは独立して決める。通常機能開発は`iphone-ja`、仕上げ・リリースは`full`とする承認済み方針に従い、実行経路の対応状況を確認する。未指定の既存Issueは`full`。
- 外部サービスを使う場合、サービス、環境、CodexまたはClaudeの実行者が指定されている。
- 法的、課金、本番破壊操作を伴う場合、必要なユーザー承認が記載されている。
- Feature Issueでは、アプリ固有の`specs/product.md`と`specs/acceptance.md`がともに**確定**しており、Issueの受け入れ条件と矛盾しない。満たさない場合は`blocked:user`とし、Branch/worktree作成や実装を開始しない。

## 3. Issue Definition of Done

次をすべて満たしたIssueだけを完了とします。

1. 受け入れ条件を満たす実装がある。
2. profileが要求するBuildとTestが実行済みで成功している。
3. `standard`／`strict`のUI変更は、安定した最終候補HeadをIssueの検証範囲に対応するSimulatorマトリクスで確認済み。1条件経路の実装までは§4の現行4条件を維持する。
4. `standard`／`strict`のUI変更は、AIが要求された全スクリーンショットと操作結果を評価済み。延期した英語・iPadを成功と推測していない。
5. 検証証拠のCommit SHAが現在のHead SHAと一致する。
6. `standard`／`strict`は反対モデルがレビューし、未解決の重大指摘がない。`fast`はblocking reviewを要求しない。
7. reviewを要求するprofileでは、レビュー対象のHead SHAが現在のHead SHAと一致する。
8. PR本文にIssue、仕様、検証、レビューの要約がある。
9. Issueで指定された実行モデルがSquash Mergeした。
10. リモートBranch、ローカルBranch、worktreeを安全に後片付けした。
11. GitHub Issueが完了状態になっている。

ユーザーの実機確認は、このDefinition of Doneの後に行います。実機で問題が見つかった場合は、新しいRegression Issueとして扱います。

機能Issueの完了とアプリ全体のリリース準備完了は別である。日本語iPhoneの機能Issueでは、明示的に延期した英訳・iPad最適化を未完了ACへ戻さない。仕上げIssueへ集約してリリースIssueの依存にし、リリース候補Headでは4条件と提出要件を再確認する。詳細は[段階的開発仕様](development-stages.md#5-issueレビューリリースの扱い)を正とする。

## 3.1 Delivery profile

| Profile | 使用条件 | 完了ゲート |
| --- | --- | --- |
| `fast` | 非UI、ローカル、低リスク。ドメインロジック、局所的なデータ変換、文書、通常の保守 | 現在HeadのBuild、対象Unit Test、変更対象がworkflow toolならrepository test。4条件Simulator、画像評価、blocking reviewは不要 |
| `standard` | 通常の画面、操作、localization、accessibility変更 | 開発中は日本語iPhoneと対象Testを優先。安定した最終候補Headで要求範囲のSimulator、画像評価、反対モデルレビューを1回実行 |
| `strict` | 認証・認可、秘密、DB schema／migration、本番データ、破壊的操作、課金・plan、privacy・法務、App Store／TestFlight、署名、delivery gate自体 | 重要な失敗経路のTest、要求範囲のSimulator、反対モデルレビュー、必要なaccount／target preflightとユーザー承認。Foundation・Identity/bootstrap、delivery gate、リリースはfull |

`fast`はUI verificationが`Not applicable`の場合だけ選択できます。承認が必要な操作またはstrict対象operationを含むIssueへ`fast`／`standard`を指定した場合は実装開始前に拒否し、focused evidence発行時にもUI source、security／service import、migration、ownership、release、delivery gateの変更を検出して拒否します。GitHubのIssue、Branch、PR、Squash Mergeはprofileに関係なくaccount preflightとexact Head照合を維持します。

profile未導入の既存Issueは安全な移行のため`strict`です。

profileを下げることで日本語iPhone開発を実現しない。危険度の判定は維持し、端末・言語の範囲だけを[開発段階](development-stages.md#3-危険度と検証範囲は別に決める)に合わせる。現在のapplication検証は4条件固定であり、次節の移行境界を守る。

## 4. 標準Simulatorマトリクス

確定した目標は、通常機能開発の`iphone-ja`（下表の日本語iPhoneだけ）と、仕上げ・リリースの`full`（下表の4条件）の分離である。`iphone-ja`でのcanonical完了経路は[Issue #32](https://github.com/yuto1201/iOS-Template/issues/32)で実装する。対応前のツール・既存snapshotには下表の4条件を適用し、1条件を無理に通さない。

| Family | Device | Locale | Language |
| --- | --- | --- | --- |
| iPhone | 最新の利用可能なiPhone Pro。Pro Maxを除く | `en_US` | `en` |
| iPhone | 同上 | `ja_JP` | `ja` |
| iPad | 最新の利用可能なiPad Air | `en_US` | `en` |
| iPad | 同上 | `ja_JP` | `ja` |

「最新」はIssueバッチ開始時にインストール済みXcodeから解決し、バッチ中は固定します。条件に合うデバイスがなければ `blocked:environment` とし、黙って別モデルへ変更しません。

このmatrixは現行経路および`full`の定義であり、`standard`／`strict`の最終候補Headだけに使用します。`fast`では解決、起動、Screenshot取得を行いません。将来の1条件経路でも端末・Runtime・case集合を固定し、scope違いのmatrixや証拠を再利用しません。

## 5. 品質ゲート

- Build warningを新規に増やさない。
- 失敗テストを削除・Skipして成功扱いにしない。
- ユーザー向け文字列は最初からlocalization可能に管理し、日本語を機能開発で完成させる。新規文言の英訳・用語統一は仕上げで完成させ、既存英語リソースを削除・破壊しない。
- Dynamic Type、VoiceOverラベル、タップ領域、色コントラストを変更範囲に応じて確認する。
- 固定画面幅を前提にせず、iPad targetと可変レイアウトの土台を維持する。iPad専用の配置・余白・操作の最適化と横断確認は仕上げで行う。
- 日時・通貨・保存形式・認証・課金などの正しさは、UIの対応順序を理由に後送りしない。必要なlocaleのドメインTestも初期から行う。
- 秘密、個人情報、会社アカウント識別子を証拠へ含めない。
- 外部操作の成功は実行モデルが実応答から確認し、推測で記録しない。

## 6. 失敗と再試行

- 同じ原因の失敗が3回続いたら自動再試行を止める。
- レビュー不能は `blocked:review`。
- 外部認証・契約・レート制限は `blocked:ops`。
- Xcode、Runtime、Simulator不足は `blocked:environment`。
- 仕様判断不足は `blocked:user`。
- 依存Issue未完了は `blocked:dependency`。

Pre-mergeの失敗は同じIssueで修正します。マージ後に判明した不具合だけ、新しいRegression Issueを作ります。

完全な4条件検証が失敗した後は、同じ原因を再現する対象Testまたは局所確認が成功するまで完全検証を再実行しません。実装中の各commitでcanonical Simulator証拠を作らず、最終候補Headが安定してから一度だけ作ることを標準とします。

## 7. Bootstrap Issue

自動化ツール自身を作る最初の3件だけは、まだ存在しないツールを完了条件にできません。Foundation Issue、Identity bootstrap Issue、Simulator verification IssueをBootstrap Issueとし、Issueで選択された実行モデル（CodexまたはClaude）が次を手動で実行します。

- 設定済みGitHubアカウント確認、Issue、Branch、Push、PR、Squash Merge、後片付け
- Head SHAを明記したBuild・Test・4条件Simulator結果のPR記録
- 反対モデルのread-onlyレビューと、対象Head SHAのPR記録
- `--match-head-commit` によるSquash Merge

Bootstrapで免除されるのは、未実装の自動スクリプトを通すことだけです。Build、Test、標準Simulatorマトリクス、反対モデルレビュー、SHA一致は免除しません。Identity bootstrapは使い捨てのテンプレート生成リポジトリでも同じ検証を行います。Simulator verification Issueがマージされた後は検証ツールを使い、Security and workflow Issueがマージされた後は全自動ゲートを使います。
