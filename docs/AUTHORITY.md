# Authority boundary

この文書は、CodexとClaudeが実行できる操作の正本です。利便性のために境界を緩めません。

## 1. 基本原則

本リポジトリは個人開発です。Claude側で利用可能なGitHub、Supabase、Cloudflareは会社用アカウントに紐づくため、このプロジェクトには使用しません。

- Claude: ローカルの実装・修正・検証担当
- Codex: ローカル作業に加え、個人アカウントを使う唯一の外部操作実行者
- 評価エージェント: read-only
- マージ実行者: 常にCodex

## 2. 操作マトリクス

| 操作 | Claude | Codex |
| --- | --- | --- |
| 仕様・コード・テストの読取と編集 | 可 | 可 |
| ローカル `git status`、`diff`、`add`、`commit` | 可 | 可 |
| ローカルBranchとworktree操作 | 可 | 可 |
| Xcode Build、Test、Simulator | 可 | 可 |
| Xcode UIのComputer Use | ローカルProject作成とSimulator操作に限り可 | 可。利用可能な場合 |
| 公開ドキュメントの調査 | 可 | 可 |
| `gh` とGitHub MCP・プラグイン | 不可 | 可 |
| `git push`、`fetch`、`pull`、remote変更 | 不可 | 可 |
| Supabaseリモート操作・MCP | 不可 | 可 |
| Cloudflareリモート操作・MCP | 不可 | 可 |
| ElevenLabs生成API・CLI | 不可 | 可 |
| App Store Connect、TestFlight、提出 | 不可 | 可 |
| Keychainからの個人用秘密取得 | 不可 | 可 |
| テンプレート専用秘密ディレクトリの読取 | 不可 | 可 |
| `codex` CLIの任意プロンプト実行 | 不可 | 可 |
| 固定ラッパーによるCodexへの外部操作委託 | 可 | 実行・判定 |
| 固定ラッパーによるCodex read-onlyレビュー | 可 | 評価 |
| 反対モデルレビュー | 可。Codex実装時 | 可。Claude実装時 |
| PRのSquash MergeとリモートBranch削除 | 不可 | 可 |

公開Webページの閲覧は外部操作に含めません。ログイン、Token、Cookie、MCP、CLI認証、変更を伴うAPIを使う時点で認証済み外部操作です。

ClaudeはXcodeのAccounts、Organizer、Signing team変更、Archive upload、App Store Connect操作をComputer Useで開いてはいけません。これらはCodexだけが実行します。

## 3. ClaudeからCodexへの委託

Claudeは認証済み外部操作が必要になったら、操作を試行せず `codex-external-ops` を使います。ClaudeはPrimary implementerになれますが、GitHub Issue状態と外部操作の実行者は常にCodexです。

委託のtransportは次に固定します。

1. Claudeが `.artifacts/ops-requests/${requestId}.json` を作る。
2. Claudeは `tools/request-codex-op.sh --request ${requestFile} --result ${resultFile}` だけを呼べる。
3. ラッパーがrequestをdescriptor-boundに固定し、canonical Issue contractのbytes/digest、`state.json`のbinding、個人GitHub preflight、current live Issue本文のexact reconstruction、操作詳細とConfig identityを照合する。
4. ラッパーはrequest digestごとのnonblocking lockを取得し、外部実行より先に `.artifacts/ops-receipts/${requestId}.json` を`in-flight`としてno-replaceで記録する。
5. Codexが権限、個人アカウント、対象を独立にpreflightし、固定requestだけを実行してsanitized result候補をstdoutへ1件だけ返す。
6. ラッパーがexact schema、requestとのidentity一致、秘密値・local path・control character不在を再検証し、`.artifacts/ops-results/${requestId}.json`をno-replaceで公開してreceiptを`completed`へCAS更新する。

Claudeによる直接の `codex` CLI、自由文prompt、別ラッパー、外部CLIは拒否します。read-only反対モデルレビューは別の `tools/request-codex-review.sh` を使い、外部操作権限を与えません。

依頼には次を含めます。

```json
{
  "requestVersion": 1,
  "requestId": "issue-42-create-pr-1",
  "issue": 42,
  "operation": "github.create_pr",
  "target": {
    "kind": "repository",
    "identifier": "yuto1201/example-ios-app"
  },
  "environment": "production",
  "expectedAccount": "yuto1201",
  "inputs": {
    "base": "main",
    "head": "claude/42-settings-screen"
  },
  "reason": "Issue 42 の検証と反対モデルレビューが完了したため"
}
```

依頼者は承認要否を指定できません。sealed contractの`Approval required`から導出します。現行transportにはrequesterが書けないCodex-owned approval receiptの発行・検証workflowがまだないため、`Approval required: yes`はIssue本文のreferenceだけでは承認済みとみなさず常に停止します。

Codexは実行結果を、秘密値を含まない次の形式で返します。

```json
{
  "status": "succeeded",
  "executor": "codex",
  "verifiedAccount": "yuto1201",
  "target": "yuto1201/example-ios-app",
  "operation": "github.create_pr",
  "resultReference": "https://github.com/yuto1201/example-ios-app/pull/57",
  "executedAt": "2026-08-21T12:00:00+09:00"
}
```

