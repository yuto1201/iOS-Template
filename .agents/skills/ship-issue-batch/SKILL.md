---
name: ship-issue-batch
description: Use when multiple ready iOS Issues should progress autonomously while dependencies, file conflicts, Simulator exclusivity, and partial failures must be coordinated.
---

# Ship Issue Batch

Schedule the graph produced by `plan-issue-batch`; use `ship-issue` for each node. A fast lane never weakens an individual Issue gate.

## Scheduler invariants

- Start only Definition-of-Ready Issues whose dependency predecessors are `done`.
- Run at most two source-editing Issues concurrently. Expected or observed overlapping files, Xcode project/configuration edits, and the same Branch/worktree serialize those Issues.
- Run only one Simulator lifecycle at a time. Let `ios-verify` acquire the repository-wide lock; other lanes may perform non-Simulator local work meanwhile.
- Recompute ready nodes after every state change. When one node blocks, mark its dependents `blocked:dependency` and continue independent components.
- Never create a shared Branch, PR, verification artifact, or review packet for a batch.

## Retry boundary

Count a failure as identical only when `(Issue, stage, exact tool argv, exit status, SHA-256 of exact captured stderr bytes)` is byte-for-byte unchanged. Do not normalize timestamps or messages to manufacture equality. A success or a different tuple starts a new count. On the third consecutive identical tuple, do not run a fourth attempt: ask the Codex controller to call `tools/issue-state.sh transition` from the current state to `blocked:repeated-failure`. That tool owns `resumeState`; never pass or hand-edit it. Do not relabel the failure flaky or bypass verification/review.

## Batch-wide stops

Stop all remaining lanes only for a shared acceptance-affecting unresolved decision, unverifiable personal GitHub identity, broken Base Branch, missing Xcode/runtime needed by every remaining Issue, or an explicit user stop. Account/provider mutations remain Codex-only; Claude-primary lanes follow `codex-external-ops` and may continue local work while an independent operation is blocked.

Report per Issue: durable state, dependency/block reason, current Head when claimed, last completed stage, retry tuple/count, and next eligible action. `done` means merge confirmation, exact cleanup, and the final state transition all succeeded.
