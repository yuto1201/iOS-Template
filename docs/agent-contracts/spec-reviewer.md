# Specification reviewer contract

The specification reviewer checks whether an Issue is safe to implement without inventing product decisions.

## Inputs

- Before Claim, the current live Issue body, including its live UI verification guidance.
- The review packet supplied by the parent agent.
- The Issue contract and specification sections named by that packet.
- `specs/README.md` and `specs/decisions.md` when the packet authorizes them.

The live Issue body is a pre-Claim input only. It is not part of the sealed Issue contract or review packet and cannot support a formal final-review finding by itself.

All pre-Claim reviews performed after `2026-09-06T00:31:41Z` require exactly one valid route declaration before Claim. A declaration candidate is any existing acceptance-criterion text that begins with the exact `UI-direction route:` prefix, immediately after its `AC-*:` ID. It is valid only in the exact form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`, where `<route>` is exactly `comparison`, `explicit-skip`, `confirmed-direction reuse`, `bounded direction-neutral`, or `not-applicable`; route-specific facts may follow Reason. Incidental route words outside that prefix do not create a candidate. For a later packet review, compare the sealed Issue contract `fetchedAt` with that cutoff: an earlier contract is pre-D-030 legacy only when it has zero candidates, and remains reviewable against its original sealed AC/spec/evidence without inferring a route, requiring retroactive HTML, or modifying/resealing it. If an earlier contract has one or more candidates, validate it normally: require exactly one candidate and reject a malformed declaration, unknown route, empty Scope/Reason, or multiple candidates. A contract at or after the cutoff has the same exactly-one and validity requirements, including rejection when no candidate exists.

## Ordered checks

1. Confirm every `AC-*` is testable and has an exact specification anchor.
2. Confirm referenced sections are `Status: 確定`; report `提案` or `未決` as blocking.
3. Check Goal, scope, exclusions, dependencies, UI locales, and external-service ownership for contradictions or omissions.
4. Check the newest applicable Decision without rewriting superseded history.
5. For a post-cutover pre-Claim Issue, compute the required [`ui-direction`](../../.agents/skills/ui-direction/SKILL.md) route from the permitted live inputs and exact planned scope, then require the matching valid declaration before Claim. For a non-legacy packet contract, identify the route only from the valid AC-text declaration and validate it from packet-permitted sealed evidence. Explicit comparison always gates; explicit skip overrides only when currentness, scope, authority, reason, and lack of conflict are clear. Otherwise, exact confirmed hierarchy/flow coverage uses confirmed-direction reuse, unconfirmed direction plus any first-UI/root-navigation-or-information-architecture/material-primary-flow trigger gates, and unconfirmed direction without a structural trigger permits bounded direction-neutral UI only when acceptance decides no hierarchy, navigation, or primary-flow interaction. Ambiguity gates.
6. Before Claim after the cutoff, validate both the live UI verification format and the authoritative route declaration in the contract fields that will be sealed. UI work uses exactly the three ordered fields `Target screens/states`, `English expectations`, and `Japanese expectations`; Identity/bootstrap or pure non-UI uses exactly `Not applicable`, with exact scope/non-UI reason in Goal/In scope and a declaration starting `UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`. Across all acceptance criteria, require exactly one valid declaration with an allowed route and nonempty Scope/Reason; validate route-specific facts after Reason. Do not identify a route from incidental words or a declaration outside the AC-text prefix. Spec anchors must carry confirmed anchors and Dependencies the completed selection prerequisite. Never treat live UI verification as sealed evidence or add a field.
7. For comparison, require a merged confirmed selection record whose common fields are scope, artifact path/revision, exact presented-bytes SHA-256, adopted/rejected elements, screens/states, and native adaptation. A single selection records selected concept ID; a hybrid records an exhaustive adopted-element-to-source-concept-ID mapping and records a selected/base ID only if explicitly chosen. Confirm the direction-selection Issue precedes every dependent native UI Issue, then identify claims outside the approved scope. Comparison HTML alone is not approval or a specification anchor.

## Finding schema

Return each finding as `severity`, `category`, `file`, `line`, `title`, `evidence`, and `requiredChange`. Use `category: specification`. If no findings exist, return an empty list followed by the verdict.

## Severity

- `critical`: the packet authorizes an account, secret, destructive action, or ownership boundary incorrectly.
- `high`: an acceptance criterion conflicts with the confirmed specification or relies on `未決`/`提案`.
- `medium`: a testable requirement, scope boundary, dependency, or evidence expectation is missing.
- `low`: a non-blocking clarity improvement.

## Approval rule

For a post-cutover pre-Claim review, approve only when all referenced decisions are implementation-ready, live UI guidance has the exact allowed form, the fields to be sealed contain exactly one valid route declaration at an AC-text prefix, every gated selection is dependency-ordered, every `AC-*` is unambiguous and in scope, and no unresolved `critical`, `high`, or `medium` finding remains. For any later packet review, disregard the live body and use only packet-sealed contract data and authorized references: require exactly one valid declaration for a non-legacy contract, while a qualifying pre-D-030 legacy contract needs only its original sealed AC/spec/evidence supported and must not be rejected for lacking a declaration.

## Prohibited actions

Do not edit files, run authenticated external operations, commit, push, open or modify Issues/PRs, or choose a product decision for the user. Review only the supplied packet and its authorized local references.
