# Issue-to-merge workflow

## 1. 作業単位

- 1 Issue = 1 Branch = 1 PR
- Codex Branch: `codex/${issueNumber}-${slug}`
- Claude Branch: `claude/${issueNumber}-${slug}`
- Worktree: `.worktrees/${issueNumber}-${slug}`
- Base Branch: `main`
- Merge method: Squash

Primary implementerとExternal orchestratorはCodexまたはClaudeです。各認証済み外部操作はIssue contractの`Executor`へ実行モデルを明示し、`docs/AUTHORITY.md`の共通account／target preflightを通します。

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

[段階的開発仕様](../specs/development-stages.md)に従い、最初の操作可能な成果を`shape`、承認後の問題別改善を`harden`、完全検証を`release`へ分けます。一つのharden Issueへ無関係な品質項目を束ねません。変更の危険度、成熟段階、端末・言語範囲を別々に記載します。

## 3. Issue contract snapshot

新規Issue本文にはDelivery stageとVerification scopeを別々に記載します。Feature formの既定は`shape / 120 minutes / standard / iphone-ja`です。

```markdown
## Delivery stage

- Stage: shape
- Time budget: 120 minutes
- Reason: 主要導線を実画面で確認できる状態にする。

## Verification scope

- Scope: iphone-ja
- Reason: 日本語iPhone 1条件で主要導線をSmoke確認する。
```

shapeのVerification JSONは`iphone-ja`のSmoke Test 1件とBuild／重要Unit Test mappingを持ち、visual checkを持ちません。hardenは`targeted`なcanonical case部分集合、releaseは固定4件と全visual checkを持ちます。Stage／Time budget／Reason、Scope／Reasonの順序、未知値、重複、矛盾を共通producerで拒否します。App Store操作は`release / strict / full`だけに許可します。

Claim済みで`deliveryStage`を持たない旧snapshotへfieldを補完せず、従来のprofile／scope gateを維持します。新規Issueのstage省略は拒否します。理由・scope・stageのClaim後変更もlive再照合で拒否します。

選択された実行モデルはClaim時にGitHub Issueを読み、共通producerで`.artifacts/issues/${issueNumber}/issue-contract.json`へ次のsanitized snapshotを保存します。Bootstrapも同じproducerを使い、canonical contractを手書きで生成・縮小しません。

