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
  family=value.fetch("screenshots").fetch("requiredFamilies").find{|entry| entry.fetch("id")=="iphone-6.9"}
  family["deviceTypes"]=["iPhone 17 Pro Max"]
  File.binwrite(path,JSON.generate(value))
' "$requirements"

write_png() {
  local path=$1 width=$2 height=$3 color_type=$4 seed=$5
  mkdir -p "$(dirname "$path")"
  ruby -rzlib -e '
    path,width,height,color_type,seed=ARGV
    width=Integer(width); height=Integer(height); color_type=Integer(color_type); seed=Integer(seed)
    channels=color_type==6 ? 4 : 3
    pixel=[seed%251,(seed*3)%251,(seed*7)%251,255].take(channels).pack("C*")
    raw=("\x00" + pixel*width)*height
    chunk=lambda do |type,data|
      type=type.b; [data.bytesize].pack("N")+type+data+[Zlib.crc32(type+data)].pack("N")
    end
    png="\x89PNG\r\n\x1a\n".b
    png << chunk.call("IHDR",[width,height,8,color_type,0,0,0].pack("NNC5"))
    png << chunk.call("IDAT",Zlib::Deflate.deflate(raw,9))
    png << chunk.call("IEND","".b)
    File.binwrite(path,png)
  ' "$path" "$width" "$height" "$color_type" "$seed"
}

