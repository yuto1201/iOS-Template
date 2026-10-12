# appstore-creativeスキルでストア用の画像を作る

[appstore-creativeスキル](../.agents/skills/appstore-creative/SKILL.md)は、公式Goldie 0.3.1を土台に
App Store向け画像を装飾し、依頼された場合に撮影や動画生成を進めます（D-077）。
テンプレートから作ったアプリでは `.agents/skills/appstore-creative/` が引き継がれます。
Claude側も同じ正本へのリンク（`.claude/skills/appstore-creative`）を使います。

CodexやClaudeには、たとえば次のように依頼できます。

- 「appstore-creativeでストア用スクショのパターンを提案して」
- 「appstore-creativeでGoldieをセットアップして。スクショはまだ作らないで」
- 「appstore-creativeで、採用済みのスクショの背景だけ変えて。撮影し直さないで」

## 流れ（D-077）

1. 実画面の撮影画像（日本語・英語）をそろえる。足りなければ専用Simulatorで撮る。
2. アプリの売り、雰囲気、色、使える実画面、枚数を短い提案メモにまとめる。
3. 第1段階：3〜4パターンを、日本語iPhoneの実際の描画で比べるシートにする。各パターンは代表の生成画像を1枚だけ使う。
4. シートを見てもらい、パターンIDを1つ、または面ごとの出どころを明示した組み合わせを選んでもらう。Claudeは同じシートを非公開のArtifactとしても公開する。
5. 第2段階：選んだパターンだけ素材をすべて生成し、日英とiPhone・iPadの見本で確認する。
6. 採用した設定と生成画像を各アプリの `goldie/` にcommitし、画像を既存の準備手順へ渡す。

面の種類は、実画面＋装飾、2画面、2枚にまたがる面、連続背景、部分拡大、使用シーン、イメージ画像だけの面の7種です。
最初の3枚には必ず実画面を入れ、イメージ画像だけの面は2枚まで、全体の3分の1以下にします。
生成画像には文字、ロゴ、アプリの画面、誰か分かる顔を描かず、端末と画面は必ず撮影した本物を使います。
提案シートは `tools/appstore-creative-sheet.sh` で作り、`.artifacts/store-creative/` に置いてGitに入れません。

スキルはリポジトリの `.agents/skills/appstore-creative/` だけに置き、個人用のスキルフォルダ
（`~/.codex/skills/` など）へはコピーしません。スキルはリポジトリのtoolを使うためです。CLIの導入と設定例は
[config reference](../.agents/skills/appstore-creative/references/config.md)を参照してください。

アプリごとに `goldie/ja/` と `goldie/en-US/` の設定を分けます。Goldie 0.3.1は
最初のlocaleのUIしか撮影しないためです。出力 `out/` はGit管理外とし、採用した
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

Goldie 0.3.1の機種には、App Store用のiPhone 6.3インチ（1206×2622、D-079）とiPadがありません。
そのため、App Store用の面はすべてD-077の拡張層（`tools/appstore-creative-render.sh`）で描きます。
見出しの下に敷く生成画像と端末のない面も、拡張層が描きます。iPadの撮影は同じ撮影toolで専用iPadを使い、
日英・iPhone・iPadの各条件を一つずつ撮影します。
プレビュー動画は、スキルの案内（`references/preview-video.md`）がある場合だけ作ります。
Goldieの成功は、ネイティブアプリの検証、法務確認、提出パッケージの封印や
App Store審査完了の代わりにはなりません。

## 導入確認（2026-09-08）

- Node 25.9.0、Goldie 0.3.1、Argent 0.22.1、ffmpegを確認。
- npmの独立したruntimeへインストールし、CLI `version` / `help` が終了コード0。
- 同梱の設定例を公式 `loadConfig` で日英それぞれ読み込み、言語別出力先と
  screenshot-onlyのsceneを確認。スキルのfrontmatter検証も通過。
- この確認では撮影、画像合成、動画生成、App Store送信を実行していない。
  実アプリのflowは、そのアプリでの制作依頼時に作成・検証する。
