---
name: plan-issue-batch
description: Use when a requested iOS change or backlog must be split into implementation-ready Issues with explicit dependencies and safe parallelism.
---

# Plan Issue Batch

Produce a reviewable Issue graph before Claim. Keep setup with its first useful outcome unless it has independent acceptance value; preserve `1 Issue = 1 Branch = 1 PR`.

## Required planning pass

1. Read `specs/README.md`, affected specifications, and `specs/decisions.md`. Classify relevant choices through `spec-workflow`.
2. Before the first authenticated Issue creation in a new repository, have the selected Codex or Claude executor run `tools/sync-github-labels.sh --repo "$REPO" --executor "$EXECUTOR"` after the shared GitHub account preflight. Never create the first Issue against an uninitialized label set.
3. Split by independently verifiable outcome. Give every Issue Goal, In/Out of scope, ordered `AC-1..n`, exact spec anchors, dependencies, UI verification, Delivery profile with reason, External operations, User approvals, and an expected write-set. Use exactly one of `type:feature`, `type:regression`, `type:docs`, or `type:release`.
   - `fast`: non-UI, local, low-risk work. No approval-required or strict provider operation.
   - `standard`: ordinary user-visible UI, localization, or accessibility work.
   - `strict`: auth/authorization, secrets, schema/migration, production/destructive data, billing/plan, privacy/legal, App Store/TestFlight/signing, or delivery-gate changes.
   - An existing Issue without an explicit profile remains `strict`; never downgrade it by inference.
   - Independently declare Verification scope with Scope, Stage, Reason in order. Normal UI uses standard + iphone-ja / feature; adaptation uses full / adaptation; release uses strict + full / release. Foundation, identity, project configuration, gate and cross-device changes use full. Absent scope remains legacy full.
   - Plan one shared English/iPad finishing Issue per app, link deferred feature work, and make release depend on it. Preserve String Catalog keys, flexible layout and critical auth/data/billing tests. Do not invent Issue numbers or require finished English/iPad UI per feature.
4. Run `tools/validate-issue-body.sh --type "$TYPE"` on each proposed body. An Issue is Definition of Ready only when that validator passes and every acceptance-affecting decision is confirmed.
5. Draw directed edges `prerequisite -> dependent`. Reject cycles. A dependency is an ordering constraint, not a reason to combine otherwise independent outcomes.
6. Add serialization edges when expected write-sets overlap. Treat Xcode project/configuration edits as conflicts even when paths are generated indirectly.

Return one table in dependency order:

| Issue | Outcome / AC IDs | Spec anchors | Expected writes | Depends on | DoR / block |
| --- | --- | --- | --- | --- | --- |

Then list dependency edges and serialization groups. Codex or Claude may create and update GitHub Issues when the Issue contract names that executor and the shared `external-ops` account and target checks pass.

## Partial blocking

An unresolved decision blocks only Issues whose acceptance criteria depend on it, plus their dependents (`blocked:user` or `blocked:dependency`). Continue planning and shipping unaffected graph components. Stop the whole batch only when a shared unresolved decision changes every remaining Issue.

Do not invent defaults, Issue numbers, Branches, or external approval. Record the uncertainty in the affected row.
