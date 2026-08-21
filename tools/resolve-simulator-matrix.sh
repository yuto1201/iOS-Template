#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"
xcrun_bin="${XCRUN_BIN:-xcrun}"
resolver_bin="${SIMULATOR_MATRIX_RESOLVER:-swift}"

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

matrix_path="$(ruby - "$repo_root" "$batch_id" "$output" <<'RUBY'
require "fileutils"

repo, batch_id, output = ARGV
repo = File.realpath(repo)
batches = File.join(repo, ".artifacts", "batches")
expected = File.join(batches, batch_id, "simulator-matrix.json")
actual = File.expand_path(output, Dir.pwd)
abort "blocked:environment: output must be #{expected}" unless actual == expected

current = repo
[".artifacts", "batches", batch_id].each do |component|
  current = File.join(current, component)
  if File.exist?(current) || File.symlink?(current)
    abort "blocked:environment: artifact path contains a symlink" if File.symlink?(current)
    abort "blocked:environment: artifact path is not a directory" unless File.directory?(current)
  else
    Dir.mkdir(current)
  end
end

abort "blocked:environment: artifact directory escaped repository" unless File.realpath(File.dirname(expected)) == File.dirname(expected)
abort "blocked:environment: matrix path is a symlink" if File.symlink?(expected)
puts expected
RUBY
)"
matrix_dir="$(dirname "$matrix_path")"

if [[ -e "$matrix_path" || -L "$matrix_path" ]]; then
  ruby -rjson - "$matrix_path" "$batch_id" <<'RUBY'
matrix_path, batch_id = ARGV
matrix = JSON.parse(File.read(matrix_path))
expected = {
  "iphone-en" => ["iPhone", "en_US", "en"],
  "iphone-ja" => ["iPhone", "ja_JP", "ja"],
  "ipad-en" => ["iPad", "en_US", "en"],
  "ipad-ja" => ["iPad", "ja_JP", "ja"]
}
abort "blocked:environment: matrix is not a complete frozen batch matrix" unless matrix.keys.sort == ["batchId", "cases", "resolvedAt", "runtime", "schemaVersion"]
abort "blocked:environment: matrix is not a complete frozen batch matrix" unless matrix["schemaVersion"] == 1 && matrix["batchId"] == batch_id
runtime = matrix["runtime"]
abort "blocked:environment: matrix is not a complete frozen batch matrix" unless runtime.is_a?(Hash) && runtime.keys.sort == ["identifier", "version"] && runtime.values.all? { |value| value.is_a?(String) && !value.empty? }
cases = matrix["cases"]
abort "blocked:environment: matrix is not a complete frozen batch matrix" unless cases.is_a?(Array) && cases.length == 4
abort "blocked:environment: matrix is not a complete frozen batch matrix" unless cases.map { |entry| entry.is_a?(Hash) ? entry["id"] : nil } == %w[iphone-en iphone-ja ipad-en ipad-ja]
actual = {}
cases.each do |entry|
  abort "blocked:environment: matrix is not a complete frozen batch matrix" unless entry.is_a?(Hash) && entry.keys.sort == ["deviceType", "family", "id", "language", "locale", "udid"]
  type = entry["deviceType"]
  abort "blocked:environment: matrix is not a complete frozen batch matrix" unless type.is_a?(Hash) && type.keys.sort == ["identifier", "name"] && type.values.all? { |value| value.is_a?(String) && !value.empty? }
  abort "blocked:environment: matrix is not a complete frozen batch matrix" unless entry["udid"].is_a?(String) && entry["udid"].match?(/\A[0-9A-Fa-f-]+\z/)
  actual[entry["id"]] = [entry["family"], entry["locale"], entry["language"]]
end
abort "blocked:environment: matrix is not a complete frozen batch matrix" unless actual == expected && cases.map { |entry| entry["udid"] }.uniq.length == 4
RUBY

  devices_path="$matrix_dir/devices.json"
  temporary_devices="$(mktemp "$matrix_dir/.devices.XXXXXX")"
  trap 'rm -f "$temporary_devices"' EXIT
  "$xcrun_bin" simctl list devices -j >"$temporary_devices"
  mv "$temporary_devices" "$devices_path"
  trap - EXIT
  ruby -rjson - "$matrix_path" "$devices_path" "$batch_id" <<'RUBY'
