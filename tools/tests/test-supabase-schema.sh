#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
activate="$repo_root/.agents/skills/supabase-ops/scripts/activate.sh"
validator="$repo_root/.agents/skills/supabase-ops/scripts/validate-migrations.sh"
supabase_root="$repo_root/supabase"
[[ -x "$activate" && -x "$validator" ]] || { echo 'the supabase-ops activation or validation script is missing' >&2; exit 1; }

# #329: static checks only. Replaying the migrations on a local database (Supabase CLI and Docker) is a
# separate decision.
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-supabase-schema.XXXXXX")
workspace=$(cd "$workspace" && pwd -P)
trap 'rm -rf -- "$workspace"' EXIT

# Static rules beyond validate-migrations.sh. Git-ignored runtime state (.temp/, .branches/, .env*,
# .DS_Store) is skipped, so a direct run sees what a clean checkout holds.
schema_tool="$workspace/schema-tool.rb"
cat > "$schema_tool" <<'RUBY'
# frozen_string_literal: true

require "fileutils"
require "set"
require "time"

RUNTIME_DIRECTORIES = %w[.temp .branches].freeze
IGNORED_FILE = /\A(?:\.DS_Store|\.env(?:\.(?!example\z).+)?)\z/.freeze
MIGRATION_NAME = /\A[0-9]{14}_[a-z0-9]+(?:_[a-z0-9]+)*\.sql\z/.freeze
IDENTIFIER = /(?:"[^"]+"|[a-z_][a-z0-9_$]*)/.freeze
QUALIFIED = /(#{IDENTIFIER})(?:\s*\.\s*(#{IDENTIFIER}))?/.freeze
CREDENTIAL = /(service[_]role|secret[_ -]?key|-----BEGIN [A-Z ]*PRIVATE KEY-----|password\s*=|api[_ -]?token|sb_secret_[A-Za-z0-9_-]{8,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.)/i.freeze

def refuse(message)
  warn "Supabase schema check failed: #{message}"
  exit 1
end

def tracked_files(root)
  files = []
  walk = lambda do |directory, relative|
    Dir.children(directory).sort.each do |name|
      path = File.join(directory, name)
      entry = relative.empty? ? name : "#{relative}/#{name}"
      stat = File.lstat(path)
      next if relative.empty? && stat.directory? && RUNTIME_DIRECTORIES.include?(name)
      refuse("symbolic links are not allowed: #{entry}") if stat.symlink?
      if stat.directory?
        walk.call(path, entry)
      elsif stat.file?
        files << entry unless name.match?(IGNORED_FILE)
      else
        refuse("unsupported file type: #{entry}")
      end
    end
  end
  walk.call(root, "")
  files
end

def text(root, entry)
  value = File.binread(File.join(root, entry)).force_encoding(Encoding::UTF_8)
  refuse("file is not valid UTF-8: #{entry}") unless value.valid_encoding?
  value
end

def sql_body(value)
  value.downcase.gsub(/--[^\n]*/, " ").gsub(%r{/\*.*?\*/}m, " ")
end

def unquote(identifier)
  identifier&.delete('"')
end

def check(root)
  files = tracked_files(root)
  files.each do |entry|
    refuse("credential pattern in #{entry}") if File.binread(File.join(root, entry)).match?(CREDENTIAL)
  end

  project_ids = text(root, "config.toml").lines.count { |line| line.match?(/\A\s*project_id\s*=\s*"[^"]+"\s*\z/) }
  refuse("config.toml must set project_id exactly once") unless project_ids == 1

  migrations = files.select { |entry| entry.start_with?("migrations/") }.map { |entry| entry.delete_prefix("migrations/") }.sort
  migrations.each do |name|
    refuse("migrations/ holds only <14-digit version>_<snake_case>.sql files: #{name}") unless name.match?(MIGRATION_NAME)
  end
  repeated = migrations.group_by { |name| name[0, 14] }.select { |_, names| names.length > 1 }.keys
  refuse("migration versions repeat: #{repeated.join(', ')}") unless repeated.empty?
  latest = Time.now.utc + 86_400
  migrations.each do |name|
    version = Time.strptime("#{name[0, 14]}+0000", "%Y%m%d%H%M%S%z")
    refuse("migration version is in the future: #{name}") if version > latest
  rescue ArgumentError
    refuse("migration version is not a UTC timestamp: #{name}")
  end

  public_tables = {}
  rls_enabled = Set.new
  migrations.each do |name|
    sql = sql_body(text(root, "migrations/#{name}"))
    create = /\bcreate\s+(?:(?:global|local)\s+)?(?:(temp|temporary|unlogged)\s+)?table\s+(?:if\s+not\s+exists\s+)?#{QUALIFIED}/
    sql.scan(create) do |kind, first, second|
      next if kind&.start_with?("temp")
      refuse("create table must name its schema: #{unquote(first)} in #{name}") if second.nil?
      public_tables[unquote(second)] ||= name if unquote(first) == "public"
    end
    rls = /\balter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?#{QUALIFIED}\s+(enable|disable)\s+row\s+level\s+security/
    sql.scan(rls) do |first, second, action|
      schema, table = second ? [unquote(first), unquote(second)] : [nil, unquote(first)]
      if action == "disable"
        refuse("row level security is disabled on public.#{table} in #{name}") if schema == "public" || (schema.nil? && public_tables.key?(table))
      elsif schema == "public"
        rls_enabled << table
      end
    end
  end
  missing = public_tables.keys.sort.reject { |table| rls_enabled.include?(table) }
  refuse("public tables without row level security: #{missing.join(', ')}") unless missing.empty?

  files.select { |entry| entry.start_with?("tests/") }.each do |entry|
    refuse("pgTAP tests use the .pg extension: #{entry}") unless entry.end_with?(".pg")
    lines = text(root, entry).downcase.lines.map { |line| line.sub(/--.*/, "").strip.gsub(/\s+/, " ") }.reject(&:empty?)
    refuse("pgTAP test must start with begin;: #{entry}") unless lines.first == "begin;"
    refuse("pgTAP test must end with select * from finish(); and rollback;: #{entry}") unless lines.last(2) == ["select * from finish();", "rollback;"]
    refuse("pgTAP test must declare a plan: #{entry}") unless lines.any? { |line| line.match?(/\bselect (?:\* from )?(?:plan\(\s*[0-9]+\s*\)|no_plan\(\s*\))/) }
  end
end

mode, *arguments = ARGV
case mode
when "check" then check(*arguments)
else abort "usage: schema-tool.rb check ROOT"
end
RUBY

check_schema_root() {
  "$validator" --root "$1" >/dev/null && ruby "$schema_tool" check "$1"
}

# The product specification adopts Supabase with the same two exact lines that activate.sh requires.
supabase_adopted() {
  /usr/bin/grep -Eq '^Status:[[:space:]]*確定[[:space:]]*$' "$1" &&
    /usr/bin/grep -Eq '^Supabase:[[:space:]]*required[[:space:]]*$' "$1"
}

# The rules are exercised on fixtures on every run, so they stay proven while supabase/ is dormant.
# The fixture starts from what the skill's activation creates.
activation_repo="$workspace/activation"
mkdir -p "$activation_repo/specs"
printf '%s\n' '# Product' '' 'Status: 確定' 'Supabase: required' > "$activation_repo/specs/product.md"
"$activate" --repo "$activation_repo" --spec specs/product.md >/dev/null
fixture_base="$activation_repo/supabase"
mkdir -p "$fixture_base/tests"
cat > "$fixture_base/migrations/20260101000000_create_notes.sql" <<'SQL'
-- Notes belong to their owner.
create table public.notes (
  id uuid primary key,
  owner_id uuid not null
);
alter table public.notes enable row level security;
create policy "notes_owner_reads" on public.notes for select using ((select auth.uid()) = owner_id);
create table private.note_events (id bigint primary key);
alter table private.note_events enable row level security;
create function private.copy_notes() returns void language plpgsql as $$
begin
  create temporary table scratch_notes (id uuid) on commit drop;
end;
$$;
SQL
cat > "$fixture_base/tests/01_notes.pg" <<'SQL'
-- Owners read only their own notes.
begin;
select plan(1);
select has_table('public', 'notes', 'notes exists');
select * from finish();
rollback;
SQL

fixture_case=0
new_fixture() {
  fixture_case=$((fixture_case + 1))
  fixture="$workspace/fixture-$fixture_case"
  /bin/cp -R "$fixture_base" "$fixture"
}
assert_fixture_refused() {
  local label=$1 diagnostic=$2
  if check_schema_root "$fixture" >"$workspace/fixture.out" 2>"$workspace/fixture.err"; then
    echo "schema check accepted a fixture it must refuse: $label" >&2
    exit 1
  fi
  /usr/bin/grep -Fq -- "$diagnostic" "$workspace/fixture.err" || {
    echo "schema check refused for an unexpected reason: $label" >&2
    /bin/cat "$workspace/fixture.err" >&2
    exit 1
  }
}

new_fixture
check_schema_root "$fixture" || { echo 'schema check refused the valid fixture' >&2; exit 1; }
mkdir -p "$fixture/.temp" "$fixture/.branches"
printf '%s\n' 'runtime state' > "$fixture/.temp/project-ref"
printf '%s\n' "API_""TOKEN=runtime-only" > "$fixture/.env"
check_schema_root "$fixture" || { echo 'schema check read ignored runtime state' >&2; exit 1; }

new_fixture
mv "$fixture/migrations/20260101000000_create_notes.sql" "$fixture/migrations/create_notes.sql"
assert_fixture_refused 'migration without a version' 'migration filename is invalid'

new_fixture
printf '%s\n' 'select 1;' > "$fixture/migrations/20260101000000_more_notes.sql"
assert_fixture_refused 'repeated migration version' 'migration versions repeat: 20260101000000'

new_fixture
printf '%s\n' 'select 1;' > "$fixture/migrations/29991231235959_far_future.sql"
assert_fixture_refused 'future migration version' 'migration version is in the future'

new_fixture
printf '%s\n' 'notes' > "$fixture/migrations/README.txt"
assert_fixture_refused 'stray migrations entry' 'migrations/ holds only'

new_fixture
printf '%s\n' 'create table "public"."orphans" (id int);' > "$fixture/migrations/20260102000000_create_orphans.sql"
assert_fixture_refused 'quoted public table without RLS' 'public tables without row level security: orphans'

new_fixture
printf '%s\n' 'create table loose_notes (id int);' > "$fixture/migrations/20260102000000_create_loose_notes.sql"
assert_fixture_refused 'unqualified table' 'create table must name its schema: loose_notes'

new_fixture
printf '%s\n' 'alter table public.notes disable row level security;' > "$fixture/migrations/20260102000000_open_notes.sql"
assert_fixture_refused 'RLS disabled later' 'row level security is disabled on public.notes'

new_fixture
/usr/bin/sed -i '' 's/^rollback;$/commit;/' "$fixture/tests/01_notes.pg"
assert_fixture_refused 'pgTAP test that commits' 'pgTAP test must end with'

new_fixture
/usr/bin/sed -i '' '/^begin;$/d' "$fixture/tests/01_notes.pg"
assert_fixture_refused 'pgTAP test outside a transaction' 'pgTAP test must start with begin;'

new_fixture
/usr/bin/sed -i '' '/plan(1)/d' "$fixture/tests/01_notes.pg"
assert_fixture_refused 'pgTAP test without a plan' 'pgTAP test must declare a plan'

new_fixture
printf '%s\n' "begin; select plan(0); set role service""_role; select * from finish(); rollback;" > "$fixture/tests/02_roles.pg"
assert_fixture_refused 'credential pattern in a pgTAP test' 'credential pattern in tests/02_roles.pg'

new_fixture
printf '%s\n' 'begin;' 'select plan(0);' 'select * from finish();' 'rollback;' > "$fixture/tests/03_notes.sql"
assert_fixture_refused 'pgTAP test with the .sql extension' 'SQL exists outside migrations'

new_fixture
ln -s ../seed.sql "$fixture/tests/seed.pg"
assert_fixture_refused 'symbolic link' 'symbolic links are not allowed: tests/seed.pg'

new_fixture
/usr/bin/sed -i '' '/^project_id/d' "$fixture/config.toml"
assert_fixture_refused 'config without project_id' 'config.toml must set project_id exactly once'

if [[ ! -e "$supabase_root" && ! -L "$supabase_root" ]]; then
  echo 'PASS: Supabase is dormant (no supabase/); the schema rules passed on fixtures'
  exit 0
fi
[[ -d "$supabase_root" && ! -L "$supabase_root" ]] || { echo 'supabase/ must be a real directory' >&2; exit 1; }
supabase_adopted "$repo_root/specs/product.md" || {
  echo 'supabase/ exists but specs/product.md does not adopt Supabase with Status: 確定 and Supabase: required' >&2
  exit 1
}
check_schema_root "$supabase_root" || exit 1

echo 'PASS: supabase/ satisfies the static schema rules'
