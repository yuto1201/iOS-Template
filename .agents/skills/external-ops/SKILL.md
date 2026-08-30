---
name: external-ops
description: Use when Codex or Claude must execute one authenticated external operation after exact configured-account, target, Issue-contract, approval, and secret-handling checks pass.
---

# Account-bound External Operations

Codex and Claude have the same authority. Model identity never grants or removes external access. `Config/ownership.yml`, the live Issue contract, current Head, and required user approval define the authority.

## Required workflow

1. Read `docs/AUTHORITY.md`, the live Issue, its sealed contract, and `Config/ownership.yml`.
2. Confirm the operation is an exact allowlisted ID in the Issue contract and its `Executor` is the model performing the operation.
3. Immediately before authenticated access, run the applicable preflight with the explicit executor:

```sh
tools/github-account-preflight.sh --repo "$REPO" --issue "$ISSUE" \
  --intended-operation "$OPERATION"

tools/provider-preflight.sh --executor "$EXECUTOR" --issue "$ISSUE" \
  "$PROVIDER" ${PROVIDER_ARGUMENTS}
```

4. Require case-sensitive equality between the live account/target and `Config/ownership.yml`. An unset identifier, another account, another target, ambiguous session, unhealthy resource, or stale evidence is `blocked:ops`.
5. Check the Issue-bound approval classification. Destructive production data changes, billing/plan changes, new service registration, first App Store publication or legal claims, broad DNS replacement, and membership/role changes require a separate user approval.
6. Retrieve secrets only at child-process scope with the repository secret tooling. Never expose secrets in prompts, argv, logs, Issue/PR text, screenshots, or artifacts.
7. Execute only the declared operation and return sanitized account, target, operation, result reference, status, and time. Do not infer success or automatically replay an ambiguous mutation.

## Configured-but-incomplete targets

Account-level identity may be configured before an app-specific target exists. Supabase Project Ref, Cloudflare deploy target, Vercel Project ID, ElevenLabs Workspace ID, and App Store Team/Bundle ID remain fail-closed until explicitly configured for the app.
