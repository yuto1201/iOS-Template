# Authority boundary

この文書は、CodexとClaudeが実行できる操作と、使用を許可する外部アカウントの正本です。モデル名ではなく、設定済みアカウント、対象、Issue contract、ユーザー承認で権限を決めます。

## 1. 基本原則

- CodexとClaudeは同じ権限を持ち、どちらもローカル作業と認証済み外部操作を実行できる。
- 実装担当と外部操作実行者はIssueの`Executor`で明示し、実行モデルと一致させる。
- 評価エージェントは引き続きread-onlyで、外部操作、編集、commit、push、mergeを行わない。
- 外部操作は`Config/ownership.yml`の安定識別子と完全一致するアカウント／targetだけを使う。
- モデルが利用できる接続先や認証sessionを、許可済みと推測しない。
- 不一致、未設定、曖昧、検証不能は操作前に`blocked:ops`として停止する。

## 2. 設定済みアカウント

認可判定には、表示名や件数など変動する情報ではなく次の安定識別子を使います。

| Service | 設定済みidentity | 追加制約 |
| --- | --- | --- |
| GitHub | login `yuto1201` | 対象Repositoryのowner/name、既定Branch、Issue、Branch、Head SHAも一致させる |
| Supabase | Organization ID `kmjpkzaqlewqnypyqwkg` | Organization名は`yuto1201's Org`。Project Ref未設定中はProject操作を行わない |
| Cloudflare | Account ID `7ea8e713d76506f9e303f58624829aa5` | Account名`Yuto Dev`、plan `free`。deploy target未設定中はdeployしない |
| Linear | workspace slug `yuto33004` | URL `https://linear.app/yuto33004`、team key `YUT` |
| Vercel | Team ID `team_ANEUn6gVL8dccPaY08wkvxFt` | team slug `yuto16`、plan `hobby`。Project ID未設定中はdeployしない |
| ElevenLabs | 未設定 | Account IDとWorkspace IDが設定されるまで認証済み操作を行わない |
| App Store Connect | 未設定 | Team IDとアプリ固有Bundle IDが設定されるまで認証済み操作を行わない |

メールアドレス、表示名、role、public repository件数は補助的な観察情報であり、単独の認可predicateにしません。メールアドレスは公開Repositoryの設定へ保存せず、providerが必要とする場合だけ認証session内で確認します。

## 3. 操作マトリクス

| 操作 | Claude | Codex |
| --- | --- | --- |
| 仕様・コード・テストの読取と編集 | 可 | 可 |
| ローカルGit、Branch、worktree | 可 | 可 |
| Xcode Build、Test、Simulator、必要なXcode UI | 可 | 可 |
| 公開ドキュメントの調査 | 可 | 可 |
| `gh`、GitHub MCP・プラグイン、remote Git | 可。preflight必須 | 可。preflight必須 |
| Supabase、Cloudflare、Linear、Vercelの認証済み操作 | 可。preflight必須 | 可。preflight必須 |
| ElevenLabs生成API・CLI | 可。設定とentitlement確認必須 | 可。設定とentitlement確認必須 |
| App Store Connect、TestFlight、提出 | 可。設定、監査、承認必須 | 可。設定、監査、承認必須 |
| Keychainと専用秘密ディレクトリの利用 | 可。子process scope限定 | 可。子process scope限定 |
| PRのSquash Mergeとremote Branch削除 | 可。Issue指定時 | 可。Issue指定時 |
| 反対モデルレビュー | Codex実装時にread-only | Claude実装時にread-only |

公開Webページの閲覧は認証済み外部操作に含めません。ログイン、Token、Cookie、認証済みMCP／CLI／browser、変更を伴うAPIを使う時点で外部操作です。

## 4. 共通の外部操作手順

CodexとClaudeは同じ`external-ops`手順を使います。

1. live Issueとsealed contractを読み、operation、Service、Environment、Executor、Approval requiredを確認する。
2. Executorが実行モデルと一致することを確認する。
3. `Config/ownership.yml`から期待account／targetを取得する。
4. 操作直前に実sessionのaccount／target／healthを再取得し、case-sensitiveに照合する。
5. GitHubではRepository、Issue、Branch、Base、Head SHAを追加照合する。
6. 必要なユーザー承認と、現在Headに結び付いた検証・レビュー証拠を確認する。
7. 宣言された一操作だけを実行し、sanitized結果だけを保存する。
8. 成否が曖昧なmutationは別IDや別操作として自動再試行しない。

