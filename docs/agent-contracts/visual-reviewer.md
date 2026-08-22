# Visual reviewer contract

## 1. Purpose and authority

The visual reviewer evaluates the immutable screenshots produced by iOS verification. It does not edit code, change specifications, run external operations, or approve facts that are absent from the packet. A preference is not a blocking finding unless it violates an acceptance criterion or an observable usability requirement.

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

`visual-packet.json` is an exact schema-version-1 object. No unlisted key is allowed. All paths are relative to `.artifacts/issues/${issue}/${headSha}/`; the packet never contains Simulator UDIDs, DerivedData paths, Xcode paths, account data, secrets, or personal absolute paths.

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
    {"id": "AC-1", "text": "The localized screen is usable in every standard case"}
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

The real packet always contains exactly `iphone-en`, `iphone-ja`, `ipad-en`, and `ipad-ja` in that order. Every case has one primary image. Additional direct-child PNGs are ordered by filename and represent named UI states. Each image is a descriptor-bound regular file whose SHA-256 and decoded dimensions were checked at the packet publication boundary.

## 3. Review procedure

Open every image listed in every case. For each image, evaluate the following in order:

1. Acceptance criteria: the visible state supports every relevant `AC-*`; do not infer hidden behavior.
2. Clipping and overflow: text, controls, safe areas, sheets, alerts, keyboards, and navigation elements are fully visible.
3. Overlap and spacing: controls do not collide, obscure content, or create unusable accidental whitespace.
4. Translation: Japanese and English convey the specified meaning, fit the layout, and do not expose untranslated keys or placeholder text.
5. Information hierarchy: labels, primary actions, destructive actions, focus, and reading order are understandable on iPhone and iPad.
6. iPad adaptation: the layout uses the available width intentionally and does not merely stretch, crop, or misplace a phone presentation.
7. Dynamic Type indicators: visible text truncation, fixed-height text containers, or density that would clearly fail at larger text sizes are findings. A normal-size screenshot does not prove every accessibility size.
8. Tap targets: flag controls that are visibly too small, crowded, or ambiguous; do not claim a measured point size from pixels alone.
9. Spec comparison: compare only against designs or states named by the acceptance criteria or linked specification. Do not invent a new design requirement.

Compare the English/Japanese pair within each family and the iPhone/iPad pair within each language. If a required state is absent, report it as unsupported instead of treating the primary screenshot as proof.

## 4. Findings

Every finding is one single-line string with this exact shape:

```text
case=<case-id>; image=<relative-image-path>; check=<review-check>; finding=<observable problem>; requiredChange=<bounded correction>
```

`case` and `image` must match one packet entry. `check` must be one of `reviewChecks`. The finding describes visible evidence, and `requiredChange` stays within the Issue acceptance criteria. Do not include prompts, tokens, personal paths, raw logs, or speculative implementation details.

## 5. Exact visual result schema

The evaluator writes `.artifacts/issues/${issue}/${headSha}/visual-result.json`. The object has exactly the keys below. It remains bound to the draft exact bytes and to each primary screenshot exact digest; additional-state findings cite their packet image path in the finding string.

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
  "cases": [
    {
      "id": "iphone-en",
      "status": "approved",
      "screenshot": "iphone-en/screenshot.png",
      "screenshotDigest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      "findings": []
    },
    {
      "id": "iphone-ja",
      "status": "approved",
      "screenshot": "iphone-ja/screenshot.png",
      "screenshotDigest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "findings": []
    },
    {
      "id": "ipad-en",
      "status": "approved",
      "screenshot": "ipad-en/screenshot.png",
      "screenshotDigest": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "findings": []
    },
    {
      "id": "ipad-ja",
      "status": "approved",
      "screenshot": "ipad-ja/screenshot.png",
      "screenshotDigest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      "findings": []
    }
  ],
  "findings": [],
  "reviewedAt": "2026-08-21T13:00:00+09:00"
}
```

For approval, top-level `status` and all case statuses are `approved`, all finding arrays are empty, the four cases retain canonical order, and `reviewedAt` is a complete ISO 8601 timestamp no earlier than draft completion. If any finding exists, use `changes-requested` for the top-level status and the affected case status, place each finding in its affected case and once in the top-level array, and do not run finalization. The current finalizer accepts only the all-approved form and revalidates the draft, contract, matrix, current Head, and primary screenshot bytes before producing `verify.json`.
