#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg ruby jq git ffmpeg ffprobe /usr/bin/xcrun /usr/bin/plutil /usr/bin/lockf

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
tool="$repo_root/tools/record-appstore-preview.sh"
lock_wrapper="$repo_root/tools/with-ios-simulator-lock.sh"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-appstore-preview.XXXXXX")
workspace=$(cd "$workspace" && pwd -P)
trap 'rm -rf -- "$workspace"' EXIT
fail() { echo "$*" >&2; exit 1; }
encode=(-c:v libx264 -preset ultrafast -pix_fmt yuv420p)

# --- Quality gate on synthetic clips (AC-6) --------------------------------------------------------
# D-079: the dedicated iPhone 17 Pro records 1206x2622 and the dedicated iPad Pro 13-inch (M5) 2064x2752.
clips="$workspace/clips"; mkdir -p "$clips"
iphone=1206x2622
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=$iphone:r=60:d=2" "${encode[@]}" "$clips/good.mp4"
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=$iphone:r=30:d=2" "${encode[@]}" "$clips/fps30.mp4"
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=$iphone:r=25:d=2" "${encode[@]}" "$clips/fps25.mp4"
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=$iphone:r=15:d=2" "${encode[@]}" "$clips/slow.mp4"
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=$iphone:r=60:d=0.6" -vf "tpad=stop_mode=clone:stop_duration=1.4" "${encode[@]}" "$clips/frozen.mp4"
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=$iphone:r=60:d=2" -vf "select='not(between(t,0.8,1.3))'" -fps_mode vfr "${encode[@]}" "$clips/gap.mp4"
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=$iphone:r=60:d=1.4" -f lavfi -i "color=c=black:s=$iphone:r=60:d=0.6" \
  -filter_complex "[0:v][1:v]concat=n=2:v=1[v]" -map "[v]" "${encode[@]}" "$clips/black.mp4"
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=1280x720:r=60:d=2" "${encode[@]}" "$clips/small.mp4"
# The former dedicated iPhone 17 Pro Max screen (1320x2868) is no longer the native iPhone recording.
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=1320x2868:r=60:d=2" "${encode[@]}" "$clips/former.mp4"
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=1179x2556:r=60:d=2" "${encode[@]}" "$clips/user.mp4"
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=2064x2752:r=30:d=2" "${encode[@]}" "$clips/ipad.mp4"

check_clip() { # name family expected-status expected-reason [extra args...]
  local name=$1 family=$2 expected=$3 reason=$4 status=0 label
  shift 4
  label="$name-$family${1:+$1}"
  "$tool" check --clip "$clips/$name.mp4" --family "$family" --seconds 2 "$@" >"$workspace/check-$label.json" 2>"$workspace/check-$label.err" || status=$?
  if [[ "$expected" == passed ]]; then
    [[ "$status" -eq 0 ]] || { cat "$workspace/check-$label.json" "$workspace/check-$label.err" >&2; fail "quality gate rejected $label"; }
  else
    [[ "$status" -eq 3 ]] || { cat "$workspace/check-$label.json" "$workspace/check-$label.err" >&2; fail "quality gate did not fail $label with status 3"; }
  fi
  jq -e --arg status "$expected" --arg reason "$reason" \
    '.status == $status and (if $reason == "" then .reasons == [] else (.reasons | any(contains($reason))) end) and (.clipSha256 | test("^sha256:[0-9a-f]{64}$"))' \
    "$workspace/check-$label.json" >/dev/null || { cat "$workspace/check-$label.json" >&2; fail "quality result differs for $label"; }
}
check_clip good iphone passed ''
check_clip fps30 iphone passed ''
check_clip ipad ipad passed ''
check_clip small iphone failed 'size 1280x720 is not the iphone screen 1206x2622'
check_clip former iphone failed 'size 1320x2868 is not the iphone screen 1206x2622'
check_clip good ipad failed 'size 1206x2622 is not the ipad screen 2064x2752'
check_clip fps25 iphone failed 'average frame rate 25.0 fps is below 30 fps'
check_clip slow iphone failed 'average frame rate 15.0 fps is below 30 fps'
check_clip frozen iphone failed 'the picture freezes'
check_clip frozen iphone passed '' --allow-still
check_clip gap iphone failed 'frame gaps longer than 100 ms'
check_clip black iphone failed 'black frames'
check_clip black iphone failed 'black frames' --allow-still
# A user's own recording only needs to be portrait and at least as wide as the preview.
check_clip user iphone failed 'is not the iphone screen 1206x2622'
check_clip user iphone passed '' --minimum-size
check_clip small iphone failed 'is not a portrait recording at least 886 wide' --minimum-size
status=0; "$tool" check --clip "$clips/good.mp4" --family iphone --seconds 5 >"$workspace/check-long.json" || status=$?
[[ "$status" -eq 3 ]] && jq -e '.reasons | any(contains("the plan is 5.00s"))' "$workspace/check-long.json" >/dev/null || fail 'quality gate accepted a clip shorter than the plan'
# The thresholds the gate applied are part of its JSON result.
jq -e '.thresholds == {"minAverageFps": 30.0, "maxFrameGapMs": 100, "maxGapShare": 0.02, "durationToleranceSeconds": 0.5,
    "freezeMinSeconds": 0.5, "blackMinSeconds": 0.1} and .sizeRule == "native" and .metrics.width == 1206 and .metrics.height == 2622' \
  "$workspace/check-good-iphone.json" >/dev/null || { cat "$workspace/check-good-iphone.json" >&2; fail 'quality result does not state its thresholds'; }
