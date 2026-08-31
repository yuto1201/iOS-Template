#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

scratch="$(mktemp -d -t simulator-lifecycle.XXXXXX)"
mkdir -p "$scratch/tmp"
batch_id="lifecycle-$RANDOM-$RANDOM"
partial_batch="partial-$RANDOM-$RANDOM"
scoped_batch="ja-$RANDOM-$RANDOM"
matrix=".artifacts/batches/$batch_id/simulator-matrix.json"
partial_matrix=".artifacts/batches/$partial_batch/simulator-matrix.json"
scoped_matrix=".artifacts/batches/$scoped_batch/simulator-matrix.json"
[[ ! -e "$matrix" && ! -L "$matrix" && ! -e "$partial_matrix" && ! -L "$partial_matrix" ]] || {
  echo "test batch artifact unexpectedly already exists" >&2
  exit 1
}
trap 'rm -rf "$scratch" "$(dirname "$matrix")" "$(dirname "$partial_matrix")" "$(dirname "$scoped_matrix")"' EXIT

fake_bin="$scratch/bin"
io_helper="$scratch/simulator-matrix-io"
state="$scratch/devices.json"
log="$scratch/xcrun.log"
xcode_log="$scratch/xcode.log"
mkdir -p "$fake_bin"
cp tools/tests/fixtures/simctl/devices.json "$state"

cat >"$fake_bin/xcrun" <<'RUBY'
#!/usr/bin/ruby --disable-gems
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
  abort "configured list failure" if ENV["FAKE_LIST_MODE"] == "fail-devicetypes" && subject == "devicetypes"
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
cat >"$fake_bin/xcode-select" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcode-select\t%s\n' "$*" >>"$FAKE_XCODE_LOG"
[[ "$#" -eq 1 && "$1" == "-p" ]]
printf '%s\n' '/Applications/Fake Xcode.app/Contents/Developer'
SH
chmod +x "$fake_bin/xcode-select"

cat >"$fake_bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodebuild\t%s\n' "$*" >>"$FAKE_XCODE_LOG"
[[ "$#" -eq 1 && "$1" == "-version" ]]
printf '%s\n' 'Xcode 26.5' 'Build version 17F42'
SH
chmod +x "$fake_bin/xcodebuild"

real_swift="$(command -v swift)"
swiftc -D MATRIX_IO_TESTING tools/simulator-matrix-io.swift -o "$io_helper"
cat >"$fake_bin/swift" <<'RUBY'
#!/usr/bin/ruby --disable-gems
require "json"

arguments = ARGV.dup
if arguments.first == "tools/simulator-matrix-io.swift"
  arguments.shift
  exec ENV.fetch("MATRIX_IO_HELPER"), *arguments
end

unless arguments.first == "tools/resolve-simulator-matrix.swift"
  exec ENV.fetch("REAL_SWIFT"), *arguments
end

