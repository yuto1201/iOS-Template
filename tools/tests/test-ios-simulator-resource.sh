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
    target = find.call(ARGV.fetch(0))
    if state["mode"] == "shutdown-vanishes"
      # The device leaves the list before any Shutdown can be observed.
      state.fetch("devices").each_value { |entries| entries.delete(target) }
      (state["hidden"] ||= []) << target
    else
      target["state"] = "Shutdown"
    end
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
# Another type: the former dedicated iPhone 17 Pro Max (D-079), which must no longer satisfy the declaration.
other_iphone_type=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
[[ "$other_iphone_type" != "$iphone_type" ]] || fail "the other iPhone type equals the declared one"
edit_simctl 'devices.delete_if { |d| d["udid"] == "00000000-0000-0000-0000-000000000099" }; devices.find { |d| d["udid"] == args[0] }["deviceTypeIdentifier"] = args[1]' "$iphone_udid" "$other_iphone_type"
expect_denied 'dedicated device with another type' "does not match its declared Device Type and Runtime" allocate session-3 attempt-3 iphone-ja
edit_simctl 'devices.find { |d| d["udid"] == args[0] }["deviceTypeIdentifier"] = args[1]; state.delete("saved")' "$iphone_udid" "$iphone_type"
expect_denied 'request for an undeclared type' "differ from the dedicated Simulator declaration" \
  allocate session-3 attempt-3 iphone-ja "$owner_pid" 0 "$other_iphone_type"
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

# Coexistence with repositories that still run the pre-D-063 manager (AC-4). The frozen legacy manager counts
# only its own state file and running `iOS-Template-` devices, so it cannot see a dedicated lease: with three
# running legacy devices and the dedicated iPhone leased and running, it still reports free capacity. This
# manager counts both and refuses the next lease. docs/verification.md records the limit.
legacy_manager=(ruby tools/tests/fixtures/legacy-simulator-resource/ios-simulator-resource.rb)
edit_simctl '3.times { |i| devices << {"udid" => "LEGACY-RUN-#{i}", "name" => "iOS-Template-legacy-iphone-ja-#{i}", "state" => "Booted", "isAvailable" => true, "deviceTypeIdentifier" => args[0], "dataPath" => "/fixture/legacy-run-#{i}"} }' "$iphone_type"
coexist="$(allocate coexist-session coexist-attempt iphone-ja)"
IFS=$'\t' read -r coexist_id _ _ <<<"$coexist"
set_device_state "$iphone_udid" Booted
[[ "$(inventory | jq -r '.capacityInUse')" == 4 ]] || fail "this manager did not count the dedicated lease with the running legacy devices"
expect_denied 'lease over a full Mac with running legacy devices' 'limit (4) is in use' allocate coexist-next coexist-next-attempt ipad-ja
legacy_view="$("${legacy_manager[@]}" inventory "${common[@]}")"
[[ "$(jq -r '[.activeCount, ([.protectedUnmanagedDevices[] | select(.countsTowardCapacity)] | length), .limit] | map(tostring) | join("|")' <<<"$legacy_view")" == "0|3|4" ]] ||
  fail "the legacy manager view of the Mac-wide capacity changed: $legacy_view"
jq -e --arg iphone "$iphone_name" --arg ipad "$ipad_name" '[.protectedUnmanagedDevices[] | select(.name == $iphone or .name == $ipad)] | length == 0' <<<"$legacy_view" >/dev/null ||
  fail "the legacy manager unexpectedly counted a dedicated Simulator"
release_lease coexist-session "$coexist_id" >/dev/null
edit_simctl 'devices.reject! { |d| d["udid"].start_with?("LEGACY-RUN-") }'
assert_no_forbidden_calls

# A device that disappears while cleanup waits for its Shutdown is never recorded as shut down. The lease
# is returned as explicitly unverified, release fails, and the receipt cannot pass the runner validator,
# which accepts only cleanup status passed with deviceState Shutdown.
vanish="$(allocate vanish-session vanish-attempt iphone-ja)"
IFS=$'\t' read -r vanish_id _ vanish_receipt <<<"$vanish"
set_device_state "$iphone_udid" Booted
edit_simctl 'state["mode"] = "shutdown-vanishes"'
expect_denied 'release after the device disappeared' 'disappeared before its Shutdown was observed' release_lease vanish-session "$vanish_id"
[[ "$(jq -r '[.status, .cleanup.status, .cleanup.deviceState] | join("|")' "$vanish_receipt")" == "released|unverified|absent" ]] ||
  fail "a disappeared device produced shutdown proof: $(jq -c '.cleanup' "$vanish_receipt")"
[[ "$(inventory | jq -r --arg id "$vanish_id" '.allocations[] | select(.allocationId == $id) | .status + ":" + .cleanup.status + ":" + .cleanup.deviceState')" == "released:unverified:absent" ]] ||
  fail "the durable lease recorded a Shutdown that was never observed"
