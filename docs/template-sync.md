# テンプレート同期：差分レポート、承認、適用

テンプレート更新を、テンプレートから作ったリポジトリや、テンプレートを未適用のリポジトリへ取り込む仕組みです（D-074）。流れは次のとおりです。

1. 差分レポートと適用計画を作る（3〜5節）。取り込み先へは何も書き込まない。
2. 適用計画の承認を得る（6節）。原則はユーザーが承認し、ユーザーが指定したときだけCodexが計画を確認して承認する。
3. 承認後に、計画どおり取り込み先の作業ブランチへ適用する（7節）。

取り込み先では、この流れを1つの「テンプレート同期Issue」として進めます（8節）。

## 1. ファイルの所有区分

`tools/template-sync/ownership.json`が、テンプレートのtrackedファイルをすべて次のどれか一つへ分類します。exact pathの指定が優先し、なければ最も長く一致するprefixで決まります。

| 区分 | 意味 | 取り込み時の扱い |
| --- | --- | --- |
| `template` | テンプレートが持つもの（tool、skill、運用文書など） | 3者比較の結果に従って取り込む |
| `identity` | Identity bootstrapが書き換える文書 | 取り込み先のIdentityで変換してから比べ、取り込む |
| `app` | アプリが持つもの（アプリのソース、Xcode project、`App Store/`の原稿、product／acceptance仕様） | 取り込まない |
| `mixed` | テンプレートとアプリの内容が混ざるもの | 規則ごとに手で確認する |
| `template-only` | テンプレート専用（同期tool自身、過去の実装計画） | アプリへ持ち込まない |

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
- GitHubのテンプレート機能で作った既存の派生アプリには記録がありません。その場合、基準は不明として扱います。

## 3. 差分レポートの作り方

テンプレートのcheckoutから実行します。

```sh
tools/template-sync.sh report --app-root /path/to/app --output-dir /path/outside/app/sync-report
```

- `--template-ref`で比べるテンプレートのcommitを指定できます（既定は`HEAD`）。比べるのは、commit済みの内容です。
- 取り込み先は、HEADのcommitをGitのobjectから読みます。作業tree、index、`.git`の設定は変更しません。作業中の変更がある場合は、その旨をレポートに書きます。
- `--output-dir`は、存在しない新しいフォルダで、取り込み先の外に置く必要があります。
- `--work-dir`を指定すると、テンプレートの展開と変換の結果を再利用します。

## 4. 判定の区分

基準commitが分かる場合は、基準、テンプレートの最新、取り込み先の3つを比べます。

| 区分 | 条件 | 計画での扱い |
| --- | --- | --- |
| 足りない（`missing`） | 取り込み先にない | 追加 |
| 安全に更新できる（`safe-update`） | 取り込み先は基準のままで、テンプレート側だけが変わった | 更新 |
| 衝突する（`conflict`） | 両方が変わった、または基準が分からない | 手で確認する |
| アプリ側だけの変更（`app-only-change`） | テンプレート側は基準のまま | 上書きしない |
| テンプレートで削除された（`deleted-in-template`） | 基準にあり、最新にない | 取り込み先が基準のままなら削除、変更があれば手で確認する |
| 一致（`up-to-date`） | テンプレートと同じ | なし |

テンプレートで削除されたファイルは、基準の版の`tools/template-sync/ownership.json`で区分を決めます。最新の版でmanifestの記載が消えていても、基準の版で`app`だったファイルを削除の対象にしません。基準の版にmanifestがない、またはそのファイルを分類できない場合は、区分を`unknown`とし、削除せずに手で確認します。

比べるのは、Gitに記録された内容と種類（通常のファイル、実行可能なファイル、symlink、submodule）の両方です。実行権限だけの変更も変更として扱います。テンプレートのファイルを置く場所に、取り込み先では同じ名前のフォルダやsubmoduleがある場合や、親のパスがファイルである場合は、`conflict`として手で確認します。

基準commitが記録されていない、または記録が不正な場合は、ファイルごとのhashだけで比べます。違いはすべて`conflict`として手で確認し、レポートの冒頭に基準が不明であることを書きます。

`identity`と、変換指定のある`mixed`のファイルは、そのテンプレートのcommitに含まれる`tools/bootstrap-app.swift`で、取り込み先の`Config/app-identity.json`のIdentityを再適用してから比べます。変換後も`TemplateApp`などの元の名前が増える場合は、更新せずに手で確認する扱いにします。取り込み先にIdentityがない場合や変換に失敗した場合も、これらのファイルは手で確認します。

## 5. 出力

`--output-dir`に次の2つを書きます。

- `plan.md`：ユーザーが読む日本語の計画です。適用する変更、追記する決定事項、上書きしないファイル、手で確認するファイル、決定事項の番号の衝突、専用Simulator、`Config/app-identity.json`の形式の違い、必要な承認を並べます。
- `plan.json`：適用toolが読む計画です。ファイルごとに区分、判定、扱い、理由と、テンプレート最新・基準・取り込み先それぞれのSHA-256を持ちます。`decisions.append`は、`specs/decisions.md`の末尾へ追記する`D-###`です。番号が衝突している場合と、取り込み先に`specs/decisions.md`がない場合は空です。承認は、このファイルのdigest（実行結果の`planDigest`）に結び付けます。

