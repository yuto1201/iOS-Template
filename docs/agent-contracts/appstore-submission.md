# App Store submission contract

This contract separates release readiness from authenticated App Store Connect mutation. A prepared package does not authorize submission.

## Authority and entry conditions

- Codex and Claude may execute App Store Connect, authenticated browser, upload, signing-account, and provider operations when named as the Issue executor.
- The release Issue must declare each intended production operation, including inspection, section updates, screenshot upload, build selection, and submission for review. No skill invocation broadens Issue authority.
- Immediately before each mutation batch, the selected executor verifies the active configured Team, App, Bundle ID, version, and build against `Config/ownership.yml` and the sealed package. Another identity or ambiguous target is a hard stop.
- `prepare-appstore-assets` must have produced `${VERSION}-package.json` for the exact source SHA and build digest, with current Apple requirements and an approved release-auditor result.
- A first public release additionally requires the user's package-bound confirmation of the privacy policy and terms. AI review cannot grant legal approval.

## Immutable inputs

The prepared manifest binds the Bundle ID, version, source SHA, build digest, package tree digest, requirement cache, screenshot manifest, release audit, and first-publication approval. Recompute them at workflow start and resume. Any mismatch invalidates all unperformed sections; never repair a mismatch by editing the manifest or remote values.

Secrets and App Store session data are not immutable package inputs. Resolve a required review credential from Keychain only into a child process or the exact authenticated form field. Never put secret values in tracked files, browser transcripts, screenshots, logs, evidence, Issue/PR text, or AI prompts.

## Ordered remote transaction

Process `app-information`, `localization`, `privacy`, `screenshots`, `build`, `review-information`, and `submission` in that order. For each section:

1. Recheck personal Team/App/version/build identity and local digests.
2. Enter only sealed values and upload only screenshot-manifest bytes.
3. Save the remote section.
4. Read the resulting remote values back from App Store Connect.
5. Compare them to the sealed source and record only a sanitized remote reference and readback digest.

Do not continue when App Store Connect presents an unexpected agreement, price, legal claim, destructive replacement, paid action, target, or remote value. Treat transport ambiguity as unknown state and read back before retrying; never submit a duplicate action speculatively.

## Result and resume

`App Store/submission/${VERSION}-result.json` is an ordered, sanitized journal. Each entry contains the section ID, `verified` status, an `asc://` remote reference, SHA-256 readback digest, `app-store-connect` source, and verification time. It contains no field values or credentials.

On resume, the selected executor must authenticate again, rerun preflight, recompute all immutable inputs, and read back every recorded remote section. `scripts/record-section.sh --resume-readback yes` is valid only after that comparison. Local status alone is not evidence of remote completion.

The final journal status `submitted` means only that the exact candidate was submitted for review and read back. It does not mean Apple approved or released the app. App Review and release status are later observations and must be reported separately.
