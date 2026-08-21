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
    {"id": "iphone-en", "family": "iPhone", "deviceType": {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "name": "iPhone 17 Pro"}, "locale": "en_US", "language": "en"},
    {"id": "iphone-ja", "family": "iPhone", "deviceType": {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "name": "iPhone 17 Pro"}, "locale": "ja_JP", "language": "ja"},
    {"id": "ipad-en", "family": "iPad", "deviceType": {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "name": "iPad Air 13-inch (M3)"}, "locale": "en_US", "language": "en"},
    {"id": "ipad-ja", "family": "iPad", "deviceType": {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "name": "iPad Air 13-inch (M3)"}, "locale": "ja_JP", "language": "ja"}
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

### Stage D.1: 二段階の証拠公開

application検証は、実行と視覚承認を分けます。最初のcommandは現在のGit Head、信頼済みBase、canonical Issue contract、完全な固定matrixをXcode commandより先に検証します。Buildを1回、unit testを1回だけ実行し、その後4caseを直列実行します。

```bash
tools/verify-ios-issue.sh \
  --issue 42 \
  --expected-base "${BASE_SHA}" \
  --issue-contract .artifacts/issues/42/issue-contract.json \
  --matrix .artifacts/batches/settings-2026-08-21/simulator-matrix.json \
  --project ExampleApp.xcodeproj \
  --scheme ExampleApp
```

runnerは `/tmp/ios-template-verify/${worktreeId}/issue-42/${headSha}/` の `DerivedData`、`Build.xcresult`、`Tests.xcresult` だけを使い、Repository内へDerivedDataやresult bundleを作りません。`/Applications/Xcode.app/Contents/Developer` が有効なら優先し、それ以外は `xcode-select -p` のpathで `xcodebuild -version` が成功した場合だけ使います。解決は1回だけ行い、すべての `xcodebuild` と `xcrun` へcommand-scoped `DEVELOPER_DIR` を渡します。callerが実行binaryを環境変数で差し替えるinterfaceは持ちません。

実行成功時はfinal結果ではなく、canonical `.artifacts/issues/42/${headSha}/verify-draft.json` をatomic publishします。次がschema version 1のexact internal schemaです。Objectは例にないkeyを持てず、`cases` と `acceptanceEvidence` はcontractの順序を保ちます。`mechanicalCheck` は実行した `test:${testIdentifier}` または `assertion:launch-succeeded`、acceptance evidenceは空でない実在stage/case参照です。

```json
{
  "schemaVersion": 1,
  "status": "awaiting-visual-review",
  "issue": 42,
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "issueContract": {"path": ".artifacts/issues/42/issue-contract.json", "digest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e"},
  "matrixFile": ".artifacts/batches/settings-2026-08-21/simulator-matrix.json",
  "matrixDigest": "sha256:490d32bf9174b57fb9b05a00e0231d22082e4a9576b0377f0df2641d96349d0b",
  "executionRoute": "xcodebuild-simctl",
  "xcode": {"path": "/Applications/Xcode.app/Contents/Developer", "version": "26.5", "build": "17F42"},
  "build": {"status": "passed", "scheme": "ExampleApp", "warningsAdded": 0},
  "tests": {"status": "passed", "passed": 24, "failed": 0, "skipped": 0},
  "cases": [
    {"id": "iphone-en", "status": "passed", "screenshot": "iphone-en/screenshot.png", "mechanicalCheck": "test:ExampleAppUITests/SmokeTests/testLaunch"},
    {"id": "iphone-ja", "status": "passed", "screenshot": "iphone-ja/screenshot.png", "mechanicalCheck": "assertion:launch-succeeded"},
    {"id": "ipad-en", "status": "passed", "screenshot": "ipad-en/screenshot.png", "mechanicalCheck": "test:ExampleAppUITests/SmokeTests/testLaunch"},
    {"id": "ipad-ja", "status": "passed", "screenshot": "ipad-ja/screenshot.png", "mechanicalCheck": "assertion:launch-succeeded"}
  ],
  "acceptanceEvidence": [
    {"id": "AC-1", "evidence": ["stage:build", "stage:unit-tests", "cases:iphone-en,iphone-ja,ipad-en,ipad-ja"]}
  ],
  "workspaceArtifacts": {
    "derivedDataPath": "/tmp/ios-template-verify/worktree-id/issue-42/0123456789abcdef0123456789abcdef01234567/DerivedData",
    "buildResultBundlePath": "/tmp/ios-template-verify/worktree-id/issue-42/0123456789abcdef0123456789abcdef01234567/Build.xcresult",
    "testResultBundlePath": "/tmp/ios-template-verify/worktree-id/issue-42/0123456789abcdef0123456789abcdef01234567/Tests.xcresult"
  },
  "executionCompletedAt": "2026-08-21T12:55:00+09:00"
}
```

