# iOS Simulator Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the latest installed iPhone Pro and iPad Air once per Issue batch, verify Japanese and English behavior, and bind reproducible evidence to the current Head SHA.

**Architecture:** A Swift resolver parses CoreSimulator JSON without third-party dependencies. Shell orchestration creates dedicated template Simulators, runs Build/Test and acceptance cases serially, captures screenshots, and writes schema-validated evidence consumed by review and pre-merge gates.

**Tech Stack:** Swift command-line scripts, `xcrun simctl`, `xcodebuild`, XcodeBuildMCP when available, POSIX shell, JSON fixtures

**Spec:** `docs/verification.md`

## Global Constraints

- Select the latest installed available iOS Runtime.
- Select iPhone Pro but exclude Pro Max.
- Select the latest iPad Air.
- Verify `en_US`/`en` and `ja_JP`/`ja` for both device families.
- Resolve the matrix once per batch and reuse it unchanged.
- Do not silently fall back to another device family.
- Serialize Simulator verification and use worktree-specific DerivedData.
- Evidence, review, and current Git Head must use the same SHA.

---

## File map

| Path | Responsibility |
| --- | --- |
| `tools/resolve-simulator-matrix.swift` | Select Runtime and Device Types from JSON |
| `tools/resolve-simulator-matrix.sh` | Query CoreSimulator, invoke resolver, create dedicated Simulators |
| `tools/destroy-simulator-matrix.sh` | Delete only Simulators created for one batch |
| `tools/verify-ios-issue.sh` | Run Build, Test, locale cases, screenshots, and evidence |
| `tools/validate-verify-json.swift` | Enforce evidence schema and SHA rules |
| `tools/visual-review-packet.sh` | Create redacted image-review input |
| `.agents/skills/ios-verify/` | Shared orchestration instructions |
| `tools/tests/fixtures/simctl/` | Versioned CoreSimulator JSON inputs |
| `tools/tests/test-simulator-resolver.sh` | Deterministic resolver tests |
| `tools/tests/test-ios-evidence.sh` | Evidence and stale-SHA tests |

### Task 1: Deterministic Runtime and Device Type resolver

**Files:**
- Create: `tools/resolve-simulator-matrix.swift`
- Create: `tools/tests/test-simulator-resolver.sh`
- Create: `tools/tests/fixtures/simctl/runtimes.json`
- Create: `tools/tests/fixtures/simctl/devicetypes.json`
- Create: `tools/tests/fixtures/simctl/devices.json`

**Interfaces:**
- `resolve-simulator-matrix.swift --runtimes runtimes.json --device-types devicetypes.json --devices devices.json --batch-id settings-2026-08-21`
- Produces matrix JSON on stdout without creating Simulators

- [ ] **Step 1: Create JSON fixtures**

Include two available iOS Runtimes with different semantic versions, one unavailable newer Runtime, iPhone standard, iPhone Pro, iPhone Pro Max, iPad, two iPad Air generations, and 11-inch plus 13-inch variants of the newest Air generation. Include names whose lexical order differs from version order to force semantic comparison.

- [ ] **Step 2: Write failing resolver tests**

Assert selection of the highest available Runtime, highest iPhone Pro excluding Pro Max, and 13-inch iPad Air from the highest generation. Add failure cases for no Pro and no Air. Assert four cases with exact locale/language pairs and stable order `iphone-en`, `iphone-ja`, `ipad-en`, `ipad-ja`.

- [ ] **Step 3: Run tests**

Run: `bash tools/tests/test-simulator-resolver.sh`  
Expected: non-zero because the Swift resolver is absent.

- [ ] **Step 4: Implement Codable input and semantic ordering**

Define `Runtime`, `DeviceType`, `Device`, `Matrix`, and `MatrixCase` Codable structs. Parse version components as integers, ignore unavailable entries, match `iPhone .* Pro` while excluding `Pro Max`, and match names beginning with `iPad Air`. Rank Air by generation first and screen size second, preferring 13-inch over 11-inch within the same generation.

- [ ] **Step 5: Emit stable JSON**

Use `JSONEncoder` with `.prettyPrinted`, `.sortedKeys`, and `.withoutEscapingSlashes`. Include Runtime identifier, version, Device Type identifier and name, locale, language, batch ID, and resolution timestamp supplied through `--resolved-at` during tests.

