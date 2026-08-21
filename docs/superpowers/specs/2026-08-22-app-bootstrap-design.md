# App Identity Bootstrap Design

Status: 確定

Version: 1.0

Date: 2026-08-22

## 1. Purpose

GitHub Templateから生成した新しいリポジトリを、Feature開発前に`TemplateApp`から一つのアプリ固有Identityへ安全に変換する。将来のアプリ名をテンプレートへ固定せず、利用時に与えた検証済み入力だけを使う。

## 2. Required inputs

`tools/bootstrap-app.sh`は次の4値を必須とする。

| Argument | Meaning | Validation |
| --- | --- | --- |
| `--display-name` | ホーム画面などへ表示する人間向け名称 | 1〜30文字、改行・制御文字・`/`を禁止 |
| `--module-name` | Xcode Project、Target、Scheme、Product、Swift Moduleの共通名称 | ASCII英字で開始し、ASCII英数字のみ、2〜50文字 |
| `--app-slug` | 秘密保存先や生成物で使う機械向け名称 | lowercase kebab-case、1〜50文字 |
| `--bundle-id` | App TargetのBundle ID | 逆DNS形式、各segmentは英数字で開始し英数字・`-`のみ |

Unit TestとUI TestのTarget名は`${moduleName}Tests`と`${moduleName}UITests`、Bundle IDは`${bundleId}Tests`と`${bundleId}UITests`へ導出する。入力値や派生値が既存pathと衝突する場合は変更前に失敗する。

Deployment TargetはIdentity入力と混同しない。bootstrap前にアプリ仕様で最小iOSを確定してXcode設定へ反映し、変換後の全Target/Configurationでその値が維持されていることを検証する。

## 3. Source identity and result record

`Config/template-identity.json`を変換元の唯一のmachine-readable正本とする。schema version、元Project/Target/Module/Bundle ID、変換対象path、変換後に`TemplateApp`が残ってはならないlive pathを記録する。

成功時に`Config/app-identity.json`を作成し、schema version、display name、module name、app slug、Bundle ID、元Template identity versionを記録する。秘密、GitHub Token、Signing Team、リモートprovider ID、timestampは含めない。同じ入力で再実行した場合は`already-complete`を返して変更しない。異なる入力で再実行した場合は失敗する。

## 4. Transformation boundary

変換する対象:

- `TemplateApp.xcodeproj`と共有Scheme path
- App、Unit Test、UI Testのsource directoryとSwift filename
- `project.pbxproj`のProject、Target、Product、Module、Bundle ID、Test Host、Test Target
- 共有SchemeのBuildable、Blueprint、Container
- App entry type、Test type、`@testable import`
- `CFBundleDisplayName` build setting
- `README.md`のProject/Scheme/Test実行例
- `AGENTS.md`のリポジトリ契約見出し
- `specs/architecture.md`と`docs/verification.md`のlive project例
- `docs/agent-contracts/review-packet.md`のlive source path例
- `docs/security.md`の`template-app`例を入力app Slugへ変換
- Welcome localization keyとaccessibility identifierの`template` prefixを入力app Slugへ変換
- `Config/ownership.yml`のApp Store Bundle ID

意図的に変換しない対象:

- `docs/superpowers/plans/`の過去またはテンプレート構築履歴
- `.agents/skills/`内のテンプレート自体を説明する名称
- `~/Library/Application Support/iOS-Template/`の共通秘密namespace
- `iOS-Template-`の専用Simulator prefix
- PBX UUID、TestTargetID、Xcode object/upgrade metadata、`DEVELOPMENT_TEAM`
- GitHubリポジトリ名、remote URL、外部Bundle ID登録、Signing Team

ツールは全追跡ファイルの無差別な置換を行わない。Manifestに列挙したlive fileとpathだけを変更し、live residual pathに元Identityが残れば失敗する。

## 5. Transaction model

1. 呼び出し元がGit repository root、clean worktree/index、非default Branchであることを確認する。
2. 引数、Manifest、変換元path、衝突、既存result recordを確認する。
3. `/tmp`配下へdetached Git worktreeを作成する。
4. 一時worktreeでpath rename、限定content transformation、result record生成、residual audit、`xcodebuild -list`を完了する。
5. 一時worktreeの全変更をstageし、binary full-index patchを生成する。
6. 呼び出し元で`git apply --check --index`後にpatchを適用し、成功後にこのIssue分だけをunstageして通常のレビュー可能な変更として残す。
7. 一時worktreeを`git worktree remove`で解除する。trapは記録された一時pathだけを対象とする。

いずれかのpreflightまたは一時worktree検証が失敗した場合、呼び出し元は変更しない。patch適用前にもclean stateとHead SHAを再確認し、競合した場合は失敗する。

## 6. Interfaces

Primary command:

```sh
tools/bootstrap-app.sh \
  --display-name 'Garden Notes' \
  --module-name GardenNotes \
  --app-slug garden-notes \
  --bundle-id com.yuto.GardenNotes
```

Machine transformer:

```sh
swift tools/bootstrap-app.swift apply \
  --root /absolute/staging/worktree \
  --manifest Config/template-identity.json \
  --display-name 'Garden Notes' \
  --module-name GardenNotes \
  --app-slug garden-notes \
  --bundle-id com.yuto.GardenNotes
```

Both successful routes emit sanitized JSON containing only`status`、result record path、module name、app slug、Bundle ID。Patch contentや秘密値をstdoutへ出さない。

## 7. Failure behavior

- dirty index/worktree、default Branch、detached caller、source Manifest mismatch: 変更せずexit non-zero
- invalid input、derived name collision、destination path collision: 変更せずexit non-zero
- live file anchorの不足または想定回数違い: 一時worktreeだけを破棄してexit non-zero
- Xcode project list failure、residual audit failure: 一時worktreeだけを破棄してexit non-zero
- same Identity再実行: exit zero、`already-complete`
- conflicting Identity再実行: 変更せずexit non-zero
- cleanup failure: 作成pathを報告し、他のworktreeを削除しない

同一原因の自動再試行は3回までとする。

## 8. Verification

Deterministic tests use local clones of the actual repository and prove:

- valid transformation changes every required Xcode/Swift/config identity
- invalid values、dirty state、default Branch、collision、Manifest drift fail without mutation
- display nameとmodule nameの分離が英語空白名と日本語表示名の双方で維持される
- same/conflicting second-run behavior
- historical/generic template references remain while live residuals are absent
- caller Head and source checkout remain unchanged
- transformed `xcodebuild -list` exposes the renamed Project、Scheme、App/Test targets
- `xcodebuild -showBuildSettings`がApp/Test Bundle ID、Module、Test Host、Test Target、確定済みDeployment Targetを全Configurationで示す

Issue completion also uses one disposable transformed repository to run Build、Unit Test、UI Test、iPhone Pro/iPad Air × English/Japanese launches and screenshot evaluation. File ProviderによるCodeSign metadata混入を避けるため、DerivedDataとresult bundleはrepository外の`/tmp`配下へ置く。

## 9. Shared skill and authority

`.agents/skills/app-bootstrap/SKILL.md`を正本とし、`.claude/skills/app-bootstrap`は相対symlinkにする。Skillは最小Identity仕様、Issue/Branch、bootstrap command、検証、反対モデルレビューの順序を定める。

Claudeはローカル変換とXcode検証を実行できる。GitHub Template repository作成、Issue、Push、PR、Merge、remote repository rename、Bundle ID登録などの認証済み外部操作はCodexだけが実行する。
