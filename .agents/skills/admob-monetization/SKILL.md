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

The validator compares the Debug and Release App ID build settings, the SKAdNetworkItems, and both branches of the generated configuration with the recorded activation input itself, so a file edited together with the record's digest still fails. Release must hold only the app's own pair, never Google's demo publisher, and the activated sources must not contain the network-free UI-test fixture route.

## Info.plist handling

Activation keeps every Info.plist source the app already has. It never changes `GENERATE_INFOPLIST_FILE`, never removes or edits an `INFOPLIST_KEY_*` setting (scene manifest, launch screen, orientations, display name), and never replaces or duplicates an existing `INFOPLIST_FILE`. It adds only:

- `ADMOB_APPLICATION_IDENTIFIER` to the application target's Debug (Google's demo App ID) and Release (the app's own App ID) build configurations;
- `GADApplicationIdentifier` = `$(ADMOB_APPLICATION_IDENTIFIER)` and the input's exact `SKAdNetworkItems` to the Info.plist the app uses.

Where the two keys go depends on the project:

- When Debug and Release already point at the same `INFOPLIST_FILE`, the keys are added to that file with `plutil`. Every other key and value stays; `plutil` rewrites an XML plist with its keys in sorted order and keeps a binary plist binary.
- When the application has no `INFOPLIST_FILE` and both configurations keep `GENERATE_INFOPLIST_FILE = YES`, activation adds `<Module>/AdMob/Info.plist` holding only the two keys and points both configurations at it. Xcode merges that file with the generated keys. In a file-system-synchronized app folder the file is also excluded from the target's resources with a membership exception, as Xcode itself does, so it is not copied into the bundle a second time.

Activation stops before any change, with the reason, when Debug and Release use different `INFOPLIST_FILE` values, when one configuration declares more than one or a conditional `INFOPLIST_FILE`, when the file is missing, symlinked, outside the repository, or not a dictionary plist, when it already has a different `GADApplicationIdentifier` or different `SKAdNetworkItems`, when the app declares `NSUserTrackingUsageDescription`, when the project-level settings or a tracked `.xcconfig` set `INFOPLIST_FILE` or `ADMOB_APPLICATION_IDENTIFIER`, or when the project already links Google Mobile Ads.

The Info.plist file is the app's own file, so its bytes are not pinned in the activation record: the app may add or edit unrelated keys later. The validator reads the Info.plist in use and requires exactly the `$(ADMOB_APPLICATION_IDENTIFIER)` reference, the recorded `SKAdNetworkItems`, no `NSUserTrackingUsageDescription`, one `INFOPLIST_FILE` per configuration, and `GENERATE_INFOPLIST_FILE` unchanged from the activation source. Do not use `INFOPLIST_KEY_GADApplicationIdentifier`; Xcode accepts only its own fixed key set there.

## Moving an app that integrated ads outside the template

An app that added Google Mobile Ads by hand (for example its own `<Module>/AdMob/` code, its own package reference, and App ID keys in its own Info.plist) can move to this activation in a dedicated Issue when all of these hold:

1. Its confirmed specification satisfies [references/input-contract.md](references/input-contract.md): the non-tracking UMP route with one anchored-adaptive banner, minimum age 18 or more, the exact pinned SDK and UMP versions, and verified Release identifiers for this Bundle ID.
2. On a feature branch with a clean worktree, it first removes its own integration in one commit: the `<Module>/AdMob/` folder, the Google Mobile Ads package reference and product, any `ADMOB_APPLICATION_IDENTIFIER` or other App ID build settings, and `GADApplicationIdentifier` and `SKAdNetworkItems` from its Info.plist. It keeps every other Info.plist key and the existing `INFOPLIST_FILE`.
3. Debug and Release use the same `INFOPLIST_FILE` (or none, with `GENERATE_INFOPLIST_FILE = YES`).

Then run the activation and the validator as above, wire `AdMobRuntimeCoordinator` and `AdaptiveBannerHost` in place of the removed code, and rebuild and retest the app. When a condition cannot be met, for example a tracking or other ad format, a different SDK version, an App ID that differs by configuration in another way, or separate Debug and Release Info.plist files that must stay separate, keep the app's own integration under its own decision and record why; do not edit the activation output or the record by hand to make it pass.

## Readiness report

After validation passes, report the facts a release hardening Issue must review:

```sh
tools/validate-admob-integration.sh --root /absolute/path/to/derived-app --readiness \
  [--source-packages /path/to/DerivedData/<app>/SourcePackages] \
  [--evidence /absolute/path/to/admob-evidence.json]
```

The report lists the pinned and latest observed SDK/UMP versions, the minimum and active Xcode, the official-source check time (`recheck-required` after 30 days), SKAdNetwork drift against the dated [official snapshot](references/official-snapshot.json), the app's `PrivacyInfo.xcprivacy`, and the App Store data-use record. It maps each collected data type in the app privacy manifest to its App Store category through an explicit table of Apple's values and reports categories missing from the manifest, categories not in the record, and unmapped types; without a readable manifest the comparison stays `unverified`. SDK privacy manifests and signature files are checked only in a supplied resolved-package tree; otherwise they stay `unverified`. Xcode verifies the xcframework signatures when it builds, and the Xcode privacy report is a GUI step outside this tool. `releaseReadiness` is always `not-proven`.

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
