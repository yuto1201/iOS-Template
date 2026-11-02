---
name: prepare-appstore-assets
description: Check App Store source readiness and registration prerequisites without mutation, or prepare and seal complete release assets when a verified candidate and screenshot scope exist. Use for store drafts, changed submission assets, or before submit-appstore-release.
---

# Prepare App Store Assets

Prepare from confirmed product facts. Source preparation and full release-package readiness are distinct modes; neither opens or mutates App Store Connect.

## Source preparation before a release candidate

For inventory, draft promotion or a new App record's prerequisites, first follow the [source inventory and registration preparation](../../../docs/agent-contracts/appstore-submission.md#source-inventory-and-registration-preparation), including its field-level readiness report. Keep draft/confirmed/remote-saved distinct; report missing Team, naming/SKU choices, production IAP, age-rating answers, public URLs and SDK/privacy re-audit needs. In a derived app that activated AdMob, the checker also reconciles `Config/admob-activation.json` with `App Store/privacy/data-use.yml`: data collection, the recorded tracking value and data-use categories, and whether the answers changed after the recorded privacy review. Matching answers remove only those reasons; they are not privacy proof, a live Google check or release readiness. The current package validator is not proof that every new preparation requirement is automated. Do not add unsupported schema keys, invoke registration operations or mark the release checklist complete from a partial draft.

Read the [preparation format](<../../../App Store/metadata/preparation-format.md>) for versioned sources, reviewed-draft migration and required evidence. Preserve old ledger wording and user files; migration never converts a `confirmed` label into approval. Run the read-only checker from the app checkout:

```sh
tools/prepare-appstore-sources.sh --project-root "$PWD"
```

Exit 0 means the modeled source inventory is `prepared`, not release-ready or authorized to save; exit 1 retains per-field blocked/deferred progress, and exit 2 rejects unsafe or changing input. Report supplied or synthetic observations honestly: this command does not inspect Apple or public pages live. Obtain new external observations only through separately authorized operations; never invent proof files, user approvals, complete questionnaires or a matching account.

Use `dispositions` only for explicit user decisions; do not infer optionality from missing values. Localized URLs and names require their exact locale's confirmation. Non-English primary-language support remains blocked by the existing package-validator limitation. For supplied records involving private coupled fields, the format's explicit transient-pipe interface compares preserved values without file or hash persistence; absent authorized transient input blocks that row. It is not a credential reader or a private-field update route.

Independent text preparation can continue before complete release inputs exist. If screenshots are explicitly deferred or their scope remains for the user to decide, stop before capture; do not execute the screenshot steps below or seal a complete package. Continue the complete preparation sequence only when its prerequisites and screenshot scope are established. This does not waive any release gate or authorize partial remote saves.

## Draft the store copy (ASO)

