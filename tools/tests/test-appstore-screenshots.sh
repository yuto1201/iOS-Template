#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg ruby /usr/bin/xcrun

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-appstore-screenshots.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT

builder="$repo_root/tools/build-appstore-screenshot-set.sh"
capture="$repo_root/tools/capture-appstore-screenshots.sh"
requirements="$workspace/requirements.json"
states="$repo_root/App Store/screenshots/states.json"
raw="$workspace/raw"
final="$workspace/final"
review="$workspace/review.json"
source_sha=$(git -C "$repo_root" rev-parse HEAD)
runtime=com.apple.CoreSimulator.SimRuntime.iOS-26-5
build_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

/bin/cp "$repo_root/tools/tests/fixtures/appstore/requirements.json" "$requirements"
ruby -rjson -e '
  path=ARGV.fetch(0); value=JSON.parse(File.binread(path))
  family=value.fetch("screenshots").fetch("requiredFamilies").find{|entry| entry.fetch("id")=="iphone-6.3"}
  family["deviceTypes"]=["iPhone 17 Pro"]
  File.binwrite(path,JSON.generate(value))
' "$requirements"

write_png() {
  local path=$1 width=$2 height=$3 color_type=$4 seed=$5 alpha=${6:-255}
  mkdir -p "$(dirname "$path")"
  ruby -rzlib -e '
    path,width,height,color_type,seed,alpha=ARGV
    width=Integer(width); height=Integer(height); color_type=Integer(color_type); seed=Integer(seed)
    channels=color_type==6 ? 4 : 3
    pixel=[seed%251,(seed*3)%251,(seed*7)%251,Integer(alpha)].take(channels).pack("C*")
    raw=("\x00" + pixel*width)*height
    chunk=lambda do |type,data|
      type=type.b; [data.bytesize].pack("N")+type+data+[Zlib.crc32(type+data)].pack("N")
    end
    png="\x89PNG\r\n\x1a\n".b
    png << chunk.call("IHDR",[width,height,8,color_type,0,0,0].pack("NNC5"))
    png << chunk.call("IDAT",Zlib::Deflate.deflate(raw,9))
    png << chunk.call("IEND","".b)
    File.binwrite(path,png)
  ' "$path" "$width" "$height" "$color_type" "$seed" "$alpha"
}

write_valid_fixture() {
  rm -rf -- "$raw" "$final"
  mkdir -p "$raw/en-US/iphone-6.3" "$raw/en-US/ipad-13" "$raw/ja/iphone-6.3" "$raw/ja/ipad-13"
  write_png "$raw/en-US/iphone-6.3/01-primary.png" 1206 2622 2 11
  write_png "$raw/ja/iphone-6.3/01-primary.png" 1206 2622 2 12
  write_png "$raw/en-US/ipad-13/01-primary.png" 2064 2752 2 21
  write_png "$raw/ja/ipad-13/01-primary.png" 2064 2752 2 22
  RAW="$raw" REVIEW="$review" REQUIREMENTS="$requirements" SOURCE_SHA="$source_sha" RUNTIME="$runtime" BUILD_DIGEST="$build_digest" ruby -rjson -rdigest -e '
    raw=ENV.fetch("RAW")
    definitions=[
      ["en-US","iphone-6.3","iPhone 17 Pro",1206,2622],
      ["ja","iphone-6.3","iPhone 17 Pro",1206,2622],
      ["en-US","ipad-13","iPad Air (M4)",2064,2752],
      ["ja","ipad-13","iPad Air (M4)",2064,2752]
    ]
    cases=definitions.map do |locale,family,device,width,height|
      relative="#{locale}/#{family}/01-primary.png"; digest="sha256:#{Digest::SHA256.file(File.join(raw,relative)).hexdigest}"
      {"locale"=>locale,"family"=>family,"state"=>"primary","order"=>1,"path"=>relative,
       "sourceSha"=>ENV.fetch("SOURCE_SHA"),"buildDigest"=>ENV.fetch("BUILD_DIGEST"),
       "runtime"=>ENV.fetch("RUNTIME"),"deviceType"=>device,"width"=>width,"height"=>height,"digest"=>digest}
    end
    manifest={"schemaVersion"=>1,"sourceSha"=>ENV.fetch("SOURCE_SHA"),"buildDigest"=>ENV.fetch("BUILD_DIGEST"),
      "runtime"=>ENV.fetch("RUNTIME"),"requirementsDigest"=>"sha256:#{Digest::SHA256.file(ENV.fetch("REQUIREMENTS")).hexdigest}","cases"=>cases}
    File.binwrite(File.join(raw,"manifest.json"),JSON.generate(manifest))
    checks=cases.map{|entry| {"locale"=>entry["locale"],"family"=>entry["family"],"state"=>entry["state"],
      "path"=>entry["path"],"digest"=>entry["digest"],"safeArea"=>"passed","textClipping"=>"passed",
      "truthfulRepresentation"=>"passed","localeParity"=>"passed"}}
    review={"schemaVersion"=>1,"sourceSha"=>ENV.fetch("SOURCE_SHA"),"buildDigest"=>ENV.fetch("BUILD_DIGEST"),
      "visualReviewStatus"=>"passed","releaseAuditor"=>{"status"=>"approved","model"=>"release-auditor"},"cases"=>checks}
    File.binwrite(ENV.fetch("REVIEW"),JSON.generate(review))
  '
}