write_valid_fixture() {
  rm -rf -- "$raw" "$final"
  mkdir -p "$raw/en-US/iphone-6.9" "$raw/en-US/ipad-13" "$raw/ja/iphone-6.9" "$raw/ja/ipad-13"
  write_png "$raw/en-US/iphone-6.9/01-primary.png" 1260 2736 2 11
  write_png "$raw/ja/iphone-6.9/01-primary.png" 1260 2736 2 12
  write_png "$raw/en-US/ipad-13/01-primary.png" 2064 2752 2 21
  write_png "$raw/ja/ipad-13/01-primary.png" 2064 2752 2 22
  RAW="$raw" REVIEW="$review" REQUIREMENTS="$requirements" SOURCE_SHA="$source_sha" RUNTIME="$runtime" BUILD_DIGEST="$build_digest" ruby -rjson -rdigest -e '
    raw=ENV.fetch("RAW")
    definitions=[
      ["en-US","iphone-6.9","iPhone 17 Pro Max",1260,2736],
      ["ja","iphone-6.9","iPhone 17 Pro Max",1260,2736],
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
[[ -f "$final/en-US/iphone-6.9/01-primary.png" && -f "$final/ja/ipad-13/01-primary.png" && -f "$final/manifest.json" ]] || {
  echo 'final screenshot set is incomplete' >&2; exit 1
}

write_valid_fixture
write_png "$raw/en-US/iphone-6.9/01-primary.png" 1170 2532 2 31
refresh_digests
assert_failure 'wrong dimensions' 'dimensions'

write_valid_fixture
write_png "$raw/en-US/iphone-6.9/01-primary.png" 1260 2736 6 32
refresh_digests
assert_failure 'alpha channel' 'alpha'

write_valid_fixture
/bin/cp "$raw/en-US/iphone-6.9/01-primary.png" "$raw/ja/iphone-6.9/01-primary.png"
refresh_digests
assert_failure 'duplicate bytes' 'duplicate'

write_valid_fixture
ruby -rjson -e 'p=ARGV.fetch(0); v=JSON.parse(File.binread(p)); v["cases"].reject!{|e| e["locale"]=="ja"}; File.binwrite(p,JSON.generate(v))' "$raw/manifest.json"
assert_failure 'missing locale' 'missing ja'

write_valid_fixture
ruby -rjson -e 'p=ARGV.fetch(0); v=JSON.parse(File.binread(p)); v["cases"].find{|e| e["locale"]=="en-US" && e["family"]=="iphone-6.9"}["order"]=2; File.binwrite(p,JSON.generate(v))' "$raw/manifest.json"
assert_failure 'non-contiguous ordering' 'order'

write_valid_fixture
ruby -rjson -e 'p=ARGV.fetch(0); v=JSON.parse(File.binread(p)); v["cases"].first.delete("deviceType"); File.binwrite(p,JSON.generate(v))' "$raw/manifest.json"
assert_failure 'incomplete manifest' 'deviceType'

write_valid_fixture
ruby -rjson -e 'p=ARGV.fetch(0); v=JSON.parse(File.binread(p)); v["cases"].first["safeArea"]="failed"; File.binwrite(p,JSON.generate(v))' "$review"
assert_failure 'safe area clipping' 'safeArea'

write_valid_fixture
ruby -rjson -e 'p=ARGV.fetch(0); v=JSON.parse(File.binread(p)); v["cases"].find{|e| e["family"]=="iphone-6.9"}["deviceType"]="iPhone 17 Pro"; File.binwrite(p,JSON.generate(v))' "$raw/manifest.json"
assert_failure 'required Pro Max capture' 'deviceType'

# Exercise deterministic Simulator capture through the shared resource manager
# and a fake xcrun adapter. The pinned fixture intentionally makes the 6.9-inch
# family Pro-Max-only. Each locale/family is allocated and deleted before the
# next one, so one session never holds two devices.
fake_bin="$workspace/fake-bin"; mkdir -p "$fake_bin"
fake_png="$workspace/fake.png"; write_png "$fake_png" 1260 2736 2 77
fake_ipad_png="$workspace/fake-ipad.png"; write_png "$fake_ipad_png" 2064 2752 2 78
fake_log="$workspace/xcrun.log"
fake_state="$workspace/simctl-state.json"
resource_state="$workspace/resource-state"
printf '%s\n' '{"sequence":0,"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[]}}' > "$fake_state"
cat > "$fake_bin/xcrun" <<'RUBY'
#!/usr/bin/ruby --disable-gems
require "fileutils"
require "json"

state_path = ENV.fetch("FAKE_SIMCTL_STATE")
log_path = ENV.fetch("FAKE_XCRUN_LOG")
File.open(log_path, "a", 0o600) { |file| file.puts(ARGV.join(" ")) }
abort "expected simctl" unless ARGV.shift == "simctl"
command = ARGV.shift
runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"

lock = File.open(state_path + ".lock", File::RDWR | File::CREAT, 0o600)
lock.flock(File::LOCK_EX)
begin
  state = JSON.parse(File.binread(state_path))
  devices = state.fetch("devices").fetch(runtime)
  case command
  when "list"
    case ARGV
    when %w[-j devicetypes]
      puts JSON.generate("devicetypes" => [
        {"name" => "iPhone 17 Pro Max", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"},
        {"name" => "iPad Air (M4)", "identifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Air-M4-13-inch"}
      ])
    when %w[devices -j]
      puts JSON.generate("devices" => state.fetch("devices"))
    else
      abort "unexpected list arguments"
    end
  when "create"
    name, device_type, requested_runtime = ARGV
    abort "invalid create" unless ARGV.length == 3 && requested_runtime == runtime
    state["sequence"] += 1
    udid = format("00000000-0000-0000-0000-%012d", state.fetch("sequence"))
    data_path = File.join(File.dirname(state_path), "data", udid)
    FileUtils.mkdir_p(data_path)
    devices << {
      "udid" => udid, "name" => name, "state" => "Shutdown", "isAvailable" => true,
      "deviceTypeIdentifier" => device_type, "dataPath" => data_path
    }
    File.binwrite(state_path, JSON.generate(state))
    puts udid
  when "boot"
    device = devices.find { |entry| entry.fetch("udid") == ARGV.fetch(0) } or abort "missing boot target"
    device["state"] = "Booted"
    File.binwrite(state_path, JSON.generate(state))
  when "shutdown"
    device = devices.find { |entry| entry.fetch("udid") == ARGV.fetch(0) } or abort "missing shutdown target"
    device["state"] = "Shutdown"
    File.binwrite(state_path, JSON.generate(state))
  when "delete"
    device = devices.find { |entry| entry.fetch("udid") == ARGV.fetch(0) } or abort "missing delete target"
    FileUtils.rm_rf(device.fetch("dataPath"))
    devices.delete(device)
    File.binwrite(state_path, JSON.generate(state))
  when "io"
    abort "configured screenshot failure" if ENV["FAKE_FAIL_SCREENSHOT"] == "1"
    destination = ARGV.fetch(-1)
    source = destination.include?("/ipad-13/") ? ENV.fetch("FAKE_IPAD_PNG") : ENV.fetch("FAKE_PNG")
    FileUtils.cp(source, destination)
  when "bootstatus", "status_bar", "install", "launch", "terminate", "uninstall"
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
capture_root="$workspace/captured"
FAKE_XCRUN_LOG="$fake_log" FAKE_SIMCTL_STATE="$fake_state" FAKE_PNG="$fake_png" FAKE_IPAD_PNG="$fake_ipad_png" \
  IOS_TEMPLATE_SIMULATOR_SESSION_ID=appstore-test-session IOS_TEMPLATE_SIMULATOR_RESOURCE_TEST_MODE=1 \
  IOS_TEMPLATE_SIMULATOR_RESOURCE_STATE_ROOT="$resource_state" IOS_TEMPLATE_APPSTORE_XCRUN="$fake_bin/xcrun" \
  "$capture" --requirements "$requirements" --states "$states" --app-path "$workspace/Fake.app" \
  --bundle-id com.yuto.TemplateApp --source-sha "$source_sha" --build-digest "$build_digest" \
  --runtime "$runtime" --output-root "$capture_root" --issue 88 --batch-id appstore-test >/dev/null
ruby -rjson -e '
  value=JSON.parse(File.binread(ARGV.fetch(0))); abort "capture cases" unless value.fetch("cases").length==4
  iphone=value.fetch("cases").find{|entry| entry.fetch("family")=="iphone-6.9"}
  abort "Pro Max not resolved" unless iphone.fetch("deviceType")=="iPhone 17 Pro Max"
' "$capture_root/manifest.json"
[[ "$(find "$capture_root/simulator-allocations" -type f -name 'allocation-*.json' | wc -l | tr -d ' ')" == 4 ]] || {
  echo 'released allocation receipts were not preserved' >&2; exit 1
}
ruby -rjson -e '
  files=Dir.glob(File.join(ARGV.fetch(0),"allocation-*.json")); abort "receipt count" unless files.length==4
  files.each do |path|
    value=JSON.parse(File.binread(path))
    abort "allocation not released" unless value.fetch("status")=="released" && value.dig("cleanup","status")=="passed"
  end
' "$capture_root/simulator-allocations"
ruby -e '
  active=0; maximum=0; creates=deletes=0
  File.readlines(ARGV.fetch(0),chomp:true).each do |line|
    if line.start_with?("simctl create ") then active+=1; creates+=1; maximum=[maximum,active].max
    elsif line.start_with?("simctl delete ") then active-=1; deletes+=1; abort "delete without create" if active.negative?
    end
  end
  abort "not sequential" unless creates==4 && deletes==4 && active.zero? && maximum==1
' "$fake_log"
[[ "$(jq '[.devices[] | .[]] | length' "$fake_state")" == 0 ]] || { echo 'fake Simulator device leaked after capture' >&2; exit 1; }
! rg -q '^simctl erase ' "$fake_log" || { echo 'capture used erase instead of exact resource release' >&2; exit 1; }
rg -q 'status_bar .*--time 9:41' "$fake_log" || { echo 'fixed status bar was not applied' >&2; exit 1; }
rg -q -- '-AppleLanguages.*en' "$fake_log" || { echo 'English launch arguments are missing' >&2; exit 1; }
rg -q -- '-AppleLanguages.*ja' "$fake_log" || { echo 'Japanese launch arguments are missing' >&2; exit 1; }

# A capture failure must still release and delete the exact owned device.
failure_root="$workspace/capture-failure"
set +e
FAKE_XCRUN_LOG="$fake_log" FAKE_SIMCTL_STATE="$fake_state" FAKE_PNG="$fake_png" FAKE_IPAD_PNG="$fake_ipad_png" \
  FAKE_FAIL_SCREENSHOT=1 IOS_TEMPLATE_SIMULATOR_SESSION_ID=appstore-failure-session \
  IOS_TEMPLATE_SIMULATOR_RESOURCE_TEST_MODE=1 IOS_TEMPLATE_SIMULATOR_RESOURCE_STATE_ROOT="$resource_state" \
  IOS_TEMPLATE_APPSTORE_XCRUN="$fake_bin/xcrun" \
  "$capture" --requirements "$requirements" --states "$states" --app-path "$workspace/Fake.app" \
  --bundle-id com.yuto.TemplateApp --source-sha "$source_sha" --build-digest "$build_digest" \
  --runtime "$runtime" --output-root "$failure_root" --issue 88 --batch-id appstore-failure \
  >"$workspace/failure.out" 2>"$workspace/failure.err"
failure_status=$?
set -e
[[ "$failure_status" -ne 0 && ! -e "$failure_root" ]] || { echo 'failed capture published output' >&2; exit 1; }
[[ "$(jq '[.devices[] | .[]] | length' "$fake_state")" == 0 ]] || { echo 'failed capture leaked its Simulator' >&2; exit 1; }

echo 'PASS: App Store screenshots require exact images, deterministic locales, sequential managed Simulators, cleanup, and release-only device families'
