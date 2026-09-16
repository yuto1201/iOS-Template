---
name: prepare-appstore-assets
description: Prepare, validate, review, and immutably seal localized App Store metadata, privacy and legal text, review notes, release notes, and release screenshots. Use when an iOS release candidate needs App Store Connect assets, when an existing submission package changed, or before the submit-appstore-release workflow.
---

# Prepare App Store Assets

Build the package from the confirmed product specification and exact release candidate. This skill proves readiness; it does not open or mutate App Store Connect.

## Source preparation before a release candidate

For inventory, draft promotion or a new App record's prerequisites, first follow the [source inventory and registration preparation](../../../docs/agent-contracts/appstore-submission.md#source-inventory-and-registration-preparation), including its field-level readiness report. Keep draft/confirmed/remote-saved distinct; report missing Team, naming/SKU choices, production IAP, age-rating answers, public URLs and SDK/privacy re-audit needs. The current package validator is not proof that every new preparation requirement is automated. Do not add unsupported schema keys, invoke registration operations or mark the release checklist complete from a partial draft.

Independent text preparation can continue before complete release inputs exist. If screenshots are explicitly deferred or their scope remains for the user to decide, stop before capture; do not execute the screenshot steps below or seal a complete package. Continue the complete preparation sequence only when its prerequisites and screenshot scope are established. This does not waive any release gate or authorize partial remote saves.

## Legal-page handoff

When confirmed support, privacy, or terms sources need public AppLibrary pages, follow the [legal-page handoff contract](templates/legal-page-handoff.md) and `tools/prepare-appstore-legal-handoff.sh`. Generate a copy-ready Issue for exactly `yuto1201/Web-AppLibrary`, perform duplicate search and authenticated creation/readback only under the source Issue's declared GitHub operation, then leave prompt forwarding and legal/publication approval to the user. This workflow does not edit or deploy the Web repository.

Before URL fields or release readiness may consume the result, require a live `publication-verification.json` whose exact source/route digests, Web Issue, user actions, HTTP 200 responses, approved text, locale, and interlinks were verified. A `fixture-validated` result is not App Store evidence and is not App Store eligible.

## Preconditions

1. Read the release Issue, confirmed `specs/` documents, `App Store/README.md`, `docs/AUTHORITY.md`, and `docs/agent-contracts/release-auditor.md`.
2. For a phase-aware publication Issue, require an exact Phase 6 `Release-phase binding:` and its committed record. Validate `.artifacts/issues/<issue>/<head>/evidence-applicability.json`: reuse only the exact Phase 5 candidate/context, and require the recorded target re-verification for `targeted-reverify` or `expanded-verification`. A sealed Issue without a binding remains `legacy-unbound`; do not synthesize or retrofit a record.
3. Require exact source Head, trusted verification Base and Issue, canonical passed full application verify.json for that Head and Bundle ID, the separate distribution-build digest, version, and first-publication status. English/iPad adaptation must be complete. Japanese iPhone-only evidence never satisfies release readiness.
4. Use the selected Codex or Claude executor to refresh `App Store/submission/requirements.json` from official Apple documentation when its `retrievedAt` exceeds `maxAgeDays`. Store only public limits and source URLs.
5. Refuse to continue if the build, package, requirements, or specification is changing.

## Phase 6 screenshot routing

Use [`goldie`](../goldie/SKILL.md) as the standard Phase 6 presentation workflow for iPhone 6.9-inch App Store images. Keep `goldie/ja/` and `goldie/en-US/` as separate configs, raw inputs, flows, and disposable outputs. Existing real screenshots that need only headline, background, frame, font, layout, or order changes are imported and rendered without recapture.

For new raw capture, acquire one inherited session through `tools/with-ios-simulator-lock.sh`; all device creation must flow through `tools/lib/ios-simulator-resource.rb`. Prefer the repository-owned capture tool and import its iPhone raw images into Goldie because Goldie 0.3.1 cannot select an exact UDID. If direct Goldie capture is explicitly requested, use it only when the device its installed selector will choose is the exact active allocation owned by this session; otherwise fall back to owned capture plus import. Save screenshots and diagnostics outside the device, then require the released allocation receipt before continuing.

Goldie does not support iPad. Route iPad capture through `tools/capture-appstore-screenshots.sh`; never stretch an iPhone export. The repository capture is invoked under the shared lock and captures all required locale/family conditions sequentially:

```sh
tools/with-ios-simulator-lock.sh --timeout 0 -- \
  tools/capture-appstore-screenshots.sh \
    --requirements "$REQUIREMENTS" --states "App Store/screenshots/states.json" \
    --app-path "$APP_PATH" --bundle-id "$BUNDLE_ID" --source-sha "$HEAD_SHA" \
    --build-digest "$BUILD_DIGEST" --runtime "$RUNTIME_ID" --output-root "$RAW_ROOT" \
    --issue "$ISSUE" --batch-id "$BATCH_ID"
```

The Mac-wide cap remains four iPhone/iPad allocations total and one allocation per session. Four conditions are create/capture/save/delete sequences, not a four-device pool. Failure, timeout, or interruption must release the exact owned allocation; a cleanup failure is reported and remains blocked for durable recovery. Do not erase, reuse, or delete user/other-owner devices.

## Prepare the source package

1. Derive `metadata/`, localized English and Japanese copy, `privacy/data-use.yml`, review notes, and release notes from observable app behavior and confirmed specifications. Do not invent marketing, privacy, account-deletion, or legal claims.
2. Draft privacy policy, terms, and support text from the same facts. For a first publication, stop until the user confirms the legal documents and an approval receipt is available. Mark their exact `Status: Confirmed`; an AI or release auditor cannot supply this approval. If public pages are required, complete the legal-page handoff above and bind the live verification record before treating their URLs as ready.
3. Follow the Phase 6 screenshot routing above. Use Goldie for reviewed iPhone presentation and the repository capture path for iPad; do not reuse the ordinary verification matrix when Apple requires another display family such as Pro Max. Preserve exact source/build provenance across imported and rendered images.
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