refresh_digests() {
  RAW="$raw" REVIEW="$review" ruby -rjson -rdigest -e '
    manifest_path=File.join(ENV.fetch("RAW"),"manifest.json"); manifest=JSON.parse(File.binread(manifest_path))
    review=JSON.parse(File.binread(ENV.fetch("REVIEW")))
    manifest.fetch("cases").each do |entry|
      digest="sha256:#{Digest::SHA256.file(File.join(ENV.fetch("RAW"),entry.fetch("path"))).hexdigest}"
      entry["digest"]=digest
      check=review.fetch("cases").find{|candidate| candidate.values_at("locale","family","state")==entry.values_at("locale","family","state")}
      check["digest"]=digest if check
    end
    File.binwrite(manifest_path,JSON.generate(manifest)); File.binwrite(ENV.fetch("REVIEW"),JSON.generate(review))
  '
}

build_set() {
  "$builder" --raw-root "$raw" --output-root "$final" --requirements "$requirements" \
    --review "$review" --source-sha "$source_sha" --runtime "$runtime" --build-digest "$build_digest"
}

assert_failure() {
  local label=$1 expected=$2
  rm -rf -- "$final"
  set +e
  output=$(build_set 2>&1)
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *"$expected"* ]] || {
    echo "expected screenshot failure: $label: $output" >&2
    exit 1
  }
}

write_valid_fixture
result=$(build_set)
[[ "$result" == *'"status":"ready"'* ]] || { echo "valid screenshot set failed: $result" >&2; exit 1; }
[[ -f "$final/en-US/iphone-6.3/01-primary.png" && -f "$final/ja/ipad-13/01-primary.png" && -f "$final/manifest.json" ]] || {
  echo 'final screenshot set is incomplete' >&2; exit 1
}

write_valid_fixture
write_png "$raw/en-US/iphone-6.3/01-primary.png" 1170 2532 2 31
refresh_digests
assert_failure 'wrong dimensions' 'dimensions'

# D-079: the iPhone family is Dynamic Island (medium display). A consistent iPhone 6.9-inch image
# (1320x2868, the former dedicated iPhone 17 Pro Max size) is refused by the family sizes alone.
write_valid_fixture
ruby -rjson -e 'p=ARGV.fetch(0); v=JSON.parse(File.binread(p)); v["cases"].find{|e| e["locale"]=="en-US" && e["family"]=="iphone-6.3"}.merge!("width"=>1320,"height"=>2868); File.binwrite(p,JSON.generate(v))' "$raw/manifest.json"
write_png "$raw/en-US/iphone-6.3/01-primary.png" 1320 2868 2 33
refresh_digests
assert_failure 'iPhone 6.9-inch dimensions' 'en-US/iphone-6.3/01-primary.png:dimensions-not-allowed'

write_valid_fixture
write_png "$raw/en-US/iphone-6.3/01-primary.png" 1206 2622 6 32
refresh_digests
assert_failure 'alpha channel' 'alpha'

write_valid_fixture
/bin/cp "$raw/en-US/iphone-6.3/01-primary.png" "$raw/ja/iphone-6.3/01-primary.png"
refresh_digests
assert_failure 'duplicate bytes' 'duplicate'

write_valid_fixture
ruby -rjson -e 'p=ARGV.fetch(0); v=JSON.parse(File.binread(p)); v["cases"].reject!{|e| e["locale"]=="ja"}; File.binwrite(p,JSON.generate(v))' "$raw/manifest.json"
assert_failure 'missing locale' 'missing ja'

write_valid_fixture
ruby -rjson -e 'p=ARGV.fetch(0); v=JSON.parse(File.binread(p)); v["cases"].find{|e| e["locale"]=="en-US" && e["family"]=="iphone-6.3"}["order"]=2; File.binwrite(p,JSON.generate(v))' "$raw/manifest.json"
assert_failure 'non-contiguous ordering' 'order'

write_valid_fixture
ruby -rjson -e 'p=ARGV.fetch(0); v=JSON.parse(File.binread(p)); v["cases"].first.delete("deviceType"); File.binwrite(p,JSON.generate(v))' "$raw/manifest.json"
assert_failure 'incomplete manifest' 'deviceType'

write_valid_fixture
ruby -rjson -e 'p=ARGV.fetch(0); v=JSON.parse(File.binread(p)); v["cases"].first["safeArea"]="failed"; File.binwrite(p,JSON.generate(v))' "$review"
assert_failure 'safe area clipping' 'safeArea'

