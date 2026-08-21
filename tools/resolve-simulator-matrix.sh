#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"
xcrun_bin="${XCRUN_BIN:-xcrun}"

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
actual = {}
cases.each do |entry|
  abort "blocked:environment: matrix is not a complete frozen batch matrix" unless entry.is_a?(Hash) && entry.keys.sort == ["deviceType", "family", "id", "language", "locale", "udid"]
  type = entry["deviceType"]
  abort "blocked:environment: matrix is not a complete frozen batch matrix" unless type.is_a?(Hash) && type.keys.sort == ["identifier", "name"] && type.values.all? { |value| value.is_a?(String) && !value.empty? }
  abort "blocked:environment: matrix is not a complete frozen batch matrix" unless entry["udid"].is_a?(String) && entry["udid"].match?(/\A[0-9A-Fa-f-]+\z/)
  actual[entry["id"]] = [entry["family"], entry["locale"], entry["language"]]
end
abort "blocked:environment: matrix is not a complete frozen batch matrix" unless actual == expected
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
devices = JSON.parse(File.read(devices_path)).fetch("devices").values.flatten
matrix.fetch("cases").each do |entry|
  expected_name = "iOS-Template-#{batch_id}-#{entry.fetch("id")}"
  live = devices.select { |device| device["udid"] == entry.fetch("udid") }
  abort "blocked:environment: recorded Simulator no longer matches its batch matrix" unless live.length == 1 && live.first["name"] == expected_name
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
created_udids=()
cleanup_created() {
  local udid
  for udid in "${created_udids[@]}"; do
    "$xcrun_bin" simctl delete "$udid" || true
  done
  rm -f "$working_matrix"
}
trap cleanup_created ERR INT TERM

swift tools/resolve-simulator-matrix.swift \
  --runtimes "$matrix_dir/runtimes.json" \
  --device-types "$matrix_dir/devicetypes.json" \
  --devices "$matrix_dir/devices.json" \
  --batch-id "$batch_id" >"$working_matrix"

while IFS=$'\t' read -r case_id device_type runtime; do
  simulator_name="iOS-Template-$batch_id-$case_id"
  udid="$("$xcrun_bin" simctl create "$simulator_name" "$device_type" "$runtime")"
  [[ "$udid" =~ ^[0-9A-Fa-f-]+$ ]] || {
    echo "blocked:environment: simctl returned an invalid Simulator UDID" >&2
    exit 1
  }
  created_udids+=("$udid")
  ruby -rjson - "$working_matrix" "$case_id" "$udid" <<'RUBY'
path, case_id, udid = ARGV
matrix = JSON.parse(File.read(path))
entry = matrix.fetch("cases").find { |candidate| candidate["id"] == case_id }
abort "blocked:environment: resolver returned an unexpected matrix case" unless entry && !entry.key?("udid")
entry["udid"] = udid
temporary = "#{path}.next"
File.write(temporary, JSON.pretty_generate(matrix) + "\n")
File.rename(temporary, path)
RUBY
done < <(ruby -rjson - "$working_matrix" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
expected = %w[iphone-en iphone-ja ipad-en ipad-ja]
abort "blocked:environment: resolver did not return exactly four stable cases" unless matrix.fetch("cases").map { |entry| entry["id"] } == expected
matrix.fetch("cases").each do |entry|
  type = entry.fetch("deviceType")
  puts [entry.fetch("id"), type.fetch("identifier"), matrix.fetch("runtime").fetch("identifier")].join("\t")
end
RUBY
)

ln "$working_matrix" "$matrix_path"
rm -f "$working_matrix"
trap - ERR INT TERM
echo "$matrix_path"
