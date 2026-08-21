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
trap 'rm -rf "$scratch" "$io_helper" "$(dirname "$matrix")" "$(dirname "$partial_matrix")"' EXIT

fake_bin="$scratch/bin"
io_helper="/tmp/ios-template-lifecycle-helper-$$"
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
  slot = (sequence - 1) % 4 + 1
  mode = ENV["FAKE_CREATE_MODE"]
  abort "configured create failure" if mode == "fail-third" && slot == 3
 udid = format("00000000-0000-0000-0000-%012d", sequence)
 state = JSON.parse(File.read(state_path))
  returned_udid = mode == "repeat-udid" && slot == 2 ? format("00000000-0000-0000-0000-%012d", sequence - 1) : udid
  recorded_type = mode == "wrong-type" && slot == 4 ? "com.apple.CoreSimulator.SimDeviceType.Wrong" : device_type
  recorded_runtime = mode == "wrong-runtime" && slot == 4 ? "com.apple.CoreSimulator.SimRuntime.iOS-Wrong" : runtime
  state.fetch("devices")[recorded_runtime] ||= []
  state.fetch("devices").fetch(recorded_runtime) << {
   "udid" => udid,
   "name" => name,
   "state" => "Shutdown",
   "isAvailable" => true,
    "deviceTypeIdentifier" => recorded_type
 }
  if mode == "duplicate-name" && slot == 4
    state.fetch("devices").fetch(recorded_runtime) << {"udid" => "00000000-0000-0000-0000-999999999999", "name" => name, "state" => "Shutdown", "isAvailable" => true, "deviceTypeIdentifier" => recorded_type}
  end
 File.write(state_path, JSON.generate(state))
  puts returned_udid
when "delete"
  udid = ARGV.fetch(0)
  abort "expected one delete argument" unless ARGV.length == 1
  abort "configured delete failure" if ENV["FAKE_DELETE_MODE"] == "fail-first"
  state = JSON.parse(File.read(state_path))
  state.fetch("devices").each_value { |devices| devices.reject! { |device| device["udid"] == udid } }
  File.write(state_path, JSON.generate(state))
else
  abort "unexpected simctl command: #{command}"
end
RUBY
chmod +x "$fake_bin/xcrun"
swiftc tools/simulator-matrix-io.swift -o "$io_helper"

run() {
  XCRUN_BIN="$fake_bin/xcrun" \
  SIMULATOR_MATRIX_TESTING=1 \
  SIMULATOR_MATRIX_IO_TEST_BIN="$io_helper" \
  SIMULATOR_MATRIX_XCODE_JSON='{"path":"/Applications/Xcode.app/Contents/Developer","version":"26.5","build":"17F42"}' \
  FAKE_SIMCTL_LOG="$log" \
  FAKE_SIMCTL_STATE="$state" \
  FAKE_SIMCTL_FIXTURES="$repo_root/tools/tests/fixtures/simctl" \
  "$@"
}

run_with_create_mode() {
  local mode="$1"
  shift
  XCRUN_BIN="$fake_bin/xcrun" \
  SIMULATOR_MATRIX_TESTING=1 \
  SIMULATOR_MATRIX_IO_TEST_BIN="$io_helper" \
  SIMULATOR_MATRIX_XCODE_JSON='{"path":"/Applications/Xcode.app/Contents/Developer","version":"26.5","build":"17F42"}' \
  FAKE_CREATE_MODE="$mode" \
  FAKE_SIMCTL_LOG="$log" \
  FAKE_SIMCTL_STATE="$state" \
  FAKE_SIMCTL_FIXTURES="$repo_root/tools/tests/fixtures/simctl" \
  "$@"
}

run_with_delete_mode() {
  XCRUN_BIN="$fake_bin/xcrun" \
  SIMULATOR_MATRIX_TESTING=1 \
  SIMULATOR_MATRIX_IO_TEST_BIN="$io_helper" \
  SIMULATOR_MATRIX_XCODE_JSON='{"path":"/Applications/Xcode.app/Contents/Developer","version":"26.5","build":"17F42"}' \
  FAKE_DELETE_MODE="fail-first" \
  FAKE_SIMCTL_LOG="$log" \
  FAKE_SIMCTL_STATE="$state" \
  FAKE_SIMCTL_FIXTURES="$repo_root/tools/tests/fixtures/simctl" \
  "$@"
}

