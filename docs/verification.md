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
- current Headと信頼済みBaseのrangeを検証し、filterを起動しないplumbingとdescriptor readでtracked inventory、index flag、mode、bytesがexact Headに一致することを確認する
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
historical evidence表記の`tests:TemplateAppTests/NotificationSettingsTests`はbootstrapのlive identity anchorとしてだけ保持します。Task 4 contractの`acceptanceMappings.checks`ではこの表記を許可せず、`stage:unit-tests`と実行済みcase referenceを使います。

```bash
tools/verify-ios-issue.sh \
  --issue 42 \
  --expected-base "${BASE_SHA}" \
  --issue-contract .artifacts/issues/42/issue-contract.json \
  --matrix .artifacts/batches/settings-2026-08-21/simulator-matrix.json \
  --project ExampleApp.xcodeproj \
  --scheme ExampleApp
```

runnerは `/tmp/ios-template-verify/${physicalWorktreeName}-${sha256OfPhysicalRoot}/issue-42/${headSha}/Attempts/attempt-${uuid}/` の `DerivedData`、`Build.xcresult`、`Tests.xcresult`、`Cases/${caseId}.xcresult`、一時Screenshotだけを使い、Repository内へDerivedDataやresult bundleを作りません。`/tmp` の各directoryは現在のuid所有、mode `0700`、symlinkなしをdescriptor-boundに確認します。Issue/Head単位のkernel advisory lockはrunner lifetime中だけ保持され、正常終了、signal、crashでkernelが解放します。同じIssue/Headの同時実行は一方だけが進み、失敗attemptだけを片付けるため、同じHeadを安全に再試行できます。

production entrypointはprivileged modeのabsolute `/bin/bash -p` で起動し、entrypoint directoryはshell parameter expansion、`builtin cd`、absolute `/bin/pwd`だけで解決します。その後はabsolute `/usr/bin/git`、`/usr/bin/xcode-select`、`/usr/bin/xcrun` を使います。Gitは全呼び出しでRepository localのfsmonitorを無効化し、hooks pathを`/dev/null`へ固定します。`/Applications/Xcode.app/Contents/Developer` が有効なら優先し、それ以外はtrusted `xcode-select -p` のphysical pathを使います。そこからnon-symlinkの `usr/bin/xcodebuild` と同じDeveloper directory内へ解決されるSwift toolchainを固定し、`xcodebuild -version` が成功した場合だけ採用します。Git、Ruby、Swift、XcodeBuild、xcrunはvalidated HOME/TMPDIR/user/localeと固定PATHだけを入れた`env -i`から実行します。Xcode commandだけへ同じcommand-scoped `DEVELOPER_DIR` を追加し、Git、Ruby/Gem/Bundler、DYLD、Swift driver、SDK/toolchain、compiler/build-setting環境を継承しません。callerの `PATH`、`BASH_ENV`、export済みshell function、環境変数でproduction executableを差し替えるinterfaceは持ちません。

`--project` はRepository-relativeなcommitted `.xcodeproj` directoryだけを許可します。runnerはtrusted Gitの`ls-tree` exact inventoryと各object IDへの`cat-file blob`だけからprivate `Source`をdescriptor-relatively構築し、regular blob以外をmaterializeせず、実行bitを保存してseal/fsyncします。Xcodeはmutable worktreeではなくこのraw-Head snapshotだけをBuild/Testします。worktree側は`git status`やcheckoutを使わず、index inventory、assume-unchanged/skip-worktree flag、tracked mode/bytesをdescriptor-boundでHeadへ照合します。ignored/untracked fileやconversion filterはBuild入力になりません。full Head tuple/blob digestとproject-relative pathを`build.sourceTree`、project subtree digestを`build.project`としてdraft/finalへ固定します。Buildはsingle destination、`-parallel-testing-enabled NO`の`build-for-testing`を1回だけ実行します。その後、contractのexact `unitTestIdentifier`を同じdestinationで`test-without-building -only-testing:`し、各`testIdentifier` caseも同じbuildを使います。Build、unit test、caseのdiagnostics/test countsはhuman-readable logをgrepせず、trusted `xcrun xcresulttool` schema `0.1.0` の`devicesAndConfigurations`とtest treeから判定します。Build/unit test/caseのwarning、analyzer warning、errorはすべて0でなければ失敗します。unit stageと各UI stageはsummary、configuration、test treeのすべてで指定した1件だけがexpected target/class/method、exact matrix UDIDとconfigurationでpassedし、failed/skipped/expected failureが0でなければ失敗します。UI caseではcontractのlocale/language引数もcommandに固定します。