- [ ] **Step 6: Run tests and commit**

Run: `bash tools/tests/test-simulator-resolver.sh`  
Expected: all selection and failure cases pass.

```bash
git add tools/resolve-simulator-matrix.swift tools/tests
git commit -m "feat: resolve the standard Simulator matrix"
```

### Task 2: Batch matrix lifecycle

**Files:**
- Create: `tools/resolve-simulator-matrix.sh`
- Create: `tools/destroy-simulator-matrix.sh`
- Create: `tools/tests/test-simulator-lifecycle.sh`

**Interfaces:**
- `resolve-simulator-matrix.sh --batch-id settings-2026-08-21 --output .artifacts/batches/settings-2026-08-21/simulator-matrix.json`
- Adds one dedicated Simulator UDID to each matrix case
- `destroy-simulator-matrix.sh --matrix .artifacts/batches/settings-2026-08-21/simulator-matrix.json` deletes only those four UDIDs

- [ ] **Step 1: Write fake-simctl lifecycle tests**

Use a fixture `xcrun` that records arguments. Assert exact `simctl list -j` calls, four `simctl create` calls, reuse of an existing complete matrix, refusal to overwrite a partial matrix, and exact deletion of recorded UDIDs only.

- [ ] **Step 2: Run tests**

Run: `bash tools/tests/test-simulator-lifecycle.sh`  
Expected: non-zero because lifecycle scripts are absent.

- [ ] **Step 3: Implement matrix creation**

Query `simctl list runtimes -j`, `devicetypes -j`, and `devices -j` into the batch artifact directory. Invoke the Swift resolver, then create Simulators with the interpolation `iOS-Template-${batchId}-${caseId}` from the exact Device Type and Runtime identifiers. Insert each returned UDID into the matrix atomically.

- [ ] **Step 4: Implement safe destruction**

Require a matrix under `.artifacts/batches/`, require Simulator names to begin with `iOS-Template-`, confirm each UDID still has the recorded name, then call `simctl delete` for those UDIDs. Refuse any mismatch.

- [ ] **Step 5: Run tests and commit**

Run: `bash tools/tests/test-simulator-lifecycle.sh`  
Expected: all lifecycle safety cases pass.

```bash
git add tools/resolve-simulator-matrix.sh tools/destroy-simulator-matrix.sh tools/tests
git commit -m "feat: manage batch-scoped Simulators"
```

### Task 3: Evidence schema validator

**Files:**
- Create: `tools/validate-verify-json.swift`
- Create: `tools/tests/test-ios-evidence.sh`
- Create: `tools/tests/fixtures/verify/passed.json`
- Create: `tools/tests/fixtures/verify/failed-case.json`
- Create: `tools/tests/fixtures/verify/stale-sha.json`

**Interfaces:**
- `validate-verify-json.swift --file verify.json --expected-issue 42 --expected-head 0123456789abcdef0123456789abcdef01234567`
- Exit zero only for a complete passed result or explicit documented `not-applicable`

- [ ] **Step 1: Write fixture tests**

Test the complete schema-version-1 passed evidence, one failed matrix case, missing screenshot, stale Head SHA, skipped test, added warning, duplicate case ID, missing or changed Issue-contract digest, missing execution route, missing Xcode, missing matrix digest, missing or duplicate acceptance evidence, and an allowed documentation-only `not-applicable` with null matrix/Xcode fields and a non-empty reason.

- [ ] **Step 2: Run tests**

Run: `bash tools/tests/test-ios-evidence.sh`  
Expected: non-zero because the validator is absent.

- [ ] **Step 3: Implement strict decoding**

Decode every required schema-version-1 field from `docs/verification.md`. Require the Issue contract to match the requested Issue and digest and use its `AC-*` list as the only acceptance input. For application changes, require exact SHA, Build passed, zero added warnings, Tests passed with zero failed and zero skipped, the exact four case IDs, execution route, Xcode identity, matching matrix digest, one evidence entry per contract `AC-*`, passed visual evaluation, and existing relative screenshot paths contained under the evidence directory.

- [ ] **Step 4: Implement documentation-only exception**

Allow `status: not-applicable` only when `changeClassification` is `documentation-only`, `reason` is non-empty, matrix path/digest and Xcode are null, execution route is `none`, cases are empty, Build/Tests/visual status are `not-applicable`, and `git diff --name-only "${baseSha}" "${headSha}"` contains no Swift, Xcode project, asset, localization, entitlement, or configuration files. Resolve both SHAs from verify.json and require them to exist before classification. This path must not resolve, create, boot, or require any Simulator.

