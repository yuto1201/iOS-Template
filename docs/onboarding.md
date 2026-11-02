# 初回起動のオンボーディング

アプリを初めて開いた人に、数枚のページで価値を伝え、必要なら1つか2つ質問し、通知の許可を前置きしてから、アプリのルート画面へ進めてもらう部品です（#483）。全アプリが持つ標準機能で（[D-099](../specs/decisions.md#d-099-初回起動のオンボーディングを全アプリ必須の標準機能にする)）、見た目と流れはページ送り型（OB-A、[D-102](../specs/decisions.md#d-102-初回起動のオンボーディングのui方向をページ送り型ob-aにする)、[`specs/product.md` §4.6](../specs/product.md#46-初回起動のオンボーディング)）です。

部品はアプリのフォルダの`Features/Onboarding/`にあり、テンプレートでは`ContentView`の`.onboarding(_:reviewPrompt:)`で組み込んでいます。

## 画面と操作

- 全ページを同じ形の全画面ページとして順に並べます。上に戻るとSkip、中央に絵と見出しと短い本文、下にページの点と主ボタンを置きます。
- 完了以外の全ページにSkip、2枚目以降の全ページ（完了を含む）に戻るがあります。
- 横のスワイプとボタンの両方で進み、戻ります。選択肢のページでは前へ進むスワイプを止め、「次へ」でだけ進みます。許可の前置きのページを前へスワイプしたときは「今はしない」と同じで、ダイアログを出しません。
- 選択肢は選択印のついた行のリストです。選ぶまで「次へ」は押せず、Skipはいつでも押せます。
- 許可の前置きは「通知を許可する」と「今はしない」を出します。「通知を許可する」でだけシステムの許可ダイアログを出します。拒否されたら同じページに「設定アプリからいつでも変えられる」注記を出し、主ボタンを「次へ」にします。「今はしない」とSkipではダイアログを出しません。
- 完了のページの「はじめる」で完了を記録し、ルート画面へ進みます。Skipも完了として記録します。
- ページの点は飾りで、VoiceOverは「3ページ中2ページ目」のように位置を読みます。選んだ行は選択中として読まれます。スワイプに頼らず、すべてボタンで操作できます。文字を大きくすると絵が小さくなり、ページの中がスクロールし、主ボタンは画面の中に残ります。操作は44pt以上です。ページは横にすべって入れ替わり、Reduce Motionのときは動かさずに薄く入れ替わります。
- iPadでは、中央の幅を絞った列に同じ順序で置きます。

## 設定（`OnboardingConfig.json`）

各アプリが自分のページを宣言します。

| 項目 | 意味 |
| --- | --- |
| `enabled` | `false`で機能ごと無効。外すのはユーザーが明示した場合だけ（D-099） |
| `version` | 宣言の版（1以上、省略すると1）。完了したときの版を記録する |
| `pages` | 3〜5件のページ |
| `legacyCompletionKeys` | 既存アプリの完了の鍵（`UserDefaults`のBool）。どれかが`true`なら完了済みとして扱う |

各ページは次を持ちます。

| 項目 | 意味 |
| --- | --- |
| `id` | 安定した英小文字の名前（例：`welcome`、`purpose`）。答えはこの名前で保存する |
| `kind` | `value`（価値の説明）、`choice`（選択肢）、`permissionPrimer`（許可の前置き）、`completion`（完了） |
| `titleKey`、`messageKey` | 見出しと本文の文言の鍵（`Localizable.xcstrings`） |
| `imageName` | 任意。Asset Catalogの画像の名前。無いときはページの種類の記号を出す |

`choice`は、`selection`（`single`または`multiple`）、`options`（2〜6件。`id`、`titleKey`、任意の`subtitleKey`と`imageName`）、`usedFor`（答えをアプリのどこで使うかの説明。空にできない）も持ちます。比較で示したのは1つを選ぶ形だけなので、`multiple`を使うかは各アプリのIssueで決めます。`permissionPrimer`は`permission`（いまは`notifications`だけ）も持ちます。