Build productはlocked attempt内のDerivedData `Build/Products` 配下にあるregular app directoryだけを候補にし、Bundle IDとBundle executableを検証します。runnerはbundle tree全体をdescriptor-boundに再帰走査し、symlink、special file、別uid、複数hardlinkを拒否してprivate `StagedApp`へcopy、seal、fsyncします。tree digestはrecord type、path、content length/contentをlength-prefixして構造とbytesを一意に固定します。各install直前にstaged tree、Bundle ID、executableを再読してdigest一致を要求するため、Build productやstaged pathの置換をinstallへ持ち込めません。

各case直前にlive Git Head、tracked Head inventory/bytes/flags、sealed config、canonical contract/matrix、source/project digestを再検証します。その後matrixのexact UDIDをbootまたは既存Booted状態として確認し、bootstatus、staged appのinstall、Bundle IDからinstalled app containerを取得、既存processのterminate、exact language/localeでlaunch、bounded process-liveness probe、contractの機械check、もう一度のbounded liveness probe、Screenshot、terminateの順に直列実行します。`testIdentifier` はunique case xcresultを使うexact `-only-testing` です。UI testがappを再launchできるため、完了後はvalidated executableをSimulator内のbounded `pgrep`とnon-truncated `ps -ww -o comm=`で一意に再取得し、そのexecutable pathがBundle IDから取得したapp container内のexact executableであることを照合してcurrent PIDをprobeします。すべてのSimulator process queryはhost側でも5秒に制限します。`launch-succeeded` はlaunchが返したPIDのlivenessまでを確認する狭いsmoke checkであり、UI内容の保証ではありません。runnerはSimulatorをcreate、erase、delete、または別deviceへ代替しません。途中終了時も現在activeなBundle IDをbest-effort terminateします。

