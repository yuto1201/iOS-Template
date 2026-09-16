---
name: report-template-issue
description: Use when a derived app reveals a reusable iOS-Template bug or improvement and the user wants it investigated, deduplicated, drafted, or reported to the explicit template repository.
---

# Report Template Issue

派生アプリで見つかった問題を、アプリ固有の要望と混同せず `yuto1201/iOS-Template` へ報告します。「この問題をテンプレート側に報告して」「アプリで直した共通処理をテンプレートにも反映したい」という自然言語、または `report-template-issue` の明示呼出しで使用します。発見は投稿許可ではありません。

## 固定境界

- `発見元repository` と `報告先repository` を最初に別々に記録します。このテンプレート由来と確認できた場合の報告先は明示的な `yuto1201/iOS-Template` です。
- 発見元の `origin`、repository名の置換、organizationの類似性から報告先を作りません。別テンプレート由来または由来不明なら、対象を推測しないで確認待ちまたはlocal draftにします。
- `upstream remote` やテンプレートのローカルcheckoutがなくても、許可済みGitHub readで報告先identityとcurrent templateを確認できます。ローカルcheckoutが必要なvalidationは、検証済み報告先の一時checkoutで行い、発見元を報告先として扱いません。
- このskillはIssue報告までを扱います。template修正、patch同期、cherry-pick、PR作成、merge、派生アプリへの反映は別Issueです。

## 必須フロー

### 1. 発見元の証拠を固定する

次をsanitizedなメモへ分けます。

- 問題と期待動作
- 再現手順または最小例
- 観測したOS、Xcode、device、localeなどの環境
- 発見元のrevisionと、分かる場合だけテンプレートの適用元revision
- 影響、回避策、派生アプリ側の既存修正
- 共通化すべき理由

適用元revisionが分からなければ `unknown` と書きます。観測事実と仮説を分離し、原因未確定の調査Issueを実装承認済みとして扱いません。秘密、個人情報、非公開の業務情報、認証情報、未加工ログは本文や添付へ入れません。発見元Issue、PR、commitは公開・共有可能な参照だけを使います。

### 2. 共通性とcurrent templateを判定する

次のいずれかへ根拠付きで分類します。

| 分類 | 判定 | 次の処理 |
| --- | --- | --- |
| `template-common` | current templateの共有skill、generator、workflow、Foundationにも再現する、または複数派生アプリへ影響する | 重複確認とdraftへ進む |
| `app-specific` | アプリ固有のproduct仕様、設定、asset、独自実装だけに依存する | template Issueを作らず発見元へ戻す |
| `environment-only` | 発見元machine、toolchain、外部serviceの一時状態だけに依存する | templateで再現／緩和できる証拠がなければ投稿しない |
| `unknown` | 共通性または原因をまだ区別できない | 観測事実中心の調査draftにし、実装承認を主張しない |

報告先のdefault branchと関連path／仕様／履歴をcurrent templateとして確認します。既に修正済みなら、修正revisionまたは既存Issueを示して `already-fixed` とし、新規Issueを作りません。発見元の古いsnapshotだけを現行不具合の証拠にしません。

### 3. open／closed双方の重複を確認する

許可済みの `github.read_issue` で、症状、期待動作、影響path、error語、関連機能を変えてopen／closed Issuesを検索し、候補の本文、comment、PR、解決内容まで読みます。

- 同じ問題または同じ改善が追跡済みなら既存IssueのURLを返し、重複作成しない。
- closed Issueは同名だけで再発を否定しない。修正範囲とcurrent templateを照合する。
- 既存Issueへの追加commentまたは本文更新は、現在の依頼とIssue contractが `github.update_issue` まで許可するときだけ行う。
- 類似していてもAcceptance criteriaや影響範囲が異なる場合は、関係と差分を新規draftに明記する。

### 4. 現行形式の本文を作る

報告先のcurrent default branchにあるIssue template、仕様、labels、validatorを正本にします。[`spec-workflow`](../spec-workflow/SKILL.md)で判断状態とSpec anchorsを確認し、実装可能な範囲へ進む場合は[`plan-issue-batch`](../plan-issue-batch/SKILL.md)のDoRを満たします。古い派生アプリ内のIssue形式をコピーしません。

本文には少なくとも次を含めます。

- Goal、In scope、Out of scope
- 検証可能で順序付きのAcceptance criteria
- 問題、期待動作、再現手順または最小例
- 環境、revision、影響、回避策または既存修正
- 共通化すべき理由とテンプレート側の対応範囲
- Spec anchors、Dependencies、UI verification
- Delivery stage、正のTime budget、Delivery profileと各Reason
- 必要なExternal operations、Executor、User approvals、expected write-set

