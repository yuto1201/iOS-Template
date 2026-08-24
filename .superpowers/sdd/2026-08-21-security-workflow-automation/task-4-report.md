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
