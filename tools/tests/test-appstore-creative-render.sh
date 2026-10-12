#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" node ffmpeg ruby shasum

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
tool="$repo_root/tools/appstore-creative-render.sh"
runtime="${GOLDIE_RUNTIME:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-goldie/0.3.1}"
pinned_goldie="$runtime/node_modules/goldie"
[[ -f "$pinned_goldie/package.json" ]] || { echo "pinned Goldie runtime is missing: $runtime (see .agents/skills/appstore-creative/references/config.md)" >&2; exit 1; }
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-creative-render.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT
fail() { echo "$*" >&2; exit 1; }

runtime_digest() { (cd "$pinned_goldie" && find dist assets package.json -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256); }
before_runtime=$(runtime_digest)

# Synthetic inputs: pure green captures (a color nothing else uses) for Goldie's own iPhone 6.9-inch and
# the D-079 iPhone 6.3-inch, red corner markers on the iPad capture, and a blue full-tile image for the
# concept tile.
ffmpeg -loglevel error -f lavfi -i "color=c=0x00FF00:s=1320x2868,format=rgb24" -frames:v 1 "$workspace/iphone-home.png"
ffmpeg -loglevel error -f lavfi -i "color=c=0x00FF00:s=1206x2622,format=rgb24" -frames:v 1 "$workspace/iphone63-home.png"
ffmpeg -loglevel error -f lavfi -i "color=c=0x00FF00:s=2064x2752,format=rgb24" -frames:v 1 \
  -vf "drawbox=x=0:y=0:w=220:h=220:color=0xFF0000:t=fill,drawbox=x=1844:y=0:w=220:h=220:color=0xFF0000:t=fill,drawbox=x=0:y=2532:w=220:h=220:color=0xFF0000:t=fill,drawbox=x=1844:y=2532:w=220:h=220:color=0xFF0000:t=fill,format=rgb24" \
  "$workspace/ipad-home.png"
mkdir -p "$workspace/app/goldie/ja" "$workspace/app/goldie/assets"
ffmpeg -loglevel error -f lavfi -i "color=c=0x3366CC:s=1206x2622,format=rgb24" -frames:v 1 "$workspace/app/goldie/assets/concept.png"
# A two-tile strip: orange on the left tile, purple on the right one.
ffmpeg -loglevel error -f lavfi -i "color=c=0xFF8800:s=1206x2622,format=rgb24" -f lavfi -i "color=c=0x8800FF:s=1206x2622,format=rgb24" \
  -filter_complex "[0:v][1:v]hstack,format=rgb24" -frames:v 1 "$workspace/app/goldie/assets/strip.png"

write_config() { # path scenes-json [devices-json]
  local devices=${3:-'["iphone-6.3"]'}
  cat >"$1" <<EOF
const config = {
  appRoot: "$workspace/app", appPath: "$workspace/app/App.app", bundleId: "com.example.render",
  devices: $devices, locales: ["ja"], appearance: "light", frame: { variant: "17-pro-silver" },
  theme: { background: "#E9EFF5", headlineColor: "#111111", subheadColor: "#444444",
    fontFamily: '"Hiragino Sans", -apple-system, sans-serif', copyHeightRatio: 0.2, deviceWidthRatio: 0.84, layout: "classic" },
  store: { name: "Render", subtitle: { ja: "" }, developer: "", category: "", rating: 0, ratingCount: "", ageRating: "", price: "", description: { ja: "" } },
  scenes: $2
};
export default config;
EOF
}
write_manifest() { # config-dir device capture
  mkdir -p "$1/out/raw/$2"
  printf '{"device":"%s","udid":"","capturedAt":"","screenshots":[{"sceneId":"home","file":"%s"}],"preview":null}\n' "$2" "$3" >"$1/out/raw/$2/manifest.json"
}
pixels() { # png -> count of exact RGB pixels "r,g,b" inside an optional band (top fraction)
  local png=$1 rgb=$2 band=${3:-1}
  ffmpeg -loglevel error -i "$png" -f rawvideo -pix_fmt rgb24 - | ruby -e '
    width, height, rgb, band = ARGV[0].to_i, ARGV[1].to_i, ARGV[2].split(",").map(&:to_i).pack("C3"), ARGV[3].to_f
    data = $stdin.binmode.read; limit = (height * band).floor * width * 3; count = 0; i = 0
    while i < limit; count += 1 if data.byteslice(i, 3) == rgb; i += 3; end
    puts count' "$(ruby -e 'b=File.binread(ARGV[0]); print b[16,4].unpack1("N")' "$png")" \
                 "$(ruby -e 'b=File.binread(ARGV[0]); print b[20,4].unpack1("N")' "$png")" "$rgb" "$band"
}
quadrants_with_red() { # png -> number of image quadrants that contain a red marker pixel
  ffmpeg -loglevel error -i "$1" -f rawvideo -pix_fmt rgb24 - | ruby -e '
    width, height = ARGV[0].to_i, ARGV[1].to_i; data = $stdin.binmode.read; seen = {}
    (0...height).step(4) { |y| (0...width).step(4) { |x| i = (y * width + x) * 3
      r, g, b = data.getbyte(i), data.getbyte(i + 1), data.getbyte(i + 2)
      seen[[x < width / 2, y < height / 2]] = true if r > 200 && g < 60 && b < 60 } }
    puts seen.size' "$(ruby -e 'b=File.binread(ARGV[0]); print b[16,4].unpack1("N")' "$1")" "$(ruby -e 'b=File.binread(ARGV[0]); print b[20,4].unpack1("N")' "$1")"
}
png_info() { ruby -e 'b=File.binread(ARGV[0]); print "#{b[16,4].unpack1("N")}x#{b[20,4].unpack1("N")} color#{b.getbyte(25)}"' "$1"; }