"$tool" check --clip "$clips/good.mp4" --family iphone --seconds 2 --output "$workspace/quality.json" >/dev/null
if "$tool" check --clip "$clips/good.mp4" --family iphone --seconds 2 --output "$workspace/quality.json" >/dev/null 2>"$workspace/quality-again.err"; then
  fail 'quality gate replaced an existing quality record'
fi
grep -Fq 'quality record already exists' "$workspace/quality-again.err" || fail 'unexpected quality record failure'

# --- Recording on the dedicated Simulator through a fake xcrun (AC-3, AC-4, AC-5) ------------------
dedicated_config="$repo_root/Config/dedicated-simulators.json"
capture_runtime=$(jq -er '.devices[0].runtimeIdentifier' "$dedicated_config")
iphone_name=$(jq -er '.devices[] | select(.family == "iphone") | .name' "$dedicated_config")
ipad_name=$(jq -er '.devices[] | select(.family == "ipad") | .name' "$dedicated_config")
iphone_type=$(jq -er '.devices[] | select(.family == "iphone") | .deviceTypeIdentifier' "$dedicated_config")
ipad_type=$(jq -er '.devices[] | select(.family == "ipad") | .deviceTypeIdentifier' "$dedicated_config")
[[ "$iphone_type" == com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro ]] || fail "the dedicated iPhone is not iPhone 17 Pro: $iphone_type"
requirements="$repo_root/tools/tests/fixtures/appstore/requirements.json"
states="$workspace/states.json"
cat >"$states" <<'JSON'
{"schemaVersion":1,"locales":[{"id":"en-US","appleLanguage":"en","appleLocale":"en_US"},{"id":"ja","appleLanguage":"ja","appleLocale":"ja_JP"}],
 "states":[{"id":"primary","order":1,"launchArguments":["--appstore-screenshot","--fixture","primary"]},
           {"id":"rain","order":2,"launchArguments":["--appstore-screenshot","--fixture","rain"]}]}
