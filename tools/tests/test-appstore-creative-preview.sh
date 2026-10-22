#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby jq node ffmpeg ffprobe

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
tool="$repo_root/tools/appstore-creative-preview.sh"
runtime="${GOLDIE_RUNTIME:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-goldie/0.3.1}"
[[ -f "$runtime/node_modules/goldie/package.json" ]] || { echo "pinned Goldie runtime is missing: $runtime" >&2; exit 1; }
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-creative-preview.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT
fail() { echo "$*" >&2; exit 1; }
expect_failure() { # label message command...
  local label=$1 message=$2; shift 2
  if "$@" >"$workspace/$label.out" 2>"$workspace/$label.err"; then fail "preview tool accepted $label"; fi
  grep -Fq -- "$message" "$workspace/$label.err" || { cat "$workspace/$label.err" >&2; fail "unexpected failure for $label"; }
}
encode=(-c:v libx264 -preset ultrafast -pix_fmt yuv420p)
clip() { # path size seconds [extra filter]
  ffmpeg -y -loglevel error -f lavfi -i "testsrc2=s=$2:r=30:d=$3" ${4:+-vf "$4"} "${encode[@]}" "$1"
}
# D-079: the dedicated iPhone 17 Pro records 1206x2622 (family iphone-6.3); the dedicated iPad 2064x2752.
iphone=1206x2622
ipad=2064x2752
record_dir() { # dir family locale size seconds[:planned]... -> a recorder-shaped record.json
  local dir=$1 family=$2 locale=$3 size=$4; shift 4
  mkdir -p "$dir/$locale/$family"
  local index=1 segments=()
  for seconds in "$@"; do
    local relative="$locale/$family/0$index-seg$index.mp4"
    clip "$dir/$relative" "$size" "${seconds%%:*}"
    segments+=("$(ruby -rjson -rdigest -e 'puts JSON.generate({"id" => ARGV[0], "state" => "primary", "seconds" => Integer(ARGV[1]),
      "allowStill" => false, "path" => ARGV[2], "sha256" => "sha256:#{Digest::SHA256.file(ARGV[3]).hexdigest}"})' "seg$index" "${seconds##*:}" "$relative" "$dir/$relative")")
    index=$((index+1))
  done
  ruby -rjson -e 'puts JSON.pretty_generate({"schemaVersion" => 1, "family" => ARGV[0], "locale" => ARGV[1], "deviceType" => "test",
    "runtime" => "test", "sourceSha" => "0" * 40, "buildDigest" => "sha256:#{"b" * 64}", "segments" => ARGV.drop(2).map { |s| JSON.parse(s) }})' \
    "$family" "$locale" "${segments[@]}" >"$dir/record.json"
}
write_config() { # config-dir device segment-count
  mkdir -p "$1"
  local segments; segments=$(ruby -e 'puts (1..Integer(ARGV[0])).map { |i| %({ id: "seg#{i}", flow: "x" }) }.join(", ")' "$3")
  cat >"$1/goldie.config.mjs" <<EOF
export default {
  appRoot: "$workspace", appPath: "$workspace/App.app", bundleId: "com.example.preview",
  devices: ["$2"], locales: ["ja"], appearance: "light", frame: { variant: "17-pro-silver" },
  theme: { background: "#FFFFFF", headlineColor: "#111111", subheadColor: "#444444", fontFamily: "sans-serif",
    copyHeightRatio: 0.2, deviceWidthRatio: 0.84, layout: "classic" },
  store: { name: "Preview", subtitle: { ja: "" }, developer: "", category: "", rating: 0, ratingCount: "", ageRating: "", price: "", description: { ja: "" } },
  scenes: [{ kind: "preview", id: "preview", segments: [$segments] }]
};
EOF
}
assert_video() { # mp4 width height
  ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,avg_frame_rate:format=duration -of json "$1" |
    jq -e --argjson w "$2" --argjson h "$3" '(.streams | map(select(.codec_type == "video")) | first | .codec_name == "h264" and .width == $w and .height == $h and .avg_frame_rate == "30/1")
      and (.streams | any(.codec_type == "audio")) and ((.format.duration | tonumber) >= 15 and (.format.duration | tonumber) <= 30)' >/dev/null ||
    fail "encoded preview $1 does not match ${2}x$3, H.264, 30 fps, audio, 15-30 s"
}
iphone_config="$workspace/app/goldie/ja/goldie.config.mjs"
write_config "$workspace/app/goldie/ja" iphone-6.3 3

