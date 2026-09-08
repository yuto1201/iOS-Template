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

現在のGoldieはiPhone 6.9インチ向けです。iPadは既存のApp Store撮影手順を使います。
Goldieの成功は、ネイティブアプリの検証、法務確認、提出パッケージの封印や
App Store審査完了の代わりにはなりません。

## 導入確認（2026-09-08）

- Node 25.9.0、Goldie 0.3.1、Argent 0.22.1、ffmpegを確認。
- npmの独立したruntimeへインストールし、CLI `version` / `help` が終了コード0。
- 同梱の設定例を公式 `loadConfig` で日英それぞれ読み込み、言語別出力先と
  screenshot-onlyのsceneを確認。スキルのfrontmatter検証も通過。
- この確認では撮影、画像合成、動画生成、App Store送信を実行していない。
  実アプリのflowは、そのアプリでの制作依頼時に作成・検証する。
