#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git jq ruby

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

scratch="$(mktemp -d -t ios-simulator-resource.XXXXXX)"
state_root="$scratch/resource-state"
simctl_state="$scratch/simctl-state.json"
fake_xcrun="$scratch/xcrun"
receipts="$scratch/receipts"
head_sha="$(git rev-parse HEAD)"
owner_pid="$$"
trap 'rm -rf "$scratch"' EXIT

printf '%s\n' '{"sequence":0,"mode":"","devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[]}}' >"$simctl_state"
cat >"$fake_xcrun" <<'RUBY'
#!/usr/bin/ruby --disable-gems
require "fileutils"
require "json"

path = File.join(__dir__, "simctl-state.json")
lock = File.open(path + ".lock", File::RDWR | File::CREAT, 0o600)
lock.flock(File::LOCK_EX)
begin
  state = JSON.parse(File.read(path))
  abort "expected simctl" unless ARGV.shift == "simctl"
  command = ARGV.shift
  runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
  devices = state.fetch("devices").fetch(runtime)

  case command
  when "list"
    abort "invalid list" unless ARGV == %w[devices -j]
    puts JSON.generate("devices" => state.fetch("devices"))
  when "create"
    name, type, requested_runtime = ARGV
    abort "invalid create" unless ARGV.length == 3 && requested_runtime == runtime
    state["sequence"] += 1
    if state["mode"] == "create-fail"
      File.write(path, JSON.generate(state))
      abort "configured create failure"
    end
    udid = format("00000000-0000-0000-0000-%012d", state.fetch("sequence"))
    data_path = File.join(File.dirname(path), "data", udid)
    FileUtils.mkdir_p(data_path)
    devices << {
      "udid" => udid, "name" => name, "state" => "Shutdown", "isAvailable" => true,
      "deviceTypeIdentifier" => type, "dataPath" => data_path
    }
    File.write(path, JSON.generate(state))
    abort "configured partial creation failure" if state["mode"] == "partial-create-fail"
    puts udid
  when "shutdown"
    udid = ARGV.fetch(0)
    device = devices.find { |entry| entry["udid"] == udid } or abort "missing shutdown target"
    device["state"] = "Shutdown"
    File.write(path, JSON.generate(state))
  when "delete"
    udid = ARGV.fetch(0)
    abort "configured delete failure" if state["mode"] == "delete-fail"
    device = devices.find { |entry| entry["udid"] == udid } or abort "missing delete target"
    FileUtils.rm_rf(device.fetch("dataPath"))
    devices.delete(device)
    File.write(path, JSON.generate(state))
  else
    abort "unexpected simctl command #{command}"
  end
ensure
  lock.flock(File::LOCK_UN)
  lock.close
end
RUBY
chmod +x "$fake_xcrun"

manager=(ruby tools/lib/ios-simulator-resource.rb)
common=(--test-mode --state-root "$state_root" --xcrun "$fake_xcrun" --minimum-free-bytes 0 --command-timeout 10)

set_mode() {
  ruby -rjson - "$simctl_state" "$1" <<'RUBY'
path, mode = ARGV
state = JSON.parse(File.read(path))
state["mode"] = mode
File.write(path, JSON.generate(state))
RUBY
}

allocate() {
  local session="$1" attempt="$2" case_id="$3" pid="${4:-$owner_pid}" wait_seconds="${5:-0}"
  "${manager[@]}" allocate "${common[@]}" \
    --session "$session" --repository "$repo_root" --issue 89 --head "$head_sha" \
    --batch resource-test --attempt "$attempt" --case "$case_id" \
    --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-5 \
    --device-type "com.apple.CoreSimulator.SimDeviceType.$([[ "$case_id" == iphone-* ]] && printf iPhone-17-Pro || printf iPad-Air-13-inch-M3)" \
    --owner-pid "$pid" --wait-seconds "$wait_seconds" --receipt-dir "$receipts"
}

release_allocation() {
  local session="$1" allocation="$2"
  "${manager[@]}" release "${common[@]}" --session "$session" --allocation-id "$allocation" \
    --reason test-complete --receipt-dir "$receipts"
}

active_count() {
  "${manager[@]}" inventory "${common[@]}" | jq -r '.activeCount'
}

device_count() {
  jq -r '[.devices[] | .[]] | length' "$simctl_state"
}

