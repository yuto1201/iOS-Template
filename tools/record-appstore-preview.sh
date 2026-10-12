#!/bin/bash
set -euo pipefail

# D-077: record App Store preview footage on the repository's dedicated Simulator. Run `record` through
# tools/with-ios-simulator-lock.sh. One run records the storyboard segments of one family and locale
# under one lease, the same way the screenshot capture does: the Mac-wide resource manager erases the
# device before the lease and shuts it down on release, the device's system language is written and
# read back, and no device is created, cloned, renamed or deleted. `check` runs the machine quality gate
# on a clip.

record_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source "$record_script_dir/lib/bounded-command.sh"
quality="$record_script_dir/lib/appstore-preview-quality.rb"

usage() {
  echo "usage: $0 record --requirements FILE --states FILE --storyboard FILE --app-path APP --bundle-id ID --source-sha SHA --build-digest sha256:HEX --runtime ID --family iphone-6.3|ipad-13 --locale en-US|ja --output-root DIR --issue NUMBER --batch-id ID" >&2
  echo "       $0 check --clip FILE --family iphone|ipad --seconds N [--allow-still] [--minimum-size] [--output FILE]" >&2
  exit 64
}

command=${1-}; shift || true
case "$command" in
  check) exec /usr/bin/ruby --disable-gems "$quality" "$@" ;;
  record) ;;
  *) usage ;;
esac

requirements= states= storyboard= app_path= bundle_id= source_sha= build_digest= runtime= family= locale= output_root= issue= batch_id=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --requirements) requirements=${2-}; shift 2 ;;
    --states) states=${2-}; shift 2 ;;
    --storyboard) storyboard=${2-}; shift 2 ;;
    --app-path) app_path=${2-}; shift 2 ;;
    --bundle-id) bundle_id=${2-}; shift 2 ;;
    --source-sha) source_sha=${2-}; shift 2 ;;
    --build-digest) build_digest=${2-}; shift 2 ;;
    --runtime) runtime=${2-}; shift 2 ;;
    --family) family=${2-}; shift 2 ;;
    --locale) locale=${2-}; shift 2 ;;
    --output-root) output_root=${2-}; shift 2 ;;
    --issue) issue=${2-}; shift 2 ;;
    --batch-id) batch_id=${2-}; shift 2 ;;
    *) usage ;;
  esac
done
for value in "$requirements" "$states" "$storyboard" "$app_path" "$bundle_id" "$source_sha" "$build_digest" "$runtime" "$family" "$locale" "$output_root" "$issue" "$batch_id"; do
  [[ -n "$value" ]] || usage
done
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'source SHA must be a full lowercase Git SHA' >&2; exit 1; }
[[ "$build_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'build digest is invalid' >&2; exit 1; }
[[ "$bundle_id" =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9-]+)+$ ]] || { echo 'bundle identifier is invalid' >&2; exit 1; }
[[ "$runtime" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'runtime identifier is invalid' >&2; exit 1; }
# D-079: the App Store iPhone family is iphone-6.3 (the dedicated iPhone 17 Pro, 1206x2622).
[[ "$family" == iphone-6.3 || "$family" == ipad-13 ]] || { echo 'family must be iphone-6.3 or ipad-13' >&2; exit 1; }
[[ "$locale" == ja || "$locale" == en-US ]] || { echo 'locale must be ja or en-US' >&2; exit 1; }
[[ "$issue" =~ ^[1-9][0-9]*$ ]] || { echo 'Issue number is invalid' >&2; exit 1; }
[[ "$batch_id" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,63}$ ]] || { echo 'batch identifier is invalid' >&2; exit 1; }
for file in "$requirements" "$states" "$storyboard"; do
  [[ -f "$file" && ! -L "$file" ]] || { echo "input must be a regular non-symbolic-link file: $(basename "$file")" >&2; exit 1; }
done
[[ -d "$app_path" && ! -L "$app_path" ]] || { echo 'app path must be a non-symbolic-link directory' >&2; exit 1; }
repository_root=$(git -C "$record_script_dir/.." rev-parse --show-toplevel 2>/dev/null) || { echo 'recording requires a Git worktree' >&2; exit 1; }
repository_root=$(cd "$repository_root" && /bin/pwd -P)
[[ "$(git -C "$repository_root" rev-parse HEAD)" == "$source_sha" ]] || { echo 'source SHA differs from the recording worktree Head' >&2; exit 1; }
resource_manager="$record_script_dir/lib/ios-simulator-resource.rb"
[[ -f "$resource_manager" && ! -L "$resource_manager" ]] || { echo 'Simulator resource manager is unavailable' >&2; exit 1; }
dedicated_config="$repository_root/Config/dedicated-simulators.json"
[[ -f "$dedicated_config" && ! -L "$dedicated_config" ]] || { echo 'blocked:environment: Config/dedicated-simulators.json is not a regular file' >&2; exit 1; }

