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
background_pids=()
cleanup() {
  local pid
  for pid in "${background_pids[@]-}"; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$scratch"
}
trap cleanup EXIT

fail() {
  echo "Simulator resource regression: $1" >&2
  exit 1
}

# The dedicated declaration under test is the repository's own tracked config (D-063).
runtime="$(jq -r '.devices[0].runtimeIdentifier' Config/dedicated-simulators.json)"
iphone_name="$(jq -r '.devices[] | select(.family == "iphone") | .name' Config/dedicated-simulators.json)"
iphone_type="$(jq -r '.devices[] | select(.family == "iphone") | .deviceTypeIdentifier' Config/dedicated-simulators.json)"
ipad_name="$(jq -r '.devices[] | select(.family == "ipad") | .name' Config/dedicated-simulators.json)"
ipad_type="$(jq -r '.devices[] | select(.family == "ipad") | .deviceTypeIdentifier' Config/dedicated-simulators.json)"
iphone_udid=00000000-0000-0000-0000-000000000017
ipad_udid=00000000-0000-0000-0000-000000000016

ruby -rjson - "$simctl_state" "$runtime" "$iphone_name" "$iphone_type" "$iphone_udid" "$ipad_name" "$ipad_type" "$ipad_udid" <<'RUBY'
path, runtime, iphone_name, iphone_type, iphone_udid, ipad_name, ipad_type, ipad_udid = ARGV
device = ->(udid, name, type) { {"udid" => udid, "name" => name, "state" => "Shutdown", "isAvailable" => true, "deviceTypeIdentifier" => type, "dataPath" => "/fixture/#{udid}"} }
File.write(path, JSON.generate(
  "mode" => "", "calls" => [],
  "devices" => {runtime => [device.call(iphone_udid, iphone_name, iphone_type), device.call(ipad_udid, ipad_name, ipad_type)]}
))
RUBY
cp "$simctl_state" "$scratch/simctl-initial.json"

cat >"$fake_xcrun" <<'RUBY'
#!/usr/bin/ruby --disable-gems
require "json"

path = File.join(__dir__, "simctl-state.json")
lock = File.open(path + ".lock", File::RDWR | File::CREAT, 0o600)
lock.flock(File::LOCK_EX)
begin
  state = JSON.parse(File.read(path))
  abort "expected simctl" unless ARGV.shift == "simctl"
  command = ARGV.shift
  unless command == "list"
    state.fetch("calls") << {"command" => command, "args" => ARGV.dup}
    File.write(path, JSON.generate(state))
  end
  devices = state.fetch("devices").values.flatten
  find = ->(udid) { devices.find { |entry| entry["udid"] == udid } or abort "missing #{command} target" }
  case command
  when "list"
    abort "invalid list" unless ARGV == %w[devices -j]
    puts JSON.generate("devices" => state.fetch("devices"))
  when "erase"
    abort "configured erase failure" if state["mode"] == "erase-fail"
    device = find.call(ARGV.fetch(0))
    abort "erase requires a shut-down device" unless device["state"] == "Shutdown"
    device["erased"] = device.fetch("erased", 0) + 1
    File.write(path, JSON.generate(state))
  when "shutdown"
    find.call(ARGV.fetch(0))["state"] = "Shutdown"
    File.write(path, JSON.generate(state))
  when "create", "clone", "delete", "rename"
    abort "forbidden simctl #{command}"
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

# edit_simctl RUBY-EXPRESSION runs with `state` bound to the fake simctl state.
edit_simctl() {
  ruby -rjson - "$simctl_state" "$1" "${@:2}" <<'RUBY'
path, expression, *args = ARGV
state = JSON.parse(File.read(path))
devices = state.fetch("devices").values.first
eval(expression)
File.write(path, JSON.generate(state))
RUBY
}

set_device_state() {
  edit_simctl 'devices.find { |d| d["udid"] == args[0] }["state"] = args[1]' "$1" "$2"
}

allocate() {
  local session="$1" attempt="$2" case_id="$3" pid="${4:-$owner_pid}" wait_seconds="${5:-0}" device_type="${6-}"
  if [[ -z "$device_type" ]]; then
    device_type="$([[ "$case_id" == iphone-* ]] && printf '%s' "$iphone_type" || printf '%s' "$ipad_type")"
  fi
  "${manager[@]}" allocate "${common[@]}" \
    --session "$session" --repository "$repo_root" --issue 185 --head "$head_sha" \
    --batch resource-test --attempt "$attempt" --case "$case_id" \
    --runtime "$runtime" --device-type "$device_type" \
    --owner-pid "$pid" --wait-seconds "$wait_seconds" --receipt-dir "$receipts"
}

