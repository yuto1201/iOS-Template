#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-supabase-skill.XXXXXX")
trap 'rm -rf -- "$test_workspace"' EXIT

skill_root="$repo_root/.agents/skills/supabase-ops"
activate="$skill_root/scripts/activate.sh"
validator="$skill_root/scripts/validate-migrations.sh"
fixture_repo="$test_workspace/app"
mkdir -p "$fixture_repo/specs"

assert_fails() {
  local label=$1
  shift
  if "$@" >"$test_workspace/stdout" 2>"$test_workspace/stderr"; then
    echo "expected failure: $label" >&2
    exit 1
  fi
}

cat > "$fixture_repo/specs/product.md" <<'EOF'
# Product

Status: 確定

Supabase: not required
EOF
[[ ! -e "$fixture_repo/supabase" ]] || { echo 'fixture unexpectedly starts activated' >&2; exit 1; }
assert_fails 'activation without an explicit requirement' "$activate" --repo "$fixture_repo" --spec specs/product.md
[[ ! -e "$fixture_repo/supabase" ]] || { echo 'rejected activation created Supabase files' >&2; exit 1; }

cat > "$fixture_repo/specs/product.md" <<'EOF'
# Product

Status: 確定

Supabase: required
EOF
activation_result=$("$activate" --repo "$fixture_repo" --spec specs/product.md)
[[ "$activation_result" == '{"status":"activated","schemaSource":"supabase/migrations"}' ]] || {
  echo "unexpected activation result: $activation_result" >&2
  exit 1
}
[[ -f "$fixture_repo/supabase/config.toml" && -f "$fixture_repo/supabase/seed.sql" && -d "$fixture_repo/supabase/migrations" ]] || {
  echo 'activation did not create the migration-first structure' >&2
  exit 1
}
[[ ! -e "$fixture_repo/supabase/schema.sql" ]] || { echo 'activation created a second schema source' >&2; exit 1; }

cat > "$fixture_repo/supabase/migrations/20260826062000_create_profiles.sql" <<'SQL'
create table public.profiles (
  id uuid primary key
);

alter table public.profiles enable row level security;

create policy "profiles_read_own"
on public.profiles
for select
using (auth.uid() = id);
SQL
"$validator" --root "$fixture_repo/supabase"

mv "$fixture_repo/supabase/migrations/20260826062000_create_profiles.sql" "$fixture_repo/supabase/migrations/create_profiles.sql"
assert_fails 'migration without UTC timestamp' "$validator" --root "$fixture_repo/supabase"
mv "$fixture_repo/supabase/migrations/create_profiles.sql" "$fixture_repo/supabase/migrations/20260826062000_create_profiles.sql"

/usr/bin/sed -i '' '/enable row level security/d' "$fixture_repo/supabase/migrations/20260826062000_create_profiles.sql"
assert_fails 'public table without RLS' "$validator" --root "$fixture_repo/supabase"
/usr/bin/sed -i '' '/create policy/,$d' "$fixture_repo/supabase/migrations/20260826062000_create_profiles.sql"
cat >> "$fixture_repo/supabase/migrations/20260826062000_create_profiles.sql" <<'SQL'
alter table public.profiles enable row level security;
SQL
assert_fails 'public table without policy' "$validator" --root "$fixture_repo/supabase"

cat > "$fixture_repo/supabase/migrations/20260826062000_create_profiles.sql" <<'SQL'
create table public.profiles (id uuid primary key);
alter table public.profiles enable row level security;
create policy "profiles_read" on public.profiles for select using (true);
-- service_role must never be placed in a migration
SQL
assert_fails 'service role pattern' "$validator" --root "$fixture_repo/supabase"

cat > "$fixture_repo/supabase/migrations/20260826062000_create_profiles.sql" <<'SQL'
create table public.profiles (id uuid primary key);
alter table public.profiles enable row level security;
create policy "profiles_read" on public.profiles for select using (true);
SQL
printf '%s\n' 'select 1;' > "$fixture_repo/supabase/schema.sql"
assert_fails 'second schema source' "$validator" --root "$fixture_repo/supabase"
rm -f -- "$fixture_repo/supabase/schema.sql"

printf '%s\n' 'supabase db reset --linked' > "$fixture_repo/supabase/remote-reset.sh"
assert_fails 'linked reset' "$validator" --root "$fixture_repo/supabase"
rm -f -- "$fixture_repo/supabase/remote-reset.sh"

/usr/bin/sed -i '' 's/synthetic-only: true/synthetic-only: false/' "$fixture_repo/supabase/seed.sql"
assert_fails 'non-synthetic seed' "$validator" --root "$fixture_repo/supabase"

[[ -L "$repo_root/.claude/skills/supabase-ops" ]] || { echo 'Claude Supabase skill link is missing' >&2; exit 1; }
[[ "$(readlink "$repo_root/.claude/skills/supabase-ops")" == '../../.agents/skills/supabase-ops' ]] || { echo 'Claude Supabase skill link target differs' >&2; exit 1; }
ruby -ryaml -e '
  text=File.binread(ARGV.fetch(0)); match=text.match(/\A---\n(.*?)\n---\n/m) or abort
  value=YAML.safe_load(match[1], permitted_classes: [], aliases: false)
  abort unless value.is_a?(Hash) && value.keys.sort == %w[description name]
  abort unless value["name"] == "supabase-ops" && value["description"].is_a?(String) && !value["description"].empty?
' "$skill_root/SKILL.md"

echo 'PASS: optional Supabase activation is specification-gated and migrations enforce one RLS-protected schema history'
