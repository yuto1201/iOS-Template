# テンプレート同期：差分レポート、事前の判定と分析、承認、適用

テンプレート更新を、テンプレートから作ったリポジトリや、テンプレートを未適用のリポジトリへ取り込む仕組みです（D-074、D-078）。流れは次のとおりです。1から3は読み取りだけで行い、取り込み先へは何も書き込みません。

1. 差分レポートと適用計画を作る（3〜5節）。
2. 取り込み先がほかの作業中かと、変更の大きさを判定する（6節）。ほかの作業中なら止める。
3. 計画を分析する（7節）。
4. 適用計画の承認を得る（8節）。原則はユーザーが計画と分析を読んで承認し、ユーザーが指定したときだけCodexが計画を確認して承認する。
5. 承認後に、計画どおり取り込み先の作業ブランチへ適用する（9節）。

取り込みは、開発中のアプリから始める入り口と、テンプレートから取り込み先を指定する入り口のどちらからでも始められます。どちらの場合も、取り込み先の1つの「テンプレート同期Issue」として進めます（10節）。この手順は、スキル`ios-template-sync`にまとめています（11節）。

## 1. ファイルの所有区分

`tools/template-sync/ownership.json`が、テンプレートのtrackedファイルをすべて次のどれか一つへ分類します。exact pathの指定が優先し、なければ最も長く一致するprefixで決まります。

| 区分 | 意味 | 取り込み時の扱い |
| --- | --- | --- |
| `template` | テンプレートが持つもの（tool、skill、運用文書など） | 3者比較の結果に従って取り込む |
| `identity` | Identity bootstrapが書き換える文書 | 取り込み先のIdentityで変換してから比べ、取り込む |
| `app` | アプリが持つもの（アプリのソース、Xcode project、`App Store/`の原稿、product／acceptance仕様） | 取り込まない |
| `mixed` | テンプレートとアプリの内容が混ざるもの | 規則ごとに手で確認する |
| `template-only` | テンプレート専用（同期tool自身、テンプレート専用のスキル`.agents/user-skills/`とリンクのtool、過去の実装計画） | アプリへ持ち込まない |

`mixed`の規則は次のとおりです。

- `agents-md`（`AGENTS.md`）：変更する文面はD-075に従ってユーザーの承認を得て、`docs/agents-md-approvals.md`へ記録する。
- `agents-md-approvals`（`docs/agents-md-approvals.md`）：テンプレートの承認記録を末尾へ追記する。
- `decisions`（`specs/decisions.md`）：テンプレートの新しい`D-###`を末尾へ追記する。番号が衝突している取り込み先では、アプリ固有の決定事項を`specs/app-decisions.md`の`A-###`へ移すまで追記しない。
- `dedicated-simulators`（`Config/dedicated-simulators.json`）：取り込み先の表示名を前置した2台を保ち、テンプレート用の端末を指す変更を入れない。
- `ownership`（`Config/ownership.yml`）：アカウントと提出先はアプリの値を保つ。
- `repository-tests`（`Config/repository-tests.json`）：アプリが追加したtestを保つ。

`tools/template-sync.sh check`は、分類されないファイル、manifestに残った存在しないpath、何にも一致しないprefixがあると失敗します。Identity bootstrapの対象（`Config/template-identity.json`）と`identity`／`mixed`の変換指定が食い違っても失敗します。テンプレートに新しい最上位のファイルやフォルダを追加するときは、この分類も更新します。

## 2. 基準commitの記録

取り込み先は、どのテンプレートの版に基づくかを`Config/template-base.json`に記録します。

```json
{
  "baseCommit": "<テンプレートの40桁のcommit SHA>",
  "method": "created",
  "recordedAt": "2026-10-05T00:00:00Z",
  "schemaVersion": 1,
  "templateRepository": "yuto1201/iOS-Template"
}
```

- `method`は、テンプレートをコピーして作った場合（D-073）が`created`、既存のリポジトリへ後から取り込んだ場合が`adopted`です。
- 適用が終わったら、`baseCommit`を取り込んだテンプレートのcommitへ更新します。
- GitHubのテンプレート機能で作った既存の派生アプリには記録がありません。その場合、基準は不明として扱い、ファイルごとの出どころで判定します（4節）。

