# App Store submission sources

This directory is the versioned, non-secret source for App Store preparation. It is not a ready-to-publish legal package.

- `metadata/`: app identity and English/Japanese product-page copy.
- `privacy/`: declarations derived from actual app behavior and integrated SDKs.
- `legal/`: drafts generated from the privacy declaration; confirm before first publication.
- `review/`: review instructions and Keychain references, never credentials.
- `release-notes/`: localized version notes.
- `screenshots/`: only audited final screenshot sets and their manifests.
- `submission/`: official-requirement cache, checklist, and sanitized resume records.

Validate offline with an explicit requirements snapshot:

```sh
tools/validate-appstore-package.sh \
  --root 'App Store' \
  --project-root "$PWD" \
  --bundle-id com.yuto.TemplateApp \
  --version 1.0 \
  --requirements 'App Store/submission/requirements.json'
```

The template URLs, legal drafts, screenshots, release-auditor decision, and first-publication confirmation must be replaced by a real app-specific release Issue before submission.

## Prepare confirmed sources before registration

Use the [field inventory and registration preparation](../docs/agent-contracts/appstore-submission.md#source-inventory-and-registration-preparation) to map every field to its app/spec source and ASC destination. Identity bootstrap does not currently rewrite this directory or register a Bundle/App. Check it separately for residual template values and stale privacy/SDK declarations.

Promote temporary copy only after reviewing it against actual app behavior. Keep existing-schema values in their files; for registration fields and confirmation provenance not yet supported by the YAML schemas, create `metadata/reviewed-draft.md` in the app that needs it. Record field/locale, source anchor/revision/digest, draft/confirmed/remote-saved state, confirmation reference and unresolved reason; never store contact values or credentials. This human-readable ledger is not an executable schema or a sealed release package.

Missing Team, SKU, naming approval, age-rating answers, production IAP or public URLs must remain explicit blockers for the affected operation. Independent text preparation may continue, but complete package validation and the checklist cannot be waived. AppLibrary routes still require the user's specified destination. Screenshots remain deferred when the user has left their scope undecided; do not generate them just because text preparation began. See the [readiness report and fixture requirements](../docs/agent-contracts/appstore-submission.md#readiness-report-and-required-fixtures).
