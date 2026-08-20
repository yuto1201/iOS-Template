# iOS Template Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a minimal vanilla SwiftUI template that supports iPhone, iPad, Japanese, English, shared agent instructions, and read-only evaluator agents.

**Architecture:** Keep the Xcode project close to Apple's new-project layout. Put durable behavior in `AGENTS.md` and `specs/`; place shared skill content in `.agents/skills` and expose it to Claude through relative symlinks, while keeping native agent wrappers in model-specific directories.

**Tech Stack:** SwiftUI, Swift Testing, XCUITest, Xcode project, POSIX shell, Codex project agents, Claude project agents

**Spec:** `specs/architecture.md`

## Global Constraints

- The app supports iPhone and iPad.
- The app supports Japanese and English.
- No `CLAUDE.md` file is created.
- No remote database, audio SDK, analytics SDK, payment SDK, or notification capability is added.
- `.agents/skills` is the canonical shared skill location.
- Evaluator agents are read-only.

---

## File map

| Path | Responsibility |
| --- | --- |
| `.gitignore` | Ignore local artifacts, worktrees, local configuration, and Supabase runtime state |
| `Config/` | Public build configuration, local example, and centralized ownership expectations |
| `TemplateApp.xcodeproj/` | Vanilla Xcode project with app, unit-test, and UI-test targets |
| `TemplateApp/` | Minimal localized SwiftUI application |
| `TemplateAppTests/` | Swift Testing unit tests |
| `TemplateAppUITests/` | XCUITest launch and localization smoke tests |
| `.agents/skills/spec-workflow/` | Canonical specification workflow |
| `.claude/skills/spec-workflow` | Relative symlink to the canonical skill |
| `.codex/agents/*.toml` | Codex evaluator definitions |
| `.claude/agents/*.md` | Claude evaluator definitions |
| `docs/agent-contracts/*.md` | Shared evaluator criteria |
| `tools/tests/test-foundation.sh` | Repository policy and layout test |
| `tools/check-markdown-links.swift` | Validate local Markdown links across repository guidance |

## Bootstrap prerequisite

Before creating the Foundation Issue, Codex must verify that the Xcode application is installed and that its local `computer-use` capability is callable. This capability is required only to drive Apple's new-project UI; it does not contact an authenticated external service. Record the successful capability check in the Issue. If it is unavailable, do not create or claim the Issue until the capability is enabled; no downstream plan starts. XcodeBuildMCP is used for Build, Test, and Simulator work, but this plan does not assume it exposes project scaffolding unless that callable tool is actually present at execution time.

### Task 1: Repository policy test

**Files:**
- Create: `.gitignore`
- Create: `tools/tests/test-foundation.sh`
- Create: `tools/check-markdown-links.swift`
- Create: `Config/Public.xcconfig`
- Create: `Config/Local.xcconfig.example`
- Create: `Config/ownership.yml`

**Interfaces:**
- Consumes: `specs/architecture.md`
- Produces: executable `tools/tests/test-foundation.sh` returning zero only when the required structure is valid

- [ ] **Step 1: Write the failing repository policy test**

Create `tools/tests/test-foundation.sh` with strict shell mode. It must assert that `AGENTS.md`, all four specification files, and `docs/AUTHORITY.md` exist; that `CLAUDE.md` does not exist; and that each `.claude/skills` entry is a relative symlink whose target resolves inside `.agents/skills`.

```bash
#!/usr/bin/env bash
set -euo pipefail

test -f AGENTS.md
test -f specs/product.md
test -f specs/architecture.md
test -f specs/acceptance.md
test -f specs/decisions.md
test -f docs/AUTHORITY.md
test ! -e CLAUDE.md

for link in .claude/skills/*; do
  test -L "$link"
  target=$(readlink "$link")
  case "$target" in
    ../../.agents/skills/*) ;;
    *) echo "invalid Claude skill target: $link -> $target" >&2; exit 1 ;;
  esac
  test -f "$link/SKILL.md"
done
```

- [ ] **Step 2: Run the test and confirm the missing scaffold fails**

Run: `bash tools/tests/test-foundation.sh`  
Expected: non-zero because the skill and agent directories do not exist yet.

- [ ] **Step 3: Add ignore rules**

Create `.gitignore` with these entries:

```gitignore
.DS_Store
xcuserdata/
DerivedData/
.artifacts/
.worktrees/
Config/Local.xcconfig
*.p8
*.mobileprovision
.env
.env.*
!.env.example
supabase/.temp/
supabase/.branches/
```

- [ ] **Step 4: Add public configuration and ownership**

Create `Config/Public.xcconfig` with optional inclusion `#include? "Local.xcconfig"` and no provider values. Create `Config/Local.xcconfig.example` with comments explaining local non-secret client configuration. Create `Config/ownership.yml` with schema version 1, GitHub login `yuto1201`, Supabase Organization `YUTO1201`, and null app-specific Supabase Project Ref, Cloudflare Account ID, App Store Team ID, and Bundle ID. Provider preflight must later reject null required values.

- [ ] **Step 5: Add the Markdown link checker**

