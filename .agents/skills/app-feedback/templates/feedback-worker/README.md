# Feedback Worker

Receives anonymous feedback from the app and files it as an issue in the app's private feedback repository, `GITHUB_REPOSITORY` in `wrangler.jsonc` (template decision D-076). The iOS-Template `app-feedback` skill keeps the template; the provisioning tool writes this directory with the app's values.

## API

`POST /v1/feedback` with a JSON body:

```json
{ "category": "bug", "body": "…", "appVersion": "1.1", "build": "5", "osVersion": "27.0", "deviceModel": "iPhone18,1", "locale": "ja_JP" }
```

| Status | Body | Meaning |
| --- | --- | --- |
| 201 | `{"status":"created"}` | Issue created |
| 400 | `{"error":"invalid"}` | Unknown field, bad value, body over 2000 characters, or request over 8KB |
| 404 / 405 | `{"error":"not_found"}` / `{"error":"method_not_allowed"}` | Wrong path or method |
| 429 | `{"error":"rate_limited"}` | Same sender within about 60 seconds (best effort: the Cloudflare rate limit is approximate and per location), or 100 issues already today (UTC, exact) |
| 502 | `{"error":"upstream"}` | GitHub or the GitHub App authentication failed |
| 503 | `{"error":"unavailable"}` | The daily counter failed; nothing was created |

`DAILY_ISSUE_LIMIT` (in `wrangler.jsonc`) caps issues per UTC day; `"0"` closes intake. GitHub calls give up after 10 seconds. Failures log only a status or an error name, never the submission or the sender address. A `GITHUB_REPOSITORY` that is still a template placeholder, or malformed, fails before any GitHub call.

The sender address is used only as the rate-limit entry (IPv6 senders by their /64 prefix). Submissions are never logged, and Workers invocation logs are turned off in the config so Cloudflare does not keep request details such as the sender address. Bodies over 8KB are rejected, including streamed bodies without Content-Length, which are cut off as soon as they pass the cap.

## Test

Requires Node 24 or later. No packages to install.

```bash
node test/all.ts
```

## Settings

| Setting | Where | Value |
| --- | --- | --- |
| Worker name | `wrangler.jsonc` `name` | `<appSlug>-feedback` |
| Feedback repository | `wrangler.jsonc` `vars.GITHUB_REPOSITORY` | `<GitHub login>/<moduleName>-feedback` (private); the installation token and User-Agent follow its name |
| Rate-limit namespace | `wrangler.jsonc` `ratelimits[0].namespace_id` | A positive integer unique in the Cloudflare account, so apps never share per-sender counts |
| Daily limit | `wrangler.jsonc` `vars.DAILY_ISSUE_LIMIT` | `100` |
| GitHub App | Worker secrets `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_SIGNING_PKCS8` | The shared App (Issues: Read and write only, no webhook), installed on the feedback repository |

Secrets live only in Worker secrets. Never put them in `wrangler.jsonc`, the app, `.dev.vars` (ignored by Git), a log, an Issue, or a PR.

## Deploy

The provisioning tool does these steps for a new app, after the user approves the external operations in that app's Issue:

1. Create the private feedback repository with labels `feedback`, `bug`, `request`, `other`.
2. Confirm the shared GitHub App is installed on that repository (the user installs it on GitHub).
3. Register the three Worker secrets (the signing key converted to PKCS#8) without printing them.
4. Deploy with the Workers config in this directory, then send one real submission and confirm the issue appears.
5. Put the deployed host name only (`<worker name>.<subdomain>.workers.dev`, no scheme or path) into the app's feedback host setting; the app adds `https://` and `/v1/feedback`.