## 3. 差分レポートの作り方

テンプレートのcheckoutから実行します。取り込み元は、テンプレートのcleanな`main`で`origin/main`と一致するcommitだけです（D-078）。テンプレートで作業途中の変更は取り込みません。

```sh
tools/template-sync.sh report --app-root /path/to/app --template-ref <確かめたテンプレートのcommit> \
  --output-dir /path/outside/app/sync-report --work-dir /path/outside/app/sync-work
```

- `--template-ref`で比べるテンプレートのcommitを指定できます（既定は`HEAD`）。比べるのは、commit済みの内容です。
- 取り込み先は、HEADのcommitをGitのobjectから読みます。作業tree、index、`.git`の設定は変更しません。作業中の変更がある場合は、その旨をレポートに書きます。
- `--output-dir`は、存在しない新しいフォルダで、取り込み先の外に置く必要があります。テンプレートのcheckoutの中にも置きません。
- `--work-dir`を指定すると、テンプレートの展開と変換の結果を再利用します。

## 4. 判定の区分

基準commitが分かる場合は、基準、テンプレートの最新、取り込み先の3つを比べます。

| 区分 | 条件 | 計画での扱い |
| --- | --- | --- |
| 足りない（`missing`） | 取り込み先にない | 追加 |
| 安全に更新できる（`safe-update`） | 取り込み先は基準のままで、テンプレート側だけが変わった。基準が分からない場合は、取り込み先がテンプレートのどれかの版と1バイトも違わない | 更新 |
| 衝突する（`conflict`） | 両方が変わった。基準が分からない場合は、取り込み先がテンプレートのどの版とも一致しない | 手で確認する |
| アプリ側だけの変更（`app-only-change`） | テンプレート側は基準のまま | 上書きしない |
| テンプレートで削除された（`deleted-in-template`） | 基準にあり、最新にない | 取り込み先が基準のままなら削除、変更があれば手で確認する |
| 一致（`up-to-date`） | テンプレートと同じ | なし |

テンプレートで削除されたファイルは、基準の版の`tools/template-sync/ownership.json`で区分を決めます。最新の版でmanifestの記載が消えていても、基準の版で`app`だったファイルを削除の対象にしません。基準の版にmanifestがない、またはそのファイルを分類できない場合は、区分を`unknown`とし、削除せずに手で確認します。

比べるのは、Gitに記録された内容と種類（通常のファイル、実行可能なファイル、symlink、submodule）の両方です。実行権限だけの変更も変更として扱います。テンプレートのファイルを置く場所に、取り込み先では同じ名前のフォルダやsubmoduleがある場合や、親のパスがファイルである場合は、`conflict`として手で確認します。

`identity`と、変換指定のある`mixed`のファイルは、そのテンプレートのcommitに含まれる`tools/bootstrap-app.swift`で、取り込み先の`Config/app-identity.json`のIdentityを再適用してから比べます。変換後も`TemplateApp`などの元の名前が増える場合は、更新せずに手で確認する扱いにします。取り込み先にIdentityがない場合や変換に失敗した場合も、これらのファイルは手で確認します。

### 基準が分からない場合：ファイルごとの出どころ（D-078）

基準commitが記録されていない、または記録が不正な場合は、ファイルごとの出どころで判定し、レポートの冒頭に基準が不明であることを書きます。

- テンプレートの最新の版と違う`template`、`identity`、`mixed`のファイルを、テンプレートの全履歴（比べるcommitまで）にある同じパスの全版と、内容とfile modeの両方で比べます。`identity`と、変換指定のある`mixed`のファイルは、各版にもそのcommitの`tools/bootstrap-app.swift`で取り込み先のIdentityを再適用してから比べます。
- どれかの版と1バイトも違わずに一致すれば、取り込み先はその版を改造せずに使っているとして、その版を基準に判定します。テンプレート側だけが変わったことになるので、最新の版への更新は`safe-update`です。一致した版を、計画のファイルの`provenance`（`commit`と`method: exact`）に記録します。同じ内容が履歴に何度か現れる場合は、その内容を最後に入れたcommitです。
- どの版とも一致しなければ、アプリ側で変えたものとして`conflict`（手で確認する）にし、最も近い版を`nearest`（`commit`と、変わった行の数`changedLines`）として添えます。file modeだけが違う場合、変わった行の数は0です。比べられる版がなければ`nearest`は`null`です。
- アプリのファイルが最も多く一致するcommitを、推定の基準`inferredBase`（`commit`と`matchedFiles`）として示します。参考の情報で、判定には使いません。一致するファイルがなければ`null`です。
- 取り込み先にないファイルは`missing`として追加します。基準がないため、テンプレートで削除されたファイルは判定しません。名前が変わって古い名前が残っているものは、事前の分析（7節）が示します。

