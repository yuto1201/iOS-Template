---
name: ship-issue
description: Use when one implementation-ready iOS Issue must proceed from Claim through current-Head verification, opposite-model review, merge, and cleanup.
---

# Ship Issue

Resume from durable GitHub/state artifacts; never infer completion from local files or skip a stage. Existing tools own identity, Git, evidence, review, merge, and cleanup validation—do not reproduce their logic.

## Authority routing

- Codex and Claude have equal authority. The selected Issue executor runs Claim/state/merge/cleanup tools and authenticated provider operations after the same configured-account preflight.
- Every authenticated operation uses `external-ops`; the live Issue operation block must name the executing model and match `Config/ownership.yml`.
- When a `release` stage or `strict` profile requires opposite review, always use `cross-model-review`; never invoke a reviewer CLI directly or self-approve. Explicit non-release `shape`/`harden` work with `standard` and every explicit `fast` Issue omit the blocking review stage.

## State-driven workflow

Use the exact order:

```text
approved -> claimed -> in-progress -> verify-passed -> review-requested
review-requested -> approved-for-merge -> merged -> done
review-requested -> changes-requested -> in-progress
verify-passed -> approved-for-merge -> merged -> done  # review-not-required contract only
```

1. Have the selected executor read the durable GitHub state first:

```sh
tools/issue-state.sh get --repo "$REPO" --issue "$ISSUE"
```

Dispatch from that returned state; do not replay from the beginning:

- `approved`: run `tools/claim-issue.sh --repo "$REPO" --issue "$ISSUE" --agent "$PRIMARY"`.
- `claimed`: run `tools/resume-issue.sh --repo "$REPO" --issue "$ISSUE"`, then before editing run `tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" --from claimed --to in-progress`.
- `in-progress`: run Resume and continue local implementation; do not call Claim again.
- `changes-requested`: run Resume, then before editing run `tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" --from changes-requested --to in-progress`; repeat verification/review after the fix.
- `verify-passed`, `review-requested`, or `approved-for-merge`: run Resume and continue that exact stage. Do not edit until an allowed state-machine transition returns the Issue to `in-progress`; `verify-passed` and `approved-for-merge` permit that transition, while `review-requested` requires the review result to move to `changes-requested` first.
- `blocked:*` or `paused`: read the exact durable `resumeState` returned by `issue-state.sh get`, execute that explicit state transition, then reconstruct local state and redispatch. `resume-issue.sh` never changes a GitHub label:

```sh
STATE_JSON="$(tools/issue-state.sh get --repo "$REPO" --issue "$ISSUE")"
CURRENT_STATE="$(jq -er '.state' <<<"$STATE_JSON")"
RESUME_STATE="$(jq -er '.resumeState | strings' <<<"$STATE_JSON")"
tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" --from "$CURRENT_STATE" --to "$RESUME_STATE"
tools/resume-issue.sh --repo "$REPO" --issue "$ISSUE"
```

Dispatch again from `RESUME_STATE`; do not imply that Resume performed the transition.
- `merged`: perform the cleanup stage below. `done`: return idempotent success without Claim or Resume.

Transition only through `tools/issue-state.sh`; do not hand-edit labels, markers, or state JSON.
Every allowed recovery into `in-progress` clears the old durable Head binding. Treat that state as unverified: re-resolve the current Issue worktree Head and repeat verification before creating a new binding; never reuse an earlier Head or its evidence.

2. Only in `in-progress`, implement the Issue contract. Apply TDD and commit locally. During implementation run the affected test first, then related regression tests; do not create canonical evidence for each intermediate commit. A changed Head invalidates prior canonical verification/review. For a `shape` Issue, monitor the sealed Time budget. If it will be exceeded, narrow scope, split focused harden work, stop as `blocked:environment`, or use `blocked:user`; do not accumulate quality work in the same Issue.
3. Use `ios-verify` at a stable Head. Route by Delivery stage, independently of risk profile:
   - `shape`: Build, critical Unit Tests, and the sealed `iphone-ja` smoke path. No screenshots, complete accessibility audit, full matrix, or release claim.
   - `harden`: only the affected checks and sealed `targeted` cases. Do not rerun a complete matrix for an unrelated quality concern.
   - `release` or a legacy contract without Delivery stage: complete `full` verification and release evidence.
   - explicit `fast`: focused non-UI evidence; documentation-only work uses `tools/publish-documentation-verify.sh`.

Transition to `verify-passed` only after canonical `verify.json` validates for current Head. Never describe shape/harden evidence as `release ready` or `fully verified`. From the canonical Issue worktree, bind the exact current Head accepted by the state tool:

```sh
ISSUE_WORKTREE="$(git rev-parse --show-toplevel)"
HEAD_SHA="$(git -C "$ISSUE_WORKTREE" rev-parse HEAD)"
cd "$ISSUE_WORKTREE"
tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" --from in-progress --to verify-passed --head-sha "$HEAD_SHA"
```

4. Ask the canonical contract helper whether review is required. A `strict` profile, `release` stage, or legacy contract requires review. An explicit `fast` contract and a non-release `standard` shape/harden contract transition directly from `verify-passed` to `approved-for-merge`; the state tool enforces this decision. When review is required, transition to `review-requested`, then run the exact opposite-model handoff:

```sh
tools/cross-model-review.sh \
  --primary "$PRIMARY" \
  --packet ".artifacts/issues/${ISSUE}/${HEAD_SHA}/review-packet.json" \
  --output ".artifacts/issues/${ISSUE}/${HEAD_SHA}/review.json"
```

The tool moves an approved result to `approved-for-merge` and a rejected result to `changes-requested`. Fix only in scope; a new Head repeats verification and review.

5. At `approved-for-merge`, let the selected executor run the sole publication orchestrator:

```sh
tools/merge-issue.sh --repo "$REPO" --issue "$ISSUE"
```

`merge-issue.sh` owns the merge-operation preflights, PR rendering/publication, and initial/final `premerge-gate.sh` calls. Do not call the gate separately or duplicate that sequence.

6. Only after durable `merged`, run from the primary checkout:

```sh
tools/cleanup-issue.sh --repo "$REPO" --issue "$ISSUE"
tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" --from merged --to done
```

Any failed, unavailable, stale, or skipped stage is not success. Preserve its recoverable state and continue only after the deterministic tool accepts the same Issue/Head identity.