[[ "$(active_count)" == 0 ]] || fail "an unverified cleanup kept the lease active"
edit_simctl 'state.delete("hidden").each { |d| d["state"] = "Shutdown"; devices << d }; state["mode"] = ""'
assert_no_forbidden_calls

# D-098: an app without its own pair declares the Mac's shared pair. Leases work the same way, and requests for
# a busy shared device wait in arrival order. All devices here are fake simctl entries.
shared_repo="$scratch/shared-app"
mkdir -p "$shared_repo/Config"
git -C "$shared_repo" init -q
shared_iphone_name='Shared iPhone 17 Pro'
shared_ipad_name='Shared iPad Pro 13-inch (M5)'
shared_iphone_udid=00000000-0000-0000-0000-000000000027
shared_ipad_udid=00000000-0000-0000-0000-000000000026
write_shared_config() {
  jq -n --arg runtime "$runtime" --arg in "$1" --arg it "$iphone_type" --arg an "$2" --arg at "$ipad_type" \
    '{schemaVersion: 1, devices: [
      {family: "iphone", name: $in, deviceTypeIdentifier: $it, runtimeIdentifier: $runtime},
      {family: "ipad", name: $an, deviceTypeIdentifier: $at, runtimeIdentifier: $runtime}]}' \
    >"$shared_repo/Config/dedicated-simulators.json"
}
write_shared_config "$shared_iphone_name" "$shared_ipad_name"
edit_simctl 'devices << {"udid" => args[0], "name" => args[1], "state" => "Shutdown", "isAvailable" => true, "deviceTypeIdentifier" => args[2], "dataPath" => "/fixture/shared-iphone"}; devices << {"udid" => args[3], "name" => args[4], "state" => "Shutdown", "isAvailable" => true, "deviceTypeIdentifier" => args[5], "dataPath" => "/fixture/shared-ipad"}' \
  "$shared_iphone_udid" "$shared_iphone_name" "$iphone_type" "$shared_ipad_udid" "$shared_ipad_name" "$ipad_type"

# allocate_shared SESSION CASE [OWNER-PID] [WAIT-SECONDS]
allocate_shared() {
  local session="$1" case_id="$2" pid="${3:-$owner_pid}" wait_seconds="${4:-0}" device_type
  device_type="$([[ "$case_id" == iphone-* ]] && printf '%s' "$iphone_type" || printf '%s' "$ipad_type")"
  "${manager[@]}" allocate "${common[@]}" \
    --session "$session" --repository "$shared_repo" --issue 495 --head "$head_sha" \
    --batch shared-test --attempt "$session" --case "$case_id" \
    --runtime "$runtime" --device-type "$device_type" \
    --owner-pid "$pid" --wait-seconds "$wait_seconds" --receipt-dir "$receipts"
}

queue_length() {
  inventory | jq -r '.queue | length'
}

# wait_until DESCRIPTION COMMAND... polls for up to 30 seconds.
wait_until() {
  local description="$1" attempt
  shift
  for attempt in $(seq 1 150); do
    "$@" && return 0
    sleep 0.2
  done
  fail "timed out waiting until $description"
}
queue_is() { [[ "$(queue_length)" == "$1" ]]; }
lease_output_ready() { [[ -s "$1" ]]; }
process_exited() { ! kill -0 "$1" 2>/dev/null; }

# A shared lease erases the shared device and returns a normal dedicated-lease receipt.
shared_holder="$(allocate_shared shared-holder iphone-ja)"
IFS=$'\t' read -r shared_holder_id shared_holder_udid shared_holder_receipt <<<"$shared_holder"
[[ "$shared_holder_udid" == "$shared_iphone_udid" && "$(jq -r '.deviceName + "|" + (.preparation.erased | tostring)' "$shared_holder_receipt")" == "$shared_iphone_name|true" ]] ||
  fail "the shared iPhone lease is invalid: $shared_holder"

