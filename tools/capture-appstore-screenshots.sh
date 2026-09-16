#!/bin/bash
set -euo pipefail

capture_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source "$capture_script_dir/lib/bounded-command.sh"

usage() {
  echo "usage: $0 --requirements FILE --states FILE --app-path APP --bundle-id ID --source-sha SHA --build-digest sha256:HEX --runtime ID --output-root DIR --issue NUMBER --batch-id ID" >&2
  exit 64
}

requirements= states= app_path= bundle_id= source_sha= build_digest= runtime= output_root= issue= batch_id=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --requirements) requirements=${2-}; shift 2 ;;
    --states) states=${2-}; shift 2 ;;
    --app-path) app_path=${2-}; shift 2 ;;
    --bundle-id) bundle_id=${2-}; shift 2 ;;
    --source-sha) source_sha=${2-}; shift 2 ;;
    --build-digest) build_digest=${2-}; shift 2 ;;
    --runtime) runtime=${2-}; shift 2 ;;
    --output-root) output_root=${2-}; shift 2 ;;
    --issue) issue=${2-}; shift 2 ;;
    --batch-id) batch_id=${2-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$requirements" && -n "$states" && -n "$app_path" && -n "$bundle_id" && -n "$source_sha" && -n "$build_digest" && -n "$runtime" && -n "$output_root" && -n "$issue" && -n "$batch_id" ]] || usage
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'source SHA must be a full lowercase Git SHA' >&2; exit 1; }
[[ "$build_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'build digest is invalid' >&2; exit 1; }
[[ "$bundle_id" =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9-]+)+$ ]] || { echo 'bundle identifier is invalid' >&2; exit 1; }
[[ "$runtime" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'runtime identifier is invalid' >&2; exit 1; }
[[ "$issue" =~ ^[1-9][0-9]*$ ]] || { echo 'Issue number is invalid' >&2; exit 1; }
[[ "$batch_id" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,63}$ ]] || { echo 'batch identifier is invalid' >&2; exit 1; }
for file in "$requirements" "$states"; do
  [[ -f "$file" && ! -L "$file" ]] || { echo "input must be a regular non-symbolic-link file: $(basename "$file")" >&2; exit 1; }
done
[[ -d "$app_path" && ! -L "$app_path" ]] || { echo 'app path must be a non-symbolic-link directory' >&2; exit 1; }
repository_root=$(git -C "$capture_script_dir/.." rev-parse --show-toplevel 2>/dev/null) || { echo 'capture requires a Git worktree' >&2; exit 1; }
repository_root=$(cd "$repository_root" && /bin/pwd -P)
[[ "$(git -C "$repository_root" rev-parse HEAD)" == "$source_sha" ]] || { echo 'source SHA differs from the capture worktree Head' >&2; exit 1; }
resource_manager="$capture_script_dir/lib/ios-simulator-resource.rb"
[[ -f "$resource_manager" && ! -L "$resource_manager" ]] || { echo 'Simulator resource manager is unavailable' >&2; exit 1; }

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

simulator_session_id=${IOS_TEMPLATE_SIMULATOR_SESSION_ID:-${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}}
if [[ -z "$simulator_session_id" ]]; then
  simulator_session_id=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')
fi
[[ "$simulator_session_id" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$ ]] || { echo 'Simulator session identity is invalid' >&2; exit 1; }

for variable in requirements states app_path; do
  value=${!variable}; directory=$(cd "$(dirname "$value")" && /bin/pwd -P)
  printf -v "$variable" '%s/%s' "$directory" "$(basename "$value")"
done
output_parent=$(cd "$(dirname "$output_root")" && /bin/pwd -P)
output_root="$output_parent/$(basename "$output_root")"
[[ ! -e "$output_root" && ! -L "$output_root" ]] || { echo 'output root already exists; refusing to overwrite it' >&2; exit 1; }
staging=$(mktemp -d "$output_parent/.appstore-capture.XXXXXX")
allocation_receipt_dir="$staging/simulator-allocations"
/bin/mkdir -m 700 "$allocation_receipt_dir"
attempt_id="appstore-$$"
active_case_id=
active_allocation_id=
active_allocation_udid=
active_allocation_receipt=

run_simulator_resource() {
  /usr/bin/ruby --disable-gems "$resource_manager" "$@"
}

