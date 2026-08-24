#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

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
make_temp devices_copy destroy-devices
make_temp udids destroy-udids
matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name simulator-matrix.json >"$matrix_copy"
xcrun simctl list devices -j >"$devices_copy"
matrix_io --operation replace --repo "$repo_root" --batch "$batch_id" --source "$devices_copy" --name devices.json
ruby tools/validate-simulator-matrix.rb complete "$matrix_copy" "$batch_id" "$devices_copy"
ruby -rjson - "$matrix_copy" >"$udids" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
puts matrix.fetch("cases").map { |entry| entry.fetch("udid") }
RUBY

while IFS= read -r udid; do
  xcrun simctl delete "$udid"
done <"$udids"