# 1. A wrong Goldie version stops before anything is written.
fake="$workspace/fake-runtime"; mkdir -p "$fake/node_modules/goldie"
printf '{"name":"goldie","version":"0.3.2"}\n' >"$fake/node_modules/goldie/package.json"
config="$workspace/app/goldie/ja/goldie.config.mjs"
write_config "$config" '[{ kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "見出し" } }]' '["iphone-6.9"]'
if "$tool" render --runtime "$fake" --config "$config" --device iphone-6.9 --locale ja >"$workspace/version.out" 2>"$workspace/version.err"; then
  fail 'render accepted a Goldie runtime other than 0.3.1'
fi
grep -Fq 'Goldie runtime must be 0.3.1, found 0.3.2' "$workspace/version.err" || { cat "$workspace/version.err" >&2; fail 'unexpected version failure'; }
[[ ! -e "$workspace/app/goldie/ja/out/screenshots" ]] || fail 'version failure still rendered'

# 2. Goldie's own iPhone 6.9-inch layouts match Goldie's frame command pixel for pixel through the extension.
write_manifest "$workspace/app/goldie/ja" iphone-6.9 "$workspace/iphone-home.png"
GOLDIE_CONFIG="$config" node "$pinned_goldie/dist/cli.js" frame >/dev/null 2>"$workspace/cli.err" || { cat "$workspace/cli.err" >&2; fail 'Goldie frame failed'; }
cp "$workspace/app/goldie/ja/out/screenshots/iphone-6.9/ja/01-home.png" "$workspace/cli-home.png"
"$tool" render --runtime "$runtime" --config "$config" --device iphone-6.9 --locale ja >"$workspace/iphone.json"
raw_digest() { ffmpeg -loglevel error -i "$1" -f rawvideo -pix_fmt rgb24 - | shasum -a 256; }
[[ "$(raw_digest "$workspace/cli-home.png")" == "$(raw_digest "$workspace/app/goldie/ja/out/screenshots/iphone-6.9/ja/01-home.png")" ]] ||
  fail 'extension changed the pixels of an existing iPhone layout'

# 2b. D-079: the iPhone 6.3-inch tile is 1206x2622 without alpha and draws the capture inside Goldie's
# own iOS frame; describe reports its 886x1920 preview size.
write_manifest "$workspace/app/goldie/ja" iphone-6.3 "$workspace/iphone63-home.png"
write_config "$config" '[{ kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "見出し" } }]'
"$tool" render --runtime "$runtime" --config "$config" --device iphone-6.3 --locale ja >"$workspace/iphone63.json"
home63="$workspace/app/goldie/ja/out/screenshots/iphone-6.3/ja/01-home.png"
[[ "$(png_info "$home63")" == "1206x2622 color2" ]] || fail "iPhone 6.3-inch tile has the wrong size or an alpha channel: $(png_info "$home63")"
(( $(pixels "$home63" 0,255,0) > 100000 )) || fail 'iPhone 6.3-inch tile lost its capture'
(( $(pixels "$home63" 17,17,17 0.24) > 500 )) || fail 'iPhone 6.3-inch tile lost its headline'
"$tool" describe --runtime "$runtime" | ruby -rjson -e 'iphone = JSON.parse($stdin.read).fetch("iphone")
  abort "iPhone 6.3-inch sizes" unless iphone.fetch("screenshot") == {"width" => 1206, "height" => 2622} && iphone.fetch("preview") == {"width" => 886, "height" => 1920} && iphone.fetch("platform") == "ios"'

# 3. A concept tile draws the headline over its background image, with no device or capture.
write_config "$config" '[
  { kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "見出し" } },
  { kind: "screenshot", id: "art", flow: "store-ja-home", layout: "concept", headline: { ja: "空とともに" },
    backgroundImage: "../assets/concept.png" }]'
