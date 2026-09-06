---
name: ship-issue-batch
description: Use when multiple ready iOS Issues should progress autonomously while dependencies, file conflicts, Simulator exclusivity, and partial failures must be coordinated.
---

# Ship Issue Batch

Group Simulator batches by sealed Delivery stage and scope with distinct batch IDs. `shape` uses one `iphone-ja` case, `harden` uses its exact `targeted` subset, and `release` or a sealed legacy contract uses `full`. Never shrink a claimed scope or silently fall back. Required focused harden Issues must be dependencies of the release candidate.

Schedule the graph produced by `plan-issue-batch`; use `ship-issue` for each node. Evaluate UI nodes through [`ui-direction`](../ui-direction/SKILL.md): a current explicit comparison always gates; explicit skip overrides only when currentness/exact scope/authority/reason and lack of conflict are clear; otherwise exact confirmed hierarchy/flow coverage uses confirmed-direction reuse. When direction is unconfirmed, creating the first user-facing UI, creating or changing root navigation/information architecture, or materially redesigning a primary flow gates; without any of those three triggers, bounded direction-neutral UI is permitted only when acceptance decides no hierarchy/navigation/primary-flow interaction. Ambiguity gates.

For each sealed node, compare `fetchedAt` with `2026-09-06T00:31:41Z`. Any AC text beginning exact `UI-direction route:` is a declaration candidate; it is fully valid only in form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>` using a route allowed by `ui-direction`, and route-specific facts may follow Reason. Incidental route words outside the prefix do not create a candidate. A node fetched earlier with zero candidates is pre-D-030 legacy: do not infer a route, demand retroactive HTML/route declaration, or modify/reseal it; schedule it against its original sealed AC/spec/evidence. If an earlier node has one or more candidates, validate normally and reject unless exactly one is fully valid; malformed, unknown-route, empty Scope/Reason, and multiple-candidate cases are not legacy. A node at or after the cutoff has the same exactly-one and validity requirements, including rejection when no candidate exists, plus confirmed anchors in Spec anchors and any selection prerequisite in Dependencies. A gated node waits until that dependency is `done`; its common selection record has scope, artifact path/revision, exact presented-bytes SHA-256, adopted/rejected elements, screens/states, and native adaptation. A single selection adds selected concept ID; a hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping and only adds a selected/base ID if explicitly chosen. UI Issues keep the exact ordered `Target screens/states`, `English expectations`, and `Japanese expectations` UI verification fields as live guidance, and post-cutover pre-Claim checks them plus the declaration to be sealed. Identity/bootstrap and pure non-UI nodes claimed after the cutoff set UI verification to exact `Not applicable`, put scope/non-UI reason in Goal/In scope, start one AC text with `UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`, and cite a relevant product/specification anchor in Spec anchors, not a UI-direction anchor; independent non-UI lanes may continue. A fast lane never weakens an individual Issue gate.

## Scheduler invariants

- Start only Definition-of-Ready Issues whose dependency predecessors are `done`.
- Run at most two source-editing Issues concurrently. Expected or observed overlapping files, Xcode project/configuration edits, and the same Branch/worktree serialize those Issues.
- Run only one Simulator lifecycle at a time. Let `ios-verify` acquire the repository-wide lock; other lanes may perform non-Simulator local work meanwhile.
- Recompute ready nodes after every state change. When one node blocks, mark its dependents `blocked:dependency` and continue independent components.
- Never create a shared Branch, PR, verification artifact, or review packet for a batch.

## Retry boundary

Count a failure as identical only when `(Issue, stage, exact tool argv, exit status, SHA-256 of exact captured stderr bytes)` is byte-for-byte unchanged. Do not normalize timestamps or messages to manufacture equality. A success or a different tuple starts a new count. Stop after the second identical failure; never start a third attempt automatically.

The current state machine permits `blocked:repeated-failure` only from `in-progress`:

- At `in-progress`, the second identical failure transitions directly to `blocked:repeated-failure` through `tools/issue-state.sh transition`.
- At `changes-requested`, `verify-passed`, or `approved-for-merge`, first use their explicit allowed transition to `in-progress`, then transition to `blocked:repeated-failure`. This abandons the stale later-stage readiness; resumption must repeat the affected verification/review.
- At `review-requested`, do not invent an `in-progress` or repeated-failure transition. Reviewer unavailability uses the allowed `blocked:review` path; a real changes-requested result follows `changes-requested -> in-progress`.
- At `claimed`, `merged`, or `done`, do not manufacture a repeated-failure state. Preserve the current state and surface the unsupported recovery to the selected executor.

`tools/issue-state.sh` owns `resumeState`; never pass or hand-edit it. Do not relabel a failure flaky or bypass verification/review.

## Batch-wide stops

Stop all remaining lanes only for a shared acceptance-affecting unresolved decision, unverifiable configured GitHub identity, broken Base Branch, missing Xcode/runtime needed by every remaining Issue, or an explicit user stop. Account/provider mutations may be executed by Codex or Claude through the same `external-ops` preflight.

Report per Issue: durable state, dependency/block reason, current Head when claimed, last completed stage, retry tuple/count, and next eligible action. `done` means merge confirmation, exact cleanup, and the final state transition all succeeded.