- [ ] **Step 5: Run tests and commit**

Run: `bash tools/tests/test-ios-evidence.sh`  
Expected: all valid and invalid fixtures classify correctly.

```bash
git add tools/validate-verify-json.swift tools/tests
git commit -m "feat: validate iOS verification evidence"
```

### Task 4: Build and test runner

**Files:**
- Create: `tools/verify-ios-issue.sh`
- Create: `tools/lib/xcode.sh`
- Create: `tools/tests/test-ios-runner.sh`

**Interfaces:**
- `verify-ios-issue.sh --issue 42 --issue-contract .artifacts/issues/42/issue-contract.json --matrix .artifacts/batches/settings-2026-08-21/simulator-matrix.json --project TemplateApp.xcodeproj --scheme TemplateApp`
- With `HEAD_SHA` set from `git rev-parse HEAD`, produces `.artifacts/issues/42/${HEAD_SHA}/verify.json`

- [ ] **Step 1: Write fake-xcodebuild and fake-simctl tests**

Assert one Build and one unit-test invocation per Head SHA, one UI-test or smoke invocation for each of the four locale cases, a unique DerivedData path containing Issue and SHA, four serialized locale launches, Screenshot paths under each case ID, failure propagation, and atomic verify.json creation.

- [ ] **Step 2: Run tests**

Run: `bash tools/tests/test-ios-runner.sh`  
Expected: non-zero because the runner is absent.

- [ ] **Step 3: Implement Xcode environment discovery**

Prefer `/Applications/Xcode.app/Contents/Developer` when it exists; otherwise use `xcode-select -p` only if `xcodebuild -version` succeeds. Never call `sudo xcode-select`. Record the resolved path, Xcode version, and build.

- [ ] **Step 4: Implement Build and Test**

Read the first matrix UDID, set `HEAD_SHA` from `git rev-parse HEAD`, and run `xcodebuild` for the shared scheme with `-derivedDataPath .artifacts/derived-data/42/${HEAD_SHA}` and `-resultBundlePath` inside the Issue artifact directory. Capture a sanitized summary and test counts; retain the `.xcresult` locally.

- [ ] **Step 5: Implement serialized locale cases**

Seal the batch ID, Runtime and Device Type identities, dedicated names, and exact four UDIDs into the runner config. Before Build, validate the complete live four-device ownership set and erase only those dedicated device contents; after unit tests, restore the first UI destination to a clean state. For each recorded UDID: revalidate ownership, boot, wait for boot status, install the built app, launch with `-AppleLanguages` and `-AppleLocale`, run the Issue-specific UI test plan or smoke assertion, durably copy and digest the named host screenshot, revalidate inputs, terminate the target Bundle ID, then shutdown/erase and postcheck that same dedicated device. Failure and TERM reclaim only the active owned case; the next start reclaims all four after SIGKILL. Any identity or reclamation failure emits no draft. `erase` preserves the frozen UDID and is distinct from `delete`; delete the four dedicated devices only after same-Head evidence and opposite-model review complete. Never mutate an unrelated Simulator or partially resume/merge case evidence.

- [ ] **Step 6: Write evidence atomically**

Write to `verify.json.tmp`, including Issue-contract path/digest, matrix digest, execution route, Xcode identity, and `AC-*` evidence mappings; validate it, then rename to `verify.json`. On any failure, preserve a failed evidence file with stage and sanitized error; return non-zero.

- [ ] **Step 7: Run tests and commit**

Run: `bash tools/tests/test-ios-runner.sh`  
Expected: all sequencing, failure, and atomic-write cases pass.

```bash
git add tools/verify-ios-issue.sh tools/lib/xcode.sh tools/tests
git commit -m "feat: run reproducible iOS verification"
```

### Task 5: Visual evaluation packet

**Files:**
- Create: `tools/visual-review-packet.sh`
- Create: `docs/agent-contracts/visual-reviewer.md`
- Create: `tools/tests/test-visual-review-packet.sh`

**Interfaces:**
- `visual-review-packet.sh --issue 42 --evidence verify.json --output visual-packet.json`
- Produces only sanitized metadata and existing image paths

