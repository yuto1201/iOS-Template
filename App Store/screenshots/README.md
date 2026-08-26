# Release screenshots

Store only audited final assets, grouped as `${locale}/${displayFamily}/${order}-${state}.png`, plus the generated `manifest.json`. Raw captures stay in a release-specific temporary workspace until review is complete.

The display families are resolved from the current official requirements cache. They are separate from the normal iPhone Pro/iPad Air verification matrix and may require an iPhone Pro Max. `states.json` is the checked-in launch-state contract; an app created from this template must implement those deterministic launch arguments before release capture.

## Production flow

1. Build the exact release candidate and record its full Git SHA and artifact SHA-256 digest.
2. Run `tools/capture-appstore-screenshots.sh` with the current requirements, `states.json`, built `.app`, Bundle ID, Runtime identifier, Git SHA, and build digest. The tool creates and later deletes only its own release Simulators, fixes language, locale, appearance, time, status bar, local fixture, and launch state, and captures exact PNG output.
3. Have the AI visual evaluator and `release-auditor` inspect every raw image. Their sanitized JSON must mark safe area, text clipping, truthful representation, locale parity, and the exact image digest as passed.
4. Run `tools/build-appstore-screenshot-set.sh` with that review JSON. It accepts only current display dimensions, no alpha, no duplicate bytes, exact English/Japanese families, contiguous ordering, allowed device types, and the same source/build identity. It copies bytes without stretching, cropping, or compositing.
5. Commit only the resulting final images and manifest for the intended release.

Any app code, localized copy, source SHA, build digest, requirement cache, or reviewed image change invalidates the set. Never include personal data, notification banners, credentials, debug overlays, placeholder marketing claims, or reuse an image across locales when visible copy differs. Cropping and compositing are intentionally unsupported until a separate checked-in specification and tests approve an exact transformation.
