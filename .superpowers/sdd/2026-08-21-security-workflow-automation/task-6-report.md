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
