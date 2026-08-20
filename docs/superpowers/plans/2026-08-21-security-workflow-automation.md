# Security and Workflow Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce the Claude/Codex authority boundary and automate a resumable GitHub Issue-to-Squash-Merge workflow.

**Architecture:** Keep policy in checked-in documents, enforcement in deterministic shell tools, and orchestration in shared skills. GitHub labels and comments are durable state; local JSON artifacts accelerate resume but never override verified GitHub state.

**Tech Stack:** POSIX shell, macOS `plutil`, Git, GitHub CLI, Claude Code hooks, Codex CLI, Claude CLI

**Spec:** `docs/AUTHORITY.md` and `docs/workflow.md`

## Global Constraints

- Authenticated external operations are executed only by Codex.
- Claude may use local Git but may not contact Git remotes.
- Every implementation has one Issue, one Branch, and one PR.
- Every merge is Squash and matches an explicitly verified Head SHA.
- Reviewer unavailability blocks review and never falls back to self-approval.
- A repeated identical failure stops after three attempts.

---

## File map

| Path | Responsibility |
| --- | --- |
| `.claude/settings.json` | Project hooks for instructions and external-operation enforcement |
| `.claude/hooks/guard-external-ops.sh` | Deny Claude external and secret operations |
| `.claude/hooks/load-agents-md.sh` | Add `AGENTS.md` to Claude session context without `CLAUDE.md` |
| `tools/github-account-preflight.sh` | Verify personal GitHub account and repository |
| `tools/issue-state.sh` | Read and transition durable Issue labels |
| `tools/claim-issue.sh` | Create deterministic Branch/worktree after Issue readiness checks |
| `tools/cross-model-review.sh` | Invoke the opposite model and validate review JSON |
| `tools/premerge-gate.sh` | Enforce SHA, verification, review, and acceptance gates |
| `tools/merge-issue.sh` | Push, create PR, Squash Merge, and confirm remote state |
| `tools/cleanup-issue.sh` | Remove only the merged Issue Branch and worktree |
| `.github/` | Issue form, PR template, and label manifest |
| `.agents/skills/` | Shared workflow orchestration |
| `tools/tests/` | Fixtures and deterministic shell tests |

### Task 1: Claude external-operation guard

**Files:**
- Create: `.claude/settings.json`
- Create: `.claude/hooks/guard-external-ops.sh`
- Create: `.claude/hooks/load-agents-md.sh`
- Create: `tools/tests/test-claude-guard.sh`
- Create: `tools/tests/fixtures/claude-hook/`

**Interfaces:**
- Consumes: Claude hook JSON on stdin
- Produces: no output and exit 0 for allowed operations; PreToolUse deny JSON for forbidden operations

- [ ] **Step 1: Write table-driven failing guard tests**

Create fixtures for allowed `git status`, `git diff`, `git add`, `git commit`, Xcode Build, and public `curl` without credentials. Create denied fixtures for `gh`, `git push`, `git fetch`, `git pull`, `supabase`, `wrangler`, `elevenlabs`, `fastlane`, `security find-generic-password`, the dedicated secret path, and tool names containing GitHub, Supabase, or Cloudflare MCP identifiers.

The test pipes each fixture to the guard, parses its output with `plutil`, and asserts the decision. It also asserts that a denied response contains `Codexへ委託`.

- [ ] **Step 2: Run the guard tests**

Run: `bash tools/tests/test-claude-guard.sh`  
Expected: non-zero because the hook does not exist.

- [ ] **Step 3: Implement the guard**

Use `/usr/bin/plutil -extract tool_name raw -o - -` and the same command for `tool_input.command`. Normalize only for matching; never print the original command. Deny exact external CLI command positions, authenticated API patterns, MCP tool-name prefixes, Keychain reads, and `~/Library/Application Support/iOS-Template/secrets/` access.

