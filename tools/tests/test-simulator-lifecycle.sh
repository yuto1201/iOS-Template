#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

scratch="$(mktemp -d -t simulator-lifecycle.XXXXXX)"
batch_id="lifecycle-$RANDOM-$RANDOM"
partial_batch="partial-$RANDOM-$RANDOM"
matrix=".artifacts/batches/$batch_id/simulator-matrix.json"
partial_matrix=".artifacts/batches/$partial_batch/simulator-matrix.json"
[[ ! -e "$matrix" && ! -L "$matrix" && ! -e "$partial_matrix" && ! -L "$partial_matrix" ]] || {
  echo "test batch artifact unexpectedly already exists" >&2
  exit 1
}
trap 'rm -rf "$scratch" "$(dirname "$matrix")" "$(dirname "$partial_matrix")"' EXIT

fake_bin="$scratch/bin"
state="$scratch/devices.json"
log="$scratch/xcrun.log"
mkdir -p "$fake_bin"
cp tools/tests/fixtures/simctl/devices.json "$state"

cat >"$fake_bin/xcrun" <<'RUBY'
#!/usr/bin/env ruby
require "json"

log = ENV.fetch("FAKE_SIMCTL_LOG")
state_path = ENV.fetch("FAKE_SIMCTL_STATE")
fixtures = ENV.fetch("FAKE_SIMCTL_FIXTURES")
File.open(log, "a") { |file| file.puts(ARGV.join("\t")) }

abort "expected simctl" unless ARGV.shift == "simctl"
command = ARGV.shift
case command
when "list"
  subject, format = ARGV
  abort "expected JSON list" unless format == "-j"
  path = subject == "devices" ? state_path : File.join(fixtures, "#{subject}.json")
  print File.read(path)
when "create"
  name, device_type, runtime = ARGV
  abort "expected create arguments" unless name && device_type && runtime && ARGV.length == 3
  sequence = File.exist?("#{state_path}.sequence") ? File.read("#{state_path}.sequence").to_i + 1 : 1
  File.write("#{state_path}.sequence", sequence.to_s)
  udid = format("00000000-0000-0000-0000-%012d", sequence)
  state = JSON.parse(File.read(state_path))
  state.fetch("devices").fetch(runtime) << {
    "udid" => udid,
    "name" => name,
    "state" => "Shutdown",
    "isAvailable" => true,
    "deviceTypeIdentifier" => device_type
  }
  File.write(state_path, JSON.generate(state))
  puts udid
when "delete"
  udid = ARGV.fetch(0)
  abort "expected one delete argument" unless ARGV.length == 1
  state = JSON.parse(File.read(state_path))
  state.fetch("devices").each_value { |devices| devices.reject! { |device| device["udid"] == udid } }
  File.write(state_path, JSON.generate(state))
else
  abort "unexpected simctl command: #{command}"
end
RUBY
chmod +x "$fake_bin/xcrun"

run() {
  XCRUN_BIN="$fake_bin/xcrun" \
  FAKE_SIMCTL_LOG="$log" \
  FAKE_SIMCTL_STATE="$state" \
  FAKE_SIMCTL_FIXTURES="$repo_root/tools/tests/fixtures/simctl" \
  "$@"
}

run bash tools/resolve-simulator-matrix.sh --batch-id "$batch_id" --output "$matrix"
ruby -rjson - "$matrix" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
abort "expected exactly four cases" unless matrix.fetch("cases").length == 4
expected = {
  "iphone-en" => "00000000-0000-0000-0000-000000000001",
  "iphone-ja" => "00000000-0000-0000-0000-000000000002",
  "ipad-en" => "00000000-0000-0000-0000-000000000003",
  "ipad-ja" => "00000000-0000-0000-0000-000000000004"
}
actual = matrix.fetch("cases").to_h { |entry| [entry.fetch("id"), entry.fetch("udid")] }
abort "unexpected created UDIDs: #{actual.inspect}" unless actual == expected
RUBY

expected_create_log="$scratch/expected-create.log"
cat >"$expected_create_log" <<EOF
simctl	list	runtimes	-j
simctl	list	devicetypes	-j
simctl	list	devices	-j
simctl	create	iOS-Template-$batch_id-iphone-en	com.apple.CoreSimulator.SimDeviceType.iPhone-10-Pro	com.apple.CoreSimulator.SimRuntime.iOS-10-3
simctl	create	iOS-Template-$batch_id-iphone-ja	com.apple.CoreSimulator.SimDeviceType.iPhone-10-Pro	com.apple.CoreSimulator.SimRuntime.iOS-10-3
simctl	create	iOS-Template-$batch_id-ipad-en	com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3	com.apple.CoreSimulator.SimRuntime.iOS-10-3
simctl	create	iOS-Template-$batch_id-ipad-ja	com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3	com.apple.CoreSimulator.SimRuntime.iOS-10-3
EOF
cmp -s "$expected_create_log" "$log" || { diff -u "$expected_create_log" "$log"; exit 1; }

: >"$log"
run bash tools/resolve-simulator-matrix.sh --batch-id "$batch_id" --output "$matrix"
printf 'simctl\tlist\tdevices\t-j\n' >"$scratch/expected-reuse.log"
cmp -s "$scratch/expected-reuse.log" "$log" || { diff -u "$scratch/expected-reuse.log" "$log"; exit 1; }

mkdir -p "$(dirname "$partial_matrix")"
printf '{"schemaVersion":1,"batchId":"%s","cases":[]}' "$partial_batch" >"$partial_matrix"
: >"$log"
if run bash tools/resolve-simulator-matrix.sh --batch-id "$partial_batch" --output "$partial_matrix"; then
  echo "resolver overwrote a partial matrix" >&2
  exit 1
fi
[[ ! -s "$log" ]] || { echo "partial matrix invoked simctl" >&2; exit 1; }

: >"$log"
run bash tools/destroy-simulator-matrix.sh --matrix "$matrix"
expected_delete_log="$scratch/expected-delete.log"
cat >"$expected_delete_log" <<EOF
simctl	list	devices	-j
simctl	delete	00000000-0000-0000-0000-000000000001
simctl	delete	00000000-0000-0000-0000-000000000002
simctl	delete	00000000-0000-0000-0000-000000000003
simctl	delete	00000000-0000-0000-0000-000000000004
EOF
cmp -s "$expected_delete_log" "$log" || { diff -u "$expected_delete_log" "$log"; exit 1; }

echo "all simulator lifecycle tests passed"
