---
name: app-feedback
description: Use when porting, testing, or provisioning the standard anonymous in-app feedback (D-076) — the per-app Cloudflare Worker template that files issues in the app's private feedback repository through the shared GitHub App.
---

# App Feedback

Every app ships anonymous in-app feedback ([product §4.5](../../../specs/product.md#45-アプリ内フィードバック), [architecture §7.4](../../../specs/architecture.md#74-アプリ内フィードバック境界), D-076). The app sends a submission to its own Cloudflare Worker; the Worker files an issue in the app's private repository `<GitHub login>/<moduleName>-feedback` through one GitHub App shared by all apps. The app holds no secret.

## Worker template

`templates/feedback-worker/` is the Worker every app deploys. It validates the 7-field payload (8KB), limits each sender to 1 per 60 seconds and the Worker to 100 issues per UTC day, never stores or logs the sender address or the submission, and exchanges the GitHub App credentials for an installation token scoped to the app's feedback repository only.

The template is not deployable as is. `wrangler.jsonc` holds the placeholders listed in [`worker-values.json`](worker-values.json); write every one with the app's value and leave no `{{` behind:

| Placeholder | Value |
| --- | --- |
| `{{WORKER_NAME}}` | `<appSlug>-feedback` |
| `{{GITHUB_REPOSITORY}}` | `<GitHub login>/<moduleName>-feedback`; the token scope and User-Agent follow its name |
| `{{RATE_LIMIT_NAMESPACE_ID}}` | A positive integer unique in the Cloudflare account, so apps never share per-sender counts |

A Worker whose `GITHUB_REPOSITORY` is still a placeholder or malformed refuses before any GitHub call.

## Tests

The Worker tests use Node 24 or later with `node:test` and no packages: run `node test/all.ts` inside the Worker directory. In this repository, `tools/tests/test-feedback-worker.sh` runs them on the template and on a copy written with sample values, and checks the placeholder contract and that no app-specific value remains.

## Boundaries

- Secrets (`GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_SIGNING_PKCS8`) live only in Worker secrets. Never write them to `wrangler.jsonc`, the app, `.dev.vars` (ignored by Git), a log, an Issue, or a PR.
- This skill performs no external operation. Creating the feedback repository, registering secrets, deploying, and setting the app's host belong to the provisioning tool, run in each app's Issue after the user approves those operations. Creating the shared GitHub App, installing it, and issuing its signing key are the user's.
- The app side (`Features/Feedback/`) sends to `https://<host>/v1/feedback` and hides its entry until the host is set.
