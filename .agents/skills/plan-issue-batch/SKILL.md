---
name: plan-issue-batch
description: Use when a requested iOS change or backlog must be split into implementation-ready Issues with explicit dependencies and safe parallelism.
---

# Plan Issue Batch

Produce a reviewable Issue graph before Claim. Keep setup with its first useful outcome unless it has independent acceptance value; preserve `1 Issue = 1 Branch = 1 PR`.

## Required planning pass

1. Read `specs/README.md`, affected specifications, and `specs/decisions.md`. Classify relevant choices through `spec-workflow`.
2. Split by independently verifiable outcome. Give every Issue Goal, In/Out of scope, ordered `AC-1..n`, exact spec anchors, dependencies, External operations, User approvals, and an expected write-set.
3. Run `tools/validate-issue-body.sh` on each proposed body. An Issue is Definition of Ready only when that validator passes and every acceptance-affecting decision is confirmed.
4. Draw directed edges `prerequisite -> dependent`. Reject cycles. A dependency is an ordering constraint, not a reason to combine otherwise independent outcomes.
5. Add serialization edges when expected write-sets overlap. Treat Xcode project/configuration edits as conflicts even when paths are generated indirectly.

Return one table in dependency order:

| Issue | Outcome / AC IDs | Spec anchors | Expected writes | Depends on | DoR / block |
| --- | --- | --- | --- | --- | --- |

Then list dependency edges and serialization groups. Do not create GitHub Issues from a Claude session; authenticated creation or updates follow `codex-external-ops` and remain Codex-only.

## Partial blocking

An unresolved decision blocks only Issues whose acceptance criteria depend on it, plus their dependents (`blocked:user` or `blocked:dependency`). Continue planning and shipping unaffected graph components. Stop the whole batch only when a shared unresolved decision changes every remaining Issue.

Do not invent defaults, Issue numbers, Branches, or external approval. Record the uncertainty in the affected row.
