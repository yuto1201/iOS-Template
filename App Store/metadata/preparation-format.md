# Versioned preparation sources

`tools/prepare-appstore-sources.sh --project-root /absolute/physical/app/root` reads the app's sources and supplied evidence without modifying files, contacting Apple, generating screenshots or granting release authority. In a canonical linked worktree, `.artifacts/appstore-preparation/` resolves to the shared primary evidence store; arbitrary artifact symlinks are rejected.

This source format complements the existing exact-key YAML files. It is **not** an alternative package/checklist/result schema. Keep supported app and localized fields in `app.yml` and `localizations/*.yml`, privacy in `privacy/data-use.yml`, and legal/review/release-note text in their existing files. Do not add preparation-only keys to those YAML files.

## Partial source document

The app may create `App Store/metadata/preparation.json` with required headers:

```json
{
  "schemaVersion": 1,
  "recordType": "appstore-preparation-sources"
}
```

Every other root key is optional during drafting. Missing/null values are unanswered, not `false`, an empty value, or a not-applicable decision. Unknown keys and versions are rejected. A structurally valid value does not establish its truth or approval. Current-byte derive/user/public/account evidence remains necessary for confirmation.

Allowed root keys, beyond the headers:

| Key | Source value |
| --- | --- |
| `build` | Numeric build string, not a JSON number |
| `buildArtifact` | Descriptor of the supplied distribution export record described below |
| `supportedLocales` | Exact current modeled locale set `en-US` and `ja` (unique; order does not matter). Additional locales require a format/report expansion rather than silent omission |
| `sku`, `secondaryCategory`, `marketingURL` | Nonempty strings; a URL also needs approved public-page evidence |
| `account` | Partial object with only `appId`, `bundleRegistration`, `userAccess`; non-secret strings |
| `demoAccess` | Exact `required` boolean, `credentialsReference`, `instructionsSource`. When false, both references are null; when true, credentials use a `keychain://` reference and instructions identify a held non-secret `App Store/review/*.md` source whose bytes join the field fingerprint |
| `legal` | Partial object with only `eula`: exact `choice` (`standard` or `custom`), `url`, `textSource` descriptor; public proof must match that URL and source |
| `iap` | Partial object with only the seven fields below |
| `ageRating`, `contentRights`, `exportCompliance` | Explicit questionnaires described below |
| `screenshots` | Optional exact `en-US`/`ja` objects containing only `iphone`/`ipad` records. An `adopted` record has exact `status`, `manifest`, `review`, `requirements` descriptors. Use `dispositions` for a deferral, not an alternate screenshot value |
| `dispositions` | Optional array of exact `fieldId`, `locale`, `decision`, `reason` declarations, described below; declarations alone never confirm a decision |
| `publicPages` | Per-field mapping for `supportURL`, `privacyPolicyURL`, `marketingURL`, `legal.privacyPolicy`, `legal.termsOfUse`, `legal.eula`, or `ageRating`, each with exact `url` and reviewed `textSource` descriptor; supplied public observation is still required and unknown fields are rejected |
| `localizedURLs`, `localizedPublicPages` | Optional exact `en-US`/`ja` objects with only `supportURL`, `privacyPolicyURL`, `marketingURL` keys. Values override the shared URL or approved-page mapping only for that locale. An explicitly null URL stays unanswered; it does not fall back |

IAP fields are `productId`, `productType`, `price`, `territories`, `availability`, `restore`, `offerCodeApplicability` (seven configuration attributes, including the identity). `productId` is one ID string or a unique nonempty ID list. With a list, each remaining field is an object keyed by every declared product ID, with no missing or extra IDs. `price` has exact `amount` decimal string and three-letter `currency`; `territories` is a unique nonempty code list; `restore` is an explicit boolean. Product type uses `CONSUMABLE`, `NON_CONSUMABLE`, `AUTO_RENEWABLE_SUBSCRIPTION` or `NON_RENEWING_SUBSCRIPTION`; availability is `available` or `unavailable`; offer applicability is `applicable` or `not-applicable`. None of these local values proves production availability, price, restore behavior or eligibility.

