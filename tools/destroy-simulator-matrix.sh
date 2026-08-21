#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"
xcrun_bin="${XCRUN_BIN:-xcrun}"
matrix_io() {
  if [[ "${SIMULATOR_MATRIX_TESTING:-}" == "1" && "${SIMULATOR_MATRIX_IO_TEST_BIN:-}" == /tmp/ios-template-* && -x "${SIMULATOR_MATRIX_IO_TEST_BIN:-}" ]]; then
    "$SIMULATOR_MATRIX_IO_TEST_BIN" "$@"
  else
    swift tools/simulator-matrix-io.swift "$@"
  fi
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

matrix_copy="$(mktemp /tmp/ios-template-destroy-matrix.XXXXXX)"
devices_copy="$(mktemp /tmp/ios-template-destroy-devices.XXXXXX)"
udids="$(mktemp /tmp/ios-template-destroy-udids.XXXXXX)"
trap 'rm -f "$matrix_copy" "$devices_copy" "$udids"' EXIT
matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name simulator-matrix.json >"$matrix_copy"
"$xcrun_bin" simctl list devices -j >"$devices_copy"
matrix_io --operation replace --repo "$repo_root" --batch "$batch_id" --source "$devices_copy" --name devices.json
ruby tools/validate-simulator-matrix.rb "$matrix_copy" "$batch_id" "$devices_copy"
ruby -rjson - "$matrix_copy" >"$udids" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
puts matrix.fetch("cases").map { |entry| entry.fetch("udid") }
RUBY

while IFS= read -r udid; do
  "$xcrun_bin" simctl delete "$udid"
done <"$udids"
