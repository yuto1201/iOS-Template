#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"
xcrun_bin="${XCRUN_BIN:-xcrun}"

usage() {
  echo "usage: destroy-simulator-matrix.sh --matrix <path>" >&2
  exit 2
}

[[ $# -eq 2 && $1 == "--matrix" ]] || usage
matrix_argument="$2"

matrix_path="$(ruby - "$repo_root" "$matrix_argument" <<'RUBY'
repo, argument = ARGV
repo = File.realpath(repo)
batches = File.join(repo, ".artifacts", "batches")
path = File.expand_path(argument, Dir.pwd)
abort "blocked:environment: matrix must be under .artifacts/batches" unless path.start_with?(batches + File::SEPARATOR)
parts = path.delete_prefix(batches + File::SEPARATOR).split(File::SEPARATOR)
abort "blocked:environment: matrix must be a batch simulator-matrix.json" unless parts.length == 2 && parts.last == "simulator-matrix.json"
batch_id = parts.first
abort "blocked:environment: invalid batch ID" unless batch_id.match?(/\A[A-Za-z0-9][A-Za-z0-9-]{0,63}\z/)

current = repo
[".artifacts", "batches", batch_id].each do |component|
  current = File.join(current, component)
  abort "blocked:environment: artifact path contains a symlink" if File.symlink?(current)
  abort "blocked:environment: matrix path is unavailable" unless File.directory?(current)
end
abort "blocked:environment: matrix path is a symlink" if File.symlink?(path)
abort "blocked:environment: matrix path is unavailable" unless File.file?(path)
abort "blocked:environment: artifact directory escaped repository" unless File.realpath(File.dirname(path)) == File.dirname(path)
puts path
RUBY
)"

batch_id="$(basename "$(dirname "$matrix_path")")"
devices_path="$(dirname "$matrix_path")/devices.json"
temporary_devices="$(mktemp "$(dirname "$matrix_path")/.devices.XXXXXX")"
trap 'rm -f "$temporary_devices"' EXIT
"$xcrun_bin" simctl list devices -j >"$temporary_devices"
mv "$temporary_devices" "$devices_path"
trap - EXIT

validated_udids="$(mktemp "$(dirname "$matrix_path")/.validated-udids.XXXXXX")"
trap 'rm -f "$validated_udids"' EXIT
ruby -rjson - "$matrix_path" "$devices_path" "$batch_id" "$validated_udids" <<'RUBY'
matrix_path, devices_path, batch_id, validated_udids_path = ARGV
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
udids = []
cases.each do |entry|
  abort "blocked:environment: matrix is not a complete frozen batch matrix" unless entry.is_a?(Hash) && entry.keys.sort == ["deviceType", "family", "id", "language", "locale", "udid"]
  type = entry["deviceType"]
  abort "blocked:environment: matrix is not a complete frozen batch matrix" unless type.is_a?(Hash) && type.keys.sort == ["identifier", "name"] && type.values.all? { |value| value.is_a?(String) && !value.empty? }
  udid = entry["udid"]
  abort "blocked:environment: matrix is not a complete frozen batch matrix" unless udid.is_a?(String) && udid.match?(/\A[0-9A-Fa-f-]+\z/)
  actual[entry["id"]] = [entry["family"], entry["locale"], entry["language"]]
  udids << [entry["id"], udid]
end
abort "blocked:environment: matrix is not a complete frozen batch matrix" unless actual == expected && udids.map(&:last).uniq.length == 4

runtime_id = matrix.fetch("runtime").fetch("identifier")
buckets = JSON.parse(File.read(devices_path)).fetch("devices")
devices = buckets.values.flatten
udids.each do |case_id, udid|
  expected_name = "iOS-Template-#{batch_id}-#{case_id}"
  case_entry = cases.find { |entry| entry["id"] == case_id }
  live = Array(buckets[runtime_id]).select { |device| device["udid"] == udid && device["name"] == expected_name && device["deviceTypeIdentifier"] == case_entry.fetch("deviceType").fetch("identifier") }
  abort "blocked:environment: recorded Simulator no longer matches its batch matrix" unless live.length == 1 && devices.count { |device| device["name"] == expected_name } == 1
end
File.write(validated_udids_path, udids.map(&:last).join("\n") + "\n")
RUBY

while IFS= read -r udid; do
  "$xcrun_bin" simctl delete "$udid"
done <"$validated_udids"
