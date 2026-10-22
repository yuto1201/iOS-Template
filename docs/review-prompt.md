# レビュー誘導（アプリ評価のお願い）

利用者がアプリをある程度使った後に、たまに小さなsheetで「<アプリ名>はどうですか？」と聞く部品です（#383）。

- 「良い」：sheetを閉じた後に、Appleの評価の依頼（SwiftUIの`requestReview`）を呼びます。アプリ独自の星の画面は作りません（App Store審査ガイドライン5.6.1）。
- 「いまいち」：「よろしければ、改善のためにご意見をお聞かせください。」と、アプリ内フィードバック（D-076）を開く「フィードバックを送る」と「閉じる」を出します。送信先が無いビルドでは、サポートページ（`LegalLinks`）があればその案内、無ければお礼だけを出します。
- 「あとで」または下へ閉じる：答えずに閉じた回数として数えます。

部品はアプリのフォルダの`Features/ReviewPrompt/`にあり、テンプレートでは`ContentView`の`.reviewPrompt(_:)`で組み込んでいます。

## 設定（`ReviewPromptConfig.json`）

各アプリが値を変えられます。欠けた値は既定値を使い、負の数や型の違う値、壊れたファイルは機能を無効にします。

| 設定 | 既定値 | 意味 |
| --- | --- | --- |
| `enabled` | `true` | `false`で機能ごと無効 |
| `minimumLaunchCount` | 5 | この回数目以降の起動でだけ聞く。初回起動では必ず聞かない |
| `minimumDaysSinceFirstLaunch` | 7 | 初回起動から何日たったら聞くか |
| `minimumSignificantEvents` | 3（テンプレートは0） | 「成功の瞬間」が何回あったら聞くか。使わないアプリは0 |
| `cooldownDays` | 120 | 「いまいち」や答えずに閉じた後、次に聞くまでの日数 |
| `maximumDismissals` | 2 | 答えずに閉じた回数がこれに達したら、以後は聞かない |
| `oncePerVersion` | `true` | 同じversionでは1回まで |
| `presentationDelaySeconds` | 1.5 | 聞くまでの短い間 |

「良い」を選んだ後と、フィードバックを送った後は、以後は聞きません。記録（起動回数、初回起動日、成功の瞬間の回数、最後に聞いた日とversion、閉じた回数、答え）は端末の`UserDefaults`だけに置き、外部へ送りません。アプリのデータや個人の情報は記録しません。

## 派生アプリでの組み込み

1. ルート画面に`@State private var reviewPrompt = ReviewPromptCenter.live()`を置き、`.reviewPrompt(reviewPrompt)`を付けます。起動回数を数え、条件を満たせば聞きます。
2. 利用者が目的を果たした「成功の瞬間」（記録を保存した、タスクを完了した、など）で`reviewPrompt.recordSignificantEvent()`を呼び、続けて邪魔にならない時機に`await reviewPrompt.presentIfEligible()`を呼びます。成功の瞬間を使うなら、`minimumSignificantEvents`を1以上にします。
3. 次の間は`reviewPrompt.suppress("理由")`で止め、終わったら`reviewPrompt.resume("理由")`で戻します：onboarding、購入の途中、全画面の広告、エラーの表示、別のsheetやalertの表示。

## 気をつけること

- `requestReview`を呼んでも、システムの評価ポップアップが出るとは限りません。1人の利用者につき365日で最大3回ほどに制限され、利用者が設定で止めていることもあります。アプリには出たかどうかが分からないので、出た前提で処理を進めず、代わりに独自の星の画面を出しません（[RequestReviewAction](https://developer.apple.com/documentation/storekit/requestreviewaction)、[Ratings, reviews, and responses](https://developer.apple.com/app-store/ratings-and-reviews/)、[HIG: Ratings and reviews](https://developer.apple.com/design/human-interface-guidelines/ratings-and-reviews)）。
- 満足した人だけを評価へ送る形（review gating）は、Appleの方針上グレーになり得ます。質問は中立な言い方のままにし、評価や見返りを約束する言葉を足さず、「いまいち」の側にも必ずフィードバックの経路を残します。報酬と引き換えに評価を求めません（[App Review Guidelines 5.6.1](https://developer.apple.com/app-store/review/guidelines/#developer-information)）。
- Xcodeから実行したDebug buildでは、システムの評価ポップアップは毎回出ますが送信されません。TestFlightでは出ません。App Storeの配信版だけが本来の制限で動きます。
- Debug buildでは起動引数`-ReviewPromptForceShow`で、条件に関係なく起動時に質問を出せます（UI Testとスクリーンショット用）。
