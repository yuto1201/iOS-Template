# App Identity Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert a newly generated iOS-Template repository from `TemplateApp` to one validated app identity before feature development, without partial or broad replacement.

**Architecture:** A Codable JSON manifest defines the source identity and exact live paths. A Swift transformer performs validated path/content changes inside a detached temporary Git worktree; a shell orchestrator applies the resulting checked patch to a clean Issue worktree only after residual and Xcode project validation.

**Tech Stack:** Swift command-line scripts, POSIX shell, Git worktrees and patches, Xcode project/scheme text formats, shell integration tests

**Spec:** `docs/superpowers/specs/2026-08-22-app-bootstrap-design.md`

## Global Constraints

- Require a clean nondefault Branch and an unchanged Head SHA before applying any patch.
- Accept exactly display name, module name, app slug, and Bundle ID; derive Test identities.
- Do not rename GitHub remotes, register Bundle IDs, change Signing Team, or call authenticated providers.
- Transform only Manifest-declared live paths; preserve historical plans and generic `iOS-Template` namespaces.
- Use repository-external temporary worktrees and DerivedData under `/tmp`.
- The same identity is idempotent; a conflicting second identity fails without mutation.
- Minimum iOS remains a separately confirmed app specification and must survive the identity transformation unchanged.
- Feature Issues remain blocked until the app-specific product and acceptance specs are confirmed.
- No production transformation code is written before its behavior test has failed for the expected reason.

---

## File map

| Path | Responsibility |
| --- | --- |
| `Config/template-identity.json` | Versioned source identity, rename paths, live content paths, residual policy |
| `Config/app-identity.json` | Generated non-secret result record in bootstrapped app repositories |
| `tools/bootstrap-app.swift` | Input validation, controlled content/path transformation, residual audit |
| `tools/bootstrap-app.sh` | Git preflight, temporary worktree, validation, checked patch application, cleanup |
| `tools/tests/test-app-bootstrap.sh` | Real local-clone behavior tests and mutation-safety assertions |
| `.agents/skills/app-bootstrap/SKILL.md` | Shared Codex/Claude orchestration procedure |
| `.claude/skills/app-bootstrap` | Relative link to the shared skill |

### Task 1: Confirm specification and roadmap

**Files:**
- Modify: `specs/product.md`
- Modify: `specs/architecture.md`
- Modify: `specs/acceptance.md`
- Modify: `specs/decisions.md`
- Create: `docs/superpowers/specs/2026-08-22-app-bootstrap-design.md`
- Create: `docs/superpowers/plans/2026-08-22-app-bootstrap.md`
- Modify: `docs/superpowers/plans/README.md`

**Interfaces:**
- Consumes: approved Issue #5 body and user-approved manifest-driven design
- Produces: confirmed D-022, exact transformation boundary, and executable plan

- [ ] **Step 1: Validate the saved Issue body against referenced specs**

Run:

```sh
.agents/skills/spec-workflow/scripts/check-spec-state.sh .artifacts/issues/5/issue-body.md
```

Expected: `Referenced specification sections are implementation-ready.`

- [ ] **Step 2: Run link and policy checks**

Run:

```sh
swift tools/check-markdown-links.swift
bash tools/tests/test-foundation.sh
```

Expected: all local links resolve and Foundation policy checks pass.

- [ ] **Step 3: Self-review the design and plan**

Run:

```sh
python3 - <<'PY'
from pathlib import Path
patterns = ["T" + "BD", "TO" + "DO", "implement " + "later", "Status: " + "提案", "Status: " + "未決"]
paths = [Path("docs/superpowers/specs/2026-08-22-app-bootstrap-design.md"), Path("docs/superpowers/plans/2026-08-22-app-bootstrap.md"), *Path("specs").glob("*.md")]
hits = [(str(path), pattern) for path in paths for pattern in patterns if pattern in path.read_text()]
raise SystemExit(hits)
PY
```

Expected: no unresolved or placeholder result.

- [ ] **Step 4: Commit the confirmed contract**

```sh
git add -- specs/product.md specs/architecture.md specs/acceptance.md specs/decisions.md \
  docs/superpowers/specs/2026-08-22-app-bootstrap-design.md \
  docs/superpowers/plans/2026-08-22-app-bootstrap.md \
  docs/superpowers/plans/README.md
git commit -m "docs: define safe app identity bootstrap"
```

