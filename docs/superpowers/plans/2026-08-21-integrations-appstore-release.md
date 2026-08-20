# Integrations and App Store Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Codex-only secret handling and optional Supabase, ElevenLabs, Cloudflare, and App Store workflows without adding unused SDKs to the template app.

**Architecture:** Provider workflows remain dormant shared skills until an app specification activates them. Secrets live in macOS Keychain or the approved external directory, provider adapters run only through Codex after identity preflight, and `App Store/` contains only sanitized submission source material.

**Tech Stack:** macOS Keychain, POSIX shell, Supabase CLI, ElevenLabs CLI/API skill, Cloudflare tools, App Store Connect, Codex browser control, SwiftUI/XCUITest screenshots

**Spec:** `specs/product.md`, `specs/architecture.md`, and `docs/security.md`

## Global Constraints

- Claude never reads personal secrets or runs authenticated provider operations.
- No secret value is written to Git, Issue, PR, log, screenshot, or AI prompt.
- Supabase is added only after an app specification requires remote database, authentication, synchronization, or storage.
- `supabase/migrations/*.sql` is the only schema source of truth.
- ElevenLabs is used only when audio is an acceptance criterion.
- Music entitlement failure is reported once and is not retried.
- App Store legal text is generated from the app's actual data practices and requires user confirmation before first publication.
- Browser submission uses Codex and the user's personal App Store Connect session.

---

## File map

| Path | Responsibility |
| --- | --- |
| `tools/secret-store.sh` | Store and check secrets without printing values |
| `tools/run-with-secret.sh` | Inject one Keychain value into one child process |
| `tools/provider-preflight.sh` | Verify provider identity and target without exposing credentials |
| `.agents/skills/supabase-ops/` | Conditional migration-first Supabase workflow |
| `.agents/skills/ios-audio-assets/` | Conditional ElevenLabs generation and asset validation |
| `.agents/skills/prepare-appstore-assets/` | Generate and validate submission sources |
| `.agents/skills/submit-appstore-release/` | Codex-only browser submission and evidence |
| `App Store/` | Sanitized metadata, legal, review, screenshots, notes, and submission record |
| `tools/validate-appstore-package.sh` | Validate required fields, locales, images, and privacy consistency |
| `tools/tests/` | Fake Keychain/provider and package tests |

### Task 1: Keychain-backed secret execution

**Files:**
- Create: `tools/secret-store.sh`
- Create: `tools/run-with-secret.sh`
- Create: `tools/tests/test-secret-store.sh`
- Create: `tools/tests/fixtures/security`

**Interfaces:**
- `secret-store.sh put --app template-app --service elevenlabs --environment production --key api-key` reads one-line values from stdin
- `secret-store.sh check` reports only present or absent
- `run-with-secret.sh --service-name ios-template/template-app/elevenlabs/production/api-key --env ELEVENLABS_API_KEY -- command arguments...`

- [ ] **Step 1: Write fake-security tests**

Use a fixture `security` command and assert canonical Service names, stdin-only secret input, no value in process arguments, no value in stdout/stderr, missing-secret failure, and child-only environment injection.

- [ ] **Step 2: Run tests**

Run: `bash tools/tests/test-secret-store.sh`  
Expected: non-zero because the tools are absent.

- [ ] **Step 3: Implement Service-name validation**

Require lowercase app, service, environment, and key segments matching `[a-z0-9-]+`. Build `ios-template/${app}/${service}/${environment}/${key}` internally and reject callers that attempt path separators or empty segments.

- [ ] **Step 4: Implement put and check**

`put` reads exactly one line from stdin and calls Keychain without echoing it. `check` suppresses Keychain output and prints a JSON object containing only Service name and boolean presence. Do not add a command that prints the secret.

- [ ] **Step 5: Implement child-process injection**

Read the secret into a shell variable, assign and export the validated environment variable in the current shell, then call `exec "$@"`. Do not invoke `env NAME=value`, because that would expose the secret in the intermediate process argv. Unset the shell variable on error. Reject tracing modes and commands containing shell evaluation strings.

- [ ] **Step 6: Define multi-line private-key handling and run tests**

Keep App Store Connect `.p8` keys out of the one-line Keychain interface. Store them only under `~/Library/Application Support/iOS-Template/secrets/${APP_SLUG}/` with directory mode `0700` and file mode `0600`; a Codex-only file wrapper validates the exact path and passes it directly to the child process. Confirm the existing `.gitignore` rules cover local config, environment files, private keys, profiles, and generated secret staging directories.