release_lease() {
  local session="$1" allocation="$2"
  "${manager[@]}" release "${common[@]}" --session "$session" --allocation-id "$allocation" \
    --reason test-complete --receipt-dir "$receipts"
}

inventory() {
  "${manager[@]}" inventory "${common[@]}"
}

active_count() {
  inventory | jq -r '.activeCount'
}

calls_of() {
  jq -r --arg command "$1" '[.calls[] | select(.command == $command)] | length' "$simctl_state"
}

assert_no_forbidden_calls() {
  [[ "$(jq -r '[.calls[] | select(.command == "create" or .command == "clone" or .command == "delete" or .command == "rename")] | length' "$simctl_state")" == 0 ]] ||
    fail "a device was created, cloned, renamed, or deleted"
  [[ "$(jq -r '[.devices[] | .[] | select(.name == $a or .name == $b)] | length' --arg a "$iphone_name" --arg b "$ipad_name" "$simctl_state")" -ge 2 ]] ||
    fail "a dedicated Simulator disappeared"
}

expect_denied() {
  local label="$1" message="$2"
  shift 2
  if "$@" >/dev/null 2>"$scratch/denied.err"; then
    fail "$label unexpectedly succeeded"
  fi
  grep -Fq -- "$message" "$scratch/denied.err" || fail "$label reported: $(<"$scratch/denied.err")"
}

# A lease erases the dedicated iPhone before returning and publishes a dedicated-lease receipt.
lease="$(allocate session-1 attempt-1 iphone-ja)"
IFS=$'\t' read -r lease_id lease_udid lease_receipt <<<"$lease"
[[ "$lease_id" =~ ^[0-9a-f-]{36}$ && "$lease_udid" == "$iphone_udid" && -f "$lease_receipt" ]] || fail "lease output is invalid: $lease"
[[ "$(jq -r '[.schemaVersion, .kind, .status, .deviceName, .preparation.status, .preparation.erased] | map(tostring) | join("|")' "$lease_receipt")" == "2|dedicated-lease|active|$iphone_name|passed|true" ]] ||
  fail "lease receipt does not prove the erase"
[[ "$(jq -r 'has("repository") or has("owner") or has("allocator") or has("dataPath")' "$lease_receipt")" == false ]] ||
  fail "lease receipt exposed private durable-state identity"
[[ "$(calls_of erase)" == 1 && "$(jq -r --arg u "$iphone_udid" '[.calls[] | select(.command == "erase" and .args[0] == $u)] | length' "$simctl_state")" == 1 ]] ||
  fail "the dedicated iPhone was not erased exactly once before the lease"
[[ "$(manager_state="$("${manager[@]}" validate "${common[@]}" --session session-1 --allocation-id "$lease_id")"; printf '%s' "$manager_state")" == Shutdown ]] ||
  fail "validate did not report the leased device state"
expect_denied 'expected-state mismatch' 'does not match the required state' \
  "${manager[@]}" validate "${common[@]}" --session session-1 --allocation-id "$lease_id" --expected-state Booted

# One lease per session and one lease per dedicated device.
expect_denied 'second lease in one session' 'same session already owns' allocate session-1 attempt-second ipad-ja
expect_denied 'second lease of one device' "is leased by another run" allocate session-2 attempt-2 iphone-en
ipad_lease="$(allocate session-2 attempt-2 ipad-ja)"
IFS=$'\t' read -r ipad_lease_id ipad_lease_udid _ <<<"$ipad_lease"
[[ "$ipad_lease_udid" == "$ipad_udid" && "$(active_count)" == 2 ]] || fail "the dedicated iPad lease was not recorded"
expect_denied 'release by another session' 'belongs to another session' release_lease another-session "$lease_id"

# Release shuts the device down and never deletes it; a repeated release returns the same receipt.
set_device_state "$iphone_udid" Booted
released="$(release_lease session-1 "$lease_id")"
IFS=$'\t' read -r _ _ released_receipt <<<"$released"
[[ "$(jq -r '[.status, .cleanup.status, .cleanup.reason, .cleanup.deviceState] | join("|")' "$released_receipt")" == "released|passed|test-complete|Shutdown" ]] ||
  fail "release receipt does not prove the shutdown"
[[ "$(jq -r --arg u "$iphone_udid" '.devices[] | .[] | select(.udid == $u) | .state' "$simctl_state")" == Shutdown ]] || fail "release did not shut the device down"
release_lease session-1 "$lease_id" >/dev/null
[[ "$(active_count)" == 1 ]] || fail "a repeated release changed the lease count"
assert_no_forbidden_calls