# AC-4: recorded 1206x2622 iPhone segments become an 886x1920 preview through Goldie and the render
# extension's iphone-6.3 device; the clips and the written preview pass the quality gate.
record_dir "$workspace/rec-iphone" iphone-6.3 ja "$iphone" 6 6 6
"$tool" encode --config "$iphone_config" --device iphone-6.3 --locale ja \
  --record "$workspace/rec-iphone" --output "$workspace/encoded-iphone" >"$workspace/encode-iphone.json" || {
  cat "$workspace/encode-iphone.json" >&2; fail 'iPhone preview encode failed'; }
assert_video "$workspace/encoded-iphone/preview.mp4" 886 1920
jq -e '.status == "encoded" and .device == "iphone-6.3" and .source == "simulator" and .goldieVersion == "0.3.1"
  and (.clips | length == 3 and all(.qualityStatus == "passed" and .source == "simulator" and (.sha256 | test("^sha256:[0-9a-f]{64}$"))))
  and .video.width == 886 and .video.height == 1920 and .video.codec == "h264" and .video.fps == 30 and .video.audioCodec == "aac"
  and .video.qualityStatus == "passed" and (.video.sha256 | test("^sha256:[0-9a-f]{64}$"))' \
  "$workspace/encoded-iphone/encode.json" >/dev/null || { cat "$workspace/encoded-iphone/encode.json" >&2; fail 'encode record is incomplete'; }
for result in seg1 seg2 seg3 preview; do
  jq -e '.status == "passed"' "$workspace/encoded-iphone/quality/$result.json" >/dev/null || fail "encode did not keep the passing quality result $result"
done
jq -e '.metrics.width == 1206 and .metrics.height == 2622 and .sizeRule == "native"' "$workspace/encoded-iphone/quality/seg1.json" >/dev/null ||
  fail 'the recorded iPhone clip was not checked at its 1206x2622 native size'
jq -e '.metrics.width == 886 and .metrics.height == 1920' "$workspace/encoded-iphone/quality/preview.json" >/dev/null ||
  fail 'the written preview was not checked by the quality gate'
expect_failure re-encode 'output already exists and is never replaced' "$tool" encode --config "$iphone_config" \
  --device iphone-6.3 --locale ja --record "$workspace/rec-iphone" --output "$workspace/encoded-iphone"

# AC-4: iPad segments become a 1200x1600 preview through the render extension.
record_dir "$workspace/rec-ipad" ipad-13 ja "$ipad" 8 8
write_config "$workspace/app-ipad/goldie/ja" ipad-13 2
"$tool" encode --config "$workspace/app-ipad/goldie/ja/goldie.config.mjs" --device ipad-13 --locale ja \
  --record "$workspace/rec-ipad" --output "$workspace/encoded-ipad" >/dev/null || fail 'iPad preview encode failed'
assert_video "$workspace/encoded-ipad/preview.mp4" 1200 1600

# AC-4: a clip is shown for one more frame than its first-to-last frame time, so an exact 15-second
# recording and three 5-second segments make a 15-second preview, while a 14.9-second clip is refused.
record_dir "$workspace/rec-exact" iphone-6.3 ja "$iphone" 15
write_config "$workspace/app-one/goldie/ja" iphone-6.3 1
"$tool" encode --config "$workspace/app-one/goldie/ja/goldie.config.mjs" --device iphone-6.3 --locale ja \
  --record "$workspace/rec-exact" --output "$workspace/encoded-exact" >"$workspace/encode-exact.out" 2>&1 || {
  cat "$workspace/encode-exact.out" >&2; fail 'an exact 15-second recording was refused'; }
assert_video "$workspace/encoded-exact/preview.mp4" 886 1920
jq -e '.clips | map(.durationSeconds) == [15]' "$workspace/encoded-exact/encode.json" >/dev/null ||
  fail 'the exact 15-second clip was not counted as 15 seconds'
record_dir "$workspace/rec-fives" iphone-6.3 ja "$iphone" 5 5 5
"$tool" encode --config "$iphone_config" --device iphone-6.3 --locale ja \
  --record "$workspace/rec-fives" --output "$workspace/encoded-fives" >"$workspace/encode-fives.out" 2>&1 || {
  cat "$workspace/encode-fives.out" >&2; fail 'three 5-second segments were refused'; }