JSON
good_storyboard="$workspace/storyboard.json"
printf '%s\n' '{"schemaVersion":1,"segments":[{"id":"open","state":"primary","seconds":1},{"id":"rain","state":"rain","seconds":1,"allowStill":true}]}' >"$good_storyboard"
storyboard=$good_storyboard
source_sha=$(git -C "$repo_root" rev-parse HEAD)
build_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
fake_bin="$workspace/fake-bin"; mkdir -p "$fake_bin" "$workspace/Fake.app"
fake_log="$workspace/xcrun.log"
fake_state="$workspace/simctl-state.json"
resource_state="$workspace/resource-state"
iphone_udid=00000000-0000-0000-0000-000000000001
ipad_udid=00000000-0000-0000-0000-000000000002
user_udid=00000000-0000-0000-0000-000000000003
# The user's own iPhone 18 Pro belongs to the same App Store family; recording must still never use it.
ruby -rjson -e '
  runtime, iphone_name, iphone_type, ipad_name, ipad_type, iphone_udid, ipad_udid, user_udid = ARGV
  device = ->(udid, name, type) { {"udid" => udid, "name" => name, "state" => "Shutdown", "isAvailable" => true, "deviceTypeIdentifier" => type} }
  puts JSON.generate("devices" => {runtime => [
    device.(iphone_udid, iphone_name, iphone_type),
    device.(ipad_udid, ipad_name, ipad_type),
    device.(user_udid, "iPhone 18 Pro", "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro")]})
' "$capture_runtime" "$iphone_name" "$iphone_type" "$ipad_name" "$ipad_type" "$iphone_udid" "$ipad_udid" "$user_udid" >"$fake_state"
cat >"$fake_bin/xcrun" <<'RUBY'
#!/usr/bin/ruby --disable-gems
require "fileutils"
require "json"

log = ->(line) { File.open(ENV.fetch("FAKE_XCRUN_LOG"), "a", 0o600) { |file| file.puts(line) } }
log.call(ARGV.join(" "))
abort "expected simctl" unless ARGV.shift == "simctl"
command = ARGV.shift
# A command that never returns, to exercise the recorder's bounded timeouts.
sleep 120 if ENV["FAKE_HANG"] == command
if command == "io" && ARGV[1] == "recordVideo"
  abort "configured recording failure" if ENV["FAKE_FAIL_RECORD"] == "1"
  FileUtils.touch(ENV.fetch("FAKE_RECORDING_MARKER"))
  # The documented command runs the recorder through tools/with-ios-simulator-lock.sh; while it
  # records, the same lock cannot be taken again.
  if ENV["FAKE_LOCK_REPO"]
    free = system(ENV.fetch("FAKE_LOCK_WRAPPER"), "--timeout", "0", "--", "/usr/bin/true",
      chdir: ENV.fetch("FAKE_LOCK_REPO"), out: File::NULL, err: File::NULL)
    log.call(free ? "lock free during recordVideo" : "lock held during recordVideo")
  end
  FileUtils.cp(ENV.fetch("FAKE_CLIP"), ARGV.fetch(-1))
  $stderr.puts "Recording started"
  $stderr.flush
  Signal.trap("INT", "IGNORE") if ENV["FAKE_IGNORE_INT"] == "1"
  begin
    sleep
  rescue Interrupt
    log.call("stopped recordVideo #{ARGV.fetch(0)}")
    exit 0
  end
