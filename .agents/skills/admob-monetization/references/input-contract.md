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
  - `container`: exact `safe-area-bottom`.
  - `privacyOptionsEntry`: a nonempty, confirmed native entry-point identifier.
- `audience`:
  - `minimumAge`: integer `18` or greater.
  - `regions`: nonempty sorted unique region identifiers.
  - `childDirected`: exact `false`.
  - `underAgeOfConsent`: exact `false`.
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

## Environment separation

The generated configuration must keep three routes distinct:

| Route | Identifier/source | Pass condition |
|---|---|---|
| Debug | Google demo App ID and demo anchored-adaptive banner ID | Optional Google demo smoke; never production traffic |
| UI Test | Protocol-injected offline consent, eligibility, and creative | Deterministic local Build/Unit/UI evidence; no SDK request or network success |
| Release | Verified app-specific production App ID/banner pair | Deferred release gate on the same candidate; local activation alone is not readiness |