`type:feature`、`type:docs`、`type:release`は同じ基本contract schemaを使い、`type:regression`だけ`Original PR`と`Reproduction steps`を追加必須にします。4種類のうちexact 1 labelが必要で、複数または未知のtypeはClaimとGateで拒否します。

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
  "externalOperationDetailsDigest": "sha256:948c57dcd48bcede8fc5ad4707bd140ab260564f2c1960891e00959a4236c92c",
  "fetchedAt": "2026-08-21T12:00:00+09:00"
}
```

新規snapshotには、たとえば次を追加します。

```json
{
  "deliveryStage": {"name":"shape","timeBudgetMinutes":120,"reason":"主要導線を確認する。"},
  "deliveryProfile": {"name":"standard","reason":"通常UI変更。"},
  "verificationScope": {"name":"iphone-ja","reason":"代表的な日本語iPhone Smoke。"}
}
```

`externalOperations` は順序付きの操作ID配列です。`externalOperationDetailsDigest` はIssue本文の各五field blockを `operation`、`service`、`environment`、`executor`、`approvalRequired`、正規化したnullまたはstringの`approvalReference`へ変換し、同じ順序のcanonical JSONへ計算したSHA-256です。したがってIDが同じでもservice、environment、executor、承認条件または承認参照が変わればsnapshot bytesとdigestが変わります。

新規Issueは`Delivery profile`節へ`Profile`と`Reason`を記載し、snapshotへ次を追加します。

```json
{"deliveryProfile":{"name":"fast","reason":"Local non-UI logic covered by targeted tests."}}
```

`name`は`fast`、`standard`、`strict`だけを許可します。profile未導入の既存snapshotは`strict`です。`fast`はUI verificationが`Not applicable`で、追加承認やstrict対象operationがない場合だけ有効です。Supabase migration、Cloudflare deploy、メディア生成、App Store upload／metadata／submissionなどを低いprofileへ指定するとClaim前に拒否します。

検証、視覚評価、反対モデルレビュー、pre-merge gateは同じsnapshot pathとdigestを使用します。実行モデルがGitHubから取得して生成したsnapshotをローカル入力として読みます。Head SHAが変わってもIssue本文が変わらない限りsnapshotは再利用できます。Claimの再実行ではlive本文からの再生成bytesが既存契約と一致しなければ拒否し、古い契約・証拠を自動上書きしません。

application検証を実行するIssueは任意の`Verification`節へ、次の例のように完全なJSON objectを記載します。生のJSONまたは単一の`json` code fenceを使い、外側の`verification` wrapperは書きません。`tools/validate-issue-body.sh`とClaimが同じ`tools/lib/issue-contract.rb`で入力を検証し、canonical snapshotの`verification`へ格納します。Feature／Regression formにも入力欄があります。Configや環境変数から暗黙の既定値を補わず、このIssue本文だけを入力の正本とします。

許可するkeyは`bundleIdentifier`、`unitTestIdentifier`、scopeで定まるfixed 1件／targeted部分集合／fixed 4件の`cases`、受け入れ条件と同じ順の`acceptanceMappings`だけです。`shape`のcaseは操作を確認する`testIdentifier`を必須とします。各caseは`testIdentifier`またはexact `{"kind":"launch-succeeded"}`の一方だけを持ちます。

documentation-only Issueでは節を省略するか、`Not applicable`／GitHub空欄の`_No response_`にします。この場合、従来のsnapshot bytesに`verification`を追加しません。空のJSON、空節、部分設定を「省略」には読み替えません。`fast`へapplication Verificationを指定することも拒否します。application実行時のobject不在は、引き続きBuild前に失敗します。

`acceptanceMappings` は全 `AC-*` をexactに一度ずつ含め、各 `checks` は空でなく重複せず、次のcanonical順を守ります: `stage:build`、`stage:unit-tests`、4つの `case:<case-id>`、4つの `visual:<case-id>`。少なくとも1つのstageまたはcase checkが必要です。runnerは実行したstage/caseだけをdraftへ記録し、finalizeはAIが承認したvisual checkを加えたexact mappingをfinal evidenceへ記録します。未知または未実行の参照は許可しません。

````markdown
## Verification

```json
{
    "bundleIdentifier": "com.example.ExampleApp",
    "unitTestIdentifier": "ExampleAppTests/UnitSmokeTests/testUnit",
    "cases": [
      {"id": "iphone-en", "testIdentifier": "ExampleAppUITests/SmokeTests/testLaunch"},
      {"id": "iphone-ja", "assertion": {"kind": "launch-succeeded"}},
      {"id": "ipad-en", "testIdentifier": "ExampleAppUITests/SmokeTests/testLaunch"},
      {"id": "ipad-ja", "assertion": {"kind": "launch-succeeded"}}
    ],
    "acceptanceMappings": [
      {"id": "AC-1", "checks": ["stage:build", "stage:unit-tests", "case:iphone-en", "case:iphone-ja"]},
      {"id": "AC-2", "checks": ["case:ipad-en", "case:ipad-ja", "visual:iphone-en", "visual:iphone-ja", "visual:ipad-en", "visual:ipad-ja"]}
    ]
}
```
````

各ACのchecksは実際にそのACを確認するものだけを明示し、未指定のACへ全checkを自動割当しません。例のidentifierやmappingをそのまま根拠として使わず、実在TestとACへ置き換えます。Repository toolのACはapplication smokeだけでは証明できないため、§5.3のcanonical repository testとAC別mappingも必須です。live IssueのVerification／deliveryProfile改変検出は既存[Issue #29](https://github.com/yuto1201/iOS-Template/issues/29)で修正します。

このobjectはIssue contractのdigestへ含まれます。runnerは開始時にbytesをdescriptor-boundなsealed snapshotへ固定し、各caseとScreenshot/draftのno-replace publication境界でGit Head、tracked Head inventory/bytes/flags、canonical contract/matrixのexact bytes/digestを再照合します。trusted Git `ls-tree`/`cat-file blob`からcontained relative symlinkを含むprivate raw-Head source snapshotを構築してXcodeへ渡し、project pathをlength-prefixしたfull source digestを`build.sourceTree`、project subtree digestを`build.project`としてdraft/finalへ固定し、両者のproject path exact一致を要求します。Build productはprivate attemptへ再帰copyしてlength-prefixしたtree digestを固定し、各install直前に再検証します。Task 5はcanonical draftからdescriptor-bound `visual-packet.json`をno-replace生成し、primaryと追加stateを含む全PNGを順序、path、SHA-256、dimensionへ固定します。`visual-result.json`とfinal `visualEvaluation`はpacket exact bytesと全reviewed imageをattestし、finalizeとstandalone validatorはcurrent bytesまで再照合します。Screenshot/draft publicationはIssue/Head lock下のdurable journalからSIGKILL後のpartial transactionをrollbackし、complete transactionをidempotent successとして回収します。finalもexact既存bytesだけをidempotent successとします。CLI引数や環境変数でBundle ID、test identifier、assertionを差し替えません。

## 4. 状態機械

```text
proposed
  -> approved
  -> claimed
  -> in-progress
  -> verify-passed
  -> approved-for-merge              # fast only
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
| `verify-passed` | `approved-for-merge`（review不要のexplicit `fast`または非release `standard` shape／harden） |
| `review-requested` | `changes-requested`, `approved-for-merge`, `blocked:review` |
| `changes-requested` | `in-progress`, `blocked:user`, `paused` |
| `approved-for-merge` | `merged`, `in-progress`, `blocked:conflict`, `blocked:ops` |
| `merged` | `done` |
| 任意の`blocked:*` | 直前の非blocked状態、`paused`, `superseded` |
| `paused` | 停止前の状態、`superseded` |

