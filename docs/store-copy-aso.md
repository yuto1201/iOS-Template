# App Storeの原稿のASOガイド

App Storeで選ばれやすい（検索で見つかり、商品ページで入れたくなる）アプリ名、サブタイトル、キーワード、プロモーション用テキスト、説明、What's New、スクリーンショットの見出しの書き方を、出典付きでまとめます（ASO：App Store Optimization）。
原稿は[prepare-appstore-assetsスキル](../.agents/skills/prepare-appstore-assets/SKILL.md)がこのガイドに従って作り、機械で確かめられる部分は読み取りだけの検査tool [`tools/check-store-copy.sh`](../tools/check-store-copy.sh)で確かめます。

このガイドは、確認済みのアプリの振る舞いと仕様から原稿を作るという既存の規則を変えません。アプリにない機能、順位、受賞、評価の数を書きません。App Store Connectへの保存は[save-appstore-metadataスキル](../.agents/skills/save-appstore-metadata/SKILL.md)だけが行い、このガイドと検査toolは保存も外部への通信もしません。

## 読み方

- **Apple公式**：Appleのページに書かれていること。
- **実務の知見**：ASOの実務者の記事に書かれていて、Appleが明言していないこと。Apple公式と分けて書き、そのまま事実として扱いません。
- **何を書くか／避けること**：上の二つから、このテンプレートが決めた書き方です。
- **検査toolが確かめるか**：[検査tool](#検査tool)が確かめる項目と、目で確かめる項目です。

出典はすべて2026-10-21に確認しました。各節の確認日も同じです。有料のASOツール（AppTweak、Sensor Towerなど）の契約やAPI、App Storeのページの自動収集は使いません。

| 出典 | 種類 | URL | 確認日 |
| --- | --- | --- | --- |
| App Store search | Apple公式 | https://developer.apple.com/app-store/search/ | 2026-10-21 |
| Creating Your Product Page | Apple公式 | https://developer.apple.com/app-store/product-page/ | 2026-10-21 |
| Platform version information | Apple公式 | https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information | 2026-10-21 |
| Platform version information（日本語版） | Apple公式 | https://developer.apple.com/jp/help/app-store-connect/reference/app-information/platform-version-information/ | 2026-10-21 |
| App Review Guidelines（2026-10-16更新） | Apple公式 | https://developer.apple.com/app-store/review/guidelines/ | 2026-10-21 |
| App Store localizations | Apple公式 | https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations/ | 2026-10-21 |
| Product Page Optimization | Apple公式 | https://developer.apple.com/app-store/product-page-optimization/ | 2026-10-21 |
| Create a test | Apple公式 | https://developer.apple.com/help/app-store-connect/create-product-page-optimization-tests/create-a-test/ | 2026-10-21 |
| Custom Product Pages | Apple公式 | https://developer.apple.com/app-store/custom-product-pages/ | 2026-10-21 |
| AppTweak: iOS keyword field | 実務の知見 | https://www.apptweak.com/en/aso-blog/how-to-optimize-your-ios-keyword-field | 2026-10-21 |
| AppTweak: ASO checklist for iOS | 実務の知見 | https://www.apptweak.com/en/aso-blog/app-store-optimization-aso-checklist-for-ios | 2026-10-21 |
| Applyra: character limits | 実務の知見 | https://www.applyra.io/tools/character-limits | 2026-10-21 |
| AppLupe: localization keywords | 実務の知見 | https://aso.appmatch.jp/guide/localization-keywords | 2026-10-21 |
| Appalize: locale character limits | 実務の知見 | https://www.appalize.com/tools/locale-character-limits | 2026-10-21 |
| Appfigures: App Store algorithm update 2025 | 実務の知見 | https://appfigures.com/resources/guides/app-store-algorithm-update-2025 | 2026-10-21 |
| ConsultMyApp: screenshot titles | 実務の知見 | https://www.consultmyapp.com/blog/-is-apple-now-indexing-screenshot-titles-on-the-app-store | 2026-10-21 |
| Appfigures: screenshots that rank and convert | 実務の知見 | https://appfigures.com/resources/videos/how-to-make-app-store-screenshots-that-rank-and-convert | 2026-10-21 |

## 流れ

1. 原稿の正本は各アプリの`App Store/metadata/localizations/<locale>.yml`（`name`、`subtitle`、`keywords`、`promotionalText`、`description`）と、What's Newにあたる`App Store/release-notes/<locale>.md`です。文字数の上限は[`App Store/submission/requirements.json`](<../App Store/submission/requirements.json>)を正とします。
2. `prepare-appstore-assets`が、確認済みの機能からロケールごとの案を2〜3出し、正本の外（例：`.artifacts/appstore-draft/<案>/localizations/`）に置きます。
3. 各案を検査toolに通し、`error`を直し、残す`warning`には理由を書きます。
4. 案と検査の結果をユーザーに見せ、明示に1案を選んでもらいます。
5. 選んだ案と理由（狙う語、避けた語、英語（米国）の欄の扱い、残したwarning）を、原稿の横の`App Store/metadata/aso-decisions.md`に記録してから、正本へ反映します。
6. App Store Connectへの保存は、`save-appstore-metadata`の手順と承認でだけ行います。

## 検索と商品ページの仕組み

確認日：2026-10-21（この節の出典すべて）

### Apple公式

- 検索の順位は、テキストの関連性（アプリ名、サブタイトル、キーワード、主カテゴリ）と、利用者の行動（ダウンロード、評価とレビューなど）で決まる。（[App Store search](https://developer.apple.com/app-store/search/)）
- 検索結果には、評価と、最大3枚のスクリーンショットまたはプレビュー、メタデータからLLMで作る「app tags」が出る。（[App Store search](https://developer.apple.com/app-store/search/)）
- 人気の語は競争が激しく、新しい小さなアプリは、少ない語の方が上位を取りやすい。（[App Store search](https://developer.apple.com/app-store/search/)）

## アプリ名

確認日：2026-10-21（この節の出典すべて）

### Apple公式

- 上限は30字。（[Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)、[日本語版](https://developer.apple.com/jp/help/app-store-connect/reference/app-information/platform-version-information/)）
- 覚えやすく、綴りやすく、何をするアプリか分かる名前にする。（[Creating Your Product Page](https://developer.apple.com/app-store/product-page/)）
- 審査ガイドライン2.3.7：名前は固有で30字まで。商標、人気アプリの名前、価格、無関係な語でメタデータを埋めない。名前、サブタイトル、スクリーンショット、プレビューに、価格や、種類に合わない説明を入れない。（[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)）

### 実務の知見

- 名前（タイトル）が検索で最も重く、サブタイトルとキーワード欄が続く。重要な語は名前とサブタイトルに置く。Appleはこれを明言していない。（[AppTweak: ASO checklist for iOS](https://www.apptweak.com/en/aso-blog/app-store-optimization-aso-checklist-for-ios)、[AppTweak: iOS keyword field](https://www.apptweak.com/en/aso-blog/how-to-optimize-your-ios-keyword-field)）

### 何を書くか

- `<ブランド名>`と、必要なら区切りの後に主な機能の語を置き、30字以内にする。日本語は`Tempo：集中タイマー`、英語は`Tempo: Focus Timer`のように書く。
- 主な機能の語は、利用者が検索する言葉から選ぶ（[キーワード](#キーワード)の調べ方を使う）。
- 綴りやすさと、既存アプリとの紛らわしさを、App Storeで名前と似た語を検索して確かめる。

### 避けること

- 価格、「無料」「Free」、割引の表記。
- 「No.1」「世界一」「最高」「best」のような、確かめられない順位や最上級の主張。
- 他社のアプリ名、商標、有名人の名前、アプリと関係の無い語。

### 検査toolが確かめるか

- 確かめる：文字数（`length`、2〜30字）、価格と無料の表記（`price`）、確かめられない主張（`unverifiable-claim`）、設定した競合名と商標との一致（`competitor-name`、`trademark`）。どれも`error`です。
- 確かめない：綴りやすさ、既存アプリとの紛らわしさ、名前の良さ。目で確かめ、`aso-decisions.md`に書きます。

## サブタイトル

確認日：2026-10-21（この節の出典すべて）

### Apple公式

- 上限は30字。（[Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)）
- アプリの価値を短く言う。「世界一のアプリ」のような一般的な言い方を避ける。（[Creating Your Product Page](https://developer.apple.com/app-store/product-page/)）
- 審査ガイドライン2.3.7：サブタイトルは他のアプリに触れず、確かめられない主張をしない。価格を入れない。（[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)）
- サブタイトルは検索の順位を決めるテキストの一つ。（[App Store search](https://developer.apple.com/app-store/search/)）

### 実務の知見

- 名前に次いで重い。名前と同じ語を繰り返しても重みは増えない。（[AppTweak: iOS keyword field](https://www.apptweak.com/en/aso-blog/how-to-optimize-your-ios-keyword-field)）

### 何を書くか

- 主な利点を、利用者が検索する言葉で、30字以内で書く。
- 名前に無い語を使い、名前と合わせて何ができるかが伝わるようにする。

### 避けること

- 名前と同じ語の繰り返し。
- 「かんたん」「便利」だけのような一般的な誇張、順位や最上級の主張、価格、他社名。

### 検査toolが確かめるか

- 確かめる：文字数（`length`）、`price`、`unverifiable-claim`、`competitor-name`、`trademark`。どれも`error`です。
- 確かめない：名前との語の重なり、言い方の誇張。目で確かめます。

## キーワード

確認日：2026-10-21（この節の出典すべて）

### Apple公式

- カンマで区切り、カンマの前後にスペースを入れない。語句の中のスペースは使える。（[App Store search](https://developer.apple.com/app-store/search/)）
- アプリ名、サブタイトル、カテゴリと同じ語を繰り返さない。単数形があれば複数形を入れない。「app」「game」のような広すぎる語、つなぎの語、特殊文字を避ける。（[App Store search](https://developer.apple.com/app-store/search/)、[Creating Your Product Page](https://developer.apple.com/app-store/product-page/)）
- 商標、有名人の名前、関係の無い語、他社のアプリ名を使わない。これらは却下の多い理由である。（[App Store search](https://developer.apple.com/app-store/search/)、[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 2.3.7）
- 上限は、App Store Connectヘルプでは「100バイト」。一方で[App Store search](https://developer.apple.com/app-store/search/)は「100 characters」と書く。日本語は1文字3バイトなので、二つの差は大きい。（[Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)、[日本語版](https://developer.apple.com/jp/help/app-store-connect/reference/app-information/platform-version-information/)）
- 日本のストアの既定の言語は日本語で、追加の言語は英語（米国）。（[App Store localizations](https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations/)）
- 人気の語は競争が激しく、新しい小さなアプリは、少ない語の方が上位を取りやすい。（[App Store search](https://developer.apple.com/app-store/search/)）

### 実務の知見

- キーワード欄には、名前とサブタイトルに無い語を単語の単位で入れる。Appleは欄をまたいで語を組み合わせるので、語句を丸ごと入れる必要は無い。繰り返しても重みは増えない。（[AppTweak: iOS keyword field](https://www.apptweak.com/en/aso-blog/how-to-optimize-your-ios-keyword-field)）
- 英語以外の言語では、複数形を別の語として扱うことがある。（[AppTweak: iOS keyword field](https://www.apptweak.com/en/aso-blog/how-to-optimize-your-ios-keyword-field)）
- 実務では、キーワード欄の上限を文字数で数えるという報告が多い。（[Applyra: character limits](https://www.applyra.io/tools/character-limits)）
- 日本のストアでは英語（米国）のメタデータも検索の対象になり、キーワード欄を実質2つ使えると広く言われる。Appleは検索の対象になるとは明記していない。（[AppLupe: localization keywords](https://aso.appmatch.jp/guide/localization-keywords)、[Appalize: locale character limits](https://www.appalize.com/tools/locale-character-limits)）

### 何を書くか

- 調べ方：App Storeの検索欄に語を入れて出る検索候補、同じカテゴリの競合アプリの名前とサブタイトル、日本語と英語の言い換えから候補を集める。有料のASOツールは使わない。
- 選び方：人気と競争のバランスを見る。新しいアプリは、利用者が実際に使う、より具体的で絞った語を選ぶ。重要な語は名前とサブタイトルに回し、キーワード欄には残りを入れる。
- 書き方：`語,語,語`のようにASCIIのカンマだけで区切り、スペースを入れない。名前、サブタイトル、カテゴリと重ねない。英語は単数形だけにする。「アプリ」「app」「game」を入れない。他社名と商標を入れない。
- 日本語と英語（米国）の欄の使い分け：`ja.yml`には日本語の語、`en-US.yml`には英語の語を入れるのを基本にする。英語（米国）の欄に日本語の語を入れるかは、アプリごとに決め、理由を`aso-decisions.md`に書く（[決まっていないこと](#決まっていないこと)）。

### 避けること

- カンマの前後のスペース、全角の読点（`、`）や全角カンマでの区切り、空の語、同じ語の重複。
- 名前とサブタイトルにある語、広すぎる語、特殊文字、英語の単数形と複数形の両方。
- 他社のアプリ名、商標、有名人の名前、関係の無い語。

### 検査toolが確かめるか

- `error`：上限の超過（`keywords-length`）、カンマの前後のスペース（`space-around-comma`）、全角の区切り（`full-width-comma`）、空の語（`empty-term`）、同じ語の重複（`duplicate-term`）、設定した競合名と商標（`competitor-name`、`trademark`）、欄が空（`missing`）。
- `warning`：もう一方の単位での超過（`keywords-length-other-unit`）、同じロケールの名前とサブタイトルとの重複（`keyword-overlap`）、広すぎる語（`broad-term`）、特殊文字（`special-character`）、英語の単数形と複数形の重複（`plural-duplicate`）。
- 長さはバイト数と文字数の両方を出します。どちらで止めるかは設定の`keywordLimit`で選び、既定はApp Store Connectヘルプのバイト数です。
- 確かめない：カテゴリとの重複、語の人気と競争、英語（米国）の欄の日本語の扱い。

## プロモーション用テキスト

確認日：2026-10-21（この節の出典すべて）

### Apple公式

- 上限は170字。版の提出なしに、いつでも更新できる。（[Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)）
- 検索の順位に影響しないので、キーワードを並べない。（[App Store search](https://developer.apple.com/app-store/search/)）
- Custom product pagesでは、ページごとにプロモーション用テキストを変えられる。（[Custom Product Pages](https://developer.apple.com/app-store/custom-product-pages/)）

### 実務の知見

- この項目について、このガイドが使う実務の出典はありません。

### 何を書くか

- 季節の話題や新しい機能の告知を、1〜2文の文章で書く。いつでも変えられるので、古くなったら書き換える。

### 避けること

- カンマ区切りの語の並び（検索に効かない）、確かめられない主張、他社名。

### 検査toolが確かめるか

- 確かめる：文字数（`length`、`error`）、キーワードの羅列に見えること（`keyword-list`、`warning`：区切られた短い語が4つ以上続き、文の終わりが無い）、設定した競合名と商標（`competitor-name`、`trademark`、`warning`）。
- 確かめない：告知の内容が今も正しいか。

## 説明

確認日：2026-10-21（この節の出典すべて）

### Apple公式

- 上限は4000字。版の提出で更新する。（[Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)）
- 1文目が最も重要で、「続きを読む」の前に読める。価格を書かない。検索のための不要なキーワードを入れない。（[Creating Your Product Page](https://developer.apple.com/app-store/product-page/)）

### 実務の知見

- この項目について、このガイドが使う実務の出典はありません。

### 何を書くか

- 1文目で、何ができるアプリかを言う。
- 続けて短い段落と、主な機能の箇条書きを書く。機能は実装済みで確認できるものだけにする。

### 避けること

- 箇条書きや見出し、空行から始めること。
- 価格、「無料」、検索のためだけの語の並び、他社名。

### 検査toolが確かめるか

- `error`：1文目の欠落（`first-sentence-missing`：空行、箇条書き、見出しから始まる）、文字数（`length`）、欄が空（`missing`）。
- `warning`：1文目が長い（`first-sentence-long`）、価格の表記（`price`）、設定した競合名と商標（`competitor-name`、`trademark`）。
- 1文目の長さの目安は、日本語60字、ほかの言語120字です。これはテンプレートの既定で、Appleの数値ではありません。設定の`firstSentenceMaxCharacters`で変えられます。
- 確かめない：検索のための不要な語、文章の分かりやすさ。

## What's New

確認日：2026-10-21（この節の出典すべて）

### Apple公式

- 上限は4000字。（[Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)）
- 審査ガイドライン2.3.12：新しい機能と変更を、What's Newの文章で具体的に説明する。（[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)）

### 実務の知見

- この項目について、このガイドが使う実務の出典はありません。

### 何を書くか

- 今回の大きな変更を、利用者に関わる順に、具体的に書く。正本は`App Store/release-notes/<locale>.md`で、`save-appstore-metadata`の`whatsNew`にあたる。

### 避けること

- 「不具合を修正しました」だけのような、何が変わったか分からない文。実装していない変更。

### 検査toolが確かめるか

- 確かめない。What's Newの上限は`requirements.json`に無く、この検査は`requirements.json`の上限だけを使うためです。文字数と内容は目で確かめます。

## スクリーンショットの見出し

確認日：2026-10-21（この節の出典すべて）

### Apple公式

- プレビューが無いと、最初の1〜3枚のスクリーンショットが検索結果に出るので、アプリの本質を見せる。以降は1枚に1つの利点か機能を見せる。Dark Modeに対応していれば、1枚は見せる。（[Creating Your Product Page](https://developer.apple.com/app-store/product-page/)、[App Store search](https://developer.apple.com/app-store/search/)）
- 審査ガイドライン2.3.3：スクリーンショットは使用中のアプリを見せる。2.3.7：スクリーンショットとプレビューに価格を入れない。（[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)）

### 実務の知見

- スクリーンショットの見出しの文字が検索の順位に使われ始めたという報告がある（2025年6月）。（[Appfigures: App Store algorithm update 2025](https://appfigures.com/resources/guides/app-store-algorithm-update-2025)）
- 一方で、広くは確認できないという検証もある。（[ConsultMyApp: screenshot titles](https://www.consultmyapp.com/blog/-is-apple-now-indexing-screenshot-titles-on-the-app-store)）
- どちらでも、見出しは検索の語と同じ言葉で利点を言い、読みやすいコントラストにするのが安全とされる。（[Appfigures: screenshots that rank and convert](https://appfigures.com/resources/videos/how-to-make-app-store-screenshots-that-rank-and-convert)）

### 何を書くか

- 最初の3枚で、アプリの本質（何ができ、何が違うか）を見せる。
- 1枚に1つの利点を、狙うキーワードと同じ言葉で、短く言う。
- 背景に対して読みやすいコントラストにする。
- 見た目と描画は[appstore-creativeスキル](../.agents/skills/appstore-creative/SKILL.md)（[使い方](./appstore-creative.md)）が担当し、見出しの方針はこの節を正とします。appstore-creativeの見出しの案は仮の文言で、この節に合わせて選びます。

### 避けること

- アプリに無い機能、順位、受賞、評価、価格。
- 画面の説明だけで利点が分からない見出し。

### 検査toolが確かめるか

- 確かめない。見出しは画像とGoldieの設定にあり、この検査は原稿のYAMLだけを読むためです。appstore-creativeの提案シートが見出しの長さに印を付け、残りは目で確かめます。

## 計測と改善

確認日：2026-10-21（この節の出典すべて）

### Apple公式

- Product page optimization：アイコン、スクリーンショット、プレビューの代替を最大3つ作り、元の商品ページと比べる。テストは1度に1つ、期間は最長90日で、開始後は変えられない。テストに使うメタデータは審査が必要。（[Product Page Optimization](https://developer.apple.com/app-store/product-page-optimization/)、[Create a test](https://developer.apple.com/help/app-store-connect/create-product-page-optimization-tests/create-a-test/)）
- Custom product pages：最大70の追加ページを作り、スクリーンショット、プレビュー、プロモーション用テキストを変えられる。キーワードを割り当てると、検索結果に出せる。（[Custom Product Pages](https://developer.apple.com/app-store/custom-product-pages/)）

### 実務の知見

- この項目について、このガイドが使う実務の出典はありません。

### 何を書くか

- 1度に変えるのは1つの要素にする（例：最初のスクリーンショットだけ）。
- テストの前に、次の形で計画を`aso-decisions.md`に書き、終わったら結果と判断を書き足す。

```markdown
## 検証：<名前>（<開始日>〜<終了日>）

- 種類：Product page optimization／Custom product page
- 仮説：<何を変えると、なぜ良くなると考えるか>
- 変える要素：<1つだけ。例：1枚目のスクリーンショット>
- 比べるもの：<元のページと代替A〜C、または対象のキーワード>
- 指標：<App Store Connectで見る値>
- 結果：<数値と期間>
- 判断：<採用、不採用、次の仮説>
```

- テストとページの作成、提出は認証済みの外部操作で、このガイドの範囲外です。後続のIssueで、指定された実行モデルと承認によって行います。

### 避けること

- 複数の要素を同時に変えること、結果を待たずに次のテストを始めること。

### 検査toolが確かめるか

- 確かめない。

## 審査ガイドラインとの関係

確認日：2026-10-21（この節の出典すべて）

[app-review-guidelinesスキル](../.agents/skills/app-review-guidelines/SKILL.md)の[対応表](../.agents/skills/app-review-guidelines/guidelines.json)と同じ分類で扱います。このガイドに従っても、審査の結果を予測・保証しません。

| 項目 | 対応表の分類 | このガイドでの扱い |
| --- | --- | --- |
| 2.3.3 | `always` | スクリーンショットは使用中のアプリを見せる（[スクリーンショットの見出し](#スクリーンショットの見出し)）。 |
| 2.3.7 | `always` | 名前、サブタイトル、キーワードに価格、他社名、商標、無関係な語、確かめられない主張を入れない。検査toolの`price`、`unverifiable-claim`、`competitor-name`、`trademark`が一部を確かめる。 |
| 2.3.12 | `always` | What's Newに大きな変更を具体的に書く（[What's New](#whats-new)）。 |
| 2.3.14 | `triggered`（`store-promotions`） | 商品ページのcreative assetsを使う場合、内容はアプリとブランドに関わり、全年齢向けで、誤解を招く表現や具体的な価格を含めない。 |
| 5.6.1 | `triggered`（`review-prompts`） | 評価とレビューは検索の順位に影響する（[App Store search](https://developer.apple.com/app-store/search/)）が、評価の依頼は提供されたAPIで行い、独自のレビュー依頼の画面を出さない。 |

出典：[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)（2026-10-16更新）。

## 決まっていないこと

次の3つは、まだ決まっていません。実装と原稿作りは止めず、既定の扱いで進め、アプリごとの判断を`aso-decisions.md`に記録します。

1. キーワードの上限の単位：App Store Connectヘルプは「100バイト」、Appleの[App Store search](https://developer.apple.com/app-store/search/)は「100 characters」と書き、実務では文字数で数えるという報告が多い。App Store Connectの入力欄で実際に確かめるまで、検査toolの既定はバイト数（安全側）とします。設定の`keywordLimit`を`characters`にすると文字数で止め、バイト数の超過は`warning`になります。`requirements.json`の上限の値は変えません。
2. 日本のストアでの英語（米国）の扱い：英語（米国）のメタデータが日本のストアの検索の対象になるかを、Appleは明記していません。英語（米国）の欄に日本語の語を入れるかは、アプリごとに決め、理由を記録します。
3. 有料のASOツール：今は使いません。

## 検査tool

`tools/check-store-copy.sh`は、ローカルのファイルだけを読みます。原稿を書き換えず、ネットワーク、App Store Connect、認証情報の保存先へ接続しません。成功は、承認、release readiness、審査の通過の証拠ではありません。

```sh
tools/check-store-copy.sh --project-root "$PWD"
tools/check-store-copy.sh --project-root "$PWD" \
  --localizations .artifacts/appstore-draft/candidate-a/localizations
```

| option | 既定 | 内容 |
| --- | --- | --- |
| `--project-root DIR` | 必須 | アプリのリポジトリの絶対path |
| `--localizations DIR` | `App Store/metadata/localizations` | `<locale>.yml`を読むフォルダ。案を確かめるときに使う |
| `--requirements PATH` | `App Store/submission/requirements.json` | 文字数の上限 |
| `--config PATH` | `App Store/metadata/aso.json`（無ければ既定値） | 下の設定 |

結果はJSONで標準出力に出ます。`status`、読んだ`locales`、キーワードの上限（`keywordLimit`の`unit`と`value`）、ロケールごとのキーワードのバイト数と文字数（`keywords`）、`errors`、`warnings`を持ち、各指摘は`severity`、`locale`、`field`、`code`、`message`と、必要なら`term`を持ちます。終了コードは、`error`が無ければ0、あれば1、入力を読めないときや設定が不正なときは2です。

- `error`：提出の前に直す。
- `warning`：直すか、残す理由を`aso-decisions.md`に書けば残せる。

設定（`App Store/metadata/aso.json`、任意）：

```json
{
  "schemaVersion": 1,
  "keywordLimit": "bytes",
  "competitors": ["<競合のアプリ名>"],
  "trademarks": ["<商標>"],
  "firstSentenceMaxCharacters": {"ja": 60, "en-US": 120}
}
```

`schemaVersion`だけが必須です。`keywordLimit`は`bytes`（既定）か`characters`です。`characters`の上限は、`requirements.json`に`keywords.maxCharacters`があればその値、無ければ`maxBytes`と同じ数（100）を使います。

| code | severity | 内容 |
| --- | --- | --- |
| `no-localizations` | `error` | `<locale>.yml`が1つも無い |
| `missing-locale` | `warning` | `ja`か`en-US`が無い |
| `invalid-localization` | `error` | YAMLとして読めない、または項目の対応表でない |
| `invalid-field` | `error` | 項目が文字列でない |
| `missing` | `error` | `name`、`keywords`、`description`が空 |
| `length` | `error` | 名前、サブタイトル、プロモーション用テキスト、説明が`requirements.json`の上限を超える |
| `keywords-length` | `error` | キーワードが選んだ単位の上限を超える |
| `keywords-length-other-unit` | `warning` | 選んだ単位では収まるが、もう一方の単位では超える |
| `space-around-comma` | `error` | カンマの前後、または欄の端にスペースがある |
| `full-width-comma` | `error` | `、`や`，`で区切っている |
| `empty-term` | `error` | 空の語がある |
| `duplicate-term` | `error` | 同じ語が2回以上ある（全角と半角、大文字と小文字をそろえて比べる） |
| `special-character` | `warning` | 文字、数字、スペース、`-`、`'`、`.`、`+`以外の文字がある |
| `broad-term` | `warning` | 「app」「game」「アプリ」「ゲーム」のような広すぎる語 |
| `keyword-overlap` | `warning` | 同じロケールの名前かサブタイトルにある語 |
| `plural-duplicate` | `warning` | 英語の単数形と複数形が両方ある |
| `price` | 名前とサブタイトルは`error`、説明は`warning` | 価格、「無料」「Free」、割引の表記 |
| `unverifiable-claim` | `error` | 名前とサブタイトルの「No.1」「世界一」「最高」「best」などの主張 |
| `competitor-name` | 名前、サブタイトル、キーワードは`error`、説明とプロモーション用テキストは`warning` | 設定の`competitors`と一致する |
| `trademark` | `competitor-name`と同じ | 設定の`trademarks`と一致する |
| `first-sentence-missing` | `error` | 説明が空行、箇条書き、見出しから始まる |
| `first-sentence-long` | `warning` | 説明の1文目が目安より長い |
| `keyword-list` | `warning` | プロモーション用テキストがキーワードの羅列に見える |

語の一致は、英字の語は単語の単位で、日本語などは文字列として比べます。日本語の語の区切りは見ないため、目での確認を省きません。

## 選択の記録

選んだ案と理由は、原稿の横の`App Store/metadata/aso-decisions.md`に、新しい順に書き足します。過去の記録は書き換えません。認証情報や個人情報を書きません。

```markdown
## <日付>：<対象の版、または変更の名前>

- 案：A、B、C（`.artifacts/appstore-draft/<案>/`）
- 選んだ案：B（ユーザーの明示の選択。記録先：<Issueのコメントなど>）
- 狙う語：ja <語>、en-US <語>
- 避けた語と理由：<語>（<他社名、人気が高すぎる、など>）
- 英語（米国）の欄の日本語の語：入れる／入れない（理由：<理由>）
- 残したwarningと理由：`<code>`（<理由>）
- 検査：`tools/check-store-copy.sh`の`status`と、ロケールごとのキーワードのバイト数と文字数
```
