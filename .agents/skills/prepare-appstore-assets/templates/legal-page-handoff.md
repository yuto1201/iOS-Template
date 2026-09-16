# Legal-page handoff contract

Use this contract when confirmed App Store legal/support sources must be implemented in `yuto1201/Web-AppLibrary`.

1. Keep the app repository's confirmed English and Japanese support, privacy, and terms documents as the source of truth. Record their exact SHA-256 digests, approval references, and user-approved public routes.
2. Generate the copy-ready body with `tools/prepare-appstore-legal-handoff.sh render`. The generated body fixes the target repository, source Issue/Head, facts, routes, exact localized text, `1 Issue = 1 Branch = 1 PR`, public checks, and return contract.
3. Before creating anything, search open and closed Issues for the same app, documents, source Issue, and handoff ID. Creating an Issue requires an Issue contract that authorizes `github.create_issue`, the selected executor, and the exact target `yuto1201/Web-AppLibrary`.
4. Immediately before creation, use the external-operations preflight to verify the configured GitHub account and exact target. Create at most once. If the result is missing or ambiguous, search/read back before retrying.
5. Read back the created Issue's number, URL, title, body, and state. Pass that readback to `record-issue`; a different repository or altered body is rejected.
6. The user forwards the prompt to the Web implementation agent and retains final approval of legal text and publication. The agent must not infer either action from an Issue, PR, deployment, or AI review.
7. After the Web task returns, pass its deployment reference, exact URLs, source digests, and user approval references to `verify-publication`. Live verification requires HTTPS on the approved host, no redirect, HTTP 200 without credentials, matching approved source text, locale identity, and same-locale support/privacy/terms interlinks.

`--response-fixture` exists only for deterministic regression tests. Its `fixture-validated` result is not App Store evidence and is never App Store eligible. Only a live `verified` `publication-verification.json` for the exact source and routes may be consumed by release preparation or submission.

This workflow does not edit Web-AppLibrary, deploy Vercel, change Cloudflare/DNS, approve legal text, publish a page, update App Store Connect, or submit an app.