`in-progress -> verify-passed` だけは、canonical Issue worktreeの現在値を明示する `tools/issue-state.sh transition ... --head-sha ${HEAD_SHA}` が必須です。遷移処理はdurable stateのBranch/worktreeとGit top-level/common directory、current Head、raw Branch refをGitHub mutation前、各remote step後、durable write直前に再照合し、一致したHeadを`state.json`へ保存します。Primary checkoutからHeadを推測しません。他の遷移で`--head-sha`は拒否します。

Head SHAが変わった場合、`verify-passed`、`changes-requested`、`approved-for-merge` から `in-progress` へ戻し、検証とレビューをやり直します。これらの遷移は古い`headSha`を削除し、次の`in-progress -> verify-passed`で明示した現在Headへ置き換えます。それ以降のforward遷移は同じ`headSha`を保持します。`done` と `superseded` は終端状態です。

各遷移commentには機械可読markerとして `from`、`to`、`resumeState`、executor、timestampを保存します。markerは `Config/ownership.yml` の個人GitHub loginが投稿したcommentだけを信頼し、comment author、marker timestamp、comment作成時刻、合法な遷移履歴を結び付けます。第三者または不正なmarkerを除外した最新の有効markerをtimestampで決定し、同時刻に複数の有効候補があれば推測せず失敗します。`blocked:*` または`paused`へ入るときの`resumeState`は遷移前状態です。復帰時は `issue-state.sh transition --from <current> --to <resumeState>` を明示実行してから `resume-issue.sh` でlocal stateを再構築します。`resume-issue.sh` 自体はlabelを変更しません。存在しない場合は推測せず`blocked:conflict`にします。ローカル`state.json`にも同じfieldsを保存し、失われた場合はGitHub commentから再構築します。

中断状態:

- `blocked:user`: 仕様または承認待ち
- `blocked:ops`: 外部認証、契約、API制限
- `blocked:review`: 反対モデルを利用できない
- `blocked:conflict`: 同一ファイルまたはBranchの競合
- `blocked:dependency`: 依存Issueが未完了
- `blocked:environment`: Xcode、Runtime、Simulator不足
- `blocked:repeated-failure`: 同一原因の2回連続失敗
- `paused`: ユーザーが明示的に停止
- `superseded`: 別Issueまたは決定に置き換えられた

