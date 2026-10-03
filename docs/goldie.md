# CodexでGoldieを使う

[Goldieスキル](../.agents/skills/goldie/SKILL.md)は、公式Goldie 0.3.1を利用して
App Store向け画像を装飾し、依頼された場合に撮影や動画生成を進めます。
テンプレートから作ったアプリでは `.agents/skills/goldie/` が引き継がれます。
Claude側も同じ正本へのリンクを使います。

Codexには、たとえば次のように依頼できます。

- 「Goldieをセットアップして。スクショはまだ作らないで」
- 「Goldieで、この実際のアプリ画像に日本語の見出しを付けて」
- 「Goldieでストア用スクショを日本語と英語で作って。動画は不要」
- 「Goldieで背景だけ変えて。撮影し直さないで」

このMacでは個人スキル `~/.codex/skills/goldie/` からも利用できます。
別のMacでは同じスキルフォルダをその場所にコピーします。既存スキルがある場合は
差分を確認し、上書きしません。CLIの導入と設定例は
[config reference](../.agents/skills/goldie/references/config.md)を参照してください。

アプリごとに `goldie/ja/` と `goldie/en-US/` の設定を分けます。Goldie 0.3.1は
最初のlocaleのUIしか撮影しないためです。出力 `out/` はGit管理外とし、採用した
最終画像だけを既存の `App Store/screenshots/` 準備手順へ渡します。

GoldieはPhase 6のiPhone 6.9インチ用presentation経路です。新規raw撮影は
`tools/with-ios-simulator-lock.sh`の内側で`tools/capture-appstore-screenshots.sh`を
実行し、`tools/lib/ios-simulator-resource.rb`がleaseするrepository専用の2台だけを
使います（D-063）。leaseの前にeraseし、終了時にshutdownし、端末を作成・削除しません。
D-070により専用の2台はApp Storeの必須画像サイズの機種なので、撮影画像を合成や
切り抜きなしで使い、locale別にGoldieへimportします。Goldie 0.3.1の`capture`は
UDIDを指定できず、名前が`iPhone 17 Pro Max`の端末を選んでappを再installするため、
preview動画を含めて使いません。画像と診断を端末外へ保存し、leaseの解除receiptを
確認してから次の条件へ進みます。

現在のGoldieはiPhone 6.9インチ向けです。iPadは同じ撮影toolで専用iPadを使い、
日英・iPhone・iPadの各条件を一つずつ撮影します。
Goldieの成功は、ネイティブアプリの検証、法務確認、提出パッケージの封印や
App Store審査完了の代わりにはなりません。

## 導入確認（2026-09-08）

- Node 25.9.0、Goldie 0.3.1、Argent 0.22.1、ffmpegを確認。
- npmの独立したruntimeへインストールし、CLI `version` / `help` が終了コード0。
- 同梱の設定例を公式 `loadConfig` で日英それぞれ読み込み、言語別出力先と
  screenshot-onlyのsceneを確認。スキルのfrontmatter検証も通過。
- この確認では撮影、画像合成、動画生成、App Store送信を実行していない。
  実アプリのflowは、そのアプリでの制作依頼時に作成・検証する。