matrix_path, devices_path, batch_id = ARGV
matrix = JSON.parse(File.read(matrix_path))
runtime = matrix.fetch("runtime").fetch("identifier")
device_buckets = JSON.parse(File.read(devices_path)).fetch("devices")
devices = device_buckets.values.flatten
matrix.fetch("cases").each do |entry|
  expected_name = "iOS-Template-#{batch_id}-#{entry.fetch("id")}"
  live = Array(device_buckets[runtime]).select { |device| device["udid"] == entry.fetch("udid") && device["name"] == expected_name && device["deviceTypeIdentifier"] == entry.fetch("deviceType").fetch("identifier") }
  abort "blocked:environment: recorded Simulator no longer matches its batch matrix" unless live.length == 1 && devices.count { |device| device["name"] == expected_name } == 1
end
RUBY
  echo "$matrix_path"
  exit 0
fi

capture_list() {
  local subject="$1"
  local destination="$matrix_dir/$subject.json"
  local temporary
  temporary="$(mktemp "$matrix_dir/.${subject}.XXXXXX")"
  "$xcrun_bin" simctl list "$subject" -j >"$temporary"
  mv "$temporary" "$destination"
}

capture_list runtimes
capture_list devicetypes
capture_list devices

working_matrix="$(mktemp "$matrix_dir/.simulator-matrix.XXXXXX")"
plan_file="$(mktemp "$matrix_dir/.creation-plan.XXXXXX")"
created_file="$(mktemp "$matrix_dir/.created-simulators.XXXXXX")"
trap 'rm -f "$working_matrix" "$plan_file" "$created_file"' EXIT

"$resolver_bin" tools/resolve-simulator-matrix.swift \
  --runtimes "$matrix_dir/runtimes.json" \
  --device-types "$matrix_dir/devicetypes.json" \
  --devices "$matrix_dir/devices.json" \
  --batch-id "$batch_id" >"$working_matrix"

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
  ruby -rjson - "$created_file" "$matrix_dir/creation-failure.json" "$failed_case" "$failed_name" <<'RUBY'
created_path, report_path, failed_case, failed_name = ARGV
created = File.readlines(created_path, chomp: true).map do |line|
  case_id, name, type, runtime, udid = line.split("\t", 5)
  {"id" => case_id, "name" => name, "deviceTypeIdentifier" => type, "runtimeIdentifier" => runtime, "udid" => udid}
end
File.write(report_path, JSON.pretty_generate({"status" => "blocked:environment", "failedCase" => failed_case, "failedName" => failed_name, "possibleDedicatedSimulators" => created}) + "\n")
RUBY
}

while IFS=$'\t' read -r case_id simulator_name device_type runtime; do
  if ! udid="$("$xcrun_bin" simctl create "$simulator_name" "$device_type" "$runtime")"; then
    record_failure "$case_id" "$simulator_name"
    echo "blocked:environment: Simulator creation failed; preserved possible dedicated Simulators in $matrix_dir/creation-failure.json" >&2
    exit 1
  fi
  [[ "$udid" =~ ^[0-9A-Fa-f-]+$ ]] || {
    record_failure "$case_id" "$simulator_name"
    echo "blocked:environment: simctl returned an invalid Simulator UDID; preserved possible dedicated Simulators in $matrix_dir/creation-failure.json" >&2
    exit 1
  }
  printf '%s\t%s\t%s\t%s\t%s\n' "$case_id" "$simulator_name" "$device_type" "$runtime" "$udid" >>"$created_file"
done <"$plan_file"

post_devices="$(mktemp "$matrix_dir/.post-devices.XXXXXX")"
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
mv "$working_matrix.next" "$working_matrix"
mv "$post_devices" "$matrix_dir/devices.json"

swift tools/simulator-matrix-io.swift \
  --directory "$matrix_dir" \
  --source "$(basename "$working_matrix")" \
  --destination "simulator-matrix.json"
rm -f "$working_matrix"
trap - EXIT
echo "$matrix_path"