状態はGitHub Issueのlabelとcommentを正本とします。ローカルの状態ファイルは再開を補助しますが、GitHubと矛盾する場合は実行モデルがGitHubを再確認します。

## 5. Issue実行フロー

### 5.1 Claim

1. 実行モデルがIssue読取の直前に設定済みGitHubアカウントとRepositoryを確認し、live Issue contractの`github.read_issue`宣言を検証する。
2. IssueのGoal、Scope、Acceptance criteria、Dependenciesを読む。
3. Definition of Readyを満たさなければ作業を開始しない。
4. 通常のshippingに必要な`github.read_issue`、`github.update_issue`、`github.push_branch`、`github.create_pr`、`github.merge_pr`、`github.delete_branch`がすべてlive Issue contractへ宣言されていることを確認し、`issue-contract.json` を作成してdigestを記録する。
5. Primary agentをIssueへ記録する。
6. Branch、worktree、共有artifact link、sealed contract、durable stateを順に作成してからremoteの`claimed` labelと所有者markerを公開する。各境界はjournalで再開可能にし、同じagentとexact contractだけが続行できる。

CodexとClaudeは同じ手順で1、4、5、6とGitHub上の状態変更を実行します。

### 5.2 Implement

1. 受け入れ条件に対応する失敗テストを作る。
2. 失敗を確認する。
3. 最小の実装を行う。
4. Unit Testを成功させる。
5. 小さな意味単位でcommitする。
6. Scope外の必要作業を発見したら、勝手に含めず追跡Issue候補へ記録する。

開発中は対象Test、関連回帰Test、stage標準検証の順で広げます。shapeのTime budgetを超えそうならScope縮小、harden分離、環境停止、または`blocked:user`を選び、品質項目を積み増しません。release完全検証は候補Headが安定してから一度実行します。

### 5.3 Verify

1. 非UI`fast`は`verify-fast-issue.sh`でBuildと指定Unit Testだけを実行する。
2. `shape`はBuild、重要Unit Test、`iphone-ja` 1条件のSmoke Testを実行し、Screenshot／visual reviewなしの`xcodebuild-stage`証拠を発行する。
3. `harden`は対象Test、関連回帰、宣言した`targeted` caseだけを実行する。visual checkを明示した場合だけ対象画像を評価する。
4. `release`は`full` 4条件、visual、accessibility、統合UI、同一Head evidenceを実行する。
5. IssueがRepository toolやworkflowを変更する場合、profileに関係なく全tracked repository testsをclean detached worktree上で実行する。
6. 同じHeadを明示して`in-progress -> verify-passed`へ遷移する。

canonical検証が失敗した場合、原因へ直接対応する対象Testが成功するまで要求scopeの検証を再実行しません。別Headのcanonical evidenceを作り続けることを進捗として扱いません。

### 5.4 Opposite-model review

- `fast`および`standard`の`shape`／`harden`: blocking reviewを行わず、`verify-passed -> approved-for-merge`へ進む
- Codex実装: Claudeへread-onlyレビューを依頼
- Claude実装: Codexへread-onlyレビューを依頼

`strict`または`release`のレビュー対象はIssue、仕様、Base SHA、Head SHA、Verify SHA、diff、テスト結果、要求画像です。レビュー結果が`changes-requested`なら対象確認からやり直します。

レビューのタイムアウトは10分です。利用不能時は `blocked:review` とし、独立Issueを進めます。自己承認はしません。

固定launcherはchild完了後にcanonical `review.json` と `review-receipt.json` をdescriptor-boundで対として発行します。receiptはprimary/opposite model、fixed launcher bytes、exact packet/result/review digest、開始/完了時刻、exit statusを固定します。既存reviewだけ、偽造または不一致receipt、自己承認は再利用しません。review publication後のstate transitionだけが失敗した場合は、exact review/receipt pairを検証した再実行だけがreviewerを再起動せず遷移を再開できます。

### 5.5 PR and merge