Codexが期待アカウントと実際のアカウントの不一致を検出した場合、操作せず `blocked:ops` を返します。

`expectedAccount`と`target.identifier`は`Config/ownership.yml`からproviderごとに完全一致で決まります。GitHubは`login`/Issue contractの`repository`、Supabaseは`organization`/`projectRef`、Cloudflareは`accountId`/`target`、ElevenLabsは`accountId`/`workspaceId`、App Store Connectは`teamId`/`bundleId`です。未設定値、別account、別targetはCodexを起動する前に拒否します。

同じ`requestId`と同じcanonical request digestでcompleted receiptがある場合、ラッパーは保存済みsanitized resultを返し、Codexやproviderを再実行しません。別digestで同じID、concurrent実行、`in-flight`のまま終了した曖昧な試行、resultだけの事前配置はfail closedです。固定promptはprovider idempotency keyを渡しますが、providerが対応しない場合まで外部side effectのuniversal exactly-onceを保証するものではありません。曖昧な試行を新しいIDや別操作として自動retryしません。

`operation` は次の完全一致allowlistから選びます。各操作の `target.kind` と `inputs` は実装時のJSON Schemaでさらに制限し、未知のfieldを拒否します。

- GitHub: `github.read_issue`、`github.create_issue`、`github.update_issue`、`github.push_branch`、`github.create_pr`、`github.merge_pr`、`github.delete_branch`、`github.sync_labels`
- Supabase: `supabase.inspect_project`、`supabase.apply_migrations`
- Cloudflare: `cloudflare.inspect_account`、`cloudflare.deploy`
- ElevenLabs: `elevenlabs.generate_audio`
- App Store Connect: `appstore.inspect_app`、`appstore.upload_build`、`appstore.update_metadata`、`appstore.submit_review`

共通の `target` は `kind` と、秘密でない一意な `identifier` を持ちます。結果の `target` は同じidentifierです。

## 4. Codexの外部操作前チェック

Identityの期待値は `Config/ownership.yml` を正本とします。GitHub login以外のアプリ固有Project Ref、Account ID、target、Workspace ID、Team ID、Bundle IDが未設定なら、対象操作を始めません。Provider preflightのaccount/targetは、Supabase=`organization`/`projectRef`、Cloudflare=`accountId`/`target`、ElevenLabs=`accountId`/`workspaceId`、App Store Connect=`teamId`/`bundleId`へcase-sensitiveに一致させます。

### GitHub

- アクティブアカウントが `Config/ownership.yml` の個人用loginであること
- 対象Repositoryのowner/nameと既定Branch
- Push対象BranchとHead SHA
- PR作成・マージ時のIssue番号

### Supabase

- `Config/ownership.yml` に記録された個人用Organization
- Project name、Project Ref、region、health
- local、preview、staging、productionのどの環境か
- 適用対象migrationとdry-run結果

### Cloudflare

- 個人用Account nameとAccount ID
- 対象Zone、domain、WorkerまたはPages project
- 変更前の状態

### ElevenLabs

- 個人用Account IDとWorkspace ID、および認証状態
- 実行する生成種別と契約上の利用可否
- 出力先がRepository内の許可された素材ディレクトリであること

### App Store Connect

- Team、App、Bundle ID、version、build
- 対象が提出準備か実提出か
- 法的文面とプライバシー申告の監査状態

## 5. ユーザー承認が必要な操作

通常のIssue運用、Push、PR、Squash Merge、Branch削除は承認済みの自動化範囲です。次は別途ユーザー承認が必要です。

- 本番データを削除または不可逆変換するDB操作
- 有料契約、課金、予算、価格を変更する操作
- 新しい外部サービスへの登録
- App Storeへの初回公開または法的主張の確定
- ドメイン移管、DNSの広範囲な置換
- 権限、Team、Organization membershipの変更

## 6. Claudeガード

`.claude/settings.json` の `PreToolUse` から `.claude/hooks/guard-external-ops.sh` を呼び、すべてのTool inputについて秘密パスを検査し、Bash、MCP、外部プラグイン、秘密取得を検査します。Bashでは実行ファイルの絶対パス、shell・interpreter・`env`・`xargs`・`find -exec`を介した間接実行、remote Gitのporcelainとplumbingも同じ境界として扱います。拒否時は、Codexへ委託すべき操作であることをClaudeへ返します。

Repository内のshell scriptをClaudeが起動するときは、物理パスがRepository内かつGit管理対象であることを確認し、参照する管理対象helperを有界・cycle-safeにたどって検査します。固定されたCodex依頼とread-onlyレビューの2ラッパーだけは、文書化された完全一致argvで直接起動できます。

このガードは同一macOSユーザー内の誤操作防止であり、OSレベルの完全な分離ではありません。完全分離が必要になった場合はClaude専用OSユーザーまたは隔離実行環境へ移行します。

公開資料調査のため、認証情報を伴わないWebアクセスは許可します。したがってこのガードはネットワーク隔離や情報流出防止境界ではありません。秘密値と会社／個人アカウントの混同防止が目的です。
