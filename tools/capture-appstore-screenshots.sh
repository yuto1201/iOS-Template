#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: $0 --requirements FILE --states FILE --app-path APP --bundle-id ID --source-sha SHA --build-digest sha256:HEX --runtime ID --output-root DIR" >&2
  exit 64
}

requirements= states= app_path= bundle_id= source_sha= build_digest= runtime= output_root=
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
    *) usage ;;
  esac
done
[[ -n "$requirements" && -n "$states" && -n "$app_path" && -n "$bundle_id" && -n "$source_sha" && -n "$build_digest" && -n "$runtime" && -n "$output_root" ]] || usage
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'source SHA must be a full lowercase Git SHA' >&2; exit 1; }
[[ "$build_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'build digest is invalid' >&2; exit 1; }
[[ "$bundle_id" =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9-]+)+$ ]] || { echo 'bundle identifier is invalid' >&2; exit 1; }
[[ "$runtime" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'runtime identifier is invalid' >&2; exit 1; }
for file in "$requirements" "$states"; do
  [[ -f "$file" && ! -L "$file" ]] || { echo "input must be a regular non-symbolic-link file: $(basename "$file")" >&2; exit 1; }
done
[[ -d "$app_path" && ! -L "$app_path" ]] || { echo 'app path must be a non-symbolic-link directory' >&2; exit 1; }
xcrun_bin=$(command -v xcrun) || { echo 'xcrun is unavailable' >&2; exit 1; }

for variable in requirements states app_path; do
  value=${!variable}; directory=$(cd "$(dirname "$value")" && /bin/pwd -P)
  printf -v "$variable" '%s/%s' "$directory" "$(basename "$value")"
done
output_parent=$(cd "$(dirname "$output_root")" && /bin/pwd -P)
output_root="$output_parent/$(basename "$output_root")"
[[ ! -e "$output_root" && ! -L "$output_root" ]] || { echo 'output root already exists; refusing to overwrite it' >&2; exit 1; }
staging=$(mktemp -d "$output_parent/.appstore-capture.XXXXXX")
created_devices=()
cleanup() {
  local udid
  for udid in "${created_devices[@]}"; do
    "$xcrun_bin" simctl shutdown "$udid" >/dev/null 2>&1 || true
    "$xcrun_bin" simctl delete "$udid" >/dev/null 2>&1 || true
  done
  [[ -n "${staging:-}" && -d "$staging" ]] && rm -rf -- "$staging"
  return 0
}
trap cleanup EXIT INT TERM

"$xcrun_bin" simctl list -j devicetypes > "$staging/inventory.json"
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

device_map="$staging/devices.tsv"
: > "$device_map"
while IFS=$'\t' read -r family device_type device_identifier; do
  [[ -n "$family" && -n "$device_type" && -n "$device_identifier" ]] || { echo 'release device plan is incomplete' >&2; exit 1; }
  name="iOS-Template-AppStore-${family}-$$"
  udid=$("$xcrun_bin" simctl create "$name" "$device_identifier" "$runtime")
  [[ "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]] || { echo "simctl returned an invalid UDID for $family" >&2; exit 1; }
  created_devices+=("$udid")
  printf '%s\t%s\t%s\n' "$family" "$udid" "$device_type" >> "$device_map"
done < <(ruby -rjson -e 'JSON.parse(File.binread(ARGV.fetch(0))).fetch("devices").each{|entry| puts entry.values_at("family","deviceType","deviceTypeIdentifier").join("\t")}' "$staging/plan.json")

case_count=$(ruby -rjson -e 'puts JSON.parse(File.binread(ARGV.fetch(0))).fetch("cases").length' "$staging/plan.json")
index=0
while [[ "$index" -lt "$case_count" ]]; do
  IFS=$'\t' read -r locale language apple_locale family state order device_type < <(
    ruby -rjson -e 'entry=JSON.parse(File.binread(ARGV.fetch(0))).fetch("cases").fetch(Integer(ARGV.fetch(1))); puts entry.values_at("locale","appleLanguage","appleLocale","family","state","order","deviceType").join("\t")' "$staging/plan.json" "$index"
  )
  udid=$(/usr/bin/awk -F '\t' -v family="$family" '$1==family {print $2}' "$device_map")
  [[ -n "$udid" ]] || { echo "release Simulator is unavailable for $family" >&2; exit 1; }
  launch_arguments=()
  while IFS= read -r argument; do launch_arguments+=("$argument"); done < <(
    ruby -rjson -e 'JSON.parse(File.binread(ARGV.fetch(0))).fetch("cases").fetch(Integer(ARGV.fetch(1))).fetch("launchArguments").each{|arg| puts arg}' "$staging/plan.json" "$index"
  )
  destination_directory="$staging/$locale/$family"
  mkdir -p "$destination_directory"
  destination="$destination_directory/$(printf '%02d' "$order")-$state.png"
  "$xcrun_bin" simctl boot "$udid"
  "$xcrun_bin" simctl bootstatus "$udid" -b
  "$xcrun_bin" simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100
  "$xcrun_bin" simctl install "$udid" "$app_path"
  "$xcrun_bin" simctl launch --terminate-running-process "$udid" "$bundle_id" \
    -AppleLanguages "($language)" -AppleLocale "$apple_locale" -AppleInterfaceStyle Light \
    --disable-animations --fixed-date 2026-01-01T09:41:00Z "${launch_arguments[@]}"
  "$xcrun_bin" simctl io "$udid" screenshot --type=png "$destination"
  "$xcrun_bin" simctl terminate "$udid" "$bundle_id"
  "$xcrun_bin" simctl status_bar "$udid" clear
  "$xcrun_bin" simctl shutdown "$udid"
  "$xcrun_bin" simctl erase "$udid"
  index=$((index+1))
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

rm -f -- "$staging/inventory.json" "$staging/plan.json" "$staging/devices.tsv"
/bin/mv "$staging" "$output_root"
staging=
cleanup
created_devices=()
trap - EXIT INT TERM
printf '{"cases":%s,"status":"captured"}\n' "$case_count"
