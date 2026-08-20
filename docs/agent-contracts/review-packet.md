# Opposite-model review contract

## 1. 目的

主開発モデルとは異なるモデルが、現在のHead SHAに対して受け入れ条件、実装、検証証拠をread-onlyで評価します。自己承認と、古い差分に対する承認を防ぎます。

## 2. Review packet

`cross-model-review` は次の情報を一つのpacketへまとめます。Acceptance criteriaとspec anchorsは、同じpacket内のIssue contractから読み、digest一致を検証します。

```json
{
  "schemaVersion": 1,
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
  "diffFile": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/review.diff",
  "verifyFile": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/verify.json",
  "imageFiles": [
    "iphone-en/settings.png",
    "iphone-ja/settings.png",
    "ipad-en/settings.png",
    "ipad-ja/settings.png"
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
  "schemaVersion": 1,
  "issue": 42,
  "reviewerModel": "claude",
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "verifySha": "0123456789abcdef0123456789abcdef01234567",
  "issueContractDigest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e",
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

## 5. 呼び出し

- Codex primary -> Claudeを非対話read-onlyで呼ぶ
- Claude primary -> Codexをread-only sandboxで呼ぶ
- Timeout: 10分
- Reviewerはファイル編集、外部操作、commit、pushを行わない
- Reviewerが環境や認証状態を推測した場合、主エージェントは実環境で再確認する

Reviewerが利用不能なら `blocked:review` です。別モデルへの無断置換や主開発モデル自身の承認は行いません。