Task 5のAI評価はcanonical `.artifacts/issues/42/${headSha}/visual-result.json` を次のexact schemaで書きます。`draft.path` は同じIssue/Headのcanonical path、`draft.digest` はdraftのexact bytesです。4件すべての `id` と `screenshot` はdraftに一致し、承認時はtop-levelと各caseの `findings` が空です。

```json
{
  "schemaVersion": 1,
  "status": "approved",
  "issue": 42,
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "draft": {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/verify-draft.json", "digest": "sha256:4ae755fb899a15125dfe7db017761abe901e1de00bf266894157826c827a3f2f"},
  "cases": [
    {"id": "iphone-en", "status": "approved", "screenshot": "iphone-en/screenshot.png", "findings": []},
    {"id": "iphone-ja", "status": "approved", "screenshot": "iphone-ja/screenshot.png", "findings": []},
    {"id": "ipad-en", "status": "approved", "screenshot": "ipad-en/screenshot.png", "findings": []},
    {"id": "ipad-ja", "status": "approved", "screenshot": "ipad-ja/screenshot.png", "findings": []}
  ],
  "findings": [],
  "reviewedAt": "2026-08-21T13:00:00+09:00"
}
```

次のfinalize commandはcurrent Head、canonical path、draft digest、Issue、4case、Screenshot path、承認状態、時刻順序を再検証します。strict Task 3 schemaのcandidateを完成させてatomic renameし、exact Base/Issue/Headを引数に `tools/validate-verify-json.swift` を呼びます。失敗時にpartial `verify.json` を残しません。

```bash
tools/verify-ios-issue.sh --finalize \
  --issue 42 \
  --expected-base "${BASE_SHA}" \
  --draft ".artifacts/issues/42/${HEAD_SHA}/verify-draft.json" \
  --visual-result ".artifacts/issues/42/${HEAD_SHA}/visual-result.json"
```

各失敗は既存結果を上書きせず、`.artifacts/issues/42/${headSha}/failures/failure-${timestamp}-${unique}.json` へ次のexact sanitized schemaでexclusive作成します。`stage` と `error` はrunnerが定める非秘密の分類だけで、command output、Token、個人pathは保存しません。

```json
{
  "schemaVersion": 1,
  "status": "failed",
  "issue": 42,
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "stage": "unit-tests",
  "error": "unit tests failed, were skipped, or reported invalid counts",
  "recordedAt": "2026-08-21T12:50:00+09:00"
}
```

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

application変更が参照するmatrixは、batch lifecycleが完成させたexact schemaのファイルです。top-levelは `schemaVersion`、`batchId`、`resolvedAt`、`xcode`、`runtime`、`cases` だけを持ち、4つのcaseは固定順で、それぞれ `id`、`family`、`deviceType`、`locale`、`language`、`udid` だけを持ちます。Evidenceの4つのcase IDと順序はこのmatrixへ一致させ、各Screenshot pathはcase IDから始まる一意な相対pathにします。

検証時はGit top-levelから、Issueの信頼済みBase/HeadをJSONとは別の引数で渡します。

```bash
swift tools/validate-verify-json.swift \
  --file ".artifacts/issues/42/${HEAD_SHA}/verify.json" \
  --expected-issue 42 \
  --expected-base "${BASE_SHA}" \
  --expected-head "${HEAD_SHA}"
```

