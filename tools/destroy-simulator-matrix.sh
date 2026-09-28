#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"
source "$repo_root/tools/lib/bounded-command.sh"

cleanup_paths=()
cleanup() {
  local path
  for path in "${cleanup_paths[@]-}"; do
    [[ -n "$path" ]] && rm -f -- "$path"
  done
}
make_temp() {
  local variable="$1"
  local label="$2"
  local path
  path="$(mktemp "${TMPDIR:-/tmp}/ios-template-${label}.XXXXXX")"
  cleanup_paths+=("$path")
  printf -v "$variable" '%s' "$path"
}
trap cleanup EXIT

matrix_io() {
  bounded_run simulator-matrix-io "${IOS_TEMPLATE_SWIFT_TIMEOUT_SECONDS:-600}" \
    swift tools/simulator-matrix-io.swift "$@"
}

[[ $# -eq 2 && $1 == "--matrix" ]] || {
  echo "usage: destroy-simulator-matrix.sh --matrix <path>" >&2
  exit 2
}
matrix_argument="$2"
absolute="$(ruby -e 'puts File.expand_path(ARGV[0], Dir.pwd)' "$matrix_argument")"
prefix="$repo_root/.artifacts/batches/"
[[ "$absolute" == "$prefix"*/simulator-matrix.json ]] || {
  echo "blocked:environment: matrix must be under .artifacts/batches" >&2
  exit 1
}
relative="${absolute#"$prefix"}"
batch_id="${relative%/simulator-matrix.json}"
[[ "$batch_id" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,63}$ && "$relative" == "$batch_id/simulator-matrix.json" ]] || {
  echo "blocked:environment: invalid batch matrix path" >&2
  exit 1
}

make_temp matrix_copy destroy-matrix
matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name simulator-matrix.json >"$matrix_copy"
matrix_schema="$(ruby -rjson -e 'puts JSON.parse(File.binread(ARGV.fetch(0))).fetch("schemaVersion")' "$matrix_copy")"
if [[ "$matrix_schema" == 2 ]]; then
  ruby tools/validate-simulator-matrix.rb complete "$matrix_copy" "$batch_id"
  echo "schema v2 matrix contains conditions only; dedicated Simulator leases are returned through ios-simulator-resource.rb and devices are never deleted"
  exit 0
fi
[[ "$matrix_schema" == 1 ]] || {
  echo "blocked:environment: unsupported Simulator matrix schema" >&2
  exit 1
}
# D-063: verification tools never delete Simulators. Report the legacy batch devices instead.
ruby tools/validate-simulator-matrix.rb complete "$matrix_copy" "$batch_id"
ruby -rjson - "$matrix_copy" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
udids = matrix.fetch("cases").map { |entry| entry.fetch("udid") }
puts "legacy schema v1 matrix Simulators are not deleted by tools (D-063); remove them manually when no longer needed: #{udids.join(" ")}"
RUBY
