---
name: ui-direction
description: Use when the current user explicitly requests an HTML UI comparison, or when the scoped UI direction is unconfirmed and work creates the first user-facing UI, changes root navigation or information architecture, or materially redesigns a primary flow before SwiftUI implementation.
---

# UI Direction

Resolve an acceptance-affecting UI direction before planning or claiming the dependent native UI Issue. This is a conditional specification gate, not a replacement for SwiftUI implementation or Simulator verification.

## Preserve pre-D-030 contracts

The cutover is `2026-09-06T00:31:41Z`, the replacement Issue #47 `createdAt`. A declaration candidate is any existing acceptance-criterion text that begins with the exact `UI-direction route:` prefix, immediately after its `AC-*:` ID. It is valid only in the exact form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`. `<route>` must be exactly `comparison`, `explicit-skip`, `confirmed-direction reuse`, `bounded direction-neutral`, or `not-applicable`; route-specific facts may follow Reason. Incidental route words outside that prefix, including prose listing all routes, do not create a candidate. If a sealed Issue contract has `fetchedAt` earlier than the cutoff and zero candidates, treat it as pre-D-030 legacy. Do not infer a route, require retroactive HTML or a route declaration, or modify/reseal the contract; review or resume it against its original sealed acceptance criteria, specification anchors, Dependencies, and evidence. If an earlier contract has one or more candidates, validate it normally and reject unless exactly one candidate is fully valid; malformed, unknown-route, empty Scope/Reason, and multiple-candidate cases are not legacy. A contract fetched at or after the cutoff has the same exactly-one and validity requirements, including rejection when no candidate exists. Every post-cutover pre-Claim workflow must add a fully valid declaration before Claim. Determine this boundary only from sealed `fetchedAt` and prefix candidates, never Issue number, update time, file mtime, live UI verification, or bare route words outside the prefix.

## Decide whether the gate applies

Evaluate the current user instruction before applying the normal rule. An explicit current request for an HTML comparison is the highest-priority trigger and runs the gate regardless of an existing direction. If the current instruction instead explicitly skips the comparison, that instruction may override the normal gate only when its scope, current applicability, and authority are unambiguous and it does not conflict with a current comparison request. Before a post-cutover Claim, start one acceptance-criterion text with `UI-direction route: explicit-skip; Scope: <nonempty>; Reason: <nonempty>` and put currentness, authority, and lack of conflict after Reason; cite a relevant confirmed product/specification or Decision anchor in Spec anchors. A conflict or ambiguity in any of those facts makes the dependent UI work `blocked:user`.

Without either explicit override, classify the exact planned scope in this order:

1. If a confirmed UI direction/specification covers the exact planned hierarchy and flow, use the confirmed-direction reuse route even if the Issue or change is labelled structural. Before a post-cutover Claim, start one acceptance-criterion text with `UI-direction route: confirmed-direction reuse; Scope: <nonempty>; Reason: <nonempty>`, put the covered hierarchy/flow after Reason, and cite the reusable confirmed UI-direction anchor in Spec anchors.
2. Otherwise, if the scoped UI direction is unconfirmed and the work does at least one of the following, run the comparison gate:

   - creates the app's first user-facing UI;
   - creates or changes root navigation or information architecture; or
   - materially redesigns a primary flow's structure or interaction.

3. If the scoped direction is unconfirmed and none of those structural triggers applies, a bounded direction-neutral UI route is allowed only when its acceptance criteria do not decide hierarchy, navigation, or primary-flow interaction. Before a post-cutover Claim, start one acceptance-criterion text with `UI-direction route: bounded direction-neutral; Scope: <nonempty>; Reason: <nonempty>`, put that non-decision boundary after Reason, and cite the relevant confirmed product/behavior specification anchor in Spec anchors. If the work would make any of those direction decisions, run the gate.

A required trigger still applies when the work is described as a form, regression, localization, or accessibility change. If direction coverage, trigger applicability, or neutrality is ambiguous, fail closed by running the comparison gate.

