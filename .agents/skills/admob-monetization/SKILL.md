---
name: admob-monetization
description: Activate and validate the template's optional, non-tracking AdMob anchored-adaptive banner integration for a derived iOS app after its product specification explicitly adopts ads. Do not use for AdMob Console operations, production release readiness, or apps that have not adopted advertising.
---

# AdMob Monetization

Use this skill only for a derived app whose confirmed specification and claimed Issue explicitly adopt the conditional AdMob contract. The unactivated `TemplateApp` and a fresh bootstrap output must remain free of Google SDK, identifiers, consent code, and banner source.

## Before changing the app

1. Read the Issue contract and its confirmed product, architecture, privacy, UI-direction, and entitlement anchors. Stop as `blocked:user` if adoption, placement, audience, non-tracking policy, privacy-options entry point, or ad-free entitlement source is undecided.
2. Read [references/input-contract.md](references/input-contract.md) and prepare one sanitized JSON input. Debug must use Google's demo App ID and anchored-adaptive banner ID. Release must use a verified app-specific production pair; never place that pair in this template repository.
3. Read [references/official-baseline.md](references/official-baseline.md). Recheck the linked Google and Apple sources at activation time and record the checked time, exact package versions and revisions, minimum requirements, and source URLs in the input. Do not silently substitute a newer SDK.
4. Confirm the destination is the derived app root, not this template root. Activation is local source/project mutation only; it grants no AdMob Console, contract, payment, tax, consent-message publication, `app-ads.txt`, or App Store Connect authority.

## Activate and validate

Run the deterministic entry point from the template checkout:

```sh
tools/activate-admob-integration.sh \
  --root /absolute/path/to/derived-app \
  --input /absolute/path/to/admob-activation.json
```

The tool must validate every decision before writing, apply atomically, and be idempotent for the same input. A different input against an existing activation record must stop before changing source or project files.

Then validate the resulting derived app:

```sh
tools/validate-admob-integration.sh --root /absolute/path/to/derived-app
```

The validator compares the Debug and Release Info.plist App IDs, the SKAdNetworkItems, and both branches of the generated configuration with the recorded activation input itself, so a file edited together with the record's digest still fails. Release must hold only the app's own pair, never Google's demo publisher, and the activated sources must not contain the network-free UI-test fixture route.

## Readiness report

After validation passes, report the facts a release hardening Issue must review:

```sh
tools/validate-admob-integration.sh --root /absolute/path/to/derived-app --readiness \
  [--source-packages /path/to/DerivedData/<app>/SourcePackages] \
  [--evidence /absolute/path/to/admob-evidence.json]
```

The report lists the pinned and latest observed SDK/UMP versions, the minimum and active Xcode, the official-source check time (`recheck-required` after 30 days), SKAdNetwork drift against the dated [official snapshot](references/official-snapshot.json), the app's `PrivacyInfo.xcprivacy`, and the App Store data-use record. SDK privacy manifests and signature files are checked only in a supplied resolved-package tree; otherwise they stay `unverified`. Xcode verifies the xcframework signatures when it builds, and the Xcode privacy report is a GUI step outside this tool. `releaseReadiness` is always `not-proven`.

Offline fixture, Google demo smoke, AdMob remote state, and production release are separate evidence classes. Each one is `not-run` or `unverified` unless an evidence file states that class explicitly:

```json
{"schemaVersion":1,"classes":{"googleDemoSmoke":{"status":"passed","recordedAt":"2026-10-04T05:00:00Z","summary":"Debug demo banner rendered on the dedicated iPhone"}}}
```

A class never follows from another class's result. The evidence file must not contain AdMob identifiers.

### Optional Google demo smoke

Only in an activated derived app, and only when its Issue asks for it: build Debug, which uses Google's demo App ID and banner ID, run it on that app's dedicated iPhone Simulator under `tools/with-ios-simulator-lock.sh`, and confirm that a labelled test ad renders in the included screen. Record the result only as `googleDemoSmoke`. It proves nothing about the Release pair, AdMob Console state, impressions, revenue, or review. Never use the Release configuration or production identifiers for a smoke run. The template's own fixture uses SDK stubs and never sends an ad request.

Wire the generated `AdMobRuntimeCoordinator` once at the application lifecycle boundary and call `bootstrapConsent(from:)` once during each launch, before depending on `isPrivacyOptionsRequired` or showing an included banner screen. Inject the app's real entitlement/placement eligibility source and one long-lived renderer into `AdaptiveBannerHost`; do not construct either in a frequently recreated SwiftUI body. Show the confirmed `ActivatedAdMobConfiguration.privacyOptionsEntry` only while `isPrivacyOptionsRequired` is true, and invoke `presentPrivacyOptions(from:)` from that native entry point. Use the actual proposed container width, not `UIScreen` or an orientation guess. The host collapses when consent, eligibility, configuration, or loading does not permit an ad; a width change may issue one necessary replacement banner request while repeated renders at the same width are deduplicated. Call `invalidateEligibility()` whenever an eligibility input changes, such as the verified ad-free entitlement becoming true. Every host that is visible or still preparing then prepares again and collapses, and callbacks from the suppressed request cannot reopen it.

## Fixed privacy and test boundaries

- The supported default is UMP plus one anchored-adaptive banner path. Tracking, personalized ads, IDFA/ATT, interstitial, rewarded, native, and app-open formats require a separate Decision and Issue.
- Request UMP information on each app launch, present any required form, check `canRequestAds`, and only then initialize the SDK and request an ad. Expose the privacy-options entry point when UMP requires it.
- Disable publisher first-party ID and publisher personalization before SDK start. Do not import AppTrackingTransparency, add `NSUserTrackingUsageDescription`, or call ATT from this integration.
- Treat Debug demo ads, the network-free UI-test fixture, AdMob remote state, and Release production delivery as independent evidence. Normal UI tests use injected offline consent, eligibility, and creative implementations and never wait for Google network success.
- The template fixture verifies the banner host on the Japanese iPhone and iPad offline; this is not release readiness. English coverage, a live Google demo smoke, inspection of the archived privacy report, production identifiers, App Store privacy answers, Console state, upload, and submission stay with the derived app's own hardening and release Issues.
