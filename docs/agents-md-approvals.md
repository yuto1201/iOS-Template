# AGENTS.md変更の承認記録

D-075に従い、`AGENTS.md`を書き換えるときは、変更する文面をユーザーに示し、merge前に承認を得て、その承認をIssueのコメントに記録します。このファイルは、そのIssueコメントの写しを残すための記録です。

- 新しい承認は末尾へ追記し、既存の記録は書き換えません。
- 各記録には、Issue、承認を記録したIssueコメントのURL、承認した変更の文面（`diff`）、承認後の`AGENTS.md`のSHA-256を書きます。SHA-256は、Identity bootstrapが書き換える1行目の見出しを除いた内容から計算します。
- `tools/tests/test-agents-md-approval.sh`は、現在の`AGENTS.md`が最後の記録と一致することを確かめます。記録のない`AGENTS.md`の変更は、このtestで失敗します。

## #241（2026-10-05）

- Issue: #241
- 承認を記録したIssueコメント: https://github.com/yuto1201/iOS-Template/issues/241#issuecomment-5981699173（2026-10-04T15:40:22Z）
- 承認: ユーザーが会話の中で、変更文面を示した質問に「この文面で承認」と回答した。
- 承認後の`AGENTS.md`（1行目を除く）のSHA-256: `sha256:2534c4065664ba121b72fbd1d153918efa7d7f2a41680ec08123e28b2d44d669`

承認した変更の文面:

```diff
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -23 +23,3 @@
-- ClaudeとCodexのどちらでも通常の仕様化・実装・検証・外部操作を担当できる。ただし3Dモデル、mesh、material、rig、animationの作成・生成・形状変更は例外とし、必ず[3D Asset skill](.agents/skills/ios-3d-assets/SKILL.md)を使ってCodexのexact model `gpt-6-astra`へ依頼するか、同モデル自身が実行する。Claudeや別のCodex modelは要件整理、統合、形式検証、レビューを行えるが3D asset bytesを作成しない。`gpt-6-astra`を利用できない場合は別modelへfallbackせず停止する。
+- ClaudeとCodexのどちらでも通常の仕様化・実装・検証・外部操作を担当できる。3Dモデル、mesh、material、rig、animationの作成・生成・形状変更は[3D Asset skill](.agents/skills/ios-3d-assets/SKILL.md)に従う。標準はユーザーまたはClaudeがブラウザでTripoを操作して作る経路とし、簡単なモデルや即効性を求める場合だけClaudeまたはCodexの`gpt-6-astra`（reasoning effort `xhigh`）に依頼する。Tripoのログイン、プランや課金の変更、認証情報の入力はユーザーが行う。どの経路で作ったassetも形式検証、統合、Build／Test、視覚確認を行い、Issue／PR証拠にauthoringの経路を記録する。
+- リポジトリのルートに置く文書は`AGENTS.md`だけとし、`README.md`を置かない。`README.md`はフォルダ内の説明が必要な場合（例：`docs/README.md`）だけに使う。
+- `AGENTS.md`を書き換えるときは、変更する文面をユーザーに示し、merge前に必ず承認を得て、その承認をIssueのコメントに記録する。
@@ -30 +32 @@
-- provider統合をTemplateAppやroot projectへ入れずに検証するapplication Issueは、必要な場合だけ既存AC一つをexact `Application-fixture binding: <canonical JSON>`で開始する。`tracked-fixture-v1`はschema 1の`fixtureRoot`、`project`、`route`、`schemaVersion`、`skillRoot`、`toolPaths`だけを辞書順で持ち、`fixtureRoot`を`tools/tests/fixtures/`配下へ限定してClaim時に封印する。利用Issueは#121と#122を直接Dependenciesへ置き、双方が`state:done`になるまで承認またはClaimしない。`skillRoot/application-fixture.json`はbinding JSONと改行なしでexact一致するprovider ownership markerとし、Baseのfixture、skill、tool、Claude aliasへの後付け所有権を許可しない。Headではprovider `SKILL.md`、全tool、exact Claude aliasの実体も検証する。`Config/repository-tests.json`を変更する場合はBaseのschema、head-all設定、全既存rule／testをexact保持し、safeなprovider固有rule／testだけを追加する。`shape / strict / iphone-ja`またはapplication `harden / strict / targeted`と完全かつ`visual:` mappingのない`Verification`を必須とし、workflow-only、release、binding宣言pathとroute固定の`README.md`／`Config/repository-tests.json`以外、live app／root project、削除／rename／gitlink／不正modeを許可しない。bindingなしの既存application Issueは従来経路を維持し、例外を推測しない。
+- provider統合をTemplateAppやroot projectへ入れずに検証するapplication Issueは、必要な場合だけ既存AC一つをexact `Application-fixture binding: <canonical JSON>`で開始する。`tracked-fixture-v1`はschema 1の`fixtureRoot`、`project`、`route`、`schemaVersion`、`skillRoot`、`toolPaths`だけを辞書順で持ち、`fixtureRoot`を`tools/tests/fixtures/`配下へ限定してClaim時に封印する。利用Issueは#121と#122を直接Dependenciesへ置き、双方が`state:done`になるまで承認またはClaimしない。`skillRoot/application-fixture.json`はbinding JSONと改行なしでexact一致するprovider ownership markerとし、Baseのfixture、skill、tool、Claude aliasへの後付け所有権を許可しない。Headではprovider `SKILL.md`、全tool、exact Claude aliasの実体も検証する。`Config/repository-tests.json`を変更する場合はBaseのschema、head-all設定、全既存rule／testをexact保持し、safeなprovider固有rule／testだけを追加する。`shape / strict / iphone-ja`またはapplication `harden / strict / targeted`と完全かつ`visual:` mappingのない`Verification`を必須とし、workflow-only、release、binding宣言pathとroute固定の`docs/README.md`／`Config/repository-tests.json`以外、live app／root project、削除／rename／gitlink／不正modeを許可しない。bindingなしの既存application Issueは従来経路を維持し、例外を推測しない。
```

