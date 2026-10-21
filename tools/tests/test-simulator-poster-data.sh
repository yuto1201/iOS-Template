#!/usr/bin/env bash
set -euo pipefail

# #370 (D-084): `ios-simulator-resource.rb poster-data` removes the poster data of the repository's dedicated
# Simulators only when the device has no active lease, simctl reports Shutdown, device.plist reports Shutdown,
# and no launchd_sim runs for it. The default run only reports. It never erases, deletes, boots, or creates a
# device, and it leaves app data, other devices, and symbolic links alone.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git jq ruby plutil

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

scratch="$(mktemp -d -t simulator-poster-data.XXXXXX)"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { echo "Simulator poster data regression: $1" >&2; exit 1; }

state_root="$scratch/resource-state"
devices_root="$scratch/Devices"
simctl_state="$scratch/simctl-state.json"
fake_xcrun="$scratch/xcrun"
fake_ps="$scratch/ps"
ps_lines="$scratch/ps-lines"
receipts="$scratch/receipts"
head_sha="$(git rev-parse HEAD)"

runtime="$(jq -r '.devices[0].runtimeIdentifier' Config/dedicated-simulators.json)"
iphone_name="$(jq -r '.devices[] | select(.family == "iphone") | .name' Config/dedicated-simulators.json)"
iphone_type="$(jq -r '.devices[] | select(.family == "iphone") | .deviceTypeIdentifier' Config/dedicated-simulators.json)"
ipad_name="$(jq -r '.devices[] | select(.family == "ipad") | .name' Config/dedicated-simulators.json)"
ipad_type="$(jq -r '.devices[] | select(.family == "ipad") | .deviceTypeIdentifier' Config/dedicated-simulators.json)"
iphone_udid=00000000-0000-0000-0000-000000000017
ipad_udid=00000000-0000-0000-0000-000000000016
other_udid=00000000-0000-0000-0000-000000000099

ruby -rjson - "$simctl_state" "$runtime" "$iphone_name" "$iphone_type" "$iphone_udid" "$ipad_name" "$ipad_type" "$ipad_udid" "$other_udid" <<'RUBY'
path, runtime, iphone_name, iphone_type, iphone_udid, ipad_name, ipad_type, ipad_udid, other_udid = ARGV
device = ->(udid, name, type) { {"udid" => udid, "name" => name, "state" => "Shutdown", "isAvailable" => true, "deviceTypeIdentifier" => type} }
File.write(path, JSON.generate(
  "calls" => [],
  "devices" => {runtime => [device.call(iphone_udid, iphone_name, iphone_type), device.call(ipad_udid, ipad_name, ipad_type),
                            device.call(other_udid, "Manual iPhone", iphone_type)]}
))
RUBY

# The fake records every simctl command other than list, so the test can show poster-data runs none.
cat >"$fake_xcrun" <<'RUBY'
#!/usr/bin/ruby --disable-gems
require "json"
path = File.join(__dir__, "simctl-state.json")
state = JSON.parse(File.read(path))
abort "expected simctl" unless ARGV.shift == "simctl"
command = ARGV.shift
unless command == "list"
  state.fetch("calls") << command
  File.write(path, JSON.generate(state))
end
case command
when "list" then puts JSON.generate("devices" => state.fetch("devices"))
when "erase", "shutdown" then nil
else abort "unexpected simctl command #{command}"
end
RUBY
cat >"$fake_ps" <<EOF
#!/bin/bash
[[ "\$*" == "-axo command=" ]] || exit 1
cat "$ps_lines"
EOF
chmod +x "$fake_xcrun" "$fake_ps"
: >"$ps_lines"