実行成功時はfinal結果ではなく、4枚のdecodable PNGとcanonical `.artifacts/issues/42/${headSha}/verify-draft.json` を一つのpublication transactionとしてno-replace publishし、fileとdirectoryをfsyncします。全4caseとinput再検証が完了するまではcanonical Screenshotもdraftも公開しません。publication前にsealed `.verify-publication-journal.json` をdurable publishし、draft完成後にだけ削除・fsyncします。SIGKILL等で途中終了した場合、次のrunnerがIssue/Head lock取得後にjournalのexact digestを検証し、このtransactionのpartial Screenshotだけをrollbackして同じHeadを再試行できます。通常のdraft衝突も同じ範囲だけをrollbackします。次がschema version 1のexact internal schemaです。Objectは例にないkeyを持てず、`cases` と `acceptanceEvidence` はcontractの順序を保ちます。`mechanicalCheck` は実行した `test:${testIdentifier}` または `assertion:launch-succeeded`、acceptance evidenceはcontractのmappingからvisual参照だけを除いたexactな実行済みstage/case参照です。sealed config digest、canonical contract/matrix/source/project、Git Headとtracked Head inventory/bytes/flagsはcaseごと、およびpublication直前にdescriptor-boundで再検証します。

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
  "build": {"status": "passed", "scheme": "ExampleApp", "warningsAdded": 0, "project": {"path": "ExampleApp.xcodeproj", "digest": "sha256:c508ebb4550e3fc36666de55b2f9750e95adcbaab20421810f48d7e39b69e15e"}, "sourceTree": {"headSha": "0123456789abcdef0123456789abcdef01234567", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "projectPath": "ExampleApp.xcodeproj"}},
  "tests": {"status": "passed", "passed": 1, "failed": 0, "skipped": 0},
  "cases": [
    {"id": "iphone-en", "status": "passed", "screenshot": "iphone-en/screenshot.png", "screenshotDigest": "sha256:54808a3902e22d616104502c99f728a3b9fb8f7d00412c2d725a03580e98b6e9", "mechanicalCheck": "test:ExampleAppUITests/SmokeTests/testLaunch"},
    {"id": "iphone-ja", "status": "passed", "screenshot": "iphone-ja/screenshot.png", "screenshotDigest": "sha256:fd1a5bba126762a8aee2cbfd9816ba4983c335bad13cc170e6db5940449bb4b3", "mechanicalCheck": "assertion:launch-succeeded"},
    {"id": "ipad-en", "status": "passed", "screenshot": "ipad-en/screenshot.png", "screenshotDigest": "sha256:8f5674ac5c3bdfa4bc63bf120ee8d6a7706598557fc99b51d37de343e7091e9d", "mechanicalCheck": "test:ExampleAppUITests/SmokeTests/testLaunch"},
    {"id": "ipad-ja", "status": "passed", "screenshot": "ipad-ja/screenshot.png", "screenshotDigest": "sha256:5d173426722d981121aee0251e7c64a2b25797ea3fc154c06c4aaeb433e2ee62", "mechanicalCheck": "assertion:launch-succeeded"}
  ],
  "acceptanceEvidence": [
    {"id": "AC-1", "evidence": ["stage:build", "stage:unit-tests", "case:iphone-en", "case:iphone-ja"]},
    {"id": "AC-2", "evidence": ["case:ipad-en", "case:ipad-ja"]}
  ],
  "workspaceArtifacts": {
    "derivedDataPath": "/tmp/ios-template-verify/worktree-name-64hex-root-digest/issue-42/0123456789abcdef0123456789abcdef01234567/Attempts/attempt-uuid/DerivedData",
    "buildResultBundlePath": "/tmp/ios-template-verify/worktree-name-64hex-root-digest/issue-42/0123456789abcdef0123456789abcdef01234567/Attempts/attempt-uuid/Build.xcresult",
    "testResultBundlePath": "/tmp/ios-template-verify/worktree-name-64hex-root-digest/issue-42/0123456789abcdef0123456789abcdef01234567/Attempts/attempt-uuid/Tests.xcresult"
  },
  "executionCompletedAt": "2026-08-21T12:55:00+09:00"
}
```

Task 5のAI評価はcanonical `.artifacts/issues/42/${headSha}/visual-result.json` を次のexact schemaで書きます。`draft.path` は同じIssue/Headのcanonical path、`draft.digest` はdraftのexact bytesです。4件すべての `id`、`screenshot`、`screenshotDigest` はdraftに一致し、承認時はtop-levelと各caseの `findings` が空です。

```json
{
  "schemaVersion": 1,
  "status": "approved",
  "issue": 42,
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "draft": {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/verify-draft.json", "digest": "sha256:4ae755fb899a15125dfe7db017761abe901e1de00bf266894157826c827a3f2f"},
  "cases": [
    {"id": "iphone-en", "status": "approved", "screenshot": "iphone-en/screenshot.png", "screenshotDigest": "sha256:54808a3902e22d616104502c99f728a3b9fb8f7d00412c2d725a03580e98b6e9", "findings": []},
    {"id": "iphone-ja", "status": "approved", "screenshot": "iphone-ja/screenshot.png", "screenshotDigest": "sha256:fd1a5bba126762a8aee2cbfd9816ba4983c335bad13cc170e6db5940449bb4b3", "findings": []},
    {"id": "ipad-en", "status": "approved", "screenshot": "ipad-en/screenshot.png", "screenshotDigest": "sha256:8f5674ac5c3bdfa4bc63bf120ee8d6a7706598557fc99b51d37de343e7091e9d", "findings": []},
    {"id": "ipad-ja", "status": "approved", "screenshot": "ipad-ja/screenshot.png", "screenshotDigest": "sha256:5d173426722d981121aee0251e7c64a2b25797ea3fc154c06c4aaeb433e2ee62", "findings": []}
  ],
  "findings": [],
  "reviewedAt": "2026-08-21T13:00:00+09:00"
}
```

次のfinalize commandはcurrent Headとtracked Head bytes/flags、descriptor-bound canonical path、draft digest、Issue、matrix、4case、Screenshot path/digest/bytes、承認状態、時刻順序、各mechanical checkとAC mappingのcurrent canonical contract一致を再検証します。Swift finalizerがstrict Task 3 schemaのprivate sealed candidateを完成させ、同じprocess内のvalidatorがexact Base/Issue/Headで検証します。validated candidate FD/inode/digestを保持し、Git/config/Screenshotをpublication境界で再検証したまま`renameatx_np(RENAME_EXCL)`でcanonical `verify.json`をatomic no-replace公開して再照合し、fileとdirectoryをfsyncします。standalone `--candidate-file` publicationは許可しません。衝突時は既存winnerを保持し、失敗時にpartial `verify.json` を露出しません。

```bash
tools/verify-ios-issue.sh --finalize \
  --issue 42 \
  --expected-base "${BASE_SHA}" \
  --draft ".artifacts/issues/42/${HEAD_SHA}/verify-draft.json" \
  --visual-result ".artifacts/issues/42/${HEAD_SHA}/visual-result.json"
```

Issue/current Head identityを確立した後のrange、tracked Head不一致、その他preflightを含む各失敗は既存結果を上書きせず、`.artifacts/issues/42/${headSha}/failures/failure-${uuid}.json` へ次のexact sanitized schemaでdescriptor-boundなprivate candidateからatomic no-replace publishし、fileとdirectoryをfsyncします。failure writerはGit top-levelとcurrent Headを独立再検証しますが、失敗理由になったtracked状態やBase ancestryを成功条件にはしません。`stage` と `error` はrunnerが定める非秘密の分類だけで、command output、Token、個人pathは保存しません。

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
  "build": {"status": "passed", "scheme": "TemplateApp", "warningsAdded": 0, "project": {"path": "ExampleApp.xcodeproj", "digest": "sha256:c508ebb4550e3fc36666de55b2f9750e95adcbaab20421810f48d7e39b69e15e"}, "sourceTree": {"headSha": "0123456789abcdef0123456789abcdef01234567", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "projectPath": "ExampleApp.xcodeproj"}},
  "tests": {"status": "passed", "passed": 1, "failed": 0, "skipped": 0},
  "cases": [
    {"id": "iphone-en", "status": "passed", "screenshot": "iphone-en/settings.png", "screenshotDigest": "sha256:54808a3902e22d616104502c99f728a3b9fb8f7d00412c2d725a03580e98b6e9"},
    {"id": "iphone-ja", "status": "passed", "screenshot": "iphone-ja/settings.png", "screenshotDigest": "sha256:fd1a5bba126762a8aee2cbfd9816ba4983c335bad13cc170e6db5940449bb4b3"},
    {"id": "ipad-en", "status": "passed", "screenshot": "ipad-en/settings.png", "screenshotDigest": "sha256:8f5674ac5c3bdfa4bc63bf120ee8d6a7706598557fc99b51d37de343e7091e9d"},
    {"id": "ipad-ja", "status": "passed", "screenshot": "ipad-ja/settings.png", "screenshotDigest": "sha256:5d173426722d981121aee0251e7c64a2b25797ea3fc154c06c4aaeb433e2ee62"}
  ],
  "visualEvaluation": {"status": "passed", "findings": []},
  "acceptanceEvidence": [
    {
      "id": "AC-1",
      "status": "passed",
      "evidence": ["stage:build", "stage:unit-tests", "case:iphone-en", "case:iphone-ja"]
    },
    {
      "id": "AC-2",
      "status": "passed",
      "evidence": ["case:ipad-en", "case:ipad-ja", "visual:iphone-en", "visual:iphone-ja", "visual:ipad-en", "visual:ipad-ja"]
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
  "build": {"status": "not-applicable", "scheme": null, "warningsAdded": null, "project": null, "sourceTree": null},
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
