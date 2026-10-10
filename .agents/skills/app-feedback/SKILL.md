---
name: app-feedback
description: Use when porting, testing, or provisioning the standard anonymous in-app feedback (D-076) — the per-app Cloudflare Worker template that files issues in the app's private feedback repository through the shared GitHub App, and the tool that prepares a new app's repository, Worker and host.
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

## Shared GitHub App (the user, once)

The user creates one GitHub App for all apps and keeps its credentials on this Mac. The AI never creates the App, installs it, issues its key, or types, prints, or records a credential value.

1. GitHub > Settings > Developer settings > GitHub Apps > New GitHub App. Repository permissions: Issues: Read and write, nothing else (Metadata: Read-only is automatic). Webhook: off. Where can this GitHub App be installed: Only on this account.
2. Install it on the account with **Only select repositories**. Never choose All repositories: the installation must reach the feedback repositories only.
3. Generate a private key. Move the downloaded `.pem` to `~/Library/Application Support/iOS-Template/secrets/github-<login>/feedback-github-app.pem`, where `<login>` is the lowercased `github.login` of `Config/ownership.yml`. Keep the two directories at mode `0700` and the file at `0600`, with one copy only, like the App Store Connect key (D-066). The tool converts it to PKCS#8 in memory.
4. Store the App ID and the installation ID (the number at the end of the installation's settings URL) in the Keychain, each as one line on standard input, never as an argument:

```bash
tools/secret-store.sh put --app github-<login> --service feedback-github-app --environment production --key app-id
```

```bash
tools/secret-store.sh put --app github-<login> --service feedback-github-app --environment production --key installation-id
```

macOS may ask once whether `security` can read these items; the user answers.

## Provisioning a new app

Run in the app's repository after Identity bootstrap ([product §3.1](../../../specs/product.md#31-新しいアプリの開始順序), step 5), in an Issue of that app. `tools/provision-app-feedback.sh` works on the repository it belongs to:

- It reads `Config/app-identity.json` and `Config/ownership.yml`: the repository `<login>/<moduleName>-feedback`, the Worker `<appSlug>-feedback`, and a rate-limit namespace derived from the Cloudflare account ID and the Worker name. `cloudflare.target` must already be the Worker name.
- Before anything changes, it checks that `gh` is signed in as `github.login`, that `wrangler` (pinned version, run with `npx`) can use `cloudflare.accountId`, that the shared App credentials are stored as above, and that the App and its installation have only Issues: Read and write and only selected repositories.

| Command | What it does |
| --- | --- |
| `plan` | Reads only. Prints the plan, its `planDigest`, and what already exists. |
| `apply --plan-digest <digest>` | Refuses unless the plan still has the approved digest. Then writes `Services/feedback-worker/` and runs its tests, creates the private repository and the missing labels (`feedback`, `bug`, `request`, `other`), stops with exit 3 until the shared App is installed on the repository, deploys the Worker and takes its host from what Cloudflare reports, registers its three secrets from standard input, writes the host to `<moduleName>/Features/Feedback/FeedbackEndpoint.json`, and records `Config/app-feedback.json` (no secret). |
| `check-delivery --plan-digest <digest>` | Runs `apply` for the same approved plan, then sends one real submission to the host Cloudflare just reported and confirms that the issue appeared with the `feedback` and `other` labels. |

Every stage checks what exists first, so a rerun creates no second repository, label or secret. Each run deploys the same Worker again, because the host is read only from Cloudflare and never trusted from the repository's files: a record or endpoint file that names another host stops the tool. It registers only the Worker secrets that are missing; replacing a registered secret, such as after a new signing key, is a separate operation the user approves. A repository that is public or archived, a Worker directory, host or record that differs from the plan, a failure, or an unreadable answer stops the tool without overwriting anything.

Who does what:

1. The AI sets `cloudflare.target` to `<appSlug>-feedback`, runs `plan`, and shows the user the plan and its digest.
2. The user approves that digest in the app's Issue. That Issue uses the `strict` profile and declares, with `Approval required: yes`, `github.create_repository` for the feedback repository and its labels and `cloudflare.deploy` for the Worker and its secrets. Declare no other Cloudflare operation: the pre-merge gate takes one Cloudflare evidence file per Issue.
3. The AI runs `apply`. When it stops for the installation, the user adds the repository to the shared App (Configure > Repository access > add the repository > Save), and the AI runs `apply` again with the same digest.
4. After the user approves sending one real submission, the AI runs `check-delivery` with the same digest.
5. The AI commits `Services/feedback-worker/`, the endpoint file, `Config/app-feedback.json` and `Config/ownership.yml` in the Issue's PR. Before merging, it publishes the Cloudflare evidence with `tools/provider-preflight.sh --executor <executor> --issue <number> cloudflare --target <appSlug>-feedback --operation cloudflare.deploy`; that check signs in nothing and reads only whether the `wrangler` session can use the configured account.

The user signs in `gh` and `wrangler` (`npx wrangler@<pinned version> login`); the AI never signs in or switches accounts.

## Tests

The Worker tests use Node 24 or later with `node:test` and no packages: run `node test/all.ts` inside the Worker directory. In this repository, `tools/tests/test-feedback-worker.sh` runs them on the template and on a copy written with sample values, and checks the placeholder contract and that no app-specific value remains. `tools/tests/test-app-feedback-provision.sh` runs the provisioning tool in a sample app with fake `gh`, `wrangler`, `security` and `curl`.

## Boundaries

- Secrets (`GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_SIGNING_PKCS8`) live only in Worker secrets and in the places above. The tool passes them to child processes on standard input only: never as arguments, and never to `wrangler.jsonc`, the app, `.dev.vars` (ignored by Git), a log, an Issue, or a PR.
- The skill and its template perform no external operation. Creating the feedback repository, registering secrets, deploying, and setting the app's host belong to the provisioning tool, run in each app's Issue after the user approves those operations. Creating the shared GitHub App, installing it, and issuing its signing key are the user's.
- The app side (`Features/Feedback/`) sends to `https://<host>/v1/feedback` and hides its entry until the host is set.
