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

Wire the generated `AdMobRuntimeCoordinator` once at the application lifecycle boundary and call `bootstrapConsent(from:)` once during each launch, before depending on `isPrivacyOptionsRequired` or showing an included banner screen. Inject the app's real entitlement/placement eligibility source and one long-lived renderer into `AdaptiveBannerHost`; do not construct either in a frequently recreated SwiftUI body. Show the confirmed `ActivatedAdMobConfiguration.privacyOptionsEntry` only while `isPrivacyOptionsRequired` is true, and invoke `presentPrivacyOptions(from:)` from that native entry point. Use the actual proposed container width, not `UIScreen` or an orientation guess. The host collapses when consent, eligibility, configuration, or loading does not permit an ad; a width change may issue one necessary replacement banner request while repeated renders at the same width are deduplicated. Call `invalidateEligibility()` whenever an eligibility input changes, such as the verified ad-free entitlement becoming true. Every host that is visible or still preparing then prepares again and collapses, and callbacks from the suppressed request cannot reopen it.

## Fixed privacy and test boundaries

- The supported default is UMP plus one anchored-adaptive banner path. Tracking, personalized ads, IDFA/ATT, interstitial, rewarded, native, and app-open formats require a separate Decision and Issue.
- Request UMP information on each app launch, present any required form, check `canRequestAds`, and only then initialize the SDK and request an ad. Expose the privacy-options entry point when UMP requires it.
- Disable publisher first-party ID and publisher personalization before SDK start. Do not import AppTrackingTransparency, add `NSUserTrackingUsageDescription`, or call ATT from this integration.
- Treat Debug demo ads, the network-free UI-test fixture, AdMob remote state, and Release production delivery as independent evidence. Normal UI tests use injected offline consent, eligibility, and creative implementations and never wait for Google network success.
- This shape-stage integration is not release readiness. English/iPad coverage, live Google creative smoke, archive privacy/signature inspection, production identifiers, App Store privacy answers, Console state, upload, and submission stay deferred to their explicit hardening/release Issues.
