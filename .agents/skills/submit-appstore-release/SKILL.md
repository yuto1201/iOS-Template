---
name: submit-appstore-release
description: Route App Store draft-only or metadata-save requests separately from full submission; execute and resume submission only from an exact sealed, audited release package with account preflight and readback.
---

# Submit App Store Release

Codex and Claude may perform this authenticated external workflow. The Issue must name the selected executor, which uses the same configured Team/App preflight and secret-handling rules.

## Choose the requested mode

Read [operation modes and selective metadata save](../../../docs/agent-contracts/appstore-submission.md#operation-modes-and-selective-metadata-save) before treating “enter the text” or “save for later” as a release request.

- `draft`: follow the contract's existing field inventory and source preparation; return reviewed copy, unresolved fields and a proposed diff without remote writes. Keep screenshots deferred when requested; do not invoke capture/upload or seal a partial package.
- `save`: use [`save-appstore-metadata`](../save-appstore-metadata/SKILL.md) and its public `scripts/save-appstore-metadata.sh` entrypoint only for the six allowed confirmed text fields. It requires the exact Issue operation, ownership, fresh preflight, source and baseline digests, publication-impact approval for promotional text, and full-form readback. Keep its partial journal separate from the release package/result. Do not use manual browser input as a fallback.
- `ready`: use [`prepare-appstore-assets`](../prepare-appstore-assets/SKILL.md) only when complete candidate inputs and screenshot scope are available. A partial save record is not release evidence.
- `submit`: continue below only after the exact package is sealed/audited and the user has explicitly authorized submitting this candidate, with the Issue's declared operations and executor. Permission to draft/save does not authorize submission.

Do not infer that Save means private staging or make privacy/legal/price decisions to unblock ordinary copy. The detailed save contract owns those boundaries. A complete release uses the schema-2 ordered section result below.

## Entry gates

For the complete release workflow below, require completed English/iPad adaptation and a schema-2 manifest bound to passed full application verification at the exact candidate Head and Bundle ID. Old manifests must be resealed. Before any authenticated write in this workflow, and again on its resume, check that proof:

```sh
ruby tools/lib/release-verification.rb "$PWD" "$PACKAGE_MANIFEST" "$HEAD_SHA" "$BUNDLE_ID"
```

This read-only check does not authorize submission or replace account, legal, build, package or independent screenshot requirements. record-section.sh rechecks the same proof before publishing each result.

If support, privacy, or terms URLs are part of the candidate, also require the exact live `publication-verification.json` produced by the `prepare-appstore-assets` legal-page handoff. It must be `verified` and `appStoreEligible: true`, and its source digests, routes, Web-AppLibrary Issue, user approval references, and public checks must match the sealed package. Reject `fixture-validated`, a changed source/URL, a login-only/non-200 page, or a record from another candidate. This record verifies publication; it does not replace the user's legal approval or authorize submission.

For a phase-aware submission, also require the exact Phase 6 `Release-phase binding:` and revalidate the same `.artifacts/issues/<issue>/<head>/evidence-applicability.json` consumed by preparation, review, PR, and pre-merge. `reuse` proves applicability of the Phase 5 run; it does not claim a new run. `targeted-reverify` and `expanded-verification` require their later target proof. Package integrity, Goldie/iPad screenshot audit, privacy, legal, configured account/target, remote readback, upload, and explicit submit authorization are always Phase 6-specific. A sealed unbound Issue stays `legacy-unbound`; never invent or retrofit a record.

1. Read the release Issue operation declarations, `docs/AUTHORITY.md`, `docs/agent-contracts/appstore-submission.md`, and `${VERSION}-package.json`.
2. Require the Issue to authorize the exact App Store operation and executor. Verify the active authenticated session belongs to the configured Team and the remote App, Bundle ID, version, and build are exact. Never use another visible Team.
3. Run `tools/provider-preflight.sh --executor "$EXECUTOR" --issue "$ISSUE" app-store --version "$VERSION" --operation "$OPERATION"` for each section's declared operation. App information, localization, and screenshots require `appstore.update_metadata`; build selection and submission require `appstore.submit_review`; privacy and review information require `appstore.inspect_app`. Require fresh healthy production evidence whose account and target equal `Config/ownership.yml`.
4. Recompute the package, build, release-audit, screenshot-manifest, and prepared-manifest digests. Refuse any mismatch. A first-publication package must contain the user legal-approval digest.
5. Resolve review contact credentials only at child-process scope from Keychain. Never place a secret value in the browser transcript, command arguments, result JSON, Issue, PR, screenshot, or AI prompt.

## Section workflow

Process these sections in order:

1. app information — guarded `asc` API
2. English and Japanese localization — guarded `asc` API, reusing the selective-save form baseline/save/readback path
3. privacy declarations — selected executor's authenticated browser
4. exact manifest screenshots — guarded `asc` API, only when the remote set is empty or already identical
5. tested build selection — guarded `asc` API, requiring the #133 VALID processing readback journal
6. review information — selected executor's authenticated browser; `asc` 5.4.0 requires secret contact/demo values in argv
7. submission for review — guarded `asc` API, only with the candidate-bound explicit approval reference

For API sections, invoke `ruby tools/lib/appstore-release-sections.rb` with the exact Issue, Team/App/Bundle/version/build, package Head/digest, release audit, #133 build journal, section and current time. The tool enters only sealed package values, uses the guarded runner, reads back the remote section and passes its sanitized digest and `asc://` reference to `scripts/record-section.sh`. For submission, the Issue's `appstore.submit_review` block must require approval and supply `--approval-reference "approval: user-approval://..."` matching its exact User approvals reference. For browser sections, enter sealed values in the selected executor's authenticated browser, compare the browser readback with the sealed source, then supply `--browser-readbacks` as schema 1 with `sections.{privacy,review-information}` entries containing `checkedAt`, an App-scoped `asc://` remote reference, sanitized `readBackDigest`, and exact `sealedSourceDigest`. Refresh `checkedAt` and readback for every resume; the tool rejects evidence older than one hour. Do not put review credentials or private contact values in that file. `record-section.sh` requires `--readback-source api|browser` and checks the section route, operation-specific preflight, package/audit/full verification, order and schema-2 result.

## Resume and interruption

The only resume source for this complete release workflow is `App Store/submission/${VERSION}-result.json`; a metadata-save journal cannot replace it. When it exists:

1. Re-run personal Team/App/Bundle/version/build preflight for the next section's operation.
2. The section tool re-reads every recorded API section through the guarded runner and compares it with the sealed source and recorded digest/reference.
3. The selected executor re-reads every recorded browser section and supplies fresh sanitized browser readback evidence. The tool checks those digests/references and sealed-source digests before proceeding.
4. The tool passes `--resume-readback yes` to `record-section.sh` only after every prior comparison succeeds. A local completion flag is insufficient.

Record sections in order and use `--submit-for-review yes` only for the final `submission` section. An existing schema-1 result is legacy and stops; create a new result for a new candidate. The result contains sanitized references and digests, never field values or credentials. If App Store Connect shows another Team, App, version, build, unexpected remote value, agreement, pricing, legal question, paid action, or changed package, stop without submitting and report the precise blocker.

Successful field entry is not submission success. After the final action, read back the remote review status and retain the sanitized result. Do not claim Apple approval; later App Review status changes are separate observations.