基準commitが記録されている取り込み先は、これまでどおり3者比較で判定し（D-074）、`provenance`、`nearest`、`inferredBase`を持ちません。

## 5. 出力

`--output-dir`に次の2つを書きます。

- `plan.md`：ユーザーが読む日本語の計画です。適用する変更、追記する決定事項、上書きしないファイル、手で確認するファイル、決定事項の番号の衝突、専用Simulator、`Config/app-identity.json`の形式の違い、必要な承認を並べます。基準が分からない場合は、冒頭に推定の基準を、更新するファイルに一致した版を、手で確認するファイルに最も近い版との違いを示します。
- `plan.json`：適用toolが読む計画です。ファイルごとに区分、判定、扱い、理由と、テンプレート最新・基準・取り込み先それぞれのSHA-256を持ちます。基準が分からない場合は、ファイルごとの`provenance`または`nearest`と、`inferredBase`も持ちます（4節）。`decisions.append`は、`specs/decisions.md`の末尾へ追記する`D-###`です。番号が衝突している場合と、取り込み先に`specs/decisions.md`がない場合は空です。承認は、このファイルのdigest（実行結果の`planDigest`）に結び付けます。

## 6. ほかの作業中かと変更の大きさ（preflight）

取り込みを始める前に、取り込み先がほかの作業中かと、計画の変更の大きさを判定します（D-078）。`gh`と`git`の読み取りだけで行い、取り込み先とGitHubへ何も書き込みません。

```sh
tools/template-sync.sh preflight --app-root /path/to/app --repo <owner>/<repo> \
  --plan /path/outside/app/sync-report/plan.json --output-dir /path/outside/app/sync-preflight
```

- `--app-root`は取り込み先の本体のcheckoutです。linked worktreeは受け付けません。`--repo`は取り込み先のGitHubのリポジトリです。
- ほかの作業中（`busy`）：作業中の状態（`state:claimed`、`state:in-progress`、`state:verify-passed`、`state:review-requested`、`state:changes-requested`、`state:approved-for-merge`、`state:paused`、`blocked:*`）のIssue、開いているPR、本体以外のworktree、`main`以外のブランチにいるか未commitの変更がある本体のcheckoutのどれかがあれば`busy`、どれもなければ`idle`です。未追跡のファイルは一覧に出しますが、数えません。テンプレート同期Issueも、Claimすると作業中に数えられるので、この判定はClaimの前に行います。
- 変更の大きさ（`large`）：基準commitが記録されていない、書き込むファイルが30を超える、手で確認するファイルが10を超える、共有の設定（`mixed`のファイルと決定事項の追記）に触れる、決定事項の番号が衝突している、取り込み先のIdentityが使えない、のどれかに当たれば`large`とし、当たった理由を並べます。それ以外は`normal`です。
- `gh`が失敗した、60秒以内に答えない、答えを読めない場合は、判定できないとして止まり、`idle`とは報告しません。
- 出力は`preflight.json`（toolが読む）と`preflight.md`（ユーザーが読む）です。

`busy`なら取り込みを始めず、作業中の内容をユーザーに伝えて、終わるまで待つことを勧めます。並行して進めるならworktreeを分けて行えますが、大きい変更では並行をおすすめしません。並行するかは、ユーザーの明示の指示だけで決めます。この判定は並行するかを決めません。

## 7. 事前の分析（analyze）

計画を承認する前に、テンプレートの履歴（計画のcommitまで）、計画、取り込み先のHEADのGitのobjectを読み、取り込み先へ何も書き込まずに計画を分析します（D-078）。