assert_video "$workspace/encoded-fives/preview.mp4" 886 1920
jq -e '.clips | map(.durationSeconds) == [5, 5, 5]' "$workspace/encoded-fives/encode.json" >/dev/null ||
  fail 'the 5-second segments were not counted as 5 seconds each'
record_dir "$workspace/rec-nearly" iphone-6.3 ja "$iphone" 14.9:15
expect_failure nearly-15 'the clips run 14.90s; a preview must run 15 to 30 seconds' "$tool" encode \
  --config "$workspace/app-one/goldie/ja/goldie.config.mjs" --device iphone-6.3 --locale ja \
  --record "$workspace/rec-nearly" --output "$workspace/encoded-nearly"

# AC-4: too short, too long, a failing clip, the former iPhone 17 Pro Max size, a changed or escaping
# clip, the former family, and a family mismatch are refused, and a refused encode leaves nothing.
record_dir "$workspace/rec-short" iphone-6.3 ja "$iphone" 5 5
write_config "$workspace/app-short/goldie/ja" iphone-6.3 2
expect_failure too-short 'a preview must run 15 to 30 seconds' "$tool" encode --config "$workspace/app-short/goldie/ja/goldie.config.mjs" \
  --device iphone-6.3 --locale ja --record "$workspace/rec-short" --output "$workspace/encoded-short"
record_dir "$workspace/rec-long" iphone-6.3 ja "$iphone" 16 16
expect_failure too-long 'a preview must run 15 to 30 seconds' "$tool" encode --config "$iphone_config" \
  --device iphone-6.3 --locale ja --record "$workspace/rec-long" --output "$workspace/encoded-long"
cp -R "$workspace/rec-iphone" "$workspace/rec-frozen"
clip "$workspace/rec-frozen/ja/iphone-6.3/02-seg2.mp4" "$iphone" 2 "tpad=stop_mode=clone:stop_duration=4"
ruby -rjson -rdigest -e 'path = ARGV[0]; record = JSON.parse(File.read(path)); segment = record["segments"][1]
  segment["sha256"] = "sha256:#{Digest::SHA256.file(File.join(File.dirname(path), segment["path"])).hexdigest}"; File.write(path, JSON.generate(record))' \
  "$workspace/rec-frozen/record.json"
expect_failure frozen-clip 'clip seg2 failed the quality gate: the picture freezes' "$tool" encode --config "$iphone_config" \
  --device iphone-6.3 --locale ja --record "$workspace/rec-frozen" --output "$workspace/encoded-frozen"
record_dir "$workspace/rec-former-size" iphone-6.3 ja 1320x2868 6
expect_failure former-size 'clip seg1 failed the quality gate: size 1320x2868 is not the iphone screen 1206x2622' "$tool" encode \
  --config "$iphone_config" --device iphone-6.3 --locale ja --record "$workspace/rec-former-size" --output "$workspace/encoded-former-size"
cp -R "$workspace/rec-iphone" "$workspace/rec-changed"
clip "$workspace/rec-changed/ja/iphone-6.3/01-seg1.mp4" "$iphone" 6 "hflip"
expect_failure changed-clip 'recorded clip seg1 differs from its record' "$tool" encode --config "$iphone_config" \
  --device iphone-6.3 --locale ja --record "$workspace/rec-changed" --output "$workspace/encoded-changed"
cp -R "$workspace/rec-iphone" "$workspace/rec-escape"
ruby -rjson -e 'path = ARGV[0]; record = JSON.parse(File.read(path)); record["segments"][0]["path"] = "../rec-iphone/ja/iphone-6.3/01-seg1.mp4"; File.write(path, JSON.generate(record))' \
  "$workspace/rec-escape/record.json"
expect_failure escaping-clip 'recorded clip seg1 lies outside its recording' "$tool" encode --config "$iphone_config" \
  --device iphone-6.3 --locale ja --record "$workspace/rec-escape" --output "$workspace/encoded-escape"
expect_failure former-family 'device must be iphone-6.3 or ipad-13' "$tool" encode --config "$iphone_config" \
  --device iphone-6.9 --locale ja --record "$workspace/rec-iphone" --output "$workspace/encoded-former-family"