resource_test_mode=${IOS_TEMPLATE_SIMULATOR_RESOURCE_TEST_MODE:-0}
resource_test_flags=()
if [[ "$resource_test_mode" == 1 ]]; then
  xcrun_bin=${IOS_TEMPLATE_APPSTORE_XCRUN:-}
  state_root=${IOS_TEMPLATE_SIMULATOR_RESOURCE_STATE_ROOT:-}
  [[ -x "$xcrun_bin" && "$state_root" == /* ]] || { echo 'Simulator resource test configuration is incomplete' >&2; exit 1; }
  resource_test_flags=(--test-mode --state-root "$state_root" --xcrun "$xcrun_bin" --minimum-free-bytes 0)
else
  [[ "$resource_test_mode" == 0 && -z "${IOS_TEMPLATE_APPSTORE_XCRUN:-}" && -z "${IOS_TEMPLATE_SIMULATOR_RESOURCE_STATE_ROOT:-}" ]] || {
    echo 'Simulator resource test hooks require explicit test mode' >&2; exit 1;
  }
  xcrun_bin=/usr/bin/xcrun
  [[ -x "$xcrun_bin" ]] || { echo 'xcrun is unavailable' >&2; exit 1; }
fi
simctl_timeout=${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}
settle_seconds=${IOS_TEMPLATE_PREVIEW_SETTLE_SECONDS:-2}
stop_seconds=${IOS_TEMPLATE_PREVIEW_STOP_SECONDS:-30}
start_seconds=${IOS_TEMPLATE_PREVIEW_START_SECONDS:-10}
[[ "$settle_seconds" =~ ^[0-9]+$ && "$stop_seconds" =~ ^[1-9][0-9]*$ && "$start_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo 'recording timing settings are invalid' >&2; exit 1;
}

simulator_session_id=${IOS_TEMPLATE_SIMULATOR_SESSION_ID:-${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}}
if [[ -z "$simulator_session_id" ]]; then
  simulator_session_id=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')
fi
[[ "$simulator_session_id" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$ ]] || { echo 'Simulator session identity is invalid' >&2; exit 1; }

for variable in requirements states storyboard app_path; do
  value=${!variable}; directory=$(cd "$(dirname "$value")" && /bin/pwd -P)
  printf -v "$variable" '%s/%s' "$directory" "$(basename "$value")"
done
output_parent=$(cd "$(dirname "$output_root")" && /bin/pwd -P)
output_root="$output_parent/$(basename "$output_root")"
[[ ! -e "$output_root" && ! -L "$output_root" ]] || { echo 'output root already exists; refusing to overwrite it' >&2; exit 1; }
staging=$(mktemp -d "$output_parent/.appstore-preview.XXXXXX")
allocation_receipt_dir="$staging/simulator-allocations"
/bin/mkdir -m 700 "$allocation_receipt_dir"
attempt_id="appstore-preview-$$"
active_allocation_id=
active_allocation_udid=
active_allocation_receipt=
recorder_pid=
sleep_pid=

run_simulator_resource() {
  /usr/bin/ruby --disable-gems "$resource_manager" "$@"
}

release_active_simulator() {
  local reason=$1 output allocation_id udid receipt
  [[ -n "$active_allocation_id" ]] || return 0
  output=$(run_simulator_resource release ${resource_test_flags[@]+"${resource_test_flags[@]}"} \
    --session "$simulator_session_id" --allocation-id "$active_allocation_id" \
    --reason "$reason" --receipt-dir "$allocation_receipt_dir") || return 1
  IFS=$'\t' read -r allocation_id udid receipt <<<"$output"
  [[ "$allocation_id" == "$active_allocation_id" && "$udid" == "$active_allocation_udid" && \
     "$receipt" == "$active_allocation_receipt" && -f "$receipt" ]] || return 1
  active_allocation_id=
  active_allocation_udid=
  active_allocation_receipt=
}

# Stop a running recorder: SIGINT lets simctl finish the file; anything that outlives the stop window
# is terminated and then killed, and the recording counts as failed.
stop_recorder() {
  local pid=$recorder_pid waited=0
  [[ -n "$pid" ]] || return 0
  kill -INT "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt "$stop_seconds" ]]; do
    /bin/sleep 1; waited=$((waited+1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    /bin/sleep 2
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    recorder_pid=
    return 1
  fi
  local status=0
  wait "$pid" 2>/dev/null || status=$?
  recorder_pid=
  [[ "$status" -eq 0 || "$status" -eq 130 ]]
}

# Wait in the background so that INT and TERM run their traps at once instead of after a long sleep.
pause() {
  /bin/sleep "$1" &
  sleep_pid=$!
  wait "$sleep_pid"
  sleep_pid=
}

cleanup() {
  local status=$? cleanup_status=0
  trap - EXIT INT TERM
  # Nothing in this trap may stop it under set -e before the lease is released.
  if [[ -n "$sleep_pid" ]]; then kill "$sleep_pid" 2>/dev/null || true; fi
  if [[ -n "$recorder_pid" ]]; then
    stop_recorder || true
  fi
  if [[ -n "$active_allocation_id" ]]; then
    release_active_simulator appstore-preview-aborted || cleanup_status=1
  fi
  if [[ -n "${staging:-}" && -d "$staging" ]]; then rm -rf -- "$staging" || true; fi
  if [[ "$cleanup_status" -ne 0 ]]; then
    echo 'App Store preview recording failed to release its owned Simulator; durable allocation remains for recovery' >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bounded_run appstore-simulator-inventory "$simctl_timeout" "$xcrun_bin" simctl list -j devicetypes > "$staging/inventory.json"
REQUIREMENTS="$requirements" STATES="$states" STORYBOARD="$storyboard" INVENTORY="$staging/inventory.json" PLAN="$staging/plan.json" \
DEDICATED="$dedicated_config" RUNTIME="$runtime" FAMILY="$family" LOCALE="$locale" ruby --disable-gems <<'RUBY'
require "json"

requirements = JSON.parse(File.binread(ENV.fetch("REQUIREMENTS")))
states = JSON.parse(File.binread(ENV.fetch("STATES")))
storyboard = JSON.parse(File.binread(ENV.fetch("STORYBOARD")))
inventory = JSON.parse(File.binread(ENV.fetch("INVENTORY")))
abort "states schemaVersion is invalid" unless states.is_a?(Hash) && states["schemaVersion"] == 1
locale = (states["locales"] || []).find { |entry| entry.is_a?(Hash) && entry["id"] == ENV.fetch("LOCALE") }
abort "locale #{ENV.fetch("LOCALE")} is not defined in states" unless locale &&
  %w[appleLanguage appleLocale].all? { |key| locale[key].is_a?(String) && locale[key].match?(/\A[A-Za-z0-9_-]+\z/) }
launch = (states["states"] || []).to_h { |entry| [entry["id"], entry["launchArguments"]] }

abort "storyboard must be an object with schemaVersion 1 and segments" unless storyboard.is_a?(Hash) &&
  storyboard.keys.sort == %w[schemaVersion segments] && storyboard["schemaVersion"] == 1 && storyboard["segments"].is_a?(Array)
segments = storyboard["segments"]
abort "storyboard needs at least one segment" if segments.empty?
segments.each do |segment|
  abort "storyboard segment is invalid" unless segment.is_a?(Hash) && (segment.keys - %w[id state seconds allowStill]).empty? &&
    segment["id"].is_a?(String) && segment["id"].match?(/\A[a-z0-9][a-z0-9-]{0,31}\z/)
  abort "storyboard segment #{segment["id"]} names unknown state #{segment["state"].inspect}" unless launch.key?(segment["state"])
  args = launch.fetch(segment["state"])
  abort "state #{segment["state"]} has invalid launch arguments" unless args.is_a?(Array) && args.all? { |arg| arg.is_a?(String) && !arg.empty? && !arg.match?(/[\r\n\0]/) }
  abort "storyboard segment #{segment["id"]} seconds must be an integer from 1 to 30" unless segment["seconds"].is_a?(Integer) && (1..30).cover?(segment["seconds"])
  abort "storyboard segment #{segment["id"]} allowStill must be true or false" unless [nil, true, false].include?(segment["allowStill"])
end
ids = segments.map { |segment| segment["id"] }
abort "storyboard segment ids must be unique" unless ids.uniq.length == ids.length
abort "storyboard is longer than 30 seconds" if segments.sum { |segment| segment["seconds"] } > 30

# D-063/D-070: record only on the dedicated Simulator declared for the family's platform.
type_names = (inventory["devicetypes"].is_a?(Array) ? inventory["devicetypes"] : []).select { |entry| entry.is_a?(Hash) }.to_h { |entry| [entry["identifier"], entry["name"]] }
dedicated = JSON.parse(File.binread(ENV.fetch("DEDICATED")))
declared = (dedicated.is_a?(Hash) && dedicated["devices"].is_a?(Array) ? dedicated["devices"] : []).select { |entry| entry.is_a?(Hash) }.group_by { |entry| entry["family"] }
family = (requirements.dig("screenshots", "requiredFamilies") || []).find { |entry| entry["id"] == ENV.fetch("FAMILY") }
abort "family #{ENV.fetch("FAMILY")} is not in the requirements" unless family && family["deviceTypes"].is_a?(Array)
platform = family["platform"]
matches = declared.fetch(platform, [])
abort "blocked:environment: no dedicated Simulator is declared for #{platform}" unless matches.length == 1 && matches[0]["deviceTypeIdentifier"].is_a?(String)
device = matches[0]
abort "blocked:environment: --runtime differs from the dedicated #{platform} Simulator declaration" unless device["runtimeIdentifier"] == ENV.fetch("RUNTIME")
name = type_names[device["deviceTypeIdentifier"]]
abort "blocked:environment: the dedicated #{platform} Device Type is not installed" unless name.is_a?(String)
size = family.fetch("id")[/-([0-9.]+)\z/, 1]
candidates = [name]
candidates << name.sub(" #{size}-inch ", " ") if size && name.include?(" #{size}-inch ")
apple_name = family["deviceTypes"].find { |entry| candidates.include?(entry) }
abort "blocked:environment: the dedicated #{platform} Simulator (#{name}) is not a #{family["id"]} App Store device type" unless apple_name
File.binwrite(ENV.fetch("PLAN"), JSON.generate({
  "schemaVersion" => 1, "family" => family.fetch("id"), "platform" => platform, "deviceType" => apple_name,
  "deviceTypeIdentifier" => device.fetch("deviceTypeIdentifier"), "locale" => locale.fetch("id"),
  "appleLanguage" => locale.fetch("appleLanguage"), "appleLocale" => locale.fetch("appleLocale"),
  "segments" => segments.map { |segment| segment.merge("launchArguments" => launch.fetch(segment["state"])) }
}))
RUBY

plan_value() { ruby -rjson -e 'puts JSON.parse(File.binread(ARGV.fetch(0))).fetch(ARGV.fetch(1))' "$staging/plan.json" "$1"; }
device_identifier=$(plan_value deviceTypeIdentifier)
language=$(plan_value appleLanguage)
apple_locale=$(plan_value appleLocale)
case "$family:$locale" in
  iphone-*:en-US) case_id=iphone-en ;;
  iphone-*:ja) case_id=iphone-ja ;;
  ipad-*:en-US) case_id=ipad-en ;;
  ipad-*:ja) case_id=ipad-ja ;;
  *) echo "unsupported App Store preview condition: $family/$locale" >&2; exit 1 ;;
esac
# Launch arguments only reach the app. The status bar and system UI follow the device's own language,
# which an erased device takes from the Mac, so the system language is written and the device restarted
# in place (erasing would drop it) before any recording, as the screenshot capture does (#173).
case "$language:$apple_locale" in
  en:en_US) system_language=en-US ;;
  ja:ja_JP) system_language=ja-JP ;;
  *) echo "unsupported App Store preview system language: $language/$apple_locale" >&2; exit 1 ;;
esac

allocation_output=$(run_simulator_resource allocate ${resource_test_flags[@]+"${resource_test_flags[@]}"} \
  --session "$simulator_session_id" --repository "$repository_root" --issue "$issue" --head "$source_sha" \
  --batch "$batch_id" --attempt "$attempt_id" --case "$case_id" --runtime "$runtime" \
  --device-type "$device_identifier" --owner-pid "$$" --wait-seconds 60 \
  --receipt-dir "$allocation_receipt_dir")
IFS=$'\t' read -r active_allocation_id active_allocation_udid active_allocation_receipt <<<"$allocation_output"
allocation_receipt_dir_physical=$(cd "$allocation_receipt_dir" && /bin/pwd -P)
[[ "$active_allocation_id" =~ ^[0-9a-f-]{36}$ && "$active_allocation_udid" =~ ^[0-9A-Fa-f-]+$ && \
   "$active_allocation_receipt" == "$allocation_receipt_dir_physical/allocation-$active_allocation_id.json" && \
   -f "$active_allocation_receipt" ]] || { echo 'Simulator allocation receipt is invalid' >&2; exit 1; }

bounded_run appstore-simulator-boot "$simctl_timeout" "$xcrun_bin" simctl boot "$active_allocation_udid"
bounded_run appstore-simulator-bootstatus "${IOS_TEMPLATE_SIMULATOR_BOOT_TIMEOUT_SECONDS:-300}" "$xcrun_bin" simctl bootstatus "$active_allocation_udid" -b
bounded_run appstore-system-language "$simctl_timeout" "$xcrun_bin" simctl spawn "$active_allocation_udid" defaults write -g AppleLanguages -array "$system_language"
bounded_run appstore-system-locale "$simctl_timeout" "$xcrun_bin" simctl spawn "$active_allocation_udid" defaults write -g AppleLocale -string "$apple_locale"
bounded_run appstore-locale-shutdown "$simctl_timeout" "$xcrun_bin" simctl shutdown "$active_allocation_udid"
bounded_run appstore-locale-boot "$simctl_timeout" "$xcrun_bin" simctl boot "$active_allocation_udid"
bounded_run appstore-locale-bootstatus "${IOS_TEMPLATE_SIMULATOR_BOOT_TIMEOUT_SECONDS:-300}" "$xcrun_bin" simctl bootstatus "$active_allocation_udid" -b
system_preferences="$staging/system-preferences.plist"
bounded_run appstore-system-locale-readback "$simctl_timeout" "$xcrun_bin" simctl spawn "$active_allocation_udid" defaults export -g - > "$system_preferences"
observed_languages=$(/usr/bin/plutil -extract AppleLanguages json -o - "$system_preferences" 2>/dev/null) || observed_languages=
observed_locale=$(/usr/bin/plutil -extract AppleLocale raw -o - "$system_preferences" 2>/dev/null) || observed_locale=
[[ "$observed_languages" == "[\"$system_language\"]" && "$observed_locale" == "$apple_locale" ]] || {
  echo "the dedicated Simulator system language/locale is not $system_language/$apple_locale after the restart" >&2; exit 1;
}

segment_count=$(ruby -rjson -e 'puts JSON.parse(File.binread(ARGV.fetch(0))).fetch("segments").length' "$staging/plan.json")
mkdir -p "$staging/$locale/$family"
segment_index=0
while [[ "$segment_index" -lt "$segment_count" ]]; do
  IFS=$'\t' read -r segment_id seconds < <(
    ruby -rjson -e 'entry = JSON.parse(File.binread(ARGV.fetch(0))).fetch("segments").fetch(Integer(ARGV.fetch(1)))
      puts entry.values_at("id", "seconds").join("\t")' "$staging/plan.json" "$segment_index"
  )
  launch_arguments=()
  while IFS= read -r argument; do launch_arguments+=("$argument"); done < <(
    ruby -rjson -e 'JSON.parse(File.binread(ARGV.fetch(0))).fetch("segments").fetch(Integer(ARGV.fetch(1))).fetch("launchArguments").each { |arg| puts arg }' \
      "$staging/plan.json" "$segment_index"
  )
  destination="$staging/$locale/$family/$(printf '%02d' "$((segment_index+1))")-$segment_id.mp4"
  bounded_run appstore-simulator-install "$simctl_timeout" "$xcrun_bin" simctl install "$active_allocation_udid" "$app_path"
  # The fixed status bar (9:41, full battery) is applied after each install, right before the launch.
  bounded_run appstore-status-bar "$simctl_timeout" "$xcrun_bin" simctl status_bar "$active_allocation_udid" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100
  # Animations stay on for footage; the fixed date keeps the clock and data deterministic.
  bounded_run appstore-simulator-launch "$simctl_timeout" "$xcrun_bin" simctl launch --terminate-running-process "$active_allocation_udid" "$bundle_id" \
    -AppleLanguages "($language)" -AppleLocale "$apple_locale" -AppleInterfaceStyle Light \
    --fixed-date 2026-01-01T09:41:00Z ${launch_arguments[@]+"${launch_arguments[@]}"}
  pause "$settle_seconds"
  # A background job of a non-interactive shell ignores SIGINT, which simctl needs to finish the file,
  # so the recorder starts with the default SIGINT disposition restored.
  recorder_log="$staging/recorder-$segment_id.log"
  /usr/bin/ruby --disable-gems -e 'Signal.trap("INT", "SYSTEM_DEFAULT"); exec(*ARGV)' \
    "$xcrun_bin" simctl io "$active_allocation_udid" recordVideo --codec=h264 --force "$destination" 2>"$recorder_log" &
  recorder_pid=$!
  # simctl takes a moment before it captures; count the segment from its "Recording started" notice.
  waited=0
  until /usr/bin/grep -qi 'recording started' "$recorder_log" 2>/dev/null || [[ "$waited" -ge $((start_seconds * 5)) ]]; do
    kill -0 "$recorder_pid" 2>/dev/null || break
    pause 0.2; waited=$((waited+1))
  done
  /usr/bin/grep -qi 'recording started' "$recorder_log" 2>/dev/null ||
    echo "warning: recorder for $segment_id did not report its start; timing from now" >&2
  pause "$seconds"
  kill -0 "$recorder_pid" 2>/dev/null || { recorder_pid=; echo "recording of $segment_id stopped early" >&2; exit 1; }
  stop_recorder || { echo "recording of $segment_id did not stop cleanly" >&2; exit 1; }
  [[ -s "$destination" && ! -L "$destination" ]] || { echo "recording of $segment_id produced no file" >&2; exit 1; }
  bounded_run appstore-simulator-terminate "$simctl_timeout" "$xcrun_bin" simctl terminate "$active_allocation_udid" "$bundle_id"
  bounded_run appstore-simulator-uninstall "$simctl_timeout" "$xcrun_bin" simctl uninstall "$active_allocation_udid" "$bundle_id"
  segment_index=$((segment_index+1))
done

bounded_run appstore-status-bar-clear "$simctl_timeout" "$xcrun_bin" simctl status_bar "$active_allocation_udid" clear
bounded_run appstore-simulator-shutdown "$simctl_timeout" "$xcrun_bin" simctl shutdown "$active_allocation_udid"
release_active_simulator appstore-preview-complete || { echo 'owned Simulator release failed' >&2; exit 1; }

PLAN="$staging/plan.json" ROOT="$staging" SOURCE_SHA="$source_sha" BUILD_DIGEST="$build_digest" RUNTIME="$runtime" ruby --disable-gems <<'RUBY'
require "json"
require "digest"

root = ENV.fetch("ROOT")
plan = JSON.parse(File.binread(ENV.fetch("PLAN")))
segments = plan.fetch("segments").each_with_index.map do |segment, index|
  relative = "#{plan.fetch("locale")}/#{plan.fetch("family")}/#{format('%02d', index + 1)}-#{segment.fetch("id")}.mp4"
  stat = File.lstat(File.join(root, relative))
  abort "recording is not a regular file" unless stat.file? && !stat.symlink?
  {"id" => segment.fetch("id"), "state" => segment.fetch("state"), "seconds" => segment.fetch("seconds"),
   "allowStill" => segment.fetch("allowStill", false), "path" => relative,
   "sha256" => "sha256:#{Digest::SHA256.file(File.join(root, relative)).hexdigest}"}
end
record = {"schemaVersion" => 1, "family" => plan.fetch("family"), "locale" => plan.fetch("locale"),
  "deviceType" => plan.fetch("deviceType"), "runtime" => ENV.fetch("RUNTIME"), "sourceSha" => ENV.fetch("SOURCE_SHA"),
  "buildDigest" => ENV.fetch("BUILD_DIGEST"), "segments" => segments}
File.binwrite(File.join(root, "record.json"), JSON.pretty_generate(record) + "\n")
File.chmod(0o644, File.join(root, "record.json"))
RUBY

rm -f -- "$staging/inventory.json" "$staging/plan.json" "$staging/system-preferences.plist" "$staging"/recorder-*.log
/bin/mv "$staging" "$output_root"
staging=
trap - EXIT INT TERM
printf '{"segments":%s,"status":"recorded"}\n' "$segment_count"