```sh
tools/template-sync.sh analyze --plan /path/outside/app/sync-report/plan.json --app-root /path/to/app \
  --preflight /path/outside/app/sync-preflight/preflight.json --output-dir /path/outside/app/sync-analysis
```

- 計画は、取り込み先の今のHEADで作ったものに限ります。`--preflight`は、同じ計画と同じHEADの判定だけを受け付け、その変更の大きさを使います。指定しなければ、計画から同じ規則で求めます。`--work-dir`も指定できます。
- 出力は`analysis.md`（ユーザーが読む日本語）と`analysis.json`（toolが読む）で、`--output-dir`は取り込み先の外の新しいフォルダです。冒頭に、書き込むファイルの数、手で確認する数、名前の変更の組の数、重複の可能性の数、先に必要な整理、大きい変更かどうかとその理由を要約します。分析だけが見つける先に必要な整理（Identityの形式の違い、専用Simulatorの宣言、取り込み先のtoolの更新）があれば、大きい変更とします。

分析は次の4項目です。

1. 不足と更新：足りないファイルと古い版のままのファイルに、今の版を入れたテンプレートのcommit、その件名にあるIssueとPRの番号、関係する決定事項を添えます。
2. 重複と名前の変更：テンプレートの履歴で名前が変わり、古い名前が取り込み先に残っているものを、古い方の削除と新しい方の追加の1組として示します。取り込み先だけにあるファイルのうち、テンプレートのファイルと同じ名前のものと、中身が似ているもの（前後の空白を除いた行の集合のJaccard係数が0.6以上）を、重複の可能性として示します。扱いはユーザーが決めます。
3. アプリ独自の改造：計画の「衝突する」ファイルについて、比べた版との違いの要約、候補（アプリの変更を残す、テンプレートに合わせる、両方を合わせる）、テンプレートへ戻す価値の所見の候補を示します。テンプレートへの報告は、ユーザーが頼んだときだけ`report-template-issue`で行います。
4. 先に必要な整理：Identityの未設定や形式の違い、決定事項の番号の衝突、専用Simulatorの宣言、基準commitの記録、取り込み先のtoolの更新を、片付ける順に示します。テンプレート同期Issueの最初の手順として、この順に片付けます。取り込み先のファイルを変えたら、レポートと計画を作り直し、分析をやり直します。

## 8. 承認

承認は、`plan.json`のdigestに結び付けた記録（`approval.json`）です。`plan.json`が1byteでも変わると、その承認は使えません。`plan.md`は、`plan.json`から作り直した内容と一致する必要があります。どちらかを手で変えた計画は、承認も適用もできません。承認の記録は、取り込み先の外に置きます。

### ユーザーの承認（原則）

ユーザーが`plan.md`と`analysis.md`を読んで承認したら、承認を書いたIssueコメントのURLを参照として記録します。

```sh
tools/template-sync.sh approve --plan /path/outside/app/sync-report/plan.json --approver user \
  --reference 'https://github.com/<owner>/<repo>/issues/<番号>#issuecomment-<ID>' \
  --output /path/outside/app/sync-report/approval.json
```

### Codexの承認（ユーザーが指定したときだけ）

ユーザーがCodexに計画の確認を任せると指定したときだけ使います。指定したコメントのURLを`--user-request`に渡します。

```sh
tools/template-sync.sh codex-review --plan /path/outside/app/sync-report/plan.json \
  --user-request 'https://github.com/<owner>/<repo>/issues/<番号>#issuecomment-<ID>' \
  --output /path/outside/app/sync-report/codex-review.json
tools/template-sync.sh approve --plan /path/outside/app/sync-report/plan.json --approver codex \
  --review /path/outside/app/sync-report/codex-review.json \
  --output /path/outside/app/sync-report/approval.json
```