# Legacy per-case allocations in state-v1.json count toward the Mac-wide limit and are never changed.
ruby -rjson - "$state_root/state-v1.json" <<'RUBY'
records = %w[active reserved deleting].each_with_index.map do |status, index|
  {"allocationId" => "legacy-#{index}", "status" => status, "sessionId" => "legacy-session-#{index}",
   "udid" => "LEGACY-#{index}", "deviceName" => "iOS-Template-legacy-iphone-ja-00000000000#{index}"}
end
records << {"allocationId" => "legacy-released", "status" => "released", "sessionId" => "legacy-done"}
File.write(ARGV[0], JSON.generate({"schemaVersion" => 1, "allocations" => records}))
RUBY
chmod 600 "$state_root/state-v1.json"
legacy_digest="$(shasum -a 256 "$state_root/state-v1.json")"
[[ "$(inventory | jq -r '[.capacityInUse, .legacyActiveCount, .limit] | map(tostring) | join("|")')" == "4|3|4" ]] ||
  fail "inventory does not report the combined Mac-wide capacity"
expect_denied 'fifth Mac-wide Simulator' 'limit (4) is in use' allocate session-3 attempt-3 iphone-ja
[[ "$(shasum -a 256 "$state_root/state-v1.json")" == "$legacy_digest" ]] || fail "the legacy state file was changed"
rm -f "$state_root/state-v1.json"

# Running unmanaged legacy-named devices count toward the limit; shut-down ones do not; none are touched.
edit_simctl '3.times { |i| devices << {"udid" => "UNMANAGED-#{i}", "name" => "iOS-Template-unmanaged-ipad-ja-#{i}", "state" => "Booted", "isAvailable" => true, "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Air", "dataPath" => "/fixture/unmanaged-#{i}"} }'
[[ "$(inventory | jq -r '.capacityInUse')" == 4 ]] || fail "running unmanaged devices were not counted"
expect_denied 'lease over running unmanaged devices' 'limit (4) is in use' allocate session-3 attempt-3 iphone-ja
edit_simctl 'devices.each { |d| d["state"] = "Shutdown" if d["name"].start_with?("iOS-Template-unmanaged-") }'
[[ "$(inventory | jq -r '[.capacityInUse, ([.protectedUnmanagedDevices[].countsTowardCapacity] | any)] | map(tostring) | join("|")')" == "1|false" ]] ||
  fail "shut-down unmanaged devices were counted"
[[ "$(jq -r '[.calls[] | select(.args | map(startswith("UNMANAGED-")) | any)] | length' "$simctl_state")" == 0 ]] || fail "an unmanaged device was targeted"
edit_simctl 'devices.delete_if { |d| d["name"].start_with?("iOS-Template-unmanaged-") }'

# The dedicated device must exist exactly once with the declared type and Runtime, and be shut down.
edit_simctl 'state["saved"] = devices.find { |d| d["udid"] == args[0] }; devices.delete(state["saved"])' "$iphone_udid"
expect_denied 'missing dedicated device' "must exist exactly once (found 0)" allocate session-3 attempt-3 iphone-ja
edit_simctl 'devices << state["saved"]; devices << state["saved"].merge("udid" => "00000000-0000-0000-0000-000000000099")'
expect_denied 'duplicate dedicated device' "must exist exactly once (found 2)" allocate session-3 attempt-3 iphone-ja
edit_simctl 'devices.delete_if { |d| d["udid"] == "00000000-0000-0000-0000-000000000099" }; devices.find { |d| d["udid"] == args[0] }["deviceTypeIdentifier"] = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"' "$iphone_udid"
expect_denied 'dedicated device with another type' "does not match its declared Device Type and Runtime" allocate session-3 attempt-3 iphone-ja
edit_simctl 'devices.find { |d| d["udid"] == args[0] }["deviceTypeIdentifier"] = args[1]; state.delete("saved")' "$iphone_udid" "$iphone_type"
expect_denied 'request for an undeclared type' "differ from the dedicated Simulator declaration" \
  allocate session-3 attempt-3 iphone-ja "$owner_pid" 0 com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
set_device_state "$iphone_udid" Booted
expect_denied 'device booted outside a lease' "Booted outside a lease" allocate session-3 attempt-3 iphone-ja
set_device_state "$iphone_udid" Shutdown