batch_index = arguments.index("--batch-id")
abort "missing batch ID" unless batch_index
matrix = {
  "schemaVersion" => 1,
  "batchId" => arguments.fetch(batch_index + 1),
  "resolvedAt" => "2026-08-21T12:00:00+09:00",
  "runtime" => {
    "identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-10-3",
    "version" => "10.3"
  },
  "cases" => [
    ["iphone-en", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-10-Pro", "iPhone 10 Pro", "en_US", "en"],
    ["iphone-ja", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-10-Pro", "iPhone 10 Pro", "ja_JP", "ja"],
    ["ipad-en", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "en_US", "en"],
    ["ipad-ja", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "ja_JP", "ja"]
  ].map do |id, family, identifier, name, locale, language|
    {"id" => id, "family" => family, "deviceType" => {"identifier" => identifier, "name" => name}, "locale" => locale, "language" => language}
  end
}
if arguments.include?("--scope") && arguments[arguments.index("--scope") + 1] == "iphone-ja"
  matrix["scope"] = "iphone-ja"
  matrix["cases"].select! { |entry| entry["id"] == "iphone-ja" }
end
case ENV["FAKE_RESOLVER_MODE"]
when "wrong-batch"
  matrix["batchId"] = "otherwise-valid-wrong-batch"
when "split-family-types"
  matrix.fetch("cases").fetch(1)["deviceType"] = {
    "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-Other-Pro",
    "name" => "iPhone Other Pro"
  }
when "preexisting-udid"
  matrix.fetch("cases").fetch(0)["udid"] = "00000000-0000-0000-0000-000000000999"
when nil
else
  abort "unknown fake resolver mode"
end
puts JSON.pretty_generate(matrix)
RUBY
chmod +x "$fake_bin/swift"

malicious_command="$scratch/malicious-command"
cat >"$malicious_command" <<'SH'
#!/usr/bin/env bash
printf '%s\n' invoked >>"$MALICIOUS_OVERRIDE_LOG"
exit 99
SH
chmod +x "$malicious_command"
malicious_log="$scratch/malicious.log"

run() {
  PATH="$fake_bin:$PATH" \
  TMPDIR="$scratch/tmp" \
  RUBYOPT="--disable-gems" \
  REAL_SWIFT="$real_swift" \
  MATRIX_IO_HELPER="$io_helper" \
  XCRUN_BIN="$malicious_command" \
  SIMULATOR_MATRIX_TESTING=1 \
  SIMULATOR_MATRIX_IO_TEST_BIN="$malicious_command" \
  SIMULATOR_MATRIX_RESOLVER="$malicious_command" \
  SIMULATOR_MATRIX_XCODE_JSON='{"path":"/untrusted","version":"0","build":"evil"}' \
  MALICIOUS_OVERRIDE_LOG="$malicious_log" \
  FAKE_XCODE_LOG="$xcode_log" \
  FAKE_SIMCTL_LOG="$log" \
  FAKE_SIMCTL_STATE="$state" \
  FAKE_SIMCTL_FIXTURES="$repo_root/tools/tests/fixtures/simctl" \
  /usr/bin/env -u DEVELOPER_DIR "$@"
}

run_with_create_mode() {
  local mode="$1"
  shift
  FAKE_CREATE_MODE="$mode" \
  run "$@"
}

run_with_delete_mode() {
  FAKE_DELETE_MODE="fail-first" \
  run "$@"
}

run_with_list_mode() {
  FAKE_LIST_MODE="fail-devicetypes" \
  run "$@"
}

run_with_resolver_mode() {
  local mode="$1"
  shift
  FAKE_RESOLVER_MODE="$mode" run "$@"
}

assert_test_tmp_clean() {
  if find "$scratch/tmp" -mindepth 1 -print -quit | rg -q .; then
    echo "production lifecycle left a temporary file in test TMPDIR" >&2
    find "$scratch/tmp" -mindepth 1 -maxdepth 1 -print >&2
    exit 1
  fi
}

run bash tools/resolve-simulator-matrix.sh --batch-id "$batch_id" --output "$matrix"
ruby -rjson - "$matrix" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
abort "expected exactly four cases" unless matrix.fetch("cases").length == 4
abort "Xcode metadata did not come from trusted commands" unless matrix.fetch("xcode") == {
  "path" => "/Applications/Fake Xcode.app/Contents/Developer",
  "version" => "26.5",
  "build" => "17F42"
}
expected = {
  "iphone-en" => "00000000-0000-0000-0000-000000000001",
  "iphone-ja" => "00000000-0000-0000-0000-000000000002",
  "ipad-en" => "00000000-0000-0000-0000-000000000003",
  "ipad-ja" => "00000000-0000-0000-0000-000000000004"
}
actual = matrix.fetch("cases").to_h { |entry| [entry.fetch("id"), entry.fetch("udid")] }
abort "unexpected created UDIDs: #{actual.inspect}" unless actual == expected
RUBY
[[ ! -e "$malicious_log" ]] || { echo "legacy executable/data override was invoked" >&2; exit 1; }
printf '%s\n' $'xcode-select\t-p' $'xcodebuild\t-version' >"$scratch/expected-xcode.log"
cmp -s "$scratch/expected-xcode.log" "$xcode_log" || { diff -u "$scratch/expected-xcode.log" "$xcode_log"; exit 1; }
assert_test_tmp_clean

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
assert_test_tmp_clean

mkdir -p "$(dirname "$partial_matrix")"
printf '{"schemaVersion":1,"batchId":"%s","cases":[]}' "$partial_batch" >"$partial_matrix"
: >"$log"
if run bash tools/resolve-simulator-matrix.sh --batch-id "$partial_batch" --output "$partial_matrix"; then
  echo "resolver overwrote a partial matrix" >&2
  exit 1
fi
[[ ! -s "$log" ]] || { echo "partial matrix invoked simctl" >&2; exit 1; }
assert_test_tmp_clean

for resolver_mode in wrong-batch split-family-types preexisting-udid; do
  adversarial_batch="$resolver_mode-$RANDOM-$RANDOM"
  : >"$log"
  if run_with_resolver_mode "$resolver_mode" bash tools/resolve-simulator-matrix.sh --batch-id "$adversarial_batch" --output ".artifacts/batches/$adversarial_batch/simulator-matrix.json"; then
    echo "resolver accepted otherwise-valid $resolver_mode pre-create matrix" >&2
    exit 1
  fi
  if rg -q '^simctl\tcreate\t' "$log"; then
    echo "$resolver_mode pre-create matrix reached simctl create" >&2
    exit 1
  fi
  rm -rf ".artifacts/batches/$adversarial_batch"
  assert_test_tmp_clean
done

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
assert_test_tmp_clean

delete_failure_batch="delete-failure-$RANDOM-$RANDOM"
delete_failure_matrix=".artifacts/batches/$delete_failure_batch/simulator-matrix.json"
run bash tools/resolve-simulator-matrix.sh --batch-id "$delete_failure_batch" --output "$delete_failure_matrix"
: >"$log"
if run_with_delete_mode bash tools/destroy-simulator-matrix.sh --matrix "$delete_failure_matrix"; then
  echo "destroy succeeded after configured delete failure" >&2
  exit 1
fi
[[ "$(wc -l <"$log")" -eq 2 ]] || { echo "destroy did not stop on first delete failure" >&2; exit 1; }
assert_test_tmp_clean
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
assert_test_tmp_clean
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
  assert_test_tmp_clean
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
assert_test_tmp_clean
rm -rf "$(dirname "$failed_matrix")"

capture_failure_batch="capture-failure-$RANDOM-$RANDOM"
capture_failure_matrix=".artifacts/batches/$capture_failure_batch/simulator-matrix.json"
: >"$log"
if run_with_list_mode bash tools/resolve-simulator-matrix.sh --batch-id "$capture_failure_batch" --output "$capture_failure_matrix"; then
  echo "resolver succeeded after configured list capture failure" >&2
  exit 1
fi
[[ ! -e "$capture_failure_matrix" ]] || { echo "resolver published after list capture failure" >&2; exit 1; }
if rg -q '^simctl\tcreate\t' "$log"; then
  echo "list capture failure reached simctl create" >&2
  exit 1
fi
assert_test_tmp_clean
rm -rf "$(dirname "$capture_failure_matrix")"

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

prelink_batch="prelink-$RANDOM-$RANDOM"
if MATRIX_IO_TEST_PRELINK_FAILURE=1 "$io_helper" --operation publish --repo "$repo_root" --batch "$prelink_batch" --source "$io_source" --name simulator-matrix.json; then
  echo "helper ignored configured pre-link failure" >&2
  exit 1
fi
[[ ! -e ".artifacts/batches/$prelink_batch/simulator-matrix.json" ]] || {
  echo "pre-link failure left a final matrix" >&2
  exit 1
}
if find ".artifacts/batches/$prelink_batch" -type f -name '.*' -print -quit | rg -q .; then
  echo "pre-link failure left a hidden publication temporary" >&2
  exit 1
fi
rm -rf ".artifacts/batches/$prelink_batch"

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
[[ ! -e "$malicious_log" ]] || { echo "legacy executable/data override was invoked" >&2; exit 1; }

run bash tools/resolve-simulator-matrix.sh --batch-id "$scoped_batch" --output "$scoped_matrix" --scope iphone-ja
ruby -rjson - "$scoped_matrix" "$log" "$scoped_batch" <<'RUBY'
path, log, batch = ARGV
matrix = JSON.parse(File.read(path))
abort "one-case matrix missing scope" unless matrix["scope"] == "iphone-ja"
abort "one-case matrix contains other devices" unless matrix["cases"].map { |entry| entry["id"] } == ["iphone-ja"]
created = File.readlines(log).select { |line| line.start_with?("simctl\tcreate\tiOS-Template-#{batch}-") }
abort "must create exactly one Japanese iPhone" unless created.length == 1 && created.first.include?("-iphone-ja\t")
RUBY
cp "$log" "$scratch/before-scope-mismatch.log"
cp "$scoped_matrix" "$scratch/frozen-ja.json"
if run bash tools/resolve-simulator-matrix.sh --batch-id "$scoped_batch" --output "$scoped_matrix"; then
  echo "resolver reused iphone-ja as full" >&2; exit 1
fi
cmp "$log" "$scratch/before-scope-mismatch.log"
cmp "$scoped_matrix" "$scratch/frozen-ja.json"
run bash tools/resolve-simulator-matrix.sh --batch-id "$scoped_batch" --output "$scoped_matrix" --scope iphone-ja
run bash tools/destroy-simulator-matrix.sh --matrix "$scoped_matrix"
ruby -rjson - "$scratch/frozen-ja.json" "$log" <<'RUBY'
matrix = JSON.parse(File.read(ARGV.fetch(0)))
udid = matrix.fetch("cases").first.fetch("udid")
deletes = File.readlines(ARGV.fetch(1)).count { |line| line.chomp == "simctl\tdelete\t#{udid}" }
abort "scoped cleanup must delete exactly its owned Simulator" unless deletes == 1
RUBY
echo "all simulator lifecycle tests passed"