# Two later requests get the device in arrival order and report their place in the queue on stderr.
allocate_shared shared-first iphone-en "$owner_pid" 30 >"$scratch/shared-first.out" 2>"$scratch/shared-first.err" &
shared_first_pid=$!
background_pids+=("$shared_first_pid")
wait_until 'the first waiting request is queued' queue_is 1
allocate_shared shared-second iphone-ja "$owner_pid" 30 >"$scratch/shared-second.out" 2>"$scratch/shared-second.err" &
shared_second_pid=$!
background_pids+=("$shared_second_pid")
wait_until 'the second waiting request is queued' queue_is 2
[[ "$(inventory | jq -r '[.queue[] | .sessionId] | join(",")')" == "shared-first,shared-second" ]] || fail "the queue is not in arrival order"
wait_until 'the first request reports its place' grep -Fq "waiting for Simulator '$shared_iphone_name': queue position 1, 0 request(s) ahead" "$scratch/shared-first.err"
wait_until 'the second request reports its place' grep -Fq "queue position 2, 1 request(s) ahead" "$scratch/shared-second.err"
release_lease shared-holder "$shared_holder_id" >/dev/null
wait "$shared_first_pid" || fail "the first waiting request failed: $(<"$scratch/shared-first.err")"
kill -0 "$shared_second_pid" 2>/dev/null || fail "the second request did not keep waiting behind the first"
[[ ! -s "$scratch/shared-second.out" && "$(queue_length)" == 1 ]] || fail "the second request overtook the first"
IFS=$'\t' read -r shared_first_id _ _ <"$scratch/shared-first.out"
release_lease shared-first "$shared_first_id" >/dev/null
wait "$shared_second_pid" || fail "the second waiting request failed: $(<"$scratch/shared-second.err")"
grep -Fq "queue position 1, 0 request(s) ahead" "$scratch/shared-second.err" || fail "the second request did not report moving to the front"
IFS=$'\t' read -r shared_second_id _ _ <"$scratch/shared-second.out"
release_lease shared-second "$shared_second_id" >/dev/null
[[ "$(queue_length)" == 0 && "$(active_count)" == 0 ]] || fail "the queue or the leases were not emptied"

# A free device still goes to the request at the front: here the front request waits only because its
# session holds the shared iPad, and a new request for the free iPhone does not overtake it.
shared_ipad="$(allocate_shared shared-front ipad-ja)"
IFS=$'\t' read -r shared_ipad_id _ _ <<<"$shared_ipad"
allocate_shared shared-front iphone-en "$owner_pid" 30 >"$scratch/shared-front.out" 2>"$scratch/shared-front.err" &
shared_front_pid=$!
background_pids+=("$shared_front_pid")
wait_until 'the front request is queued' queue_is 1
expect_denied 'a request that would overtake the queue' "1 earlier lease request(s) wait for Simulator '$shared_iphone_name'" \
  allocate_shared shared-late iphone-ja
release_lease shared-front "$shared_ipad_id" >/dev/null
wait "$shared_front_pid" || fail "the front request did not receive the free device: $(<"$scratch/shared-front.err")"
IFS=$'\t' read -r shared_front_id _ _ <"$scratch/shared-front.out"

# A request whose wait expires stops with blocked:environment and leaves the queue.
expect_denied 'an expired shared wait' 'blocked:environment: dedicated Simulator' allocate_shared shared-expired iphone-ja "$owner_pid" 1
grep -Fq 'wait expired after 1 seconds' "$scratch/denied.err" || fail "the expired wait did not say so: $(<"$scratch/denied.err")"
[[ "$(queue_length)" == 0 ]] || fail "an expired request stayed in the queue"

# A waiting request that finds the device free only after its deadline does not take the lease: here the
# lease lock is held past the deadline while the holder's owner dies, as a slow release would.
sleep 60 &
late_holder_owner=$!
background_pids+=("$late_holder_owner")
late_holder="$(allocate_shared shared-late-holder ipad-ja "$late_holder_owner")"
IFS=$'\t' read -r late_holder_id _ _ <<<"$late_holder"
erase_before="$(calls_of erase)"
allocate_shared shared-late-waiter ipad-en "$owner_pid" 2 >"$scratch/shared-late.out" 2>"$scratch/shared-late.err" &
late_waiter=$!
background_pids+=("$late_waiter")
wait_until 'the late request is queued' queue_is 1
ruby -e '
  lock = File.open(ARGV[0], File::RDWR)
  lock.flock(File::LOCK_EX)
  File.write(ARGV[1], "locked")
  sleep 4
' "$state_root/dedicated-v1.lock" "$scratch/lock-held" &
lock_holder=$!
background_pids+=("$lock_holder")
wait_until 'the test holds the lease lock' test -f "$scratch/lock-held"
kill "$late_holder_owner"
wait "$late_holder_owner" 2>/dev/null || true
wait "$lock_holder"
if wait "$late_waiter"; then fail "a request whose wait expired took the lease"; fi
grep -Fq 'became free only after the wait expired after 2 seconds' "$scratch/shared-late.err" ||
  fail "the late request reported: $(<"$scratch/shared-late.err")"
[[ ! -s "$scratch/shared-late.out" && "$(queue_length)" == 0 && "$(calls_of erase)" == "$erase_before" ]] ||
  fail "the late request left the queue, a lease, or an erase behind"
[[ "$(inventory | jq -r --arg id "$late_holder_id" '[.activeCount, (.allocations[] | select(.allocationId == $id) | .cleanup.reason)] | map(tostring) | join("|")')" == "1|orphan-recovery" ]] ||
  fail "the dead holder was not recovered, or the late request holds a lease"