共有preflightは実行モデルを明示します。

```sh
tools/provider-preflight.sh --executor codex --issue 42 linear --target YUT
tools/provider-preflight.sh --executor claude --issue 42 vercel --target yuto16
```

preflight証拠には秘密値を含めず、Issue、executor、provider、account、target、environment、operation、health、timestamp、digestだけを保存します。

## 5. Operation allowlist

- GitHub: `github.read_issue`、`github.create_issue`、`github.update_issue`、`github.push_branch`、`github.create_pr`、`github.merge_pr`、`github.delete_branch`、`github.sync_labels`
- Supabase: `supabase.inspect_project`、`supabase.apply_migrations`
- Cloudflare: `cloudflare.inspect_account`、`cloudflare.deploy`
- Linear: `linear.inspect_workspace`
- Vercel: `vercel.inspect_team`
- ElevenLabs: `elevenlabs.process_media`。旧`elevenlabs.generate_audio`は新規Issueで使用しない
- App Store Connect: `appstore.inspect_app`、`appstore.upload_build`、`appstore.update_metadata`、`appstore.submit_review`

Linear／Vercelのmutation operationは、必要なworkflowとschemaを別Issueで追加するまでallowlistへ含めません。利用可能なconnectorが存在することだけではmutation権限になりません。

## 6. Provider別preflight

### GitHub

- active loginが`yuto1201`
- Repository owner/name、default Branch、Issue番号
- Push対象BranchとHead SHA、PRのHead SHA

### Supabase

- Organization IDが`kmjpkzaqlewqnypyqwkg`
- Project Ref、region、health、environment
- migrationとdry-run結果。Project Ref未設定中はremote Project操作を拒否

### Cloudflare

- Account IDが`7ea8e713d76506f9e303f58624829aa5`
- Account名`Yuto Dev`、plan `free`
- Zone／Worker／Pages projectと変更前状態。target未設定中はdeployを拒否
- Pro／Business前提の機能や課金変更は自動的に追加しない

### Linear

- workspace slug `yuto33004`、URL `https://linear.app/yuto33004`
- team key `YUT`
- user roleは補助確認とし、membership／role変更は別途ユーザー承認を要求

### Vercel

- Team ID `team_ANEUn6gVL8dccPaY08wkvxFt`、slug `yuto16`
- plan `hobby`
- Project ID、environment、deployment target。Project ID未設定中はdeployを拒否

### ElevenLabs

- Account ID、Workspace ID、認証状態、mode別entitlement
- source／referenceの権利、同意、保持方針、出力先

### App Store Connect

- Team、App、Bundle ID、version、build
- 提出準備か実提出か、法的文面とprivacy監査状態

## 7. ユーザー承認が必要な操作

通常のIssue運用、Push、PR、Squash Merge、Branch削除は、Issue contractで宣言されていれば追加承認不要です。次は別途ユーザー承認が必要です。

- 本番データの削除または不可逆変換
- 有料契約、課金、予算、価格、planの変更
- 新しい外部サービスへの登録
- App Storeへの初回公開または法的主張の確定
- ドメイン移管、DNSの広範囲な置換
- 権限、Team、Organization、workspace membership、roleの変更

## 8. 秘密と実行環境

- 秘密は`docs/security.md`に従い、実行直前にだけ取得する。
- Token、Cookie、private key、認証済みbrowser storageをGit、Issue、PR、prompt、log、artifactへ残さない。
- 一行secretは`tools/run-with-secret.sh`、file secretは`tools/run-with-private-key.sh`を使い、子processへだけ渡す。
- モデル固有の秘密アクセス拒否hookは置かない。両モデルへ同じaccount／target／approval／secret-handling gateを適用する。
- このMacで会社用または別個人アカウントへ接続されたproviderを検出した場合、モデルに関係なく操作を止め、正しいlocal sessionへ切り替えてから再preflightする。
