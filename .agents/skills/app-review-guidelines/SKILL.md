---
name: app-review-guidelines
description: Use when planning an iOS feature, writing a Feature Issue, or checking Definition of Ready, to find which App Store Review Guidelines the feature triggers and put their concrete requirements into acceptance criteria (D-081); when auditing every guideline for a build before App Store submission; or when the guideline map must be rechecked against Apple's page.
---

# App Store審査ガイドライン

Appleの[App Store審査ガイドライン](https://developer.apple.com/app-store/review/guidelines/)を、機能の計画時と提出の前の2か所で適用する（D-081）。正本はAppleのページであり、このスキルの`guidelines.json`は、項目番号、日本語の短い要約、分類、関わる機能の種類、確かめ方だけを持つ対応表である。Appleの本文を写さない。

計画時の手順は下の「計画時の手順」、提出の前の点検は「提出前の点検」に従う。どちらも審査の結果を予測・保証しない。

## 対応表

`guidelines.json`の主な内容：

- `source`：Appleのページの`url`、ページの「Last Updated」の`lastUpdated`、取得した日の`retrievedAt`。
- `maxAgeDays`：取得日からこの日数を超えた対応表は、Appleのページを確かめ直すまで使わない（30日）。
- `featureKinds`：機能の種類の一覧。
- `guidelines`：各項目の`id`、`class`、`features`、`summary`、`check`。
- `containers`：子の項目だけで内容が決まる入れ物の番号。`omitted`：Appleが「Intentionally omitted」とした番号。

`class`は次のどれか1つ：

| class | 意味 | 計画時の扱い |
| --- | --- | --- |
| `always` | すべてのアプリに関わる | 機能がその前提を崩さないか確かめる。提出前の点検で必ず扱う |
| `triggered` | `features`の機能を持つときだけ関わる | 当たる機能を計画するとき、要件を受け入れ条件へ入れる |
| `user-judgment` | AIが機械的に判断できない | AIは所見だけを示し、ユーザーが決める |

## 計画時の手順

1. 鮮度を確かめる。Appleのページの「Last Updated」を読み、`source.lastUpdated`と同じか、`source.retrievedAt`から`maxAgeDays`以内かを確かめる。日付が違うか期限を過ぎていれば、下の「対応表の更新」を先に行うか、Appleのページを直接読んで同じ判断をし、そのことをIssueに書く。
2. 計画する機能を`featureKinds`の種類へ当てはめる。迷う場合は当たるものとして扱う。
3. 当たる種類を`features`に含む`triggered`の項目を引く。

   ```sh
   jq -r --arg kind accounts '.guidelines[] | select(.features | index($kind)) | "\(.id)\t\(.summary)"' .agents/skills/app-review-guidelines/guidelines.json
   ```

4. 引いた各項目の`check`を、その機能の具体的な要件としてIssueの受け入れ条件へ入れる。例：
   - アカウントを作れる → アプリ内でアカウントを削除できる（5.1.1(v)）。
   - 他社のログインを主に使う → Sign in with Appleなどの同等のログインも出す（4.8）。
   - デジタルの購入 → アプリ内課金を使い、復元の導線を用意する（3.1.1）。
   - 利用者の投稿 → 不適切な内容の抑止、通報、ブロック、連絡先を用意する（1.2）。
   - 位置情報、トラッキング、外部のAIへの送信 → 事前に説明して同意を得る（5.1.5、5.1.2(i)）。
5. 当たる種類がなければ、Issueの本文（In scopeまたはOut of scope）に「審査ガイドラインの`triggered`の項目に当たる機能はない」と書く。
6. 機能が`always`の項目の前提（例：プライバシーポリシーへのリンク、連絡先、ログインなしで使える範囲）を変えるなら、その要件も受け入れ条件へ入れる。
7. `user-judgment`の項目（模倣、最低限の機能、スパム、知的財産、不適切な内容など）に関わる懸念があれば、所見をIssueに書き、ユーザーの判断を待つ。AIだけで満たしたと決めない。
8. 要件の扱いが受け入れ条件を変えるのに決まっていなければ、`spec-workflow`に従ってIssueを`blocked:user`にする。

項目の要件を満たす実装を、Issueの範囲の外へ広げない。別の機能になる要件は別のIssueに分ける。

## 対応表の更新

Appleのページの「Last Updated」が`source.lastUpdated`と違うとき、テンプレートで対応表を更新するIssueを作る（派生アプリでは行わず、テンプレートの取り込みで受け取る）。

1. Appleのページを取得し、番号付きの全項目を確かめる。5.1.1と5.1.2はローマ数字の小項目、2.1は(a)と(b)を別の項目にする。
2. 変わった項目の要約、分類、機能の種類、確かめ方を更新し、新しい番号を追加し、消えた番号を除く。すべての番号が`guidelines`、`containers`、`omitted`のどれか1つだけに入るようにする。
3. `source.lastUpdated`と`source.retrievedAt`を更新する。要約と確かめ方は日本語の言い換えにし、Appleの本文を写さない。
4. `tools/tests/test-app-review-guidelines.sh`の`inventories`に、新しい更新日をキーとして、対応表とは別にAppleのページから数えた番号の一覧を加える。testは、対応表の`guidelines`、`containers`、`omitted`の番号がこの一覧と過不足なく一致することを確かめる。
5. `tools/tests/test-app-review-guidelines.sh`を実行する。

## 提出前の点検

各アプリは、提出するbuildごとに、対応表のすべての項目を点検した点検表`App Store/review/guidelines-audit.json`を持つ。テンプレート自身は提出しないため、点検表をcommitしない。

1. Appleのページの「Last Updated」を確かめる。対応表の`source.lastUpdated`と違えば提出を止め、先にテンプレートで対応表を更新して取り込む。取得日から`maxAgeDays`を超えた対応表も、確かめ直すまで使えない。
2. 点検表を作る。形式：

   ```json
   {
     "schemaVersion": 1,
     "map": {"lastUpdated": "2026-10-16", "digest": "sha256:<guidelines.jsonのSHA-256>"},
     "app": {"bundleId": "<Bundle ID>", "version": "<version>", "build": "<build>"},
     "auditedAt": "<ISO 8601>",
     "items": [
       {"id": "1.5", "status": "satisfied", "evidence": ["<projectの中のpath、path:行、またはhttps URL>"]},
       {"id": "1.2", "status": "not-applicable", "reason": "<当たらない理由>"},
       {"id": "4.2", "status": "user-confirmed", "confirmation": {"by": "user", "confirmedAt": "<ISO 8601>", "reference": "https://github.com/<owner>/<repo>/issues/<n>#issuecomment-<id>"}}
     ]
   }
   ```

   - `always`は`satisfied`だけ、`triggered`は`satisfied`か`not-applicable`、`user-judgment`は`user-confirmed`だけを使う。各項目に`note`を添えてよい。
   - `satisfied`の根拠は、実装、設定、文書、公開ページなど、確かめた場所を指す。
   - `user-judgment`は、AIの所見をIssueのコメントに書いてユーザーに確認してもらい、ユーザーが確認したコメントのURLを`reference`に入れる。AIだけで`user-confirmed`にしない。
   - 秘密、パスワード、デモアカウントの実値、個人情報を書かない。
3. 点検toolを実行する。

   ```sh
   tools/check-review-guidelines.sh --project-root "$PWD" --bundle-id "$BUNDLE_ID" --version "$VERSION" --build "$BUILD"
   ```

   exit 0（`"status":"passed"`）だけを合格とする。exit 1は点検表の不備で、出力の`errors`を直す。exit 2は読めない入力である。点検toolはlocalのファイルだけを読み、network、App Store Connect、Appleのページに接続しない。
4. `prepare-appstore-assets`は合格を確かめてからrelease auditorの承認と封印へ進み、`submit-appstore-release`は認証を伴う書き込みとその再開の前にもう一度実行する。

点検toolの合格は審査通過の証拠ではない。提出packageの検査、初回の法務承認、release audit、提出の明示許可、外部操作の権限は、これまでどおり別に満たす。

## 境界

- 対応表とこのスキルは、審査の結果を予測・保証しない。
- 既存の提出の明示許可、初回の法務承認、release audit、提出packageの検査、外部操作の権限を変えない。