Write the name, subtitle, keywords, promotional text, description and release notes (What's New) by the [ASO guide](../../../docs/store-copy-aso.md), from the same confirmed facts. The guide adds no exception to step 1 of [Prepare the source package](#prepare-the-source-package): never invent features, rankings, awards or ratings to rank better.

1. Draft two or three candidate sets for each locale (`ja` and `en-US`) that differ in the target terms they put in the name, subtitle and keyword field. Keep them outside the canonical sources, as `.artifacts/appstore-draft/<candidate>/localizations/<locale>.yml` with the keys of `App Store/metadata/localizations/`, and the release notes beside them.
2. Run the read-only checker on every candidate:

   ```sh
   tools/check-store-copy.sh --project-root "$PWD" \
     --localizations .artifacts/appstore-draft/<candidate>/localizations
   ```

   Fix every `error`; keep a `warning` only with a written reason. The checker reports the keyword length in bytes and characters and stops on bytes unless the app's `App Store/metadata/aso.json` sets `keywordLimit` to `characters`; list competitors and trademarks there. It never writes or opens the network. A passing check is not approval, release readiness or an App Review prediction.
3. Show the candidates, their checker results and the checks the guide leaves to the eye (spelling, confusion with existing apps, Japanese terms in the en-US keyword field) to the user, and ask for an explicit choice of one candidate per locale. Do not choose for the user; a vague answer is not a choice.
4. Record the choice in `App Store/metadata/aso-decisions.md` next to the copy, in the guide's format: the candidates, the user's explicit choice and where it was given, the target terms, the avoided terms and why, whether the en-US field carries Japanese terms and why, and every kept warning with its reason. Then write only the chosen text into `App Store/metadata/localizations/` and `App Store/release-notes/`.
5. Drafting never saves to App Store Connect. Saving stays with `save-appstore-metadata` in `submit-appstore-release` `save` mode, under its own approvals and gates; neither the checker nor the record authorizes a save.

## Legal-page handoff

When confirmed support, privacy, or terms sources need public AppLibrary pages, follow the [legal-page handoff contract](templates/legal-page-handoff.md) and `tools/prepare-appstore-legal-handoff.sh`. The pages live at `https://app.yutodev.com/apps/<appSlug>/support/`, `/privacy/`, and `/terms/` (D-072), with `<appSlug>` from `Config/app-identity.json`; each page carries both its Japanese and English text, so there is one URL per page, not per language. Generate a copy-ready Issue for exactly `yuto1201/Web-AppLibrary`, perform duplicate search and authenticated creation/readback only under the source Issue's declared GitHub operation, then leave prompt forwarding and legal/publication approval to the user. This workflow does not edit or deploy the Web repository.

Before URL fields or release readiness may consume the result, require a live `publication-verification.json` whose exact source digests for both languages, D-072 URLs, Web Issue, user actions, HTTP 200 responses, approved Japanese and English text on each page, and interlinks were verified. A `fixture-validated` result is not App Store evidence and is not App Store eligible.

## Preconditions

The following preconditions apply only when continuing from source preparation into a complete release package. They are not prerequisites for the read-only source-readiness command above.

1. Read the release Issue, confirmed `specs/` documents, `App Store/README.md`, `docs/AUTHORITY.md`, and `docs/agent-contracts/release-auditor.md`.
2. For a phase-aware publication Issue, require an exact Phase 6 `Release-phase binding:` and its committed record. Validate `.artifacts/issues/<issue>/<head>/evidence-applicability.json`: reuse only the exact Phase 5 candidate/context, and require the recorded target re-verification for `targeted-reverify` or `expanded-verification`. A sealed Issue without a binding remains `legacy-unbound`; do not synthesize or retrofit a record.
3. Require exact source Head, trusted verification Base and Issue, canonical passed full application verify.json for that Head and Bundle ID, the separate distribution-build digest, version, and first-publication status. English/iPad adaptation must be complete. Japanese iPhone-only evidence never satisfies release readiness.
4. Use the selected Codex or Claude executor to refresh `App Store/submission/requirements.json` from official Apple documentation when its `retrievedAt` exceeds `maxAgeDays`. Store only public limits and source URLs.
5. Refuse to continue if the build, package, requirements, or specification is changing.

## Phase 6 screenshot routing

Use [`appstore-creative`](../appstore-creative/SKILL.md) (Goldie-based, D-077) as the standard Phase 6 presentation workflow for iPhone 6.3-inch (family `iphone-6.3`, 1206×2622, D-079) and iPad 13-inch App Store images; iPad tiles are rendered through its render extension (`tools/appstore-creative-render.sh render --config <iPad config> --device ipad-13 --locale <locale>`). Keep `goldie/ja/` and `goldie/en-US/` as separate configs, raw inputs, flows, and disposable outputs. Existing real screenshots that need only headline, background, frame, font, layout, or order changes are imported and rendered without recapture.

For new raw capture, acquire one inherited session through `tools/with-ios-simulator-lock.sh` and run the repository capture tool. It leases only the dedicated iPhone and iPad Simulators declared in `Config/dedicated-simulators.json` through `tools/lib/ios-simulator-resource.rb` and never creates, clones, renames, or deletes a device. Since D-079 the dedicated iPhone 17 Pro captures the required iPhone with Dynamic Island (medium display) size, 1206×2622 (family `iphone-6.3`), and the dedicated iPad Pro 13-inch (M5) captures iPad 13-inch, so captures are used at their native size without cropping or compositing. Import the iPhone raw images into Goldie. Do not run Goldie's own `capture`: Goldie 0.3.1 selects a device by name and cannot reach a dedicated Simulator. Save screenshots and diagnostics outside the device, then require the released lease receipts before continuing.

Goldie 0.3.1 has no iPad device, so iPad tiles come from iPad captures through the render extension. Route iPad capture through `tools/capture-appstore-screenshots.sh`; never stretch an iPhone export. The repository capture is invoked under the shared lock and captures all required locale/family conditions sequentially:

```sh
tools/with-ios-simulator-lock.sh --timeout 0 -- \
  tools/capture-appstore-screenshots.sh \
    --requirements "$REQUIREMENTS" --states "App Store/screenshots/states.json" \
    --app-path "$APP_PATH" --bundle-id "$BUNDLE_ID" --source-sha "$HEAD_SHA" \
    --build-digest "$BUILD_DIGEST" --runtime "$RUNTIME_ID" --output-root "$RAW_ROOT" \
    --issue "$ISSUE" --batch-id "$BATCH_ID"
```

Each locale/family condition leases its platform's dedicated Simulator, which is erased before the lease and shut down on release, and the conditions run one after another. The tool records the Apple model name of each display family and the actual image size, and refuses a dedicated device or Runtime that does not match the requirements before any Simulator changes. Failure, timeout, or interruption must release the exact lease; a cleanup failure is reported and remains blocked for durable recovery. Never boot, erase, install into, or delete a user or other-owner device.

## Prepare the source package

1. Derive `metadata/`, localized English and Japanese copy, `privacy/data-use.yml`, review notes, and release notes from observable app behavior and confirmed specifications. Do not invent marketing, privacy, account-deletion, or legal claims. Draft and choose the store copy as in [Draft the store copy (ASO)](#draft-the-store-copy-aso).
2. Draft privacy policy, terms, and support text from the same facts. For a first publication, stop until the user confirms the legal documents and an approval receipt is available. Mark their exact `Status: Confirmed`; an AI or release auditor cannot supply this approval. If public pages are required, complete the legal-page handoff above and bind the live verification record before treating their URLs as ready.
3. Follow the Phase 6 screenshot routing above. Use `appstore-creative` for reviewed iPhone and iPad presentation, with every raw capture taken through the repository capture path. Preserve exact source/build provenance across imported and rendered images. When the adopted faces are drawn by the D-093 renderer (`tools/appstore-creative-compose.sh compose`), bind them with `finalize` (D-101) before review; see [Composed screenshot sets](#composed-screenshot-sets-d-101).
4. Audit every App Store Review Guideline for this exact version and build in `App Store/review/guidelines-audit.json`, following the pre-submission audit of [`app-review-guidelines`](../app-review-guidelines/SKILL.md) (D-081). Recheck Apple's page date first, get the user's Issue-comment confirmation for every `user-judgment` guideline, and require `tools/check-review-guidelines.sh --project-root "$PWD" --bundle-id "$BUNDLE_ID" --version "$VERSION" --build "$BUILD"` to pass before the release-auditor review. A failing or stale audit stops preparation; never seal around it.
5. Have the visual evaluator inspect every raw image for safe area, clipping, truthfulness, ordering, and English/Japanese parity. For a composed set, also inspect every composed face for safe area, text clipping and English/Japanese parity, and check that it shows its raw capture unedited (guidelines 2.3.3 and 2.3.9); each `review.json` case then carries both the composed face's `digest` and its raw capture's `rawDigest`. Then obtain `release-auditor` approval for the exact source SHA, build digest, package digest, privacy/legal declarations, screenshots, and the passing guideline audit.
6. Assemble final screenshots with `tools/build-appstore-screenshot-set.sh`. Never stretch or silently transform them. A raw-capture set takes the raw root as it always has; a composed set adds `--composition FILE --composed-root DIR` from `finalize`.
7. Validate the complete package with `tools/validate-appstore-package.sh --require-fresh`.

## Composed screenshot sets (D-101)

A set drawn by the D-093 renderer is sealed through the same package, audit and seal as raw captures, bound to the capture that each face shows:

1. Render every locale and family with `tools/appstore-creative-compose.sh compose` from the raw captures of one capture batch, and record the user's choice on the proposal sheet with `tools/appstore-creative-sheet.sh select`.
2. Bind the adopted faces. `finalize` refuses a face without a raw capture of its locale and family, a capture shown twice, a material that `goldie/assets/provenance.json` does not record as adopted, and any declaration, face or capture whose bytes changed after rendering:

   ```sh
   tools/appstore-creative-compose.sh finalize --raw-root "$RAW_ROOT" \
     --render-records "$JA_IPHONE_RECORD,$EN_IPHONE_RECORD,$JA_IPAD_RECORD,$EN_IPAD_RECORD" \
     --selection .artifacts/store-creative/<revision>/selection.json \
     --provenance goldie/assets/provenance.json --approval "$ISSUE_COMMENT_URL" \
     --capture-batch "$BATCH_ID" --out "$COMPOSED_ROOT"
   ```

   `$COMPOSED_ROOT` receives `<locale>/<family>/NN-<state>.png`, byte copies of the render records and provenance under `records/`, and `composition.json` (schemaVersion 1): the raw manifest's SHA-256, the capture batch, source SHA, build digest, runtime and requirements digest, the renderer's SHA-256, the adoption (proposal sheet and selection SHA-256, concept ID, `user-explicit`, approval reference, recorded time, provenance SHA-256), and for each face its locale, family, state, order, path, raw path and SHA-256, declaration, render record and material SHA-256, size and SHA-256. It holds no absolute path. Keep `$COMPOSED_ROOT` with the other working output outside Git: its record copies name local paths, and only the assembled set enters `App Store/screenshots/`.
3. Review both the raw captures and the composed faces (step 5) and assemble the set with the composition:

   ```sh
   tools/build-appstore-screenshot-set.sh --raw-root "$RAW_ROOT" --output-root "$OUTPUT_ROOT" \
     --requirements "$REQUIREMENTS" --review "$REVIEW" --source-sha "$HEAD_SHA" --runtime "$RUNTIME_ID" \
     --build-digest "$BUILD_DIGEST" --composition "$COMPOSED_ROOT/composition.json" --composed-root "$COMPOSED_ROOT"
   ```

   The raw manifest keeps every existing check (source SHA, build digest, runtime, requirements digest, device type, naming and digests). Each composed face must match exactly one raw case by locale, family and state with the same raw digest; its render record must name that capture and the declaration digest and use only adopted materials; and it must be a real, non-linked RGB PNG without an alpha channel, at a size the family allows, with the recorded SHA-256. English and Japanese must show the same states in the same order. The output adds `screenshots/composition.json`, `compositionDigest` and each case's `rawDigest` to the manifest; the package digest that the release auditor approves and the seal records covers the composition record, so replacing one face or changing the record makes the seal stale. Without `--composition` the raw-capture route and its output are unchanged.

Moving from an exception `App Store/screenshots/adopted.json` (CafLog A-086, PayCycle A-057): its `capture` block (`batchId`, `sourceSha`, `buildDigest`, `runtime`, `requirementsDigest`) becomes `--capture-batch` and the raw `manifest.json` that `finalize` reads; `decision`, `issue` and `pattern` become the proposal sheet's `selection.json`, `--approval` and `conceptId`; each tile's `raw` and `image` become a case's `rawDigest` and `digest`. Faces drawn by an app's own script (`script`, `scriptSha256`) have no render record: draw them again with `tools/appstore-creative-compose.sh compose` from the same captures, then finalize, review, assemble, validate and seal as above, and close the exception in the app's own Issue.

## Seal the exact candidate

Run the skill script only after the guideline audit check passes for this version and build, and the release audit and, when applicable, user legal approval match the current package digest. The guideline audit file is inside the package tree, so the package digest binds it:

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
