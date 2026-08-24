# Task 4 report: deterministic Issue claim and resume

## Implementation

- Added `tools/claim-issue.sh`. It performs read-only GitHub account preflight, reads the Issue through `gh`, selects Regression validation only from a verified `type:regression` label, validates Definition of Ready, derives a canonical Issue-contract JSON/digest, and normalizes the title to the canonical ASCII Branch/worktree names.
- A new claim verifies that the Issue is `approved`, no local/remote Branch or worktree candidate exists, fetches current `origin/main`, transitions `approved -> claimed`, creates the dedicated worktree from that Base SHA, and persists the complete durable local record.
- Same-agent repeated Claim accepts the one logical Branch even when it exists as both a local and `origin/` ref, delegates reconstruction to Resume, and performs no second Issue transition. Agent, state, Branch, or worktree conflicts fail closed.
- Added `tools/resume-issue.sh`. It reconstructs the result solely from the current durable Issue label, the latest matching state-transition marker, local/remote Branch facts, `git worktree list --porcelain`, and the canonical contract bytes/digest. Missing marker, non-local Branch, or multiple candidates returns `blocked:conflict` without a Git transition.
- Added an isolated `tools/tests/test-claim-resume.sh` suite. It creates an empty temporary seed repository, a temporary bare remote, and a local clone; all `gh` calls use a fixture on `PATH`.

## Test evidence

- `bash tools/tests/test-claim-resume.sh` — PASS: deterministic Issue claim, idempotency, conflict refusal, dirty-main preservation, and marker-based resume.
- `bash -n tools/claim-issue.sh tools/resume-issue.sh tools/tests/test-claim-resume.sh` — PASS.
- `bash tools/tests/test-workflow-state.sh` — PASS.
- `bash tools/tests/test-issue-contract.sh` — PASS.
- `git diff --check` — PASS.

## TDD evidence

- RED: after adding the isolated test and before creating the Claim tool, `bash tools/tests/test-claim-resume.sh` exited non-zero at `tools/claim-issue.sh: No such file or directory`.
- GREEN: after implementation, the focused test passed with the complete temporary bare-remote/fake-`gh` fixture.

## Self-review

- The test asserts Issue-contract values for Goal, local spec anchor, ordered AC IDs, dependency, external-operation snapshot, and state-file digest reference.
- The test preserves both a user-owned tracked edit and untracked file in the default checkout and compares `git status --porcelain` before/after Claim and conflicting Claim.
- The test verifies resume after `state.json` deletion, missing-marker refusal, multiple-candidate refusal, and that a remote-tracking ref duplicating the canonical local Branch remains idempotent.
- No Task 1–3 or Task 5+ implementation files were modified.

## Concerns

- If the GitHub transition succeeds but `git worktree add` subsequently fails for an unexpected local Git error, the durable Issue state is `claimed` while Resume intentionally fails closed rather than guessing a worktree. This is observable and recoverable by resolving the local conflict; no existing worktree or Branch is removed automatically.

---

## Fix round 1: canonical resume candidates and latest-marker validation

### Implementation

- `resume-issue.sh` now uses the exact Claim ASCII title-to-slug normalization before accepting Branch or worktree facts. Only `codex|claude/<issue>-<current-slug>` and `.worktrees/<issue>-<current-slug>` qualify; a stale-title candidate is `blocked:conflict`.
- Resume selects the latest comment containing an `ios-template-state` marker and requires exactly one structurally valid marker in it. A newer mismatched, malformed, or duplicate marker therefore fails closed instead of allowing an older convenient marker.
- Resume verifies that the marker target equals the current label, the `from -> to` edge is in `workflow_transition_allowed`, and blocked/paused marker resume state follows the same recovery rules as the state-transition tool.

### TDD evidence

- RED command: `bash tools/tests/test-claim-resume.sh`
- RED output: `expected failure: resume rejects a stale-title Branch and worktree`.
- GREEN command: `bash tools/tests/test-claim-resume.sh`
- GREEN output: `PASS: deterministic Issue claim, idempotency, conflict refusal, dirty-main preservation, and marker-based resume`.

### Covering verification

- `bash tools/tests/test-claim-resume.sh` — PASS, including stale slug, newer marker mismatch masking an older match, malformed newest marker, duplicate newest markers, invalid `done -> claimed` marker, dirty-main preservation, idempotency, and duplicate remote tracking ref behavior.
- `bash tools/tests/test-workflow-state.sh` — PASS: `PASS: GitHub preflight, durable state transitions, and fixed Codex operation transport`.
- `bash tools/tests/test-issue-contract.sh` — PASS: `PASS: Issue forms, Definition of Ready validator, PR template, labels, and Codex label sync`.
- `bash -n tools/claim-issue.sh tools/resume-issue.sh tools/tests/test-claim-resume.sh` — PASS.
- `git diff --check` — PASS.

### Self-review

- Verified Resume does not accept any wildcard Issue Branch or worktree after a title rename.
- Verified a comment later than the valid Claim marker cannot be ignored merely because it is malformed or references another state.
- Verified workflow legality is checked after structural validation and before any local state-file write.
- The deferred `type:docs` / `type:release` Minor remains unchanged, as requested.

---

## Fix round 2: decoded blocked and paused resume state

### Implementation

- `resume-issue.sh` now retains `resumeState` as its JSON representation only for JSON/state-file output and decodes a non-null value to a raw, validated workflow state for all blocked/paused comparisons.
- Correct `blocked:user -> in-progress` and `paused -> in-progress` markers with `resumeState: "in-progress"` are accepted; a null, unknown, or different resume state is refused before a state-file write.

### TDD evidence

- RED command: `bash tools/tests/test-claim-resume.sh`
- RED output: `blocked:conflict: state-transition marker has an invalid blocked or paused resume state` for the valid blocked recovery fixture.
- GREEN command: `bash tools/tests/test-claim-resume.sh`
- GREEN output: `PASS: deterministic Issue claim, idempotency, conflict refusal, dirty-main preservation, and marker-based resume`.

### Covering verification

- `bash tools/tests/test-claim-resume.sh` — PASS, including valid blocked and paused recovery plus mismatched blocked resumeState refusal.
- `bash tools/tests/test-workflow-state.sh` — PASS: `PASS: GitHub preflight, durable state transitions, and fixed Codex operation transport`.
- `bash tools/tests/test-issue-contract.sh` — PASS: `PASS: Issue forms, Definition of Ready validator, PR template, labels, and Codex label sync`.
- `bash -n tools/claim-issue.sh tools/resume-issue.sh tools/tests/test-claim-resume.sh` — PASS.
- `git diff --check` — PASS.

### Self-review

- Verified raw string comparison is now used only after JSON null handling and `workflow_is_state` validation.
- Verified JSON null is still retained as null in the reconstructed state record/output.
- The deferred `type:docs` / `type:release` Minor remains unchanged.
