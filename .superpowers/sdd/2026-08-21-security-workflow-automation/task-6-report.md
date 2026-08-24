# Task 6 report — pre-merge gate, merge, and cleanup

## RED

- `bash tools/tests/test-premerge-gate.sh` initially exercised the absent gate and observed the expected non-zero command failure.
- `bash tools/tests/test-cleanup-issue.sh` initially exercised the absent cleanup command and observed the expected non-zero command failure.

## Implementation

- Added canonical-artifact-link-bound pre-merge gating, deterministic PR body rendering, exact-head squash merge orchestration, and PR-confirmed targeted cleanup.
- Gate checks immutable live Issue-contract fields, Head-bound verification/review/preflight identity and freshness, exact AC evidence, review findings, and the tightly scoped documentation-only representation. Application evidence requires a canonical matrix file whose exact digest matches.
- Cleanup requires a single exact merged PR, exact head OID, merge commit, clean recorded worktree, and preserves unrelated targets.
- Per the controller ruling, Task 6 scripts run only inside the recorded Issue worktree and require its `.artifacts` symlink to resolve exactly to the primary checkout's canonical artifact store.

## GREEN evidence

- `bash tools/tests/test-premerge-gate.sh` — PASS. Covers matching evidence, stale Verify/Review SHA, changes-requested review, live-contract staleness, missing/duplicate AC evidence, failed matrix representation, changed matrix digest, absent/digest-mismatched/stale merge preflight, documentation-only exception, and deterministic PR body rendering.
- `bash tools/tests/test-cleanup-issue.sh` — PASS. Covers open and closed-unmerged PR refusal, missing merge commit, stale PR Head, dirty worktree refusal, successful exact cleanup, and unrelated worktree/Branch preservation.
- `bash tools/tests/test-workflow-state.sh && bash tools/tests/test-claim-resume.sh` — PASS.
- `bash -n` on all Task 6 scripts/tests and `git diff --check` — PASS.

## Adjacent concern

- `bash tools/tests/test-cross-model-review.sh` returned non-zero after reporting the expected reviewer-write rejection. This is an existing Task 5 adjacent-suite result and no Task 5 file was modified by Task 6.

## Fix round 1 (in progress)

- Added truthful PR-body remaining-work status and a regression assertion for changes-requested review output.
- Gate now delegates canonical verify.json validation to `validate-verify-json.swift`; its linked-worktree artifact-root support is being repaired by the authorized validator owner.
- Added the ruled sealed provider-preflight consumer schema and strengthened merge retry state convergence plus delete-branch preflight/remote-absence handling.
- Final focused rerun and commit remain pending validator integration and the required full merge E2E/restart-boundary coverage.

### Current evidence

- After validator repair `d2656495`, `bash tools/tests/test-premerge-gate.sh && bash tools/tests/test-cleanup-issue.sh` passed, as did Task 6 shell syntax and `git diff --check`.
- The remaining full fake-GitHub merge E2E and primary-entrypoint post-worktree-removal retry coverage require a follow-up; they are not claimed as complete in this round.

## Fix round 2 — merge and cleanup recovery completion

### RED evidence

- The committed 18-line merge fixture failed before any fake-`gh` call with `artifact identity mismatch`; it used a digest unrelated to the canonical contract and tried to keep fake PR state in a child-process environment.
- The new provider fixture initially failed with `expected failure: blank provider account is rejected`, proving the consumer accepted whitespace-only sealed fields.
- The primary-entrypoint regression initially allowed cleanup to delete its own active Issue worktree; the test observed the remote deletion, missing-current-directory errors, and an unexpected successful `cleaned` result.
- The already-merged remote-state regression initially failed because a remote `state:merged` label could not converge a still-local `approved-for-merge` durable record.

### Implementation and coverage

- Replaced the merge fixture with real temporary primary repositories, linked Issue worktrees, canonical shared artifacts, local bare remotes, stateful fake GitHub files, and exact ordered logs. It runs the real renderer, merge orchestration, Issue transition, and durable-state persistence while stubbing only the heavy gate and account preflight with exact-argument wrappers.
- Covered new PR, existing OPEN PR, CLOSED-unmerged refusal, already-MERGED before transition, and already-MERGED after the remote workflow label advanced. Successful paths persist `state`, `previousState`, `from`, `to`, `transitionedAt`, `headSha`, and `pullRequest`; retry paths do not push, create, or merge.
- Cleanup now refuses any non-primary entrypoint before GitHub or remote Git access. Deterministic injected failures prove safe resume after remote deletion, worktree removal, and local Branch deletion, with the exact Issue-worktree `github.delete_branch` preflight immediately before a real remote deletion attempt.
- Provider preflight consumption rejects symlink path components, whitespace-only/untrimmed/overlong/unsafe identity fields, and unknown environments before trusting the sealed digest.

### Final verification evidence

- `bash tools/tests/test-premerge-gate.sh` — `PASS: gate covers canonical evidence, strict provider fields, provider containment, and documentation-only cases`
- `bash tools/tests/test-merge-issue.sh` — `PASS: merge workflow covers new, open, closed-unmerged, and both already-merged convergence paths`
- `bash tools/tests/test-cleanup-issue.sh` — `PASS: cleanup refuses unsafe PRs and resumes exact cleanup after each deletion boundary`
- `bash tools/tests/test-workflow-state.sh` — `PASS: GitHub preflight, durable state transitions, and fixed Codex operation transport`
- `bash tools/tests/test-claim-resume.sh` — `PASS: deterministic Issue claim, idempotency, conflict refusal, dirty-main preservation, and marker-based resume`
- `bash tools/tests/test-cross-model-review.sh` — `PASS: approved, envelope, changes-requested, malformed, SHA mismatch, timeout, write-attempt, native hardened Codex sandbox probes, and idempotent retry cases`
- `bash -n` on all Task 6 scripts and tests — `PASS: Task 6 shell syntax`
- `git diff --check` — `PASS: git diff --check`

No live GitHub, provider, model, or network operation was performed; all remote Git traffic targeted temporary local bare repositories.