- [ ] **Step 1: Write packet validation tests**

Test exact four cases, missing image, image outside the Issue artifact directory, secret-like filename, mismatched SHA, and a valid UI state with multiple screenshots per case.

- [ ] **Step 2: Implement packet creation**

Read acceptance criteria from the explicit `issueContract.path` and verify its digest, include device, locale, state label, image dimensions, and relative path, and reject symlinks or paths outside the evidence root.

- [ ] **Step 3: Write the visual evaluator contract**

Define checks for clipping, overlap, translation, information hierarchy, iPad adaptation, Dynamic Type indicators, tap targets, and spec-specific comparisons. Require findings to cite case ID and image path.

- [ ] **Step 4: Run tests and commit**

Run: `bash tools/tests/test-visual-review-packet.sh`  
Expected: all path and schema cases pass.

```bash
git add tools/visual-review-packet.sh docs/agent-contracts/visual-reviewer.md tools/tests
git commit -m "feat: package Simulator screenshots for AI evaluation"
```

### Task 6: Shared ios-verify skill

**Files:**
- Create: `.agents/skills/ios-verify/SKILL.md`
- Create: `.claude/skills/ios-verify` as a relative symlink
- Modify: `tools/tests/test-foundation.sh`

**Interfaces:**
- Skill orchestrates matrix reuse, runner, visual evaluation, evidence validation, and review packet creation

- [ ] **Step 1: Add failing integration tests**

Require the shared skill and symlink. Add evidence cases for a missing matrix, matrix modified after verification, failed visual evaluation, and a valid documentation-only exception.

- [ ] **Step 2: Write the skill**

The skill first checks XcodeBuildMCP session defaults when available, otherwise uses the deterministic scripts. It resolves or reuses the batch matrix, executes verification exclusively, requests AI visual evaluation, validates final evidence, and returns the exact artifact path and digest.

- [ ] **Step 3: Complete evidence generation**

Hash the matrix during verification and store its digest in verify.json. Record the execution route and Xcode identity required by the canonical schema. External account preflights remain separate merge-time artifacts.

- [ ] **Step 4: Run the relevant suites**

Run: `bash tools/tests/test-foundation.sh && bash tools/tests/test-ios-evidence.sh`
Expected: all pass.

- [ ] **Step 5: Commit integration**

```bash
git add .agents/skills/ios-verify .claude/skills/ios-verify tools
git commit -m "feat: add shared iOS verification workflow"
```

### Task 7: Live template verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the actual installed Xcode, latest Runtime, and `TemplateApp`
- Produces: one real batch matrix and one passed Issue evidence record in `.artifacts`

- [ ] **Step 1: Resolve the live matrix**

Run the matrix lifecycle tool with batch ID `template-foundation-live`.  
Expected: four dedicated Simulators on one latest installed Runtime.

- [ ] **Step 2: Verify the app**

Codex first reads the Bootstrap Issue and writes the canonical `issue-contract.json` with unique `AC-*` entries. Run `verify-ios-issue.sh` with that contract, `TemplateApp.xcodeproj`, and scheme `TemplateApp`.
Expected: Build and tests pass; four locale cases and screenshots pass.

- [ ] **Step 3: Inspect all four screenshots**

Confirm English and Japanese text values and confirm the layout is usable on iPhone Pro and iPad Air. Record any real finding, fix it in the same Issue, and rerun all affected evidence.

- [ ] **Step 4: Run the opposite-model review**

Include the four screenshots and final verify.json.  
Expected: approved for the same Head SHA.

- [ ] **Step 5: Destroy only the dedicated Simulators**

Run the matrix destruction tool with the recorded matrix.  
Expected: the four `iOS-Template-template-foundation-live-*` Simulators are removed; unrelated Simulators remain.

- [ ] **Step 6: Document the verified workflow and commit**

Add exact live Xcode, Runtime, Device Type, test count, and commands to README without committing `.artifacts`.

```bash
git add README.md
git commit -m "docs: record live Simulator verification"
```

- [ ] **Step 7: Complete the final Bootstrap gate manually**

Codex records GitHub account preflight, all `AC-*` mappings, final verify.json digest, opposite-model approval, and matching Head SHA in the PR. Codex uses `gh pr merge --squash --match-head-commit` and removes only this Issue's Branch and worktree. All later Issues use the verification tools created here.