"$tool" render --runtime "$runtime" --config "$config" --device iphone-6.3 --locale ja >"$workspace/concept.json"
art="$workspace/app/goldie/ja/out/screenshots/iphone-6.3/ja/02-art.png"
[[ -f "$art" ]] || fail 'concept tile was not written'
[[ "$(png_info "$art")" == "1206x2622 color2" ]] || fail "concept tile has the wrong size or an alpha channel: $(png_info "$art")"
[[ "$(pixels "$art" 0,255,0)" == 0 ]] || fail 'concept tile drew the capture'
(( $(pixels "$workspace/app/goldie/ja/out/screenshots/iphone-6.3/ja/01-home.png" 0,255,0) > 100000 )) || fail 'device tile lost its capture'
(( $(pixels "$art" 51,102,204) > 1000000 )) || fail 'concept tile lost its background image'
(( $(pixels "$art" 17,17,17 0.24) > 500 )) || fail 'concept tile lost its headline'
ruby -rjson -e 'record = JSON.parse(File.read(ARGV[0]))
  abort "record version" unless record.fetch("goldieVersion") == "0.3.1"
  abort "record files" unless record.fetch("files").map { |file| File.basename(file.fetch("path")) } == %w[01-home.png 02-art.png]
  abort "record extensions" unless record.dig("extensions", "layouts", 0, "key") == "concept" && record.dig("extensions", "devices", "ipad-13", "preview") == {"width" => 1200, "height" => 1600} &&
    record.dig("extensions", "devices", "iphone-6.3", "screenshot") == {"width" => 1206, "height" => 2622}' \
  "$workspace/app/goldie/ja/out/creative-render-iphone-6.3-ja.json"

# 4. Background images sit under the headline and the device, and a strip runs across tiles.
write_config "$config" '[
  { kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "雨の日も" }, backgroundImage: { src: "../assets/strip.png", strip: 2, index: 0 } },
  { kind: "screenshot", id: "next", flow: "store-ja-home", layout: "concept", headline: { ja: "風の日も" }, backgroundImage: { src: "../assets/strip.png", strip: 2, index: 1 } }]'
"$tool" render --runtime "$runtime" --config "$config" --device iphone-6.3 --locale ja >"$workspace/strip.json"
left="$workspace/app/goldie/ja/out/screenshots/iphone-6.3/ja/01-home.png"
right="$workspace/app/goldie/ja/out/screenshots/iphone-6.3/ja/02-next.png"
[[ "$(png_info "$left")" == "1206x2622 color2" && "$(png_info "$right")" == "1206x2622 color2" ]] || fail 'background tiles have the wrong size or alpha'
(( $(pixels "$left" 17,17,17 0.24) > 500 )) || fail 'background image hid the headline'
(( $(pixels "$left" 0,255,0) > 100000 )) || fail 'background image hid the device'
(( $(pixels "$left" 255,136,0) > 100000 )) && [[ "$(pixels "$left" 136,0,255)" == 0 ]] || fail 'first strip tile shows the wrong slice'
(( $(pixels "$right" 136,0,255) > 1000000 )) && [[ "$(pixels "$right" 255,136,0)" == 0 ]] || fail 'second strip tile shows the wrong slice'
write_config "$config" '[{ kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "x" }, backgroundImage: { src: "../assets/strip.png", strip: 2, index: 2 } }]'
if "$tool" render --runtime "$runtime" --config "$config" --device iphone-6.3 --locale ja >/dev/null 2>"$workspace/strip-past.err"; then
  fail 'render accepted a background slice past its strip'
fi
grep -Fq 'runs past its strip of 2 tiles' "$workspace/strip-past.err" || { cat "$workspace/strip-past.err" >&2; fail 'unexpected strip failure'; }

# 5. iPad tiles are 2064x2752 without alpha and keep the whole capture inside the bare screen.
write_manifest "$workspace/app/goldie/ja" ipad-13 "$workspace/ipad-home.png"
write_config "$config" '[{ kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "iPadでも" } }]' '["ipad-13"]'
"$tool" render --runtime "$runtime" --config "$config" --device ipad-13 --locale ja >"$workspace/ipad.json"
ipad="$workspace/app/goldie/ja/out/screenshots/ipad-13/ja/01-home.png"
[[ "$(png_info "$ipad")" == "2064x2752 color2" ]] || fail "iPad tile has the wrong size or an alpha channel: $(png_info "$ipad")"
[[ "$(quadrants_with_red "$ipad")" == 4 ]] || fail 'iPad tile cropped a corner of the capture'
(( $(pixels "$ipad" 0,255,0) > 100000 )) || fail 'iPad tile lost its capture'
"$tool" describe --runtime "$runtime" | ruby -rjson -e 'ipad = JSON.parse($stdin.read).fetch("ipad")
  abort "iPad preview size" unless ipad.fetch("preview") == {"width" => 1200, "height" => 1600}'

# 6. The installed runtime is never written to.
[[ "$(runtime_digest)" == "$before_runtime" ]] || fail 'render changed the installed Goldie runtime'

echo 'appstore-creative render extension tests passed'
