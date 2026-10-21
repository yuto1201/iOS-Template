#!/usr/bin/env bash
set -euo pipefail

# #379 (D-086): the template's build entry point builds for the dedicated Simulators by their run-time UDID
# without booting, installing, launching or erasing them, and builds and installs on exactly one connected
# development device named in Config/development-device.json without launching it or passing
# -allowProvisioningUpdates. Zero, two or more, or unconnected matches stop before any build. Every build
# uses the worktree's fixed DerivedData, and no device identifier is written into the repository.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby shasum

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ios-template-build-for-device.XXXXXX")"
work="$(cd "$work" && pwd -P)"
trap 'rm -rf -- "$work"' EXIT

fail() { echo "build-for-device test: $*" >&2; exit 1; }

iphone_udid=11111111-2222-4333-8444-555555555555
ipad_udid=66666666-7777-4888-9999-AAAAAAAAAAAA
device_udid=00008120-00FACE0000000001
other_udid=00008120-00FACE0000000002

# The tool runs from a disposable copy of the template, so the test can change its declarations freely.
repo="$work/template"
mkdir -p "$repo/tools/lib" "$repo/Config" "$repo/TemplateApp.xcodeproj"
for path in tools/build-for-device.sh tools/xcodebuild-in-worktree.sh tools/lib/xcode.sh tools/lib/bounded-command.rb \
  Config/dedicated-simulators.json Config/development-device.json; do
  cp "$repo_root/$path" "$repo/$path"
done
printf '// placeholder\n' > "$repo/TemplateApp.xcodeproj/project.pbxproj"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -q -m init
grep -Fxq '  "name": "iPhone19"' "$repo/Config/development-device.json" || fail 'the development device declaration changed'

root="$work/derived-data"
mkdir -p "$root"

# Both fakes run in the tool's scrubbed environment, so they read their behavior from files.
cat > "$work/fake-xcrun" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$work/xcrun.log"
case "\$*" in
  'simctl list devices -j') cat "$work/simctl.json" ;;
  'devicectl list devices --json-output '*) cp "$work/devicectl.json" "\$5" ;;
  'devicectl device install app --device '*)
    [[ -d "\$7" ]] || exit 66
    printf '%s\n' "\$7" > "$work/installed" ;;
  *) exit 99 ;;
esac
EOF
cat > "$work/fake-xcodebuild" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$work/xcodebuild.log"
derived="" destination="" previous=""
for argument in "\$@"; do
  [[ "\$previous" == -derivedDataPath ]] && derived="\$argument"
  [[ "\$previous" == -destination ]] && destination="\$argument"
  previous="\$argument"
done
case " \$* " in
  *' -showBuildSettings '*)
    printf '[{"target":"TemplateApp","buildSettings":{"CODE_SIGN_STYLE":"%s","DEVELOPMENT_TEAM":"AUZ2MV247A","TARGET_BUILD_DIR":"%s","FULL_PRODUCT_NAME":"TemplateApp.app"}}]\n' \
      "\$(cat "$work/sign-style")" "\$derived/Build/Products/Debug-iphoneos"
    exit 0 ;;
  *' build '*)
    case "\$(cat "$work/build-mode")" in
      signing) echo "error: No profiles for 'com.yuto.TemplateApp' were found"; exit 65 ;;
      fail) echo 'error: compile failed'; exit 65 ;;
    esac
    case "\$destination" in
      id=$device_udid) mkdir -p "\$derived/Build/Products/Debug-iphoneos/TemplateApp.app" ;;
      *) mkdir -p "\$derived/Build/Products/Debug-iphonesimulator/TemplateApp.app" ;;
    esac
    exit 0 ;;
esac
exit 98
EOF
chmod +x "$work/fake-xcrun" "$work/fake-xcodebuild"

