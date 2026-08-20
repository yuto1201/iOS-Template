# Issue-to-merge workflow

## 1. 作業単位

- 1 Issue = 1 Branch = 1 PR
- Codex Branch: `codex/<issue-number>-<slug>`
- Claude Branch: `claude/<issue-number>-<slug>`
- Worktree: `.worktrees/<issue-number>-<slug>`
- Base Branch: `main`
- Merge method: Squash

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

## 3. 状態機械

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

## 4. Issue実行フロー

### 4.1 Claim

1. Codexがアクティブな個人GitHubアカウントとRepositoryを確認する。
2. IssueのGoal、Scope、Acceptance criteria、Dependenciesを読む。
3. Definition of Readyを満たさなければ作業を開始しない。
4. Primary agentをIssueへ記録する。
5. Branchとworktreeを作成する。

### 4.2 Implement

1. 受け入れ条件に対応する失敗テストを作る。
2. 失敗を確認する。
3. 最小の実装を行う。
4. Unit Testを成功させる。
5. 小さな意味単位でcommitする。
6. Scope外の必要作業を発見したら、勝手に含めず追跡Issue候補へ記録する。

### 4.3 Verify

1. `ios-verify` がバッチ固定済みSimulatorマトリクスを読む。
2. Buildと対象Testを実行する。
3. iPhone ProとiPad Airを日英で操作する。
4. スクリーンショットと機械判定を保存する。
5. AIが見た目と受け入れ条件を評価する。
6. `verify.json` にHead SHAを記録する。

### 4.4 Opposite-model review

- Codex実装: Claudeへread-onlyレビューを依頼
- Claude実装: Codexへread-onlyレビューを依頼

レビュー対象はIssue、仕様、Base SHA、Head SHA、Verify SHA、diff、テスト結果、UI画像です。レビュー結果が `changes-requested` なら同じIssueで修正し、検証とレビューをやり直します。

レビューのタイムアウトは10分です。利用不能時は `blocked:review` とし、独立Issueを進めます。自己承認はしません。

### 4.5 PR and merge

1. Codexが個人GitHubアカウントを再確認する。
2. BranchをPushする。
3. PRを作成し、Issueを `Closes #<number>` で関連付ける。
4. `tools/premerge-gate.sh` を実行する。
5. 現在のHead SHAと検証・レビューSHAが一致することを確認する。
6. `gh pr merge --squash --match-head-commit <head-sha>` を実行する。
7. PRのマージ状態とIssueのCloseを確認する。
8. remote Branch、worktree、local Branchの順に対象を再確認して後片付けする。

`gh pr merge --delete-branch` に後片付け全体を任せません。各対象を明示して、別worktreeやユーザーBranchを削除しないようにします。

## 5. PR本文の必須項目

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

## 6. 再試行とRegression

- Pre-mergeで見つかった問題: 元Issueで修正
- Merge後または実機確認で見つかった問題: Regression Issue
- 同じ障害を重複起票しない
- Regression IssueからさらにRegression Issueを自動連鎖させない
- 同じ原因の失敗が3回続いたら状態をblockedへ移す

## 7. 止まらず進める範囲

一つのIssueがblockedでも、依存しないIssueは継続します。次の場合だけバッチ全体を止めます。

- 共通仕様の未決が全Issueへ影響する
- 個人GitHubアカウントを確認できない
- Base Branchの状態が壊れている
- Xcodeまたは必要Runtimeがなく全Issueを検証できない
- ユーザーが明示的に停止した

