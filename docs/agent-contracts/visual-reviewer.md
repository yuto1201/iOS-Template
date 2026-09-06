# Visual reviewer contract

## 1. Purpose and authority

The visual reviewer evaluates the immutable screenshots produced by iOS verification. It does not edit code, change specifications, run external operations, or approve facts that are absent from the packet. A preference is not a blocking finding unless it violates an acceptance criterion or an observable usability requirement.

Apply the [staged-development policy](../../specs/development-stages.md): an explicit iphone-ja feature packet has one Japanese iPhone case; absent/full has four. Inspect every required image. English/iPad polish may be deferred to a linked adaptation Issue, not added as feature ACs or claimed as completed. Adaptation/release packets require full.

Read the sealed Issue contract `fetchedAt` before classifying [`ui-direction`](../../.agents/skills/ui-direction/SKILL.md). A declaration candidate is any acceptance-criterion text that begins with exact `UI-direction route:` immediately after its `AC-*:` ID. It is valid only in form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`, with `<route>` exactly `comparison`, `explicit-skip`, `confirmed-direction reuse`, `bounded direction-neutral`, or `not-applicable`; route-specific facts may follow Reason. Incidental route words outside that prefix do not create a candidate. If `fetchedAt` is earlier than `2026-09-06T00:31:41Z` and there are zero candidates, treat the contract as pre-D-030 legacy: do not infer a route, demand retroactive HTML/route declaration, or modify/reseal the contract; compare the images only with its original sealed AC, linked specifications, and current-Head evidence. If an earlier contract has one or more candidates, validate it normally and reject unless exactly one candidate is fully valid; malformed, unknown-route, empty Scope/Reason, and multiple-candidate cases are not legacy. A contract at or after the cutoff has the same exactly-one and validity requirements, including rejection when no candidate exists.

For every non-legacy contract, identify the route only from that valid AC-text prefix, never from bare route words, then validate it using packet-sealed Goal, acceptance criteria, Spec anchors, Dependencies, linked confirmed specifications/Decision, and current-Head diff/evidence. Live UI verification is absent from the packet and is never review evidence. A packet-supported current explicit comparison always gates; a packet-supported explicit skip overrides only when currentness, exact scope, authority, reason, and lack of conflict are clear; otherwise exact confirmed hierarchy/flow coverage uses confirmed-direction reuse. When direction is unconfirmed, creating the first user-facing UI, creating or changing root navigation/information architecture, or materially redesigning a primary flow gates; without any of those three triggers, bounded direction-neutral UI is permitted only when acceptance decides no hierarchy, navigation, or primary-flow interaction. Ambiguity is gated.

For every non-legacy contract, require exactly one valid declaration across the sealed acceptance criteria, with nonempty Scope/Reason and applicable facts after Reason. For confirmed-direction reuse, require its exact UI-direction anchor. For bounded direction-neutral UI, require a relevant product/behavior anchor and verify the non-decision boundary. For explicit skip, require packet-visible currentness, scope, authority, reason, and no conflicting comparison request. For not-applicable Identity/bootstrap or pure non-UI work, confirm scope/reason from sealed Goal/AC and diff plus a relevant product/specification anchor; never require a UI-direction anchor.

The reviewer consumes only the canonical packet for the current Issue and Head:

```bash
tools/visual-review-packet.sh \
  --issue 42 \
  --expected-base "${BASE_SHA}" \
  --draft ".artifacts/issues/42/${HEAD_SHA}/verify-draft.json" \
  --output ".artifacts/issues/42/${HEAD_SHA}/visual-packet.json"