reset_logs() {
  rm -f "$work/xcrun.log" "$work/xcodebuild.log" "$work/installed"
  : > "$work/xcrun.log"
  : > "$work/xcodebuild.log"
  echo Automatic > "$work/sign-style"
  echo ok > "$work/build-mode"
}
run_tool() {
  (cd "$work" && IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_XCRUN="$work/fake-xcrun" \
    IOS_TEMPLATE_TEST_XCODEBUILD="$work/fake-xcodebuild" IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT="$root" \
    "$repo/tools/build-for-device.sh" "$@") >"$work/out" 2>&1
}
expect_stop() {
  local label=$1 message=$2
  shift 2
  reset_logs
  if run_tool "$@"; then
    fail "$label did not stop"
  fi
  grep -Fq -- "$message" "$work/out" || { cat "$work/out" >&2; fail "unexpected message for $label"; }
  [[ ! -s "$work/xcodebuild.log" ]] || fail "$label reached xcodebuild"
  ! grep -q 'install' "$work/xcrun.log" || fail "$label installed"
}
# No call may boot, install to, launch or erase a Simulator, or launch an app on the device.
check_no_device_changes() {
  ! grep -Eq '^simctl (boot|install|launch|erase|shutdown|delete|create|clone)' "$work/xcrun.log" || fail "a Simulator was changed: $(cat "$work/xcrun.log")"
  ! grep -Eq 'launch|process|erase|reboot' "$work/xcrun.log" || fail "a device was launched or changed: $(cat "$work/xcrun.log")"
  ! grep -Eq 'allowProvisioning|CODE_SIGN|DEVELOPMENT_TEAM|PROVISIONING_PROFILE' "$work/xcodebuild.log" || fail 'signing was overridden'
  ! grep -Eq "$device_udid|$other_udid|$iphone_udid|$ipad_udid" "$work/out" || fail 'a device identifier was printed'
}
worktree_id() {
  printf '%s-%s' "$(basename "$repo" | sed 's/[^A-Za-z0-9_.-]/-/g')" "$(printf '%s' "$repo" | shasum -a 256 | cut -c1-64)"
}
derived="$root/$(worktree_id)/DerivedData"

# The dedicated Simulators: one exact match each, next to decoys with another runtime, type or name.
write_simulators() {
  local ipad_entries=$1
  cat > "$work/simctl.json" <<EOF
{"devices":{
  "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
    {"name":"iOS-Template iPhone 17 Pro","udid":"$iphone_udid","deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","isAvailable":true,"state":"Shutdown"},
    {"name":"iOS-Template iPhone 17 Pro","udid":"00000000-0000-4000-8000-000000000001","deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17","isAvailable":true,"state":"Shutdown"},
    {"name":"Other iPad Pro 13-inch (M5)","udid":"00000000-0000-4000-8000-000000000002","deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB","isAvailable":true,"state":"Shutdown"}
    $ipad_entries
  ],
  "com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
    {"name":"iOS-Template iPad Pro 13-inch (M5)","udid":"00000000-0000-4000-8000-000000000003","deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB","isAvailable":true,"state":"Shutdown"}
  ]
}}
EOF
}
ipad_entry=",{\"name\":\"iOS-Template iPad Pro 13-inch (M5)\",\"udid\":\"$ipad_udid\",\"deviceTypeIdentifier\":\"com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB\",\"isAvailable\":true,\"state\":\"Shutdown\"}"
write_simulators "$ipad_entry"

for case in "iphone-simulator $iphone_udid" "ipad-simulator $ipad_udid"; do
  target="${case% *}" udid="${case#* }"
  reset_logs
  run_tool "$target" || { cat "$work/out" >&2; fail "$target failed"; }
  [[ "$(cat "$work/xcrun.log")" == 'simctl list devices -j' ]] || fail "$target made other xcrun calls: $(cat "$work/xcrun.log")"
  [[ "$(wc -l < "$work/xcodebuild.log" | tr -d ' ')" == 1 ]] || fail "$target did not build exactly once"
  grep -Fq -- "-destination id=$udid build" "$work/xcodebuild.log" || fail "$target did not build for its dedicated UDID: $(cat "$work/xcodebuild.log")"
  grep -Fq -- "-derivedDataPath $derived " "$work/xcodebuild.log" || fail "$target did not use the fixed DerivedData"
  grep -Fq 'the Simulator was not booted and nothing was installed' "$work/out" || fail "$target did not report the build"
  check_no_device_changes
done

