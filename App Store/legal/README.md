# Legal and support page handoff

`App Store/legal/` contains the app-owned legal/support sources. Draft placeholders are not approved publication inputs.

For a Web-AppLibrary handoff, maintain one confirmed source for each `en-US` / `ja` × `support` / `privacy` / `terms` pair. The request records the exact source path and digest, approval reference, public host and user-approved route. See the [handoff contract](../../.agents/skills/prepare-appstore-assets/templates/legal-page-handoff.md).

The local entrypoint has three non-authenticated operations:

```sh
tools/prepare-appstore-legal-handoff.sh render --repo-root "$PWD" --request REQUEST.json --output HANDOFF.md
tools/prepare-appstore-legal-handoff.sh record-issue --repo-root "$PWD" --request REQUEST.json --prompt HANDOFF.md --readback READBACK.json --output WEB-ISSUE.json --now UTC
tools/prepare-appstore-legal-handoff.sh verify-publication --repo-root "$PWD" --request REQUEST.json --prompt HANDOFF.md --issue-record WEB-ISSUE.json --publication RETURN.json --output PUBLICATION-VERIFICATION.json --now UTC
```

The request/output schemas are fail-closed and reject unknown fields, path escapes/symlinks, source digest mismatch, non-confirmed documents, unsupported locale/kind sets, altered Issue readback, unapproved routes, authentication/non-200 responses, changed public text, and missing interlinks. Existing outputs are never overwritten.

Creating the Web-AppLibrary Issue is a separate authenticated operation governed by the source Issue and external-operations preflight. The user controls prompt forwarding and legal/publication approval. A fixture result is test evidence only; only a live `verified` result with `appStoreEligible: true` can support App Store URL readiness.