### Task 2: Source manifest and input contract

**Files:**
- Create: `Config/template-identity.json`
- Create: `tools/tests/test-app-bootstrap.sh`
- Create: `tools/bootstrap-app.swift`

**Interfaces:**
- `swift tools/bootstrap-app.swift validate --manifest Config/template-identity.json --display-name NAME --module-name MODULE --app-slug SLUG --bundle-id ID`
- Produces sanitized JSON with normalized values or a nonzero validation error without echoing untrusted control characters

- [ ] **Step 1: Write failing validation tests**

Create a table that invokes the real Swift command with these literal cases:

```text
valid:    Garden Notes | GardenNotes | garden-notes | com.yuto.GardenNotes
invalid:  empty display name
invalid:  display name containing /
invalid:  module beginning with a digit
invalid:  module containing whitespace
invalid:  module equal to TemplateApp
invalid:  Swift keyword as module
invalid:  uppercase app slug
invalid:  slug with adjacent hyphens
invalid:  bundle ID without a dot
invalid:  bundle segment beginning with a hyphen
```

For the valid case assert literal JSON values. For every invalid case assert nonzero status and an unchanged fixture hash.

- [ ] **Step 2: Run the test and confirm RED**

Run: `bash tools/tests/test-app-bootstrap.sh validation`

Expected: failure because `Config/template-identity.json` and `tools/bootstrap-app.swift` do not exist.

- [ ] **Step 3: Add the versioned manifest**

Use schema version 1 with these source values and exact path sets:

```json
{
  "schemaVersion": 1,
  "source": {
    "project": "TemplateApp",
    "module": "TemplateApp",
    "bundleId": "com.yuto.TemplateApp"
  },
  "renamePaths": [
    "TemplateApp.xcodeproj/xcshareddata/xcschemes/TemplateApp.xcscheme",
    "TemplateApp.xcodeproj",
    "TemplateApp/TemplateAppApp.swift",
    "TemplateAppTests/TemplateAppTests.swift",
    "TemplateAppUITests/TemplateAppUITests.swift",
    "TemplateApp",
    "TemplateAppTests",
    "TemplateAppUITests"
  ],
  "liveContentPaths": [
    "AGENTS.md",
    "README.md",
    "Config/ownership.yml",
    "specs/architecture.md",
    "docs/verification.md",
    "docs/security.md",
    "docs/agent-contracts/review-packet.md"
  ]
}
```

The transformer additionally resolves renamed Xcode/Swift files from this source identity; no path is accepted from command-line input.

- [ ] **Step 4: Implement minimal Codable validation**

Define `TemplateManifest`, `SourceIdentity`, `AppIdentity`, `Command`, and `BootstrapError`. Validate inputs with anchored regular expressions and lengths. Encode success using `JSONEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`.

- [ ] **Step 5: Run validation tests and commit**

Run: `bash tools/tests/test-app-bootstrap.sh validation`

Expected: all valid/invalid table rows pass.

```sh
git add -- Config/template-identity.json tools/bootstrap-app.swift tools/tests/test-app-bootstrap.sh
git commit -m "feat: validate app bootstrap identity"
```

### Task 3: Controlled content and path transformation

**Files:**
- Modify: `tools/tests/test-app-bootstrap.sh`
- Modify: `tools/bootstrap-app.swift`

**Interfaces:**
- `bootstrap-app.swift apply --root ROOT ...` mutates only the supplied staging root
- Produces renamed Project/App/Test paths and `Config/app-identity.json`

- [ ] **Step 1: Write the failing valid-transformation test**

Create a real local clone, checkout Branch `codex/test-bootstrap`, call the Swift `apply` command directly, and assert these literals:

```text
GardenNotes.xcodeproj
GardenNotes.xcodeproj/xcshareddata/xcschemes/GardenNotes.xcscheme
GardenNotes/GardenNotesApp.swift
GardenNotesTests/GardenNotesTests.swift
GardenNotesUITests/GardenNotesUITests.swift
PRODUCT_BUNDLE_IDENTIFIER = com.yuto.GardenNotes;
PRODUCT_BUNDLE_IDENTIFIER = com.yuto.GardenNotesTests;
PRODUCT_BUNDLE_IDENTIFIER = com.yuto.GardenNotesUITests;
@testable import GardenNotes
struct GardenNotesApp: App
"garden-notes.welcome"
"garden-notes.welcome-title"
ios-template/garden-notes/elevenlabs/production/api-key
"file": "GardenNotes/Settings/NotificationSettings.swift"
```

