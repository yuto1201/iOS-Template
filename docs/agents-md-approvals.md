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
