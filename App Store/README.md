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

## Save text before complete release assets

Use the [mode and selective-save contract](../docs/agent-contracts/appstore-submission.md#operation-modes-and-selective-metadata-save) to distinguish offline `draft`, selective remote `save`, complete `ready` package and explicitly authorized `submit`. Confirmed general text may be eligible for save while screenshots/build/legal remain deferred, but only after exact identity, operation authority, field requirements, form-wide diff and public-effect checks. Save is not necessarily private staging. Unknown values must not erase existing remote copy.

The source ledger stays here; the future save execution journal belongs in `.artifacts/appstore-metadata/<issue>/<attempt>/`, **outside** this directory and canonical Issue evidence. See the [synthetic record and resume algorithm](../docs/agent-contracts/appstore-submission.md#separate-save-journal-and-resume) for relative source paths/digests, per-locale outcomes and readback. Preserve source/user edits and prior attempts. Reauthenticate, rehash sources and reread all saved forms when resuming; local flags never prove remote completion. Record failed/unknown/blocked/deferred rows separately, not as whole-batch success.

#52 documents this route; the [dedicated save implementation](../specs/architecture.md#92-原稿保存と正式提出の分離) is still future work. Until it exists, prepare offline copy/diffs only and do not bypass the full-release entrypoint. No new YAML keys, executable save flag or partial-result input to `record-section.sh` is introduced. Do not place active save journals in a sealed package or modify its hash exclusions. Ready/submit still require all release assets, declarations, legal approval, release audit and explicit submission authority; neither draft nor saved text may set checklist completion or become a release result.