Write a Swift script that scans `README.md`, `AGENTS.md`, `specs/**/*.md`, and `docs/**/*.md`; extracts local Markdown destinations; decodes `%20`; ignores HTTP(S) and same-document anchors; and exits non-zero with source file and destination when a local target does not exist. Add it to `test-foundation.sh`.

- [ ] **Step 6: Commit the policy test**

```bash
git add .gitignore Config tools/check-markdown-links.swift tools/tests/test-foundation.sh
git commit -m "test: define template foundation policy"
```

### Task 2: Minimal Xcode project

**Files:**
- Create: `TemplateApp.xcodeproj/project.pbxproj`
- Create: `TemplateApp.xcodeproj/xcshareddata/xcschemes/TemplateApp.xcscheme`
- Create: `TemplateApp/TemplateAppApp.swift`
- Create: `TemplateApp/ContentView.swift`
- Create: `TemplateApp/Assets.xcassets/Contents.json`
- Create: `TemplateAppTests/TemplateAppTests.swift`
- Create: `TemplateAppUITests/TemplateAppUITests.swift`

**Interfaces:**
- Produces: shared scheme `TemplateApp` with app, unit-test, and UI-test targets
- Produces: accessibility identifier `template.welcome-title`

- [ ] **Step 1: Create the project through Xcode's iOS App template**

Codex uses the prerequisite-verified `computer-use` capability to drive Xcode's iOS App template with these exact selections: Product Name `TemplateApp`, Interface `SwiftUI`, Language `Swift`, Testing System `Swift Testing with UI Tests`, Storage `None`, Include Tests enabled. Save the project at the repository root and do not initialize another Git repository. If the verified capability becomes unavailable during the Issue, set `blocked:environment`; do not hand-author `project.pbxproj` or silently introduce XcodeGen.

- [ ] **Step 2: Configure supported destinations and signing-neutral defaults**

Set the app target's Supported Destinations to iPhone and iPad. Keep the generated signing settings unchanged and pass `CODE_SIGNING_ALLOWED=NO` only to Simulator build commands. Set the generated shared scheme name to `TemplateApp` and verify `xcuserdata` is not tracked.

- [ ] **Step 3: Replace the generated view with a deterministic launch screen**

Use this body in `ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "app.dashed")
                .font(.largeTitle)
                .accessibilityHidden(true)

            Text("template.welcome")
                .font(.headline)
                .accessibilityIdentifier("template.welcome-title")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 4: Add the first failing unit and UI tests**

The unit test asserts that both localization keys exist through a small `Bundle` lookup helper. The UI test launches the app and waits up to five seconds for `template.welcome-title`.

- [ ] **Step 5: Build and test the scheme**

Run the XcodeBuildMCP session-default check, select the generated project, shared scheme, and an available iPhone Pro Simulator, then run Build and Test. If XcodeBuildMCP is unavailable, set `SIMULATOR_UDID` from the selected entry in `xcrun simctl list devices available` and run `xcodebuild -project TemplateApp.xcodeproj -scheme TemplateApp -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" test`.

Expected: Build passes; localization unit test still fails until Task 3; UI launch test passes.

- [ ] **Step 6: Commit the minimal project**

```bash
git add TemplateApp.xcodeproj TemplateApp TemplateAppTests TemplateAppUITests
git commit -m "feat: add minimal SwiftUI template app"
```

### Task 3: Japanese and English localization

