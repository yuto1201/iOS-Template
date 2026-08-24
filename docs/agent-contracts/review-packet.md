# Opposite-model review contract

## 1. 目的

主開発モデルとは異なるモデルが、現在のHead SHAに対して受け入れ条件、実装、検証証拠をread-onlyで評価します。自己承認と、古い差分に対する承認を防ぎます。

## 2. Review packet

`tools/prepare-review-packet.sh` は、信頼済みBaseと現在のHeadから決定論的なactual Git diffを生成し、canonical verify.jsonとそのvisual evidenceをdescriptor-boundで読み、一つのschema v2 packetへ封印します。Acceptance criteriaとspec anchorsはIssue contractから読み、すべてexact bytesのdigestで固定します。schema v1は通常レビューの既存成果物を読む場合に限る互換形式で、pre-merge gateは受理しません。

```json
{
  "schemaVersion": 2,
  "issue": 42,
  "primaryModel": "codex",
  "reviewerModel": "claude",
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "verifySha": "0123456789abcdef0123456789abcdef01234567",
  "issueContract": {
    "path": ".artifacts/issues/42/issue-contract.json",
    "digest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e"
  },
  "specAnchors": ["specs/features/settings.md#notification-time"],
  "acceptanceCriteria": [
    {"id": "AC-1", "text": "通知時刻を保存できる"},
    {"id": "AC-2", "text": "日本語と英語で時刻が正しく表示される"}
  ],
  "diff": {
    "path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/review.diff",
    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "verify": {
    "path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/verify.json",
    "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  },
  "imageFiles": [
    {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/iphone-en/settings.png", "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
    {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/iphone-ja/settings.png", "digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
    {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/ipad-en/settings.png", "digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},
    {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/ipad-ja/settings.png", "digest": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}
  ]
}
```

例のパスと値は形式を示します。実際のIssue、仕様、SHA、画像を使用します。

## 3. Reviewer questions

レビューでは次の順に確認します。

1. 各受け入れ条件に実装と証拠があるか。
2. 仕様外の振る舞いを追加・変更していないか。
3. correctness、state、concurrency、persistence、securityの問題がないか。
4. iPhone、iPad、日本語、英語で明らかなUI問題がないか。
5. Testが重要な失敗経路を検出できるか。
6. Verify結果に未検証の事実主張がないか。
7. 現在のHead SHAを承認してよいか。

スタイル上の好みだけをBlocking findingにしません。

## 4. Result schema

```json
{
  "schemaVersion": 2,
  "issue": 42,
  "reviewerModel": "claude",
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "verifySha": "0123456789abcdef0123456789abcdef01234567",
  "issueContractDigest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e",
  "reviewPacketDigest": "sha256:9999999999999999999999999999999999999999999999999999999999999999",
  "verdict": "approved",
  "findings": [],
  "acceptanceAssessment": [
    {"id": "AC-1", "status": "supported", "evidence": ["verify.json#acceptanceEvidence/0"]},
    {"id": "AC-2", "status": "supported", "evidence": ["verify.json#cases"]}
  ],
  "reviewedAt": "2026-08-21T13:15:00+09:00"
}
```

`verdict` は `approved` または `changes-requested` のどちらかです。

Findingは次を含みます。

```json
{
  "severity": "high",
  "category": "correctness",
  "file": "TemplateApp/Settings/NotificationSettings.swift",
  "line": 38,
  "title": "保存値が再起動後に復元されない",
  "evidence": "load() が初期値だけを返し、保存先を読んでいない",
  "requiredChange": "保存先から値を復元する実装と再起動テストを追加する"
}
```

Severity:

- `critical`: データ消失、秘密漏えい、権限逸脱、主要機能不能
- `high`: 受け入れ条件違反、Crash、重大な誤動作
- `medium`: 実在する品質問題。今回のScopeで修正可能
- `low`: 非Blockingの改善提案

`critical`、`high`、未解決の`medium`があれば `changes-requested` とします。

Reviewerは各 `AC-*` について `supported` または `unsupported` と証拠参照を返します。`unsupported` が一つでもあれば `approved` にできません。

`reviewPacketDigest` はreviewerが実際に読んだ `review-packet.json` の全byte列に対するSHA-256です。result publicationはこのdigestとcanonical packetのexact bytesが一致する間だけ行い、packet path、inode、bytesがpublication中に変われば失敗します。

Result schemaにrequester-controlledな「実行済み」fieldは追加しません。固定launcherはchild process完了とResult検証の後、別artifact `review-receipt.json` を発行します。receiptはschema version、Issue/Head、primary/opposite model、`cross-model-review.sh` と実際のreviewer launcherのpath/exact bytes digest、packet exact digest、validated result exact digest、published `review.json` exact digest、started/completed timestamp、exit status 0だけを持ちます。canonical reviewが先に存在しても、このexact receiptがなければレビュー実行済みとは扱いません。

## 5. Sealing interface

Packetは次で準備します。

```bash
tools/prepare-review-packet.sh \
  --primary codex \
  --issue 42 \
  --base-sha "${BASE_SHA}" \
  --head-sha "${HEAD_SHA}"
```

producerは `/usr/bin/git diff --binary --full-index --no-ext-diff --no-textconv --no-renames` の固定形でexact Base..Head `review.diff` を生成します。verifyの `visualEvaluation.cases[].images[]` をcase/image順に平坦化したpath/digestだけが `imageFiles` です。文書例外では空配列です。verify、画像、contractをsingle-linkかつno-followで開いたdescriptorをpublication完了まで保持し、path/inode/bytes、Git Head、actual diffをpublication前後で再検証します。

pre-merge gateのdescriptor-owning callerは、まず次を呼びます。

```ruby
references = IOSTemplate::ReviewContract.strict_references!(
  packet_bytes: held_packet.bytes, issue: issue, head_sha: head_sha
)
```

返されたcanonical diff/verify/image leafをcaller自身が開いたまま保持し、最後に次を呼びます。

```ruby
IOSTemplate::ReviewContract.validate!(
  strict: true,
  packet_bytes: held_packet.bytes,
  result_bytes: held_result.bytes,
  verify_bytes: held_verify.bytes,
  contract_bytes: held_contract.bytes,
  diff_bytes: held_diff.bytes,
  image_bytes: ordered_held_image_bytes,
  actual_diff_bytes: independently_generated_base_head_diff,
  primary: primary, issue: issue, base_sha: base_sha, head_sha: head_sha,
  require_temporal_order: true
)
```

このpure validation interfaceはartifact pathを再openしません。callerは戻り値を利用し終えるまでdescriptorを保持し、終了直前に各path identity/bytesを再検証します。strict modeはschema v1、bogus/empty diff、same-Head verify差し替え、画像差し替え、packet/result不一致をすべて拒否します。Gateはさらに `review-receipt.json` をsingle-link/no-followで保持し、current packet/review bytesとlauncher identityを照合します。

## 6. 呼び出し

- Codex primary -> Claudeを非対話read-onlyで呼ぶ
- Claude primary -> Codexをread-only sandboxで呼ぶ
- Timeout: 10分
- Reviewerはファイル編集、外部操作、commit、pushを行わない
- Reviewerが環境や認証状態を推測した場合、主エージェントは実環境で再確認する

Reviewerが利用不能なら `blocked:review` です。別モデルへの無断置換や主開発モデル自身の承認は行いません。
