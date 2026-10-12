---
name: ios-template-sync
description: Use when the user wants iOS-Template updates brought into a derived or existing iOS app — 「テンプレートを取り込む」「テンプレートを反映する」「テンプレートと同期する」「テンプレートの更新を入れて」 — either from inside the app's repository (entry 1) or from the template while naming the target repository (entry 2). Runs report, preflight, analyze, the user's approval, apply and verification as one template-sync Issue of the target (D-074, D-078). Not for changing the template itself or for reporting template bugs.
---

# iOS Template Sync

テンプレート（`yuto1201/iOS-Template`）の更新を、テンプレートから作ったアプリや、テンプレートを未適用のアプリへ取り込みます（D-074、D-078）。仕組みの正本はテンプレートの`docs/template-sync.md`です。このスキルはテンプレート専用で、正本はテンプレートの`.agents/user-skills/ios-template-sync/`にあり、取り込みでアプリへ持ち込みません。

## 入り口

- **入り口1**：開発中のアプリのリポジトリから、このMacのテンプレートのcheckout（`/Users/uesugiyuuto/Documents/Xcode/iOS-Template`）を参照して、そのアプリへ取り込みます。今いるリポジトリが取り込み先です。
- **入り口2**：テンプレートのリポジトリから、ユーザーが指定した取り込み先のリポジトリへ取り込みます。取り込み先が指定されていなければ、推測せずに聞きます。

どちらの入り口でも、手順とコマンドは同じです。

## 守ること

- **取り込み元**：テンプレートのcleanな`main`で、`origin/main`と一致するcommitだけを取り込みます。テンプレートで作業途中の変更は取り込みません。
- **テンプレートへ書き込まない**：取り込みのために、テンプレートへcommit、ブランチ、Issue、PR、ファイルを作りません。出力もテンプレートの中に置きません。テンプレートの不具合や改善に気づいたら、ユーザーが頼んだときだけ`report-template-issue`で報告します。
- **取り込み先の1つのIssue**：レポート、事前の判定、分析、承認、適用、検証、mergeを、取り込み先の1つのテンプレート同期Issueとして進めます（1 Issue = 1 Branch = 1 PR）。Issue、ブランチ、PRは取り込み先に作り、取り込み先の`AGENTS.md`と規則に従います。入り口2でも、取り込み先の`AGENTS.md`を読んでから進めます。
- **出力の置き場**：レポート、判定、分析、承認、作業用フォルダは、取り込み先とテンプレートの両方の外に置きます。
- **承認**：ユーザーが`plan.md`と`analysis.md`を読んで、計画のdigestを承認します。Codexの承認は、ユーザーがCodexを指定したときだけです。承認を推測しません。
- **計画を手で変えない**：`plan.json`と`plan.md`を書き換えません。直すときは、取り込み先を直してレポートから作り直し、承認を取り直します。

## 手順

### 1. 変数を決める

```sh
export LANG=en_US.UTF-8
TEMPLATE=/Users/uesugiyuuto/Documents/Xcode/iOS-Template
REPO=yuto1201/iOS-<Name>                               # 取り込み先のGitHubのリポジトリ
APP=/Users/uesugiyuuto/Documents/Xcode/iOS-<Name>      # 取り込み先の本体のcheckout（linked worktreeではない）
SYNC="$HOME/.ios-template-sync/iOS-<Name>/$(date -u +%Y%m%dT%H%M%SZ)"   # 両方のリポジトリの外
mkdir -p "$SYNC"
```

### 2. 取り込み元を確かめる

```sh
test "$(git -C "$TEMPLATE" symbolic-ref --short HEAD)" = main
test -z "$(git -C "$TEMPLATE" status --porcelain)"
TEMPLATE_COMMIT=$(git -C "$TEMPLATE" rev-parse HEAD)
test "$TEMPLATE_COMMIT" = "$(git -C "$TEMPLATE" ls-remote origin refs/heads/main | cut -f1)"
```

どれかが失敗したら取り込まず、テンプレートの状態をユーザーに伝えます。テンプレートのcheckoutを切り替えたり進めたりするのは、ユーザーが指示したときだけです。

### 3. 取り込み先を確かめる

- `git -C "$APP" remote get-url origin`が`$REPO`を指すことを確かめます。
- 取り込み先の`AGENTS.md`と、そこから参照される規則を読みます。Issue、Claim、検証、レビュー、mergeは、その規則で行います。
- 本体のcheckoutが`main`にいて、`origin/main`と一致することを確かめます。古ければ、取り込み先の規則に従って`main`を進めてから始めます。計画は、このHEADに結び付きます。

### 4. 差分レポート（`report`）

```sh
"$TEMPLATE/tools/template-sync.sh" report --app-root "$APP" --template-ref "$TEMPLATE_COMMIT" \
  --output-dir "$SYNC/report" --work-dir "$SYNC/work"
PLAN="$SYNC/report/plan.json"
APPROVAL="$SYNC/approval.json"
```

`plan.md`（ユーザーが読む）と`plan.json`（toolが読む）ができます。基準commitの記録がない取り込み先では、各ファイルをテンプレートの全履歴の版と1バイト単位で比べ、どれかの版と一致すれば安全な更新、どの版とも一致しなければ手で確認します（`provenance`、`nearest`、参考の`inferredBase`）。

### 5. ほかの作業中かと変更の大きさ（`preflight`）

```sh
"$TEMPLATE/tools/template-sync.sh" preflight --app-root "$APP" --repo "$REPO" \
  --plan "$PLAN" --output-dir "$SYNC/preflight"
```

