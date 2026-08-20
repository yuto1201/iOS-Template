# Issue-to-merge workflow

## 1. 作業単位

- 1 Issue = 1 Branch = 1 PR
- Codex Branch: `codex/${issueNumber}-${slug}`
- Claude Branch: `claude/${issueNumber}-${slug}`
- Worktree: `.worktrees/${issueNumber}-${slug}`
- Base Branch: `main`
- Merge method: Squash

Primary implementerはCodexまたはClaudeです。Issue状態、GitHub remote、認証済み外部操作、マージを実行するExternal orchestratorは常にCodexです。Claude実装時は `docs/AUTHORITY.md` の固定transportでCodexへ委託します。

BranchはIssue作成後に作ります。Issue番号を推測して先にBranchを作りません。

## 2. Issueの塊

ユーザーは単一Issue、既存Issue群、または機能の塊を指定できます。機能の塊の場合、`plan-issue-batch` が次を行います。

1. 仕様の確定・提案・未決を分類する。
2. 受け入れ条件を変える未決があれば相談する。
3. 最小のレビュー可能単位へIssueを分ける。
4. 依存グラフを作る。
5. 同じファイルやXcode設定を触るIssueを直列化する。
6. 独立した文書、App Store文面、局所機能だけを並行化する。
7. 各IssueへDefinition of Readyを記載する。

Issue数を増やすこと自体を目的にしません。セットアップとその成果物が独立して価値を持たない場合、同じIssueへ含めます。

## 3. Issue contract snapshot

CodexはClaim時にGitHub Issueを読み、`.artifacts/issues/${issueNumber}/issue-contract.json` へ次のsanitized snapshotを保存します。Bootstrap IssueではCodexが同じ形式を手動生成します。

```json
{
  "schemaVersion": 1,
  "issue": 42,
  "repository": "yuto1201/example-ios-app",
  "goal": "通知時刻を変更できるようにする",
  "specAnchors": ["specs/features/settings.md#notification-time"],
  "acceptanceCriteria": [
    {"id": "AC-1", "text": "通知時刻を保存できる"},
    {"id": "AC-2", "text": "日本語と英語で時刻が表示される"}
  ],
  "dependencies": [],
  "externalOperations": ["github.push_branch", "github.create_pr", "github.merge_pr"],
  "fetchedAt": "2026-08-21T12:00:00+09:00"
}
```

検証、視覚評価、反対モデルレビュー、pre-merge gateは同じsnapshot pathとdigestを使用します。ClaudeはGitHubから取得せず、このCodex生成snapshotをローカル入力として読みます。Head SHAが変わってもIssue本文が変わらない限りsnapshotは再利用でき、Issue本文が変わった場合はCodexが再取得してdigestを更新します。

## 4. 状態機械

```text
proposed
  -> approved
  -> claimed
  -> in-progress
  -> verify-passed
  -> review-requested
  -> changes-requested -> in-progress
  -> approved-for-merge
  -> merged
  -> done
```

### 許可された遷移

| From | To |
| --- | --- |
| `proposed` | `approved`, `blocked:user`, `superseded` |
| `approved` | `claimed`, `blocked:dependency`, `paused`, `superseded` |
| `claimed` | `in-progress`, `blocked:conflict`, `paused` |
| `in-progress` | `verify-passed`, 任意の`blocked:*`, `paused` |
| `verify-passed` | `review-requested`, `in-progress`, `blocked:review` |
| `review-requested` | `changes-requested`, `approved-for-merge`, `blocked:review` |
| `changes-requested` | `in-progress`, `blocked:user`, `paused` |
| `approved-for-merge` | `merged`, `in-progress`, `blocked:conflict`, `blocked:ops` |
| `merged` | `done` |
| 任意の`blocked:*` | 直前の非blocked状態、`paused`, `superseded` |
| `paused` | 停止前の状態、`superseded` |

Head SHAが変わった場合、`verify-passed`、`review-requested`、`approved-for-merge` から `in-progress` へ戻し、検証とレビューをやり直します。`done` と `superseded` は終端状態です。

各遷移commentには機械可読markerとして `from`、`to`、`resumeState`、executor、timestampを保存します。`blocked:*` または`paused`へ入るときの`resumeState`は遷移前状態です。復帰時は最新markerの`resumeState`だけを使用し、存在しない場合は推測せず`blocked:conflict`にします。ローカル`state.json`にも同じfieldsを保存し、失われた場合はGitHub commentから再構築します。

中断状態:

- `blocked:user`: 仕様または承認待ち
- `blocked:ops`: 外部認証、契約、API制限
- `blocked:review`: 反対モデルを利用できない
- `blocked:conflict`: 同一ファイルまたはBranchの競合
- `blocked:dependency`: 依存Issueが未完了
- `blocked:environment`: Xcode、Runtime、Simulator不足
- `blocked:repeated-failure`: 同一原因の3回連続失敗
- `paused`: ユーザーが明示的に停止
- `superseded`: 別Issueまたは決定に置き換えられた