Parse `Config/app-identity.json` and assert exact schema and input values. Run `xcodebuild -list -json -project GardenNotes.xcodeproj` and assert Project, Scheme, and all three targets.

- [ ] **Step 2: Run the test and confirm RED**

Run: `bash tools/tests/test-app-bootstrap.sh transform`

Expected: validation succeeds but `apply` reports that transformation is not implemented.

- [ ] **Step 3: Implement counted content replacements**

Implement helpers with exact contracts:

```swift
func replaceExactly(_ old: String, with new: String, in path: URL, minimumCount: Int) throws
func insertDisplayName(_ displayName: String, bundleID: String, inPBXProj path: URL) throws
func writeIdentity(_ identity: AppIdentity, to path: URL) throws
```

Every required anchor must meet its minimum count. Apply `TemplateApp` to module replacement only in declared live content plus the resolved pbxproj, scheme, and Swift files. Replace `template.welcome` and `template.welcome-title` only in App/Test/localization files, and replace `template-app` only in the three security examples. Set only `appStore.bundleId` under `Config/ownership.yml`; preserve GitHub, Supabase, Cloudflare, Team, and Signing values. Insert escaped `INFOPLIST_KEY_CFBundleDisplayName` in the two App target configurations identified by the exact new App Bundle ID block.

- [ ] **Step 4: Implement ordered path renames**

Resolve all paths under `--root`, reject symlinks and destination collisions, then rename deepest paths first. Rename files before parent directories and `.xcodeproj` last. Do not invoke a shell from Swift.

- [ ] **Step 5: Run transform tests and commit**

Run: `bash tools/tests/test-app-bootstrap.sh transform`

Expected: all path, content, identity, and `xcodebuild -list` assertions pass.

```sh
git add -- tools/bootstrap-app.swift tools/tests/test-app-bootstrap.sh
git commit -m "feat: transform template app identity"
```

### Task 4: Transactional Git orchestration

**Files:**
- Create: `tools/bootstrap-app.sh`
- Modify: `tools/tests/test-app-bootstrap.sh`

**Interfaces:**
- `tools/bootstrap-app.sh --display-name NAME --module-name MODULE --app-slug SLUG --bundle-id ID`
- Applies one checked patch to a clean caller and leaves the resulting changes unstaged for review

- [ ] **Step 1: Write the failing transaction test**

In a local clone on `codex/test-bootstrap`, record `git rev-parse HEAD`, caller status, and source-tree digest. Invoke the missing shell command. After success is implemented, assert:

- caller Head is unchanged
- expected renamed changes exist and are unstaged
- no temporary worktree remains in `git worktree list --porcelain`
- the original test-runner repository digest is unchanged

- [ ] **Step 2: Run the test and confirm RED**

Run: `bash tools/tests/test-app-bootstrap.sh transaction`

Expected: nonzero because `tools/bootstrap-app.sh` does not exist.

- [ ] **Step 3: Implement caller preflight**

Require repository root, symbolic Branch not `main` or `master`, clean `git status --porcelain=v1`, no `Config/app-identity.json` except the idempotent route, readable manifest, and exact starting Head. Resolve all paths with `pwd -P`; never accept a caller-supplied temporary path.

- [ ] **Step 4: Implement temporary worktree and patch**

Use this lifecycle with quoted variables and a trap scoped to recorded paths:

```sh
stage_parent=$(mktemp -d /tmp/ios-template-bootstrap.XXXXXX)
stage_worktree="$stage_parent/worktree"
patch_file="$stage_parent/bootstrap.patch"
git worktree add --detach "$stage_worktree" "$start_head"
swift "$stage_worktree/tools/bootstrap-app.swift" apply --root "$stage_worktree" ...
git -C "$stage_worktree" add -A
git -C "$stage_worktree" diff --cached --binary --full-index > "$patch_file"
git apply --check --index "$patch_file"
git apply --index "$patch_file"
git reset HEAD --
git worktree remove "$stage_worktree"
```

