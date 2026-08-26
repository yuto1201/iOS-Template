#!/bin/bash
set -euo pipefail

skill_root=$(cd "$(dirname "$0")/.." && pwd -P)

fail() {
  printf '%s\n' "Supabase activation refused: $1" >&2
  exit 1
}

[[ $# -eq 4 && $1 == --repo && $3 == --spec ]] || {
  echo 'usage: activate.sh --repo ABSOLUTE_REPOSITORY --spec RELATIVE_SPEC' >&2
  exit 2
}
repository_root=${2:-}
specification_relative=${4:-}
[[ "$repository_root" == /* && -d "$repository_root" && ! -L "$repository_root" ]] || fail 'repository root is invalid'
repository_physical=$(cd "$repository_root" && /bin/pwd -P)
repository_root=$repository_physical
[[ "$specification_relative" != /* && "$specification_relative" != *'..'* && "$specification_relative" == specs/*.md ]] || fail 'specification path is invalid'
specification="$repository_root/$specification_relative"
[[ -f "$specification" && ! -L "$specification" ]] || fail 'specification is unavailable'
[[ "$(/usr/bin/stat -f '%l' "$specification")" == 1 ]] || fail 'specification must have one hard link'
/usr/bin/grep -Eq '^Status:[[:space:]]*確定[[:space:]]*$' "$specification" || fail 'specification is not confirmed'
/usr/bin/grep -Eq '^Supabase:[[:space:]]*required[[:space:]]*$' "$specification" || fail 'specification does not explicitly require Supabase'
[[ ! -e "$repository_root/supabase" && ! -L "$repository_root/supabase" ]] || fail 'supabase directory already exists'

activation_workspace=$(mktemp -d "$repository_root/.supabase-activation.XXXXXX")
trap 'rm -rf -- "$activation_workspace"' EXIT
chmod 700 "$activation_workspace"
mkdir -p "$activation_workspace/supabase/migrations"
/bin/cp "$skill_root/templates/config.toml" "$activation_workspace/supabase/config.toml"
/bin/cp "$skill_root/templates/seed.sql" "$activation_workspace/supabase/seed.sql"
chmod 644 "$activation_workspace/supabase/config.toml" "$activation_workspace/supabase/seed.sql"
/bin/mv "$activation_workspace/supabase" "$repository_root/supabase"
trap - EXIT
/bin/rmdir "$activation_workspace"
printf '%s\n' '{"status":"activated","schemaSource":"supabase/migrations"}'
