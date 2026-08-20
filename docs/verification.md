# iOS verification

## 1. 目的

AIが「コード上は正しそう」ではなく、Build、Test、操作、見た目を実測したうえでIssueを完了できるようにします。物理端末の最終判断はユーザーが後から行います。

## 2. 環境の解決

`tools/resolve-simulator-matrix.sh` はIssueバッチ開始時に一度だけ実行します。

1. 使用するXcodeを確認する。必要な場合は `DEVELOPER_DIR` をコマンド単位で指定する。
2. Xcode versionとbuildを記録する。
3. 利用可能かつ最新のiOS Runtimeを選ぶ。
4. Runtime内の利用可能なDevice TypeからiPhone Proを選ぶ。`Pro Max` は除外する。
5. 同じRuntimeから最新世代のiPad Airを選ぶ。同世代に11-inchと13-inchがあれば13-inchを選ぶ。
6. 英語と日本語を組み合わせ、4行のmatrixを作る。
7. `.artifacts/batches/${batchId}/simulator-matrix.json` へ保存する。

名前に合う端末が見つからない場合、別端末へ自動フォールバックしません。`blocked:environment` として、利用可能な候補一覧を報告します。

## 3. 固定されるmatrix

```json
{
  "schemaVersion": 1,
  "batchId": "2026-08-21-settings",
  "resolvedAt": "2026-08-21T12:00:00+09:00",
  "xcode": {
    "path": "/Applications/Xcode.app/Contents/Developer",
    "version": "26.5",
    "build": "17F42"
  },
  "runtime": {
    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    "version": "26.5"
  },
  "cases": [
    {"id": "iphone-en", "family": "iPhone", "deviceType": "iPhone 17 Pro", "locale": "en_US", "language": "en"},
    {"id": "iphone-ja", "family": "iPhone", "deviceType": "iPhone 17 Pro", "locale": "ja_JP", "language": "ja"},
    {"id": "ipad-en", "family": "iPad", "deviceType": "iPad Air 13-inch (M3)", "locale": "en_US", "language": "en"},
    {"id": "ipad-ja", "family": "iPad", "deviceType": "iPad Air 13-inch (M3)", "locale": "ja_JP", "language": "ja"}
  ]
}
```

この値は形式例です。実際のversionとDevice Typeはそのバッチで取得した値を使います。

## 4. 実行段階

### Stage A: 静的確認

- 変更ファイルとIssue Scopeの対応
- 追跡対象への秘密混入スキャン
- 日本語・英語の文字列不足
- Compile-time warningの差分

### Stage B: Build and unit tests

- 現在のHead SHAを取得
- Cleanである必要はないが、ユーザーの未関連変更を含めない
- Issueが影響するschemeをBuild
- Unit Testを実行
- 失敗、Skip、件数を記録
- worktreeごとのDerivedDataを使用

BuildとUnit Testは同じHead SHAにつき一度実行し、4つのlocaleごとに重複実行しません。

### Stage C: UI and acceptance matrix

4条件それぞれで次を行います。

1. Simulatorを対象RuntimeとDevice Typeで準備する。
2. LocaleとLanguageを明示してアプリを起動する。
3. Issueの受け入れ操作を実行する。
4. 期待するUI要素と状態を機械判定する。
5. 主要状態のスクリーンショットを保存する。
6. crash、freeze、layout overflow、欠けた翻訳を確認する。

UI変更でないIssueでも、起動や依存関係へ影響する場合は4条件のsmoke testを行います。純粋な文書変更はSimulator検証を `not-applicable` とし、その理由を記録できます。

### Stage D: AI visual evaluation

AIはスクリーンショットごとに次を評価します。

- 受け入れ条件との一致
- 切れ、重なり、意図しない余白
- iPhoneとiPadの情報階層
- 日本語と英語の文字量差
- Dynamic Typeとタップ領域への明白な問題
- Sheet、alert、keyboard、orientationなど対象状態
- 参照デザインがある場合の差異

主開発モデルが一次評価し、反対モデルレビューへ画像を含めます。見た目の好みだけで仕様を増やしません。

### Stage E: Evidence

`.artifacts/issues/${issueNumber}/${headSha}/verify.json` を生成します。

