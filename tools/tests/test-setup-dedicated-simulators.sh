#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tool="$repo_root/tools/setup-dedicated-simulators.sh"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/ios-template-dedicated-setup-test.XXXXXX")"
trap 'rm -rf -- "$workspace"' EXIT

iphone_name='iOS-Template iPhone 17'
ipad_name='iOS-Template iPad (A16)'
iphone_type='com.apple.CoreSimulator.SimDeviceType.iPhone-17'
ipad_type='com.apple.CoreSimulator.SimDeviceType.iPad-A16'
runtime='com.apple.CoreSimulator.SimRuntime.iOS-27-0'

mkdir -p "$workspace/bin"
cat >"$workspace/bin/xcrun" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_SIMCTL_STATE:?}"
# Tool lookups such as the SDK path go to the real xcrun; every simctl call is recorded and faked.
[[ "${1:-}" == simctl ]] || exec /usr/bin/xcrun "$@"
printf '%s\n' "$*" >>"$state/calls.log"
shift
case "$1 ${2:-}" in
  "list devices") cat "$state/devices.json" ;;
  "list runtimes") cat "$FAKE_SIMCTL_FIXTURES/runtimes.json" ;;
  "list devicetypes") cat "$FAKE_SIMCTL_FIXTURES/devicetypes.json" ;;
  create*)
    [[ $# -eq 4 && ! -e "$state/fail-create" ]] || exit 1
    ruby -rjson -e '
      path, name, type, runtime = ARGV
      value = JSON.parse(File.read(path))
      count = value["devices"].values.flatten.length + 1
      udid = format("00000000-0000-4000-8000-%012d", count)
      (value["devices"][runtime] ||= []) << {"name" => name, "udid" => udid, "state" => "Shutdown", "isAvailable" => true, "deviceTypeIdentifier" => type}
      File.write(path, JSON.generate(value))
      puts udid
    ' "$state/devices.json" "$2" "$3" "$4"
    ;;
  *) exit 97 ;;
esac
FAKE
chmod 755 "$workspace/bin/xcrun"

# Each case starts from the given live devices, expressed as "name|type|runtime|available" rows.
prepare() {
  local label="$1"
  shift
  state="$workspace/$label"
  mkdir -p "$state"
  : >"$state/calls.log"
  ruby -rjson -e '
    devices = {}
    ARGV.drop(1).each_with_index do |row, index|
      name, type, runtime, available = row.split("|")
      (devices[runtime] ||= []) << {"name" => name, "udid" => format("11111111-0000-4000-8000-%012d", index + 1), "state" => "Shutdown", "isAvailable" => available == "true", "deviceTypeIdentifier" => type}
    end
    File.write(ARGV.fetch(0), JSON.generate({"devices" => devices}))
  ' "$state/devices.json" "$@"
}

run_tool() {
  PATH="$workspace/bin:$PATH" FAKE_SIMCTL_STATE="$state" FAKE_SIMCTL_FIXTURES="$repo_root/tools/tests/fixtures/simctl" \
    "$tool" "$@" >"$state/stdout" 2>"$state/stderr"
}

creates() { grep -c '^simctl create ' "$state/calls.log" || true; }

assert_blocked() {
  local label="$1" message="$2"
  shift 2
  if run_tool "$@"; then
    echo "expected blocked setup: $label" >&2
    exit 1
  fi
  grep -Fq "blocked:environment: $message" "$state/stderr" || { echo "unexpected $label failure: $(cat "$state/stderr")" >&2; exit 1; }
  [[ "$(creates)" == 0 ]] || { echo "$label created a Simulator" >&2; exit 1; }
}

assert_only_list_and_create() {
  ! grep -Ev '^simctl (list (devices|runtimes|devicetypes) -j|create .+)$' "$state/calls.log" >/dev/null || {
    echo "setup ran a forbidden simctl command: $(grep -Ev '^simctl (list|create)' "$state/calls.log")" >&2
    exit 1
  }
}

device_count() {
  ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["devices"].values.flatten.count { |entry| entry["name"] == ARGV[1] }' "$state/devices.json" "$1"
}

prepare missing
run_tool
[[ "$(creates)" == 2 && "$(device_count "$iphone_name")" == 1 && "$(device_count "$ipad_name")" == 1 ]] || { echo 'missing devices were not created once each' >&2; exit 1; }
grep -Fxq "simctl create $iphone_name $iphone_type $runtime" "$state/calls.log"
grep -Fxq "simctl create $ipad_name $ipad_type $runtime" "$state/calls.log"
ruby -rjson -e '
  value = JSON.parse(File.read(ARGV[0]))
  abort "unexpected setup result" unless value["status"] == "ready" && value["devices"].map { |entry| [entry["name"], entry["status"]] } == [[ARGV[1], "created"], [ARGV[2], "created"]]
' "$state/stdout" "$iphone_name" "$ipad_name"
assert_only_list_and_create

: >"$state/calls.log"
run_tool
[[ "$(creates)" == 0 && "$(device_count "$iphone_name")" == 1 && "$(device_count "$ipad_name")" == 1 ]] || { echo 'setup rerun was not idempotent' >&2; exit 1; }
ruby -rjson -e 'abort "rerun did not report present devices" unless JSON.parse(File.read(ARGV[0]))["devices"].all? { |entry| entry["status"] == "present" }' "$state/stdout"
assert_only_list_and_create

prepare partial "$iphone_name|$iphone_type|$runtime|true" "iPhone 17|$iphone_type|$runtime|true"
run_tool
[[ "$(creates)" == 1 && "$(device_count "$iphone_name")" == 1 && "$(device_count "$ipad_name")" == 1 ]] || { echo 'partial setup did not create only the missing device' >&2; exit 1; }
grep -Fxq "simctl create $ipad_name $ipad_type $runtime" "$state/calls.log"
assert_only_list_and_create

prepare duplicate "$iphone_name|$iphone_type|$runtime|true" "$iphone_name|$iphone_type|$runtime|true"
assert_blocked 'duplicate name' "dedicated Simulator '$iphone_name' exists 2 times"
[[ "$(device_count "$iphone_name")" == 2 ]] || { echo 'duplicate devices were changed' >&2; exit 1; }
assert_only_list_and_create

prepare wrong-type "$ipad_name|com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3|$runtime|true"
assert_blocked 'wrong Device Type' "a Simulator named '$ipad_name' does not match"
prepare wrong-runtime "$iphone_name|$iphone_type|com.apple.CoreSimulator.SimRuntime.iOS-10-3|true"
assert_blocked 'wrong Runtime' "a Simulator named '$iphone_name' does not match"
prepare unavailable "$iphone_name|$iphone_type|$runtime|false"
assert_blocked 'unavailable device' "a Simulator named '$iphone_name' does not match"

sed 's/iOS-27-0/iOS-99-0/' "$repo_root/Config/dedicated-simulators.json" >"$workspace/missing-runtime.json"
prepare missing-runtime
assert_blocked 'missing Runtime' 'declared Runtime com.apple.CoreSimulator.SimRuntime.iOS-99-0 is not installed' --config "$workspace/missing-runtime.json"
sed 's/iPad-A16/iPad-Z99/' "$repo_root/Config/dedicated-simulators.json" >"$workspace/missing-type.json"
prepare missing-type
assert_blocked 'missing Device Type' 'declared Device Type com.apple.CoreSimulator.SimDeviceType.iPad-Z99 is not available' --config "$workspace/missing-type.json"
sed 's/"iOS-Template iPhone 17"/"iOS-Template-shared"/' "$repo_root/Config/dedicated-simulators.json" >"$workspace/protected-name.json"
prepare protected-name
assert_blocked 'protected name' 'Simulator declaration name is invalid' --config "$workspace/protected-name.json"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["devices"].pop; File.write(ARGV[1], JSON.generate(value))' \
  "$repo_root/Config/dedicated-simulators.json" "$workspace/one-device.json"
prepare one-device
assert_blocked 'single declared device' 'Simulator declaration schema differs' --config "$workspace/one-device.json"

prepare create-failure
touch "$state/fail-create"
if run_tool; then
  echo 'setup succeeded after a failed create' >&2
  exit 1
fi
[[ "$(device_count "$iphone_name")" == 0 ]] || { echo 'failed create left a device' >&2; exit 1; }
assert_only_list_and_create

skill="$repo_root/.agents/skills/app-bootstrap/SKILL.md"
grep -Fq 'tools/setup-dedicated-simulators.sh' "$skill" || { echo 'app-bootstrap skill does not run the setup tool' >&2; exit 1; }
grep -Fq '`<display name> iPhone 17` and `<display name> iPad (A16)`' "$skill" || { echo 'app-bootstrap skill does not name the derived devices' >&2; exit 1; }

echo 'dedicated Simulator setup tests passed'