Run: `bash tools/tests/test-secret-store.sh`  
Expected: all leakage and validation cases pass.

- [ ] **Step 7: Commit**

```bash
git add tools/secret-store.sh tools/run-with-secret.sh tools/tests
git commit -m "feat: add non-printing Keychain secret execution"
```

### Task 2: Provider identity preflights

**Files:**
- Create: `tools/provider-preflight.sh`
- Create: `tools/tests/test-provider-preflight.sh`
- Create: `tools/tests/fixtures/providers/`

**Interfaces:**
- `provider-preflight.sh github --target yuto1201/iOS-Template`
- `provider-preflight.sh supabase --environment production`
- `provider-preflight.sh cloudflare --target example.com`
- `provider-preflight.sh elevenlabs --operation sound-effect`
- `provider-preflight.sh app-store --version 1.0`
- Outputs sanitized account and target JSON only

- [ ] **Step 1: Write fake-provider tests**

Test correct personal identity, company identity rejection, target mismatch, unhealthy Supabase project, unknown Cloudflare account, ElevenLabs entitlement failure, and App Store Team mismatch.

- [ ] **Step 2: Implement explicit provider adapters**

Use one case branch per provider. Parse real responses into account, target identifiers, health, environment, operation, and timestamp. Never pass through raw provider output.

- [ ] **Step 3: Enforce expected personal ownership**

Read every expected login, Organization, Project Ref, Account ID, Team ID, and Bundle ID from `Config/ownership.yml`. GitHub uses the committed personal login. Each app-specific provider operation requires its field to be non-null. A mismatch or missing app-specific value exits before any mutation.

- [ ] **Step 4: Run tests and commit**

Run: `bash tools/tests/test-provider-preflight.sh`  
Expected: all identity and mismatch cases pass.

```bash
git add tools/provider-preflight.sh tools/tests
git commit -m "feat: verify personal provider targets"
```

### Task 3: Conditional Supabase workflow

**Files:**
- Create: `.agents/skills/supabase-ops/SKILL.md`
- Create: `.agents/skills/supabase-ops/templates/config.toml`
- Create: `.agents/skills/supabase-ops/templates/seed.sql`
- Create: `.agents/skills/supabase-ops/scripts/validate-migrations.sh`
- Create: `.claude/skills/supabase-ops` as a relative symlink
- Create: `tools/tests/test-supabase-skill.sh`

**Interfaces:**
- Skill activation creates `supabase/config.toml`, `supabase/migrations/`, and safe `supabase/seed.sql`
- Remote link, pull, push, and advisors delegate to Codex

- [ ] **Step 1: Write skill-policy tests**

Assert no root `supabase/` exists before activation. Validate templates contain no secret, migration naming uses UTC timestamp plus snake-case description, seed is synthetic, and no separate `schema.sql` is created.

- [ ] **Step 2: Write the migration validator**

Require timestamped SQL files, reject Secret Key and `service_role` patterns, require RLS enablement and Policy statements for each new public table, and reject `db reset --linked` in tracked scripts.

- [ ] **Step 3: Write the skill**

The skill confirms the app specification requires Supabase, copies safe templates, has Claude author local migrations and run `supabase db reset --local`, and delegates `link`, `pull`, `push`, remote advisors, and remote SQL to Codex after provider preflight.

- [ ] **Step 4: Define remote apply gates**

Codex reports Organization, Project, Project Ref, environment, pending migrations, and dry-run result. Destructive production SQL requires explicit user approval. Production `db reset --linked` is always refused.

- [ ] **Step 5: Run tests and commit**

Run: `bash tools/tests/test-supabase-skill.sh`  
Expected: all activation and policy cases pass.

```bash
git add .agents/skills/supabase-ops .claude/skills/supabase-ops tools/tests
git commit -m "feat: add optional migration-first Supabase workflow"
```

### Task 4: Conditional ElevenLabs audio assets

**Files:**
- Create: `.agents/skills/ios-audio-assets/SKILL.md`
- Create: `.agents/skills/ios-audio-assets/templates/audio-manifest.yml`
- Create: `.agents/skills/ios-audio-assets/scripts/validate-audio.sh`
- Create: `.agents/skills/ios-audio-assets/scripts/check-elevenlabs-capability.sh`
- Create: `.claude/skills/ios-audio-assets` as a relative symlink
- Create: `tools/tests/test-audio-skill.sh`

**Interfaces:**
- Consumes: an Issue acceptance criterion and repository asset destination
- Uses: installed `generating-elevenlabs-audio` procedure through Codex
- Produces: audio file plus sanitized manifest containing prompt, model, duration, loop, license note, hash, and generation date