```json
{
  "schemaVersion": 1,
  "status": "passed",
  "changeClassification": "application-code",
  "reason": null,
  "issue": 42,
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "issueContract": {
    "path": ".artifacts/issues/42/issue-contract.json",
    "digest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e"
  },
  "matrixFile": ".artifacts/batches/2026-08-21-settings/simulator-matrix.json",
  "matrixDigest": "sha256:490d32bf9174b57fb9b05a00e0231d22082e4a9576b0377f0df2641d96349d0b",
  "executionRoute": "xcodebuild-simctl",
  "xcode": {
    "path": "/Applications/Xcode.app/Contents/Developer",
    "version": "26.5",
    "build": "17F42"
  },
  "build": {"status": "passed", "scheme": "TemplateApp", "warningsAdded": 0},
  "tests": {"status": "passed", "passed": 24, "failed": 0, "skipped": 0},
  "cases": [
    {"id": "iphone-en", "status": "passed", "screenshot": "iphone-en/settings.png"},
    {"id": "iphone-ja", "status": "passed", "screenshot": "iphone-ja/settings.png"},
    {"id": "ipad-en", "status": "passed", "screenshot": "ipad-en/settings.png"},
    {"id": "ipad-ja", "status": "passed", "screenshot": "ipad-ja/settings.png"}
  ],
  "visualEvaluation": {"status": "passed", "findings": []},
  "acceptanceEvidence": [
    {
      "id": "AC-1",
      "status": "passed",
      "evidence": ["tests:TemplateAppTests/NotificationSettingsTests", "cases:iphone-en,iphone-ja,ipad-en,ipad-ja"]
    },
    {
      "id": "AC-2",
      "status": "passed",
      "evidence": ["cases:iphone-en,iphone-ja,ipad-en,ipad-ja"]
    }
  ],
  "completedAt": "2026-08-21T13:00:00+09:00"
}
```

`schemaVersion: 1` のapplication変更で必須となるfieldは、上の例にある `status`、`changeClassification`、`reason`、IssueとSHA、Issue contract path/digest、matrix path/digest、execution route、Xcode、Build、Tests、cases、visual evaluation、acceptance evidence、completed timeです。GitHubとproviderのpreflightは外部操作直前の証拠なのでverify.jsonへ含めず、pre-merge gateが別artifactとして検査します。

文書だけの変更では `status`、Build、Tests、visual evaluationを`not-applicable`、`changeClassification`を`documentation-only`、`reason`を空でない説明、`matrixFile`と`matrixDigest`と`xcode`をnull、`executionRoute`を`none`、`cases`を空配列にします。`AC-*`にはリンク検査や文書整合性検査の証拠を対応させます。アプリコード、Xcode project、Asset、Localization、Entitlement、Configurationの変更が一つでもあれば文書例外は使えません。文書例外はSimulatorやiOS Runtimeを必要としません。

PR本文にはverify.jsonの要約とdigestを記載します。巨大なログと一時的なSimulatorデータはGitへ入れません。

## 5. 実行手段

Codex環境でXcodeBuildMCPが利用できる場合、Project、scheme、Simulatorのsession defaultsを確認したうえでBuild、Test、UI操作、Screenshotを行います。利用できない場合は `xcodebuild` と `xcrun simctl` の決定論的なtoolsスクリプトを使います。

どちらの経路でも同じverify.jsonを生成し、実行経路を記録します。ツールが使えないことをTest成功へ読み替えません。

## 6. 排他制御

ソース実装は独立Issueなら並行化できますが、Simulatorを使う検証段階は既定で1ジョブずつ実行します。これにより、Boot状態、Locale、アプリデータ、Screenshotの取り違えを防ぎます。

各worktreeは専用DerivedDataを使います。検証中にHead SHAが変わった場合、結果を破棄して新しいSHAでやり直します。

## 7. Pre-merge条件

`tools/premerge-gate.sh` は次を検査します。

- 現在のHead SHA = verify.jsonのheadSha
- 現在のHead SHA = review.jsonのheadSha
- verify status = passedまたは正当なnot-applicable
- review verdict = approved
- 重大Finding = 0
- Acceptance criteriaの証拠欠落 = 0
- Issue本文の全 `AC-*` が `acceptanceEvidence` に一度ずつ存在
- Codexがmerge直前に更新した `.artifacts/issues/${issueNumber}/github-preflight.json` とそのdigestが存在
- Provider外部操作がある場合、`.artifacts/issues/${issueNumber}/provider-preflights/${provider}.json` とそのdigestが存在

一つでも不一致ならマージしません。
