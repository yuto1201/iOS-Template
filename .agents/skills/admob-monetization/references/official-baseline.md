# Official baseline checked 2026-09-19

Recheck these first-party sources when activating an app. They are evidence for the pinned template baseline, not permission to perform remote provider operations.

## Packages and requirements

- Google Mobile Ads Swift package: `https://github.com/googleads/swift-package-manager-google-mobile-ads.git`
  - version `13.10.0`
  - revision `12b7af0f844723a86fd3c0089b02f64b1e495605`
  - the pinned `Package.swift` declares iOS 13 and the `GoogleMobileAds` product
  - the Google quick start requires Xcode 16 or later and iOS 13 or later
- Google User Messaging Platform is a transitive dependency of the pinned Mobile Ads package:
  - package `https://github.com/googleads/swift-package-manager-google-user-messaging-platform.git`
  - resolved version `3.1.0`
  - revision `13b248eaa73b7826f0efb1bcf455e251d65ecb1b`

The activation tool adds the exact direct package requirement and records the reviewed transitive UMP facts. It does not synthesize or replace `Package.resolved`; Xcode owns the actual resolution, and release hardening verifies the resolved graph from the candidate build.

## Runtime and test facts

- Quick start: <https://developers.google.com/admob/ios/quick-start>
- UMP consent and privacy options: <https://developers.google.com/admob/ios/privacy>
- Anchored-adaptive banners: <https://developers.google.com/admob/ios/banner>
- Test ads: <https://developers.google.com/admob/ios/test-ads>
- Publisher first-party ID and privacy strategy: <https://developers.google.com/admob/ios/privacy/strategies>
- Request configuration and publisher personalization treatment: <https://developers.google.com/admob/ios/targeting>
- Apple App Tracking Transparency boundary: <https://developer.apple.com/documentation/apptrackingtransparency>

The official demo App ID is `ca-app-pub-3940256099942544~1458002511`; the anchored-adaptive banner demo ID is `ca-app-pub-3940256099942544/2435281174`. Current Swift uses `largeAnchoredAdaptiveBanner(width:)`, UMP `requestConsentInfoUpdate`, `ConsentForm.loadAndPresentIfRequired(from:)`, a privacy-options form, and `ConsentInformation.shared.canRequestAds`.

The supported default deliberately does not request ATT. Before `MobileAds.shared.start()`, set publisher first-party ID to disabled and publisher privacy personalization to disabled. Always size from the host container's actual width.

## Dated snapshot (2026-10-04)

[official-snapshot.json](official-snapshot.json) records what the readiness report compares against. It was fetched from the first-party pages on 2026-10-04:

- The latest Google Mobile Ads Swift package tag is `13.11.0`. The template still pins the reviewed `13.10.0`, so the report shows `update-available` until a separate Issue reviews and pins the newer version.
- The latest UMP tag is `3.1.0`, the same as the pin.
- Google's SKAdNetwork list has 50 identifiers. The quick start and the third-party list (<https://developers.google.com/admob/ios/3p-skadnetworks>) list the same set. An app that declares only `cstr6suwn9.skadnetwork` is reported as drift for review, not rejected.
- The data disclosure page (<https://developers.google.com/admob/ios/privacy/data-disclosure>) describes IP address (general location estimate), crash logs, performance data, device ID, advertising data, and product interactions. It does not map them to App Store categories; that review stays with the app.

Refresh the snapshot and its `checkedAt` when the report says `recheck-required`, and never edit identifiers by hand without the source page.