- [ ] **Step 1: Write policy and manifest tests**

Test required purpose, duration range, loop boolean, output path, supported audio format, file hash, repository-local or user-scope Codex capability discovery, and rejection of API keys. Test that music `paid_plan_required` becomes one `blocked:ops` result without retry.

- [ ] **Step 2: Implement audio validation**

Use `afinfo` to verify readable duration and format. For looped assets, inspect leading and trailing amplitude with an available audio analysis tool and fail an audible discontinuity threshold defined in the Issue.

- [ ] **Step 3: Write the shared skill**

Claude prepares the prompt and local integration code but delegates generation to Codex. Codex resolves `generating-elevenlabs-audio` from the Codex-visible `.agents/skills` user or repository scope before calling it; if absent, return `blocked:ops` rather than assuming a Claude-only skill. Codex runs identity preflight, invokes the capability, validates the file, stores it in the feature's Resource directory, and records the sanitized manifest.

- [ ] **Step 4: Run tests and commit**

Run: `bash tools/tests/test-audio-skill.sh`  
Expected: all manifest, validation, and entitlement cases pass using fixtures rather than the live API.

```bash
git add .agents/skills/ios-audio-assets .claude/skills/ios-audio-assets tools/tests
git commit -m "feat: add optional ElevenLabs audio workflow"
```

### Task 5: App Store package structure

**Files:**
- Create: `App Store/README.md`
- Create: `App Store/metadata/app.yml`
- Create: `App Store/metadata/localizations/en-US.yml`
- Create: `App Store/metadata/localizations/ja.yml`
- Create: `App Store/privacy/data-use.yml`
- Create: `App Store/legal/privacy-policy.md`
- Create: `App Store/legal/terms-of-use.md`
- Create: `App Store/review/review-notes.md`
- Create: `App Store/release-notes/en-US.md`
- Create: `App Store/release-notes/ja.md`
- Create: `App Store/submission/checklist.yml`
- Create: `App Store/screenshots/README.md`
- Create: `tools/validate-appstore-package.sh`
- Create: `tools/tests/test-appstore-package.sh`

**Interfaces:**
- `validate-appstore-package.sh --root 'App Store' --bundle-id com.yuto.TemplateApp --version 1.0`
- Produces a sanitized validation JSON with missing, inconsistent, and ready fields

- [ ] **Step 1: Write failing package tests**

Test a complete fixture against a pinned `requirements.json`, missing Japanese subtitle, description over the fixture limit, privacy declaration inconsistent with entitlement/SDK scan, missing support URL, missing screenshot family, and secret-like review credentials.

- [ ] **Step 2: Create the package files**

Use structured keys for app identity, locales, category, age-rating answers, support URL, privacy-policy URL, copyright, review contact reference, and release version. Mark legal documents as draft until generated from `privacy/data-use.yml` and confirmed by the user.

- [ ] **Step 3: Implement dynamic requirement lookup**

The preparation and submission skills fetch current official App Store field limits and screenshot requirements through Codex and cache the sanitized requirement version in `App Store/submission/requirements.json`. The validator itself is offline and accepts an explicit requirements file. Unit tests always use a pinned fixture. Only the live preparation/submission path refuses a cache older than 30 days.

- [ ] **Step 4: Implement privacy consistency checks**

Compare `data-use.yml` with entitlements, PrivacyInfo manifests, linked SDKs, permissions strings, Supabase usage, analytics, account deletion behavior, and stored data. Report differences without inventing a legal conclusion.

- [ ] **Step 5: Run tests and commit**

Run: `bash tools/tests/test-appstore-package.sh`  
Expected: valid fixture passes and each inconsistency fails with a precise field path.

```bash
git add 'App Store' tools/validate-appstore-package.sh tools/tests
git commit -m "feat: add App Store submission source package"
```

### Task 6: App Store screenshot production

**Files:**
- Create: `tools/capture-appstore-screenshots.sh`
- Create: `tools/build-appstore-screenshot-set.sh`
- Create: `tools/tests/test-appstore-screenshots.sh`
- Modify: `App Store/screenshots/README.md`

**Interfaces:**
- Consumes: audited screenshot requirements, deterministic UI launch states, and a release-specific Simulator matrix
- Produces final PNG files grouped by locale and required display family

- [ ] **Step 1: Write image-set tests**

Use fixture PNGs and pinned requirements to test dimensions, alpha-channel rejection where prohibited, duplicate image hashes, missing locale, ordering, safe-area clipping, manifest completeness, and a requirement that needs a Pro Max capture.