For a post-cutover Claim, Identity bootstrap and purely non-UI work are a separate not-applicable route, not UI-direction skips, and need no confirmed UI-direction anchor. Set the UI verification body to exactly `Not applicable`; put the exact non-UI scope and reason in Goal/In scope or another existing scope section; start one acceptance-criterion text with `UI-direction route: not-applicable; Scope: <nonempty>; Reason: <nonempty>`; and cite a relevant confirmed product/specification anchor in Spec anchors. Evaluate only a later native UI outcome through this gate.

UI verification is live, unsealed guidance. UI Issues keep exactly the three ordered fields `Target screens/states`, `English expectations`, and `Japanese expectations`; they may mirror the comparison, explicit-skip, confirmed-direction reuse, or bounded direction-neutral route there, but those words never count as a declaration. Pre-Claim review checks both the live field and exactly one valid declaration in the fields to be sealed. Final review identifies the route only from that sealed AC-text prefix, then validates its Scope, Reason, and route-specific facts from the sealed Issue-contract Goal, acceptance criteria, Spec anchors, Dependencies, linked confirmed specifications/Decision, and current-Head diff/evidence. Do not add a new Issue field.

## Confirm the comparison brief

Before drawing concepts, confirm the product goal, target user and job, primary flow, screens and relevant states, content/data assumptions, constraints, non-goals, and exact specification anchors. Use synthetic representative content. If an unresolved choice can change acceptance criteria, stop and route it through [`spec-workflow`](../spec-workflow/SKILL.md) as `blocked:user`.

## Create a comparable HTML artifact

Create one self-contained file at exactly:

```text
.artifacts/ui-direction/<flow-slug>/<revision>/comparison.html
```

Present two or three concepts with stable concept IDs. Hold the viewport, task, content, data, states, and fidelity constant, while making information hierarchy, navigation, or interaction materially different. Cosmetic-only color, typography, or spacing variants are not distinct concepts. For each concept, state its hypothesis, trade-offs, intended iOS translation, accessibility considerations, and the limitations of the static prototype.

Keep the artifact safe and portable: use synthetic data and inline HTML/CSS/JavaScript only; include a restrictive Content Security Policy; do not include secrets, personal or production data, analytics, remote scripts, fonts, images, stylesheets, CSS URLs/imports, network requests, form actions, meta refresh, `iframe`, `object`, or `embed` content.

Use this restrictive meta-policy as the baseline, narrowing `script-src` further when the comparison needs no JavaScript:

```html
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; connect-src 'none'; font-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; object-src 'none'">
```

Treat the exact presented bytes as immutable. Record their SHA-256 digest and revision. Never overwrite a revision that a user has seen; any brief or byte change creates a new revision and requires a new selection.

## Require an explicit selection

Ask the user to select one stable concept ID, or provide an exact hybrid mapping that names each adopted element and its source concept ID. Praise, ranking, silence, or an approximate response such as “A-ish” is not approval. If a hybrid is ambiguous, create a combined concept in a new revision and ask for selection again.

## Seal the direction before native work

Use [`spec-workflow`](../spec-workflow/SKILL.md) in a separate specification Issue, Branch, and PR. Every selection record includes scope, artifact revision/path, exact SHA-256 of the presented bytes, adopted and rejected elements, affected screens/states, and allowed native adaptation. A single-concept selection records its selected concept ID. A hybrid instead records an exhaustive adopted-element-to-source-concept-ID mapping; it records a selected/base concept ID only when the user explicitly chose one as part of that hybrid.

Merge that specification change before approving or claiming any dependent native UI Issue, and link it through the Issue's existing Spec anchors and Dependencies. For the dependent Issue, start one acceptance-criterion text with `UI-direction route: comparison; Scope: <nonempty>; Reason: <nonempty>` and place applicable selection facts after Reason. The live UI verification field may mirror the route as guidance but does not establish it. Independent non-UI lanes may continue. Do not add a special Issue-contract field or present the HTML as a canonical verification artifact.

The confirmed specification is the product truth. Translate its hierarchy, flow, and state intent into native SwiftUI components; do not embed the comparison in `WKWebView` or copy CSS pixels mechanically. Current-Head Build, Test, Simulator, and required visual evidence remain the proof of the native implementation.