1. Issueで指定された実行モデルが設定済みGitHubアカウントを再確認する。
2. durable stateのrepository、Issue、Branch、worktree、Base、Head、contract digestと、callerの `--repo`、現在のGit branch/ref/Head/Base/clean状態を一致させる。
3. `tools/premerge-gate.sh --repo ${OWNER_REPO} --issue ${ISSUE_NUMBER} --head-sha ${HEAD_SHA}` を初回実行する。
4. approvedな固定snapshotからPR本文をrenderする。`changes-requested` は本文を生成せず拒否する。
5. exact HeadをBranchへPushし、PRを作成または既存OPEN PRを再確認して、正確なPR番号をdurable stateへ保存する。
6. `github.merge_pr` のaccount preflightを現在のIssue/Headに対して更新する。
7. `tools/premerge-gate.sh --repo ${OWNER_REPO} --issue ${ISSUE_NUMBER} --head-sha ${HEAD_SHA} --merge-pr ${PR_NUMBER}` を実行する。このfinal modeが全descriptor/lockを保持したままPR identityを再取得し、exact `gh pr merge --squash --match-head-commit` まで一続きで実行する。
8. Gate外でPR identityを再取得してmergeする経路は使わない。
9. PRのマージ状態とIssueのCloseを確認する。
10. remote Branch、worktree、local Branchの順に対象を再確認して後片付けする。

`gh pr merge --delete-branch` に後片付け全体を任せません。各対象を明示して、別worktreeやユーザーBranchを削除しないようにします。

認証済みmutationはIssue contractに同じoperation IDと実行モデルの`Executor`が宣言されている場合だけ実行します。Gateとmergeには`github.merge_pr`、Push直前には`github.push_branch`、新しいPRを作る経路だけ`github.create_pr`、remote Branch削除直前には`github.delete_branch`が必要です。新規PR経路では`github.create_pr`の欠落をPushより前にも検査し、必要宣言が一つでも欠ける場合は外部mutationをゼロのまま拒否します。既存の正確なPRを再利用する経路は`github.create_pr`を要求しません。

Squash Merge後は元Branch tipが`main`の祖先にならないため、`git branch --merged` を完了判定に使いません。実行モデルは対象PRの`state == MERGED`、`headRefOid`が記録済みHead SHAと一致すること、`mergeCommit`が存在することをGitHubから確認します。必要に応じてpatch-idでSquash commitとの差分同等性も確認します。

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

上の例はfull検証です。`iphone-ja`のrendererは日本語iPhoneだけを確認済みとし、英語・iPadを`deferred / unverified`として表示します。`None for this Issue`をアプリ全体の完成と解釈しません。出力や証拠を手で縮小せず、共通producerを使用します。

## 7. 再試行とRegression

- Pre-mergeで見つかった問題: 元Issueで修正
- Merge後または実機確認で見つかった問題: Regression Issue
- 同じ障害を重複起票しない
- Regression IssueからさらにRegression Issueを自動連鎖させない
- 同じ原因の失敗が2回続いたら状態をblockedへ移す

## 8. 止まらず進める範囲

一つのIssueがblockedでも、依存しないIssueは継続します。次の場合だけバッチ全体を止めます。

- 共通仕様の未決が全Issueへ影響する
- 個人GitHubアカウントを確認できない
- Base Branchの状態が壊れている
- Xcodeまたは必要Runtimeがなく全Issueを検証できない
- ユーザーが明示的に停止した

ソース編集Issueは、依存がなく編集ファイルが重ならない場合に最大2件まで並行化できます。Simulator検証は排他的に1件ずつ実行します。

## 9. Bootstrap

Foundation、Identity bootstrap、Simulator verificationの3件は、Issue自動化が未実装の段階を含むため選択された実行モデルが同じ手順を手動実行します。手動であってもIssue、Branch、PR、4条件Simulator、反対モデルレビュー、Head SHA照合、Squash Merge、Branch削除を省略しません。Identity bootstrapはFoundationの後、Feature実装より前に完了します。

Bootstrap IssueのPRには、各受け入れ条件IDと証拠、GitHub account preflightのsanitized要約、Verify対象SHA、Review対象SHAを記載します。Simulator verificationが入った後は`verify.json`を使用し、Security and workflowが入った後は全Issueを自動状態機械へ移行します。