```

The packet builder must succeed immediately before evaluation. A packet copied from another Head, a non-canonical path, an image opened outside the packet, or an existing packet that the command refuses to replace is not review input.

## 2. Exact packet schema

`visual-packet.json` is an exact schema-version-1 object. No unlisted key is allowed. Descriptor references (`draft`, `issueContract`, and `matrix`) are repository-relative canonical paths. Image paths are relative to `.artifacts/issues/${issue}/${headSha}/`. The packet never contains Simulator UDIDs, DerivedData paths, Xcode paths, account data, secrets, or personal absolute paths.

```json
{
  "schemaVersion": 1,
  "status": "ready-for-visual-review",
  "issue": 42,
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "draft": {
    "path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/verify-draft.json",
    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "issueContract": {
    "path": ".artifacts/issues/42/issue-contract.json",
    "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  },
  "matrix": {
    "path": ".artifacts/batches/template-live/simulator-matrix.json",
    "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  },
  "acceptanceCriteria": [
    {"id": "AC-1", "text": "UI-direction route: confirmed-direction reuse; Scope: settings hierarchy and flow; Reason: the linked specification fixes both the exact hierarchy and flow."}
  ],
  "cases": [
    {
      "id": "iphone-en",
      "family": "iPhone",
      "deviceType": {
        "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        "name": "iPhone 17 Pro"
      },
      "runtime": {
        "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "version": "26.5"
      },
      "locale": "en_US",
      "language": "en",
      "images": [
        {
          "state": "primary",
          "primary": true,
          "path": "iphone-en/screenshot.png",
          "digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
          "width": 1179,
          "height": 2556
        },
        {
          "state": "settings-open",
          "primary": false,
          "path": "iphone-en/settings-open.png",
          "digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
          "width": 1179,
          "height": 2556
        }
      ]
    }
  ],
  "reviewChecks": [
    "acceptance-criteria",
    "clipping",
    "overlap",
    "translation",
    "information-hierarchy",
    "ipad-adaptation",
    "dynamic-type-indicators",
    "tap-targets",
    "spec-comparison"
  ]
}
```

A real packet contains exactly the contract's case sequence: iphone-ja alone, or iphone-en, iphone-ja, ipad-en, ipad-ja in that order. Every required case has one primary image. Additional direct-child PNGs represent named states and remain ordered by filename. Images retain descriptor-bound SHA-256 and decoded-dimension checks.

## 3. Review procedure

Open every image listed in every case. For each image, evaluate the following in order:

1. Acceptance criteria: the visible state supports every relevant `AC-*`; do not infer hidden behavior.
2. Clipping and overflow: text, controls, safe areas, sheets, alerts, keyboards, and navigation elements are fully visible.
3. Overlap and spacing: controls do not collide, obscure content, or create unusable accidental whitespace.
4. Translation: the languages required by the Issue convey the specified meaning, fit the layout, and do not expose untranslated keys or placeholder text. Explicitly deferred English copy remains incomplete, not approved as translated.
5. Information hierarchy: labels, primary actions, destructive actions, focus, and reading order are understandable in the required device scope.
6. iPad adaptation: when required by the Issue or adaptation/release stage, the layout uses the available width intentionally and does not merely stretch, crop, or misplace a phone presentation.
7. Dynamic Type indicators: visible text truncation, fixed-height text containers, or density that would clearly fail at larger text sizes are findings. A normal-size screenshot does not prove every accessibility size.
8. Tap targets: flag controls that are visibly too small, crowded, or ambiguous; do not claim a measured point size from pixels alone.
9. Spec comparison: compare only against designs or states named by the acceptance criteria or linked specification. For a `comparison` route identified by a valid AC-text declaration, require common scope, artifact path/revision, exact presented-bytes SHA-256, adopted/rejected elements, screens/states, and allowed native adaptation. A single selection adds selected concept ID; a hybrid adds an exhaustive adopted-element-to-source-concept-ID mapping and adds selected/base ID only if explicitly chosen. Assess the selected hierarchy, flow, and states from the confirmed specification/Decision while allowing documented native adaptation; do not demand CSS-pixel parity or treat the HTML comparison as native evidence. For another route identified by a valid declaration, do not invent comparison requirements. Do not invent a new design requirement.

For adaptation/release, compare the English/Japanese pair within each family and the iPhone/iPad pair within each language. For feature work, apply the declared scope without inferring parity from one locale or device. If a required state is absent, report it as unsupported instead of treating the primary screenshot as proof.

## 4. Findings

Every finding is one single-line string with this exact shape:

```text
case=<case-id>; image=<relative-image-path>; check=<review-check>; finding=<observable problem>; requiredChange=<bounded correction>
```

`case` and `image` must match one packet entry. `check` must be one of `reviewChecks`. The finding describes visible evidence, and `requiredChange` stays within the Issue acceptance criteria. Do not include prompts, tokens, personal paths, raw logs, or speculative implementation details.

## 5. Exact visual result schema

The evaluator writes `.artifacts/issues/${issue}/${headSha}/visual-result.json`. The object has exactly the keys below. It binds the exact draft and visual-packet bytes, and attests every ordered primary and additional image in every case.

```json
{
  "schemaVersion": 1,
  "status": "approved",
  "issue": 42,
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "draft": {
    "path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/verify-draft.json",
    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "visualPacket": {
    "path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/visual-packet.json",
    "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  },
  "cases": [
    {
      "id": "iphone-en",
      "status": "approved",
      "images": [
        {
          "state": "primary",
          "path": "iphone-en/screenshot.png",
          "digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
          "findings": []
        },
        {
          "state": "settings-open",
          "path": "iphone-en/settings-open.png",
          "digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
          "findings": []
        }
      ],
      "findings": []
    },
    {
      "id": "iphone-ja",
      "status": "approved",
      "images": [
        {"state": "primary", "path": "iphone-ja/screenshot.png", "digest": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "findings": []}
      ],
      "findings": []
    },
    {
      "id": "ipad-en",
      "status": "approved",
      "images": [
        {"state": "primary", "path": "ipad-en/screenshot.png", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111", "findings": []}
      ],
      "findings": []
    },
    {
      "id": "ipad-ja",
      "status": "approved",
      "images": [
        {"state": "primary", "path": "ipad-ja/screenshot.png", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222", "findings": []}
      ],
      "findings": []
    }
  ],
  "findings": [],
  "reviewedAt": "2026-08-21T13:00:00+09:00"
}
```

The example is an exact representation: the first case demonstrates an additional state while the other packet cases contain only their primary state. A real result must reproduce every packet image in exact order and may never omit an entry. For approval, a non-legacy contract's packet-visible sealed evidence must support exactly one valid UI-direction declaration; a qualifying pre-D-030 legacy contract instead needs its original sealed AC/spec/evidence supported and must not be rejected only for lacking a declaration. In both cases, top-level `status` and all case statuses are `approved`, all finding arrays are empty, the scope-selected cases retain canonical order, and `reviewedAt` is a complete ISO 8601 timestamp no earlier than draft completion. If any finding exists, use `changes-requested` for the top-level status and the affected case status, place each finding in its affected case and once in the top-level array, and do not run finalization. The current finalizer accepts only the all-approved form and revalidates the draft, contract, matrix, current Head, packet bytes, and every reviewed image before producing `verify.json`.