drop_device_listing_keep_data() {
  ruby -rjson - "$simctl_state" "$1" <<'RUBY'
path, udid = ARGV
state = JSON.parse(File.read(path))
entries = state.fetch("devices").values.flatten
device = entries.find { |entry| entry.fetch("udid") == udid } or abort "fixture device missing"
state.fetch("devices").each_value { |bucket| bucket.delete_if { |entry| entry.fetch("udid") == udid } }
File.write(path, JSON.generate(state))
puts device.fetch("dataPath")
RUBY
}

allocations=()
sessions=()
for index in 1 2 3 4; do
  session="session-$index"
  case_id="$([[ "$index" -le 2 ]] && printf iphone-ja || printf ipad-ja)"
  receipt="$(allocate "$session" "attempt-$index" "$case_id")"
  IFS=$'\t' read -r allocation udid receipt_path <<<"$receipt"
  [[ "$allocation" =~ ^[0-9a-f-]{36}$ && "$udid" =~ ^[0-9A-Fa-f-]+$ && -f "$receipt_path" ]]
  [[ "$(jq -r 'has("repository") or has("owner") or has("allocator") or has("dataPath")' "$receipt_path")" == false ]] || {
    echo "allocation receipt exposed private durable-state identity" >&2; exit 1
  }
  allocations+=("$allocation")
  sessions+=("$session")
done
[[ "$(active_count)" == 4 && "$(device_count)" == 4 ]] || { echo "four-slot mixed-device capacity was not enforced" >&2; exit 1; }

if allocate session-5 attempt-5 iphone-ja >/dev/null 2>"$scratch/fifth.err"; then
  echo "fifth Mac-wide allocation succeeded" >&2; exit 1
fi
grep -Fq 'limit (4) is in use' "$scratch/fifth.err"
if allocate session-1 attempt-second iphone-en >/dev/null 2>"$scratch/same-session.err"; then
  echo "same session acquired a second Simulator" >&2; exit 1
fi
grep -Fq 'same session already owns' "$scratch/same-session.err"
if release_allocation another-session "${allocations[1]}" >/dev/null 2>"$scratch/other-owner.err"; then
  echo "another session released an owned Simulator" >&2; exit 1
fi
grep -Fq 'belongs to another session' "$scratch/other-owner.err"

release_allocation "${sessions[0]}" "${allocations[0]}" >/dev/null
replacement="$(allocate session-5 attempt-5 iphone-ja)"
IFS=$'\t' read -r replacement_id replacement_udid replacement_path <<<"$replacement"
[[ "$(active_count)" == 4 && "$(device_count)" == 4 ]]

set +e
"${manager[@]}" allocate "${common[@]}" \
  --session session-wait --repository "$repo_root" --issue 89 --head "$head_sha" \
  --batch resource-test --attempt attempt-wait --case iphone-ja \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-5 \
  --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  --owner-pid "$owner_pid" --wait-seconds 30 --receipt-dir "$receipts" \
  >"$scratch/wait.out" 2>"$scratch/wait.err" &
wait_pid=$!
sleep 0.3
kill -TERM "$wait_pid"
wait "$wait_pid" 2>/dev/null
wait_status=$?
set -e
[[ "$wait_status" -ne 0 && "$(active_count)" == 4 && "$(device_count)" == 4 ]] || {
  echo "cancelled capacity wait changed allocations" >&2; exit 1
}

for index in 1 2 3; do
  release_allocation "${sessions[$index]}" "${allocations[$index]}" >/dev/null
done
release_allocation session-5 "$replacement_id" >/dev/null
[[ "$(active_count)" == 0 && "$(device_count)" == 0 ]]

race_pids=()
for index in 1 2 3 4 5; do
  (allocate "race-session-$index" "race-attempt-$index" iphone-ja >"$scratch/race-$index.out" 2>"$scratch/race-$index.err") &
  race_pids+=("$!")
done
race_successes=0
race_failures=0
set +e
for index in 1 2 3 4 5; do
  wait "${race_pids[$((index - 1))]}"
  status="$?"
  if [[ "$status" -eq 0 ]]; then
    race_successes=$((race_successes + 1))
  else
    race_failures=$((race_failures + 1))
  fi
done
set -e
[[ "$race_successes" -eq 4 && "$race_failures" -eq 1 && "$(active_count)" == 4 && "$(device_count)" == 4 ]] || {
  echo "concurrent reservations did not enforce the exact four-slot ceiling" >&2; exit 1
}
for index in 1 2 3 4 5; do
  [[ -s "$scratch/race-$index.out" ]] || continue
  IFS=$'\t' read -r race_id _ _ <"$scratch/race-$index.out"
  release_allocation "race-session-$index" "$race_id" >/dev/null