expect_failure wrong-family 'not ipad-13/ja' "$tool" encode --config "$iphone_config" \
  --device ipad-13 --locale ja --record "$workspace/rec-iphone" --output "$workspace/encoded-wrong"
for refused in nearly short long frozen former-size changed escape former-family wrong; do
  [[ ! -e "$workspace/encoded-$refused" ]] || fail "a refused encode left output behind: $refused"
done

# AC-5: the user's own recordings, from another iPhone size, are encoded and marked user-supplied with
# their original path and SHA-256.
mkdir -p "$workspace/user"
for index in 1 2 3; do clip "$workspace/user/IMG_000$index.mp4" 1179x2556 6; done
printf '%s\n' '{"schemaVersion":1,"clips":[{"segmentId":"seg1","path":"IMG_0001.mp4"},{"segmentId":"seg2","path":"IMG_0002.mp4"},{"segmentId":"seg3","path":"IMG_0003.mp4"}]}' >"$workspace/user/clips.json"
write_config "$workspace/app-user/goldie/ja" iphone-6.3 3
"$tool" encode --config "$workspace/app-user/goldie/ja/goldie.config.mjs" --device iphone-6.3 --locale ja \
  --user-clips "$workspace/user/clips.json" --output "$workspace/encoded-user" >/dev/null || fail 'user clip encode failed'
assert_video "$workspace/encoded-user/preview.mp4" 886 1920
ruby -rjson -rdigest -e '
  record = JSON.parse(File.read(ARGV[0])); user = ARGV[1]
  abort "user source" unless record.fetch("source") == "user-supplied"
  record.fetch("clips").each_with_index do |clip, index|
    original = File.join(File.realpath(user), "IMG_000#{index + 1}.mp4")
    abort "user clip #{index + 1}: #{clip}" unless clip.fetch("source") == "user-supplied" &&
      File.realpath(clip.fetch("originalPath")) == original && clip.fetch("sha256") == "sha256:#{Digest::SHA256.file(original).hexdigest}"
  end
' "$workspace/encoded-user/encode.json" "$workspace/user"

# AC-6: preview-decision.json adopts only a preview that passed the quality gate, needs a reason, is
# recorded once, and can record no-video with a reason at any time.
decisions="$workspace/decisions"
"$tool" decide --output "$decisions/adopt/preview-decision.json" --revision flower-r3 --decision adopt --reason '動きが伝わる' \
  --encode "$workspace/encoded-iphone" >/dev/null || fail 'adopting a passing encode failed'
ruby -rjson -rdigest -e '
  value = JSON.parse(File.read(ARGV[0])); encode = ARGV[1]
  abort "adopt fields #{value.keys.sort}" unless value.keys.sort == %w[choice decision encode reason recordedAt revision schemaVersion video]
  abort "adopt decision" unless value.values_at("decision", "choice", "revision", "reason") == ["adopt", "user-explicit", "flower-r3", "動きが伝わる"]
  abort "adopted video" unless value.dig("video", "sha256") == "sha256:#{Digest::SHA256.file(File.join(encode, "preview.mp4")).hexdigest}" &&
    value.dig("video", "device") == "iphone-6.3" && value.dig("video", "source") == "simulator"
  abort "encode reference" unless value.dig("encode", "sha256") == "sha256:#{Digest::SHA256.file(File.join(encode, "encode.json")).hexdigest}"
' "$decisions/adopt/preview-decision.json" "$workspace/encoded-iphone"
before=$(shasum -a 256 "$decisions/adopt/preview-decision.json")
expect_failure decide-again 'a preview decision is already recorded and is never replaced' "$tool" decide \
  --output "$decisions/adopt/preview-decision.json" --revision flower-r3 --decision no-video --reason 'やめる'
[[ "$(shasum -a 256 "$decisions/adopt/preview-decision.json")" == "$before" ]] || fail 'a second decision changed the first'
expect_failure decision-name 'the decision file must be named preview-decision.json' "$tool" decide \
  --output "$decisions/other.json" --revision flower-r3 --decision no-video --reason 'やめる'
cp -R "$workspace/encoded-iphone" "$workspace/encoded-bad"
ruby -rjson -e 'path = ARGV[0]; record = JSON.parse(File.read(path)); record["clips"][0]["qualityStatus"] = "failed"; File.write(path, JSON.generate(record))' \
  "$workspace/encoded-bad/encode.json"
