# テンプレート同期：差分レポートと適用計画

テンプレート更新を、テンプレートから作ったリポジトリや、テンプレートを未適用のリポジトリへ取り込む仕組みです（D-074）。流れは次のとおりです。

1. 差分レポートと適用計画を作る（この文書の範囲）。
2. 適用計画の承認を得る。原則はユーザーが承認し、ユーザーが指定したときだけCodexが計画を確認して承認する。
3. 承認後に、計画どおり取り込み先へ適用する。

承認の記録と適用のtoolは後続のIssueで追加します。ここで説明する`tools/template-sync.sh`は、取り込み先へ何も書き込みません。

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

基準commitが記録されていない、または記録が不正な場合は、ファイルごとのhashだけで比べます。違いはすべて`conflict`として手で確認し、レポートの冒頭に基準が不明であることを書きます。

`identity`と、変換指定のある`mixed`のファイルは、そのテンプレートのcommitに含まれる`tools/bootstrap-app.swift`で、取り込み先の`Config/app-identity.json`のIdentityを再適用してから比べます。変換後も`TemplateApp`などの元の名前が増える場合は、更新せずに手で確認する扱いにします。取り込み先にIdentityがない場合や変換に失敗した場合も、これらのファイルは手で確認します。

## 5. 出力

`--output-dir`に次の2つを書きます。

- `plan.md`：ユーザーが読む日本語の計画です。適用する変更、上書きしないファイル、手で確認するファイル、決定事項の番号の衝突、専用Simulator、`Config/app-identity.json`の形式の違い、必要な承認を並べます。
- `plan.json`：後続の適用toolが読む計画です。ファイルごとに区分、判定、扱い、理由と、テンプレート最新・基準・取り込み先それぞれのSHA-256を持ちます。承認は、このファイルのdigest（実行結果の`planDigest`）に結び付けます。
