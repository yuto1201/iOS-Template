# Acceptance auditor contract

The acceptance auditor applies the canonical [opposite-model review packet](./review-packet.md) contract to the exact reviewed commit.

## Inputs

- A review packet conforming to `docs/agent-contracts/review-packet.md`.
- The Issue contract, verification result, diff, and images referenced by the packet.
- The exact `baseSha`, `headSha`, `verifySha`, and Issue-contract digest.

## Ordered checks

1. Validate required packet fields and confirm `headSha == verifySha`.
2. Recompute or compare the supplied Issue-contract digest and reject stale/mismatched evidence.
3. Map every `AC-*` to concrete implementation and verification evidence.
4. Read the sealed Issue contract `fetchedAt` before UI-direction classification. A declaration candidate is any acceptance-criterion text that begins with exact `UI-direction route:` immediately after its `AC-*:` ID. It is valid only in form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`, with `<route>` exactly `comparison`, `explicit-skip`, `confirmed-direction reuse`, `bounded direction-neutral`, or `not-applicable`; route-specific facts may follow Reason. Incidental route words outside that prefix do not create a candidate. If `fetchedAt` is earlier than `2026-09-06T00:31:41Z` and there are zero candidates, classify the contract as pre-D-030 legacy: do not infer a route, demand retroactive HTML/route declaration, or modify/reseal the contract; review its original sealed AC, spec anchors, Dependencies, and current-Head evidence. If an earlier contract has one or more candidates, validate it normally and reject unless exactly one candidate is fully valid; malformed, unknown-route, empty Scope/Reason, and multiple-candidate cases are not legacy. A contract at or after the cutoff has the same exactly-one and validity requirements, including rejection when no candidate exists.
5. For every non-legacy contract, identify the route only from the valid AC-text declaration, then validate its [`ui-direction`](../../.agents/skills/ui-direction/SKILL.md) classification from packet-sealed Goal, acceptance criteria, Spec anchors, Dependencies, linked confirmed specifications/Decision, and the current-Head diff/evidence. The review packet does not contain live UI verification; never infer or require it here. Apply the route matrix: a packet-supported current explicit comparison always gates; a packet-supported explicit skip overrides only when currentness, exact scope, authority, reason, and lack of conflict are supported; otherwise exact confirmed hierarchy/flow coverage uses confirmed-direction reuse. When direction is unconfirmed, creating the first user-facing UI, creating or changing root navigation/information architecture, or materially redesigning a primary flow gates; without any of those three triggers, bounded direction-neutral UI is permitted only when acceptance decides no hierarchy, navigation, or primary-flow interaction. Ambiguity is a blocking gated classification.
6. For every non-legacy contract, require exactly one valid declaration across the sealed acceptance criteria and identify the route only from that AC-text prefix, never bare route words elsewhere. Validate its nonempty Scope/Reason, route-specific facts after Reason, confirmed anchors in Spec anchors, and the completed selection prerequisite in Dependencies. For comparison, require common scope, artifact path/revision, exact presented-bytes SHA-256, adopted/rejected elements, screens/states, and native adaptation; a single selection adds selected concept ID, while a hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping and adds selected/base ID only if explicitly chosen. For not-applicable Identity/bootstrap or pure non-UI work, confirm exact non-UI scope/reason from sealed Goal/AC and the diff, plus a relevant product/specification anchor, without requiring a UI-direction anchor.
7. Ensure HTML bytes or CSS fidelity are not substituted for current-Head native implementation evidence.
8. Inspect all listed simulator cases and images; do not infer unlisted runs.
9. Check for scope expansion and unsupported Build, Test, account, or external-operation claims.
10. Emit one `acceptanceAssessment` entry for every `AC-*` before deciding the verdict.

Use the [staged-development policy](../../specs/development-stages.md) to distinguish feature completion from release readiness. Review the sealed scope: explicit iphone-ja means one Japanese iPhone case; absent/full means all four. Deferred English/iPad polish belongs in one linked adaptation Issue, not additional feature ACs or proof of support. Adaptation/release require full coverage at the candidate Head.

## Finding schema

Use the JSON result and finding schemas in `docs/agent-contracts/review-packet.md`. Every acceptance item must be `supported` or `unsupported` and cite exact evidence paths.

## Severity

- `critical`: approval would conceal an authority breach, secret exposure, destructive action, or fabricated evidence.
- `high`: any `AC-*` is unsupported or the reviewed/verified SHA or contract digest does not match.
- `medium`: evidence exists but is incomplete, ambiguous, or does not test the claimed failure mode.
- `low`: a non-blocking evidence presentation improvement.

## Approval rule

Approve only if packet identity fields match, every `AC-*` is supported, all mandatory cases are evidenced, and no unresolved `critical`, `high`, or `medium` finding remains. In addition, a non-legacy contract must have packet-visible sealed evidence for exactly one valid UI-direction declaration and every applicable prerequisite; a qualifying pre-D-030 legacy contract instead needs its original sealed AC/spec/evidence supported and must not be rejected only for lacking a declaration.

## Prohibited actions

Do not edit packet artifacts, regenerate evidence, run tests, operate simulators, use authenticated external services, commit, push, merge, or fill an evidence gap by assumption.
