# App Store submission contract

This contract separates offline drafts, selective metadata saves, release readiness and authenticated submission. A prepared package does not authorize submission. The selective-save procedure is a specification for a future entrypoint, not an available remote-write capability.

## Source inventory and registration preparation

This section implements the documentation requirements of #53 and [architecture §9.1](../../specs/architecture.md#91-原稿の正本と登録準備). It is a preparation procedure, not a new executable registration or partial-save mode. All current remote-write scripts retain their authority, immutable release-package and ordered submission gates. Source-readiness schema/validation and read-only registration preflight are tracked separately in [#62](https://github.com/yuto1201/iOS-Template/issues/62); #52 specifies the separate future save route below. Any future registration mutation needs its own explicit implementation/operation contract and approvals; neither Issue authorizes it.

### Field inventory and source-to-ASC map

Maintain one row per field and locale, not one blanket “metadata complete” checkbox. Classification: **derive** from confirmed specification and actual app/build; **public** verify the approved public page; **account** observe the authorized remote account; **user** obtain the acceptance-affecting choice/approval. More than one class may apply.

| Field | Authoritative local source / confirmation | ASC destination | Class |
| --- | --- | --- | --- |
| Internal display name, module, slug | `Config/app-identity.json`, confirmed app specification, Xcode settings | Identity cross-check, not automatic store-name input | derive |
| Localized store name, subtitle | `App Store/metadata/localizations/{en-US,ja}.yml`; approved naming decision | New App name; App Information localization | derive + user |
| Description, keywords, promotional text | Same localization files; implemented feature/spec anchors | Version localization | derive |
| Bundle ID | Identity record + all app target configurations; `Config/ownership.yml`; `metadata/app.yml.bundleId` must agree | Registered Bundle ID / App Information | derive + account |
| Platform/device support | Actual targets and supported platforms; `metadata/app.yml.platforms` describes iPhone/iPad support | New App platform selection (iPhone/iPad both iOS), then platform-specific version | derive |
| Version and build | Release specification, Xcode marketing/build versions, distribution artifact digest; `metadata/app.yml.version` | Version and build selection | derive + account |
| Primary language and supported locales | Confirmed store-language decision; `metadata/app.yml.primaryLocale`; localization inventory | New App primary language; localized product pages | user + derive |
| SKU | Approved stable internal identifier in reviewed draft; existing remote value on resume | New App SKU | user + account |
| Categories, copyright | `metadata/app.yml.category` / `copyright`; secondary category if needed in reviewed draft | App Information / version information | derive + user |
| Support, privacy, marketing and other required public URLs | Existing app.yml URL fields; remaining URLs in reviewed draft; exact user-designated app pages | Version Support/Marketing URL; localized Privacy Policy URL | public + user |
| Review notes, contact and demo access | `App Store/review/` non-secret instructions/notes; `metadata/app.yml.reviewContactReference`, Keychain-only actual contact/credentials | App Review Information, including Notes (version-specific; do not invent a localized remote field) | derive + user + account |
| Privacy, tracking, permissions, account deletion | `App Store/privacy/data-use.yml`, actual feature/dependency inventory, SDK configuration and privacy manifests | App Privacy declarations; related review information | derive + user |
| Age rating, content rights and export/compliance answers | App behavior and reviewed-draft questionnaire with explicit unanswered fields | App Information questionnaires / build compliance | derive + user |
| Legal documents / EULA choice | `App Store/legal/`, approved data-use facts and public-page comparison | Privacy policy link / applicable license agreement | user + public |
| IAP product ID/type, pricing, territories, restore, offer-code applicability | Confirmed monetization specification + StoreKit implementation/test evidence; observed production product configuration | In-App Purchases / Pricing and Availability / offers | derive + user + account |
| Team ID, App Apple ID, Bundle registration and access | Approved `Config/ownership.yml`, exact live account; sanitized references in reviewed draft | Selected Team; existing App identity; New App User Access | account + user |
| Release notes and screenshots | `App Store/release-notes/`, adopted screenshot manifests only | What's New / App Previews and Screenshots | derive |

Paths within the table's `metadata/`, `privacy/`, `review/` and `legal/` refer to `App Store/`. Current exact-key YAML schemas do not support every field above: do not add SKU, secondary category, app Apple ID, confirmation states or questionnaire answers as arbitrary YAML keys. Use the app's human-readable `App Store/metadata/reviewed-draft.md` for those preparation rows until the dependent schema work is implemented. The current validator also fixes `primaryLocale` to `en-US`; a confirmed different primary language is a reported implementation gap, not permission to silently substitute English or loosen validation.

