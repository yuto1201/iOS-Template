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

usage() {
  echo "usage: resolve-simulator-matrix.sh --batch-id <id> --output <path> [--scope iphone-ja|targeted|full] [--case-ids id,id]" >&2
  exit 2
}

[[ $# -ge 4 && $1 == "--batch-id" && $3 == "--output" ]] || usage
batch_id="$2" output="$4"
shift 4
scope=full
scope_seen=0
requested_case_ids=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) [[ $# -ge 2 && "$scope_seen" -eq 0 ]] || usage; scope="$2"; scope_seen=1; shift 2 ;;
    --case-ids) [[ $# -ge 2 && -z "$requested_case_ids" ]] || usage; requested_case_ids="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$scope" == iphone-ja || "$scope" == targeted || "$scope" == full ]] || usage
if [[ "$scope" == targeted ]]; then
  [[ -n "$requested_case_ids" ]] || usage
  ruby -Itools/lib -rverification-scope -e 'IOSTemplate::VerificationScope.validate_targeted_case_ids!(ARGV.fetch(0).split(",", -1))' "$requested_case_ids" || usage
else
  [[ -z "$requested_case_ids" ]] || usage
fi
[[ "$batch_id" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,63}$ ]] || {
  echo "blocked:environment: invalid batch ID" >&2
  exit 1
}

expected_output="$repo_root/.artifacts/batches/$batch_id/simulator-matrix.json"
[[ "$(ruby -e 'puts File.expand_path(ARGV[0], Dir.pwd)' "$output")" == "$expected_output" ]] || {
  echo "blocked:environment: output must be $expected_output" >&2
  exit 1
}
matrix_state="$(matrix_io --operation exists --repo "$repo_root" --batch "$batch_id" --name simulator-matrix.json)"
if [[ "$matrix_state" == "present" ]]; then
  make_temp reuse_matrix reuse-matrix
  matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name simulator-matrix.json >"$reuse_matrix"
  matrix_schema="$(ruby -rjson -e 'puts JSON.parse(File.binread(ARGV.fetch(0))).fetch("schemaVersion")' "$reuse_matrix")"
  case "$matrix_schema" in
    1)
      make_temp reuse_devices reuse-devices
      ruby tools/validate-simulator-matrix.rb complete "$reuse_matrix" "$batch_id" --scope "$scope"
      bounded_run simulator-list "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" xcrun simctl list devices -j >"$reuse_devices"
      matrix_io --operation replace --repo "$repo_root" --batch "$batch_id" --source "$reuse_devices" --name devices.json
      ruby tools/validate-simulator-matrix.rb complete "$reuse_matrix" "$batch_id" "$reuse_devices" --scope "$scope"
      ;;
    2)
      ruby tools/validate-simulator-matrix.rb complete "$reuse_matrix" "$batch_id" --scope "$scope"
      ;;
    *)
      echo "blocked:environment: unsupported frozen Simulator matrix schema" >&2
      exit 1
      ;;
  esac
  if [[ "$scope" == targeted ]]; then
    ruby -rjson - "$reuse_matrix" "$requested_case_ids" <<'RUBY'
matrix, requested = ARGV
actual = JSON.parse(File.read(matrix)).fetch("cases").map { |entry| entry.fetch("id") }.join(",")
abort "blocked:environment: frozen matrix cases differ from requested target" unless actual == requested
RUBY
  fi
  echo "$expected_output"
  exit 0
fi

capture_list() {
  local subject="$1"
  local temporary
  make_temp temporary "$subject"
  bounded_run "simulator-list-$subject" "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" xcrun simctl list "$subject" -j >"$temporary"
  matrix_io \
    --operation replace --repo "$repo_root" --batch "$batch_id" \
    --source "$temporary" --name "$subject.json"
}

capture_list runtimes
capture_list devicetypes

make_temp working_matrix matrix
make_temp runtimes_input runtimes
make_temp types_input types
matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name runtimes.json >"$runtimes_input"
matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name devicetypes.json >"$types_input"

if [[ "$scope" == targeted ]]; then
  bounded_run simulator-matrix-resolver "${IOS_TEMPLATE_SWIFT_TIMEOUT_SECONDS:-600}" \
    swift tools/resolve-simulator-matrix.swift \
    --runtimes "$runtimes_input" --device-types "$types_input" \
    --batch-id "$batch_id" --scope targeted --case-ids "$requested_case_ids" >"$working_matrix"
elif [[ "$scope" == iphone-ja ]]; then
  bounded_run simulator-matrix-resolver "${IOS_TEMPLATE_SWIFT_TIMEOUT_SECONDS:-600}" \
    swift tools/resolve-simulator-matrix.swift \
    --runtimes "$runtimes_input" --device-types "$types_input" \
    --batch-id "$batch_id" --scope iphone-ja >"$working_matrix"
else
  bounded_run simulator-matrix-resolver "${IOS_TEMPLATE_SWIFT_TIMEOUT_SECONDS:-600}" \
    swift tools/resolve-simulator-matrix.swift \
    --runtimes "$runtimes_input" --device-types "$types_input" \
    --batch-id "$batch_id" >"$working_matrix"
fi

ruby tools/validate-simulator-matrix.rb planned "$working_matrix" "$batch_id" --scope "$scope"

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  developer_path="$DEVELOPER_DIR"
else
  developer_path="$(xcode-select -p)"
fi
xcode_version="$(bounded_run xcode-version "${IOS_TEMPLATE_XCODEBUILD_PROBE_TIMEOUT_SECONDS:-60}" xcodebuild -version)"
xcode_json="$(ruby -rjson - "$developer_path" "$xcode_version" <<'RUBY'
path, output = ARGV
version = output[/Xcode\s+([^\n]+)/, 1]
build = output[/Build version\s+([^\n]+)/, 1]
abort "blocked:environment: unable to resolve Xcode version/build" unless version && build
puts JSON.generate({"path" => path, "version" => version, "build" => build})
RUBY
)"
ruby -rjson - "$working_matrix" "$xcode_json" <<'RUBY'
path, xcode_json = ARGV
matrix = JSON.parse(File.read(path))
xcode = JSON.parse(xcode_json)
abort "blocked:environment: invalid Xcode metadata" unless xcode.is_a?(Hash) && xcode.keys.sort == %w[build path version] && xcode.values.all? { |value| value.is_a?(String) && !value.empty? }
matrix["xcode"] = xcode
File.write(path, JSON.pretty_generate(matrix) + "\n")
RUBY
ruby tools/validate-simulator-matrix.rb planned-with-xcode "$working_matrix" "$batch_id" --scope "$scope"
runtime_matrix="$working_matrix"
ruby tools/validate-simulator-matrix.rb complete "$runtime_matrix" "$batch_id" --scope "$scope"
matrix_io \
  --operation publish \
  --repo "$repo_root" \
  --batch "$batch_id" \
  --source "$runtime_matrix" \
  --name "simulator-matrix.json"
echo "$expected_output"