done
[[ "$(active_count)" == 0 && "$(device_count)" == 0 ]]

first_retry="$(allocate retry-session retry-one iphone-ja)"
IFS=$'\t' read -r retry_one _ _ <<<"$first_retry"
release_allocation retry-session "$retry_one" >/dev/null
second_retry="$(allocate retry-session retry-two iphone-ja)"
IFS=$'\t' read -r retry_two _ _ <<<"$second_retry"
[[ "$retry_one" != "$retry_two" ]] || { echo "retry reused an old allocation identity" >&2; exit 1; }
release_allocation retry-session "$retry_two" >/dev/null
release_allocation retry-session "$retry_two" >/dev/null
[[ "$(active_count)" == 0 && "$(device_count)" == 0 ]]

absent_release="$(allocate absent-release-session absent-release-attempt iphone-ja)"
IFS=$'\t' read -r absent_release_id absent_release_udid _ <<<"$absent_release"
absent_release_data="$(drop_device_listing_keep_data "$absent_release_udid")"
[[ -d "$absent_release_data" && "$(device_count)" == 0 ]]
if release_allocation absent-release-session "$absent_release_id" >/dev/null 2>"$scratch/absent-release.err"; then
  echo "device absence with residual data released its slot" >&2; exit 1
fi
grep -Fq 'data path remains after the device disappeared' "$scratch/absent-release.err"
[[ "$(active_count)" == 1 && -d "$absent_release_data" ]] || { echo "residual data cleanup failure released its slot" >&2; exit 1; }
rm -rf -- "$absent_release_data"
release_allocation absent-release-session "$absent_release_id" >/dev/null
[[ "$(active_count)" == 0 && "$(device_count)" == 0 ]]

sleep 30 &
orphan_owner=$!
orphan="$(allocate orphan-session orphan-attempt ipad-ja "$orphan_owner")"
IFS=$'\t' read -r orphan_id _ _ <<<"$orphan"
kill "$orphan_owner"
wait "$orphan_owner" 2>/dev/null || true
dry_run_before="$("${manager[@]}" recover "${common[@]}" --dry-run)"
[[ "$(jq -r '.recoveryCandidates | length' <<<"$dry_run_before")" == 1 && "$(device_count)" == 1 ]]
"${manager[@]}" recover "${common[@]}" >/dev/null
[[ "$(active_count)" == 0 && "$(device_count)" == 0 ]]

sleep 30 &
absent_orphan_owner=$!
absent_orphan="$(allocate absent-orphan-session absent-orphan-attempt ipad-ja "$absent_orphan_owner")"
IFS=$'\t' read -r absent_orphan_id absent_orphan_udid _ <<<"$absent_orphan"
kill "$absent_orphan_owner"
wait "$absent_orphan_owner" 2>/dev/null || true
absent_orphan_data="$(drop_device_listing_keep_data "$absent_orphan_udid")"
"${manager[@]}" recover "${common[@]}" >/dev/null
[[ "$(active_count)" == 1 && -d "$absent_orphan_data" ]] || { echo "orphan recovery released residual Simulator data" >&2; exit 1; }
[[ "$(jq -r --arg id "$absent_orphan_id" '.allocations[] | select(.allocationId == $id) | [.status, .cleanup.status] | join(":")' "$state_root/state-v1.json")" == cleanup-failed:failed ]]
rm -rf -- "$absent_orphan_data"
"${manager[@]}" recover "${common[@]}" >/dev/null
[[ "$(active_count)" == 0 && "$(device_count)" == 0 ]]

set_mode partial-create-fail
if allocate partial-session partial-attempt iphone-ja >/dev/null 2>"$scratch/partial.err"; then
  echo "partial create failure succeeded" >&2; exit 1
fi
[[ "$(active_count)" == 0 && "$(device_count)" == 0 ]] || {
  echo "partial creation was not recovered" >&2
  cat "$scratch/partial.err" >&2
  cat "$state_root/state-v1.json" >&2
  cat "$simctl_state" >&2
  exit 1
}

