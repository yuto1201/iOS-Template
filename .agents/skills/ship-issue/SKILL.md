---
name: ship-issue
description: Use when one implementation-ready iOS Issue must proceed from Claim through current-Head verification, opposite-model review, merge, and cleanup.
---

# Ship Issue

Resume from durable GitHub/state artifacts; never infer completion from local files or skip a stage. Existing tools own identity, Git, evidence, review, merge, and cleanup validation—do not reproduce their logic.

## Authority routing

- Codex is the external controller. It runs Claim/state/merge/cleanup tools and all authenticated provider operations after personal-account preflight.
- A Claude primary performs local implementation and local verification only. Every authenticated operation goes through `codex-external-ops`; Claude never runs `gh`, remote Git, a provider CLI/MCP, or Codex CLI. The enclosing runtime must supply a Codex controller to execute the Codex-only stages below. `request-codex-op.sh` is an atomic-operation transport, not a way to request a multi-operation shipping script. If no Codex controller is available, use `blocked:ops` rather than inventing a bridge.
- Opposite review always uses `cross-model-review`; never invoke a reviewer CLI directly or self-approve.

## State-driven workflow

Use the exact order:

```text
approved -> claimed -> in-progress -> verify-passed -> review-requested
review-requested -> approved-for-merge -> merged -> done
review-requested -> changes-requested -> in-progress
```

1. Have the Codex controller read the durable GitHub state first:

```sh
tools/issue-state.sh get --repo "$REPO" --issue "$ISSUE"
```

Dispatch from that returned state; do not replay from the beginning:

- `approved`: run `tools/claim-issue.sh --repo "$REPO" --issue "$ISSUE" --agent "$PRIMARY"`.
- `claimed`: run `tools/resume-issue.sh --repo "$REPO" --issue "$ISSUE"`, then before editing run `tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" --from claimed --to in-progress`.
- `in-progress`: run Resume and continue local implementation; do not call Claim again.
- `changes-requested`: run Resume, then before editing run `tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" --from changes-requested --to in-progress`; repeat verification/review after the fix.
- `verify-passed`, `review-requested`, or `approved-for-merge`: run Resume and continue that exact stage. Do not edit until an allowed state-machine transition returns the Issue to `in-progress`; `verify-passed` and `approved-for-merge` permit that transition, while `review-requested` requires the review result to move to `changes-requested` first.
- `blocked:*` or `paused`: Resume only to the exact durable `resumeState`, then dispatch again from the returned state.
- `merged`: perform the cleanup stage below. `done`: return idempotent success without Claim or Resume.

Transition only through `tools/issue-state.sh`; do not hand-edit labels, markers, or state JSON.

2. Only in `in-progress`, implement the Issue contract. Apply TDD and commit locally. A changed Head invalidates prior verification/review.
3. Use `ios-verify`. Transition to `verify-passed` only after canonical `verify.json` validates for current Head; documentation-only work uses that skill's `tools/publish-documentation-verify.sh` path, not a skipped check.
4. Transition to `review-requested`, then run the exact opposite-model handoff:

```sh
tools/cross-model-review.sh \
  --primary "$PRIMARY" \
  --packet ".artifacts/issues/${ISSUE}/${HEAD_SHA}/review-packet.json" \
  --output ".artifacts/issues/${ISSUE}/${HEAD_SHA}/review.json"
```

The tool moves an approved result to `approved-for-merge` and a rejected result to `changes-requested`. Fix only in scope; a new Head repeats verification and review.

5. At `approved-for-merge`, let the Codex controller run the sole publication orchestrator:

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