release_active_simulator() {
  local reason=$1 output allocation_id udid receipt
  [[ -n "$active_allocation_id" ]] || return 0
  output=$(run_simulator_resource release "${resource_test_flags[@]}" \
    --session "$simulator_session_id" --allocation-id "$active_allocation_id" \
    --reason "$reason" --receipt-dir "$allocation_receipt_dir") || return 1
  IFS=$'\t' read -r allocation_id udid receipt <<<"$output"
  [[ "$allocation_id" == "$active_allocation_id" && "$udid" == "$active_allocation_udid" && \
     "$receipt" == "$active_allocation_receipt" && -f "$receipt" ]] || return 1
  active_case_id=
  active_allocation_id=
  active_allocation_udid=
  active_allocation_receipt=
}

cleanup() {
  local status=$? cleanup_status=0
  trap - EXIT INT TERM
  if [[ -n "$active_allocation_id" ]]; then
    release_active_simulator appstore-capture-aborted || cleanup_status=1
  fi
  [[ -n "${staging:-}" && -d "$staging" ]] && rm -rf -- "$staging"
  if [[ "$cleanup_status" -ne 0 ]]; then
    echo 'App Store capture failed to release its owned Simulator; durable allocation remains for recovery' >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bounded_run appstore-simulator-inventory "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" "$xcrun_bin" simctl list -j devicetypes > "$staging/inventory.json"
REQUIREMENTS="$requirements" STATES="$states" INVENTORY="$staging/inventory.json" PLAN="$staging/plan.json" ruby <<'RUBY'
require "json"

requirements=JSON.parse(File.binread(ENV.fetch("REQUIREMENTS")))
states=JSON.parse(File.binread(ENV.fetch("STATES")))
inventory=JSON.parse(File.binread(ENV.fetch("INVENTORY")))
abort "states schemaVersion is invalid" unless states.is_a?(Hash) && states["schemaVersion"]==1
locales=states["locales"]
abort "states locales must be exactly en-US and ja" unless locales.is_a?(Array) && locales.map{|entry| entry["id"]}==%w[en-US ja]
locales.each do |entry|
  abort "locale definition is incomplete" unless entry.keys.sort==%w[appleLanguage appleLocale id].sort &&
    entry.values.all?{|value| value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]+\z/)}
end
state_entries=states["states"]
abort "at least one screenshot state is required" unless state_entries.is_a?(Array) && !state_entries.empty?
orders=state_entries.map{|entry| entry["order"]}
abort "screenshot state ordering must be contiguous" unless orders.sort==(1..orders.length).to_a && orders.uniq.length==orders.length
state_entries.each do |entry|
  abort "screenshot state is incomplete" unless entry.keys.sort==%w[id launchArguments order].sort &&
    entry["id"].is_a?(String) && entry["id"].match?(/\A[a-z0-9-]+\z/) &&
    entry["launchArguments"].is_a?(Array) && entry["launchArguments"].all?{|arg| arg.is_a?(String) && !arg.empty? && !arg.match?(/[\r\n\0]/)}
end
available=(inventory["devicetypes"].is_a?(Array) ? inventory["devicetypes"] : []).to_h{|entry| [entry["name"],entry["identifier"]]}
families=requirements.dig("screenshots","requiredFamilies")
abort "screenshot requirements are invalid" unless families.is_a?(Array) && !families.empty?
devices=families.map do |family|
  names=family["deviceTypes"]
  abort "device types are missing for #{family["id"]}" unless names.is_a?(Array) && !names.empty?
  selected=names.find{|name| available[name].is_a?(String)}
  abort "no installed Simulator device type satisfies #{family["id"]}" unless selected
  {"family"=>family.fetch("id"),"deviceType"=>selected,"deviceTypeIdentifier"=>available.fetch(selected)}
end
cases=[]
locales.each do |locale|
  devices.each do |device|
    state_entries.sort_by{|entry| entry.fetch("order")}.each do |state|
      cases << device.merge("locale"=>locale.fetch("id"),"appleLanguage"=>locale.fetch("appleLanguage"),
        "appleLocale"=>locale.fetch("appleLocale"),"state"=>state.fetch("id"),"order"=>state.fetch("order"),
        "launchArguments"=>state.fetch("launchArguments"))
    end
  end
end
File.binwrite(ENV.fetch("PLAN"),JSON.generate({"schemaVersion"=>1,"devices"=>devices,"cases"=>cases}))
RUBY

