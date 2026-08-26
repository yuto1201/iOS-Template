#!/bin/bash
set -euo pipefail

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
source_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
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

# Exercise deterministic Simulator capture through a fake xcrun adapter. The
# pinned fixture intentionally makes the 6.9-inch family Pro-Max-only.
fake_bin="$workspace/fake-bin"; mkdir -p "$fake_bin"
fake_png="$workspace/fake.png"; write_png "$fake_png" 1260 2736 2 77
fake_ipad_png="$workspace/fake-ipad.png"; write_png "$fake_ipad_png" 2064 2752 2 78
fake_log="$workspace/xcrun.log"; fake_counter="$workspace/counter"; printf '0\n' > "$fake_counter"
cat > "$fake_bin/xcrun" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_XCRUN_LOG"
[[ "${1-}" == simctl ]] || exit 2
shift
case "${1-}" in
  list)
    printf '%s\n' '{"devicetypes":[{"name":"iPhone 17 Pro Max","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"},{"name":"iPad Air (M4)","identifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Air-M4-13-inch"}]}'
    ;;
  create)
    count=$(<"$FAKE_COUNTER"); count=$((count+1)); printf '%s\n' "$count" > "$FAKE_COUNTER"
    printf '00000000-0000-0000-0000-%012d\n' "$count"
    ;;
  io)
    destination=${@: -1}
    if [[ "$destination" == *'/ipad-13/'* ]]; then /bin/cp "$FAKE_IPAD_PNG" "$destination"; else /bin/cp "$FAKE_PNG" "$destination"; fi
    ;;
  *) ;;
esac
EOF
chmod +x "$fake_bin/xcrun"
mkdir -p "$workspace/Fake.app"
capture_root="$workspace/captured"
FAKE_XCRUN_LOG="$fake_log" FAKE_COUNTER="$fake_counter" FAKE_PNG="$fake_png" FAKE_IPAD_PNG="$fake_ipad_png" PATH="$fake_bin:$PATH" \
  "$capture" --requirements "$requirements" --states "$states" --app-path "$workspace/Fake.app" \
  --bundle-id com.yuto.TemplateApp --source-sha "$source_sha" --build-digest "$build_digest" \
  --runtime "$runtime" --output-root "$capture_root" >/dev/null
ruby -rjson -e '
  value=JSON.parse(File.binread(ARGV.fetch(0))); abort "capture cases" unless value.fetch("cases").length==4
  iphone=value.fetch("cases").find{|entry| entry.fetch("family")=="iphone-6.9"}
  abort "Pro Max not resolved" unless iphone.fetch("deviceType")=="iPhone 17 Pro Max"
' "$capture_root/manifest.json"
rg -q 'status_bar .*--time 9:41' "$fake_log" || { echo 'fixed status bar was not applied' >&2; exit 1; }
rg -q -- '-AppleLanguages.*en' "$fake_log" || { echo 'English launch arguments are missing' >&2; exit 1; }
rg -q -- '-AppleLanguages.*ja' "$fake_log" || { echo 'Japanese launch arguments are missing' >&2; exit 1; }

echo 'PASS: App Store screenshots require exact unmodified images, audited review, deterministic locales, and release-only device families'
