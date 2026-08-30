# テンプレート構成

Status: 確定  
Version: 1.1
Date: 2026-08-30

## 1. 設計原則

- Xcode の標準構成から大きく離れない。
- 共通運用は厚く、アプリ固有コードは薄く保つ。
- ディレクトリは責務が発生した時点で追加し、空の抽象層を作らない。
- 仕様、運用、実行手順、生成証拠を混在させない。
- Codex と Claude の機能名は揃え、ネイティブ形式だけを分ける。

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

## 4. 仕様と運用の責務

| 場所 | 正本となる内容 |
| --- | --- |
| `specs/` | 目的、機能、技術設計、受け入れ条件、決定 |
| `docs/` | 作業手順、権限、セキュリティ、検証方法 |
| `.agents/skills/` | Codex と Claude が共有する反復可能な手続き |
| `.codex/agents/` | Codex のカスタムエージェント定義 |
| `.claude/agents/` | Claude のカスタムサブエージェント定義 |
| `tools/` | 人間とスキルの双方が呼べる決定論的スクリプト |
| `.artifacts/` | ローカル検証生成物。Git管理外 |
| GitHub Issue/PR | 作業状態、受け入れ条件、レビューと検証の永続的な要約 |

## 5. スキル構成

正本は `.agents/skills/${name}/SKILL.md` とします。`.claude/skills/${name}` は同じディレクトリへの相対シンボリックリンクにし、手作業による二重管理を避けます。

### Core

| スキル | 責務 |
| --- | --- |
| `spec-workflow` | 相談内容を確定・提案・未決へ分け、仕様と決定ログを更新する |
| `plan-issue-batch` | 指定された機能を依存関係付きIssue群へ分解する |
| `ship-issue` | 1 Issue を実装からSquash Mergeまで進める |
| `ship-issue-batch` | 独立Issueを安全に並行化し、依存Issueを順に進める |
| `ios-verify` | Build、Test、4条件のSimulator検証、証拠生成を行う |
| `cross-model-review` | 反対モデルへレビューを依頼し、Head SHA付き結果を保存する |
| `external-ops` | CodexとClaudeに共通のアカウント／target照合後、認証済み外部操作を実行する |
| `app-bootstrap` | 新規リポジトリのXcode・Swift・設定Identityを機能開発前に安全に初期化する |

### 条件付き

| スキル | 追加条件 |
| --- | --- |
| `supabase-ops` | アプリ仕様でSupabase使用を確定したとき |
| `ios-media-assets` | 音声、文字起こし、効果音、音声分離、音楽、画像または動画が受け入れ条件になったとき |
| `prepare-appstore-assets` | App Store 提出準備を開始するとき |
| `submit-appstore-release` | 提出情報が監査済みで、Codexが提出するとき |

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
- App Store Connect: TestFlight、提出、審査対応

認証済み操作はCodexとClaudeのどちらも実行できます。実行モデルに関係なく、Issue contractで指定されたoperation／Executorと`Config/ownership.yml`のアカウント／targetを完全一致で検証し、未設定または不一致なら操作しません。

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