**Files:**
- Create: `TemplateApp/Localizable.xcstrings`
- Modify: `TemplateAppTests/TemplateAppTests.swift`
- Modify: `TemplateAppUITests/TemplateAppUITests.swift`
- Modify: `TemplateApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: localization key `template.welcome` with English `Ready to build` and Japanese `開発を始められます`
- Produces: UI tests accepting `-AppleLanguages` and `-AppleLocale`

- [ ] **Step 1: Add the String Catalog**

Create `Localizable.xcstrings` with source language `en`, key `template.welcome`, English value `Ready to build`, and Japanese value `開発を始められます`.

- [ ] **Step 2: Complete localization tests**

Make the unit test load both `en` and `ja` localizations and assert the exact two values. Add two UI test methods that launch with `-AppleLanguages (en) -AppleLocale en_US` and `-AppleLanguages (ja) -AppleLocale ja_JP`, then assert the localized label.

- [ ] **Step 3: Wire the public build configuration**

Set Debug and Release Base Configuration to `Config/Public.xcconfig`, which optionally includes the Git-ignored `Local.xcconfig`. Run `xcodebuild -list -project TemplateApp.xcodeproj` and confirm all three targets and shared scheme are present.

- [ ] **Step 4: Run all tests**

Run the `TemplateApp` scheme tests on an available iPhone Pro.  
Expected: all unit and UI tests pass without skipped tests.

- [ ] **Step 5: Commit localization**

```bash
git add TemplateApp/Localizable.xcstrings TemplateAppTests TemplateAppUITests
git commit -m "feat: add English and Japanese template localization"
```

### Task 4: Shared specification skill

**Files:**
- Create: `.agents/skills/spec-workflow/SKILL.md`
- Create: `.agents/skills/spec-workflow/templates/decision.md`
- Create: `.agents/skills/spec-workflow/scripts/check-spec-state.sh`
- Create: `.claude/skills/spec-workflow` as a relative symlink
- Test: `tools/tests/test-foundation.sh`

**Interfaces:**
- Produces: `check-spec-state.sh issue-body.md` returning 0 only when no `Status: 未決` anchor is referenced

- [ ] **Step 1: Add a failing skill-layout assertion**

Extend `test-foundation.sh` to require `spec-workflow/SKILL.md`, its decision template, executable checker, and the Claude symlink.

- [ ] **Step 2: Run the policy test**

Run: `bash tools/tests/test-foundation.sh`  
Expected: non-zero because the skill is absent.

- [ ] **Step 3: Write the skill and checker**

The skill must read `specs/README.md`, classify each decision as 確定・提案・未決, append decisions rather than rewriting history, and stop before implementation when an acceptance-affecting item is 未決. The checker reads the Issue body file path from its only argument and rejects references whose surrounding specification section contains `Status: 未決`.

- [ ] **Step 4: Create the relative Claude symlink**

From `.claude/skills`, create `spec-workflow -> ../../.agents/skills/spec-workflow` and verify it resolves after cloning to a different absolute path.

- [ ] **Step 5: Run the policy test and commit**

Run: `bash tools/tests/test-foundation.sh`  
Expected: skill assertions pass; evaluator assertions added in Task 5 may still fail.

```bash
git add .agents .claude tools/tests/test-foundation.sh
git commit -m "feat: add shared specification workflow skill"
```

### Task 5: Read-only evaluator agents

**Files:**
- Create: `docs/agent-contracts/spec-reviewer.md`
- Create: `docs/agent-contracts/ios-reviewer.md`
- Create: `docs/agent-contracts/acceptance-auditor.md`
- Create: `docs/agent-contracts/release-auditor.md`
- Create: `.codex/agents/spec-reviewer.toml`
- Create: `.codex/agents/ios-reviewer.toml`
- Create: `.codex/agents/acceptance-auditor.toml`
- Create: `.codex/agents/release-auditor.toml`
- Create: `.claude/agents/spec-reviewer.md`
- Create: `.claude/agents/ios-reviewer.md`
- Create: `.claude/agents/acceptance-auditor.md`
- Create: `.claude/agents/release-auditor.md`
- Test: `tools/tests/test-foundation.sh`

**Interfaces:**
- Produces: four matching evaluator names in both model-native formats
- Consumes: shared criteria in `docs/agent-contracts/`

- [ ] **Step 1: Extend the failing policy test**

For each evaluator name, require a Codex TOML file, Claude Markdown file, and shared contract file. Assert every Codex file contains `sandbox_mode = "read-only"`; assert every Claude file declares only read-oriented tools.

- [ ] **Step 2: Write shared contracts**

Each contract defines inputs, ordered checks, finding schema, severity, approval rule, and the prohibition on editing or external operations. `acceptance-auditor` must use `docs/agent-contracts/review-packet.md`.

- [ ] **Step 3: Write Codex native wrappers**

Every TOML file defines exact `name`, `description`, multiline `developer_instructions`, and `sandbox_mode = "read-only"`. Instructions tell the agent to read only its matching shared contract and the packet passed by the parent.

- [ ] **Step 4: Write Claude native wrappers**

Every Markdown file defines YAML frontmatter with matching `name`, narrow `description`, and read-only `tools: Read, Glob, Grep`. The body references the matching shared contract.

- [ ] **Step 5: Run the foundation test**

Run: `bash tools/tests/test-foundation.sh`  
Expected: zero.

- [ ] **Step 6: Commit evaluator agents**

```bash
git add .codex/agents .claude/agents docs/agent-contracts tools/tests/test-foundation.sh
git commit -m "feat: add cross-model evaluator agents"
```

### Task 6: Foundation verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: all outputs in Tasks 1-5
- Produces: a clone-ready, buildable foundation and documented verification result

- [ ] **Step 1: Run repository tests**

Run: `bash tools/tests/test-foundation.sh`  
Expected: zero.

- [ ] **Step 2: Run Xcode tests on iPhone**

Build and test `TemplateApp` on an available iPhone Pro.  
Expected: all unit and UI tests pass.

- [ ] **Step 3: Run Xcode tests on iPad**

Build and test `TemplateApp` on an available iPad Air.  
Expected: all unit and UI tests pass.

- [ ] **Step 4: Verify tracked files**

Run `git ls-files` and confirm it contains no `xcuserdata`, `.artifacts`, `DerivedData`, `.env`, `.p8`, or `CLAUDE.md`.

- [ ] **Step 5: Update README and commit**

Update README status from design-only to foundation-ready and include exact Build/Test commands used.

```bash
git add README.md
git commit -m "docs: record template foundation verification"
```

- [ ] **Step 6: Complete the Bootstrap gate manually**

Codex records all `AC-*` evidence, GitHub account preflight, Build/Test results, the four standard Simulator cases, opposite-model review, and matching Head SHA in the PR. Codex then uses `gh pr merge --squash --match-head-commit` and explicitly removes only this Issue's Branch and worktree.
