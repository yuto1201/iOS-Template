---
name: plan-issue-batch
description: Use when a requested iOS change or backlog must be split into implementation-ready Issues with explicit dependencies and safe parallelism.
---

# Plan Issue Batch

Produce a reviewable Issue graph before Claim. Keep setup with its first useful outcome unless it has independent acceptance value; preserve `1 Issue = 1 Branch = 1 PR`.

## Required planning pass

1. Read `specs/README.md`, affected specifications, and `specs/decisions.md`. Classify relevant choices through `spec-workflow`.
2. Evaluate every UI outcome through [`ui-direction`](../ui-direction/SKILL.md). A current explicit comparison request always gates; an explicit skip overrides only when currentness, scope, authority, reason, and lack of conflict are clear. Otherwise, use confirmed-direction reuse when a confirmed spec covers the exact hierarchy/flow; gate an unconfirmed direction with any first-UI, root-navigation/information-architecture, or material primary-flow trigger; allow bounded direction-neutral UI only for an unconfirmed direction with no structural trigger whose acceptance does not decide hierarchy, navigation, or primary-flow interaction. Ambiguity gates. Every Issue planned for Claim after the `2026-09-06T00:31:41Z` cutover requires exactly one fully valid declaration across its existing acceptance criteria: one AC text, immediately after its `AC-*:` ID, starts with exact `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`, where `<route>` is one of the five values allowed by `ui-direction`; route-specific facts may follow Reason. Any AC text beginning exact `UI-direction route:` is a candidate, while incidental route words outside that prefix do not create one. Put confirmed anchors in Spec anchors and selection prerequisites in Dependencies. UI Issues retain the exact ordered `Target screens/states`, `English expectations`, and `Japanese expectations` UI verification fields as live guidance, and pre-Claim review checks both them and the declaration to be sealed. Identity/bootstrap and pure non-UI nodes instead set UI verification to exact `Not applicable`, put scope/non-UI reason in Goal/In scope, start one AC text with `UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`, and cite a relevant product/specification anchor in Spec anchors; they need no UI-direction anchor and may continue independently. When comparison applies, plan a separate specification/Decision Issue whose common record has scope, artifact path/revision, exact presented-bytes SHA-256, adopted/rejected elements, screens/states, and native adaptation; a single selection adds selected concept ID, while a hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping and adds a selected/base ID only if explicitly chosen. Do not invent a new Issue field. Do not rewrite an already sealed contract: one fetched before the cutoff with zero candidates is pre-D-030 legacy. If an earlier contract has any candidate, validate normally and reject malformed, unknown-route, empty Scope/Reason, or multiple candidates rather than treating it as legacy.
3. Before the first authenticated Issue creation in a new repository, have the selected Codex or Claude executor run `tools/sync-github-labels.sh --repo "$REPO" --executor "$EXECUTOR"` after the shared GitHub account preflight. Never create the first Issue against an uninitialized label set.
4. Split by independently verifiable outcome. Give every Issue Goal, In/Out of scope, ordered `AC-1..n`, exact spec anchors, dependencies, UI verification, Delivery stage with a positive Time budget and reason, Delivery profile with reason, Verification scope with reason when applicable, External operations, User approvals, and an expected write-set. Use exactly one of `type:feature`, `type:regression`, `type:docs`, or `type:release`.
   - `shape`: make one primary flow operable and reviewable quickly. Default to a 120-minute budget, `iphone-ja`, one smoke path, Build, and critical Unit Tests. If the budget will be exceeded, narrow scope, split a `harden` Issue, stop for an environment failure, or use `blocked:user`; do not silently add release work.
   - `harden`: improve one approved behavior or one quality concern. Use `targeted` with the exact affected ordered Simulator cases when application verification is needed. Do not combine unrelated localization, accessibility, Dark Mode, recovery, performance, or regression work.
   - `release`: verify one explicit release candidate. Use `strict` + `full`, the complete four-case matrix and visual/accessibility/integration/review gates. Product changes discovered here become separate shape or harden Issues.
   - Delivery stage is independent from workflow state, Issue type, and risk profile. Existing sealed Issues without it remain legacy release-level contracts; do not rewrite or shrink them after Claim.
   - Reserve `release` for a `type:release` application release candidate. Pure delivery-tool/schema/validator/review/evidence work uses `harden + strict`, exact `UI verification: Not applicable`, and no application Verification or Verification scope; its canonical workflow-only route keeps repository tests, current-Head review, and pre-merge checks without Xcode or Simulator work.
   - `fast`: non-UI, local, low-risk work. No approval-required or strict provider operation.
   - `standard`: ordinary user-visible UI, localization, or accessibility work.
   - `strict`: auth/authorization, secrets, schema/migration, production/destructive data, billing/plan, privacy/legal, App Store/TestFlight/signing, or delivery-gate changes.
   - An existing Issue without an explicit profile remains `strict`; never downgrade it by inference.
   - Keep risk and maturity separate: a security-sensitive shape can be `strict` without becoming a release candidate; a normal harden Issue can remain `standard` while using targeted evidence.
   - Plan English/iPad, Dark Mode, Dynamic Type, VoiceOver, 44pt boundaries, performance, and recovery as focused harden Issues only when needed. Make the release Issue depend on the required ones. Preserve String Catalog keys, flexible layout and critical auth/data/billing tests from the beginning; do not require finished English/iPad UI per shape Issue.
5. Run `tools/validate-issue-body.sh --type "$TYPE"` on each proposed body. An Issue is Definition of Ready only when that validator passes and every acceptance-affecting decision is confirmed.
6. Draw directed edges `prerequisite -> dependent`. Reject cycles. A dependency is an ordering constraint, not a reason to combine otherwise independent outcomes.
7. Add serialization edges when expected write-sets overlap. Treat Xcode project/configuration edits as conflicts even when paths are generated indirectly.

Return one table in dependency order:

| Issue | Outcome / AC IDs | Spec anchors | Expected writes | Depends on | DoR / block |
| --- | --- | --- | --- | --- | --- |

Then list dependency edges and serialization groups. Codex or Claude may create and update GitHub Issues when the Issue contract names that executor and the shared `external-ops` account and target checks pass.

## Partial blocking

An unresolved decision blocks only Issues whose acceptance criteria depend on it, plus their dependents (`blocked:user` or `blocked:dependency`). Continue planning and shipping unaffected graph components. Stop the whole batch only when a shared unresolved decision changes every remaining Issue.

Do not invent defaults, Issue numbers, Branches, or external approval. Record the uncertainty in the affected row.