run_with_resolver() {
  local resolver="$1"
  shift
  XCRUN_BIN="$fake_bin/xcrun" \
  SIMULATOR_MATRIX_TESTING=1 \
  SIMULATOR_MATRIX_IO_TEST_BIN="$io_helper" \
  SIMULATOR_MATRIX_RESOLVER="$resolver" \
  SIMULATOR_MATRIX_XCODE_JSON='{"path":"/Applications/Xcode.app/Contents/Developer","version":"26.5","build":"17F42"}' \
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
simctl	list	devices	-j
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

malformed_resolver="$scratch/malformed-resolver"
printf '%s\n' '#!/usr/bin/env bash' 'printf "{\"schemaVersion\":1,\"batchId\":\"bad\",\"resolvedAt\":\"x\",\"runtime\":{},\"cases\":[]}"' >"$malformed_resolver"
chmod +x "$malformed_resolver"
malformed_batch="malformed-$RANDOM-$RANDOM"
: >"$log"
if run_with_resolver "$malformed_resolver" bash tools/resolve-simulator-matrix.sh --batch-id "$malformed_batch" --output ".artifacts/batches/$malformed_batch/simulator-matrix.json"; then
  echo "resolver accepted malformed pre-create matrix" >&2
  exit 1
fi
rm -rf ".artifacts/batches/$malformed_batch"
if rg -q '^simctl\tcreate\t' "$log"; then
  echo "malformed pre-create matrix reached simctl create" >&2
  exit 1
fi

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

delete_failure_batch="delete-failure-$RANDOM-$RANDOM"
delete_failure_matrix=".artifacts/batches/$delete_failure_batch/simulator-matrix.json"
run bash tools/resolve-simulator-matrix.sh --batch-id "$delete_failure_batch" --output "$delete_failure_matrix"
: >"$log"
if run_with_delete_mode bash tools/destroy-simulator-matrix.sh --matrix "$delete_failure_matrix"; then
  echo "destroy succeeded after configured delete failure" >&2
  exit 1
fi
[[ "$(wc -l <"$log")" -eq 2 ]] || { echo "destroy did not stop on first delete failure" >&2; exit 1; }
rm -rf "$(dirname "$delete_failure_matrix")"

mismatch_batch="mismatch-$RANDOM-$RANDOM"
mismatch_matrix=".artifacts/batches/$mismatch_batch/simulator-matrix.json"
run bash tools/resolve-simulator-matrix.sh --batch-id "$mismatch_batch" --output "$mismatch_matrix"
ruby -rjson - "$state" <<'RUBY'
path = ARGV.fetch(0)
state = JSON.parse(File.read(path))
state.fetch("devices").each_value do |devices|
  device = devices.find { |entry| entry["name"].start_with?("iOS-Template-mismatch-") }
  if device
    device["name"] = "tampered"
    break
  end
end
File.write(path, JSON.generate(state))
RUBY
: >"$log"
if run bash tools/destroy-simulator-matrix.sh --matrix "$mismatch_matrix"; then
  echo "destroy accepted a mismatched live Simulator" >&2
  exit 1
fi
[[ "$(wc -l <"$log")" -eq 1 ]] || { echo "destroy deleted before validating all targets" >&2; exit 1; }
rm -rf "$(dirname "$mismatch_matrix")"

for create_mode in repeat-udid duplicate-name wrong-type wrong-runtime; do
  mode_batch="mode-$create_mode-$RANDOM-$RANDOM"
  mode_matrix=".artifacts/batches/$mode_batch/simulator-matrix.json"
  : >"$log"
  : >"$log"
  if run_with_create_mode "$create_mode" bash tools/resolve-simulator-matrix.sh --batch-id "$mode_batch" --output "$mode_matrix"; then
    echo "resolver accepted $create_mode" >&2
    exit 1
  fi
  [[ ! -e "$mode_matrix" ]] || { echo "resolver published invalid $create_mode matrix" >&2; exit 1; }
  if rg -q '^simctl\tdelete\t' "$log"; then
    echo "resolver deleted an unvalidated UDID after $create_mode" >&2
    exit 1
  fi
  rm -rf "$(dirname "$mode_matrix")"
done

failed_batch="failed-$RANDOM-$RANDOM"
failed_matrix=".artifacts/batches/$failed_batch/simulator-matrix.json"
: >"$log"
if run_with_create_mode fail-third bash tools/resolve-simulator-matrix.sh --batch-id "$failed_batch" --output "$failed_matrix"; then
  echo "resolver succeeded after configured create failure" >&2
  exit 1
fi
[[ ! -e "$failed_matrix" ]] || { echo "resolver published an incomplete matrix" >&2; exit 1; }
if rg -q $'\tsimctl\tdelete\t|\tsimctl\tdelete$|^simctl\tdelete\t' "$log"; then
  echo "resolver deleted an unvalidated UDID after create failure" >&2
  exit 1
fi
rm -rf "$(dirname "$failed_matrix")"

symlink_batch="symlink-$RANDOM-$RANDOM"
mkdir -p .artifacts/batches "$scratch/symlink-target"
ln -s "$scratch/symlink-target" ".artifacts/batches/$symlink_batch"
if run bash tools/resolve-simulator-matrix.sh --batch-id "$symlink_batch" --output ".artifacts/batches/$symlink_batch/simulator-matrix.json"; then
  echo "resolver accepted a symlinked batch directory" >&2
  exit 1
fi
rm ".artifacts/batches/$symlink_batch"

for symlink_component in artifacts batches; do
  symlink_repo="$scratch/symlink-repo-$symlink_component"
  mkdir -p "$symlink_repo" "$scratch/symlink-$symlink_component-target"
  if [[ "$symlink_component" == "artifacts" ]]; then
    ln -s "$scratch/symlink-$symlink_component-target" "$symlink_repo/.artifacts"
  else
    mkdir "$symlink_repo/.artifacts"
    ln -s "$scratch/symlink-$symlink_component-target" "$symlink_repo/.artifacts/batches"
  fi
  if (cd "$symlink_repo" && "$io_helper" --operation exists --repo "$symlink_repo" --batch test-batch --name simulator-matrix.json >/dev/null); then
    echo "helper accepted a symlinked $symlink_component ancestor" >&2
    exit 1
  fi
done

io_batch="io-$RANDOM-$RANDOM"
io_source="$scratch/source.json"
printf 'first' >"$io_source"
"$io_helper" --operation publish --repo "$repo_root" --batch "$io_batch" --source "$io_source" --name simulator-matrix.json
printf 'second' >"$io_source"
if "$io_helper" --operation publish --repo "$repo_root" --batch "$io_batch" --source "$io_source" --name simulator-matrix.json; then
  echo "helper overwrote a published matrix" >&2
  exit 1
fi
published_copy="$scratch/published.json"
"$io_helper" --operation read --repo "$repo_root" --batch "$io_batch" --name simulator-matrix.json >"$published_copy"
[[ "$(cat "$published_copy")" == "first" ]] || { echo "publication collision changed final matrix" >&2; exit 1; }
ln -s "$io_source" "$scratch/symlink-source.json"
if "$io_helper" --operation write-unique --repo "$repo_root" --batch "$io_batch" --source "$scratch/symlink-source.json" --prefix creation-failure; then
  echo "helper accepted a symlinked failure-report source" >&2
  exit 1
fi
if (cd "$scratch" && "$io_helper" --operation read --repo "$repo_root" --batch "$io_batch" --name simulator-matrix.json >/dev/null); then
  echo "helper accepted a mismatched inherited repository root" >&2
  exit 1
fi
rm -rf ".artifacts/batches/$io_batch"
if find .artifacts/batches -type f -name '.*' -print -quit | rg -q .; then
  echo "lifecycle left a hidden batch temporary file" >&2
  exit 1
fi

echo "all simulator lifecycle tests passed"
