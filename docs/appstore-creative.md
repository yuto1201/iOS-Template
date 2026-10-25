# appstore-creativeスキルでストア用の画像を作る

[appstore-creativeスキル](../.agents/skills/appstore-creative/SKILL.md)は、App Store向けの面を、面ごとのJSONの宣言から
HTMLとCSSで組み、headless Chromiumで書き出します（D-077、D-093）。公式Goldie 0.3.1は、撮影画像の読み込みと
下書きに使います。依頼された場合は、撮影や動画生成も進めます。
テンプレートから作ったアプリでは `.agents/skills/appstore-creative/` が引き継がれます。
Claude側も同じ正本へのリンク（`.claude/skills/appstore-creative`）を使います。

CodexやClaudeには、たとえば次のように依頼できます。

- 「appstore-creativeでストア用スクショのパターンを提案して」
- 「appstore-creativeでGoldieをセットアップして。スクショはまだ作らないで」
- 「appstore-creativeで、採用済みのスクショの背景だけ変えて。撮影し直さないで」

## 流れ（D-077、D-085、D-093）

無難な背景にスクリーンショットと見出しを置くだけでは、何ができるのか、個性と強みは何かが伝わりません。
アプリの世界、面をまたぐ物語、イラストや物で、買いたくなる画像を作ります。

1. 実画面の撮影画像（日本語・英語）をそろえる。足りなければ専用Simulatorで撮る。
2. 個性の正本 `goldie/brand.json` に、強み（実画面に結び付ける）、使う人と場面、世界観、物語の筋、色、字体とライセンス、言葉の調子、モチーフ、避けるものを書き、`tools/appstore-creative-sheet.sh check` で、強みの画面が実際の撮影画像（Goldieのraw manifest）にあることも確かめる。
3. 同じカテゴリの上位アプリを3〜5本、毎回before.clickやApp Storeから実際の画像を集め、`tools/appstore-creative-compose.sh research-sheet`で自分の案と同じ高さに並べて見比べ、使われている手法だけを記録する。参考の画像はGitに入れず、デザイン、イラスト、文言、ロゴは写さない。
4. パターンごとにスタイル仕様（色、字体、決め手の要素、装飾の上限、失敗条件など）を `brand.json` から書く。装飾の上限は、ミニマル0、エディトリアル2〜5、マキシマル8〜14。
5. イラストや物、背景の素材は数を限らず作る。AIっぽくありきたりなものは見せる前に作り直し、使う前にユーザーに見せて、明示に採用されたものだけを使う。
6. 第1段階：面を宣言して `tools/appstore-creative-compose.sh compose` で描き、品質の印とサムネイルの一覧を確かめる。3〜6案（基本は3〜4案）を、日本語iPhoneの実際の描画で比べるシートにし、いちばん良いと考える1案に「おすすめ」と理由を付ける。見出しは仮の文言で、ASOガイドができたらそれに合わせる。
7. シートを見てもらい、パターンIDを1つ、または面ごとの出どころを明示した組み合わせを選んでもらう。Claudeは同じシートを非公開のArtifactとしても公開する。
8. 第2段階：選んだパターンだけ素材をすべて生成し、日英とiPhone・iPadの見本で確認する。
9. 採用した面の宣言と生成画像を各アプリの `goldie/` にcommitし、画像を既存の準備手順へ渡す。

有料の字体、クレジットを使う生成、有料のツールが必要になったら、使う前に止めてユーザーに聞きます。

面の種類は、実画面＋装飾、2画面、2枚にまたがる面、連続背景、部分拡大、使用シーン、イメージ画像だけの面の7種です。
最初の3枚には必ず実画面を入れ、イメージ画像だけの面は2枚まで、全体の3分の1以下にします。
生成画像には文字、ロゴ、アプリの画面、誰か分かる顔を描かず、端末と画面は必ず撮影した本物を使います。
提案シートは `tools/appstore-creative-sheet.sh` で作り、`.artifacts/store-creative/` に置いてGitに入れません。

スキルはリポジトリの `.agents/skills/appstore-creative/` だけに置き、個人用のスキルフォルダ
（`~/.codex/skills/` など）へはコピーしません。スキルはリポジトリのtoolを使うためです。CLIの導入と設定例は
[config reference](../.agents/skills/appstore-creative/references/config.md)を参照してください。

アプリごとに `goldie/ja/` と `goldie/en-US/` の宣言と設定を分けます。出力 `out/` はGit管理外とし、採用した
最終画像だけを既存の `App Store/screenshots/` 準備手順へ渡します。

このスキルはPhase 6のpresentation経路です。新規raw撮影は
`tools/with-ios-simulator-lock.sh`の内側で`tools/capture-appstore-screenshots.sh`を
実行し、`tools/lib/ios-simulator-resource.rb`がleaseするrepository専用の2台だけを
使います（D-063）。leaseの前にeraseし、終了時にshutdownし、端末を作成・削除しません。
D-070とD-079により専用の2台（iPhone 17 ProとiPad Pro 13-inch (M5)）はApp Storeの必須画像サイズの機種なので、撮影画像を合成や
切り抜きなしで使い、locale別にGoldieへimportします。Goldie 0.3.1の`capture`は
UDIDを指定できず、Goldie自身の機種表の名前と一致する端末を選んでappを再installするため、
preview動画を含めて使いません。画像と診断を端末外へ保存し、leaseの解除receiptを
確認してから次の条件へ進みます。

App Store用の面（iPhone 6.3インチの1206×2622、D-079、とiPad 13インチの2064×2752）は、
描画器（`tools/appstore-creative-compose.sh compose`、D-093）が描きます。背景、見出し、端末、拡大カード、
採用した素材の層を宣言し、端末の枠は面の解像度で描きます。描画器は外部へ通信しません。
2画面と2枚にまたがる面、Product page headerは、拡張層（`tools/appstore-creative-render.sh`）で描きます。iPadの撮影は同じ撮影toolで専用iPadを使い、
日英・iPhone・iPadの各条件を一つずつ撮影します。
プレビュー動画は、スキルの案内（`references/preview-video.md`）がある場合だけ作ります。
描画の成功は、ネイティブアプリの検証、法務確認、提出パッケージの封印や
App Store審査完了の代わりにはなりません。

## 導入確認（2026-09-08）

- Node 25.9.0、Goldie 0.3.1、Argent 0.22.1、ffmpegを確認。
- npmの独立したruntimeへインストールし、CLI `version` / `help` が終了コード0。
- 同梱の設定例を公式 `loadConfig` で日英それぞれ読み込み、言語別出力先と
  screenshot-onlyのsceneを確認。スキルのfrontmatter検証も通過。
- この確認では撮影、画像合成、動画生成、App Store送信を実行していない。
  実アプリのflowは、そのアプリでの制作依頼時に作成・検証する。