make_device() {
  local udid=$1 state=$2
  local device="$devices_root/$udid"
  mkdir -p "$device/data/Library/Application Support/PRBPosterExtensionDataStore/poster" "$device/data/Containers/Data/Application/app"
  printf 'poster bytes\n' >"$device/data/Library/Application Support/PRBPosterExtensionDataStore/poster/data"
  printf 'app data\n' >"$device/data/Containers/Data/Application/app/data"
  plutil -create xml1 "$device/device.plist"
  plutil -insert UDID -string "$udid" "$device/device.plist"
  plutil -insert state -integer "$state" "$device/device.plist"
  # Real device.plist files also hold dates, which JSON conversion cannot represent.
  plutil -insert lastBootedAt -date 2026-10-20T00:00:00Z "$device/device.plist"
}
poster() { printf '%s' "$devices_root/$1/data/Library/Application Support/PRBPosterExtensionDataStore"; }
reset_devices() {
  rm -rf "$devices_root"
  make_device "$iphone_udid" 1
  make_device "$ipad_udid" 1
  make_device "$other_udid" 1
}
set_simctl_state() {
  ruby -rjson -e 'path, udid, value = ARGV; state = JSON.parse(File.read(path)); state["devices"].values.flatten.find { |d| d["udid"] == udid }["state"] = value; File.write(path, JSON.generate(state))' "$simctl_state" "$1" "$2"
}
simctl_calls() { jq -c '.calls' "$simctl_state"; }

manager=(ruby tools/lib/ios-simulator-resource.rb)
common=(--test-mode --state-root "$state_root" --xcrun "$fake_xcrun" --command-timeout 10)
poster_data() { "${manager[@]}" poster-data "${common[@]}" --ps "$fake_ps" --devices-root "$devices_root" --repository "$repo_root" "$@"; }
field() { jq -r --arg family "$2" ".devices[] | select(.family == \$family) | $3" <<<"$1"; }

# The default run reports sizes and removes nothing.
reset_devices
report="$(poster_data)" || fail 'the report failed'
[[ "$(jq -r .dryRun <<<"$report")" == true ]] || fail 'the default run is not a dry run'
[[ "$(field "$report" iphone .eligible)" == true && "$(field "$report" ipad .eligible)" == true ]] || fail "shut-down devices are not eligible: $report"
(( $(field "$report" iphone .posterBytes) > 0 )) || fail 'the poster size was not reported'
[[ -d "$(poster "$iphone_udid")" && -d "$(poster "$ipad_udid")" ]] || fail 'the dry run removed poster data'

# --apply removes the poster data of both shut-down dedicated devices and leaves the rest.
before_calls="$(simctl_calls)"
report="$(poster_data --apply)" || fail 'the apply run failed'
[[ "$(field "$report" iphone .removed)" == true && "$(field "$report" ipad .removed)" == true ]] || fail "poster data was not removed: $report"
[[ ! -e "$(poster "$iphone_udid")" && ! -e "$(poster "$ipad_udid")" ]] || fail 'poster data remained'
[[ -f "$devices_root/$iphone_udid/data/Containers/Data/Application/app/data" && -f "$devices_root/$iphone_udid/device.plist" ]] || fail 'app data or device.plist was removed'
[[ -d "$(poster "$other_udid")" ]] || fail 'an undeclared device was changed'
[[ "$(simctl_calls)" == "$before_calls" ]] || fail "poster-data ran a simctl command: $(simctl_calls)"

# A device that any one signal shows as running, or that is leased, is left alone.
reset_devices
set_simctl_state "$ipad_udid" Booted
report="$(poster_data --apply)"
[[ "$(field "$report" ipad .reason)" == 'simctl state is Booted' && -d "$(poster "$ipad_udid")" ]] || fail "a booted iPad was changed: $report"
[[ "$(field "$report" iphone .removed)" == true ]] || fail 'the shut-down iPhone was not handled'
set_simctl_state "$ipad_udid" Shutdown

reset_devices
plutil -replace state -integer 3 "$devices_root/$iphone_udid/device.plist"
report="$(poster_data --apply)"
[[ "$(field "$report" iphone .reason)" == 'device.plist state is not Shutdown' && -d "$(poster "$iphone_udid")" ]] || fail "device.plist did not stop removal: $report"

reset_devices
plutil -replace UDID -string "$other_udid" "$devices_root/$iphone_udid/device.plist"
report="$(poster_data --apply)"
[[ "$(field "$report" iphone .reason)" == 'device.plist state is not Shutdown' && -d "$(poster "$iphone_udid")" ]] || fail "a device.plist for another UDID was accepted: $report"

reset_devices
printf 'launchd_sim %s/%s/data/var/run/launchd_bootstrap.plist\n' "$devices_root" "$iphone_udid" >"$ps_lines"
report="$(poster_data --apply)"
[[ "$(field "$report" iphone .reason)" == 'launchd_sim is running' && -d "$(poster "$iphone_udid")" ]] || fail "launchd_sim did not stop removal: $report"
: >"$ps_lines"