Return this shape on denial:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "個人用の認証済み外部操作または秘密情報へのアクセスです。codex-external-ops で Codexへ委託してください。"
  }
}
```

- [ ] **Step 4: Implement AGENTS.md session loading**

`load-agents-md.sh` reads `${CLAUDE_PROJECT_DIR}/AGENTS.md`, rejects files larger than 32768 bytes, and returns it as SessionStart `additionalContext`. It does not read secret paths or call external commands.

- [ ] **Step 5: Configure hooks**

In `.claude/settings.json`, register SessionStart for `load-agents-md.sh` and PreToolUse with matcher `*` for `guard-external-ops.sh`. Use `${CLAUDE_PROJECT_DIR}` paths and a 10-second timeout.

- [ ] **Step 6: Run tests and commit**

Run: `bash tools/tests/test-claude-guard.sh`  
Expected: all allow and deny cases pass.

```bash
git add .claude/settings.json .claude/hooks tools/tests
git commit -m "feat: enforce Codex-only external operations"
```

### Task 2: GitHub account preflight and Issue state

**Files:**
- Create: `tools/github-account-preflight.sh`
- Create: `tools/issue-state.sh`
- Create: `tools/lib/workflow.sh`
- Create: `tools/tests/test-workflow-state.sh`
- Create: `tools/tests/fixtures/gh`

**Interfaces:**
- `github-account-preflight.sh --repo yuto1201/iOS-Template` outputs sanitized JSON
- `issue-state.sh get --repo OWNER/REPO --issue 42`
- `issue-state.sh transition --repo OWNER/REPO --issue 42 --from approved --to claimed`

- [ ] **Step 1: Write failing fake-gh tests**

Put a fixture `gh` executable first on `PATH`. Test personal account success, company account rejection, repository-owner mismatch, missing Issue, invalid transition, and successful compare-and-set transition.

- [ ] **Step 2: Run tests**

Run: `bash tools/tests/test-workflow-state.sh`  
Expected: non-zero because the tools are absent.

- [ ] **Step 3: Implement sanitized account preflight**

Call `gh auth status --active` and `gh repo view --json nameWithOwner,defaultBranchRef,url`. Require active account `yuto1201`. Output account, repository, default Branch, URL, and checked timestamp; never output Token or scopes.

- [ ] **Step 4: Implement explicit transitions**

Define the state transition table from `docs/workflow.md` in `tools/lib/workflow.sh`. `issue-state.sh transition` reads current `state:*` labels, rejects multiple current states, removes exactly the old label, adds exactly the new label, and posts a concise comment containing executor and timestamp.

- [ ] **Step 5: Run tests and commit**

Run: `bash tools/tests/test-workflow-state.sh`  
Expected: all fixture cases pass.

```bash
git add tools/github-account-preflight.sh tools/issue-state.sh tools/lib tools/tests
git commit -m "feat: add GitHub identity and Issue state controls"
```

### Task 3: GitHub forms and labels

**Files:**
- Create: `.github/ISSUE_TEMPLATE/feature.yml`
- Create: `.github/ISSUE_TEMPLATE/regression.yml`
- Create: `.github/pull_request_template.md`
- Create: `.github/labels.yml`
- Create: `tools/validate-issue-body.sh`
- Test: `tools/tests/test-issue-contract.sh`

**Interfaces:**
- Produces: Issue forms containing Goal, In scope, Out of scope, Acceptance criteria, Spec anchors, Dependencies, External operations, and User approvals
- `validate-issue-body.sh issue.md` returns zero only for Definition of Ready

- [ ] **Step 1: Write failing Issue-contract tests**

Test a complete Feature Issue, missing Acceptance criteria, missing Spec anchors, unresolved user approval, and a Regression Issue with original PR and reproduction steps.

- [ ] **Step 2: Add forms and label manifest**

Define labels for every workflow and blocked state in `docs/workflow.md`, plus `agent:codex`, `agent:claude`, `type:feature`, `type:regression`, `type:docs`, and `type:release`.

- [ ] **Step 3: Implement validation**

The validator requires every heading and at least one unchecked acceptance item. It rejects `Status: 未決` in referenced specification text and rejects an approval-required operation without an approval reference.

- [ ] **Step 4: Add the PR template**

Use the exact sections from `docs/workflow.md`: Summary, Specification, Verification, Opposite-model review, and Remaining work. Include `Closes #` as an explicit field.

- [ ] **Step 5: Run tests and commit**

Run: `bash tools/tests/test-issue-contract.sh`  
Expected: all cases pass.

```bash
git add .github tools/validate-issue-body.sh tools/tests
git commit -m "feat: define GitHub workflow contracts"
```

### Task 4: Claim and resume an Issue

**Files:**
- Create: `tools/claim-issue.sh`
- Create: `tools/resume-issue.sh`
- Create: `tools/tests/test-claim-resume.sh`

**Interfaces:**
- `claim-issue.sh --repo OWNER/REPO --issue 42 --agent codex`
- For an Issue titled `Settings screen`, produces Branch `codex/42-settings-screen` and worktree `.worktrees/42-settings-screen`
- `resume-issue.sh --repo OWNER/REPO --issue 42` returns the exact existing worktree and Branch

