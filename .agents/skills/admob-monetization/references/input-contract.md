# Activation input contract

The activation input is a UTF-8 JSON object with exactly these top-level keys:

```text
schemaVersion, adopted, appIdentity, deploymentTarget, placement, audience,
tracking, ump, adFreeEntitlement, identifiers, officialSources,
privacyDeclaration, skAdNetworkIdentifiers
```

Unknown keys are rejected. Arrays that express a set must be nonempty where noted, sorted, and unique. Do not store secrets, account credentials, payment details, or real user data.

## Required values

- `schemaVersion`: integer `1`.
- `adopted`: boolean `true`. `false` means leave the app unchanged rather than installing dormant provider code.
- `appIdentity`: exactly `displayName`, `moduleName`, `appSlug`, and `bundleId`; all values must match `Config/app-identity.json` in the destination.
- `deploymentTarget`: an iOS version at least `13.0` and equal to the destination project's declared target.
- `placement`:
  - `includedScreens`: nonempty sorted unique screen identifiers backed by the confirmed app UI specification.
  - `excludedScreens`: sorted unique identifiers, disjoint from `includedScreens`.
  - `container`: `safe-area-bottom` (the default) or `safe-area-top`. The banner is anchored to that safe-area edge; see "Banner placement" in `SKILL.md`. Any other value stops before changes.
  - `privacyOptionsEntry`: a nonempty, confirmed native entry-point identifier.
- `audience`:
  - `minimumAge`: integer `16` or greater (D-087). A value below 16, a non-integer such as `16.5`, or a string such as `"16"` stops before changes. The activation record keeps the value in `activationInput`, and the generated configuration declares it as `ActivatedAdMobConfiguration.minimumAudienceAge`.
  - `regions`: nonempty sorted unique region identifiers.
  - `childDirected`: exact `false`.
  - `underAgeOfConsent`: exact `false`.

### Audience floor and ad content rating