## #280（2026-10-12）

- Issue: #280
- 承認を記録したIssueコメント: https://github.com/yuto1201/iOS-Template/issues/280#issuecomment-6119229968（2026-10-12T06:49:01Z）
- 承認: ユーザーが会話の中で、変更前と変更後の文面を示した確認に「OK、AGENTS.mdの変更も承認するので進めて」と回答した。
- 承認後の`AGENTS.md`（1行目を除く）のSHA-256: `sha256:a0c1d70c38fccc7d2e91cbb9fbe62e093366c5d42b0de6579de51f4c290bfece`

承認した変更の文面:

```diff
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -53 +53 @@
-Release PhaseはDelivery stageとは別に扱う。Phase 3は日本語iPhoneの主要機能と軽量検証、Phase 4は英語／iPadの対象拡張、Phase 5は完全品質、Phase 6は同一candidateに対する証拠適用判断と公開準備を担当する。Phase 6のApp Store用iPhone画像はGoldieを標準参照とし、`ja`／`en-US`を分離する。iPadは検証済み既存撮影経路を使い、どちらも共通Simulator資源管理、全画像監査、package／upload／submitの独立gateを維持する。
+Release PhaseはDelivery stageとは別に扱う。Phase 3は日本語iPhoneの主要機能と軽量検証、Phase 4は英語／iPadの対象拡張、Phase 5は完全品質、Phase 6は同一candidateに対する証拠適用判断と公開準備を担当する。Phase 6のApp Store用画像とプレビュー動画は、`appstore-creative`スキル（Goldieを土台とする、D-077）でパターンを提案し、ユーザーの選択を経て作り、`ja`／`en-US`を分離する。iPhone・iPadとも撮影と録画は検証済み既存撮影経路の専用deviceを使い、共通Simulator資源管理、全画像監査、package／upload／submitの独立gateを維持する。
@@ -61 +61 @@
-workflow-onlyで扱えるApp Store関連変更は、exact allowlistのlocal guidance、非認証capture producer、非認証legal-page handoff producer、非認証のread-only source-preparation producerとそのexactなversioned-format guidance／enumerated helpers／直接regression test、D-059に従い後続Issueがexact列挙するasc adapterのtool／helper／fixture／直接regression testだけです。実アプリmetadata内容、採用画像asset、signing、provider実装、TestFlight、external operationはrelease経路から移しません。
+workflow-onlyで扱えるApp Store関連変更は、exact allowlistのlocal guidance、非認証capture producer、非認証legal-page handoff producer、非認証のread-only source-preparation producerとそのexactなversioned-format guidance／enumerated helpers／直接regression test、D-059に従い後続Issueがexact列挙するasc adapterのtool／helper／fixture／直接regression test、D-077に従い後続Issueがexact列挙する非認証creative producer（スキル、拡張層、提案シート、録画と品質確認）のtool／helper／fixture／直接regression testだけです。実アプリmetadata内容、採用画像asset、signing、provider実装、TestFlight、external operationはrelease経路から移しません。
```