状態はGitHub Issueのlabelとcommentを正本とします。ローカルの状態ファイルは再開を補助しますが、GitHubと矛盾する場合はCodexがGitHubを再確認します。

## 5. Issue実行フロー

### 5.1 Claim

1. Codexがアクティブな個人GitHubアカウントとRepositoryを確認する。
2. IssueのGoal、Scope、Acceptance criteria、Dependenciesを読む。
3. Definition of Readyを満たさなければ作業を開始しない。
4. `issue-contract.json` を作成し、digestを記録する。
5. Primary agentをIssueへ記録する。
6. Branchとworktreeを作成する。

ClaudeがPrimary implementerの場合も、1、4、5、6とGitHub上の状態変更はCodexへ委託します。

### 5.2 Implement

1. 受け入れ条件に対応する失敗テストを作る。
2. 失敗を確認する。
3. 最小の実装を行う。
4. Unit Testを成功させる。
5. 小さな意味単位でcommitする。
6. Scope外の必要作業を発見したら、勝手に含めず追跡Issue候補へ記録する。

### 5.3 Verify

1. `ios-verify` がバッチ固定済みSimulatorマトリクスを読む。
2. Buildと対象Testを実行する。
3. iPhone ProとiPad Airを日英で操作する。
4. スクリーンショットと機械判定を保存する。
5. AIが見た目と受け入れ条件を評価する。
6. `verify.json` にHead SHAを記録する。

### 5.4 Opposite-model review

- Codex実装: Claudeへread-onlyレビューを依頼
- Claude実装: Codexへread-onlyレビューを依頼

レビュー対象はIssue、仕様、Base SHA、Head SHA、Verify SHA、diff、テスト結果、UI画像です。レビュー結果が `changes-requested` なら同じIssueで修正し、検証とレビューをやり直します。

レビューのタイムアウトは10分です。利用不能時は `blocked:review` とし、独立Issueを進めます。自己承認はしません。

### 5.5 PR and merge

1. Codexが個人GitHubアカウントを再確認する。
2. BranchをPushする。
3. PRを作成し、Issueを `Closes #${ISSUE_NUMBER}` で関連付ける。
4. `tools/premerge-gate.sh` を実行する。
5. 現在のHead SHAと検証・レビューSHAが一致することを確認する。
6. `gh pr merge --squash --match-head-commit ${HEAD_SHA}` を実行する。
7. PRのマージ状態とIssueのCloseを確認する。
8. remote Branch、worktree、local Branchの順に対象を再確認して後片付けする。

`gh pr merge --delete-branch` に後片付け全体を任せません。各対象を明示して、別worktreeやユーザーBranchを削除しないようにします。

Squash Merge後は元Branch tipが`main`の祖先にならないため、`git branch --merged` を完了判定に使いません。Codexは対象PRの`state == MERGED`、`headRefOid`が記録済みHead SHAと一致すること、`mergeCommit`が存在することをGitHubから確認します。必要に応じてpatch-idでSquash commitとの差分同等性も確認します。

## 6. PR本文の必須項目

```markdown
Closes #42

## Summary
- 設定画面に通知時刻の選択を追加

## Specification
- specs/features/settings.md §3

## Verification
- Head SHA: 0123456789abcdef0123456789abcdef01234567
- Unit tests: 24 passed
- UI matrix: iPhone Pro en/ja, iPad Air en/ja passed
- Evidence digest: 9f42c7...

## Opposite-model review
- Reviewer: Claude
- Reviewed SHA: 0123456789abcdef0123456789abcdef01234567
- Verdict: approved

## Remaining work
- None for this Issue
```

PR本文の要約が永続的な証拠です。巨大なBuild logや秘密を貼りません。

## 7. 再試行とRegression

- Pre-mergeで見つかった問題: 元Issueで修正
- Merge後または実機確認で見つかった問題: Regression Issue
- 同じ障害を重複起票しない
- Regression IssueからさらにRegression Issueを自動連鎖させない
- 同じ原因の失敗が3回続いたら状態をblockedへ移す

## 8. 止まらず進める範囲

一つのIssueがblockedでも、依存しないIssueは継続します。次の場合だけバッチ全体を止めます。

- 共通仕様の未決が全Issueへ影響する
- 個人GitHubアカウントを確認できない
- Base Branchの状態が壊れている
- Xcodeまたは必要Runtimeがなく全Issueを検証できない
- ユーザーが明示的に停止した

ソース編集Issueは、依存がなく編集ファイルが重ならない場合に最大2件まで並行化できます。Simulator検証は排他的に1件ずつ実行します。

## 9. Bootstrap

FoundationとSimulator verificationの2件は、Issue自動化が未実装のためCodexが同じ手順を手動実行します。手動であってもIssue、Branch、PR、4条件Simulator、反対モデルレビュー、Head SHA照合、Squash Merge、Branch削除を省略しません。

Bootstrap IssueのPRには、各受け入れ条件IDと証拠、GitHub account preflightのsanitized要約、Verify対象SHA、Review対象SHAを記載します。Simulator verificationが入った後は`verify.json`を使用し、Security and workflowが入った後は全Issueを自動状態機械へ移行します。
