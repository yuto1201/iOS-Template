---
name: prepare-appstore-assets
description: Prepare, validate, review, and immutably seal localized App Store metadata, privacy and legal text, review notes, release notes, and release screenshots. Use when an iOS release candidate needs App Store Connect assets, when an existing submission package changed, or before the submit-appstore-release workflow.
---

# Prepare App Store Assets

Build the package from the confirmed product specification and exact release candidate. This skill proves readiness; it does not open or mutate App Store Connect.

## Preconditions

1. Read the release Issue, confirmed `specs/` documents, `App Store/README.md`, `docs/AUTHORITY.md`, and `docs/agent-contracts/release-auditor.md`.
2. Require exact source Head, trusted verification Base and Issue, canonical passed full application verify.json for that Head and Bundle ID, the separate distribution-build digest, version, and first-publication status. English/iPad adaptation must be complete. Japanese iPhone-only evidence never satisfies release readiness.
3. Use the selected Codex or Claude executor to refresh `App Store/submission/requirements.json` from official Apple documentation when its `retrievedAt` exceeds `maxAgeDays`. Store only public limits and source URLs.
4. Refuse to continue if the build, package, requirements, or specification is changing.

## Prepare the source package

1. Derive `metadata/`, localized English and Japanese copy, `privacy/data-use.yml`, review notes, and release notes from observable app behavior and confirmed specifications. Do not invent marketing, privacy, account-deletion, or legal claims.
2. Draft privacy policy and terms from the same facts. For a first publication, stop until the user confirms both legal documents and an approval receipt is available. Mark their exact `Status: Confirmed`; an AI or release auditor cannot supply this approval.
3. Capture an independent release matrix with `tools/capture-appstore-screenshots.sh` and `App Store/screenshots/states.json`. Do not reuse the ordinary verification matrix when Apple requires another display family such as Pro Max.
4. Have the visual evaluator inspect every raw image for safe area, clipping, truthfulness, ordering, and English/Japanese parity. Then obtain `release-auditor` approval for the exact source SHA, build digest, package digest, privacy/legal declarations, and screenshots.
5. Assemble final screenshots with `tools/build-appstore-screenshot-set.sh`. Never stretch or silently transform them.
6. Validate the complete package with `tools/validate-appstore-package.sh --require-fresh`.

## Seal the exact candidate

Run the skill script only after the audit and, when applicable, user legal approval match the current package digest:

```sh
.agents/skills/prepare-appstore-assets/scripts/seal-package.sh \
  --repo "$PWD" --package-root "$PWD/App Store" \
  --requirements "$PWD/App Store/submission/requirements.json" \
  --bundle-id "$BUNDLE_ID" --version "$VERSION" \
  --source-sha "$HEAD_SHA" --build-digest "$BUILD_DIGEST" \
  --verification-issue "$VERIFICATION_ISSUE" --verification-base "$VERIFICATION_BASE" \
  --audit "$RELEASE_AUDIT" --first-publication "$FIRST_PUBLICATION" \
  --legal-approval "$LEGAL_APPROVAL_OR_NONE" \
  --output "$PWD/App Store/submission/$VERSION-package.json" --now "$UTC_NOW"
```

The schema-2 output binds the full verification reference/digest and is the immutable handoff to `submit-appstore-release`. Any source, build, metadata, legal, privacy, screenshot, requirements, or audit change requires a new preparation and review. Do not store credentials, personal content, Apple session data, or secret values in the package or approval evidence.