## #290（2026-10-13）

- Issue: #290
- 承認を記録したIssueコメント: https://github.com/yuto1201/iOS-Template/issues/290#issuecomment-6127306767（2026-10-12T15:25:57Z）
- 承認: ユーザーが会話の中で、変更文面を示した確認に「両方承認して進める」と回答した。
- 承認後の`AGENTS.md`（1行目を除く）のSHA-256: `sha256:3a3a9f63c12d6ca8ff363203d444fdc229ceba309b4d4f55faadfa4caa8b6e1d`

承認した変更の文面:

```diff
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -65,2 +65,2 @@
-- 専用 iPhone（iOS 27.0 の iPhone 17 Pro Max）、英語
-- 専用 iPhone（iOS 27.0 の iPhone 17 Pro Max）、日本語
+- 専用 iPhone（iOS 27.0 の iPhone 17 Pro）、英語
+- 専用 iPhone（iOS 27.0 の iPhone 17 Pro）、日本語
@@ -70 +70 @@
-AI検証とApp Store撮影は、repository専用の上記2台だけを使う。Templateは`iOS-Template iPhone 17 Pro Max`と`iOS-Template iPad Pro 13-inch (M5)`、派生アプリは表示名を前置した同じ機種とする。どちらもApp Storeの必須画像サイズで撮影できる機種である。deviceを作成、clone、rename、削除せず、専用device以外を起動・erase・install・test対象にしない。各caseの前に専用deviceをeraseし、testは`-parallel-testing-enabled NO`で実行する。詳細はD-063とD-070。
+AI検証とApp Store撮影は、repository専用の上記2台だけを使う。Templateは`iOS-Template iPhone 17 Pro`と`iOS-Template iPad Pro 13-inch (M5)`、派生アプリは表示名を前置した同じ機種とする。どちらもApp Storeの必須画像サイズで撮影できる機種である。deviceを作成、clone、rename、削除せず、専用device以外を起動・erase・install・test対象にしない。各caseの前に専用deviceをeraseし、testは`-parallel-testing-enabled NO`で実行する。詳細はD-063、D-070とD-079。
```

## #306（2026-10-13）

- Issue: #306
- 承認を記録したIssueコメント: https://github.com/yuto1201/iOS-Template/issues/306#issuecomment-6132861494（2026-10-12T21:23:16Z）
- 承認: ユーザーが会話の中で、変更文面を示した確認に「承認する」と回答した。最初の記録は#294のコメント（https://github.com/yuto1201/iOS-Template/issues/294#issuecomment-6129244876）で、#294は#293とともに#306へ置き換えた。
- 承認後の`AGENTS.md`（1行目を除く）のSHA-256: `sha256:2501b9293d7df33eb0c5bbac0072ad5863700b76bbbfef29f04f11f746a80156`

承認した変更の文面:

