#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"
xcrun_bin="${XCRUN_BIN:-xcrun}"
resolver_bin="${SIMULATOR_MATRIX_RESOLVER:-swift}"
matrix_io() {
  if [[ "${SIMULATOR_MATRIX_TESTING:-}" == "1" && "${SIMULATOR_MATRIX_IO_TEST_BIN:-}" == /tmp/ios-template-* && -x "${SIMULATOR_MATRIX_IO_TEST_BIN:-}" ]]; then
    "$SIMULATOR_MATRIX_IO_TEST_BIN" "$@"
  else
    swift tools/simulator-matrix-io.swift "$@"
  fi
}

usage() {
  echo "usage: resolve-simulator-matrix.sh --batch-id <id> --output <path>" >&2
  exit 2
}

[[ $# -eq 4 && $1 == "--batch-id" && $3 == "--output" ]] || usage
batch_id="$2"
output="$4"
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
  reuse_matrix="$(mktemp /tmp/ios-template-reuse-matrix.XXXXXX)"
  reuse_devices="$(mktemp /tmp/ios-template-reuse-devices.XXXXXX)"
  trap 'rm -f "$reuse_matrix" "$reuse_devices"' EXIT
  matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name simulator-matrix.json >"$reuse_matrix"
  ruby tools/validate-simulator-matrix.rb "$reuse_matrix" "$batch_id"
  "$xcrun_bin" simctl list devices -j >"$reuse_devices"
  matrix_io --operation replace --repo "$repo_root" --batch "$batch_id" --source "$reuse_devices" --name devices.json
  ruby tools/validate-simulator-matrix.rb "$reuse_matrix" "$batch_id" "$reuse_devices"
  trap - EXIT
  echo "$expected_output"
  exit 0
fi

capture_list() {
  local subject="$1"
  local temporary
  temporary="$(mktemp "/tmp/ios-template-${subject}.XXXXXX")"
  "$xcrun_bin" simctl list "$subject" -j >"$temporary"
  matrix_io \
    --operation replace --repo "$repo_root" --batch "$batch_id" \
    --source "$temporary" --name "$subject.json"
  rm -f "$temporary"
}

capture_list runtimes
capture_list devicetypes
capture_list devices

working_matrix="$(mktemp "/tmp/ios-template-matrix.XXXXXX")"
plan_file="$(mktemp "/tmp/ios-template-plan.XXXXXX")"
created_file="$(mktemp "/tmp/ios-template-created.XXXXXX")"
runtimes_input="$(mktemp "/tmp/ios-template-runtimes.XXXXXX")"
types_input="$(mktemp "/tmp/ios-template-types.XXXXXX")"
devices_input="$(mktemp "/tmp/ios-template-devices.XXXXXX")"
trap 'rm -f "$working_matrix" "$plan_file" "$created_file" "$runtimes_input" "$types_input" "$devices_input"' EXIT
matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name runtimes.json >"$runtimes_input"
matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name devicetypes.json >"$types_input"
matrix_io --operation read --repo "$repo_root" --batch "$batch_id" --name devices.json >"$devices_input"

"$resolver_bin" tools/resolve-simulator-matrix.swift \
  --runtimes "$runtimes_input" \
  --device-types "$types_input" \
  --devices "$devices_input" \
  --batch-id "$batch_id" >"$working_matrix"

if [[ -n "${SIMULATOR_MATRIX_XCODE_JSON:-}" ]]; then
  xcode_json="$SIMULATOR_MATRIX_XCODE_JSON"
else
  developer_path="${DEVELOPER_DIR:-$(xcode-select -p)}"
  xcode_version="$(xcodebuild -version)"
  xcode_json="$(ruby -rjson - "$developer_path" "$xcode_version" <<'RUBY'
path, output = ARGV
version = output[/Xcode\s+([^\n]+)/, 1]
build = output[/Build version\s+([^\n]+)/, 1]
abort "blocked:environment: unable to resolve Xcode version/build" unless version && build
puts JSON.generate({"path" => path, "version" => version, "build" => build})
RUBY
)"
fi
ruby -rjson - "$working_matrix" "$xcode_json" <<'RUBY'
path, xcode_json = ARGV
matrix = JSON.parse(File.read(path))
expected = [["iphone-en", "iPhone", "en_US", "en"], ["iphone-ja", "iPhone", "ja_JP", "ja"], ["ipad-en", "iPad", "en_US", "en"], ["ipad-ja", "iPad", "ja_JP", "ja"]]
abort "blocked:environment: invalid pre-create matrix" unless matrix.keys.sort == %w[batchId cases resolvedAt runtime schemaVersion] && matrix["schemaVersion"] == 1 && matrix["cases"].map { |entry| [entry["id"], entry["family"], entry["locale"], entry["language"]] } == expected
abort "blocked:environment: invalid pre-create matrix" unless matrix["resolvedAt"].is_a?(String) && !matrix["resolvedAt"].empty? && matrix["runtime"].is_a?(Hash) && matrix["runtime"].keys.sort == %w[identifier version] && matrix["runtime"].values.all? { |value| value.is_a?(String) && !value.empty? }
matrix["cases"].each do |entry|
  abort "blocked:environment: invalid pre-create matrix" unless entry.keys.sort == %w[deviceType family id language locale]
  type = entry["deviceType"]
  abort "blocked:environment: invalid pre-create matrix" unless type.is_a?(Hash) && type.keys.sort == %w[identifier name] && type.values.all? { |value| value.is_a?(String) && !value.empty? }
end
xcode = JSON.parse(xcode_json)
abort "blocked:environment: invalid Xcode metadata" unless xcode.is_a?(Hash) && xcode.keys.sort == %w[build path version] && xcode.values.all? { |value| value.is_a?(String) && !value.empty? }
matrix["xcode"] = xcode
File.write(path, JSON.pretty_generate(matrix) + "\n")
RUBY

ruby -rjson - "$working_matrix" "$batch_id" >"$plan_file" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
batch_id = ARGV.fetch(1)
expected = %w[iphone-en iphone-ja ipad-en ipad-ja]
abort "blocked:environment: resolver did not return exactly four stable cases" unless matrix.fetch("cases").map { |entry| entry["id"] } == expected
matrix.fetch("cases").each do |entry|
  type = entry.fetch("deviceType")
  puts [entry.fetch("id"), "iOS-Template-#{batch_id}-#{entry.fetch("id")}", type.fetch("identifier"), matrix.fetch("runtime").fetch("identifier")].join("\t")
end
RUBY
ruby - "$plan_file" <<'RUBY'
rows = File.readlines(ARGV.fetch(0), chomp: true).map { |line| line.split("\t", 4) }
expected = %w[iphone-en iphone-ja ipad-en ipad-ja]
abort "blocked:environment: invalid Simulator creation plan" unless rows.length == 4 && rows.map(&:first) == expected && rows.all? { |row| row.length == 4 && row.all? { |value| !value.empty? } }
abort "blocked:environment: duplicate Simulator creation plan row" unless rows.map { |row| row[1] }.uniq.length == 4
RUBY

record_failure() {
  local failed_case="$1"
  local failed_name="$2"
  local report_file
  report_file="$(mktemp "/tmp/ios-template-creation-failure.XXXXXX")"
  ruby -rjson - "$created_file" "$report_file" "$failed_case" "$failed_name" <<'RUBY'
created_path, report_path, failed_case, failed_name = ARGV
created = File.readlines(created_path, chomp: true).map do |line|
  case_id, name, type, runtime, udid = line.split("\t", 5)
  {"id" => case_id, "name" => name, "deviceTypeIdentifier" => type, "runtimeIdentifier" => runtime, "udid" => udid}
end
File.write(report_path, JSON.pretty_generate({"status" => "blocked:environment", "failedCase" => failed_case, "failedName" => failed_name, "possibleDedicatedSimulators" => created}) + "\n")
RUBY
  matrix_io --operation write-unique --repo "$repo_root" --batch "$batch_id" --source "$report_file" --prefix creation-failure >/dev/null
  rm -f "$report_file"
}

while IFS=$'\t' read -r case_id simulator_name device_type runtime; do
  if ! udid="$("$xcrun_bin" simctl create "$simulator_name" "$device_type" "$runtime")"; then
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

post_devices="$(mktemp "/tmp/ios-template-post-devices.XXXXXX")"
trap 'rm -f "$working_matrix" "$plan_file" "$created_file" "$post_devices" "$working_matrix.next"' EXIT
"$xcrun_bin" simctl list devices -j >"$post_devices"
ruby -rjson - "$working_matrix" "$plan_file" "$created_file" "$post_devices" "$batch_id" >"$working_matrix.next" <<'RUBY'
matrix_path, plan_path, created_path, devices_path, batch_id = ARGV
matrix = JSON.parse(File.read(matrix_path))
expected_ids = %w[iphone-en iphone-ja ipad-en ipad-ja]
cases = matrix.fetch("cases")
abort "blocked:environment: resolver did not return exactly four stable cases" unless cases.map { |entry| entry["id"] } == expected_ids
plan = File.readlines(plan_path, chomp: true).map { |line| line.split("\t", 4) }
created = File.readlines(created_path, chomp: true).map { |line| line.split("\t", 5) }
abort "blocked:environment: incomplete Simulator creation set" unless created.length == 4 && created.map(&:first) == expected_ids && created.all? { |row| row.length == 5 && row[4].match?(/\A[0-9A-Fa-f-]+\z/) }
abort "blocked:environment: duplicate created Simulator UDID or name" unless created.map { |row| row[1] }.uniq.length == 4 && created.map { |row| row[4] }.uniq.length == 4
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
 ruby tools/validate-simulator-matrix.rb "$working_matrix.next" "$batch_id" "$post_devices"
mv "$working_matrix.next" "$working_matrix"
matrix_io --operation replace --repo "$repo_root" --batch "$batch_id" --source "$post_devices" --name devices.json

matrix_io \
  --operation publish \
  --repo "$repo_root" \
  --batch "$batch_id" \
  --source "$working_matrix" \
  --name "simulator-matrix.json"
rm -f "$working_matrix"
trap - EXIT
echo "$expected_output"