- [ ] **Step 1: Write isolated Git fixture tests**

Use a temporary bare remote and local clone. Test new Claim, repeated Claim by the same agent, conflicting Claim, dirty main checkout preservation, and resume after local state-file deletion.

- [ ] **Step 2: Run tests**

Run: `bash tools/tests/test-claim-resume.sh`  
Expected: non-zero because Claim tools are absent.

- [ ] **Step 3: Implement Claim**

Run account preflight, fetch Issue JSON through `gh`, validate the body, normalize the title to lowercase ASCII hyphen form, transition `approved -> claimed`, create the Branch from current `origin/main`, add the worktree, and write `.artifacts/issues/42/state.json` with Issue, Branch, worktree, Base SHA, and primary agent.

- [ ] **Step 4: Implement resume**

Reconstruct state from GitHub labels, `git worktree list --porcelain`, local Branches, and remote Branches. If more than one candidate exists, return `blocked:conflict` without modifying Git state.

- [ ] **Step 5: Run tests and commit**

Run: `bash tools/tests/test-claim-resume.sh`  
Expected: all cases pass and temporary repositories remain outside the workspace.

```bash
git add tools/claim-issue.sh tools/resume-issue.sh tools/tests
git commit -m "feat: add resumable Issue worktrees"
```

### Task 5: Automatic opposite-model review

**Files:**
- Create: `tools/cross-model-review.sh`
- Create: `tools/validate-review-result.sh`
- Create: `tools/tests/test-cross-model-review.sh`
- Create: `.agents/skills/cross-model-review/SKILL.md`
- Create: `.claude/skills/cross-model-review` as a relative symlink

**Interfaces:**
- `cross-model-review.sh --primary codex --packet packet.json --output review.json`
- Reviewer mapping: `codex -> claude`, `claude -> codex`
- Timeout: 600 seconds

- [ ] **Step 1: Write fake-reviewer tests**

Test approved result, changes requested, malformed JSON, mismatched Head SHA, timeout, and an attempt by the reviewer to write a file.

- [ ] **Step 2: Implement packet validation**

Require every field in `docs/agent-contracts/review-packet.md`, require `headSha == verifySha`, and require all referenced local files to stay inside the Issue artifact directory.

- [ ] **Step 3: Implement reviewer invocation**

For Codex primary, invoke Claude non-interactively with read-only tools and JSON output. For Claude primary, invoke Codex with `--sandbox read-only`, an ephemeral session, closed stdin, and final output redirected to the requested file. Run both with a 600-second timeout and no authenticated external tools.

- [ ] **Step 4: Validate output and transition state**

Reject non-schema output and SHA mismatch. Save valid `review.json`; transition to `approved-for-merge` only for `approved`, otherwise to `changes-requested`. Timeout becomes `blocked:review`.

- [ ] **Step 5: Add the shared skill and symlink**

The skill reads the common review contract, prepares the packet, invokes the tool, applies requested changes through the primary agent, and repeats verification before a new review.

- [ ] **Step 6: Run tests and commit**

Run: `bash tools/tests/test-cross-model-review.sh`  
Expected: all result and timeout cases pass.

```bash
git add tools .agents/skills/cross-model-review .claude/skills/cross-model-review
git commit -m "feat: automate opposite-model review"
```

### Task 6: Pre-merge gate, merge, and cleanup

**Files:**
- Create: `tools/premerge-gate.sh`
- Create: `tools/render-pr-body.sh`
- Create: `tools/merge-issue.sh`
- Create: `tools/cleanup-issue.sh`
- Create: `tools/tests/test-premerge-gate.sh`
- Create: `tools/tests/test-cleanup-issue.sh`

**Interfaces:**
- `premerge-gate.sh --issue 42 --head-sha 0123456789abcdef0123456789abcdef01234567`
- `merge-issue.sh --repo OWNER/REPO --issue 42`
- `cleanup-issue.sh --repo OWNER/REPO --issue 42`

- [ ] **Step 1: Write failing gate tests**

Test matching evidence, stale Verify SHA, stale Review SHA, changes-requested verdict, failed matrix case, missing acceptance evidence, and absent account preflight.

- [ ] **Step 2: Implement the gate**

Read current Git Head, `verify.json`, `review.json`, Issue body, and account preflight. Require SHA equality, passed verification, approved review, zero unresolved blocking findings, and evidence for every acceptance checkbox.