文言の鍵はJSONから読むので、Xcodeの文字列の抽出では見つかりません。`Localizable.xcstrings`へ手で足し、`extractionState`を`manual`にします。日本語と英語の両方を入れます。

### 決まり

- ページは3〜5枚、質問（`choice`）は0〜2問、最後が`completion`で、`completion`はちょうど1枚。
- `id`は重ならない。選択肢の`id`もページの中で重ならない。
- `choice`の`usedFor`は空にしない。答えをアプリの中で使わない質問は置かない（D-099）。
- 文言の鍵がすべて`Localizable.xcstrings`にある。

壊れたファイル、決まりに合わない宣言、ファイルが無いときは、機能を無効にしてアプリをそのまま動かします。Debug buildではassertで止めて知らせます。

## 保存と答え

記録は端末の`UserDefaults`（鍵`onboarding.record`）だけに置き、外部へ送りません。記録するのは、完了したかと時刻、完了したときの`version`、各質問で選んだoptionの`id`だけです。自由入力や個人の情報は記録しません（審査ガイドライン5.1.1）。

- `answers(for: "<ページのid>")`：完了したオンボーディングで選んだoptionの`id`の配列。答えていない質問は空。
- `onCompleted`：オンボーディングが閉じたときに一度呼ばれ、`OnboardingAnswers`（ページの`id`ごとのoptionの`id`と、Skipしたか）を受け取る。
- Skipでは、それまでに「次へ」で答えた質問の答えだけが渡り、残りは未回答のままです。Skipしたページで選びかけていた答えは渡りません。

## 派生アプリでの組み込み

1. ルート画面に`@State private var onboarding = OnboardingCenter.live()`を置き、`.onboarding(onboarding, reviewPrompt: reviewPrompt)`を付けます。評価の依頼（[review-prompt.md](review-prompt.md)）を使わないアプリは`reviewPrompt: nil`にします。
2. 答えを使う画面で`onboarding.answers(for:)`を読み、閉じた直後に反映したいときは`onboarding.onCompleted`で受け取ります。テンプレートの見本は、質問`purpose`の答えでルート画面の一言を変えています（`ContentView`）。
3. `OnboardingConfig.json`と文言を、そのアプリのPhase 1で決めた中身（伝える価値、質問と答えの使い道、許可の前置きの有無）に置き換えます。
4. 既にオンボーディングを持つアプリでは、その完了の鍵（例：CafLogとSubLogの`hasCompletedOnboarding`、Flowerの`onboarding.hintsShown`）を`legacyCompletionKeys`へ入れます。既存の利用者にもう一度出しません。
5. 既存のUI Testが起動直後のルート画面を前提にしているときは、起動引数に`-OnboardingSkip`を足します。

公開済みのアプリへ入れる、または作りを大きく変えるときは、D-099どおりそのアプリの対象releaseのPhase 1とPhase 2をユーザーに再承認してもらいます。

## 起動引数

| 引数 | 効くビルド | 動き |
| --- | --- | --- |
| `--appstore-screenshot` | すべて | 出さず、完了も記録しない |
| `--appstore-screenshot --onboarding-page <pageId>` | すべて | 指定のページから出す。記録しない |
| `-OnboardingForceShow` | Debugだけ | 完了済みでも出す |
| `-OnboardingSkip` | Debugだけ | 完了済みとして扱い、記録しない |

`--appstore-screenshot`はApp Store撮影（`tools/capture-appstore-screenshots.sh`）が`App Store/screenshots/states.json`の`launchArguments`から付けます。撮影をReleaseのbuildで行うかは#476との関係でまだ決まっていないため、この2つはDebugに限らず効きます。オンボーディング自体を撮るときは、`states.json`に`["--appstore-screenshot", "--onboarding-page", "purpose"]`のような状態を1件足します。

## 評価の依頼との関係

オンボーディングが出ている間は、評価の依頼を`reviewPrompt.suppress("onboarding")`で止め、閉じたら`resume("onboarding")`で戻します。アプリがほかの理由で止めている間（購入の途中など）は、その理由が残ります。初回起動では評価の依頼はもともと出ません。