## 6. 承認

承認は、`plan.json`のdigestに結び付けた記録（`approval.json`）です。`plan.json`が1byteでも変わると、その承認は使えません。`plan.md`は、`plan.json`から作り直した内容と一致する必要があります。どちらかを手で変えた計画は、承認も適用もできません。承認の記録は、取り込み先の外に置きます。

### ユーザーの承認（原則）

ユーザーが`plan.md`を読んで承認したら、承認を書いたIssueコメントのURLを参照として記録します。

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

- `codex-review`は、固定のlauncher（`tools/template-sync-codex-review.sh`）でCodex（`gpt-6-sol`、reasoning effort `high`）を起動します。Codexが読めるのは、一時フォルダへ写した`plan.json`と`plan.md`だけです。network、MCP、plugin、web検索、ファイルの書き込みは使えません。10分で止めます。
- Codexの答えは、`approved`と空の指摘か、`changes-requested`と1件以上の指摘（`path`と`problem`）のどちらかです。それ以外の答えは記録しません。`changes-requested`の記録からは承認を作れません。
- 確認の記録は、計画のdigest、ユーザーの指定のURL、launcherのdigest、modelを持ちます。承認と適用のときに、launcherが今のテンプレートのものと同じかを確かめます。
- Codexの承認は、その計画の適用だけに使います。`AGENTS.md`の変更文面（D-075）、その他の変更、外部操作、反対モデルレビュー、mergeの承認にはなりません。確認の記録そのもの（`codex-review.json`）は承認として使えません。

## 7. 適用

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
- 追加するパスに、ignoredやuntrackedのファイルが既にある。更新や削除するファイルが、計画を作ったときの内容と違う。親のパスがsymlinkやファイルである。

止まらなければ、次だけを書き込みます。indexは変えないので、結果は`git status`と`git diff`で確かめます。

- 計画で`add`、`update`、`delete`のファイル。区分が`template`か`identity`のものだけです。`identity`のファイルは、取り込み先のIdentityで変換した内容を書きます。実行権限とsymlinkも計画どおりにします。
- `decisions.append`の`D-###`。テンプレートの`specs/decisions.md`の節を、番号を変えずに取り込み先の末尾へ追記します。
- `Config/template-base.json`。`baseCommit`を取り込んだテンプレートのcommitへ、`recordedAt`を適用の時刻へ更新します。記録がない、または記録が不正だった取り込み先では、`method`を`adopted`にします。

書き込んだ後に、次を検査します。どれかが失敗したら、書き込み済みの変更を`git status`で確かめて、`git restore`などで戻します。

- 書いた内容が、計画のSHA-256と実行権限に一致する。
- Identity変換したファイルの元の名前（`TemplateApp`、`com.yuto.TemplateApp`）が、適用前より増えていない。
- `specs/decisions.md`の既存の内容が変わっていない。
- 専用Simulatorの宣言が、取り込み先の表示名を前置した2台のままで、テンプレート用の端末を指していない。

上書きしないファイル、手で確認するファイル、`mixed`のファイル（`AGENTS.md`、`Config/dedicated-simulators.json`、`specs/decisions.md`の追記以外の変更など）は書き込みません。

## 8. テンプレート同期Issueの進め方

取り込み先のリポジトリで、テンプレートの取り込みを1つのIssueとして進めます（1 Issue = 1 Branch = 1 PR）。

1. 取り込み先でテンプレート同期Issueを作ります。対象のテンプレートのcommit、Delivery stage、検証の範囲、Executor、反対モデルを書きます。取り込むファイルは`tools/`、`.agents/`、`Config/`などworkflowの経路に入るため、取り込み先の規則で必要な検証と承認を選びます。
2. Claimして作業ブランチを作ります。作業treeに変更がないことを確かめます。
3. テンプレートのcheckoutで差分レポートを作ります（3節）。出力は取り込み先の外に置きます。
4. `plan.md`をユーザーに見せ、承認を得ます（6節）。ユーザーがCodexの確認を指定した場合だけ、Codexの承認にします。`AGENTS.md`を変える場合は、その文面もD-075に従ってユーザーの承認を得て、Issueコメントと`docs/agents-md-approvals.md`へ記録します。
5. 適用toolで適用します（7節）。止まった場合は理由を直し、計画を作り直して、承認を取り直します。
6. 手で確認するファイルを、同じIssueの中で一つずつ判断します。適用で基準commitが新しい版へ進むため、残した差は次の取り込みでアプリ側の変更として扱われます。判断を後回しにしません。
7. 変更をcommitし、取り込み先の規則に従って検証します。テンプレートのtoolやtestを取り込んだ場合は、取り込み先のrepository testで確かめます。
8. 反対モデルのレビューが必要な場合はレビューを受け、mergeします。PRには、計画のdigest、承認の参照、適用の結果（書き込んだファイル、削除したファイル、追記した決定事項、手で判断したファイル）を書きます。