- `codex-review`は、固定のlauncher（`tools/template-sync-codex-review.sh`）でCodex（`gpt-6.1-sol`、reasoning effort `xhigh`、D-080）を起動します。Codexが読めるのは、一時フォルダへ写した`plan.json`と`plan.md`だけです。network、MCP、plugin、web検索、ファイルの書き込みは使えません。20分で止めます。
- Codexの答えは、`approved`と空の指摘か、`changes-requested`と1件以上の指摘（`path`と`problem`）のどちらかです。それ以外の答えは記録しません。`changes-requested`の記録からは承認を作れません。
- 確認の記録は、計画のdigest、ユーザーの指定のURL、launcherのdigest、modelを持ちます。承認と適用のときに、launcherが今のテンプレートのものと同じかを確かめます。
- Codexの承認は、その計画の適用だけに使います。`AGENTS.md`の変更文面（D-075）、その他の変更、外部操作、反対モデルレビュー、mergeの承認にはなりません。確認の記録そのもの（`codex-review.json`）は承認として使えません。

## 9. 適用

```sh
tools/template-sync.sh apply --plan /path/outside/app/sync-report/plan.json \
  --approval /path/outside/app/sync-report/approval.json --app-root /path/to/app
```

適用toolは、次のどれかに当たると、取り込み先へ何も書き込まずに止まります。

- 承認がない、承認の形式が違う、承認が別の計画（digest）のものである。
- 取り込み先のHEADが、計画を作ったときと違う。
- 取り込み先が`main`（または`master`、`origin`の既定ブランチ）にいる、またはブランチにいない。
- 取り込み先に作業中の変更（未commitの変更、untrackedファイル）がある。
- 計画とその承認が、取り込み先の中にある。
- 同じテンプレートのcommitと取り込み先から作り直した計画が、承認された`plan.json`と1byteでも違う。手で書き換えた計画は、承認があっても適用しません。
- 取り込み先にIdentity（`Config/app-identity.json`）がない。テンプレートを未適用のリポジトリでは、先にIdentityを決めてから計画を作り直します。
- `specs/decisions.md`の番号がテンプレートと衝突している。アプリ固有の決定事項を`specs/app-decisions.md`の`A-###`へ移してから、計画を作り直します。
- 専用Simulatorの宣言が、取り込み先の表示名を前置した2台ではない、またはテンプレート用の端末を指している。
- 追加するパスや、記録がない取り込み先の`Config/template-base.json`に、ignoredやuntrackedのファイルが既にある。更新や削除するファイルが、計画を作ったときの内容と違う。親のパスがsymlinkやファイルである。

止まらなければ、次だけを書き込みます。各ファイルは、同じフォルダに新しいランダムな名前で作った一時ファイルを置き換える形で書き、ほかの既存のファイルを消しません。indexは変えないので、結果は`git status`と`git diff`で確かめます。

- 計画で`add`、`update`、`delete`のファイル。区分が`template`か`identity`のものだけです。削除するファイルの区分は、差分レポートと同じく基準の版の`tools/template-sync/ownership.json`で決めます。`identity`のファイルは、取り込み先のIdentityで変換した内容を書きます。実行権限とsymlinkも計画どおりにします。
- `decisions.append`の`D-###`。テンプレートの`specs/decisions.md`の節を、番号を変えずに取り込み先の末尾へ追記します。
- `Config/template-base.json`。`baseCommit`を取り込んだテンプレートのcommitへ、`recordedAt`を適用の時刻へ更新します。記録がない、または記録が不正だった取り込み先では、`method`を`adopted`にします。

書き込んだ後に、次を検査します。どれかが失敗したら、書き込み済みの変更を`git status`で確かめて、`git restore`などで戻します。

- 書いた内容が、計画のSHA-256と実行権限に一致する。
- Identity変換したファイルの元の名前（`TemplateApp`、`com.yuto.TemplateApp`）が、適用前より増えていない。
- `specs/decisions.md`の既存の内容が変わっていない。
- 専用Simulatorの宣言が、取り込み先の表示名を前置した2台のままで、テンプレート用の端末を指していない。

上書きしないファイル、手で確認するファイル、`mixed`のファイル（`AGENTS.md`、`Config/dedicated-simulators.json`、`specs/decisions.md`の追記以外の変更など）は書き込みません。

## 10. 入り口とテンプレート同期Issueの進め方

取り込みには2つの入り口があります（D-078）。

- 入り口1：開発中のアプリのリポジトリから、このMacのテンプレートのcheckout（`/Users/uesugiyuuto/Documents/Xcode/iOS-Template`）を参照して、そのアプリへ取り込みます。
- 入り口2：テンプレートのリポジトリから、取り込み先のアプリのリポジトリを指定して取り込みます。