- [ ] **Step 3: Write cleanup safety tests**

Test successful removal of a merged Issue worktree, refusal to remove an unmerged Branch, refusal when the worktree is dirty, and preservation of unrelated worktrees and Branches.

- [ ] **Step 4: Implement merge**

Run GitHub preflight, Push the exact Issue Branch, create or find its PR, render the PR body, rerun the gate, and call `gh pr merge --squash --match-head-commit` with the exact Head SHA. Confirm the PR is merged and the Issue closed before cleanup.

- [ ] **Step 5: Implement cleanup**

Resolve exact targets from Issue state. Refuse dirty or unmerged targets. Remove the remote Issue Branch, then the worktree, then the local Branch. Do not use broad globs or recursive deletion.

- [ ] **Step 6: Run tests and commit**

Run: `bash tools/tests/test-premerge-gate.sh && bash tools/tests/test-cleanup-issue.sh`  
Expected: all safety cases pass.

```bash
git add tools
git commit -m "feat: gate and squash-merge verified Issues"
```

### Task 7: Shared shipping skills

**Files:**
- Create: `.agents/skills/plan-issue-batch/SKILL.md`
- Create: `.agents/skills/ship-issue/SKILL.md`
- Create: `.agents/skills/ship-issue-batch/SKILL.md`
- Create: `.agents/skills/codex-external-ops/SKILL.md`
- Create: matching relative symlinks under `.claude/skills/`
- Modify: `tools/tests/test-foundation.sh`

**Interfaces:**
- Produces: orchestration over the deterministic tools created in Tasks 1-6
- Does not duplicate account, Git, review, or merge logic inside SKILL.md

- [ ] **Step 1: Extend skill-layout tests**

Require all four skill directories and Claude symlinks. Reject copies by comparing symlink targets rather than file contents.

- [ ] **Step 2: Write `plan-issue-batch`**

Define Issue granularity, dependency-graph output, file-conflict serialization, Definition of Ready, and the rule that unresolved acceptance decisions stop only affected work.

- [ ] **Step 3: Write `ship-issue`**

Call Claim, implementation, verification, opposite review, PR, pre-merge gate, merge, and cleanup in the state-machine order. Resume from durable GitHub state and never mark success from a skipped stage.

- [ ] **Step 4: Write `ship-issue-batch`**

Start only dependency-free Issues, cap concurrent source-editing Issues at two, serialize overlapping files and all Simulator stages, continue independent work when one Issue blocks, and stop identical retry loops at three.

- [ ] **Step 5: Write `codex-external-ops`**

Validate the request schema in `docs/AUTHORITY.md`, verify provider identity, execute exactly one operation, redact output, and return the response schema. In Claude sessions, the skill delegates to Codex rather than executing the provider CLI.

- [ ] **Step 6: Run policy tests and commit**

Run: `bash tools/tests/test-foundation.sh`  
Expected: zero.

```bash
git add .agents/skills .claude/skills tools/tests/test-foundation.sh
git commit -m "feat: add autonomous Issue shipping skills"
```

### Task 8: End-to-end dry run

**Files:**
- Create: `tools/tests/test-workflow-e2e.sh`
- Modify: `README.md`

**Interfaces:**
- Uses a temporary local Git repository and fake GitHub/reviewer commands
- Proves state transitions, stale-evidence rejection, Squash Merge request formation, and safe cleanup

- [ ] **Step 1: Write the end-to-end fixture**

Create a complete fake Issue with two acceptance checks, Claim it, create a commit, attach passed Verify and approved Review files with the same SHA, render a PR body, invoke fake merge, and cleanup.

- [ ] **Step 2: Add a stale-review regression case**

Create one additional commit after review and assert the gate fails until both verification and review are rerun for the new SHA.

- [ ] **Step 3: Run the complete tool suite**

Run every `tools/tests/test-*.sh` script.  
Expected: all pass; no fixture contacts the real GitHub API.

- [ ] **Step 4: Perform one real no-mutation preflight**

Run `tools/github-account-preflight.sh --repo yuto1201/iOS-Template`.  
Expected: sanitized output identifies `yuto1201` and the intended repository, without a Token.

- [ ] **Step 5: Document recovery commands and commit**

Add Claim, resume, pre-merge gate, and cleanup examples to README, including the blocked-state behavior.

```bash
git add README.md tools/tests/test-workflow-e2e.sh
git commit -m "test: cover the autonomous shipping workflow"
```
