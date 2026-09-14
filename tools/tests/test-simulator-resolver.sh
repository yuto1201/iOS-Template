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

run_resolver() {
  swift "$resolver" \
    --runtimes "$1" \
    --device-types "$2" \
    --batch-id settings-2026-08-21 \
    --resolved-at 2026-08-21T12:00:00+09:00 \
    "${@:3}" \
    >"$output" 2>"$errors"
}

assert_matrix() {
  ruby -rjson - "$output" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
abort "unexpected schema version" unless matrix["schemaVersion"] == 2
abort "unexpected batch ID" unless matrix["batchId"] == "settings-2026-08-21"
abort "unexpected resolution time" unless matrix["resolvedAt"] == "2026-08-21T12:00:00+09:00"
runtime = matrix.fetch("runtime")
abort "did not select semantically newest available runtime" unless runtime == {
  "identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-10-3",
  "version" => "10.3"
}
expected_cases = [
  ["iphone-en", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-10-Pro", "iPhone 10 Pro", "en_US", "en"],
  ["iphone-ja", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-10-Pro", "iPhone 10 Pro", "ja_JP", "ja"],
  ["ipad-en", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "en_US", "en"],
  ["ipad-ja", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "ja_JP", "ja"]
]
actual_cases = matrix.fetch("cases").map do |entry|
  type = entry.fetch("deviceType")
  abort "Device Type must be an identifier/name object" unless type.keys.sort == ["identifier", "name"]
  [entry.fetch("id"), entry.fetch("family"), type.fetch("identifier"), type.fetch("name"), entry.fetch("locale"), entry.fetch("language")]
end
abort "unexpected matrix cases: #{actual_cases.inspect}" unless actual_cases == expected_cases
RUBY
}

expect_failure() {
  local label="$1"
  shift
  local status
  set +e
  run_resolver "$@"
  status=$?
  set -e
  [[ $status -ne 0 ]] || {
    echo "resolver unexpectedly succeeded without $label" >&2
    exit 1
  }
  grep -Fq "$label" "$errors" || {
    echo "resolver did not report $label: $(<"$errors")" >&2
    exit 1
  }
}

run_resolver "$fixtures/runtimes.json" "$fixtures/devicetypes.json"
assert_matrix

run_resolver "$fixtures/runtimes.json" "$fixtures/devicetypes-m4-vs-5th.json"
ruby -rjson - "$output" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
expected = [
  ["ipad-en", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M4", "iPad Air 13-inch (M4)"],
  ["ipad-ja", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M4", "iPad Air 13-inch (M4)"]
]
actual = matrix.fetch("cases").select { |entry| entry.fetch("family") == "iPad" }.map do |entry|
  type = entry.fetch("deviceType")
  [entry.fetch("id"), type.fetch("identifier"), type.fetch("name")]
end
abort "M4 iPad Air must outrank 5th generation and prefer 13-inch: #{actual.inspect}" unless actual == expected
RUBY

tie_runtimes="$scratch/tie-runtimes.json"
ruby -rjson - "$fixtures/runtimes.json" "$tie_runtimes" <<'RUBY'
source, destination = ARGV
document = JSON.parse(File.read(source))
document["runtimes"] << {
  "identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-10-3-z",
  "version" => "10.3",
  "isAvailable" => true,
  "name" => "iOS 10.3 z"
}
File.write(destination, JSON.generate(document))
RUBY
run_resolver "$tie_runtimes" "$fixtures/devicetypes.json"
assert_matrix

tie_device_types="$scratch/tie-device-types.json"
ruby -rjson - "$fixtures/devicetypes.json" "$tie_device_types" <<'RUBY'
source, destination = ARGV
document = JSON.parse(File.read(source))
document["devicetypes"] << {
  "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-10-Pro-z",
  "name" => "iPhone 10 Pro",
  "productFamily" => "iPhone"
}
document["devicetypes"] << {
  "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3-z",
  "name" => "iPad Air 13-inch (M3)",
  "productFamily" => "iPad"
}
File.write(destination, JSON.generate(document))
RUBY
run_resolver "$fixtures/runtimes.json" "$tie_device_types"
assert_matrix

no_pro="$scratch/no-pro.json"
ruby -rjson - "$fixtures/devicetypes.json" "$no_pro" <<'RUBY'
source, destination = ARGV
document = JSON.parse(File.read(source))
document["devicetypes"].reject! { |entry| entry["name"].start_with?("iPhone") }
File.write(destination, JSON.generate(document))
RUBY
expect_failure "no matching iPhone Pro Device Type" "$fixtures/runtimes.json" "$no_pro"

no_air="$scratch/no-air.json"
ruby -rjson - "$fixtures/devicetypes.json" "$no_air" <<'RUBY'
source, destination = ARGV
document = JSON.parse(File.read(source))
document["devicetypes"].reject! { |entry| entry["name"].start_with?("iPad Air") }
File.write(destination, JSON.generate(document))
RUBY
expect_failure "no matching iPad Air Device Type" "$fixtures/runtimes.json" "$no_air"

# Partial coverage must not even resolve an iPad, and is never an arbitrary subset.
run_resolver "$fixtures/runtimes.json" "$no_air" --scope iphone-ja
ruby -rjson - "$output" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
abort "partial scope missing" unless matrix["scope"] == "iphone-ja"
abort "partial resolver did not select exactly Japanese iPhone" unless matrix["cases"].map { |c| [c["id"], c["language"], c["locale"]] } == [["iphone-ja", "ja", "ja_JP"]]
abort "partial resolver used an older runtime" unless matrix.dig("runtime", "version") == "10.3"
RUBY
run_resolver "$fixtures/runtimes.json" "$fixtures/devicetypes.json" --scope targeted --case-ids iphone-en,ipad-ja
ruby -rjson - "$output" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
abort "targeted scope missing" unless matrix["scope"] == "targeted"
abort "targeted resolver changed the ordered subset" unless matrix.fetch("cases").map { |entry| entry.fetch("id") } == ["iphone-en", "ipad-ja"]
RUBY
expect_failure "usage:" "$fixtures/runtimes.json" "$fixtures/devicetypes.json" --scope targeted
expect_failure "usage:" "$fixtures/runtimes.json" "$fixtures/devicetypes.json" --scope targeted --case-ids ipad-ja,iphone-en
expect_failure "usage:" "$fixtures/runtimes.json" "$fixtures/devicetypes.json" --scope full --case-ids iphone-ja
expect_failure "usage:" "$fixtures/runtimes.json" "$fixtures/devicetypes.json" --scope other
expect_failure "usage:" "$fixtures/runtimes.json" "$fixtures/devicetypes.json" --scope iphone-ja --scope full
expect_failure "usage:" "$fixtures/runtimes.json" "$fixtures/devicetypes.json" --devices "$fixtures/devices.json"

malformed_versions=(
  '10..3'
  '10.a'
  '999999999999999999999999999999999999999999999999999999999999999999'
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
  expect_failure "invalid available iOS Runtime version" "$malformed_runtimes" "$fixtures/devicetypes.json"
done

echo "all simulator resolver tests passed"