Source/evidence descriptors contain exact `path`, `anchor`, `revision`, and `digest`. Paths are contained repository-relative regular files; revision is the captured actual commit only when its unreplaced tree blob equals the read bytes, otherwise null. Digest is SHA-256 of the exact non-secret bytes. Repository fsmonitor and clean/process filters are never executed while deriving this evidence. References never contain raw credentials/contact details or their value hashes. No absolute private paths enter reports.

The code inventory binds all inspected app/Config/dependency bytes. A remote Swift package must have one exact Xcode `packageReferences` URL and one matching workspace `Package.resolved` identity/location/revision pin; a same-name or root-only lock is insufficient. Package presence alone is not invented into `privacy.thirdPartySDKs`: known privacy SDK markers still require an exact supported declaration, while every unknown package remains source-bound for human privacy review. Privacy/declaration failures invalidate privacy, policy/terms and review claims, not unrelated IAP/questionnaire values; an unreadable implementation inventory continues to invalidate every implementation-derived claim.

## Source fields and resource-bound save scope

The report keeps 40 shared rows and 11 rows for each of `en-US` and `ja` (62 total). The legacy YAML schemas remain unchanged. Shared `app.yml` support/privacy URLs and preparation `marketingURL` are source defaults, not a claim that Apple stores one global URL: each locale has its own row and source-bound confirmation. Optional `localizedURLs` and `localizedPublicPages` provide distinct destinations or approved text per locale. Identical URLs still need separate locale evidence; English approval never confirms Japanese metadata.

| Preparation section | Fields | ASC resource |
| --- | --- | --- |
| `app-info-localization` | name, subtitle, privacyPolicyURL | `appInfoLocalizations` (app-level localized information) |
| `version-localization` | description, keywords, promotionalText, releaseNotes, supportURL, marketingURL | `appStoreVersionLocalizations` (selected platform/version) |
| `review` | reviewNotes, reviewContactReference, demoAccess | `appStoreReviewDetails` (one selected version, locale null) |
| `version` | version, copyright | `appStoreVersions` (one selected platform/version, locale null) |
| `app-information` | category, secondaryCategory | `appInfos` (category relationships, locale null) |
| `screenshots` | screenshots.iphone, screenshots.ipad | Existing adopted-asset validation, not text-save authorization |

The app-info baseline/readback must also preserve explicitly observed `privacyChoicesURL` and `privacyPolicyText`, even when the selected patch changes only the name. Omission is unknown, not null. Version-localization projections include all six text properties. `releaseNotes` corresponds to ASC `whatsNew`; the canonical URL IDs correspond to ASC's `*Url` attributes. Each normalized projection accepts exactly the modeled fields for its resource; an unmodeled property requires an explicit adapter expansion and is rejected rather than hashed or silently preserved. These are normalized observation records, not raw API payloads or a mutation interface.

Version projections contain `version` (ASC `versionString`), `copyright`, `earliestReleaseDate`, `releaseType`, `downloadable`, `reviewType`, `usesIdfa` and the observed `build` relationship. The last six are preserved, not authorized targets of this preparation reader; this does not select or upload a build. Category projections contain `category` (ASC `primaryCategory`), `secondaryCategory` and all four primary/secondary subcategory relationships. A relationship is represented by its observed category ID or explicit null. These mappings were checked against Apple's [version update attributes](https://developer.apple.com/documentation/appstoreconnectapi/appstoreversionupdaterequest/data-data.dictionary/attributes-data.dictionary) and [category relationships](https://developer.apple.com/documentation/appstoreconnectapi/appinfoupdaterequest/data-data.dictionary/relationships-data.dictionary) on 2026-09-09. Preserve any observed deprecated `usesIdfa` value; never infer its value or consent from app metadata.

Report sections organize source readiness; they are not universal Apple forms. Internal display name/module/slug, supported device/locale inventories, permission/SDK inventories, restore behavior and local privacy/terms documents are not direct ASC metadata-save fields. Their readback claims receive `not-a-remote-metadata-field`; remove that inapplicable claim and retain independently evidenced source confirmation. App registration/access, privacy declarations, age/content-rights/export questionnaires, EULA, production IAP and uploaded assets need their own exact resource/operation mappings. The reader does not accept invented aggregate forms for them: an unsupported requested save-readback receives `remote-form-adapter-unavailable`, without preventing their ordinary source/account/public confirmation. This is not permission to omit any inventory field from preparation or to waive a release gate.