# Waiting requests whose owner died, or whose waiting process was killed, are removed and do not hold up the
# request behind them.
sleep 60 &
dead_owner=$!
background_pids+=("$dead_owner")
allocate_shared shared-dead-owner iphone-ja "$dead_owner" 30 >/dev/null 2>"$scratch/shared-dead-owner.err" &
dead_owner_waiter=$!
background_pids+=("$dead_owner_waiter")
wait_until 'the request of the owner that will die is queued' queue_is 1
( exec "${manager[@]}" allocate "${common[@]}" --session shared-killed --repository "$shared_repo" --issue 495 \
    --head "$head_sha" --batch shared-test --attempt shared-killed --case iphone-ja --runtime "$runtime" \
    --device-type "$iphone_type" --owner-pid "$owner_pid" --wait-seconds 30 --receipt-dir "$receipts" ) >/dev/null 2>&1 &
killed_waiter=$!
background_pids+=("$killed_waiter")
wait_until 'the request that will be killed is queued' queue_is 2
allocate_shared shared-behind iphone-en "$owner_pid" 30 >"$scratch/shared-behind.out" 2>"$scratch/shared-behind.err" &
shared_behind_pid=$!
background_pids+=("$shared_behind_pid")
wait_until 'the request behind is queued' queue_is 3
wait_until 'the request behind reports its place' grep -Fq "queue position 3, 2 request(s) ahead" "$scratch/shared-behind.err"
kill -KILL "$killed_waiter"
kill "$dead_owner"
wait "$killed_waiter" 2>/dev/null || true
wait "$dead_owner" 2>/dev/null || true
wait_until 'the request of the dead owner stops' process_exited "$dead_owner_waiter"
if wait "$dead_owner_waiter"; then fail "the request of a dead owner received a lease"; fi
grep -Fq 'removed because its owner or waiting process is not active' "$scratch/shared-dead-owner.err" ||
  fail "the request of a dead owner reported: $(<"$scratch/shared-dead-owner.err")"
wait_until 'the request behind moves to the front' grep -Fq "queue position 1, 0 request(s) ahead" "$scratch/shared-behind.err"
[[ "$(inventory | jq -r '[.queue[] | .sessionId] | join(",")')" == "shared-behind" ]] || fail "dead requests stayed in the queue"
release_lease shared-front "$shared_front_id" >/dev/null
wait "$shared_behind_pid" || fail "the request behind dead requests failed: $(<"$scratch/shared-behind.err")"
IFS=$'\t' read -r shared_behind_id _ _ <"$scratch/shared-behind.out"

# Without --wait-seconds a shared request keeps waiting (the shared default, 1800 seconds, is longer than the
# dedicated 60); stopping it with TERM removes it from the queue.
( exec "${manager[@]}" allocate "${common[@]}" --session shared-default --repository "$shared_repo" --issue 495 \
    --head "$head_sha" --batch shared-test --attempt shared-default --case iphone-ja --runtime "$runtime" \
    --device-type "$iphone_type" --owner-pid "$owner_pid" --receipt-dir "$receipts" ) >/dev/null 2>"$scratch/shared-default.err" &
shared_default_pid=$!
background_pids+=("$shared_default_pid")
wait_until 'the request with the default wait is queued' queue_is 1
sleep 1.5
kill -0 "$shared_default_pid" 2>/dev/null || fail "a shared request without --wait-seconds stopped waiting: $(<"$scratch/shared-default.err")"
kill -TERM "$shared_default_pid"
wait "$shared_default_pid" 2>/dev/null || true
[[ "$(queue_length)" == 0 ]] || fail "a stopped request stayed in the queue"
release_lease shared-behind "$shared_behind_id" >/dev/null

# Only the exact shared pair may use a shared name; a mixed declaration is refused before any device is used.
erase_before="$(calls_of erase)"
write_shared_config "$shared_iphone_name" "Mixed iPad Pro 13-inch (M5)"
expect_denied 'a mixed shared declaration' 'must declare both shared Simulators exactly' allocate_shared shared-mixed iphone-ja
write_shared_config "$shared_iphone_name" "$shared_ipad_name"
[[ "$(calls_of erase)" == "$erase_before" && "$(active_count)" == 0 ]] || fail "a refused shared declaration used a device"
assert_no_forbidden_calls

# Tampered lease state is rejected.
ruby -rjson - "$state_root/dedicated-v1.json" <<'RUBY'
state = JSON.parse(File.read(ARGV[0]))
state.fetch("leases").first["issue"] = 999
File.write(ARGV[0], JSON.generate(state))
RUBY
expect_denied 'tampered lease state' 'integrity is invalid' inventory
assert_no_forbidden_calls

echo "Simulator resource tests passed"