- 同期Issueは、まだClaimしません。Claimした同期Issue、そのworktreeとブランチも、作業中に数えられるためです。
- `busy`（ほかの作業中）なら止めます。`preflight.md`の作業中の内容をユーザーに伝え、それが終わるまで待つことを勧めます。
- 並行して進めるなら、worktreeを分けて行えます。ただし、大きい変更（`large`）では並行をおすすめしないと、はっきり伝えます。並行するかは、ユーザーの明示の指示だけで決め、自分で決めません。指示があれば、Claimで分けたworktreeで進めます。
- `idle`で`large`なら進められますが、取り込みが終わるまで取り込み先でほかの作業を始めないことを勧めます。
- `gh`が読めずに止まった場合は、作業中ではないと扱わず、原因を伝えます。

### 6. 事前の分析（`analyze`）

```sh
"$TEMPLATE/tools/template-sync.sh" analyze --plan "$PLAN" --app-root "$APP" \
  --preflight "$SYNC/preflight/preflight.json" --output-dir "$SYNC/analysis" --work-dir "$SYNC/work"
```

`analysis.md`は、不足と更新、重複と名前の変更、アプリ独自の改造、先に必要な整理の4項目と、その要約です。重複の扱いと、アプリ独自の改造をどうするかは、ユーザーが決めます。

### 7. テンプレート同期Issueを作る

取り込み先の規則（Issueの形式、検証、Delivery stage、Executor、反対モデル）で、テンプレート同期Issueを作ります。まだClaimしません。4〜6節の結果は、このIssueに記録します。本文には少なくとも次を書きます。

- 取り込むテンプレートのcommit（`$TEMPLATE_COMMIT`）、計画のdigest、`preflight`の結果、変更の大きさとその理由
- 分析の「先に必要な整理」を、示された順のままIssueの最初の手順として
- 10節の検証を受け入れ条件として。取り込みの前と後で、アプリのBuildとUnit Testが同じように通ることを含めます。

### 8. 承認

`plan.md`と`analysis.md`をユーザーに見せ、同期Issueのコメントで計画のdigestを承認してもらいます。

```sh
"$TEMPLATE/tools/template-sync.sh" approve --plan "$PLAN" --approver user \
  --reference 'https://github.com/<owner>/<repo>/issues/<番号>#issuecomment-<ID>' --output "$APPROVAL"
```

ユーザーがCodexの確認を指定したときだけ、次を使います。`codex-review`は`gpt-6.1-sol`（reasoning effort `xhigh`）で、最大20分かかります（D-080）。

```sh
"$TEMPLATE/tools/template-sync.sh" codex-review --plan "$PLAN" \
  --user-request 'https://github.com/<owner>/<repo>/issues/<番号>#issuecomment-<ID>' \
  --output "$SYNC/codex-review.json"
"$TEMPLATE/tools/template-sync.sh" approve --plan "$PLAN" --approver codex \
  --review "$SYNC/codex-review.json" --output "$APPROVAL"
```

計画の承認は、`AGENTS.md`の文面（D-075）、その他の変更、反対モデルレビュー、mergeの承認にはなりません。

### 9. Claim、先に必要な整理、適用

1. 取り込み先の規則で同期IssueをClaimし、作業ブランチのcheckout（`WORKTREE`、例：`$APP/.worktrees/<番号>-<slug>`）を作ります。
2. 先に必要な整理があれば、分析の順に片付けてcommitします。
3. `WORKTREE`のHEADが計画の取り込み先のHEADと違う場合（2.でcommitした場合を含む）は、`--app-root "$WORKTREE"`で`report`と`analyze`を新しいフォルダ（例：`$SYNC/report-2`、`$SYNC/analysis-2`）へ作り直し（`analyze`に`--preflight`は付けません）、`PLAN`と`APPROVAL`を新しいパスにして、8節の承認を取り直します。`preflight`はClaimの前の1回だけです。Claimした同期Issueは、作業中に数えられるためです。
4. 適用します。

```sh
"$TEMPLATE/tools/template-sync.sh" apply --plan "$PLAN" --approval "$APPROVAL" \
  --app-root "$WORKTREE" --work-dir "$SYNC/work"
```

止まったら理由を直し、計画を作り直して承認を取り直します。手で確認するファイルは、同じIssueの中で一つずつ決めます（アプリの変更を残す、テンプレートに合わせる、両方を合わせる）。`AGENTS.md`を変えるときは、D-075に従って文面の承認を得ます。判断を次の取り込みへ後回しにしません。

### 10. 検証

取り込みIssueでは、次をすべて行います。実行していない検証を成功と報告しません。

- 取り込んだtoolとskillの、取り込み先のrepository test
- アプリのBuild
- 重要なUnit Test
- 日本語iPhoneのSmoke Test（取り込み先の専用iPhoneだけを使う）
- 取り込みの前（同期ブランチの最初のHEAD）と後で、BuildとUnit Testが同じように通ること
- 反対モデルの承認

### 11. PRとmerge

取り込み先の規則でPRを作ります。PRには、計画のdigest、承認の参照、適用の結果（書き込んだファイル、削除したファイル、追記した決定事項、手で判断したファイル）、検証の結果を書きます。反対モデルの承認の後に、取り込み先の規則でmergeします。

## このスキルのリンク

正本はテンプレートにあり、`~/.claude/skills/ios-template-sync`と`~/.codex/skills/ios-template-sync`は正本を指すリンクです。リンクはテンプレートのcheckoutで張ります。同じ名前のフォルダや別の場所を指すリンクがあれば、上書きせずに止まります。

```sh
/Users/uesugiyuuto/Documents/Xcode/iOS-Template/tools/link-user-skill.sh ios-template-sync
```