expect_failure adopt-failed 'a clip did not pass the quality gate: seg1' "$tool" decide --output "$decisions/bad/preview-decision.json" \
  --revision flower-r3 --decision adopt --reason 'x' --encode "$workspace/encoded-bad"
cp -R "$workspace/encoded-iphone" "$workspace/encoded-bad-result"
ruby -rjson -e 'path = ARGV[0]; result = JSON.parse(File.read(path)); result["status"] = "failed"; File.write(path, JSON.generate(result))' \
  "$workspace/encoded-bad-result/quality/seg2.json"
expect_failure adopt-failed-result 'a clip did not pass the quality gate: seg2' "$tool" decide --output "$decisions/bad-result/preview-decision.json" \
  --revision flower-r3 --decision adopt --reason 'x' --encode "$workspace/encoded-bad-result"
cp -R "$workspace/encoded-iphone" "$workspace/encoded-bad-video"
ruby -rjson -e 'path = ARGV[0]; record = JSON.parse(File.read(path)); record["video"]["qualityStatus"] = "failed"; File.write(path, JSON.generate(record))' \
  "$workspace/encoded-bad-video/encode.json"
expect_failure adopt-failed-video 'the encoded preview did not pass the quality gate' "$tool" decide --output "$decisions/bad-video/preview-decision.json" \
  --revision flower-r3 --decision adopt --reason 'x' --encode "$workspace/encoded-bad-video"
# The saved final quality result must exist, pass, and be for the adopted video; a clip's result must
# be for that clip. A passing flag in encode.json alone does not adopt a preview.
cp -R "$workspace/encoded-iphone" "$workspace/encoded-no-final"
rm "$workspace/encoded-no-final/quality/preview.json"
expect_failure adopt-no-final 'the encoded preview has no passing quality result for this video' "$tool" decide \
  --output "$decisions/no-final/preview-decision.json" --revision flower-r3 --decision adopt --reason 'x' --encode "$workspace/encoded-no-final"
cp -R "$workspace/encoded-iphone" "$workspace/encoded-failed-final"
ruby -rjson -e 'path = ARGV[0]; result = JSON.parse(File.read(path)); result["status"] = "failed"; File.write(path, JSON.generate(result))' \
  "$workspace/encoded-failed-final/quality/preview.json"
expect_failure adopt-failed-final 'the encoded preview has no passing quality result for this video' "$tool" decide \
  --output "$decisions/failed-final/preview-decision.json" --revision flower-r3 --decision adopt --reason 'x' --encode "$workspace/encoded-failed-final"
cp -R "$workspace/encoded-iphone" "$workspace/encoded-other-final"
cp "$workspace/encoded-fives/quality/preview.json" "$workspace/encoded-other-final/quality/preview.json"
jq -e '.status == "passed"' "$workspace/encoded-other-final/quality/preview.json" >/dev/null || fail 'the borrowed final result did not pass'
expect_failure adopt-other-final 'the encoded preview has no passing quality result for this video' "$tool" decide \
  --output "$decisions/other-final/preview-decision.json" --revision flower-r3 --decision adopt --reason 'x' --encode "$workspace/encoded-other-final"
cp -R "$workspace/encoded-iphone" "$workspace/encoded-other-clip"
cp "$workspace/encoded-fives/quality/seg1.json" "$workspace/encoded-other-clip/quality/seg1.json"
jq -e '.status == "passed"' "$workspace/encoded-other-clip/quality/seg1.json" >/dev/null || fail 'the borrowed clip result did not pass'
expect_failure adopt-other-clip 'a clip did not pass the quality gate: seg1' "$tool" decide \
  --output "$decisions/other-clip/preview-decision.json" --revision flower-r3 --decision adopt --reason 'x' --encode "$workspace/encoded-other-clip"
cp -R "$workspace/encoded-iphone" "$workspace/encoded-swapped"
cp "$workspace/encoded-ipad/preview.mp4" "$workspace/encoded-swapped/preview.mp4"
expect_failure adopt-swapped 'the encoded preview differs from its record' "$tool" decide --output "$decisions/swapped/preview-decision.json" \
  --revision flower-r3 --decision adopt --reason 'x' --encode "$workspace/encoded-swapped"