The floor is 16 because 16 is the highest age of digital consent that EU member states may set (GDPR Article 8 lets each state choose an age from 13 to 16, https://eur-lex.europa.eu/eli/reg/2016/679/oj ), so the default route needs no regional split. The earlier floor of 18 was the template's own conservative choice, not a Google or Apple rule. Google gives children and users under the age of consent a separate treatment (https://support.google.com/admob/answer/6219315 , https://developers.google.com/admob/ios/targeting ); this route still refuses both, so `childDirected` and `underAgeOfConsent` stay `false`. Apple requires ads to be appropriate for the app's age rating (App Review Guideline 2.5.18, https://developer.apple.com/app-store/review/guidelines/ ).

When `minimumAge` is below 18, the shared core (`AdMobMaxAdContentRating.cap(forMinimumAudienceAge:)`) decides the maximum ad content rating T (teen, suitable for App Store 12+), and the generated provider sets `maxAdContentRating = .teen` on the SDK request configuration before the SDK starts (https://support.google.com/admob/answer/7562142 , https://developers.google.com/admob/ios/targeting ). At 18 or more the app sets no cap, as before. Moving to `ageRestrictedTreatment`, the successor of the child-directed and under-age-of-consent tags, is outside this contract.
- `tracking`: exact non-tracking policy: `mode` is `non-tracking`; `attPrompt`, `publisherFirstPartyIDEnabled`, and `personalizedAds` are all `false`.
- `ump`: `enabled` and `privacyOptionsEnabled` are both `true`.
- `adFreeEntitlement`: `enabled` is a boolean and `source` is a nonempty name of the app-owned source of truth. The generated integration records this name; the app must inject the actual entitlement lookup.
- `identifiers`:
  - Debug App ID: exact `ca-app-pub-3940256099942544~1458002511`.
  - Debug banner ID: exact `ca-app-pub-3940256099942544/2435281174`.
  - Release App ID and banner ID: non-demo, app-specific, valid-format IDs from the same publisher. They are required for a production-configured activation, but must never be copied into this template repository.
  - `release.binding`: exactly the target `bundleId`, configuration `Release`, `readbackSource` value `admob-console-readback`, and a fresh RFC 3339 `verifiedAt`. This is the explicit confirmation that the pair was read back for this app; syntax or publisher equality alone is insufficient.
- `privacyDeclaration`:
  - `appStoreTracking`: exact `false` for this route.
  - `dataUseCategories`: nonempty sorted unique, reviewed App Store data-use category identifiers.
  - `sourcePath`: normalized repository-relative path to the reviewed privacy/App Store declaration source.
  - `sourceDigest`: `sha256:` plus the exact source file digest.
  - `reviewedAt`: fresh RFC 3339 timestamp. A missing, stale, symlinked, outside-repository, or digest-mismatched source is rejected before mutation.
- `skAdNetworkIdentifiers`: sorted unique identifiers from the currently checked official quick-start source and must include `cstr6suwn9.skadnetwork`.

## Official-source record

`officialSources.checkedAt` is a fresh RFC 3339 timestamp. The record contains:

- `googleMobileAds`: exactly `minimumIOS`, `minimumXcode`, `packageURL`, `releaseURL`, `revision`, and `version`. Use official package URL, exact `13.10.0` version, exact `12b7af0f844723a86fd3c0089b02f64b1e495605` revision, minimum iOS `13.0`, and minimum Xcode `16.0`;
- `ump`: exactly `packageURL`, `releaseURL`, `revision`, and `version`. Use the official package URL, exact `3.1.0` version, and exact `13b248eaa73b7826f0efb1bcf455e251d65ecb1b` revision;
- `googleGuides`: nonempty official Google documentation URLs covering quick start, UMP, banner sizing, test ads, and privacy configuration;
- `appleGuides`: nonempty official Apple documentation URLs used for the privacy determination.

`officialSources` itself has exactly `checkedAt`, `googleMobileAds`, `ump`, `googleGuides`, and `appleGuides`. Run the activation preflight rather than hand-editing generated output. A source/version mismatch stops before writes and needs an explicit template update, not an automatic upgrade.

The activation record retains the canonical sanitized input, its digest, the exact source Head/project digest, fixed package facts, and policy facts. Validation recomputes and cross-checks those fields; changing only record metadata cannot authorize a different input. Production identifiers are not secrets and already exist in the derived app's Release configuration, but do not copy a derived record back into this template repository.

## Info.plist output

The input carries no Info.plist path. Activation reads the application target's Debug and Release configurations: when they share one `INFOPLIST_FILE`, that file receives `GADApplicationIdentifier` (`$(ADMOB_APPLICATION_IDENTIFIER)`) and the exact `SKAdNetworkItems` built from `skAdNetworkIdentifiers`; when there is none and both keep `GENERATE_INFOPLIST_FILE = YES`, activation adds `<Module>/AdMob/Info.plist` with only those two keys. `ADMOB_APPLICATION_IDENTIFIER` is set per configuration from `identifiers.debug.appId` and `identifiers.release.appId`. An existing `GADApplicationIdentifier` or `SKAdNetworkItems` that differs, split or duplicated `INFOPLIST_FILE` settings, and a missing or symlinked file stop activation before any change. The record pins the generated Swift files and the project, not the Info.plist, so the app may change its other Info.plist keys later. See the skill's Info.plist handling and migration sections.

## Environment separation

The generated configuration must keep three routes distinct:

| Route | Identifier/source | Pass condition |
|---|---|---|
| Debug | Google demo App ID and demo anchored-adaptive banner ID | Optional Google demo smoke; never production traffic |
| UI Test | Protocol-injected offline consent, eligibility, and creative | Deterministic local Build/Unit/UI evidence; no SDK request or network success |
| Release | Verified app-specific production App ID/banner pair | Deferred release gate on the same candidate; local activation alone is not readiness |