Before the first caller `git apply`, recheck caller Head and cleanliness. The cleanup trap calls `git worktree remove` only when the recorded path appears in `git worktree list` and never deletes a broad directory.

- [ ] **Step 5: Run transaction tests and commit**

Run: `bash tools/tests/test-app-bootstrap.sh transaction`

Expected: the caller receives one complete unstaged transformation and temporary worktree registration is removed.

```sh
git add -- tools/bootstrap-app.sh tools/tests/test-app-bootstrap.sh
git commit -m "feat: apply bootstrap through checked git patch"
```

### Task 5: Failure safety, residual audit, and idempotency

**Files:**
- Modify: `tools/bootstrap-app.swift`
- Modify: `tools/bootstrap-app.sh`
- Modify: `tools/tests/test-app-bootstrap.sh`

**Interfaces:**
- `bootstrap-app.swift audit --root ROOT --manifest ... --module-name MODULE`
- Returns zero only when all live source paths are transformed and approved historical/generic references are untouched

- [ ] **Step 1: Write table-driven failing safety tests**

Create separate real clones for dirty worktree, default Branch, detached caller, precreated `GardenNotes/`, changed source Bundle ID, missing Scheme anchor, case-insensitive destination collision, symlink escape, same second run, and conflicting second run. Add invalid slash, dot-dot, newline, shell metacharacter, leading-digit module, Swift keyword, and source-name no-op inputs. For every rejected case compare literal pre/post `git status --porcelain=v1`, Head, and content digest. For the same second run assert status `already-complete` and no diff change.

- [ ] **Step 2: Run safety tests and confirm RED**

Run: `bash tools/tests/test-app-bootstrap.sh safety`

Expected: at least the residual, second-run, and Manifest-drift cases fail against the Task 4 implementation.

- [ ] **Step 3: Implement residual and provenance audit**

Audit the resolved Project/Scheme/App/Test paths plus every Manifest `liveContentPaths` entry. Reject `TemplateApp` in those live locations after applying the allowed targeted transformations. Confirm historical plan file hashes captured before transformation are identical afterward.

- [ ] **Step 4: Implement second-run and drift behavior**

If `Config/app-identity.json` exists, decode it before the clean-state requirement. Exact input equality returns sanitized `already-complete`; any mismatch exits nonzero. Reject a Manifest source identity when required source paths or counted anchors do not match.

- [ ] **Step 5: Run the complete deterministic suite and commit**

Run: `bash tools/tests/test-app-bootstrap.sh all`

Expected: validation, transform, transaction, and every safety case pass.

```sh
git add -- tools/bootstrap-app.swift tools/bootstrap-app.sh tools/tests/test-app-bootstrap.sh
git commit -m "test: enforce bootstrap failure safety"
```

### Task 6: Shared skill and user workflow

**Files:**
- Create: `.agents/skills/app-bootstrap/SKILL.md`
- Create: `.claude/skills/app-bootstrap` relative symlink
- Modify: `README.md`
- Modify: `tools/tests/test-foundation.sh`

**Interfaces:**
- Shared skill orders minimum spec, Issue/Branch, command, review, verification, and Codex-only GitHub operations

- [ ] **Step 1: Add failing behavior/layout checks**

Extend Foundation checks to require executable tools, schema-version-1 Manifest, shared skill, exact relative symlink target `../../.agents/skills/app-bootstrap`, and a dry validation command. Run the tool rather than grepping its implementation.

- [ ] **Step 2: Run checks and confirm RED**

Run: `bash tools/tests/test-foundation.sh`

Expected: failure because the skill and symlink are absent.

- [ ] **Step 3: Write the shared skill**

Require the fixed order: confirm Identity and Deployment Target in specs, create approved Issue, create nondefault Branch/worktree, invoke the command, inspect `git diff`, run Foundation and Xcode tests outside File Provider DerivedData, perform four Simulator cases, request opposite-model review, then let Codex perform PR/Squash Merge/cleanup. State that remote repository rename and Bundle ID registration are separate Codex operations.

- [ ] **Step 4: Update README and create the symlink**

Document the command, input examples, output record, same/conflicting second run, and feature-development gate. Create:

```sh
ln -s ../../.agents/skills/app-bootstrap .claude/skills/app-bootstrap
```