write_valid_fixture
ruby -rjson -e 'p=ARGV.fetch(0); v=JSON.parse(File.binread(p)); v["cases"].find{|e| e["family"]=="iphone-6.3"}["deviceType"]="iPhone 17 Pro Max"; File.binwrite(p,JSON.generate(v))' "$raw/manifest.json"
assert_failure 'iPhone 17 Pro Max capture outside the family' 'deviceType'

# D-063/D-079: capture leases only the dedicated Simulator that Config/dedicated-simulators.json
# declares for each platform and records the Apple model name of its family. The unmodified fixture
# lists iPhone 18 Pro and iPad Air (M4) first and a user-owned iPhone 18 Pro is installed, so selecting
# by the requirements order would capture on another device.
dedicated_config="$repo_root/Config/dedicated-simulators.json"
capture_runtime=$(jq -er '.devices[0].runtimeIdentifier' "$dedicated_config")
iphone_name=$(jq -er '.devices[] | select(.family == "iphone") | .name' "$dedicated_config")
ipad_name=$(jq -er '.devices[] | select(.family == "ipad") | .name' "$dedicated_config")
iphone_type=$(jq -er '.devices[] | select(.family == "iphone") | .deviceTypeIdentifier' "$dedicated_config")
ipad_type=$(jq -er '.devices[] | select(.family == "ipad") | .deviceTypeIdentifier' "$dedicated_config")
capture_requirements="$workspace/capture-requirements.json"
/bin/cp "$repo_root/tools/tests/fixtures/appstore/requirements.json" "$capture_requirements"
fake_bin="$workspace/fake-bin"; mkdir -p "$fake_bin"
# Each locale/family gets distinct bytes because the set builder rejects duplicate images.
# Like real simctl captures, they are opaque RGBA PNGs (color type 6).
fake_pngs="$workspace/fake-png"
write_png "$fake_pngs/en-US-iphone-6.3.png" 1206 2622 6 77
write_png "$fake_pngs/ja-iphone-6.3.png" 1206 2622 6 78
write_png "$fake_pngs/en-US-ipad-13.png" 2064 2752 6 79
write_png "$fake_pngs/ja-ipad-13.png" 2064 2752 6 80
# A Simulator that still renders the former iPhone 17 Pro Max size (1320x2868) must not pass capture.
old_size_pngs="$workspace/fake-png-old-size"
write_png "$old_size_pngs/en-US-iphone-6.3.png" 1320 2868 6 87
write_png "$old_size_pngs/ja-iphone-6.3.png" 1320 2868 6 88
/bin/cp "$fake_pngs/en-US-ipad-13.png" "$fake_pngs/ja-ipad-13.png" "$old_size_pngs/"
# #168: one translucent capture must stop the whole run instead of being blended.
translucent_pngs="$workspace/translucent-png"
/bin/mkdir -p "$translucent_pngs"
/bin/cp "$fake_pngs"/*.png "$translucent_pngs/"
write_png "$translucent_pngs/ja-ipad-13.png" 2064 2752 6 80 254
fake_log="$workspace/xcrun.log"
fake_state="$workspace/simctl-state.json"
resource_state="$workspace/resource-state"
user_udid=00000000-0000-0000-0000-000000000003
ruby -rjson -e '
  runtime, iphone_name, iphone_type, ipad_name, ipad_type, user_udid = ARGV
  device = lambda do |udid, name, type|
    {"udid" => udid, "name" => name, "state" => "Shutdown", "isAvailable" => true, "deviceTypeIdentifier" => type}
  end
  puts JSON.generate("devices" => {runtime => [
    device.call("00000000-0000-0000-0000-000000000001", iphone_name, iphone_type),
    device.call("00000000-0000-0000-0000-000000000002", ipad_name, ipad_type),
    device.call(user_udid, "iPhone 18 Pro", "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro")
  ]})
' "$capture_runtime" "$iphone_name" "$iphone_type" "$ipad_name" "$ipad_type" "$user_udid" > "$fake_state"
cat > "$fake_bin/xcrun" <<'RUBY'
#!/usr/bin/ruby --disable-gems
require "fileutils"
require "json"

state_path = ENV.fetch("FAKE_SIMCTL_STATE")
File.open(ENV.fetch("FAKE_XCRUN_LOG"), "a", 0o600) { |file| file.puts(ARGV.join(" ")) }
abort "expected simctl" unless ARGV.shift == "simctl"
command = ARGV.shift

lock = File.open(state_path + ".lock", File::RDWR | File::CREAT, 0o600)
lock.flock(File::LOCK_EX)
begin
  state = JSON.parse(File.binread(state_path))
  devices = state.fetch("devices").values.flatten
  target = lambda { devices.find { |entry| entry.fetch("udid") == ARGV.fetch(0) } or abort "missing #{command} target" }
  case command
  when "list"
    case ARGV
    when %w[-j devicetypes]
      puts JSON.generate("devicetypes" => [
        {"name" => "iPhone 18 Pro", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"},
        {"name" => "iPhone 17 Pro", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
        {"name" => "iPhone 17 Pro Max", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"},
        {"name" => "iPad Air 13-inch (M4)", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M4"},
        {"name" => "iPad Pro 13-inch (M5)", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"}
      ])
    when %w[devices -j]
      puts JSON.generate("devices" => state.fetch("devices"))
    else
      abort "unexpected list arguments"
    end
  when "boot"
    device = target.call
    device["state"] = "Booted"
    # #173: a restart that loses the written system language must not pass the readback.
    device.delete("preferences") if ENV["FAKE_LOCALE_FAILURE"] == "lost-on-restart"
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
      abort "configured system language write failure" if ENV["FAKE_LOCALE_FAILURE"] == "write"
      preferences["AppleLanguages"] = [arguments.last]
    elsif arguments.length == 6 && arguments.first(5) == %w[defaults write -g AppleLocale -string]
      preferences["AppleLocale"] = arguments.last
    elsif arguments == %w[defaults export -g -]
      abort "configured system language readback failure" if ENV["FAKE_LOCALE_FAILURE"] == "read"
      entries = preferences.map do |key, value|
        rendered = value.is_a?(Array) ? "<array>#{value.map { |item| "<string>#{item}</string>" }.join}</array>" : "<string>#{value}</string>"
        "<key>#{key}</key>#{rendered}"
      end
      puts %(<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>#{entries.join}</dict></plist>)
    else
      abort "unexpected spawn arguments"
    end
    File.binwrite(state_path, JSON.generate(state))
  when "bootstatus"
    # #173: the restart after the system language write is the bootstatus that follows a written preference.
    abort "configured restart failure" if ENV["FAKE_LOCALE_FAILURE"] == "restart" && target.call["preferences"]
  when "io"
    abort "configured screenshot failure" if ENV["FAKE_FAIL_SCREENSHOT"] == "1"
    destination = ARGV.fetch(-1)
    FileUtils.cp(File.join(ENV.fetch("FAKE_PNG_DIR"), destination.split("/")[-3, 2].join("-") + ".png"), destination)
  when "status_bar", "install", "launch", "terminate", "uninstall"
    # Deterministic no-op fixture commands.
  else
    abort "unexpected simctl command #{command}"
  end
ensure
  lock.flock(File::LOCK_UN)
  lock.close
end
RUBY
chmod +x "$fake_bin/xcrun"
mkdir -p "$workspace/Fake.app"

run_capture() {
  local session=$1 output=$2 requirements_file=$3 runtime_id=$4
  shift 4
  env FAKE_XCRUN_LOG="$fake_log" FAKE_SIMCTL_STATE="$fake_state" FAKE_PNG_DIR="$fake_pngs" IOS_TEMPLATE_APPSTORE_SETTLE_SECONDS=0 "$@" \
    IOS_TEMPLATE_SIMULATOR_SESSION_ID="$session" IOS_TEMPLATE_SIMULATOR_RESOURCE_TEST_MODE=1 \
    IOS_TEMPLATE_SIMULATOR_RESOURCE_STATE_ROOT="$resource_state" IOS_TEMPLATE_APPSTORE_XCRUN="$fake_bin/xcrun" \
    "$capture" --requirements "$requirements_file" --states "$states" --app-path "$workspace/Fake.app" \
    --bundle-id com.yuto.TemplateApp --source-sha "$source_sha" --build-digest "$build_digest" \
    --runtime "$runtime_id" --output-root "$output" --issue 88 --batch-id appstore-test \
    >"$workspace/capture.out" 2>"$workspace/capture.err"
}

assert_dedicated_devices_intact() {
  ruby -rjson -e '
    devices = JSON.parse(File.binread(ARGV.fetch(0))).fetch("devices").values.flatten
    abort "capture changed the installed Simulators" unless devices.length == 3 && devices.all? { |entry| entry["state"] == "Shutdown" }
  ' "$fake_state" || exit 1
  ! rg -q '^simctl (create|clone|rename|delete) ' "$fake_log" || { echo 'capture created or deleted a Simulator' >&2; exit 1; }
  ! rg -qF "$user_udid" "$fake_log" || { echo 'capture used a Simulator outside the dedicated declaration' >&2; exit 1; }
}

assert_capture_blocked() {
  local label=$1 expected=$2 requirements_file=$3 runtime_id=$4 output="$workspace/blocked-capture"
  : > "$fake_log"
  if run_capture "appstore-blocked-session" "$output" "$requirements_file" "$runtime_id"; then
    echo "expected blocked capture: $label" >&2; exit 1
  fi
  [[ ! -e "$output" ]] || { echo "blocked capture published output: $label" >&2; exit 1; }
  grep -Fq "blocked:environment: $expected" "$workspace/capture.err" || {
    echo "blocked capture failed for another reason: $label: $(<"$workspace/capture.err")" >&2; exit 1
  }
  ! rg -qv '^simctl list -j devicetypes$' "$fake_log" || { echo "blocked capture changed a Simulator: $label" >&2; exit 1; }
}

assert_capture_blocked 'Runtime outside the declaration' '--runtime differs from the dedicated iphone Simulator declaration' \
  "$capture_requirements" "$runtime"
ipad_air_only="$workspace/ipad-air-requirements.json"
ruby -rjson -e '
  value = JSON.parse(File.binread(ARGV.fetch(0)))
  value.fetch("screenshots").fetch("requiredFamilies").find { |entry| entry.fetch("id") == "ipad-13" }["deviceTypes"] = ["iPad Air (M4)"]
  File.binwrite(ARGV.fetch(1), JSON.generate(value))
' "$capture_requirements" "$ipad_air_only"
assert_capture_blocked 'dedicated device outside the family' \
  'the dedicated ipad Simulator (iPad Pro 13-inch (M5)) is not a ipad-13 App Store device type' "$ipad_air_only" "$capture_runtime"
# D-079: requirements that still name the former iPhone 6.9-inch family stop before any Simulator change,
# because the dedicated iPhone 17 Pro is not one of its Apple models.
former_iphone_family="$workspace/iphone-6.9-requirements.json"
ruby -rjson -e '
  value = JSON.parse(File.binread(ARGV.fetch(0)))
  families = value.fetch("screenshots").fetch("requiredFamilies")
  index = families.index { |entry| entry.fetch("id") == "iphone-6.3" } or abort "iphone-6.3 family is missing"
  families[index] = {"id" => "iphone-6.9", "platform" => "iphone",
    "deviceTypes" => ["iPhone Air", "iPhone 17 Pro Max", "iPhone 16 Pro Max"],
    "portraitSizes" => [[1260, 2736], [1290, 2796], [1320, 2868]],
    "landscapeSizes" => [[2736, 1260], [2796, 1290], [2868, 1320]]}
  File.binwrite(ARGV.fetch(1), JSON.generate(value))
' "$capture_requirements" "$former_iphone_family"
assert_capture_blocked 'former iPhone 6.9-inch family' \
  'the dedicated iphone Simulator (iPhone 17 Pro) is not a iphone-6.9 App Store device type' "$former_iphone_family" "$capture_runtime"
assert_dedicated_devices_intact

# D-079: a capture at the former iPhone 17 Pro Max size (1320x2868) does not satisfy iphone-6.3, publishes
# nothing, and still releases every lease.
: > "$fake_log"
old_size_root="$workspace/capture-old-size"
if run_capture appstore-old-size-session "$old_size_root" "$capture_requirements" "$capture_runtime" FAKE_PNG_DIR="$old_size_pngs"; then
  echo 'capture accepted a 1320x2868 iPhone image' >&2; exit 1
fi
[[ ! -e "$old_size_root" ]] || { echo 'capture with the former iPhone size published output' >&2; exit 1; }
grep -Fq 'capture dimensions do not satisfy iphone-6.3' "$workspace/capture.err" || {
  echo "1320x2868 capture failed for another reason: $(<"$workspace/capture.err")" >&2; exit 1
}
assert_dedicated_devices_intact

# A capture failure releases the exact lease and leaves the dedicated device shut down.
: > "$fake_log"
failure_root="$workspace/capture-failure"
if run_capture appstore-failure-session "$failure_root" "$capture_requirements" "$capture_runtime" FAKE_FAIL_SCREENSHOT=1; then
  echo 'capture succeeded after a screenshot failure' >&2; exit 1
fi
[[ ! -e "$failure_root" ]] || { echo 'failed capture published output' >&2; exit 1; }
assert_dedicated_devices_intact

# #168: an invalid settle time stops before any Simulator is touched.
for settle in 121 abc -1; do
  : > "$fake_log"
  if run_capture appstore-settle-session "$workspace/settle-capture" "$capture_requirements" "$capture_runtime" \
    IOS_TEMPLATE_APPSTORE_SETTLE_SECONDS="$settle"; then
    echo "capture accepted settle time $settle" >&2; exit 1
  fi
  grep -Fq 'IOS_TEMPLATE_APPSTORE_SETTLE_SECONDS must be an integer from 0 to 120' "$workspace/capture.err" || {
    echo "invalid settle time $settle failed for another reason: $(<"$workspace/capture.err")" >&2; exit 1
  }
  [[ ! -s "$fake_log" && ! -e "$workspace/settle-capture" ]] || { echo "invalid settle time $settle touched a Simulator" >&2; exit 1; }
done

# #168: a translucent pixel fails the capture instead of being blended, and nothing is published.
: > "$fake_log"
translucent_root="$workspace/translucent-capture"
if run_capture appstore-translucent-session "$translucent_root" "$capture_requirements" "$capture_runtime" \
  FAKE_PNG_DIR="$translucent_pngs"; then
  echo 'capture accepted a translucent screenshot' >&2; exit 1
fi
grep -Fq 'capture contains a pixel that is not fully opaque' "$workspace/capture.err" || {
  echo "translucent capture failed for another reason: $(<"$workspace/capture.err")" >&2; exit 1
}
[[ ! -e "$translucent_root" ]] || { echo 'translucent capture published output' >&2; exit 1; }
assert_dedicated_devices_intact

# #173: a failed write, restart, or readback, or a readback that differs, publishes nothing.
for locale_failure in write restart read lost-on-restart; do
  : > "$fake_log"
  locale_failure_root="$workspace/locale-$locale_failure-capture"
  if run_capture "appstore-locale-$locale_failure-session" "$locale_failure_root" "$capture_requirements" "$capture_runtime" \
    FAKE_LOCALE_FAILURE="$locale_failure"; then
    echo "capture succeeded after a system language $locale_failure failure" >&2; exit 1
  fi
  [[ ! -e "$locale_failure_root" ]] || { echo "system language $locale_failure failure published output" >&2; exit 1; }
  ! rg -q '^simctl (launch|io) ' "$fake_log" || { echo "system language $locale_failure failure still captured the app" >&2; exit 1; }
  assert_dedicated_devices_intact
done
grep -Fq 'the dedicated Simulator system language/locale is not en-US/en_US after the restart' "$workspace/capture.err" || {
  echo "a lost system language failed for another reason: $(<"$workspace/capture.err")" >&2; exit 1
}

: > "$fake_log"
capture_root="$workspace/captured"
run_capture appstore-test-session "$capture_root" "$capture_requirements" "$capture_runtime" || {
  echo "dedicated capture failed: $(<"$workspace/capture.err")" >&2; exit 1
}
assert_dedicated_devices_intact
# #168: the RGBA captures are published as RGB PNGs with the same colors and no leftover raw capture.
ruby -rjson -rzlib -e '
  root = ARGV.fetch(0)
  JSON.parse(File.binread(File.join(root, "manifest.json"))).fetch("cases").each do |entry|
    data = File.binread(File.join(root, entry.fetch("path")))
    abort "#{entry["path"]} is not RGB" unless data.byteslice(25, 1).unpack1("C") == 2
    seed = {"en-US/iphone-6.3" => 77, "ja/iphone-6.3" => 78, "en-US/ipad-13" => 79, "ja/ipad-13" => 80}.fetch("#{entry["locale"]}/#{entry["family"]}")
    idat = +""; offset = 8
    while offset < data.bytesize
      length = data.byteslice(offset, 4).unpack1("N"); type = data.byteslice(offset + 4, 4)
      idat << data.byteslice(offset + 8, length) if type == "IDAT"
      offset += 12 + length
    end
    # Every PNG filter leaves the first pixel of the first row unchanged.
    first = Zlib::Inflate.inflate(idat).byteslice(1, 3).unpack("C3")
    abort "#{entry["path"]} changed its colors" unless first == [seed % 251, (seed * 3) % 251, (seed * 7) % 251]
  end
  abort "a raw capture was left behind" unless Dir.glob(File.join(root, "**", ".raw-*"), File::FNM_DOTMATCH).empty?
' "$capture_root"
grep -Fq 'settle_seconds=${IOS_TEMPLATE_APPSTORE_SETTLE_SECONDS:-8}' "$capture" || {
  echo 'capture must wait 8 seconds by default before each screenshot' >&2; exit 1
}
ruby -e '
  lines = File.readlines(ARGV.fetch(0))
  launch = lines.index { |line| line.include?("simctl launch") }
  settle = lines.index { |line| line.strip == %q{sleep "$settle_seconds"} }
  shot = lines.index { |line| line.include?("screenshot --type=png") }
  abort "capture must wait between launch and screenshot" unless launch && settle && shot && launch < settle && settle < shot
' "$capture"
ruby -rjson -e '
  value = JSON.parse(File.binread(ARGV.fetch(0)))
  abort "capture runtime" unless value.fetch("runtime") == ARGV.fetch(1)
  expected = {"iphone-6.3" => ["iPhone 17 Pro", 1206, 2622], "ipad-13" => ["iPad Pro (M5)", 2064, 2752]}
  cases = value.fetch("cases")
  abort "capture cases" unless cases.map { |entry| entry.values_at("locale", "family") }.sort == [%w[en-US ipad-13], %w[en-US iphone-6.3], %w[ja ipad-13], %w[ja iphone-6.3]]
  cases.each do |entry|
    abort "capture device or size for #{entry["family"]}" unless entry.values_at("deviceType", "width", "height") == expected.fetch(entry.fetch("family"))
  end
' "$capture_root/manifest.json" "$capture_runtime"
ruby -rjson -e '
  files = Dir.glob(File.join(ARGV.fetch(0), "allocation-*.json"))
  abort "receipt count" unless files.length == 4
  files.each do |path|
    value = JSON.parse(File.binread(path))
    abort "lease is not a released dedicated lease" unless value.fetch("kind") == "dedicated-lease" &&
      value.fetch("status") == "released" && value.dig("cleanup", "status") == "passed" &&
      [ARGV.fetch(1), ARGV.fetch(2)].include?(value.fetch("deviceName"))
  end
' "$capture_root/simulator-allocations" "$iphone_name" "$ipad_name"
[[ "$(rg -c '^simctl erase ' "$fake_log")" == 4 ]] || { echo 'each locale/family lease did not erase its dedicated device' >&2; exit 1; }
rg -q 'status_bar .*--time 9:41' "$fake_log" || { echo 'fixed status bar was not applied' >&2; exit 1; }
rg -q -- '-AppleLanguages \(en\)' "$fake_log" && rg -q -- '-AppleLanguages \(ja\)' "$fake_log" || {
  echo 'English or Japanese launch arguments are missing' >&2; exit 1
}
# #173: each lease writes the system language and locale, restarts in place without erasing,
# and reads them back before the status bar and the first launch.
ruby -e '
  lines = File.readlines(ARGV.fetch(0)).map(&:strip)
  expected = {"en-US" => %w[en-US en_US], "ja" => %w[ja-JP ja_JP]}
  seen = []
  lines.each_index do |index|
    next unless lines[index].start_with?("simctl erase ")
    udid = lines[index].split.last
    rest = lines[index + 1..-1]
    language_line = rest.find_index { |line| line.start_with?("simctl spawn #{udid} defaults write -g AppleLanguages -array ") } or abort "no system language write after erase of #{udid}"
    language, locale = rest[language_line].split.last, rest[language_line + 1].to_s.split.last
    pair = expected.find { |_, value| value == [language, locale] } or abort "unexpected system language #{language}/#{locale}"
    sequence = rest[language_line, 7].map { |line| line.split.first(3).join(" ") }
    abort "system language for #{udid} was not written, restarted, and read back in order: #{sequence}" unless sequence == [
      "simctl spawn #{udid}", "simctl spawn #{udid}", "simctl shutdown #{udid}", "simctl boot #{udid}",
      "simctl bootstatus #{udid}", "simctl spawn #{udid}", "simctl status_bar #{udid}"
    ] && rest[language_line + 1] == "simctl spawn #{udid} defaults write -g AppleLocale -string #{locale}" &&
      rest[language_line + 5] == "simctl spawn #{udid} defaults export -g -"
    abort "the system language restart erased the device" if rest[language_line, 7].any? { |line| line.start_with?("simctl erase ") }
    first_launch = rest.find_index { |line| line.start_with?("simctl launch ") } or abort "no launch after erase of #{udid}"
    abort "the app launched before the system language was ready" unless language_line + 6 < first_launch
    seen << pair.first
  end
  abort "system languages per lease: #{seen}" unless seen.sort == %w[en-US en-US ja ja]
' "$fake_log"

# The existing set builder accepts the dedicated capture unchanged.
capture_review="$workspace/capture-review.json"
ruby -rjson -e '
  manifest = JSON.parse(File.binread(ARGV.fetch(0)))
  checks = manifest.fetch("cases").map do |entry|
    {"locale" => entry["locale"], "family" => entry["family"], "state" => entry["state"], "path" => entry["path"],
     "digest" => entry["digest"], "safeArea" => "passed", "textClipping" => "passed",
     "truthfulRepresentation" => "passed", "localeParity" => "passed"}
  end
  File.binwrite(ARGV.fetch(1), JSON.generate({"schemaVersion" => 1, "sourceSha" => manifest["sourceSha"],
    "buildDigest" => manifest["buildDigest"], "visualReviewStatus" => "passed",
    "releaseAuditor" => {"status" => "approved", "model" => "release-auditor"}, "cases" => checks}))
' "$capture_root/manifest.json" "$capture_review"
result=$("$builder" --raw-root "$capture_root" --output-root "$workspace/capture-final" --requirements "$capture_requirements" \
  --review "$capture_review" --source-sha "$source_sha" --runtime "$capture_runtime" --build-digest "$build_digest")
[[ "$result" == *'"status":"ready"'* ]] || { echo "the set builder rejected the dedicated capture: $result" >&2; exit 1; }

# #165: outside test mode resource_test_flags is empty, and macOS /bin/bash 3.2 stops with
# "unbound variable" on a bare "${resource_test_flags[@]}" under set -u. Every expansion must
# use the guarded form, as verify-ios-issue.sh does.
capture_tool="$repo_root/tools/capture-appstore-screenshots.sh"
if grep -n 'resource_test_flags\[@\]' "$capture_tool" | grep -v '\${resource_test_flags\[@\]+"\${resource_test_flags\[@\]}"}' | grep -q .; then
  echo "capture passes resource_test_flags without the empty-array guard" >&2
  exit 1
fi
[[ "$(grep -c '\${resource_test_flags\[@\]+"\${resource_test_flags\[@\]}"}' "$capture_tool")" -eq 2 ]] || {
  echo "capture must pass the guarded resource_test_flags to allocate and release" >&2; exit 1;
}
/bin/bash -c 'set -euo pipefail; flags=(); printf "%s\n" x ${flags[@]+"${flags[@]}"} >/dev/null' || {
  echo "the guarded empty-array expansion fails under /bin/bash" >&2; exit 1;
}

# #165 at the real call sites: outside test mode resource_test_flags is empty. A disposable copy of tools/
# runs under /bin/bash 3.2 with test mode off. Its xcrun path is pointed at this test's fake xcrun and its
# resource manager is a fake that refuses test flags, hands out the fake dedicated device of the requested
# type and shuts it down on release, so the capture's own allocate and release lines run with the empty
# array and no real simctl is ever called.
empty_repo="$workspace/empty-flags"
mkdir -p "$empty_repo/Config"
rsync -a --exclude tests "$repo_root/tools/" "$empty_repo/tools/"
/bin/cp "$repo_root/Config/dedicated-simulators.json" "$empty_repo/Config/"
empty_capture="$empty_repo/tools/capture-appstore-screenshots.sh"
[[ "$(grep -c '^  xcrun_bin=/usr/bin/xcrun$' "$empty_capture")" -eq 1 ]] || { echo 'capture no longer sets xcrun_bin once outside test mode' >&2; exit 1; }
sed -i '' 's|^  xcrun_bin=/usr/bin/xcrun$|  xcrun_bin=${FAKE_XCRUN_FOR_COPY:?}|' "$empty_capture"
cat >"$empty_repo/tools/lib/ios-simulator-resource.rb" <<'RUBY'
# Fake resource manager for the empty-flag regression: it records each call and uses only the fake xcrun.
require "json"
require "securerandom"
command, *rest = ARGV
File.open(ENV.fetch("FAKE_RESOURCE_LOG"), "a") { |log| log.puts(([command] + rest).join(" ")) }
abort "test flags reached the resource manager: #{rest.first}" unless rest.first == "--session"
options = rest.each_slice(2).to_h
leases = ENV.fetch("FAKE_RESOURCE_STATE")
case command
when "allocate"
  devices = JSON.parse(File.read(ENV.fetch("FAKE_SIMCTL_STATE"))).fetch("devices").values.flatten
  udid = devices.find { |device| device["deviceTypeIdentifier"] == options.fetch("--device-type") && device["name"].start_with?("iOS-Template ") }.fetch("udid")
  id = SecureRandom.uuid
  receipt = File.join(File.realpath(options.fetch("--receipt-dir")), "allocation-#{id}.json")
  File.write(receipt, "{}\n")
  line = [id, udid, receipt].join("\t")
  File.write(File.join(leases, id), line)
  puts line
when "release"
  line = File.read(File.join(leases, options.fetch("--allocation-id")))
  system(ENV.fetch("FAKE_XCRUN_FOR_COPY"), "simctl", "shutdown", line.split("\t")[1]) or abort "fake shutdown failed"
  puts line
else abort "unexpected command #{command}"
end
RUBY
git -C "$empty_repo" init -q
git -C "$empty_repo" add -A
git -C "$empty_repo" -c user.name='Capture Test' -c user.email=capture@example.invalid -c commit.gpgsign=false commit -q -m empty-flags
mkdir -p "$workspace/empty-flags-leases"
: > "$fake_log"
env -u IOS_TEMPLATE_APPSTORE_XCRUN -u IOS_TEMPLATE_SIMULATOR_RESOURCE_STATE_ROOT -u IOS_TEMPLATE_SIMULATOR_RESOURCE_TEST_MODE \
  FAKE_XCRUN_FOR_COPY="$fake_bin/xcrun" FAKE_XCRUN_LOG="$fake_log" FAKE_SIMCTL_STATE="$fake_state" FAKE_PNG_DIR="$fake_pngs" \
  FAKE_RESOURCE_LOG="$workspace/empty-flags.log" FAKE_RESOURCE_STATE="$workspace/empty-flags-leases" IOS_TEMPLATE_APPSTORE_SETTLE_SECONDS=0 \
  /bin/bash "$empty_capture" --requirements "$capture_requirements" --states "$states" --app-path "$workspace/Fake.app" \
  --bundle-id com.yuto.TemplateApp --source-sha "$(git -C "$empty_repo" rev-parse HEAD)" --build-digest "$build_digest" \
  --runtime "$capture_runtime" --output-root "$workspace/empty-flags-out" --issue 88 --batch-id appstore-empty-flags \
  >"$workspace/empty-flags.out" 2>"$workspace/empty-flags.err" || {
  echo "capture outside test mode failed with empty resource flags: $(<"$workspace/empty-flags.err")" >&2; exit 1;
}
! grep -q 'unbound variable' "$workspace/empty-flags.err" || { echo 'bash 3.2 stopped on the empty resource flags' >&2; exit 1; }
ruby -e '
  calls = File.readlines(ARGV.fetch(0)).map { |line| line.split.first(2) }
  abort "resource calls: #{calls}" unless calls.length == 8 && calls.each_slice(2).all? { |pair| pair == [%w[allocate --session], %w[release --session]] }
' "$workspace/empty-flags.log"
[[ -f "$workspace/empty-flags-out/manifest.json" ]] || { echo 'capture outside test mode published no manifest' >&2; exit 1; }
! rg -q '^simctl (create|clone|delete|rename) ' "$fake_log" || { echo 'capture outside test mode changed the device set' >&2; exit 1; }
assert_dedicated_devices_intact

echo 'PASS: App Store screenshots require exact images, deterministic locales, and release-only device families, and capture leases only the dedicated Simulators'