# No match or two matches stop before the build.
write_simulators ''
expect_stop 'no iPad Simulator' 'blocked:environment: 0 available Simulators match' ipad-simulator
write_simulators "$ipad_entry,${ipad_entry#,}"
expect_stop 'two iPad Simulators' 'blocked:environment: 2 available Simulators match' ipad-simulator
write_simulators "$(sed 's/"isAvailable":true/"isAvailable":false/' <<<"$ipad_entry")"
expect_stop 'an unavailable iPad Simulator' 'blocked:environment: 0 available Simulators match' ipad-simulator
write_simulators "$ipad_entry"

# The development device: current `properties` form, with a Simulator and another device in the list.
physical() {
  local name=$1 udid=$2 state=$3 transport=$4
  local transport_field=""
  [[ -n "$transport" ]] && transport_field=",\"transportType\":\"$transport\""
  printf '{"identifier":"%s","properties":{"hardware":{"reality":"physical","platform":"iOS","udid":"%s"},"state":{"name":"%s","developerModeStatus":{"enabled":{"mode":1}}},"connection":{"pairingState":"paired","state":"%s"%s}}}' \
    "CORE-$udid" "$udid" "$name" "$state" "$transport_field"
}
simulated='{"identifier":"SIM","properties":{"hardware":{"reality":"simulated","udid":"00000000-0000-4000-8000-000000000009"},"state":{"name":"iPhone19"},"connection":{"pairingState":"paired","state":"disconnected","transportType":"sameMachine"}}}'
write_devices() {
  local IFS=,
  printf '{"info":{"outcome":"success"},"result":{"devices":[%s]}}\n' "$*" > "$work/devicectl.json"
}

check_device_install() {
  local label=$1
  reset_logs
  run_tool device || { cat "$work/out" >&2; fail "$label failed"; }
  [[ "$(wc -l < "$work/xcodebuild.log" | tr -d ' ')" == 2 ]] || fail "$label did not run xcodebuild twice: $(cat "$work/xcodebuild.log")"
  sed -n 1p "$work/xcodebuild.log" | grep -Fq -- '-destination generic/platform=iOS -showBuildSettings -json' || fail "$label did not read the settings first"
  sed -n 2p "$work/xcodebuild.log" | grep -Fq -- "-destination id=$device_udid build" || fail "$label did not build for the device"
  grep -Fq -- "-derivedDataPath $derived " "$work/xcodebuild.log" || fail "$label did not use the fixed DerivedData"
  [[ "$(sed -n 1p "$work/xcrun.log")" == "devicectl list devices --json-output "* ]] || fail "$label did not list the devices first"
  [[ "$(sed -n 2p "$work/xcrun.log")" == "devicectl device install app --device $device_udid $derived/Build/Products/Debug-iphoneos/TemplateApp.app" ]] ||
    fail "$label did not install the built app on the device: $(cat "$work/xcrun.log")"
  [[ "$(wc -l < "$work/xcrun.log" | tr -d ' ')" == 2 ]] || fail "$label made other xcrun calls: $(cat "$work/xcrun.log")"
  [[ "$(cat "$work/installed")" == "$derived/Build/Products/Debug-iphoneos/TemplateApp.app" ]] || fail "$label installed another app"
  grep -Fq 'installed TemplateApp on iPhone19; it was not launched' "$work/out" || fail "$label did not report the install"
  check_no_device_changes
}
write_devices "$simulated" "$(physical iPhone19 "$device_udid" disconnected localNetwork)" "$(physical 'iPad Air 8' "$other_udid" connected wired)"
check_device_install 'a reachable device'
write_devices "$(physical iPhone19 "$device_udid" connected wired)"
check_device_install 'a wired device'
# The deprecated property groups alone are read the same way.
printf '{"result":{"devices":[{"identifier":"X","hardwareProperties":{"reality":"physical","udid":"%s"},"deviceProperties":{"name":"iPhone19","developerModeStatus":"enabled"},"connectionProperties":{"pairingState":"paired","tunnelState":"disconnected","transportType":"localNetwork"}}]}}\n' \
  "$device_udid" > "$work/devicectl.json"
check_device_install 'the deprecated device fields'