set_mode delete-fail
delete_failure="$(allocate delete-session delete-attempt iphone-ja)"
IFS=$'\t' read -r delete_id _ _ <<<"$delete_failure"
if release_allocation delete-session "$delete_id" >/dev/null 2>"$scratch/delete.err"; then
  echo "configured deletion failure was reported as success" >&2; exit 1
fi
[[ "$(active_count)" == 1 && "$(device_count)" == 1 ]] || { echo "failed deletion released its slot" >&2; exit 1; }
set_mode ""
release_allocation delete-session "$delete_id" >/dev/null
[[ "$(active_count)" == 0 && "$(device_count)" == 0 ]]

if "${manager[@]}" allocate --test-mode --state-root "$state_root" --xcrun "$fake_xcrun" --command-timeout 10 \
    --session low-space --repository "$repo_root" --issue 89 --head "$head_sha" \
    --batch resource-test --attempt low-space --case iphone-ja \
    --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-5 \
    --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
    --owner-pid "$owner_pid" --wait-seconds 0 --minimum-free-bytes 9223372036854775807 \
    --receipt-dir "$receipts" >/dev/null 2>"$scratch/space.err"; then
  echo "capacity preflight ignored insufficient space" >&2; exit 1
fi
grep -Fq 'insufficient free space' "$scratch/space.err"
[[ "$(device_count)" == 0 ]]

ruby -rjson - "$simctl_state" <<'RUBY'
path = ARGV.fetch(0)
state = JSON.parse(File.read(path))
runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
udid = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
data_path = File.join(File.dirname(path), "data", udid)
Dir.mkdir(File.join(File.dirname(path), "data")) unless Dir.exist?(File.join(File.dirname(path), "data"))
Dir.mkdir(data_path)
state.fetch("devices").fetch(runtime) << {
  "udid" => udid, "name" => "iOS-Template-unmanaged-device", "state" => "Shutdown",
  "isAvailable" => true, "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
  "dataPath" => data_path
}
File.write(path, JSON.generate(state))
RUBY
inventory="$("${manager[@]}" inventory "${common[@]}")"
[[ "$(jq -r '.protectedUnmanagedDevices | length' <<<"$inventory")" == 1 && "$(device_count)" == 1 ]]
if allocate protected-session protected-attempt iphone-ja >/dev/null 2>"$scratch/protected.err"; then
  echo "allocation ignored an unmanaged protected Simulator" >&2; exit 1
fi
grep -Fq 'unmanaged iOS-Template Simulator' "$scratch/protected.err"
[[ "$(device_count)" == 1 ]] || { echo "inventory or allocation deleted a protected Simulator" >&2; exit 1; }
ruby -rjson -rfileutils - "$simctl_state" <<'RUBY'
path = ARGV.fetch(0)
state = JSON.parse(File.read(path))
devices = state.fetch("devices").values.flatten
device = devices.find { |entry| entry["udid"] == "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF" } or abort "fixture device missing"
FileUtils.rm_rf(device.fetch("dataPath"))
state.fetch("devices").each_value { |entries| entries.delete_if { |entry| entry["udid"] == device["udid"] } }
File.write(path, JSON.generate(state))
RUBY

tampered_root="$scratch/tampered-state"
mkdir -p "$tampered_root"
cp "$state_root/state-v1.json" "$tampered_root/state-v1.json"
ruby -rjson - "$tampered_root/state-v1.json" <<'RUBY'
path = ARGV.fetch(0)
state = JSON.parse(File.read(path))
state.fetch("allocations").fetch(0)["caseId"] = "ipad-en"
File.write(path, JSON.generate(state))
RUBY
if "${manager[@]}" inventory --test-mode --state-root "$tampered_root" --xcrun "$fake_xcrun" \
    --minimum-free-bytes 0 --command-timeout 10 >/dev/null 2>"$scratch/tampered.err"; then
  echo "tampered allocation state was accepted" >&2; exit 1
fi
grep -Fq 'record integrity is invalid' "$scratch/tampered.err"

ln -s "$state_root" "$scratch/state-root-link"
if "${manager[@]}" inventory --test-mode --state-root "$scratch/state-root-link" --xcrun "$fake_xcrun" \
    --minimum-free-bytes 0 --command-timeout 10 >/dev/null 2>"$scratch/symlink.err"; then
  echo "symlinked resource state root was accepted" >&2; exit 1
fi
grep -Fq 'resource directory is unsafe' "$scratch/symlink.err"

echo "all iOS Simulator resource manager tests passed"
