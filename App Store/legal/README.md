# Legal and support page handoff

`App Store/legal/` contains the app-owned legal/support sources. Draft placeholders are not approved publication inputs.

For a Web-yutodev handoff, maintain one confirmed source for each `en-US` / `ja` × `support` / `privacy` / `terms` pair. The public pages are fixed at `https://yutodev.com/apps/<appSlug>/support/`, `/privacy/`, and `/terms/` (D-105, updating D-072), with `<appSlug>` from `Config/app-identity.json`, and each page shows both its Japanese and English text. The request records each source's exact path, digest and approval reference, and the three routes. See the [handoff contract](../../.agents/skills/prepare-appstore-assets/templates/legal-page-handoff.md).

The local entrypoint has four non-authenticated operations:

```sh
tools/prepare-appstore-legal-handoff.sh render --repo-root "$PWD" --request REQUEST.json --output HANDOFF.md
tools/prepare-appstore-legal-handoff.sh record-issue --repo-root "$PWD" --request REQUEST.json --prompt HANDOFF.md --readback READBACK.json --output WEB-ISSUE.json --now UTC
tools/prepare-appstore-legal-handoff.sh verify-publication --repo-root "$PWD" --request REQUEST.json --prompt HANDOFF.md --issue-record WEB-ISSUE.json --publication RETURN.json --output PUBLICATION-VERIFICATION.json --now UTC
tools/prepare-appstore-legal-handoff.sh migrate-legacy-handoff --repo-root "$PWD" --request OLD-REQUEST.json --prompt OLD-HANDOFF.md --issue-record OLD-WEB-ISSUE.json --readback READBACK.json --request-output REQUEST.json --prompt-output HANDOFF.md --issue-record-output WEB-ISSUE.json --now UTC
```

The request/output schemas are fail-closed and reject unknown fields, path escapes/symlinks, source digest mismatch, non-confirmed documents, unsupported locale/kind sets, altered Issue readback, any other host or route, a route that does not match `appSlug`, authentication/non-200 responses, changed public text, a page missing either language, and missing interlinks. Existing outputs are never overwritten.

Creating the Web-yutodev Issue is a separate authenticated operation governed by the source Issue and external-operations preflight. The user controls prompt forwarding and legal/publication approval. A fixture result is test evidence only; only a live `verified` result with `appStoreEligible: true` can support App Store URL readiness.

## Handoffs recorded before 2026-11-14 (D-105)

Until 2026-11-14 the pages lived at `app.yutodev.com` and the Web repository was `yuto1201/Web-AppLibrary`. That host now only 301-redirects to `yutodev.com` and the repository was renamed to `yuto1201/Web-yutodev`, so a request with `"webHost": "app.yutodev.com"` or an Issue record for `Web-AppLibrary` is rejected by `render`, `record-issue`, and `verify-publication`. Do not edit those files by hand and do not create a second Web Issue. Rewrite them once:

1. Read back the same Web Issue number from `yuto1201/Web-yutodev` (GitHub keeps the number across the rename) and save `number`, `url`, `title`, `body`, and `state` as `READBACK.json`. Its body must still be the legacy prompt byte for byte; a closed Issue is accepted.
2. Run `migrate-legacy-handoff` with the old request, prompt, and Issue record. It checks that the old prompt is the exact legacy rendering of the old request, that the old record matches both digests, and that the readback is the same Issue under the new repository, then writes a new request with `"webHost": "yutodev.com"`, a prompt rendered for the current host and repository, and an Issue record for `yuto1201/Web-yutodev`. The new record keeps `migratedFrom` with the old digests, the old Issue URL, and the readback state. Existing files are never overwritten, so write the outputs to new paths and commit them next to the old files.
3. Use the three new files with `verify-publication`. The public pages must answer at `https://yutodev.com/apps/<appSlug>/...` with no redirect.