どちらの入り口でも、toolはテンプレートのcheckoutから実行し、Issue、ブランチ、PRは取り込み先に作って、取り込み先の`AGENTS.md`と規則に従います。テンプレートのリポジトリには書き込みません。取り込み元は、テンプレートのcleanな`main`で`origin/main`と一致するcommitだけです。

取り込み先のリポジトリで、テンプレートの取り込みを1つのIssueとして進めます（1 Issue = 1 Branch = 1 PR）。

1. テンプレートのcheckoutが`main`にいて、変更がなく、`origin/main`と一致することを確かめます。取り込み先の本体のcheckoutは、`main`にいて`origin/main`と一致する状態にします。
2. 差分レポートを作ります（3節）。出力は、取り込み先とテンプレートの両方の外に置きます。
3. ほかの作業中かと変更の大きさを判定します（6節）。ほかの作業中なら止めて、終わるまで待つことを勧めます。並行するかは、ユーザーの明示の指示だけで決めます。
4. 計画を分析します（7節）。
5. 取り込み先でテンプレート同期Issueを作ります。対象のテンプレートのcommit、計画のdigest、判定と分析の要約、先に必要な整理とその順、Delivery stage、検証の範囲、Executor、反対モデルを書きます。取り込むファイルは`tools/`、`.agents/`、`Config/`などworkflowの経路に入るため、取り込み先の規則で必要な検証と承認を選びます。
6. `plan.md`と`analysis.md`をユーザーに見せ、承認を得ます（8節）。ユーザーがCodexの確認を指定した場合だけ、Codexの承認にします。`AGENTS.md`を変える場合は、その文面もD-075に従ってユーザーの承認を得て、Issueコメントと`docs/agents-md-approvals.md`へ記録します。
7. Claimして作業ブランチを作ります。作業treeに変更がなく、HEADが計画を作ったときの取り込み先のHEADと同じことを確かめます。
8. 先に必要な整理を、分析の順に片付けます。取り込み先のファイルを変えたら、作業ブランチのcheckoutでレポートと分析を作り直し、承認を取り直します。ほかの作業中かの判定は、最初の1回だけです。
9. 適用toolで適用します（9節）。止まった場合は理由を直し、計画を作り直して、承認を取り直します。
10. 手で確認するファイルを、同じIssueの中で一つずつ判断します。適用で基準commitが新しい版へ進むため、残した差は次の取り込みでアプリ側の変更として扱われます。判断を後回しにしません。
11. 変更をcommitし、取り込み先の規則に従って検証します。取り込んだtoolとskillのrepository test、アプリのBuild、重要なUnit Test、日本語iPhoneのSmoke Testを行い、取り込みの前と後でアプリのBuildとUnit Testが同じように通ることを受け入れ条件に含めます。Simulatorは取り込み先の専用の2台だけを使います。
12. 反対モデルの承認を受けて、mergeします。反対モデルの承認は必須です。PRには、計画のdigest、承認の参照、適用の結果（書き込んだファイル、削除したファイル、追記した決定事項、手で判断したファイル）を書きます。

## 11. スキル`ios-template-sync`とリンク

10節の手順は、スキル`ios-template-sync`にまとめています。正本はテンプレートの`.agents/user-skills/ios-template-sync/`（`SKILL.md`と`agents/openai.yaml`）で、ClaudeとCodexは、`~/.claude/skills/ios-template-sync`と`~/.codex/skills/ios-template-sync`のリンクを通して使います。スキル、リンクのtool、そのtestは`template-only`で、取り込みでアプリへ持ち込みません。

リンクは、テンプレートのcheckoutで張ります。

```sh
tools/link-user-skill.sh ios-template-sync
```

- `~/.claude/skills/<name>`と`~/.codex/skills/<name>`を、このcheckoutの`.agents/user-skills/<name>`を絶対パスで指すリンクにします。`skills/`のフォルダがなければ作ります。
- どちらかに同じ名前のフォルダやファイル、別の場所を指すリンクがあれば、どちらも変えずに非0で止まります。すでに同じ正本を指すリンクなら、何もしません。
- `<name>`は英小文字、数字、`-`だけで、正本のフォルダに`SKILL.md`が必要です。
