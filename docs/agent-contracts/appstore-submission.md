# App Store submission contract

This contract separates release readiness from authenticated App Store Connect mutation. A prepared package does not authorize submission.

## Source inventory and registration preparation

This section implements the documentation requirements of #53 and [architecture §9.1](../../specs/architecture.md#91-原稿の正本と登録準備). It is a preparation procedure, not a new executable registration or partial-save mode. The authority, immutable release-package and ordered submission gates below still apply to actual remote writes. Source-readiness schema/validation and read-only registration preflight are tracked separately in [#62](https://github.com/yuto1201/iOS-Template/issues/62); partial metadata-save semantics are specified in #52. Any future registration mutation needs its own explicit implementation/operation contract and approvals; #62 does not authorize it.

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
| Review contact and demo access | `metadata/app.yml.reviewContactReference`, `App Store/review/` instructions; Keychain-only actual contact/credentials | App Review Information | user + account |
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

## Authority and entry conditions

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

Schema-2 preparation also binds the canonical full application verification Issue, trusted Base, path and digest. Require the same current Head and Bundle ID, completed English/iPad adaptation, and all four cases. Before external writes and on resume, run `ruby tools/lib/release-verification.rb "$PWD" "$PACKAGE_MANIFEST" "$HEAD_SHA" "$BUNDLE_ID"`; it is read-only and does not grant authority. Old manifests without this proof require resealing. The section recorder rejects stale, partial or changed proof independently.

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
