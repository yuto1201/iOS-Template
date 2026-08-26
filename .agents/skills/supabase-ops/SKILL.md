---
name: supabase-ops
description: Activate and operate Supabase only when a confirmed app specification explicitly requires authentication, synchronization, remote database, or storage. Use for creating migration-first local Supabase files, validating RLS and policies, testing local migrations, or delegating authenticated Supabase inspection and apply operations to Codex.
---

# Supabase Operations

Keep `supabase/migrations/*.sql` as the only schema source of truth. Do not activate this skill for a device-only app.

## Activation

1. Read the Issue and the app-specific confirmed product specification. Require an exact `Supabase: required` line and `Status: 確定`; otherwise stop without creating files.
2. Run from the repository root:

```sh
.agents/skills/supabase-ops/scripts/activate.sh --repo "$PWD" --spec specs/product.md
```

3. Add each change as `supabase/migrations/YYYYMMDDHHMMSS_snake_case.sql` using a UTC timestamp. Never create `schema.sql`.
4. Keep `supabase/seed.sql` synthetic. Never copy production identities or data.
5. Validate before local reset:

```sh
.agents/skills/supabase-ops/scripts/validate-migrations.sh --root supabase
supabase db reset --local
```

## Security gates

- Enable RLS and add explicit policies for every new `public` table in the same migration history.
- Put no Secret Key, legacy `service_role`, password, Token, or production data in tracked files.
- Refuse `supabase db reset --linked` in every environment.
- Let Claude edit migrations and run local validation only. Claude must delegate `link`, `pull`, `push`, remote advisors, and remote SQL through `codex-external-ops`.

## Codex remote operation

Before an authenticated operation, have Codex run `tools/provider-preflight.sh` for the exact Issue and environment. Report the configured personal Organization, Project Ref, health, pending migration names, and dry-run result without credentials. Use only the operation declared in the Issue contract.

Require separate user approval for destructive production SQL. Apply only committed pending migrations from `supabase/migrations`; never reconstruct schema from the remote dashboard.