# Zero, two or more, or unconnected matches stop before any build; so does Developer Mode being off.
write_devices "$simulated" "$(physical 'iPad Air 8' "$other_udid" connected wired)"
expect_stop 'no device' 'no physical device named iPhone19' device
write_devices "$(physical iPhone19 "$device_udid" connected wired)" "$(physical iPhone19 "$other_udid" disconnected localNetwork)"
expect_stop 'two devices' '2 physical devices are named iPhone19' device
write_devices "$(physical iPhone19 "$device_udid" unavailable '')"
expect_stop 'an unconnected device' 'iPhone19 is not connected' device
write_devices "$(physical iPhone19 "$device_udid" unavailable localNetwork)"
expect_stop 'an unreachable device with a past transport' 'iPhone19 is not connected' device
write_devices "$(physical iPhone19 "$device_udid" disconnected localNetwork | sed 's/"paired"/"unpaired"/')"
expect_stop 'an unpaired device' 'iPhone19 is not connected' device
write_devices "$(physical iPhone19 "$device_udid" disconnected '')"
expect_stop 'a device without transport' 'iPhone19 is not connected' device
write_devices "$(physical iPhone19 "$device_udid" connected wired | sed 's/{"enabled":{"mode":1}}/{"disabled":{}}/')"
expect_stop 'Developer Mode off' 'Developer Mode is off on iPhone19' device

# Signing: manual signing stops before the build, and missing development signing stops before the install.
write_devices "$(physical iPhone19 "$device_udid" connected wired)"
reset_logs
echo Manual > "$work/sign-style"
if run_tool device; then fail 'manual signing did not stop'; fi
grep -Fq 'must use automatic signing' "$work/out" || fail 'manual signing gave another message'
[[ "$(wc -l < "$work/xcodebuild.log" | tr -d ' ')" == 1 ]] || fail 'manual signing reached the build'
reset_logs
echo signing > "$work/build-mode"
status=0
run_tool device || status=$?
[[ "$status" == 3 ]] || { cat "$work/out" >&2; fail "missing signing exited with $status"; }
grep -Fq 'the development signing for iPhone19 is missing' "$work/out" || fail 'missing signing gave no guidance'
grep -Fq 'does not pass -allowProvisioningUpdates' "$work/out" || fail 'missing signing guidance lacks the rule'
! grep -q install "$work/xcrun.log" || fail 'a failed build was installed'
check_no_device_changes
reset_logs
echo fail > "$work/build-mode"
if run_tool device; then fail 'a failed build did not stop'; fi
! grep -q install "$work/xcrun.log" || fail 'a failed build was installed'

# The declaration holds only the name, and the tool works only in the template repository.
cp "$repo/Config/development-device.json" "$work/declaration"
printf '{\n  "schemaVersion": 1,\n  "name": "iPhone19",\n  "udid": "%s"\n}\n' "$device_udid" > "$repo/Config/development-device.json"
expect_stop 'a declared identifier' 'must hold exactly schemaVersion 1 and a device name' device
cp "$work/declaration" "$repo/Config/development-device.json"
mv "$repo/TemplateApp.xcodeproj" "$work/project"
expect_stop 'a derived app' 'works only in the template repository' iphone-simulator
[[ ! -s "$work/xcrun.log" ]] || fail 'a derived app reached xcrun'
mv "$work/project" "$repo/TemplateApp.xcodeproj"
expect_stop 'an unknown target' 'usage: build-for-device.sh' tvos

# Nothing was written into the repository, and no device identifier is tracked.
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "the tool changed the repository: $(git -C "$repo" status --porcelain)"
! git -C "$repo" grep -Eq "$device_udid|$other_udid|$iphone_udid|$ipad_udid" || fail 'a device identifier is tracked'
ruby -rjson -e '
  config = JSON.parse(File.read(ARGV.fetch(0)))
  abort "Config/development-device.json holds more than the name" unless config.keys.sort == %w[name schemaVersion]
' "$repo_root/Config/development-device.json"
[[ -z "$(ls -A "$root/$(worktree_id)/Runs")" ]] || fail 'a run folder remained'

echo "build-for-device tests passed"