expect_failure adopt-without-encode 'adopting a preview needs --encode' "$tool" decide --output "$decisions/none/preview-decision.json" \
  --revision flower-r3 --decision adopt --reason '使う'
expect_failure no-reason 'a decision needs a reason' "$tool" decide --output "$decisions/empty/preview-decision.json" \
  --revision flower-r3 --decision no-video --reason ' '
expect_failure adopt-no-reason 'a decision needs a reason' "$tool" decide --output "$decisions/empty/preview-decision.json" \
  --revision flower-r3 --decision adopt --reason '' --encode "$workspace/encoded-iphone"
expect_failure no-video-encode 'no-video does not take --encode' "$tool" decide --output "$decisions/empty/preview-decision.json" \
  --revision flower-r3 --decision no-video --reason 'やめる' --encode "$workspace/encoded-iphone"
for refused in bad bad-result bad-video no-final failed-final other-final other-clip swapped none empty; do
  [[ ! -e "$decisions/$refused/preview-decision.json" ]] || fail "a refused decision was recorded: $refused"
done
"$tool" check 2>/dev/null && fail 'unknown command accepted' || true
# A failing trial recording leads to no-video, with a reference to the trial's quality result.
"$repo_root/tools/record-appstore-preview.sh" check --clip "$workspace/rec-frozen/ja/iphone-6.3/02-seg2.mp4" --family iphone --seconds 6 \
  --output "$workspace/trial.json" >/dev/null 2>&1 || true
jq -e '.status == "failed"' "$workspace/trial.json" >/dev/null || fail 'the frozen trial did not fail the quality gate'
"$tool" decide --output "$decisions/no-video/preview-decision.json" --revision flower-r4 --decision no-video \
  --reason '試し録りで止まりがあった' --trial "$workspace/trial.json" >/dev/null || fail 'no-video decision failed'
jq -e --arg sha "sha256:$(shasum -a 256 "$workspace/trial.json" | cut -d' ' -f1)" '.decision == "no-video" and .trial.status == "failed" and .trial.sha256 == $sha
  and (has("video") | not) and .choice == "user-explicit" and .reason == "試し録りで止まりがあった"' \
  "$decisions/no-video/preview-decision.json" >/dev/null || fail 'no-video decision record is incomplete'
# no-video needs no trial: it can be chosen at the storyboard stage.
"$tool" decide --output "$decisions/early/preview-decision.json" --revision flower-r1 --decision no-video \
  --reason '絵コンテを見て動画なしにする' >/dev/null || fail 'an early no-video decision failed'
jq -e '.decision == "no-video" and (has("trial") | not) and .choice == "user-explicit"' "$decisions/early/preview-decision.json" >/dev/null ||
  fail 'early no-video decision record is incomplete'

# D-085 (#391): the product page header video. 3840x1646, 30 or 60 fps, 5 to 30 seconds, H.264, silent,
# and a loop with no visible seam; a recording placed outside the safe area is refused.
hv="$workspace/header-video"; mkdir -p "$hv"
ffmpeg -y -loglevel error -f lavfi -i "color=c=0xE9EFF5:s=3840x1646,format=rgb24" -frames:v 1 "$hv/background.png"
ffmpeg -y -loglevel error -f lavfi -i "color=c=0xE9EFF5:s=1920x1080,format=rgb24" -frames:v 1 "$hv/wide.png"
# A landscape recording whose colors turn over time, so its first and last frames differ clearly.
header_clip() { # path seconds fps
  ffmpeg -y -loglevel error -f lavfi -i "testsrc2=s=1200x500:r=$3:d=$2" -vf "hue=h=t*25" "${encode[@]}" "$1"
}
header_clip "$hv/clip8.mp4" 8 30
header_clip "$hv/clip6-60.mp4" 6 60
header_clip "$hv/clip4.mp4" 4 30
header_clip "$hv/clip32.mp4" 32 30
screen=0.3,0.304,0.4
"$tool" encode-header --background "$hv/background.png" --clip "$hv/clip8.mp4" --screen "$screen" --output "$hv/loop.mp4" >"$hv/loop.json"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0]))
  abort "header video: #{value}" unless value.values_at("status", "width", "height", "codec", "fps", "audio", "loop") == ["encoded", 3840, 1646, "h264", 30, false, "crossfade"] &&
    (value.fetch("durationSeconds") - 7.5).abs < 0.1 && value.fetch("seam") <= 6.0 && value.fetch("sha256").match?(/\Asha256:[0-9a-f]{64}\z/)' "$hv/loop.json"