end
state_path = ENV.fetch("FAKE_SIMCTL_STATE")
lock = File.open(state_path + ".lock", File::RDWR | File::CREAT, 0o600)
lock.flock(File::LOCK_EX)
begin
  state = JSON.parse(File.binread(state_path))
  devices = state.fetch("devices").values.flatten
  udid = command == "launch" ? ARGV.find { |argument| !argument.start_with?("-") } : ARGV.fetch(0)
  target = -> { devices.find { |entry| entry.fetch("udid") == udid } or abort "missing #{command} target" }
  case command
  when "list"
    case ARGV
    when %w[-j devicetypes]
      puts JSON.generate("devicetypes" => [
        {"name" => "iPhone 18 Pro", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"},
        {"name" => "iPhone 17 Pro", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
        {"name" => "iPhone 17 Pro Max", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"},
        {"name" => "iPad Air 13-inch (M4)", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M4"},
        {"name" => "iPad Pro 13-inch (M5)", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"}])
    when %w[devices -j]
      # A device listing that fails once recording has begun makes the lease release fail.
      abort "configured device listing failure" if ENV["FAKE_FAIL_RELEASE"] == "1" && File.exist?(ENV.fetch("FAKE_RECORDING_MARKER"))
      puts JSON.generate("devices" => state.fetch("devices"))
    else abort "unexpected list arguments"
    end
  when "boot"
    target.call["state"] = "Booted"
    File.binwrite(state_path, JSON.generate(state))
  when "shutdown"
    target.call["state"] = "Shutdown"
    File.binwrite(state_path, JSON.generate(state))
  when "erase"
    device = target.call
    abort "erase requires a shut down device" unless device["state"] == "Shutdown"
    device.delete("preferences")
    File.binwrite(state_path, JSON.generate(state))
  when "spawn"
    device = target.call
    abort "spawn requires a booted device" unless device["state"] == "Booted"
    preferences = device["preferences"] ||= {}
    arguments = ARGV.drop(1)
    if arguments.length == 6 && arguments.first(5) == %w[defaults write -g AppleLanguages -array]
      preferences["AppleLanguages"] = [arguments.last]
    elsif arguments.length == 6 && arguments.first(5) == %w[defaults write -g AppleLocale -string]
      preferences["AppleLocale"] = arguments.last
    elsif arguments == %w[defaults export -g -]
      preferences = {} if ENV["FAKE_LOCALE_LOST"] == "1"
      entries = preferences.map do |key, value|
        rendered = value.is_a?(Array) ? "<array>#{value.map { |item| "<string>#{item}</string>" }.join}</array>" : "<string>#{value}</string>"
        "<key>#{key}</key>#{rendered}"
      end
      puts %(<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>#{entries.join}</dict></plist>)
    else
      abort "unexpected spawn arguments"
    end
    File.binwrite(state_path, JSON.generate(state))
  when "bootstatus", "status_bar", "install", "launch", "terminate", "uninstall"
    abort "#{command} requires a booted device" unless target.call["state"] == "Booted"
  else abort "unexpected simctl command #{command}"
  end
ensure
  lock.flock(File::LOCK_UN)
  lock.close
end
RUBY
chmod +x "$fake_bin/xcrun"

# Runs the recorder with SIGINT at its default disposition (a background job of this script would
# otherwise start with SIGINT ignored) and records its process id for the signal cases.
record_prefix=()
run_record() { # session output family locale [env...]
  local session=$1 output=$2 family=$3 locale=$4
  shift 4
  rm -f -- "$workspace/recording.marker" "$workspace/record.pid"
  /bin/bash -c 'printf "%s\n" "$$" >"$0"; exec "$@"' "$workspace/record.pid" \
    /usr/bin/ruby --disable-gems -e 'Signal.trap("INT", "SYSTEM_DEFAULT"); exec(*ARGV)' \
    /usr/bin/env FAKE_XCRUN_LOG="$fake_log" FAKE_SIMCTL_STATE="$fake_state" FAKE_CLIP="$clips/good.mp4" \
    FAKE_RECORDING_MARKER="$workspace/recording.marker" "$@" \
    IOS_TEMPLATE_SIMULATOR_SESSION_ID="$session" IOS_TEMPLATE_SIMULATOR_RESOURCE_TEST_MODE=1 \
    IOS_TEMPLATE_SIMULATOR_RESOURCE_STATE_ROOT="${record_resource_state:-$resource_state}" IOS_TEMPLATE_APPSTORE_XCRUN="$fake_bin/xcrun" \
    IOS_TEMPLATE_PREVIEW_SETTLE_SECONDS=0 IOS_TEMPLATE_PREVIEW_STOP_SECONDS=2 \
    ${record_prefix[@]+"${record_prefix[@]}"} \
    "$tool" record --requirements "${record_requirements:-$requirements}" --states "$states" --storyboard "$storyboard" \
    --app-path "$workspace/Fake.app" --bundle-id com.yuto.TemplateApp --source-sha "$source_sha" \
    --build-digest "$build_digest" --runtime "$capture_runtime" --family "$family" --locale "$locale" \
    --output-root "$output" --issue 285 --batch-id preview-test >"$workspace/record.out" 2>"$workspace/record.err"
}
assert_devices_intact() {
  ruby -rjson -e 'devices = JSON.parse(File.binread(ARGV.fetch(0))).fetch("devices").values.flatten
    abort "recording left a Simulator changed" unless devices.length == 3 && devices.all? { |entry| entry["state"] == "Shutdown" }' "$fake_state" || exit 1
  ! rg -q '^simctl (create|clone|rename|delete) ' "$fake_log" || fail 'recording created, cloned, renamed or deleted a Simulator'
  ! rg -qF "$user_udid" "$fake_log" || fail 'recording used a Simulator outside the dedicated declaration'
}
assert_lease_released() { # session [state-root]
  ruby -rjson -e '
    state = JSON.parse(File.binread(File.join(ARGV.fetch(1), "dedicated-v1.json")))
    leases = state.fetch("leases").select { |record| record["sessionId"] == ARGV.fetch(0) }
    abort "session #{ARGV.fetch(0)} has #{leases.length} leases" unless leases.length == 1
    abort "lease of #{ARGV.fetch(0)} is #{leases[0]["status"]}" unless leases[0]["status"] == "released" && leases[0].dig("cleanup", "status") == "passed"
  ' "$1" "${2:-$resource_state}" || exit 1
}
assert_refused_before_simulator() { # label expected-message
  [[ ! -e "$workspace/refused" ]] || fail "a refused recording published output: $1"
  grep -Fq -- "$2" "$workspace/record.err" || { cat "$workspace/record.err" >&2; fail "refused recording failed for another reason: $1"; }
  ! rg -qv '^simctl list -j devicetypes$' "$fake_log" || fail "a refused recording changed a Simulator: $1"
}

# The former iPhone 6.9-inch family, an unknown state, and a dedicated device outside the family stop
# before any Simulator changes.
: >"$fake_log"
if run_record preview-former "$workspace/refused" iphone-6.9 ja; then fail 'recording accepted the former iphone-6.9 family'; fi
assert_refused_before_simulator 'former family' 'family must be iphone-6.3 or ipad-13'
[[ ! -s "$fake_log" ]] || fail 'the former family reached xcrun'
printf '%s\n' '{"schemaVersion":1,"segments":[{"id":"open","state":"missing","seconds":1}]}' >"$workspace/bad-storyboard.json"
: >"$fake_log"; storyboard="$workspace/bad-storyboard.json"
if run_record preview-bad "$workspace/refused" iphone-6.3 ja; then fail 'recording accepted an unknown state'; fi
storyboard=$good_storyboard
assert_refused_before_simulator 'unknown state' 'names unknown state "missing"'
ruby -rjson -e '
  value = JSON.parse(File.binread(ARGV.fetch(0)))
  value.fetch("screenshots").fetch("requiredFamilies").find { |entry| entry.fetch("id") == "iphone-6.3" }["deviceTypes"] = ["iPhone 18 Pro"]
  File.binwrite(ARGV.fetch(1), JSON.generate(value))
' "$requirements" "$workspace/requirements-without-17-pro.json"
: >"$fake_log"; record_requirements="$workspace/requirements-without-17-pro.json"
if run_record preview-outside "$workspace/refused" iphone-6.3 ja; then fail 'recording used a device outside the family'; fi
unset record_requirements
assert_refused_before_simulator 'dedicated device outside the family' \
  'blocked:environment: the dedicated iphone Simulator (iPhone 17 Pro) is not a iphone-6.3 App Store device type'
assert_devices_intact

# The documented command: under the shared lock, one lease of the dedicated iPhone, erase, boot, the
# system language written, restarted and read back, then per segment install, fixed status bar, launch
# in its state, record, stop, and finally the release. The lock comes from a scratch repository so the
# test never contends with a real recording of this repository.
lock_repo="$workspace/lock-repository"
git init -q "$lock_repo"
git -C "$lock_repo" -c user.name='Preview Test' -c user.email='preview@example.invalid' commit -q --allow-empty -m lock
: >"$fake_log"
record_prefix=("$lock_wrapper" --timeout 60 --)
(cd "$lock_repo" && run_record preview-ok "$workspace/recorded" iphone-6.3 ja FAKE_LOCK_REPO="$lock_repo" FAKE_LOCK_WRAPPER="$lock_wrapper") ||
  { cat "$workspace/record.err" >&2; fail 'dedicated recording failed'; }
record_prefix=()
assert_devices_intact
assert_lease_released preview-ok
[[ "$(cat "$workspace/record.out")" == '{"segments":2,"status":"recorded"}' ]] || fail "unexpected recording result: $(cat "$workspace/record.out")"
order=$(rg -o '^(simctl (erase|bootstatus|boot|spawn [^ ]+ defaults (write -g AppleLanguages|write -g AppleLocale|export)|status_bar [^ ]+ (override|clear)|install|launch|io [^ ]+ recordVideo|terminate|uninstall|shutdown)|stopped recordVideo|lock held during recordVideo|lock free during recordVideo)' "$fake_log" |
  sed -E 's/ [0-9A-Fa-f-]{36}//; s/^simctl //' | tr '\n' ',')
segment='install,status_bar override,launch,io recordVideo,lock held during recordVideo,stopped recordVideo,terminate,uninstall,'
expected_order="erase,boot,bootstatus,spawn defaults write -g AppleLanguages,spawn defaults write -g AppleLocale,shutdown,boot,bootstatus,spawn defaults export,${segment}${segment}status_bar clear,shutdown,"
[[ "$order" == "$expected_order" ]] || fail "recording order differs: $order"
[[ "$(tail -n 1 "$fake_log")" == 'simctl list devices -j' ]] || fail 'the lease was not released after the last recording stopped'
[[ "$(rg -c '^simctl erase ' "$fake_log")" == 1 ]] || fail 'the lease did not erase the dedicated device exactly once'
rg -qF "$iphone_udid" "$fake_log" && ! rg -qF "$ipad_udid" "$fake_log" || fail 'iPhone recording used the wrong device'
rg -qx "simctl spawn $iphone_udid defaults write -g AppleLanguages -array ja-JP" "$fake_log" &&
  rg -qx "simctl spawn $iphone_udid defaults write -g AppleLocale -string ja_JP" "$fake_log" || fail 'the Japanese system language was not written'
rg -q 'status_bar .* override --time 9:41 .*--batteryState charged --batteryLevel 100' "$fake_log" || fail 'fixed status bar was not applied'
rg -q -- '-AppleLanguages \(ja\) -AppleLocale ja_JP .*--fixture primary$' "$fake_log" &&
  rg -q -- '-AppleLanguages \(ja\) -AppleLocale ja_JP .*--fixture rain$' "$fake_log" || fail 'state launch arguments are missing'
! rg -q -- '--disable-animations' "$fake_log" || fail 'recording disabled animations'
[[ "$(rg -c 'recordVideo --codec=h264 --force ' "$fake_log")" == 2 ]] || fail 'recording did not use H.264 for each segment'
# Only the clips, the record and the lease receipts leave the device; the record holds exactly its fields
# and nothing that identifies the Mac, the session or the device.
ruby -rjson -rdigest -e '
  root = ARGV.fetch(0)
  files = Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |path| File.directory?(File.join(root, path)) || path.end_with?("/.") || path == "." }
  receipts = files.grep(%r{\Asimulator-allocations/allocation-[0-9a-f-]{36}\.json\z})
  abort "published files: #{files.sort}" unless (files - receipts).sort == %w[ja/iphone-6.3/01-open.mp4 ja/iphone-6.3/02-rain.mp4 record.json] && receipts.length == 1
  text = File.read(File.join(root, "record.json")); record = JSON.parse(text)
  abort "record fields" unless record.keys.sort == %w[buildDigest deviceType family locale runtime schemaVersion segments sourceSha]
  abort "record identity" unless record.values_at("schemaVersion", "family", "locale", "deviceType", "runtime", "sourceSha", "buildDigest") ==
    [1, "iphone-6.3", "ja", "iPhone 17 Pro", ARGV.fetch(1), ARGV.fetch(2), ARGV.fetch(3)]
  segments = record.fetch("segments")
  abort "segments" unless segments.map { |entry| entry.values_at("id", "state", "seconds", "allowStill", "path") } ==
    [["open", "primary", 1, false, "ja/iphone-6.3/01-open.mp4"], ["rain", "rain", 1, true, "ja/iphone-6.3/02-rain.mp4"]]
  segments.each do |entry|
    abort "segment keys" unless entry.keys.sort == %w[allowStill id path seconds sha256 state]
    abort "segment digest" unless entry.fetch("sha256") == "sha256:#{Digest::SHA256.file(File.join(root, entry.fetch("path"))).hexdigest}"
  end
  [ARGV.fetch(4), "00000000-0000-0000-0000-00000000000", "preview-ok", "/Users/", "/private/", "/var/", ENV.fetch("HOME")].each do |secret|
    abort "record carries #{secret}" if text.include?(secret)
  end
  receipt = JSON.parse(File.read(File.join(root, receipts.first)))
  abort "lease not released" unless receipt.fetch("status") == "released" && receipt.dig("cleanup", "status") == "passed" && receipt.fetch("deviceName") == ARGV.fetch(5)
' "$workspace/recorded" "$capture_runtime" "$source_sha" "$build_digest" "$workspace" "$iphone_name"

# iPad records in English on the dedicated iPad only.
: >"$fake_log"
run_record preview-ipad "$workspace/recorded-ipad" ipad-13 en-US || { cat "$workspace/record.err" >&2; fail 'dedicated iPad recording failed'; }
rg -qF "$ipad_udid" "$fake_log" && ! rg -qF "$iphone_udid" "$fake_log" || fail 'iPad recording used the wrong device'
rg -qx "simctl spawn $ipad_udid defaults write -g AppleLanguages -array en-US" "$fake_log" &&
  rg -qx "simctl spawn $ipad_udid defaults write -g AppleLocale -string en_US" "$fake_log" || fail 'the English system language was not written'
jq -e '.family == "ipad-13" and .locale == "en-US" and .deviceType == "iPad Pro (M5)" and (.segments | map(.path) == ["en-US/ipad-13/01-open.mp4", "en-US/ipad-13/02-rain.mp4"])' \
  "$workspace/recorded-ipad/record.json" >/dev/null || fail 'iPad record differs'
assert_devices_intact
assert_lease_released preview-ipad

# A system language that does not survive the restart stops before the app is installed.
: >"$fake_log"
if run_record preview-locale "$workspace/refused" iphone-6.3 ja FAKE_LOCALE_LOST=1; then fail 'recording continued without the system language'; fi
grep -Fq 'the dedicated Simulator system language/locale is not ja-JP/ja_JP after the restart' "$workspace/record.err" || {
  cat "$workspace/record.err" >&2; fail 'a lost system language failed for another reason'; }
! rg -q '^simctl (install|launch|io) ' "$fake_log" || fail 'recording reached the app without the system language'
[[ ! -e "$workspace/refused" ]] || fail 'a lost system language published output'
assert_devices_intact
assert_lease_released preview-locale

# A recorder that fails, a recorder that ignores SIGINT past the stop window, and a step that exceeds
# its time limit each fail the run, publish nothing, and release the lease (AC-4).
: >"$fake_log"
if run_record preview-fail "$workspace/refused" iphone-6.3 ja FAKE_FAIL_RECORD=1; then fail 'recording succeeded after a recorder failure'; fi
grep -Fq 'recording of open stopped early' "$workspace/record.err" || { cat "$workspace/record.err" >&2; fail 'unexpected recorder failure'; }
[[ ! -e "$workspace/refused" ]] || fail 'failed recording published output'
assert_devices_intact
assert_lease_released preview-fail
: >"$fake_log"
if run_record preview-hang "$workspace/refused" iphone-6.3 ja FAKE_IGNORE_INT=1; then fail 'recording succeeded after a recorder ignored SIGINT'; fi
grep -Fq 'recording of open did not stop cleanly' "$workspace/record.err" || { cat "$workspace/record.err" >&2; fail 'unexpected hung recorder failure'; }
[[ ! -e "$workspace/refused" ]] || fail 'hung recording published output'
! pgrep -f "simctl io $iphone_udid recordVideo" >/dev/null || fail 'a hung recorder outlived the run'
assert_devices_intact
assert_lease_released preview-hang
: >"$fake_log"
if run_record preview-timeout "$workspace/refused" iphone-6.3 ja FAKE_HANG=launch IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS=5; then
  fail 'recording succeeded after a step timed out'
fi
grep -Fq 'bounded command timed out: stage=appstore-simulator-launch' "$workspace/record.err" || { cat "$workspace/record.err" >&2; fail 'unexpected timeout failure'; }
[[ ! -e "$workspace/refused" ]] || fail 'timed-out recording published output'
assert_devices_intact
assert_lease_released preview-timeout

# INT and TERM during a recording stop the recorder at once and release the lease.
printf '%s\n' '{"schemaVersion":1,"segments":[{"id":"long","state":"primary","seconds":30}]}' >"$workspace/long-storyboard.json"
storyboard="$workspace/long-storyboard.json"
for signal in INT TERM; do
  : >"$fake_log"
  run_record "preview-$signal" "$workspace/refused" iphone-6.3 ja &
  record_job=$!
  for _ in $(seq 1 150); do rg -q 'recordVideo' "$fake_log" 2>/dev/null && [[ -s "$workspace/record.pid" ]] && break; /bin/sleep 0.1; done
  rg -q 'recordVideo' "$fake_log" || fail "recording never started before $signal"
  /bin/sleep 0.5
  signal_started=$(date +%s)
  kill "-$signal" "$(cat "$workspace/record.pid")" || fail "could not send $signal to the recording tool"
  if wait "$record_job"; then fail "a recording reported success after $signal"; fi
  (( $(date +%s) - signal_started < 15 )) || fail "$signal did not stop the recording promptly"
  rg -qx "stopped recordVideo $iphone_udid" "$fake_log" || fail "$signal did not stop the recorder"
  [[ ! -e "$workspace/refused" ]] || fail "a recording stopped by $signal published output"
  assert_devices_intact
  assert_lease_released "preview-$signal"
done
storyboard=$good_storyboard

# A lease that cannot be released fails the run even after every clip was recorded (AC-4).
: >"$fake_log"
record_resource_state="$workspace/resource-state-release-failure"
if run_record preview-release "$workspace/refused" iphone-6.3 ja FAKE_FAIL_RELEASE=1; then fail 'recording reported success without releasing its lease'; fi
grep -Fq 'App Store preview recording failed to release its owned Simulator; durable allocation remains for recovery' "$workspace/record.err" || {
  cat "$workspace/record.err" >&2; fail 'a failed release was not reported'; }
[[ ! -e "$workspace/refused" ]] || fail 'a recording without a released lease published output'
ruby -rjson -e 'leases = JSON.parse(File.binread(File.join(ARGV.fetch(0), "dedicated-v1.json"))).fetch("leases")
  abort "the unreleased lease is not kept for recovery" unless leases.length == 1 && leases[0]["status"] == "cleanup-failed"' "$record_resource_state"
unset record_resource_state

# macOS /bin/bash 3.2 stops with "unbound variable" on an empty array under set -u, which is how the
# resource test flags and a state without launch arguments arrive outside test mode.
if grep -n 'resource_test_flags\[@\]\|launch_arguments\[@\]' "$tool" | grep -v '\${resource_test_flags\[@\]+"\${resource_test_flags\[@\]}"}\|\${launch_arguments\[@\]+"\${launch_arguments\[@\]}"}' | grep -q .; then
  fail 'recording expands an array without the empty-array guard'
fi
[[ "$(grep -c '\${resource_test_flags\[@\]+"\${resource_test_flags\[@\]}"}' "$tool")" -eq 2 ]] || fail 'recording must pass the guarded resource_test_flags to allocate and release'

# The skill documents the locked command and the gate's thresholds.
flows="$repo_root/.agents/skills/appstore-creative/references/flows.md"
rg -q 'tools/with-ios-simulator-lock\.sh --timeout 0 -- tools/record-appstore-preview\.sh record' "$flows" || fail 'flows guide does not run the recorder under the shared lock'
rg -q -- '--family iphone-6\.3' "$flows" && rg -q '1206×2622' "$flows" && rg -q '2064×2752' "$flows" || fail 'flows guide does not give the D-079 recording sizes'
rg -q 'at least 30 fps' "$flows" && rg -q '100 ms' "$flows" && rg -q '0\.5 s' "$flows" && rg -q '0\.1 s' "$flows" || fail 'flows guide does not state the quality thresholds'

echo 'appstore preview recording and quality tests passed'
