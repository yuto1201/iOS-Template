#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby swift

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

resolver="tools/resolve-simulator-matrix.swift"
fixtures="tools/tests/fixtures/simctl"
output="$(mktemp -t simulator-resolver-output.XXXXXX)"
errors="$(mktemp -t simulator-resolver-errors.XXXXXX)"
scratch="$(mktemp -d -t simulator-resolver-fixtures.XXXXXX)"
trap 'rm -f "$output" "$errors"; rm -rf "$scratch"' EXIT

# write_config PATH [JSON-EDIT-RUBY] writes a dedicated declaration for the fixture iOS 10.3 devices.
write_config() {
  ruby -rjson - "$1" "${2-}" <<'RUBY'
path, edit = ARGV
config = {
  "schemaVersion" => 1,
  "devices" => [
    {"family" => "iphone", "name" => "Resolver iPhone", "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-10-Pro", "runtimeIdentifier" => "com.apple.CoreSimulator.SimRuntime.iOS-10-3"},
    {"family" => "ipad", "name" => "Resolver iPad", "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "runtimeIdentifier" => "com.apple.CoreSimulator.SimRuntime.iOS-10-3"}
  ]
}
eval(edit) unless edit.to_s.empty?
File.write(path, JSON.generate(config))
RUBY
}

config="$scratch/dedicated.json"
write_config "$config"

run_resolver() {
  local runtimes="$1" device_types="$2" dedicated="$3"
  shift 3
  swift "$resolver" \
    --runtimes "$runtimes" \
    --device-types "$device_types" \
    --dedicated-config "$dedicated" \
    --batch-id settings-2026-08-21 \
    --resolved-at 2026-08-21T12:00:00+09:00 \
    "$@" \
    >"$output" 2>"$errors"
}

expect_failure() {
  local label="$1"
  shift
  if swift "$resolver" "$@" --batch-id settings-2026-08-21 >"$output" 2>"$errors"; then
    echo "resolver unexpectedly succeeded without $label" >&2
    exit 1
  fi
  grep -Fq -- "$label" "$errors" || {
    echo "resolver did not report $label: $(<"$errors")" >&2
    exit 1
  }
}

# The declared Runtime and Device Types are used as-is; no newest-device search remains.
run_resolver "$fixtures/runtimes.json" "$fixtures/devicetypes.json" "$config"
ruby -rjson - "$output" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
abort "unexpected schema version" unless matrix["schemaVersion"] == 2
abort "unexpected batch ID" unless matrix["batchId"] == "settings-2026-08-21"
abort "unexpected resolution time" unless matrix["resolvedAt"] == "2026-08-21T12:00:00+09:00"
abort "did not use the declared Runtime" unless matrix.fetch("runtime") == {
  "identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-10-3", "version" => "10.3"
}
expected_cases = [
  ["iphone-en", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-10-Pro", "iPhone 10 Pro", "en_US", "en"],
  ["iphone-ja", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-10-Pro", "iPhone 10 Pro", "ja_JP", "ja"],
  ["ipad-en", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "en_US", "en"],
  ["ipad-ja", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "ja_JP", "ja"]
]
actual = matrix.fetch("cases").map do |entry|
  abort "matrix case carries an execution UDID or name" if entry.key?("udid") || entry.key?("deviceName")
  type = entry.fetch("deviceType")
  [entry.fetch("id"), entry.fetch("family"), type.fetch("identifier"), type.fetch("name"), entry.fetch("locale"), entry.fetch("language")]
end
abort "unexpected matrix cases: #{actual.inspect}" unless actual == expected_cases
RUBY

# The repository declaration resolves to the dedicated iOS 27 iPhone 17 Pro Max and iPad Pro 13-inch (M5) when installed.
available_runtimes="$scratch/runtimes-27.json"
ruby -rjson - "$fixtures/runtimes.json" "$available_runtimes" <<'RUBY'
source, destination = ARGV
document = JSON.parse(File.read(source))
document["runtimes"].find { |entry| entry["identifier"] == "com.apple.CoreSimulator.SimRuntime.iOS-27-0" }["isAvailable"] = true
File.write(destination, JSON.generate(document))
RUBY
dedicated_types="$scratch/devicetypes-a16.json"
ruby -rjson - "$fixtures/devicetypes.json" "$dedicated_types" <<'RUBY'
source, destination = ARGV
document = JSON.parse(File.read(source))
File.write(destination, JSON.generate(document))
RUBY
run_resolver "$available_runtimes" "$dedicated_types" Config/dedicated-simulators.json
ruby -rjson - "$output" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
abort "repository declaration did not use iOS 27.0" unless matrix.dig("runtime", "identifier") == "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
names = matrix.fetch("cases").map { |entry| entry.dig("deviceType", "name") }
abort "repository declaration did not use the dedicated devices: #{names.inspect}" unless names == ["iPhone 17 Pro Max", "iPhone 17 Pro Max", "iPad Pro 13-inch (M5)", "iPad Pro 13-inch (M5)"]
RUBY

# An unavailable declared Runtime or a missing declared Device Type stops without a fallback.
unavailable_runtimes="$scratch/runtimes-unavailable.json"
ruby -rjson - "$fixtures/runtimes.json" "$unavailable_runtimes" <<'RUBY'
source, destination = ARGV
document = JSON.parse(File.read(source))
document["runtimes"].find { |entry| entry["identifier"] == "com.apple.CoreSimulator.SimRuntime.iOS-27-0" }["isAvailable"] = false
File.write(destination, JSON.generate(document))
RUBY
no_a16_types="$scratch/devicetypes-no-a16.json"
ruby -rjson - "$fixtures/devicetypes.json" "$no_a16_types" <<'RUBY'
source, destination = ARGV
document = JSON.parse(File.read(source))
document["devicetypes"].reject! { |entry| entry["identifier"] == "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB" }
File.write(destination, JSON.generate(document))
RUBY
expect_failure "declared Runtime is not installed and available: com.apple.CoreSimulator.SimRuntime.iOS-27-0" \
  --runtimes "$unavailable_runtimes" --device-types "$dedicated_types" --dedicated-config Config/dedicated-simulators.json
expect_failure "declared Device Type is not installed: com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB" \
  --runtimes "$available_runtimes" --device-types "$no_a16_types" --dedicated-config Config/dedicated-simulators.json

# Partial scopes resolve only their family, so a missing iPad type does not block the Japanese iPhone.
no_ipad_types="$scratch/no-ipad.json"
ruby -rjson - "$fixtures/devicetypes.json" "$no_ipad_types" <<'RUBY'
source, destination = ARGV
document = JSON.parse(File.read(source))
document["devicetypes"].reject! { |entry| entry["name"].start_with?("iPad") }
File.write(destination, JSON.generate(document))
RUBY
expect_failure "declared Device Type is not installed: com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3" \
  --runtimes "$fixtures/runtimes.json" --device-types "$no_ipad_types" --dedicated-config "$config"
run_resolver "$fixtures/runtimes.json" "$no_ipad_types" "$config" --scope iphone-ja
ruby -rjson - "$output" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
abort "partial scope missing" unless matrix["scope"] == "iphone-ja"
abort "partial resolver did not select exactly Japanese iPhone" unless matrix["cases"].map { |c| [c["id"], c["language"], c["locale"]] } == [["iphone-ja", "ja", "ja_JP"]]
RUBY
run_resolver "$fixtures/runtimes.json" "$fixtures/devicetypes.json" "$config" --scope targeted --case-ids iphone-en,ipad-ja
ruby -rjson - "$output" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
abort "targeted scope missing" unless matrix["scope"] == "targeted"
abort "targeted resolver changed the ordered subset" unless matrix.fetch("cases").map { |entry| entry.fetch("id") } == ["iphone-en", "ipad-ja"]
RUBY

# Invalid declarations are rejected.
invalid_edits=(
  'config["devices"].reverse!'
  'config["devices"][1]["name"] = config["devices"][0]["name"]'
  'config["devices"][0]["name"] = "iOS-Template-runner-iphone"'
  'config["devices"][1]["runtimeIdentifier"] = "com.apple.CoreSimulator.SimRuntime.iOS-9-12"'
  'config["schemaVersion"] = 2'
  'config["devices"][0]["deviceTypeIdentifier"] = "iPhone 10 Pro"'
)
for edit in "${invalid_edits[@]}"; do
  write_config "$scratch/invalid.json" "$edit"
  expect_failure "invalid dedicated Simulator declaration" \
    --runtimes "$fixtures/runtimes.json" --device-types "$fixtures/devicetypes.json" --dedicated-config "$scratch/invalid.json"
done

# Usage errors, including a missing declaration.
common_inputs=(--runtimes "$fixtures/runtimes.json" --device-types "$fixtures/devicetypes.json")
expect_failure "usage:" "${common_inputs[@]}"
expect_failure "usage:" "${common_inputs[@]}" --dedicated-config "$config" --scope targeted
expect_failure "usage:" "${common_inputs[@]}" --dedicated-config "$config" --scope targeted --case-ids ipad-ja,iphone-en
expect_failure "usage:" "${common_inputs[@]}" --dedicated-config "$config" --scope full --case-ids iphone-ja
expect_failure "usage:" "${common_inputs[@]}" --dedicated-config "$config" --scope other
expect_failure "usage:" "${common_inputs[@]}" --dedicated-config "$config" --scope iphone-ja --scope full
expect_failure "usage:" "${common_inputs[@]}" --dedicated-config "$config" --devices "$fixtures/devices.json"

malformed_versions=(
  '10..3'
  '10.a'
  ''
)
for malformed_version in "${malformed_versions[@]}"; do
  malformed_runtimes="$scratch/malformed-runtime.json"
  ruby -rjson - "$fixtures/runtimes.json" "$malformed_runtimes" "$malformed_version" <<'RUBY'
source, destination, version = ARGV
document = JSON.parse(File.read(source))
document["runtimes"].find { |entry| entry["identifier"] == "com.apple.CoreSimulator.SimRuntime.iOS-10-3" }["version"] = version
File.write(destination, JSON.generate(document))
RUBY
  expect_failure "invalid declared Runtime version" \
    --runtimes "$malformed_runtimes" --device-types "$fixtures/devicetypes.json" --dedicated-config "$config"
done

echo "all simulator resolver tests passed"
