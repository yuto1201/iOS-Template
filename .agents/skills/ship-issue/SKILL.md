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

## UI direction preflight

Before Claim or when resuming a sealed contract, classify the Issue through [`ui-direction`](../ui-direction/SKILL.md):

- First inspect any sealed Issue contract `fetchedAt`. Any AC text beginning exact `UI-direction route:` is a declaration candidate; it is fully valid only in form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>` using one of the five values allowed by `ui-direction`, and route-specific facts may follow Reason. Incidental route words outside the prefix do not create a candidate. If `fetchedAt` is earlier than `2026-09-06T00:31:41Z` and there are zero candidates, resume it as pre-D-030 legacy without inferring a route, demanding retroactive HTML/route declaration, or modifying/resealing the contract; verify and review its original sealed AC/spec/evidence. If an earlier contract has one or more candidates, validate it normally and reject unless exactly one is fully valid; malformed, unknown-route, empty Scope/Reason, and multiple-candidate cases are not legacy. A contract at or after the cutoff has the same exactly-one and validity requirements, including rejection when no candidate exists, and every post-cutover pre-Claim workflow must add a fully valid declaration before Claim.
- A current explicit user request for HTML comparison takes priority regardless of an existing direction.
- A current explicit user skip overrides the normal route only when currentness, exact scope, authority, reason, and lack of conflict with a comparison request are clear; ambiguity or conflict is `blocked:user`.
- Otherwise, use confirmed-direction reuse when a confirmed specification covers the exact planned hierarchy and flow, even if the change is labelled structural.
- If that direction is unconfirmed and the work creates the first user-facing UI, creates or changes root navigation/information architecture, or materially redesigns a primary flow, run the gate.
- If direction is unconfirmed and no structural trigger applies, allow bounded direction-neutral UI only when acceptance does not decide hierarchy, navigation, or primary-flow interaction.
- If coverage, trigger applicability, or neutrality is ambiguous, run the gate.
- Identity/bootstrap and purely non-UI work use the not-applicable route. Require the UI verification body to be exactly `Not applicable`; put exact scope/non-UI reason in Goal/In scope or another existing scope section and a relevant confirmed product/specification anchor in Spec anchors, but require no UI-direction anchor. Evaluate only dependent native UI through the gate.

For every non-legacy contract, require exactly one valid declaration across the sealed acceptance criteria. Validate its allowed route, nonempty Scope/Reason, and applicable selection/reuse/neutral/explicit-skip/not-applicable facts after Reason; never identify a route from bare words outside the AC-text prefix. Require confirmed anchors in Spec anchors and the completed selection prerequisite in Dependencies. For gated UI, the merged record has common scope, artifact path/revision, exact presented-bytes SHA-256, adopted/rejected elements, screens/states, and native adaptation; a single selection adds selected concept ID, while a hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping and adds a selected/base ID only when the user explicitly chose one. A vague preference, an unmerged selection, or comparison HTML alone is not Definition of Ready. Do not Claim or implement until `spec-workflow` repairs the contract.

UI verification for a UI Issue remains the exact ordered `Target screens/states`, `English expectations`, and `Japanese expectations` live guidance and is not sealed into the Issue contract. Pre-Claim checks both that live guidance and the authoritative declaration to be sealed; final review identifies the route only from that packet-sealed AC-text prefix and validates it with Goal, acceptance criteria, Spec anchors, Dependencies, linked confirmed specifications/Decision, and current-Head evidence. Do not invent a new field for any route.

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

2. Only in `in-progress`, implement the Issue contract. Apply TDD and commit locally. During implementation run the affected test first, then related regression tests; do not create canonical evidence for each intermediate commit. A changed Head invalidates prior canonical verification/review. For a `shape` Issue, monitor the sealed Time budget. If it will be exceeded, narrow scope, split focused harden work, stop as `blocked:environment`, or use `blocked:user`; do not accumulate quality work in the same Issue. For gated UI, implement the confirmed hierarchy, flow, and state intent with native SwiftUI; never ship the comparison HTML or treat CSS pixel parity as acceptance evidence.
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