A save receipt's `remoteReference` is exactly `asc://apps/<appId>/<resource>/<resourceId>`, where the resource must match the table's supported text/category resource. The resource ID must be a nonempty opaque ASCII alphanumeric, underscore or hyphen ID (at most 128 characters). It is included in the user-approved intent digest. Both normalized baseline and readback have exact keys `schemaVersion`, `recordType`, `identity`, `section`, `locale`, `remoteReference`, `values` and bind that same reference. An App ID alone or an equally shaped snapshot from another resource is insufficient. This validates supplied source/context/relationship evidence, not a live Apple relationship lookup; collectors must actually resolve the app/version/locale relationship under their separate authority.

Scope checked against Apple's [app-info localizations](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-appinfos-_id_-appinfolocalizations), [version localizations](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-appstoreversions-_id_-appstoreversionlocalizations), and [localization procedure](https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-information) on 2026-09-09. Shared identity includes an exact 10-character Team ID, numeric App ID, canonical Bundle ID, `IOS`, and a nonnull one-to-three-component numeric selected version. Invalid or missing members cannot form account/readback identity. This does not make an app-wide name change version-specific or establish its publication effect.

## Age rating questionnaire

The exact keys are `schemaVersion: 1`, `questionnaireVersion: "apple-age-rating-2026-09-09"`, `answers`, `ageCategory`, and `ageSuitabilityURL`. This is the template's versioned input, not an ASC API payload or calculated rating. The complete question inventory is fixed in `SourceSchema::AGE_BOOLEANS` and `AGE_FREQUENCIES`; callers cannot replace it with a shorter list. Every answer is explicit: booleans for feature presence, or `NONE`, `INFREQUENT`, `FREQUENT` for frequency. Missing/null, string booleans and deprecated frequency names remain invalid/unanswered.

`ageCategory` has exact `choice` and `value`: `not-applicable` requires null; `made-for-kids` requires `5-and-under`, `6-8`, or `9-11`; `higher-rating` requires `9+`, `13+`, `16+`, or `18+`. These are user choices, not a computed rating or a claim that Apple permits an override. `ageSuitabilityURL` is null or a real destination; providing it adds the public-evidence requirement to that row.

The question set was checked on 2026-09-09 against Apple's [age-rating definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions), [setting procedure](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/) and [API frequency migration guidance](https://developer.apple.com/documentation/appstoreconnectapi/age-ratings). Before a real operation, refresh the applicable Apple questionnaire, including any additional regional/category requirements; a version match does not prove that remote requirements never changed. The checker never computes the final global/regional age rating or answers from absence of a keyword.

## Content rights and export declarations

`contentRights` has exact `schemaVersion: 1`, `containsThirdPartyContent`, `hasNecessaryRights`, and `rightsReferences`. Third-party content requires explicit true rights confirmation and unique nonempty `rights://` references backed by the review. With no third-party content, the conditional rights answer is null and references are empty. A missing choice or an unsupported rights claim is not confirmed by a complete JSON object.

`exportCompliance` has exact `schemaVersion: 1`, `usesEncryption`, `encryptionTypes`, `distributedInFrance`, `documentationRequired`, `determinationReference`, and `documents`. All three boolean decisions are explicit. Types are a unique subset of `apple-os-only`, `standard`, `proprietary`, empty only when encryption use is false. `determinationReference` is a scope-appropriate `user-approval://` decision, not an agent's invented legal conclusion. Documents have exact `kind` (`ccats` or `france`), `status: "approved"`, and a sanitized `asc://apps/<id>/encryption/<id>` reference; supplying documents also requires current account evidence. The checker rejects unanswered or inconsistent declarations and missing stated documents, but does not grant an exemption or approve documentation.

Apple's [export overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance) and [documentation matrix](https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/) were checked on 2026-09-09. Applicability must be determined for the actual app and distribution context. Existing release/legal gates remain mandatory.

## Reviewed-draft migration

1. Preserve `reviewed-draft.md` and any existing files; do not overwrite an app's drafts as part of a template update.
2. Review its proposed values against current app/spec sources. Keep facts that belong to the existing YAML schemas there; copy only preparation-only, non-secret values to the versioned JSON document.
3. Retain unknowns as omitted/null. Do not copy ledger labels such as `confirmed` or `remote-saved` into JSON, or invent questionnaire answers while migrating.
4. Run the read-only checker. Gather fresh field/source-bound review, user approval, public or account evidence where required; old ledger wording alone is never confirmation.
5. Re-read authorized remote state separately before any remote-saved claim. No migration step performs an Apple save or promotes checklist/package/result records.