Apple distinguishes the localized store name from Bundle ID, SKU and generated Apple ID. SKU is an internal identifier that cannot be changed after record creation; Bundle ID has an upload-related edit boundary. Verify field editability against the actual app status immediately before an operation, rather than assuming that all fields become immutable together. [Apple app-information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information) (checked 2026-09-09).

### Reviewed draft and confirmation provenance

For each row, retain field ID, locale/section, proposed non-secret value (or a secret reference), source path/spec anchor, source revision and exact digest, classification, state, reviewer/approval reference, unresolved reason and affected downstream sections. Source examples in an Issue or a temporary artifact are observations, not the app's current truth.

1. Compare temporary copy to the actual app and confirmed specifications, remove unsupported claims and sensitive values, then promote only the reviewed text into its existing `App Store/` source file or the reviewed-draft ledger. Preserve existing user copy; a conflict requires an explicit resolution, not overwrite.
2. `draft` means reviewed wording still lacks at least one required fact or approval. `confirmed` means every required source, public-page check, account observation and user choice for that row is present and tied to its revision. An AI wording review does not approve legal text, pricing or account access.
3. `remote-saved` additionally requires an authorized save and fresh readback matching the same source digest and exact Team/App/Bundle/locale/section. Record only sanitized remote reference, time and readback digest, not contact data, session material or credentials. This ledger does not replace the existing sealed submission journal or authorize partial remote input.
4. On changes to copy, identity, functionality, SDK/version/configuration, permissions, public text or user choice, invalidate the affected row's confirmation and dependent release audit. Preserve the old observation as history; never relabel a stale remote save as matching the new source.
5. Leave unknown fields explicitly unresolved and prepare independent rows. If one remote form requires multiple fields atomically, any unresolved required field stops that form's save. A partial ledger never makes the whole package ready.

Bootstrap deterministically converts only the paths in `Config/template-identity.json`; it does not currently transform `App Store/metadata/`. Identity values can be proposed from its verified result, but App Store copy and remote registration require separate verification. Reject residual template Bundle IDs against the actual app identity, template names/descriptions/copyright, placeholder/invalid URLs and unsubstantiated no-data declarations. Re-audit SDK behavior and configuration after every dependency or feature change; the existing limited keyword scanner is not comprehensive privacy proof (in particular, do not infer AdMob/UMP absence from its result).

### Team setup and registration preflight