validatorは `--expected-head` が現在のGit Headと一致し、BaseとHeadが異なるcommitで、BaseがHeadの祖先であることを先に確認します。その後、verify.jsonのBase/Headが両引数と完全一致することを確認します。verify.json自身からGit検査範囲を選びません。verify.jsonは `.artifacts/issues/${issueNumber}/${headSha}/verify.json`、Issue contractは `.artifacts/issues/${issueNumber}/issue-contract.json`、matrixは `.artifacts/batches/${batchId}/simulator-matrix.json` のcanonical pathだけを許可します。

文書だけの変更では、次のexact representationを使います。省略したidentity、Issue contract、acceptance evidence、completed timeのfieldはapplication例と同じく必須です。

```json
{
  "schemaVersion": 1,
  "status": "not-applicable",
  "changeClassification": "documentation-only",
  "reason": "Only allowlisted Markdown documentation changed",
  "issue": 42,
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "issueContract": {
    "path": ".artifacts/issues/42/issue-contract.json",
    "digest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e"
  },
  "matrixFile": null,
  "matrixDigest": null,
  "executionRoute": "none",
  "xcode": null,
  "build": {"status": "not-applicable", "scheme": null, "warningsAdded": null},
  "tests": {"status": "not-applicable", "passed": null, "failed": null, "skipped": null},
  "cases": [],
  "visualEvaluation": {"status": "not-applicable", "findings": []},
  "acceptanceEvidence": [
    {"id": "AC-1", "status": "passed", "evidence": ["documents:spec consistency"]},
    {"id": "AC-2", "status": "passed", "evidence": ["links:swift tools/check-markdown-links.swift"]}
  ],
  "completedAt": "2026-08-21T13:00:00+09:00"
}
```

文書例外で許可する差分は、top-levelの `README.md` と `AGENTS.md`、`docs/` と `specs/` 以下のMarkdownだけです。NUL-safeなraw Git diffをrename検出なしで読み、追加・削除の両側を個別に検査します。Script、JSON、YAML、設定、asset、symlink、gitlink、実行bitを含むmode/type変更、allowlist外pathが一つでもあれば文書例外は使えません。文書例外はSimulatorやiOS Runtimeを必要としません。

`issueContract.fetchedAt` と `completedAt` は有効なISO 8601で、どちらも検証時刻から5分を超えて未来であってはいけません。さらに、`completedAt` は `fetchedAt` 以後でなければなりません。

PR本文にはverify.jsonの要約とdigestを記載します。巨大なログと一時的なSimulatorデータはGitへ入れません。反対モデルレビューの正本は `.artifacts/issues/${issueNumber}/${headSha}/review.json` です。

## 5. 実行手段

Codex環境でXcodeBuildMCPが利用できる場合、Project、scheme、Simulatorのsession defaultsを確認したうえでBuild、Test、UI操作、Screenshotを行います。利用できない場合は `xcodebuild` と `xcrun simctl` の決定論的なtoolsスクリプトを使います。

どちらの経路でも同じverify.jsonを生成し、実行経路を記録します。ツールが使えないことをTest成功へ読み替えません。

`executionRoute` の列挙値は、XcodeBuildMCP経路の `xcodebuild-mcp`、決定論的CLI経路の `xcodebuild-simctl`、文書例外だけに使う `none` です。

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
- `issue-contract.json` の全 `AC-*` が `acceptanceEvidence` に一度ずつ存在し、Codexが再取得したIssue本文から計算したcontract digestとも一致
- Codexがmerge直前に更新した `.artifacts/issues/${issueNumber}/github-preflight.json` が `intendedOperation: github.merge_pr` と現在のHead SHAを持ち、そのcanonical payload digestとfreshness条件を満たす
- Provider外部操作がある場合、`.artifacts/issues/${issueNumber}/provider-preflights/${provider}.json` とそのdigestが存在

一つでも不一致ならマージしません。
