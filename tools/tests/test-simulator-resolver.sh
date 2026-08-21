#!/usr/bin/env bash
set -euo pipefail

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
    --devices "$3" \
    --batch-id settings-2026-08-21 \
    --resolved-at 2026-08-21T12:00:00+09:00 \
    >"$output" 2>"$errors"
}

assert_matrix() {
  ruby -rjson - "$output" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
abort "unexpected schema version" unless matrix["schemaVersion"] == 1
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

run_resolver "$fixtures/runtimes.json" "$fixtures/devicetypes.json" "$fixtures/devices.json"
assert_matrix

no_pro="$scratch/no-pro.json"
ruby -rjson - "$fixtures/devicetypes.json" "$no_pro" <<'RUBY'
source, destination = ARGV
document = JSON.parse(File.read(source))
document["devicetypes"].reject! { |entry| entry["name"].start_with?("iPhone") }
File.write(destination, JSON.generate(document))
RUBY
expect_failure "no matching iPhone Pro Device Type" "$fixtures/runtimes.json" "$no_pro" "$fixtures/devices.json"

no_air="$scratch/no-air.json"
ruby -rjson - "$fixtures/devicetypes.json" "$no_air" <<'RUBY'
source, destination = ARGV
document = JSON.parse(File.read(source))
document["devicetypes"].reject! { |entry| entry["name"].start_with?("iPad Air") }
File.write(destination, JSON.generate(document))
RUBY
expect_failure "no matching iPad Air Device Type" "$fixtures/runtimes.json" "$no_air" "$fixtures/devices.json"

echo "all simulator resolver tests passed"