When `Config/ownership.yml.appStore.teamId` is unset, no authenticated agent operation is allowed. Ask the user to inspect their intended personal Apple Developer membership and supply/confirm its exact Team ID, not a display-name guess, email-derived value or Xcode's selected “Personal Team.” Apple exposes the identifier in Membership details. Record only the approved non-secret identifier and app Bundle ID through the app repository's configuration Issue; do not persist membership screenshots/contact details. Then rerun live account-bound preflight and stop if the active membership differs. [Apple Team ID guidance](https://developer.apple.com/help/glossary/team-id/).

For an authorized future registration operation:

1. Resolve the exact configured Team, role, app Bundle ID, platform, localized name, primary language, SKU and explicitly approved user-access selection. Compare local identity, targets and store draft. An unrelated working account is not a fallback.
2. Inspect registered Bundle IDs and existing apps in that Team. Match by stable Team and Bundle identity, not name alone. If the exact app exists, read back its Apple ID, platforms and relevant registration fields and resume it; conflicting or multiple candidates stop for resolution. A name match with another Bundle is not the same app.
3. Distinguish Bundle-not-registered from App-not-created. Registering a Bundle does not create an ASC App record. Neither `appstore.inspect_app` nor `appstore.update_metadata` authorizes these creation operations. Their explicit allowlisted operation IDs, target scope, executor, required approvals, provider checks and idempotent recovery must be implemented in the dependent Issue before any automation may execute them. Existing release operations are unchanged.
4. If a new App is actually absent, create only after the complete required input set and permission/agreement checks pass. Apple lists platform, name, primary language, Bundle ID, SKU and user access, and requires an eligible role and current agreement. A visible agreement notice alone is not evidence that every independent field/operation failed: record the actual blocked operation and response. Agreement acceptance belongs to the user/Account Holder, never the agent. [Apple new-app procedure](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/) (checked 2026-09-09).
5. On name collision, stop the name-dependent creation, retain Bundle registration evidence and ask for an approved alternate localized store name. Do not change internal display name, invent a random suffix, remove another app, alter its name or make a trademark claim automatically.
6. After success or an ambiguous response, re-read the same Team/Bundle's app inventory before retrying. If one matching record exists, retain its stable reference and verify fields; if observation is incomplete or ambiguous, stop. A timeout is not evidence of absence and must not trigger another creation.

Initial Team configuration is not service enrollment or contract consent. Legal/privacy statements, prices and changes to user access remain explicit user decisions. For a non-consumable ad-removal purchase, verify production product ID/type, approved storefront price/territory, availability, restore behavior and current offer-code eligibility separately. A local StoreKit configuration, price string or passing restore test does not prove the product exists or is usable in production; “not applicable” needs a confirmed feature/eligibility reason.

### Readiness report and required fixtures

A report identifies app/source revision and checked-at time, then lists each cause, affected field/operation, evidence/reference, current state, unblock condition and which independent preparation can continue. Example rows below are synthetic, not live account or app observations:

| Cause / synthetic input | Affected fields and effect | Unblock condition / independent work |
| --- | --- | --- |
| Identity says `com.example.sample`, metadata retains template Bundle | Bundle and every remote operation blocked | Reconcile canonical source with verified identity; prepare non-identity draft copy |
| Template name/description or `Draft` copyright survives | Relevant localized/product fields remain draft | Replace with reviewed app facts and approved rights statement |
| URL is `.invalid`, not public, requires login, or points to catalog top | Corresponding support/privacy/legal URL blocked | User-designated exact page, public reachability and matching approved text; other drafts continue |
| Added AdMob/UMP or changed SDK/configuration with old `collectsData:false` / empty SDK inventory | Privacy/legal claims and dependent release readiness invalidated | Re-audit actual data use, tracking, consent and SDK manifests; do not mechanically set collectsData true or trust a keyword-only scan |
| Age-rating questionnaire has unanswered content questions | Age rating remains draft; submission blocked | Answer from actual functionality with required user decisions; metadata copy may continue |
| Ad-removal code works locally but production IAP is absent or unobserved | IAP, price/availability and release readiness unconfirmed | Authorized production readback, user-approved price, restore evidence and offer-code applicability check |
| Team unset or observed Team differs | All authenticated app operations blocked | Approved exact personal Team setup, then matching live preflight; offline drafts continue |
| Bundle absent, or Bundle exists but App absent | Distinct registration prerequisites, not “ready” | Separate authorized creation routes after their implementation; never claim both from one success |
| Name collision / missing role / agreement required | Name-dependent creation / affected authorized operation blocked | User naming decision / correct existing permission / user contract action respectively; no privilege change or agreement acceptance by agent |
| Save/create response lost | Remote state unknown; retry blocked | Fresh exact-identity inventory/field readback; reuse the one matching record, never duplicate |
| Confirmed source digest or SDK inventory changes | Affected confirmed/remote-saved rows stale | Reconfirm new source and reread remote values; retain old history |
| Screenshots explicitly deferred | Text preparation may continue; complete release package blocked | Separate screenshot scope and user direction; do not start capture from this preparation procedure |

The implementation Issue must turn these into synthetic positive/negative fixtures: a fully confirmed non-secret app inventory succeeds; each invalid variant reports its exact cause and affected fields, does not write remotely, preserves user sources and keeps independent preparation available. Include matching-existing-app resume, duplicate/conflicting identities, source-digest invalidation, redaction of contact/credentials, and immutable old package/result compatibility. Test the real public entrypoint, not only wording or a test-only path. A fixture specification here is not a claim that these checks already run.

Do not toggle the current `submission/checklist.yml` booleans merely because draft rows are filled. Full package validation, privacy audit, first-publication legal approval, screenshots and release-auditor approval retain their existing meanings. Preserve AppLibrary's unresolved public routing below. No screenshot generation, Apple account inspection/mutation, product registration or legal publication is part of #53.

## Operation modes and selective metadata save

Reuse the inventory above; do not create a second field schema. Select the narrowest mode that matches the requested outcome:

| Mode | Required input | Output | Forbidden in this mode |
| --- | --- | --- | --- |
| `draft` | App facts/specifications, existing `App Store/` sources, requested fields/locales and unresolved reasons | Reviewed source rows and a proposed diff; unknowns stay draft | Authenticated inspection without its own authority; any remote write, capture/upload, package seal or submission |
| `save` (future entrypoint) | Confirmed selected rows, fixed source digests, current requirements, exact authorized Team/App/Bundle/platform/version, field/locale scope, remote baseline and known publication effect | Per-field/per-locale verified readbacks or explicit failed/unknown/blocked/deferred results in a separate journal | Unconfirmed or unrelated fields, unknown-to-empty overwrites, registration, screenshots/capture/upload, build upload/selection, pricing, agreements, automatic legal approval, review submission or release |
| `ready` | Complete candidate sources, distribution build, all required images/declarations/legal approval, full app verification and release audit | Existing immutable schema-2 `${VERSION}-package.json`, produced by `prepare-appstore-assets` | Remote writes or submission; calling a partial save record a complete package |
| `submit` | Exact ready package plus Issue-bound operations/executor and explicit permission to submit that candidate | Existing ordered `${VERSION}-result.json` with fresh remote readback; `submitted` only after the final action | Unsealed values, drift, unapproved declarations/legal claims, unauthorized publication or claiming Apple approval |

`save` can precede `ready`; it never replaces it. Missing screenshots, build or unapproved privacy/legal rows defer those rows and full release readiness, not an independent confirmed general description. The actual remote form may still require coupled fields: if those cannot be supplied safely, defer that entire form while continuing other independent drafts/forms. General copy that makes a privacy, legal, price or unsupported feature claim is not exempt merely because it is in Description.

The existing `submit-appstore-release` skill routes requests to this contract, offline preparation or its complete release workflow. Its scripts do **not** implement selective save. Until the [dedicated implementation](../../specs/architecture.md#92-原稿保存と正式提出の分離) is merged, return the draft/diff and the missing implementation dependency; do not invent a `--draft` flag, feed incomplete inputs to `record-section.sh`, or bypass it with manual authenticated browser input. #52 itself performs no Apple operation.

### Selective-save preconditions and transaction

For the future entrypoint, each save attempt must meet all of the following; no whole-package prerequisite is silently weakened in the existing release entrypoint:

1. Read the live and sealed Issue scope, exact executor, `appstore.inspect_app` and `appstore.update_metadata` declarations, required user approvals and configured ownership. Confirm the active Team, exact existing App Apple ID/Bundle, platform/version and current app/version status with fresh provider evidence. Missing/mismatched identity, role or authentication blocks all authenticated work. A build may be absent for metadata-only save; record that absence, never fabricate a build or select one. If the current provider cannot represent this mode safely, implement its bounded contract first rather than bypassing preflight.
2. Freeze the selected source files' exact SHA-256 and revision, field/locale mapping, confirmation references and intended non-secret values. Use the existing app-information versus version-information inventory. Name/subtitle and categories may affect the app more broadly than one version; review Notes are not necessarily localized. Match actual remote fields, not the local file organization. Unknown/missing is different from an explicitly authorized empty value or deletion.
3. Refresh Apple's field requirements, editability and actual save effect for this app status. A button named Save does not prove private staging: some metadata changes affect a public page without a new version. Defer public-impact fields unless that exact impact is explicitly authorized with all applicable approvals; unknown effect always stops the field/form. Never change release settings, accept agreements or create an App/version to make a form editable. [Apple editing procedure](https://developer.apple.com/help/app-store-connect/create-an-app-record/view-and-edit-app-information/) and [version properties](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/) (checked 2026-09-09).
4. Read the complete remote form that will be saved, including coupled fields and pending edits, and compare it to the fixed intended patch. Confirm required fields and keep unselected values unchanged. If any required value is unconfirmed, an unrelated pending change would be committed, the baseline drifts, or the adapter cannot isolate the authorized patch, stop that form and record the cause. Never discard another person's pending edits or overwrite them with an old local copy.
5. Record the sanitized intent/baseline before dispatch, recheck identity/source/baseline immediately before the mutation, then save only that patch. Use conditional version/etag protection when available; otherwise detect conflicts through pre/post readback and report the limitation rather than claiming an atomic compare-and-set. A failed or ambiguous response remains failed/unknown until a fresh same-identity readback resolves it; do not blindly retry.
6. Read all saved and preserved fields back from the same remote form. Compare selected fields to intended values and unselected fields to the baseline. Only exact agreement, including the source digest and locale/section, supports `remote-saved`. Report each locale separately. A conflicting readback is not success; do not auto-restore values. No capture/upload step may be called because images are deferred.

Use only confirmed general text for early saves. Unapproved privacy/legal declarations, questionnaire answers, URLs with unresolved public destinations, review contact/credentials, prices and access decisions remain outside the patch. Existing approved independent data on a coupled form may be preserved, but cannot be silently reconfirmed or modified. Missing independent information does not authorize a false no-data declaration or a placeholder URL.

### Separate save journal and resume

The future versioned format is `recordType: appstore-metadata-save`, `schemaVersion: 1`; it is neither an Issue verification record nor an ASC release result. Store append-only intent/outcome events under the owning app repository's `.artifacts/appstore-metadata/<issue>/<attempt>/`, outside `App Store/` and canonical `.artifacts/issues/` evidence. Each attempt has a unique ID and references its preceding attempt when resuming. Reject existing different bytes, unsafe paths/symlinks and unowned directories; never clean up another attempt or user file. Retain sanitized history for resume; missing history requires a fresh inventory, not invented success. Do not change package hash exclusions or add an active journal inside a sealed package.

Each event binds Issue/contract reference, executor, source revision, selected source relative path/anchor/digest, operation and approval references, requirement URLs/check time, Team/App/Bundle/platform/version, current status/public effect, locale/section/field, full-form baseline digest, intended patch digest, save outcome, remote reference, readback digest, UTC time and blocked/deferred reason. Distinguish `eventType: intent` (null outcome/readback, no completion claim) from `eventType: outcome`; an intent left without an outcome requires remote reconciliation before retry. Use repository-relative source paths that resolve to permitted regular sources; reject escapes. A shared app field still records the selected version as context and its actual app-wide scope. Keep non-secret reviewed values in `App Store/`, not the journal.

Illustrative **non-executable** event below is synthetic; angle-bracket tokens are not valid evidence. Production digests must be exact SHA-256 of observed bytes, never this example:

```yaml
recordType: appstore-metadata-save
schemaVersion: 1
eventType: outcome
issue: 123
attempt: example-02
previousAttempt: example-01
contractReference: <exact issue contract path and digest>
executor: codex
operation: appstore.update_metadata
approvalReference: <scope and any required publication approval>
sourceRevision: <40-hex commit>
requirements: {checkedAt: <UTC time>, sources: [<official field requirements URL>]}
target: {teamId: EXAMPLETEAM, appAppleId: "1234567890", bundleId: com.example.sample, platform: iOS, version: "1.0"}
remoteState: {appStatus: <observed>, versionStatus: <observed>, build: null, publicEffect: <verified effect>}
field: description
section: version-localization
locale: ja
source: {path: App Store/metadata/localizations/ja.yml, anchor: description, digest: <sha256 of exact file>}
confirmationReference: <source-bound confirmation>
baselineDigest: <sha256 of full sanitized form projection>
intendedPatchDigest: <sha256 of selected field patch>
outcome: remote-saved
remoteReference: asc://apps/1234567890/versions/1.0/localizations/ja
readbackDigest: <sha256 of full sanitized form readback>
checkedAt: <UTC time>
reason: null
```

The writer defines a versioned deterministic UTF-8 serialization of field IDs, locales and non-secret values for patch/form digests; it must distinguish absent, null and empty string, preserve exact Unicode content and use the same serializer for baseline/intended/readback comparisons. Do not silently trim, normalize or truncate. Raw credentials, contact details, authenticated transcripts and their value hashes do not enter the projection or logs; when an authorized complete-form comparison needs them, compare transiently in the protected process and retain only a sanitized verification reference. If that cannot be done safely, stop the form.

Outcomes are `remote-saved`, `unchanged-verified`, `failed`, `unknown`, `blocked`, `deferred`, or `stale`. `unchanged-verified` requires current matching readback without a new save. No dispatched mutation/readback means a null corresponding digest, not a made-up hash. For example, a Japanese description may be `remote-saved`, English description `failed` with `remote-validation` reason, screenshots `deferred` with `user-deferred` reason, and privacy `blocked` with `approval-missing` reason. Only the Japanese row is verified; the batch is partial, not ready/submitted. Deferred rows record the affected field/locale and known source/identity references, null unavailable data and an unblock condition.

On resume:

1. Reauthenticate and revalidate the exact configured identity, Issue/executor/operations and approvals. A stored successful preflight is not current authority.
2. Resolve the current source files, revision/digests, confirmation dependencies and official requirements; retain old events. Source or SDK/legal changes mark affected rows stale and require reconfirmation before writing.
3. Read the actual current app/version status, editability, public effect and **every** previously saved form, not merely failed rows. Compare against both the former readback and the current intended source. Local success flags alone never skip a field.
4. If current remote equals current confirmed intent and preserved fields match, append `unchanged-verified`. If remote changed, compute a new authorized diff against that baseline; unresolved conflicts stop for the user's decision rather than restoring old text. Resolve an ambiguous prior save by readback before another attempt; if observation is unavailable, keep it unknown and stop.
5. Process only still-authorized independent patches through the transaction above, append new outcomes and report partial results/deferred causes. Never promote the journal into `${VERSION}-result.json`, flip checklist booleans, or infer release readiness from saved text.

### Selective-save verification plan

Use the same fixtures for English and Japanese where applicable. This table specifies manual/behavioral checks for the future implementation; #52 does not claim an authenticated save test. Use synthetic app data only, including the example request “enter confirmed text; leave screenshots for later.”

| Case | Expected observation and action |
| --- | --- |
| Screenshots deferred, build absent, independent description confirmed | Save only the eligible description after preflight/form checks; images/build remain deferred, no capture/upload/build selection calls, no ready package |
| Japanese save succeeds, English fails validation | Read back each locale; record Japanese only as saved and English failed, preserve source and remote English values; resume by rereading both |
| Another editor changes remote text or a coupled field | Detect baseline/readback drift, recompute the permitted diff or stop for conflict resolution; never overwrite the changed field from old success flags |
| Length at limit and over limit, ASCII/Japanese/combining accents/emoji/newlines | Refresh exact field units and limits; reject excess without truncation, require confirmed corrected copy; test byte and character boundaries separately |
| Placeholder, `.invalid`, login-only or catalog-top support/privacy URL | Defer the URL/form until an approved exact public page matches the source; no placeholder save, while independent valid drafts continue |
| Privacy/legal unapproved, including such a claim inside Description | Do not submit those claims or infer approval from AI review; save only independent confirmed general text, retain the release blocker |
| Authentication expires or Team/App/Bundle/version differs | No mutation; record sanitized auth/identity blocker and rerun live preflight before resume, never switch accounts |
| Save response times out after remote success | Mark unknown, reread same form/identity and resolve exact values before any retry; no duplicate action based on a missing local result |
| App is already live and promotional text has public effect, or effect is unknown | Reject private-draft assumption; known public effect requires explicit scoped permission/approvals, unknown effect stops; no release-setting changes |
| Required field unresolved, pending edit unrelated, unknown value supplied as empty | Refuse the entire coupled form; preserve all existing values and user edits, continue only independent work |
| Source revision/digest changes or a saved row's remote value drifts on resume | Mark stale and recompare/reconfirm affected rows; unchanged source does not prove unchanged remote |
| Partial journal supplied to full-release entrypoint | Reject it; preserve required images/build/declarations/legal/audit/full verification and explicit submission permission, with old package/result compatibility |

Check current [Apple version-field requirements](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/), [app information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/) and [required/localizable/editable properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties/) at each new save batch/resume; record check time and public source references without editing an already sealed requirement snapshot. At the 2026-09-09 check, keywords allow 100 **bytes**, description 4,000 characters and promotional text 170 characters. Do not equate visible glyphs, code points, UTF-16 units and UTF-8 bytes; retain exact source content, check the actual field's documented unit and remote validation, and stop if its counting rule is unresolved. Table extraction that loses checkmarks is not evidence of editability. A bundled validator or a previously cached limit is not current Apple authority. Turn these cases into real-entrypoint fake-adapter tests in the implementation Issue, including no-write assertions, journal redaction/path ownership and immutable release regressions.

## Authority and entry conditions

The following sections govern the existing complete release workflow, not the future selective-save entrypoint. Before any final submission require an explicit, still-current authorization for this exact candidate; earlier permission to prepare or save text is insufficient. The separate save journal cannot satisfy these gates.

- Codex and Claude may execute App Store Connect, authenticated browser, upload, signing-account, and provider operations when named as the Issue executor.
- The release Issue must declare each intended production operation, including inspection, section updates, screenshot upload, build selection, and submission for review. No skill invocation broadens Issue authority.
- Immediately before each mutation batch, the selected executor verifies the active configured Team, App, Bundle ID, version, and build against `Config/ownership.yml` and the sealed package. Another identity or ambiguous target is a hard stop.
- `prepare-appstore-assets` must have produced `${VERSION}-package.json` for the exact source SHA and build digest, with current Apple requirements and an approved release-auditor result.
- A first public release additionally requires the user's package-bound confirmation of the privacy policy and terms. AI review cannot grant legal approval.
- Under the [staged-development policy](../../specs/development-stages.md), the English/iPad adaptation Issue must be complete and the release candidate Head must have full Japanese/English × iPhone/iPad verification. Japanese iPhone feature evidence alone does not establish release readiness. Keep the independent App Store screenshot requirements and privacy/legal checks.

## Legal-page publication destination

During submission preparation, follow [the AppLibrary publication policy](../../specs/product.md#61-applibraryでの法務ページ公開方針): the `app.yutodev.com` app catalog links to each app's website, where its privacy policy and terms belong. Vercel manages Web publication; Cloudflare manages the domain and DNS, not Pages hosting. Keep the app's `App Store/` sources as the authority for the published text.

AppLibrary's layout and Vercel migration are still being developed separately. The user will specify the actual placement and public URLs later; never derive them from the catalog domain or assume migration is complete. Independent app development and legal drafts can continue. If publication or submission needs an unresolved destination, mark that Issue `blocked:user` and request it. Before submission, confirm the designated pages are publicly reachable without login and match the approved text, privacy declarations, in-app links, and submission metadata. This policy is neither legal-text approval nor authority to edit/deploy AppLibrary, change DNS, or submit the app.

## Immutable inputs

Schema-2 preparation also binds the canonical full application verification Issue, trusted Base, path and digest. Require the same current Head and Bundle ID, completed English/iPad adaptation, and all four cases. Before external writes in the complete release workflow and on its resume, run `ruby tools/lib/release-verification.rb "$PWD" "$PACKAGE_MANIFEST" "$HEAD_SHA" "$BUNDLE_ID"`; it is read-only and does not grant authority. Old manifests without this proof require resealing. The section recorder rejects stale, partial or changed proof independently.

The prepared manifest binds the Bundle ID, version, source SHA, build digest, package tree digest, requirement cache, screenshot manifest, release audit, and first-publication approval. Recompute them at workflow start and resume. Any mismatch invalidates all unperformed sections; never repair a mismatch by editing the manifest or remote values.

Secrets and App Store session data are not immutable package inputs. Resolve a required review credential from Keychain only into a child process or the exact authenticated form field. Never put secret values in tracked files, browser transcripts, screenshots, logs, evidence, Issue/PR text, or AI prompts.

## Ordered remote transaction

Process `app-information`, `localization`, `privacy`, `screenshots`, `build`, `review-information`, and `submission` in that order. For each section:

1. Recheck personal Team/App/version/build identity and local digests.
2. Enter only sealed values and upload only screenshot-manifest bytes.
3. Save the remote section.
4. Read the resulting remote values back from App Store Connect.
5. Compare them to the sealed source and record only a sanitized remote reference and readback digest.

Do not continue when App Store Connect presents an unexpected agreement, price, legal claim, destructive replacement, paid action, target, or remote value. Treat transport ambiguity as unknown state and read back before retrying; never submit a duplicate action speculatively.

## Result and resume

`App Store/submission/${VERSION}-result.json` is an ordered, sanitized journal. Each entry contains the section ID, `verified` status, an `asc://` remote reference, SHA-256 readback digest, `app-store-connect` source, and verification time. It contains no field values or credentials.

On resume, the selected executor must authenticate again, rerun preflight, recompute all immutable inputs, and read back every recorded remote section. `scripts/record-section.sh --resume-readback yes` is valid only after that comparison. Local status alone is not evidence of remote completion.

The final journal status `submitted` means only that the exact candidate was submitted for review and read back. It does not mean Apple approved or released the app. App Review and release status are later observations and must be reported separately.