```diff
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -61 +61 @@ Release PhaseはDelivery stageとは別に扱う。Phase 3は日本語iPhoneの
-workflow-onlyで扱えるApp Store関連変更は、exact allowlistのlocal guidance、非認証capture producer、非認証legal-page handoff producer、非認証のread-only source-preparation producerとそのexactなversioned-format guidance／enumerated helpers／直接regression test、D-059に従い後続Issueがexact列挙するasc adapterのtool／helper／fixture／直接regression test、D-077に従い後続Issueがexact列挙する非認証creative producer（スキル、拡張層、提案シート、録画と品質確認）のtool／helper／fixture／直接regression testだけです。実アプリmetadata内容、採用画像asset、signing、provider実装、TestFlight、external operationはrelease経路から移しません。
+workflow-onlyで扱えるApp Store関連変更は、exact allowlistのlocal guidance、非認証capture producer、非認証legal-page handoff producer、非認証のread-only source-preparation producerとそのexactなversioned-format guidance／enumerated helpers／直接regression test、D-059に従い後続Issueがexact列挙するasc adapterのtool／helper／fixture／直接regression test、D-077に従い後続Issueがexact列挙する非認証creative producer（スキル、拡張層、提案シート、録画と品質確認）のtool／helper／fixture／直接regression test、D-079に従い後続Issueがexact列挙する提出の要件（`App Store/submission/requirements.json`）とそのfixture／直接regression testだけです。実アプリmetadata内容、採用画像asset、signing、provider実装、TestFlight、external operationはrelease経路から移しません。
```

## #318（2026-10-18）

- Issue: #318
- 承認を記録したIssueコメント: https://github.com/yuto1201/iOS-Template/issues/318#issuecomment-6245339912（2026-10-18T03:47:56Z）
- 承認: ユーザーが会話の中で、変更文面を示した確認に「承認する」と回答した。最初に示した文面（Claudeが作る経路をなくす案）は、ユーザーの指示でClaudeの経路を残す文面に直してから承認を得た。
- 承認後の`AGENTS.md`（1行目を除く）のSHA-256: `sha256:1860c848e3db9fe6db9b77403e98dca73eae05a9449abdecf7cc7f089fe0d0c3`

承認した変更の文面:

```diff
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -23 +23 @@
-- ClaudeとCodexのどちらでも通常の仕様化・実装・検証・外部操作を担当できる。3Dモデル、mesh、material、rig、animationの作成・生成・形状変更は[3D Asset skill](.agents/skills/ios-3d-assets/SKILL.md)に従う。標準はユーザーまたはClaudeがブラウザでTripoを操作して作る経路とし、簡単なモデルや即効性を求める場合だけClaudeまたはCodexの`gpt-6-astra`（reasoning effort `xhigh`）に依頼する。Tripoのログイン、プランや課金の変更、認証情報の入力はユーザーが行う。どの経路で作ったassetも形式検証、統合、Build／Test、視覚確認を行い、Issue／PR証拠にauthoringの経路を記録する。
+- ClaudeとCodexのどちらでも通常の仕様化・実装・検証・外部操作を担当できる。3Dモデル、mesh、material、rig、animationの作成・生成・形状変更は[3D Asset skill](.agents/skills/ios-3d-assets/SKILL.md)に従い、経路をモデルの複雑さで選ぶ（D-082）。ごく単純な形はClaudeがBlenderで直接作れる。単純なモデルと部品の単純な動きは、Codexの`gpt-6.1-sol`（reasoning effort `xhigh`）が作る参照画像と`gpt-6-astra`（reasoning effort `xhigh`）が作るモデルをClaudeが評価して修正を往復させて作り、複雑で高い品質が必要なモデルと骨格で動くモデルだけを、ユーザーまたはClaudeがブラウザでTripoを操作して作る。Tripoのログイン、プランや課金の変更、認証情報の入力はユーザーが行い、クレジットを使う操作は毎回ユーザーの承認を得る。どの経路で作ったassetも形式検証、統合、Build／Test、視覚確認を行い、Issue／PR証拠にauthoringの経路を記録する。
```
