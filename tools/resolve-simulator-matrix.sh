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

usage() {
  echo "usage: resolve-simulator-matrix.sh --batch-id <id> --output <path> [--scope iphone-ja|full]" >&2
  exit 2
}

[[ ( $# -eq 4 || $# -eq 6 ) && $1 == "--batch-id" && $3 == "--output" ]] || usage
batch_id="$2"
output="$4"
scope=full
if [[ $# -eq 6 ]]; then
  [[ "$5" == "--scope" && ( "$6" == "iphone-ja" || "$6" == "full" ) ]] || usage
  scope="$6"
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
  make_temp reuse_devices reuse-devices
  matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name simulator-matrix.json >"$reuse_matrix"
  ruby tools/validate-simulator-matrix.rb complete "$reuse_matrix" "$batch_id" --scope "$scope"
  xcrun simctl list devices -j >"$reuse_devices"
  matrix_io --operation replace --repo "$repo_root" --batch "$batch_id" --source "$reuse_devices" --name devices.json
  ruby tools/validate-simulator-matrix.rb complete "$reuse_matrix" "$batch_id" "$reuse_devices" --scope "$scope"
  echo "$expected_output"
  exit 0
fi

capture_list() {
  local subject="$1"
  local temporary
  make_temp temporary "$subject"
  xcrun simctl list "$subject" -j >"$temporary"
  matrix_io \
    --operation replace --repo "$repo_root" --batch "$batch_id" \
    --source "$temporary" --name "$subject.json"
}

capture_list runtimes
capture_list devicetypes
capture_list devices

make_temp working_matrix matrix
make_temp plan_file plan
make_temp created_file created
make_temp runtimes_input runtimes
make_temp types_input types
make_temp devices_input devices
matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name runtimes.json >"$runtimes_input"
matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name devicetypes.json >"$types_input"
matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name devices.json >"$devices_input"

swift tools/resolve-simulator-matrix.swift \
  --runtimes "$runtimes_input" \
  --device-types "$types_input" \
  --devices "$devices_input" \
  --batch-id "$batch_id" --scope "$scope" >"$working_matrix"

ruby tools/validate-simulator-matrix.rb planned "$working_matrix" "$batch_id" --scope "$scope"

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  developer_path="$DEVELOPER_DIR"
else
  developer_path="$(xcode-select -p)"
fi
xcode_version="$(xcodebuild -version)"
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

ruby -rjson -Itools/lib -rverification-scope - "$working_matrix" "$batch_id" >"$plan_file" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
batch_id = ARGV.fetch(1)
expected = IOSTemplate::VerificationScope.case_ids(IOSTemplate::VerificationScope.matrix_name(matrix))
abort "blocked:environment: resolver did not return exact scoped cases" unless matrix.fetch("cases").map { |entry| entry["id"] } == expected
matrix.fetch("cases").each do |entry|
  type = entry.fetch("deviceType")
  puts [entry.fetch("id"), "iOS-Template-#{batch_id}-#{entry.fetch("id")}", type.fetch("identifier"), matrix.fetch("runtime").fetch("identifier")].join("\t")
end
RUBY
ruby -Itools/lib -rverification-scope - "$plan_file" "$scope" <<'RUBY'
rows = File.readlines(ARGV.fetch(0), chomp: true).map { |line| line.split("\t", 4) }
expected = IOSTemplate::VerificationScope.case_ids(ARGV.fetch(1))
abort "blocked:environment: invalid Simulator creation plan" unless rows.length == expected.length && rows.map(&:first) == expected && rows.all? { |row| row.length == 4 && row.all? { |value| !value.empty? } }
abort "blocked:environment: duplicate Simulator creation plan row" unless rows.map { |row| row[1] }.uniq.length == expected.length
RUBY

record_failure() {
  local failed_case="$1"
  local failed_name="$2"
  local report_file
  make_temp report_file creation-failure
  ruby -rjson - "$created_file" "$report_file" "$failed_case" "$failed_name" <<'RUBY'
created_path, report_path, failed_case, failed_name = ARGV
created = File.readlines(created_path, chomp: true).map do |line|
  case_id, name, type, runtime, udid = line.split("\t", 5)
  {"id" => case_id, "name" => name, "deviceTypeIdentifier" => type, "runtimeIdentifier" => runtime, "udid" => udid}
end
File.write(report_path, JSON.pretty_generate({"status" => "blocked:environment", "failedCase" => failed_case, "failedName" => failed_name, "possibleDedicatedSimulators" => created}) + "\n")
RUBY
  matrix_io --operation write-unique --repo "$repo_root" --batch "$batch_id" --source "$report_file" --prefix creation-failure >/dev/null
}

while IFS=$'\t' read -r case_id simulator_name device_type runtime; do
  if ! udid="$(xcrun simctl create "$simulator_name" "$device_type" "$runtime")"; then
    record_failure "$case_id" "$simulator_name"
    echo "blocked:environment: Simulator creation failed; preserved possible dedicated Simulators in an exclusive batch failure report" >&2
    exit 1
  fi
  [[ "$udid" =~ ^[0-9A-Fa-f-]+$ ]] || {
    record_failure "$case_id" "$simulator_name"
    echo "blocked:environment: simctl returned an invalid Simulator UDID; preserved possible dedicated Simulators in an exclusive batch failure report" >&2
    exit 1
  }
  printf '%s\t%s\t%s\t%s\t%s\n' "$case_id" "$simulator_name" "$device_type" "$runtime" "$udid" >>"$created_file"
done <"$plan_file"

make_temp post_devices post-devices
make_temp complete_matrix complete-matrix
xcrun simctl list devices -j >"$post_devices"
ruby -rjson -Itools/lib -rverification-scope - "$working_matrix" "$plan_file" "$created_file" "$post_devices" "$batch_id" >"$complete_matrix" <<'RUBY'
matrix_path, plan_path, created_path, devices_path, batch_id = ARGV
matrix = JSON.parse(File.read(matrix_path))
expected_ids = IOSTemplate::VerificationScope.case_ids(IOSTemplate::VerificationScope.matrix_name(matrix))
cases = matrix.fetch("cases")
abort "blocked:environment: resolver did not return exact scoped cases" unless cases.map { |entry| entry["id"] } == expected_ids
plan = File.readlines(plan_path, chomp: true).map { |line| line.split("\t", 4) }
created = File.readlines(created_path, chomp: true).map { |line| line.split("\t", 5) }
abort "blocked:environment: incomplete Simulator creation set" unless created.length == expected_ids.length && created.map(&:first) == expected_ids && created.all? { |row| row.length == 5 && row[4].match?(/\A[0-9A-Fa-f-]+\z/) }
abort "blocked:environment: duplicate created Simulator UDID or name" unless created.map { |row| row[1] }.uniq.length == expected_ids.length && created.map { |row| row[4] }.uniq.length == expected_ids.length
abort "blocked:environment: creation plan changed before validation" unless created.map { |row| row.take(4) } == plan
devices = JSON.parse(File.read(devices_path)).fetch("devices")
all_devices = devices.values.flatten
created.each do |case_id, name, type, runtime, udid|
  matches = Array(devices[runtime]).select { |device| device["udid"] == udid && device["name"] == name && device["deviceTypeIdentifier"] == type }
  abort "blocked:environment: created Simulator does not match its validated plan" unless matches.length == 1
  abort "blocked:environment: ambiguous live dedicated Simulator name" unless all_devices.count { |device| device["name"] == name } == 1
end
cases.each { |entry| entry["udid"] = created.find { |row| row[0] == entry["id"] }[4] }
puts JSON.pretty_generate(matrix)
RUBY
ruby tools/validate-simulator-matrix.rb complete "$complete_matrix" "$batch_id" "$post_devices" --scope "$scope"
matrix_io --operation replace --repo "$repo_root" --batch "$batch_id" --source "$post_devices" --name devices.json

matrix_io \
  --operation publish \
  --repo "$repo_root" \
  --batch "$batch_id" \
  --source "$complete_matrix" \
  --name "simulator-matrix.json"
echo "$expected_output"