## Evidence and remaining readiness boundaries

Local confirmation receipts live in `.artifacts/appstore-preparation/confirmations.json` and reference individual proof files. Remote-readback receipts use distinct `schemaVersion: 2` and `recordType: appstore-preparation-readback`, not the future selective-save journal. They carry the exact claimed `issueType` (`feature`, `regression`, `docs` or `release`) and use it to reconstruct the parsed historical Issue contract/body; omission or a type that cannot reproduce the supplied contract is rejected. The same receipt binds that Issue type into the user-approved intent together with the exact executor/operation, configured identity, source revision, public effect, historical preflight, full supplied non-secret form baseline and fresh readback. Selected values must match current confirmed sources; unselected values must remain byte-semantically equal, including null/empty, numeric types and Unicode. Synthetic/supplied observation origins remain visible; no live inspection is claimed.

## Transient protected comparison

A supplied save observation can preserve unselected private form values without placing those values or their hashes in public evidence. Its public baseline/readback retain only matching `keychain://` references. Matching references alone are insufficient: an authorized caller must explicitly supply the actual observed baseline/readback through a pipe to `--protected-forms-stdin` for that invocation. There is no built-in collector, Keychain lookup, authentication, network request or secret-file reader. Do not place this payload in arguments, shell history, logs, `.artifacts`, tracked files or a temporary plaintext file. Non-pipe stdin is rejected; without the option, this input is not consumed.

The pipe contains exact `schemaVersion: 1`, `recordType: "appstore-protected-form-input"`, and `observations` (1–16 entries, maximum 1,000,000 UTF-8 bytes overall). Duplicate keys/references, malformed JSON and non-finite values are rejected with a sanitized error. Each observation has exactly:

- `reference`: unique `protected-observation://<id>` matching the readback receipt's optional `protectedObservation`;
- `source`, `identity`, `sourceRevision`, `section`, `locale`, `intentDigest`, `savedAt`, `observedAt`: exact bindings to that receipt, whose ordinary identity/freshness/authority checks remain mandatory;
- `references`: every protected field's matching public Keychain reference;
- `baseline`, `readback`: those same field IDs and their actual transient observed values. Missing is not null. Values compare exactly, including number types and Unicode; no private value hash is published.

`protectedObservation` is included in the user-approved intent digest, not merely appended after approval. Contact fields use their public reference; `demoAccess` uses its `credentialsReference` when required. This route supports **preservation only**, not updating a selected private field. A private-field update needs a separately implemented adapter and approved scope. Incorrect references, missing/changed values, another identity/source/intent or absent transient input leaves the affected row `draft`. A later invocation must supply fresh matching data again; a public `protectedComparison: matched` report is not reusable secret evidence or operation authority.

Comparison values exist in process memory for the invocation; no secure-memory-erasure guarantee is made. Successful output includes only the protected observation reference and logical field IDs, with the ordinary synthetic/supplied origin disclosure. Existing public-source secret detection stays enabled and is not bypassed for documents, proof files or binary descriptors.

For the `review` form, public `reviewNotes` corresponds to ASC `notes`. Contact and demo groups retain Keychain references, while the transient `reviewContactReference` value has exactly `contactFirstName`, `contactLastName`, `contactPhone`, `contactEmail` (nonempty strings). Transient `demoAccess` has exactly `demoAccountRequired` (explicit boolean), `demoAccountName`, `demoAccountPassword`. When required, both credentials must be nonempty strings; when not required, each is an explicitly observed string or null. Missing the requirement or a contact/demo property in both snapshots is incomplete evidence, not equality. A disabled demo account still requires the protected observation, so changing retained credentials is detected. These normalized reference groups are not direct API payloads or a localized Notes field. `reviewAttachments` is an array of at most ten unique sanitized `asc://apps/<appId>/reviewAttachments/<id>` references; supplied unselected references must remain equal.