[[ "$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$hv/loop.mp4")" == "" ]] || fail 'header video has an audio track'
"$tool" encode-header --background "$hv/background.png" --clip "$hv/clip6-60.mp4" --screen "$screen" --fps 60 --output "$hv/loop60.mp4" >"$hv/loop60.json"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); abort "60 fps header: #{value}" unless value.fetch("fps") == 60 && (value.fetch("durationSeconds") - 5.5).abs < 0.1' "$hv/loop60.json"
"$tool" encode-header --background "$hv/background.png" --seconds 5 --output "$hv/still.mp4" >"$hv/still.json"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); abort "still header: #{value}" unless value.fetch("seam") == 0.0 && value.fetch("fps") == 30' "$hv/still.json"
# The video check uses the same safe area as the render extension measured from Apple's template.
"$repo_root/tools/appstore-creative-render.sh" describe-header >"$hv/describe.json"
ruby -rjson -e 'render = JSON.parse(File.read(ARGV[0])).fetch("safeArea"); video = JSON.parse(File.read(ARGV[1])).fetch("safeArea")
  abort "safe areas differ: #{render} #{video}" unless render.slice("x", "y", "width", "height") == video' "$hv/describe.json" "$hv/loop.json"
# Inputs outside the format are refused before anything is written.
expect_failure header-short 'the header video would run 3.50 seconds; a product page header runs 5 to 30 seconds' \
  "$tool" encode-header --background "$hv/background.png" --clip "$hv/clip4.mp4" --screen "$screen" --output "$hv/short.mp4"
expect_failure header-long 'the header video would run 31.50 seconds; a product page header runs 5 to 30 seconds' \
  "$tool" encode-header --background "$hv/background.png" --clip "$hv/clip32.mp4" --screen "$screen" --output "$hv/long.mp4"
expect_failure header-size 'header background is 1920x1080; a product page header is 3840x1646' \
  "$tool" encode-header --background "$hv/wide.png" --clip "$hv/clip8.mp4" --screen "$screen" --output "$hv/size.mp4"
expect_failure header-fps 'header fps must be 30 or 60' \
  "$tool" encode-header --background "$hv/background.png" --clip "$hv/clip8.mp4" --screen "$screen" --fps 24 --output "$hv/fps.mp4"
expect_failure header-safe-area 'the clip on the header runs outside the safe area' \
  "$tool" encode-header --background "$hv/background.png" --clip "$hv/clip8.mp4" --screen 0.02,0.05,0.4 --output "$hv/outside.mp4"
# Without the crossfade the colors jump at the loop point, so the seam check refuses the video.
expect_failure header-seam 'the loop seam differs by' \
  "$tool" encode-header --background "$hv/background.png" --clip "$hv/clip8.mp4" --screen "$screen" --loop none --output "$hv/jump.mp4"
for refused in short long size fps outside jump; do [[ ! -e "$hv/$refused.mp4" ]] || fail "a refused header video was written: $refused"; done
before=$(shasum -a 256 "$hv/loop.mp4")
expect_failure header-overwrite 'output already exists and is never replaced' \
  "$tool" encode-header --background "$hv/background.png" --clip "$hv/clip8.mp4" --screen "$screen" --output "$hv/loop.mp4"
[[ "$(shasum -a 256 "$hv/loop.mp4")" == "$before" ]] || fail 'encode-header replaced an existing header video'
# verify-header checks a finished header video, for example one made elsewhere.
"$tool" verify-header --video "$hv/loop.mp4" | jq -e '.status == "valid" and .fps == 30 and .audio == false' >/dev/null || fail 'verify-header refused a valid header'
ffmpeg -y -loglevel error -i "$hv/loop.mp4" -f lavfi -i anullsrc=r=48000:cl=stereo -shortest -c:v copy -c:a aac "$hv/with-audio.mp4"
expect_failure header-audio 'it has an audio track; a header is silent by default' "$tool" verify-header --video "$hv/with-audio.mp4"
clip "$hv/portrait.mp4" 886x1920 6
expect_failure header-portrait 'size 886x1920 is not 3840x1646' "$tool" verify-header --video "$hv/portrait.mp4"

echo 'appstore-creative preview encode and decision tests passed'