reset_devices
lease="$("${manager[@]}" allocate "${common[@]}" --minimum-free-bytes 0 \
  --session poster-session --repository "$repo_root" --issue 370 --head "$head_sha" --batch poster-test \
  --attempt poster-attempt --case iphone-ja --runtime "$runtime" --device-type "$iphone_type" \
  --owner-pid "$$" --wait-seconds 0 --receipt-dir "$receipts")" || fail 'the test lease failed'
report="$(poster_data --apply)"
[[ "$(field "$report" iphone .reason)" == leased && -d "$(poster "$iphone_udid")" ]] || fail "a leased device was changed: $report"
[[ "$(field "$report" ipad .removed)" == true ]] || fail 'the unleased iPad was not handled'
IFS=$'\t' read -r lease_id _ _ <<<"$lease"
"${manager[@]}" release "${common[@]}" --session poster-session --allocation-id "$lease_id" \
  --reason test-complete --receipt-dir "$receipts" >/dev/null || fail 'the test lease was not released'

# A lease taken for the same UDID under another name (another repository's declaration, then a rename) also
# blocks the device.
other_repository="$scratch/other-repository"
mkdir -p "$other_repository/Config"
git -C "$other_repository" init -q
jq '.devices |= map(.name |= sub("^iOS-Template "; "Other "))' Config/dedicated-simulators.json >"$other_repository/Config/dedicated-simulators.json"
other_iphone_name="$(jq -r '.devices[] | select(.family == "iphone") | .name' "$other_repository/Config/dedicated-simulators.json")"
rename_device() {
  ruby -rjson -e 'path, udid, value = ARGV; state = JSON.parse(File.read(path)); state["devices"].values.flatten.find { |d| d["udid"] == udid }["name"] = value; File.write(path, JSON.generate(state))' "$simctl_state" "$1" "$2"
}
reset_devices
rename_device "$iphone_udid" "$other_iphone_name"
lease="$("${manager[@]}" allocate "${common[@]}" --minimum-free-bytes 0 \
  --session other-session --repository "$other_repository" --issue 378 --head "$head_sha" --batch poster-test \
  --attempt other-attempt --case iphone-ja --runtime "$runtime" --device-type "$iphone_type" \
  --owner-pid "$$" --wait-seconds 0 --receipt-dir "$receipts")" || fail 'the other-name test lease failed'
rename_device "$iphone_udid" "$iphone_name"
report="$(poster_data --apply)"
[[ "$(field "$report" iphone .reason)" == leased && -d "$(poster "$iphone_udid")" ]] || fail "a device leased under another name was changed: $report"
IFS=$'\t' read -r lease_id _ _ <<<"$lease"
rename_device "$iphone_udid" "$other_iphone_name"
"${manager[@]}" release "${common[@]}" --session other-session --allocation-id "$lease_id" \
  --reason test-complete --receipt-dir "$receipts" >/dev/null || fail 'the other-name test lease was not released'
rename_device "$iphone_udid" "$iphone_name"

# A symbolic link on the way stops the run before anything is removed.
reset_devices
mv "$(poster "$iphone_udid")" "$scratch/outside-poster"
ln -s "$scratch/outside-poster" "$(poster "$iphone_udid")"
if poster_data --apply >"$scratch/symlink.out" 2>&1; then
  fail 'a symbolic link was accepted'
fi
grep -Fq 'is not a directory owned by this user' "$scratch/symlink.out" || fail "unexpected symbolic link failure: $(cat "$scratch/symlink.out")"
[[ -f "$scratch/outside-poster/poster/data" && -d "$(poster "$ipad_udid")" ]] || fail 'the refused run removed data'

# A missing poster store is not an error, and the test-only roots need test mode.
reset_devices
rm -rf "$(poster "$iphone_udid")"
report="$(poster_data --apply)"
[[ "$(field "$report" iphone .posterBytes)" == 0 && "$(field "$report" iphone .removed)" == false ]] || fail "a missing poster store was not reported: $report"
if "${manager[@]}" poster-data --state-root "$state_root" --devices-root "$devices_root" --repository "$repo_root" >/dev/null 2>&1; then
  fail 'a custom root was accepted outside test mode'
fi

echo 'Simulator poster data regressions passed'