# A failed erase returns the lease instead of leaving it active.
edit_simctl 'state["mode"] = "erase-fail"'
expect_denied 'failed erase' 'dedicated Simulator preparation failed' allocate session-3 attempt-3 iphone-ja
edit_simctl 'state["mode"] = ""'
[[ "$(active_count)" == 1 ]] || fail "a failed erase left an active lease"
[[ "$(inventory | jq -r '[.allocations[] | select(.sessionId == "session-3") | .status + ":" + .cleanup.reason] | join(",")')" == "released:prepare-failure" ]] ||
  fail "a failed erase did not release its lease"

# Insufficient free space denies a lease before any erase.
erase_before="$(calls_of erase)"
if "${manager[@]}" allocate --test-mode --state-root "$state_root" --xcrun "$fake_xcrun" --command-timeout 10 \
    --minimum-free-bytes 999999999999999999 --session space-session --repository "$repo_root" --issue 185 \
    --head "$head_sha" --batch resource-test --attempt space --case iphone-ja --runtime "$runtime" \
    --device-type "$iphone_type" --owner-pid "$owner_pid" --wait-seconds 0 >/dev/null 2>"$scratch/space.err"; then
  fail "capacity preflight ignored insufficient space"
fi
grep -Fq 'insufficient free space' "$scratch/space.err" || fail "space denial reported: $(<"$scratch/space.err")"
[[ "$(calls_of erase)" == "$erase_before" ]] || fail "a denied lease erased the device"

# A cancelled wait for a busy device changes nothing.
set +e
"${manager[@]}" allocate "${common[@]}" \
  --session waiting-session --repository "$repo_root" --issue 185 --head "$head_sha" \
  --batch resource-test --attempt waiting-attempt --case ipad-en --runtime "$runtime" --device-type "$ipad_type" \
  --owner-pid "$owner_pid" --wait-seconds 30 --receipt-dir "$receipts" >/dev/null 2>&1 &
wait_pid=$!
background_pids+=("$wait_pid")
sleep 0.5
kill -TERM "$wait_pid"
wait "$wait_pid" 2>/dev/null
wait_status=$?
set -e
[[ "$wait_status" -ne 0 && "$(active_count)" == 1 ]] || fail "a cancelled wait changed the leases"

# Concurrent requests for one free dedicated device produce exactly one lease.
race_pids=()
for index in 1 2 3; do
  allocate "race-$index" "race-$index" iphone-ja >"$scratch/race-$index.out" 2>"$scratch/race-$index.err" &
  race_pids+=("$!")
done
race_successes=0
set +e
for pid in "${race_pids[@]}"; do
  wait "$pid" && race_successes=$((race_successes + 1))
done
set -e
[[ "$race_successes" == 1 && "$(active_count)" == 2 ]] || fail "concurrent requests did not serialize one dedicated device"
for index in 1 2 3; do
  if [[ -s "$scratch/race-$index.out" ]]; then
    IFS=$'\t' read -r race_id _ _ <"$scratch/race-$index.out"
    release_lease "race-$index" "$race_id" >/dev/null
  fi
done

# A lease whose owner process disappeared is recovered by shutting the device down, never deleting it.
release_lease session-2 "$ipad_lease_id" >/dev/null
sleep 30 &
orphan_owner=$!
background_pids+=("$orphan_owner")
orphan="$(allocate orphan-session orphan-attempt ipad-ja "$orphan_owner")"
IFS=$'\t' read -r orphan_id _ _ <<<"$orphan"
set_device_state "$ipad_udid" Booted
kill "$orphan_owner"
wait "$orphan_owner" 2>/dev/null || true
dry_run="$("${manager[@]}" recover "${common[@]}" --dry-run)"
[[ "$(jq -r '.recoveryCandidates | length' <<<"$dry_run")" == 1 && "$(active_count)" == 1 ]] || fail "dry-run recovery changed or missed the orphan"
"${manager[@]}" recover "${common[@]}" >/dev/null
[[ "$(active_count)" == 0 ]] || fail "orphan recovery did not return the lease"
[[ "$(inventory | jq -r --arg id "$orphan_id" '.allocations[] | select(.allocationId == $id) | .cleanup.reason + ":" + .cleanup.deviceState')" == "orphan-recovery:Shutdown" ]] ||
  fail "orphan recovery did not shut the device down"

# Tampered lease state is rejected.
ruby -rjson - "$state_root/dedicated-v1.json" <<'RUBY'
state = JSON.parse(File.read(ARGV[0]))
state.fetch("leases").first["issue"] = 999
File.write(ARGV[0], JSON.generate(state))
RUBY
expect_denied 'tampered lease state' 'integrity is invalid' inventory
assert_no_forbidden_calls

echo "Simulator resource tests passed"
