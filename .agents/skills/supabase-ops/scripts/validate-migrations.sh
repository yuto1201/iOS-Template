#!/bin/bash
set -euo pipefail

fail() {
  printf '%s\n' "Supabase validation failed: $1" >&2
  exit 1
}

[[ $# -eq 2 && $1 == --root ]] || {
  echo 'usage: validate-migrations.sh --root SUPABASE_DIRECTORY' >&2
  exit 2
}
supabase_root=${2:-}
[[ -d "$supabase_root" && ! -L "$supabase_root" ]] || fail 'root is unavailable or symbolic'
root_physical=$(cd "$supabase_root" && /bin/pwd -P)
[[ -f "$root_physical/config.toml" && -f "$root_physical/seed.sql" && -d "$root_physical/migrations" ]] || fail 'migration-first structure is incomplete'
[[ ! -e "$root_physical/schema.sql" && ! -L "$root_physical/schema.sql" ]] || fail 'schema.sql is a forbidden second source of truth'
/usr/bin/grep -Eq '^-- synthetic-only: true$' "$root_physical/seed.sql" || fail 'seed.sql is not marked synthetic-only'

if /usr/bin/grep -Eiq -- '(service_role|secret[_ -]?key|-----BEGIN [A-Z ]*PRIVATE KEY-----|password[[:space:]]*=|api[_ -]?token)' "$root_physical/config.toml" "$root_physical/seed.sql"; then
  fail 'configuration or seed contains a credential pattern'
fi
if /usr/bin/grep -R -Eiq -- 'supabase[[:space:]]+db[[:space:]]+reset[[:space:]]+--linked' "$root_physical"; then
  fail 'db reset --linked is forbidden'
fi

while IFS= read -r -d '' sql_file; do
  sql_relative=${sql_file#"$root_physical/"}
  case "$sql_relative" in
    seed.sql|migrations/*.sql) ;;
    *) fail "SQL exists outside migrations: $sql_relative" ;;
  esac
done < <(/usr/bin/find "$root_physical" -type f -name '*.sql' -print0)

while IFS= read -r -d '' migration_file; do
  migration_name=${migration_file##*/}
  [[ "$migration_name" =~ ^([0-9]{14})_[a-z0-9]+(_[a-z0-9]+)*[.]sql$ ]] || fail "migration filename is invalid: $migration_name"
  /usr/bin/ruby -rtime -e 'Time.strptime(ARGV.fetch(0), "%Y%m%d%H%M%S").utc' "${BASH_REMATCH[1]}" 2>/dev/null || fail "migration timestamp is invalid: $migration_name"
  if /usr/bin/grep -Eiq -- '(service_role|secret[_ -]?key|-----BEGIN [A-Z ]*PRIVATE KEY-----|password[[:space:]]*=|api[_ -]?token)' "$migration_file"; then
    fail "migration contains a credential pattern: $migration_name"
  fi
  /usr/bin/ruby -e '
    sql=File.binread(ARGV.fetch(0)).downcase.gsub(/--[^\n]*/, " ").gsub(/\/\*.*?\*\//m, " ")
    tables=sql.scan(/create\s+table(?:\s+if\s+not\s+exists)?\s+public[.]([a-z_][a-z0-9_]*)/).flatten.uniq
    tables.each do |table|
      rls=/alter\s+table\s+(?:if\s+exists\s+)?public[.]#{Regexp.escape(table)}\s+enable\s+row\s+level\s+security/
      policy=/create\s+policy\s+(?:"[^"]+"|[a-z_][a-z0-9_]*)\s+on\s+public[.]#{Regexp.escape(table)}\b/
      abort unless sql.match?(rls) && sql.match?(policy)
    end
  ' "$migration_file" 2>/dev/null || fail "public table RLS or policy validation failed: $migration_name"
done < <(/usr/bin/find "$root_physical/migrations" -type f -name '*.sql' -print0)

printf '%s\n' 'Supabase migrations are valid.'