- [ ] **Step 5: Run policy and link checks and commit**

Run:

```sh
bash tools/tests/test-foundation.sh
swift tools/check-markdown-links.swift
```

Expected: both pass.

```sh
git add -- .agents/skills/app-bootstrap .claude/skills/app-bootstrap README.md tools/tests/test-foundation.sh
git commit -m "docs: add shared app bootstrap workflow"
```

### Task 7: Disposable repository Xcode verification

**Files:**
- No tracked file required unless a failure requires a tested fix
- Produce: `.artifacts/issues/5/<head-sha>/disposable-verification.json`

**Interfaces:**
- Consumes the final command from current Head
- Produces sanitized evidence for a local disposable clone transformed to `BootstrapFixture`

- [ ] **Step 1: Create and transform a disposable local clone**

Clone current worktree without contacting a remote, checkout `codex/fixture-bootstrap`, and run:

```sh
tools/bootstrap-app.sh \
  --display-name 'Bootstrap Fixture' \
  --module-name BootstrapFixture \
  --app-slug bootstrap-fixture \
  --bundle-id com.yuto.BootstrapFixture
```

Expected: complete transformed diff and no `TemplateApp` residual in live paths.

- [ ] **Step 2: Validate the renamed Xcode graph**

Run `xcodebuild -list -json -project BootstrapFixture.xcodeproj` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, then use `-showBuildSettings` for App, Unit Test, and UI Test in Debug and Release.

Expected: Scheme and App target `BootstrapFixture`, Unit target `BootstrapFixtureTests`, UI target `BootstrapFixtureUITests`; exact App/Test Bundle IDs, Module, Test Host, Test Target, device family, locales, Signing Team, and confirmed Deployment Target are preserved or transformed according to the design.

- [ ] **Step 3: Build and run tests outside the repository**

Allocate `mktemp -d /tmp/ios-template-issue5-xcode.XXXXXX` and run the renamed scheme on the batch-selected iPhone Pro. Do not use DerivedData under `Documents` because File Provider adds code-signing-prohibited metadata.

Expected: Build, one Swift Testing test, and two XCUITest localization tests pass with no skipped test.

- [ ] **Step 4: Record sanitized evidence**

Write JSON containing Issue 5, current Head SHA, Xcode version/build, Runtime, selected device types, transformed module/Bundle ID, test counts, command exit statuses, and no absolute secret paths. Keep it under `.artifacts` and do not commit it.

### Task 8: Four-case acceptance, opposite review, and handoff

**Files:**
- No tracked file required unless verification/review finds a tested defect
- Produce: `.artifacts/issues/5/<head-sha>/screenshots/` and review packet/result

**Interfaces:**
- Uses latest available iPhone Pro excluding Pro Max and latest iPad Air on one latest installed iOS Runtime
- Produces Head-SHA-bound evidence covering AC-1 through AC-8

- [ ] **Step 1: Freeze the manual Bootstrap matrix**

Resolve one latest available iOS Runtime, iPhone Pro excluding Pro Max, and latest iPad Air. Record exact identifiers and use `en_US/en` and `ja_JP/ja` for four serialized cases.

- [ ] **Step 2: Run and capture all four cases**

Install and launch `BootstrapFixture`, pass Apple language/locale arguments, assert the localized welcome title, and capture one screenshot per case under the Head-scoped Issue artifact directory.

- [ ] **Step 3: Perform AI visual evaluation**

Inspect all four images for clipping, overlap, language correctness, iPhone/iPad adaptation, and renamed app identity. Map each Issue `AC-*` to deterministic or visual evidence.

- [ ] **Step 4: Run opposite-model review**

Send Issue body, specs, Base SHA, Head SHA, diff, deterministic test results, Xcode evidence, and screenshots to Claude in read-only mode. Require an approved result for the same Head SHA and resolve every blocking finding in this Issue with a new test and full affected re-verification.

- [ ] **Step 5: Prepare PR handoff**

Run all repository tests from the final Head, verify no secret/unrelated file is staged, push only `codex/5-app-bootstrap`, create one PR closing #5, include verification/review digests, and use exact Head SHA for Squash Merge. Confirm Issue closure, then remove only the merged remote Branch, local Branch, and worktree.