- [ ] **Step 2: Implement deterministic capture**

Resolve a separate release screenshot matrix from the current official display-family requirements. It may include iPhone Pro Max and other required devices and must not reuse the normal verification matrix's Pro Max exclusion. Launch one documented UI state per screenshot with fixed local data, locale, time, and appearance. Capture raw PNGs without secrets, notification banners, debugging overlays, or personal content.

- [ ] **Step 3: Implement final-set assembly**

Map raw captures to current required display sizes without stretching. Permit crop or compositing only from a checked-in screenshot specification. Write a manifest with source SHA, Runtime, Device Type, locale, state, dimensions, and output hash.

- [ ] **Step 4: Add AI and release-auditor review**

Evaluate text clipping, truthful representation, ordering, device consistency, Japanese/English parity, and correspondence to the submitted build. Any code or copy change invalidates affected screenshots.

- [ ] **Step 5: Run tests and commit**

Run: `bash tools/tests/test-appstore-screenshots.sh`  
Expected: all dimensions and manifest cases pass.

```bash
git add tools App\ Store/screenshots/README.md
git commit -m "feat: automate App Store screenshot sets"
```

### Task 7: Preparation and submission skills

**Files:**
- Create: `.agents/skills/prepare-appstore-assets/SKILL.md`
- Create: `.agents/skills/submit-appstore-release/SKILL.md`
- Create: matching relative symlinks under `.claude/skills/`
- Create: `docs/agent-contracts/appstore-submission.md`
- Create: `tools/tests/test-appstore-skills.sh`

**Interfaces:**
- Preparation produces an audited package and immutable manifest hash
- Submission consumes the same hash and records field-level results without secrets

- [ ] **Step 1: Write skill contract tests**

Assert both shared skills and symlinks exist. Assert submission requires Codex primary, personal App Store preflight, passed release-auditor result, current package digest, and user approval for first public release.

- [ ] **Step 2: Write preparation skill**

Generate localized metadata and legal drafts from actual specification and `data-use.yml`, capture screenshots, validate limits, request release-auditor review, and stop for user confirmation of first-publication legal claims.

- [ ] **Step 3: Write submission skill**

Codex opens App Store Connect in the authenticated personal session, verifies Team/App/Bundle ID/version/build, fills one section at a time from the audited package, reads back each field, uploads exact manifest screenshots, and saves sanitized result references. Claude cannot invoke this execution path directly and delegates to Codex.

- [ ] **Step 4: Define interruption and resume**

After each App Store section, record status and remote identifier in `App Store/submission/${VERSION}-result.json`, where `VERSION` comes from `metadata/app.yml`. On restart, read back current remote values before continuing. Never submit for review if the package digest or build changed.

- [ ] **Step 5: Run fixture tests and commit**

Run: `bash tools/tests/test-appstore-skills.sh`  
Expected: preparation succeeds on the complete fixture; Team mismatch, stale digest, unconfirmed legal text, and changed build all block submission.

```bash
git add .agents/skills .claude/skills docs/agent-contracts tools/tests
git commit -m "feat: add Codex App Store release workflows"
```

### Task 8: Integration security audit

**Files:**
- Modify: `tools/tests/test-claude-guard.sh`
- Modify: `tools/tests/test-foundation.sh`
- Modify: `README.md`

**Interfaces:**
- Proves conditional integrations remain dormant and Claude remains unable to execute them

- [ ] **Step 1: Expand Claude denial tests**

Add every new provider tool, Keychain tool, App Store browser action marker, and secret directory pattern to the deny table. Confirm local migration editing, local Supabase reset, audio-file inspection, and App Store text editing remain allowed.

- [ ] **Step 2: Scan tracked files**

Search tracked content for private-key headers, common Token prefixes, `service_role`, password assignments, and the dedicated secret path containing a filename. Confirm findings are policy examples only and no value is present.

- [ ] **Step 3: Verify dormant integrations**

Confirm the template app has no Supabase, ElevenLabs, Cloudflare, analytics, StoreKit, or notification SDK dependency and no root `supabase/` directory before activation.

- [ ] **Step 4: Run all repository tests**

Run every `tools/tests/test-*.sh` script and the `TemplateApp` Xcode tests.  
Expected: all pass with no skipped security case.

- [ ] **Step 5: Document activation examples and commit**

Add concise examples for activating Supabase, requesting one sound effect, preparing an App Store package, and delegating submission from Claude to Codex.

```bash
git add README.md tools/tests
git commit -m "test: audit optional integration boundaries"
```