Reviewed against Apple's [review-detail attributes](https://developer.apple.com/documentation/appstoreconnectapi/appstorereviewdetail/attributes-data.dictionary) and [review details for a version](https://developer.apple.com/documentation/appstoreconnectapi/read_the_app_store_review_details_resource_information_of_an_app_store_version) on 2026-09-09. Validation still consumes supplied observations only; creating review details, writing notes or uploading attachments is not performed or authorized here.

## Existing build and adopted screenshot evidence

`buildArtifact` points to `.artifacts/appstore-preparation/builds/<id>.json`, with exact `schemaVersion: 1`, `recordType: "appstore-distribution-build"`, `source` (`synthetic-fixture` or `xcode-export`), `sourceRevision`, `bundleId`, `version`, `build`, `platform: "iphoneos"`, `distributionMethod: "app-store-connect"`, and `artifact` descriptor. The artifact is a held regular `.ipa` under the same builds directory. Its exact bytes must match, and its ZIP directory and actual app Info.plist must identify the same Bundle/version/build and iPhoneOS platform. The captured revision's raw tree, index and every app source/resource/asset/dependency build input must still match exactly; edited, deleted, untracked or ignored inputs invalidate old build and screenshot evidence. This check uses bounded descriptor reads and raw blob comparison rather than repository-provided filters or hooks. It does not execute an archive, verify code signing, or prove a successful export/upload. Preserve the real export evidence and perform the separate release checks.

Adopted screenshots use the existing builder's final `App Store/screenshots/manifest.json`, its supplied visual-review record under `.artifacts/appstore-preparation/proofs/`, and current `App Store/submission/requirements.json`. Source SHA, build digest, requirements/review digests, locale, family, order, runtime, device, dimensions, image digest and visual-review decisions must agree. The checker reads/decompresses bounded opaque RGB PNGs and verifies structure, CRCs, scanlines, count and required display-family coverage; no screenshot is generated, transformed or accepted from a filename alone. Existing files and records stay unchanged. Binary inputs have separate finite size/aggregate limits and the same held-descriptor, no-symlink, single-link and final-byte checks as text inputs.

## Explicit dispositions

Each declaration has exactly `fieldId` (an inventory ID), `locale` (null for shared fields or the exact inventory locale), `decision` (`deferred` or `not-applicable`) and a nonempty non-secret `reason`. Unknown fields, malformed or duplicate declarations block the overall report through sanitized `planningErrors`. The declaration's source bytes, including its reason, join the field fingerprint. Reports expose only the decision and reason codes, not the raw reason text.

- `deferred` requires a current user proof, never a model-only approval. It preserves underlying missing/invalid-source diagnostics and always prevents overall `prepared`. A declared deferred screenshot is not captured or inspected as an adopted image. Existing files remain untouched. Without approval, the row stays `draft`.
- `not-applicable` requires current derive and user proofs plus a complete source inventory. It is allowed for an empty `secondaryCategory`, `marketingURL`, localized `subtitle` or `promotionalText`; all seven empty IAP fields together; or an empty screenshot field whose device platform is explicitly disabled in app metadata. Actual Xcode platform reconciliation remains required separately. Nonempty values conflict; mandatory identity, privacy, questionnaires and release notes cannot be waived. Empty IAP configuration does not prove remote products are absent: the evidence must support the app's feature applicability.
- Changes to declaration/source/code/SDK bytes invalidate prior applicability approval. Omitted/null values without an approved declaration stay unresolved. A disposition and a remote-readback claim for the same row conflict and return that row to `draft`.

When every modeled row has current confirmation, matching remote readback or approved applicability evidence and registration identity matches, the report returns `status: "prepared"` (exit 0). Deferred or missing/invalid evidence returns `blocked` (exit 1); unsafe invocation/input failure returns `invalid` (exit 2). `releaseReady` remains false and the checker never authorizes a mutation. A supplied synthetic origin stays visible in the report; a passing synthetic test is not live verification.

Changes to this workflow-only preparation reader require current-Head targeted repository verification for the affected preparation domains and any review required by the Issue contract. They do not themselves claim full native, XCTest UI, screenshot or Simulator verification; application release Issues retain their separate stage-appropriate native gates. Transient protected preservation does not establish a live collector or private-field update adapter; the unsupported readback resource families above are not silently treated as implemented. Do not treat `prepared`, partial confirmations or this format document as release readiness: existing full package validation, immutable records, screenshots, legal approval, signing/build verification and release review are unchanged.
