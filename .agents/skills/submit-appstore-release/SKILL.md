---
name: submit-appstore-release
description: Execute and resume an authenticated App Store Connect submission from an exact prepared package, with personal-team preflight, section-by-section readback, sanitized state, and build/package drift gates. Use only after prepare-appstore-assets has sealed and release-auditor has approved the intended release.
---

# Submit App Store Release

Codex and Claude may perform this authenticated external workflow. The Issue must name the selected executor, which uses the same configured Team/App preflight and secret-handling rules.

## Entry gates

Require completed English/iPad adaptation and a schema-2 manifest bound to passed full application verification at the exact candidate Head and Bundle ID. Old manifests must be resealed. Before any authenticated write, and again on resume, check that proof:

```sh
ruby tools/lib/release-verification.rb "$PWD" "$PACKAGE_MANIFEST" "$HEAD_SHA" "$BUNDLE_ID"
```

This read-only check does not authorize submission or replace account, legal, build, package or independent screenshot requirements. record-section.sh rechecks the same proof before publishing each result.

1. Read the release Issue operation declarations, `docs/AUTHORITY.md`, `docs/agent-contracts/appstore-submission.md`, and `${VERSION}-package.json`.
2. Require the Issue to authorize the exact App Store operation and executor. Verify the active authenticated session belongs to the configured Team and the remote App, Bundle ID, version, and build are exact. Never use another visible Team.
3. Run `tools/provider-preflight.sh --executor "$EXECUTOR" --issue "$ISSUE" app-store --version "$VERSION"` through the authenticated App Store adapter. Require healthy production evidence whose account and target equal `Config/ownership.yml`.
4. Recompute the package, build, release-audit, screenshot-manifest, and prepared-manifest digests. Refuse any mismatch. A first-publication package must contain the user legal-approval digest.
5. Resolve review contact credentials only at child-process scope from Keychain. Never place a secret value in the browser transcript, command arguments, result JSON, Issue, PR, screenshot, or AI prompt.

## Section workflow

Use the selected executor's authenticated browser and process these sections in order:

1. app information
2. English and Japanese localization
3. privacy declarations
4. exact manifest screenshots
5. tested build selection
6. review information
7. submission for review

For every section, enter only values from the sealed package, save them, then read the current remote values back from App Store Connect. Hash the sanitized readback and record its remote reference with `scripts/record-section.sh`. That script enforces the same personal Team, Bundle ID, version, build, source SHA, package digest, and release audit on every step.

## Resume and interruption

The only resume source is `App Store/submission/${VERSION}-result.json`. When it exists:

1. Reopen App Store Connect in the selected executor's configured session.
2. Re-run personal Team/App/Bundle/version/build preflight.
3. Read back all previously recorded sections from the remote service; do not trust local completion flags alone.
4. Pass `--resume-readback yes` only after that comparison succeeds, then record the next section.

Record sections in order and use `--submit-for-review yes` only for the final `submission` section. The result contains sanitized references and digests, never field values or credentials. If App Store Connect shows another Team, App, version, build, unexpected remote value, agreement, pricing, legal question, paid action, or changed package, stop without submitting and report the precise blocker.

Successful field entry is not submission success. After the final action, read back the remote review status and retain the sanitized result. Do not claim Apple approval; later App Review status changes are separate observations.