case_count=$(ruby -rjson -e 'puts JSON.parse(File.binread(ARGV.fetch(0))).fetch("cases").length' "$staging/plan.json")
group_count=$(ruby -rjson -e '
  cases=JSON.parse(File.binread(ARGV.fetch(0))).fetch("cases")
  puts cases.map{|entry| entry.values_at("locale","family")}.uniq.length
' "$staging/plan.json")
group_index=0
while [[ "$group_index" -lt "$group_count" ]]; do
  IFS=$'\t' read -r locale language apple_locale family device_type device_identifier < <(
    ruby -rjson -e '
      cases=JSON.parse(File.binread(ARGV.fetch(0))).fetch("cases")
      groups=cases.group_by{|entry| entry.values_at("locale","family")}.values.map(&:first)
      entry=groups.fetch(Integer(ARGV.fetch(1)))
      puts entry.values_at("locale","appleLanguage","appleLocale","family","deviceType","deviceTypeIdentifier").join("\t")
    ' "$staging/plan.json" "$group_index"
  )
  case "$family:$locale" in
    iphone-*:en-US) active_case_id=iphone-en ;;
    iphone-*:ja) active_case_id=iphone-ja ;;
    ipad-*:en-US) active_case_id=ipad-en ;;
    ipad-*:ja) active_case_id=ipad-ja ;;
    *) echo "unsupported App Store capture condition: $family/$locale" >&2; exit 1 ;;
  esac
  allocation_output=$(run_simulator_resource allocate "${resource_test_flags[@]}" \
    --session "$simulator_session_id" --repository "$repository_root" --issue "$issue" --head "$source_sha" \
    --batch "$batch_id" --attempt "$attempt_id" --case "$active_case_id" --runtime "$runtime" \
    --device-type "$device_identifier" --owner-pid "$$" --wait-seconds 60 \
    --receipt-dir "$allocation_receipt_dir")
  IFS=$'\t' read -r active_allocation_id active_allocation_udid active_allocation_receipt <<<"$allocation_output"
  allocation_receipt_dir_physical=$(cd "$allocation_receipt_dir" && /bin/pwd -P)
  [[ "$active_allocation_id" =~ ^[0-9a-f-]{36}$ && "$active_allocation_udid" =~ ^[0-9A-Fa-f-]+$ && \
     "$active_allocation_receipt" == "$allocation_receipt_dir_physical/allocation-$active_allocation_id.json" && \
     -f "$active_allocation_receipt" ]] || { echo 'Simulator allocation receipt is invalid' >&2; exit 1; }

  bounded_run appstore-simulator-boot "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" "$xcrun_bin" simctl boot "$active_allocation_udid"
  bounded_run appstore-simulator-bootstatus "${IOS_TEMPLATE_SIMULATOR_BOOT_TIMEOUT_SECONDS:-300}" "$xcrun_bin" simctl bootstatus "$active_allocation_udid" -b
  bounded_run appstore-status-bar "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" "$xcrun_bin" simctl status_bar "$active_allocation_udid" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100

  state_count=$(ruby -rjson -e '
    cases=JSON.parse(File.binread(ARGV.fetch(0))).fetch("cases")
    puts cases.count{|entry| entry["locale"]==ARGV.fetch(1) && entry["family"]==ARGV.fetch(2)}
  ' "$staging/plan.json" "$locale" "$family")
  state_index=0
  while [[ "$state_index" -lt "$state_count" ]]; do
    IFS=$'\t' read -r state order < <(
      ruby -rjson -e '
        cases=JSON.parse(File.binread(ARGV.fetch(0))).fetch("cases").select{|entry| entry["locale"]==ARGV.fetch(1) && entry["family"]==ARGV.fetch(2)}
        entry=cases.fetch(Integer(ARGV.fetch(3))); puts entry.values_at("state","order").join("\t")
      ' "$staging/plan.json" "$locale" "$family" "$state_index"
    )
    launch_arguments=()
    while IFS= read -r argument; do launch_arguments+=("$argument"); done < <(
      ruby -rjson -e '
        cases=JSON.parse(File.binread(ARGV.fetch(0))).fetch("cases").select{|entry| entry["locale"]==ARGV.fetch(1) && entry["family"]==ARGV.fetch(2)}
        cases.fetch(Integer(ARGV.fetch(3))).fetch("launchArguments").each{|arg| puts arg}
      ' "$staging/plan.json" "$locale" "$family" "$state_index"
    )
    destination_directory="$staging/$locale/$family"
    mkdir -p "$destination_directory"
    destination="$destination_directory/$(printf '%02d' "$order")-$state.png"
    bounded_run appstore-simulator-install "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" "$xcrun_bin" simctl install "$active_allocation_udid" "$app_path"
    bounded_run appstore-simulator-launch "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" "$xcrun_bin" simctl launch --terminate-running-process "$active_allocation_udid" "$bundle_id" \
      -AppleLanguages "($language)" -AppleLocale "$apple_locale" -AppleInterfaceStyle Light \
      --disable-animations --fixed-date 2026-01-01T09:41:00Z "${launch_arguments[@]}"
    bounded_run appstore-screenshot "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" "$xcrun_bin" simctl io "$active_allocation_udid" screenshot --type=png "$destination"
    bounded_run appstore-simulator-terminate "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" "$xcrun_bin" simctl terminate "$active_allocation_udid" "$bundle_id"
    bounded_run appstore-simulator-uninstall "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" "$xcrun_bin" simctl uninstall "$active_allocation_udid" "$bundle_id"
    state_index=$((state_index+1))
  done

  bounded_run appstore-status-bar-clear "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" "$xcrun_bin" simctl status_bar "$active_allocation_udid" clear
  bounded_run appstore-simulator-shutdown "${IOS_TEMPLATE_SIMCTL_TIMEOUT_SECONDS:-180}" "$xcrun_bin" simctl shutdown "$active_allocation_udid"
  release_active_simulator appstore-capture-complete || { echo 'owned Simulator release failed' >&2; exit 1; }
  group_index=$((group_index+1))
done

PLAN="$staging/plan.json" ROOT="$staging" REQUIREMENTS="$requirements" SOURCE_SHA="$source_sha" \
BUILD_DIGEST="$build_digest" RUNTIME="$runtime" ruby <<'RUBY'
require "json"
require "digest"

root=ENV.fetch("ROOT")
plan=JSON.parse(File.binread(ENV.fetch("PLAN")))
requirements=JSON.parse(File.binread(ENV.fetch("REQUIREMENTS")))
families=requirements.dig("screenshots","requiredFamilies").to_h{|entry| [entry.fetch("id"),entry]}
png_info=lambda do |path|
  data=File.binread(path); abort "captured file is not a PNG" unless data.start_with?("\x89PNG\r\n\x1a\n".b)
  offset=8; width=height=color_type=nil; alpha=false
  while offset+12<=data.bytesize
    length=data.byteslice(offset,4).unpack1("N"); type=data.byteslice(offset+4,4); payload=data.byteslice(offset+8,length)
    abort "captured PNG is truncated" unless payload && offset+12+length<=data.bytesize
    if type=="IHDR"
      width,height,bit_depth,color_type,compression,filter,interlace=payload.unpack("NNC5")
      abort "captured PNG format is unsupported" unless bit_depth==8 && [2,6].include?(color_type) && compression==0 && filter==0 && interlace==0
      alpha ||= color_type==6
    elsif type=="tRNS" then alpha=true
    elsif type=="IEND" then break
    end
    offset += 12+length
  end
  abort "captured PNG lacks dimensions" unless width && height
  [width,height,alpha,"sha256:#{Digest::SHA256.hexdigest(data)}"]
end
cases=plan.fetch("cases").map do |entry|
  relative="#{entry.fetch("locale")}/#{entry.fetch("family")}/#{format('%02d',entry.fetch("order"))}-#{entry.fetch("state")}.png"
  absolute=File.join(root,relative); stat=File.lstat(absolute)
  abort "capture is not a regular file" unless stat.file? && !stat.symlink?
  width,height,alpha,digest=png_info.call(absolute)
  family=families.fetch(entry.fetch("family")); allowed=family.fetch("portraitSizes")+family.fetch("landscapeSizes")
  abort "capture dimensions do not satisfy #{entry.fetch("family")}" unless allowed.include?([width,height])
  abort "capture contains a forbidden alpha channel" if requirements.dig("screenshots","allowAlpha")==false && alpha
  {"locale"=>entry.fetch("locale"),"family"=>entry.fetch("family"),"state"=>entry.fetch("state"),"order"=>entry.fetch("order"),
    "path"=>relative,"sourceSha"=>ENV.fetch("SOURCE_SHA"),"buildDigest"=>ENV.fetch("BUILD_DIGEST"),
    "runtime"=>ENV.fetch("RUNTIME"),"deviceType"=>entry.fetch("deviceType"),"width"=>width,"height"=>height,"digest"=>digest}
end
manifest={"schemaVersion"=>1,"sourceSha"=>ENV.fetch("SOURCE_SHA"),"buildDigest"=>ENV.fetch("BUILD_DIGEST"),
  "runtime"=>ENV.fetch("RUNTIME"),"requirementsDigest"=>"sha256:#{Digest::SHA256.file(ENV.fetch("REQUIREMENTS")).hexdigest}","cases"=>cases}
File.binwrite(File.join(root,"manifest.json"),JSON.generate(manifest))
File.chmod(0644,File.join(root,"manifest.json"))
RUBY

rm -f -- "$staging/inventory.json" "$staging/plan.json"
/bin/mv "$staging" "$output_root"
staging=
trap - EXIT INT TERM
printf '{"cases":%s,"status":"captured"}\n' "$case_count"
