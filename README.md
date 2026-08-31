# iOS-Template

CodexとClaudeを同等の実装・外部操作担当として使う個人向けiOS開発テンプレートです。仕様、Issue、ブランチ、リスクに応じた検証・レビュー、PR、Squash Mergeまでを一貫したワークフローとして扱います。

Foundation は利用可能です。最小の SwiftUI アプリ、Unit/UI Test、英語・日本語、iPhone・iPad、共有仕様スキル、Codex/Claude 共通責務の read-only 評価エージェントを含みます。運用自動化は [実装計画索引](./docs/superpowers/plans/README.md) に従って段階的に追加します。

開発順序は**日本語iPhoneで機能を固める → 英語・iPadを仕上げる → リリース前に4条件確認**です。[段階的開発仕様](./specs/development-stages.md)に、初期から残す土台と延期できる作業を定めています。1条件でのcanonical検証は[Issue #32](https://github.com/yuto1201/iOS-Template/issues/32)の実装待ちで、現行ツールは4条件固定です。文書の方針変更だけで、実行経路や既存アプリまで移行済みとは扱いません。

## Foundation の検証

リポジトリ方針は次で検証します。

```sh
tools/tests/test-foundation.sh
```

Issueには`fast`、`standard`、`strict`のdelivery profileと理由を指定します。非UI・低リスクの`fast`は現在HeadのBuild・対象Test・必要なrepository testだけ、通常UIの`standard`は安定した最終候補Headで要求範囲を検証します。`standard`／`strict`の反対モデルレビュー、高リスクの対象別Test・preflight・必要な承認を維持します。profile未指定は`strict`、検証範囲未指定は`full`です。以下は現行4条件経路の手順です。

Foundationやdelivery gate自体は`strict`です。Build と Test は、インストール済み Xcode から [標準 Simulator マトリクス](./docs/verification.md#3-固定されるmatrix)を解決し、Issue バッチ内で固定して実行します。次は Foundation 検証で使うコマンド形です。`TEMPLATE_IPHONE_UDID` と `TEMPLATE_IPAD_UDID` には、同じ最新 iOS Runtime の iPhone Pro（Pro Max を除く）と13-inch iPad Airを指定します。

```sh
TEMPLATE_IPHONE_UDID="<resolved-iPhone-Pro-UDID>"
TEMPLATE_IPAD_UDID="<resolved-iPad-Air-13-inch-UDID>"
TEMPLATE_DERIVED_DATA=$(mktemp -d /tmp/ios-template-derived-data.XXXXXX)
TEMPLATE_RESULT_BUNDLES=$(mktemp -d /tmp/ios-template-result-bundles.XXXXXX)
trap 'rm -rf "$TEMPLATE_DERIVED_DATA" "$TEMPLATE_RESULT_BUNDLES"' EXIT

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPHONE_UDID}" \
  -derivedDataPath "${TEMPLATE_DERIVED_DATA}" \
  -resultBundlePath "${TEMPLATE_RESULT_BUNDLES}/unit-tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test -only-testing:TemplateAppTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPHONE_UDID}" \
  -derivedDataPath "${TEMPLATE_DERIVED_DATA}" \
  -resultBundlePath "${TEMPLATE_RESULT_BUNDLES}/iphone-english.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testEnglishWelcomeTitle

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPHONE_UDID}" \
  -derivedDataPath "${TEMPLATE_DERIVED_DATA}" \
  -resultBundlePath "${TEMPLATE_RESULT_BUNDLES}/iphone-japanese.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testJapaneseWelcomeTitle

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPAD_UDID}" \
  -derivedDataPath "${TEMPLATE_DERIVED_DATA}" \
  -resultBundlePath "${TEMPLATE_RESULT_BUNDLES}/ipad-english.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testEnglishWelcomeTitle

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TemplateApp.xcodeproj \
  -scheme TemplateApp \
  -destination "platform=iOS Simulator,id=${TEMPLATE_IPAD_UDID}" \
  -derivedDataPath "${TEMPLATE_DERIVED_DATA}" \
  -resultBundlePath "${TEMPLATE_RESULT_BUNDLES}/ipad-japanese.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -only-testing:TemplateAppUITests/TemplateAppUITests/testJapaneseWelcomeTitle
```

### ライブ Simulator 検証記録

`template-foundation-live` バッチでは、次のインストール済み環境を一度だけ解決し、4条件で固定しました。matrixのSHA-256は`0401013f6aa579ac81c077629d43e109308e908bdec365e01845865f7a531457`です。

| 項目 | 解決値 |
| --- | --- |
| Xcode | `/Applications/Xcode.app/Contents/Developer`、version `26.6`、build `17F113` |
| iOS Runtime | `com.apple.CoreSimulator.SimRuntime.iOS-26-5`、version `26.5` |
| iPhone | `iPhone 17 Pro` (`com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro`、Pro Maxを除外) |
| iPad | `iPad Air 13-inch (M4)` (`com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M4`) |

検証ケースは `iphone-en` (`en_US`/`en`)、`iphone-ja` (`ja_JP`/`ja`)、`ipad-en` (`en_US`/`en`)、`ipad-ja` (`ja_JP`/`ja`) の固定順です。選択Testは合計5実行で、Unit Test 1件 `TemplateAppTests/TemplateAppTests/welcomeMessageLocalizations()` と、各caseでUI Test 1件ずつ（英語caseは `TemplateAppUITests/TemplateAppUITests/testEnglishWelcomeTitle`、日本語caseは `TemplateAppUITests/TemplateAppUITests/testJapaneseWelcomeTitle`）を実行します。

初回のmatrix解決は、Repository全体のSimulator lock下で次を実行します。

```sh
tools/with-ios-simulator-lock.sh --timeout 0 -- \
  /usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  tools/resolve-simulator-matrix.sh \
    --batch-id template-foundation-live \
    --output .artifacts/batches/template-foundation-live/simulator-matrix.json
```

READMEを含む対象Headをcommitした後、同じlockをmatrix再検証からrunner終了まで保持し、既存matrixがbyte-for-byte不変であることを確認してから検証します。

```sh
tools/with-ios-simulator-lock.sh --timeout 0 -- \
  /usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /bin/bash -c '
    set -euo pipefail
    matrix=.artifacts/batches/template-foundation-live/simulator-matrix.json
    before="$(shasum -a 256 "$matrix" | cut -d " " -f 1)"
    tools/resolve-simulator-matrix.sh \
      --batch-id template-foundation-live \
      --output "$matrix"
    after="$(shasum -a 256 "$matrix" | cut -d " " -f 1)"
    test "$before" = "$after"
    tools/verify-ios-issue.sh \
      --issue 6 \
      --expected-base b3c04853ae2e27f566fc7c3fc0a03dca87f8cfe6 \
      --issue-contract .artifacts/issues/6/issue-contract.json \
      --matrix "$matrix" \
      --project TemplateApp.xcodeproj \
      --scheme TemplateApp
  ' ios-verify
```

runnerが現在のHeadへ公開したdraftからvisual packetを作り、全画像を評価した同じHeadのcanonical resultだけをfinalizeします。

```sh
HEAD_SHA="$(git rev-parse HEAD)"

tools/visual-review-packet.sh \
  --issue 6 \
  --expected-base b3c04853ae2e27f566fc7c3fc0a03dca87f8cfe6 \
  --draft ".artifacts/issues/6/${HEAD_SHA}/verify-draft.json" \
  --output ".artifacts/issues/6/${HEAD_SHA}/visual-packet.json"

tools/verify-ios-issue.sh --finalize \
  --issue 6 \
  --expected-base b3c04853ae2e27f566fc7c3fc0a03dca87f8cfe6 \
  --draft ".artifacts/issues/6/${HEAD_SHA}/verify-draft.json" \
  --visual-result ".artifacts/issues/6/${HEAD_SHA}/visual-result.json"

swift tools/validate-verify-json.swift \
  --file ".artifacts/issues/6/${HEAD_SHA}/verify.json" \
  --expected-issue 6 \
  --expected-base b3c04853ae2e27f566fc7c3fc0a03dca87f8cfe6 \
  --expected-head "$HEAD_SHA"
```

証拠の形式、画像評価、Head SHA 一致条件は [iOS verification](./docs/verification.md) を正とします。Simulator のUDIDと結果ファイルは環境固有なのでGitへ追加しません。

## 新しいアプリとして使い始めるとき

- Xcodeが生成した個人のSigning Teamは初期値として残しています。別の所有者が利用する場合は、XcodeのSigning & Capabilitiesで自分のTeamへ変更します。`Config/ownership.yml` のApp Store Team IDとBundle IDは、アプリ固有の提出先が決まるまで`null`のままにします。
- Deployment Targetはテンプレート生成時のXcode既定値です。対象ユーザーと必要APIを決め、実装Issueを始める前にアプリ固有の最小OSを仕様とXcode設定へ固定します。
- ローカル設定は `Config/Local.xcconfig.example` を参考に、Git管理外の `Config/Local.xcconfig` へ置きます。秘密値はxcconfigへも保存せず、Keychainまたは各サービスの秘密管理を使います。

### GitHub workflow initialization

テンプレートから個人用リポジトリを作成した直後、最初のIssueを起票する前にCodexまたはClaudeが`Config/ownership.yml`のGitHubアカウントと対象リポジトリを確認し、workflow labelsを一度同期します。この操作は冪等で、既存の正しいlabelは変更しません。

```sh
REPO='OWNER/REPO'
tools/sync-github-labels.sh --repo "$REPO" --executor codex # または claude
```

その後、アプリ固有の最小仕様を`specs/`で確定し、Foundation、Identity bootstrap、Simulator verificationの3つのBootstrap Issueを依存順に起票します。Issue作成後にだけ各Branch/worktreeを作り、Identity bootstrapが完了するまでFeature実装を開始しません。

### Identity bootstrap

機能開発より先に、表示名、Swiftモジュール名、lowercase kebab-caseのアプリSlug、逆DNS形式のBundle IDという4つのIdentity入力を確定します。Deployment Targetはこれらと分けてアプリ仕様とXcode設定へ確定します。承認済みのIdentity Bootstrap Issueに対応するクリーンな非default Branch/worktreeで、リポジトリルートから次を実行します。

```sh
tools/bootstrap-app.sh \
  --display-name 'Garden Notes' \
  --module-name GardenNotes \
  --app-slug garden-notes \
  --bundle-id com.yuto.GardenNotes
```

コマンドは、Xcode project、Target、Scheme、Swift Module、Test、Bundle ID、設定、現行文書を一つのIdentityへ変換し、確認用の変更をunstagedで残します。標準出力は`applied`と結果パスを含むsanitized JSONで、非秘密の完全な結果は`Config/app-identity.json`へschema version 1として保存されます。

通常の`git diff`だけでは新しいuntracked fileを表示しないため、次のread-only手順でstatus、tracked diff、untracked fileをすべて確認します。`git diff --no-index`の終了値`1`は差分を表示した正常結果として扱い、それ以外の非zeroだけを失敗にします。この確認ではbootstrap出力をstageせず、indexを変更しません。

```sh
git status --short --untracked-files=all
git diff --
while IFS= read -r -d '' path; do
  git diff --no-index -- /dev/null "$path" || {
    status=$?
    [[ "$status" -eq 1 ]] || exit "$status"
  }
done < <(git ls-files --others --exclude-standard -z)
```

すべての差分と結果recordを確認してからFoundation、Xcode、4条件Simulator、反対モデルレビューを実行してください。共通の手順は[App Bootstrap skill](./.agents/skills/app-bootstrap/SKILL.md)を正とします。

同じ4入力で再実行すると`already-complete`を返して何も変更しません。1値でも異なる再実行は、既存結果と競合するため変更前に失敗します。GitHub上のリポジトリ名変更とApple側のBundle ID登録はこのコマンドに含まれず、Issueで指定された実行モデルが設定済みアカウントを確認して別操作として行います。

### Feature開発開始ゲート

Feature IssueのBranch/worktreeを作る前に、アプリ固有の`specs/product.md`と`specs/acceptance.md`がともに`Status: 確定`で、そのIssueの受け入れ条件と一致していることを確認します。未作成、確定前、または不一致なら、実行モデルがIssueを`blocked:user`へ遷移させ、Branch/worktree作成と実装を開始しません。

## 条件付き統合と秘密管理

Supabase、ElevenLabs、Cloudflare、分析、StoreKit、通知などは Foundation のアプリ本体へ組み込まれていません。必要性を確定仕様と Issue の受け入れ条件に明記した場合だけ、別 Issue で有効化します。テンプレートの状態では root `supabase/`、外部 SDK、認証済み接続を持たず、不要なサービスの保守や権限を発生させません。

- データベース、認証、同期、Storageが必要なアプリでは [Supabase operations skill](./.agents/skills/supabase-ops/SKILL.md)を使用します。`Status: 確定`かつ`Supabase: required`の仕様だけが有効化でき、`supabase/migrations/`を唯一のスキーマ履歴としてRLSとPolicyを同時に追加します。CodexとClaudeのどちらもlocal／remote作業を実行できますが、remoteではOrganization IDとProject Refを照合します。
- 読み上げ、Voice Changer、文字起こし、効果音、音声分離、音楽、画像、動画が必要な場合は [iOS media assets skill](./.agents/skills/ios-media-assets/SKILL.md)を使用します。実行モデルが設定済みElevenLabs Account／Workspaceとmode別entitlementを先に確認し、受理した出力とsanitized manifestだけを統合します。
- GitHub、Supabase、Cloudflare、Linear、Vercel、ElevenLabs、App Store Connectを含む認証済み外部操作は、CodexとClaudeが同じ [external operations skill](./.agents/skills/external-ops/SKILL.md)を使い、実行直前に設定済みアカウントと対象を照合します。
- 一行の秘密値はmacOS Keychainへ保存し、`tools/run-with-secret.sh`が子プロセスの環境だけへ渡します。App Store Connectの`.p8`は`~/Library/Application Support/iOS-Template/secrets/${appSlug}/`の`0700`ディレクトリ／`0600`ファイルだけを`tools/run-with-private-key.sh`で使用します。取得値を表示するコマンドはなく、`.secrets/`と`secret-staging/`もGit管理外です。

## App Store リリース素材

`App Store/`は、英語・日本語metadata、privacy宣言、privacy policyとtermsの原稿、review notes、release notes、最終screenshots、提出チェックリストを一括管理する非秘密の正本です。テンプレートのURLと法務文書は未確定、画像は未生成なので、そのまま提出可能という意味ではありません。現在の公開要件は`App Store/submission/requirements.json`へ取得日時・参照元とともに固定し、準備時に期限切れなら実行モデルがApple公式資料から更新します。

リリース候補がBuild/Test済みになったら [prepare-appstore-assets skill](./.agents/skills/prepare-appstore-assets/SKILL.md)で、実際の仕様から文面を生成し、App Store専用Simulator matrixで英日・iPhone/iPad画像を撮影します。このmatrixは通常検証とは別で、表示ファミリー要件に応じてPro Maxを使用できます。全画像とprivacy/legal/metadataを`release-auditor`が同一SHA・同一build digestで承認し、初回公開時はユーザーがprivacy policyとtermsを確認した後だけ、変更検知可能なpackage manifestを作ります。

提出は [submit-appstore-release skill](./.agents/skills/submit-appstore-release/SKILL.md)をIssueで指定されたCodexまたはClaudeが実行します。実行モデルが設定済みTeam、App、Bundle ID、version、buildを確認し、App Store Connectへセクション単位で入力・保存・再読込します。

## 最初に読む文書

1. [仕様索引](./specs/README.md)
2. [プロダクト方針](./specs/product.md)
3. [テンプレート構成](./specs/architecture.md)
4. [受け入れ条件](./specs/acceptance.md)
5. [決定ログ](./specs/decisions.md)
6. [権限境界](./docs/AUTHORITY.md)
7. [Issue からマージまでの運用](./docs/workflow.md)
8. [秘密管理](./docs/security.md)
9. [Simulator 検証](./docs/verification.md)
10. [公式資料](./docs/references.md)

## 設計の由来

- `Flower`: Issue 単位の証拠管理、視覚評価、作業完了ゲート
- `Elsefolk`: 仕様の確定・提案・未決の分離、決定ログ、実測を伴う完了報告
- `CafLog`: 日本語・英語対応、iPhone・iPad、App Store 用素材の管理
- 現行の確定方針: CodexとClaudeは同じ外部操作権限を持ち、`Config/ownership.yml`の設定済みアカウントだけを使用する

参照プロジェクト固有の画面、データモデル、アーキテクチャ、`CLAUDE.md` は継承しません。

## 基本原則

- 仕様が未決のまま実装を開始しない。
- 1 Issue = 1 Branch = 1 PR とする。
- AI がdelivery profileに必要な検証・レビュー、修正、PR、Squash Mergeまで進める。
- ユーザーによる実機確認は、AI の Definition of Done の後に行う最終確認とする。
- 外部アカウント操作はIssueで指定されたCodexまたはClaudeが、設定済みidentityのpreflight後に行う。
- 秘密値は Git、Issue、PR、ログ、スクリーンショット、AI プロンプトに残さない。

## Issue 自動運用とリカバリー

次のコマンドは `OWNER/REPO`、Issue番号、担当モデルを確定してから実行します。Claim は承認済みIssueに正規Branch/worktreeと共有証拠領域を一度だけ作り、同じ担当者による再実行は Resume になります。明示的な再開だけを行う場合は `resume-issue.sh` を使います。

```sh
REPO='OWNER/REPO'
ISSUE=42

tools/issue-state.sh get --repo "$REPO" --issue "$ISSUE"
tools/claim-issue.sh --repo "$REPO" --issue "$ISSUE" --agent codex
tools/resume-issue.sh --repo "$REPO" --issue "$ISSUE"
```

Issue worktreeで対象確認を終え、差分が安定してから現在のcommitを直接解決し、その同じSHAへcanonical Verifyを結び付けます。`fast`は`verify-fast-issue.sh`でBuildと対象Unit Testを実測し、`verify-passed`から直接`approved-for-merge`へ進みます。`standard`／`strict`だけが完全Simulator matrix、review packet、反対モデルreviewを使用します。ドキュメントだけの変更は`publish-documentation-verify.sh`を使い、Simulator成功を意味しません。

```sh
HEAD_SHA="$(git rev-parse HEAD)"
BASE_SHA="$(jq -r '.baseSha' ".artifacts/issues/$ISSUE/state.json")"

tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" \
  --from in-progress --to verify-passed --head-sha "$HEAD_SHA"

# explicit fast
tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" \
  --from verify-passed --to approved-for-merge

# standard / strict
tools/prepare-review-packet.sh --primary codex --issue "$ISSUE" \
  --base-sha "$BASE_SHA" --head-sha "$HEAD_SHA"
tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" \
  --from verify-passed --to review-requested
tools/cross-model-review.sh --primary codex \
  --packet ".artifacts/issues/$ISSUE/$HEAD_SHA/review-packet.json" \
  --output ".artifacts/issues/$ISSUE/$HEAD_SHA/review.json"
```

マージ診断はmutationを行わないGateを先に実行します。`standard`／`strict`では承認済みreview、全profileでは現在HeadのVerifyと最新のaccount preflightが揃った後、Issueで指定された実行モデルがPR作成、Squash Merge、正確なBranch/worktree cleanup、`done`遷移まで行います。

```sh
tools/github-account-preflight.sh --repo "$REPO" --issue "$ISSUE" \
  --intended-operation github.merge_pr --expected-head "$HEAD_SHA"
tools/premerge-gate.sh --repo "$REPO" --issue "$ISSUE" --head-sha "$HEAD_SHA"
tools/merge-issue.sh --repo "$REPO" --issue "$ISSUE"

# primary checkoutで実行
tools/cleanup-issue.sh --repo "$REPO" --issue "$ISSUE"
tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" \
  --from merged --to done
```

`blocked:*` または `paused` は失敗の隠蔽ではなく、直前状態を `resumeState` としてmarkerへ残す停止状態です。原因を直した後は担当者を変えず、まず `issue-state.sh get` が返すexact `resumeState`へ `issue-state.sh transition --from <current> --to <resumeState>` で明示的に復帰し、その後 `resume-issue.sh` でlocal stateを再構築して同じstateを再dispatchします。`resume-issue.sh` 自体はGitHub labelを変えません。成功が不明な外部操作は別コマンドへ進まず同じコマンドを再実行します。Headを変更した場合は `approved-for-merge`、`changes-requested`、または `verify-passed` から `in-progress` へ戻し、新しいHeadのVerifyとreviewを両方作り直します。