UIを変えないworkflow-only Issueは現行契約どおり`UI verification`をexact `Not applicable`とし、必要なroute／repository-test scope宣言をAcceptance criteriaの先頭へ置きます。タイトルは用途に応じた`[Workflow]:`、`[Bug]:`等のASCII prefixを持たせ、安全なBranch slugを生成できるようにします。値、番号、仕様anchor、stage/profile、label、Executorを捏造しません。

同梱の[`templates/example-issue.md`](templates/example-issue.md)は構造例であり、実在不具合として投稿しません。draftを報告先のcurrent validatorで検証します。

```sh
tools/validate-issue-body.sh --type docs /path/to/draft.md
```

typeは実際の成果に合わせ、`feature`、`regression`、`docs`、`release`から選びます。current validatorまたは確定仕様を取得・実行できない場合は、検証済みとせず `local-draft-only` と不足条件を返します。

### 5. 投稿権限を検査して一度だけ作成する

認証済み操作は[`external-ops`](../external-ops/SKILL.md)を使います。作業元のlive／sealed Issue contractに `github.read_issue` と `github.create_issue`、実行モデルと一致する `Executor`、production環境、必要な承認があることを確認します。現在の依頼または継続中の明示承認が起票を含むなら同じ承認を再要求しませんが、単なる発見、調査、ローカル修正依頼を投稿許可へ拡張しません。

作成の直前に、実行中repositoryのcurrent Headを明示してaccount／target preflightを行います。

```sh
tools/github-account-preflight.sh \
  --repo yuto1201/iOS-Template \
  --issue "$SOURCE_ISSUE" \
  --intended-operation github.create_issue \
  --expected-head "$HEAD_SHA"
```

設定済みaccount、exact target、operation、Issue contractのいずれかを確認できない場合は投稿せず `local-draft-only` にします。labelの存在を確認し、検証済みtitle/bodyを一度だけ作成します。テスト目的の実GitHub Issueは作りません。

### 6. readbackと曖昧結果を処理する

成功応答だけで完了にしません。作成されたIssueの `repository、番号、URL、本文` とlabelsを `readback` し、要求した内容と一致することを確認します。結果を次の一つとして明示します。

- `newly-created`: 新規Issueを作成しreadback一致
- `existing-issue`: 同一の既存Issueを返した
- `already-fixed`: current templateで修正済み
- `local-draft-only`: 共通性、形式、権限、targetのいずれかが未確定

投稿応答がtimeout、切断、空出力などで曖昧なら、title、本文の識別可能な内容、作成時刻、account／targetでopen／closedを再検索します。exactな一件をreadbackできた場合だけそのIssueを返し、0件または複数候補なら `reconcile-before-retry` として停止します。無条件に再実行しないでください。

Issue作成は報告の完了です。テンプレート修正、PR、merge、派生アプリへの反映の実装完了とは報告しないでください。

## 合成シナリオ

| Input ID | 期待するroute／outcome |
| --- | --- |
| `new-common-problem` | 共通性、重複なし、権限ありなら`newly-created` |
| `duplicate-open-or-closed` | 内容を照合して`existing-issue`、新規作成なし |
| `fixed-in-current-template` | 修正根拠付き`already-fixed`、新規作成なし |
| `app-specific-problem` | 発見元へ戻し`local-draft-only` |
| `missing-upstream-remote` | fixed targetを検証して`continue-with-explicit-target` |
| `unknown-create-authority` | 本文を返して`local-draft-only` |
| `ambiguous-create-result` | 検索・readbackし、確定不能なら`reconcile-before-retry` |

この表は分岐契約です。合成テストは外部投稿を行わず、各入力が指定outcomeへ到達するための手順と停止条件を検査します。

## 既存派生アプリへの導入

新規派生アプリはテンプレートrepositoryに追跡されたこのskillをそのまま含みます。既存派生アプリへ後から導入する場合は、次を一組として扱い、一部だけをコピーしません。

- 正本 `.agents/skills/report-template-issue/` とrelative symlink `.claude/skills/report-template-issue`
- 依存する `plan-issue-batch`、`spec-workflow`、`external-ops` skills
- 現行の `tools/validate-issue-body.sh`、`tools/github-account-preflight.sh`、`Config/ownership.yml`
- 専用testと `Config/repository-tests.json` のdomain mapping

導入先に同名pathまたは独自変更がある場合は上書きせず、別Issueで差分を確認します。skill追加だけで既存アプリの仕様、認証、remote、Issue履歴を変更しません。
