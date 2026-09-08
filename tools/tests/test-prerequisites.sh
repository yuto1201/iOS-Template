#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg ruby jq git

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
helper="$repo_root/tools/tests/lib/prerequisites.sh"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-prerequisites.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT

fail() { printf 'prerequisite regression: %s\n' "$1" >&2; exit 1; }
# An isolated bin excludes rg/jq regardless of where the host installed them.
# Guards use Bash builtins, so no fixture utility should be needed yet.
mkdir "$workspace/bin"
printf '#!/bin/bash\nprintf "fixture started\\n" >> "$PREREQUISITE_SENTINEL"\nexit 97\n' > "$workspace/bin/mktemp"
chmod +x "$workspace/bin/mktemp"

expect_missing() {
  local command_name=$1 label=$2 status=0
  shift 2
  "$@" > "$workspace/stdout" 2> "$workspace/stderr" || status=$?
  [[ "$status" == 69 ]] || fail "$label: expected prerequisite exit 69, got $status"
  grep -Fq "missing executable '$command_name'" "$workspace/stderr" || fail "$label: missing command diagnostic"
  [[ ! -s "$workspace/stdout" ]] || fail "$label: unexpected assertion output"
  [[ ! -e "$workspace/sentinel" ]] || fail "$label: fixture started before prerequisites"
}

# Check real entrypoints, including rg inside fake-gh scripts and shared fixtures.
checked=0
entrypoints=0
for test_file in "$repo_root"/tools/tests/test-*.sh; do
  [[ "$test_file" != "$0" && "$test_file" != "$repo_root/tools/tests/test-prerequisites.sh" ]] || continue
  declaration=$(grep '^require_test_commands ' "$test_file") || fail "${test_file##*/}: missing prerequisite declaration"
  read -r function_name test_argument first_command remaining_commands <<< "$declaration"
  [[ "$first_command" =~ ^[a-z][a-z0-9-]*$ ]] || fail "${test_file##*/}: expected named first prerequisite"
  expect_missing "$first_command" "${test_file##*/}: first dependency" env PATH="$workspace/bin" \
    PREREQUISITE_SENTINEL="$workspace/sentinel" /bin/bash "$test_file"
  entrypoints=$((entrypoints + 1))
  if grep -Eq '^require_test_commands .* rg([[:space:]]|$)' "$test_file"; then
    expect_missing rg "${test_file##*/}" env PATH="$workspace/bin" \
      PREREQUISITE_SENTINEL="$workspace/sentinel" /bin/bash "$test_file"
    checked=$((checked + 1))
  fi
done
[[ "$checked" -ge 25 ]] || fail 'rg-dependent entrypoints were not all guarded'
expect_missing rg prerequisite-entrypoint env PATH="$workspace/bin" \
  PREREQUISITE_SENTINEL="$workspace/sentinel" /bin/bash "$repo_root/tools/tests/test-prerequisites.sh"

expect_missing rg function-only env PATH="$workspace/bin" /bin/bash -c '
  source "$1"; rg() { return 0; }; require_test_commands probe rg
' _ "$helper"
expect_missing missing-test-executable missing-command /bin/bash -c '
  source "$1"; require_test_commands probe missing-test-executable
' _ "$helper"
mkdir "$workspace/not-executable"
expect_missing "$workspace/not-executable" directory /bin/bash -c '
  source "$1"; require_test_commands probe "$2"
' _ "$helper" "$workspace/not-executable"
printf '#!/bin/bash\nexit 0\n' > "$workspace/not-executable-file"
expect_missing "$workspace/not-executable-file" non-executable-file /bin/bash -c '
  source "$1"; require_test_commands probe "$2"
' _ "$helper" "$workspace/not-executable-file"
expect_missing jq real-entrypoint-jq env PATH="$workspace/bin" \
  PREREQUISITE_SENTINEL="$workspace/sentinel" /bin/bash "$repo_root/tools/tests/test-repository-test-evidence.sh"
expect_missing missing-test-compiler real-entrypoint-cc env CC=missing-test-compiler \
  PREREQUISITE_SENTINEL="$workspace/sentinel" /bin/bash "$repo_root/tools/tests/test-review-shared-artifacts.sh"

printf '#!/bin/bash\nexit 1\n' > "$workspace/bin/python3"
chmod +x "$workspace/bin/python3"
status=0
PATH="$workspace/bin" /bin/bash -c 'source "$1"; require_test_python_tomllib probe' _ "$helper" \
  > "$workspace/stdout" 2> "$workspace/stderr" || status=$?
[[ "$status" == 69 ]] || fail 'unsupported Python was not a prerequisite failure'
grep -Fq 'Python 3.11+ with tomllib is required' "$workspace/stderr" || fail 'Python version diagnostic missing'
[[ ! -s "$workspace/stdout" ]] || fail 'Python check leaked output'

require_test_commands positive rg ruby jq git /bin/bash "${CC:-cc}"
require_test_python_tomllib positive
printf 'test prerequisite regressions passed (%s entrypoints, %s with rg)\n' "$entrypoints" "$checked"
