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

# 7. D-085 (#394): image layers in front of and behind the device, art across the seam, a magnified
# piece of the real screen, a bare or cropped screen, a story across tiles, and the layer count.
# Layers are transparent PNGs with an opaque square in the middle.
ruby -rzlib -e '
  { "red" => [255, 0, 0], "blue" => [0, 0, 255], "magenta" => [255, 0, 255], "cyan" => [0, 255, 255] }.each do |name, rgb|
    rows = (0...400).map { |y| "\x00".b + (0...400).map { |x| (50...350).cover?(x) && (50...350).cover?(y) ? (rgb + [255]).pack("C4") : "\x00\x00\x00\x00".b }.join }
    chunk = ->(type, data) { [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N") }
    File.binwrite(File.join(ARGV[0], "#{name}.png"), "\x89PNG\r\n\x1A\n".b + chunk.("IHDR", [400, 400, 8, 6, 0, 0, 0].pack("N2C5")) +
      chunk.("IDAT", Zlib::Deflate.deflate(rows.join)) + chunk.("IEND", "".b))
  end' "$workspace/app/goldie/assets"
# A capture with a yellow card that the popout and the crop magnify.
ffmpeg -loglevel error -f lavfi -i "color=c=0x00FF00:s=1206x2622,format=rgb24" -frames:v 1 \
  -vf "drawbox=x=100:y=1500:w=400:h=300:color=0xFFFF00:t=fill,format=rgb24" "$workspace/iphone63-card.png"
capture_before=$(shasum -a 256 "$workspace/iphone63-card.png")
two_scene_manifest() {
  mkdir -p "$workspace/app/goldie/ja/out/raw/iphone-6.3"
  printf '{"device":"iphone-6.3","udid":"","capturedAt":"","screenshots":[{"sceneId":"home","file":"%s"},{"sceneId":"next","file":"%s"}],"preview":null}\n' \
    "$workspace/iphone63-card.png" "$workspace/iphone63-home.png" >"$workspace/app/goldie/ja/out/raw/iphone-6.3/manifest.json"
}
two_scene_manifest
render63() { "$tool" render --runtime "$runtime" --config "$config" --device iphone-6.3 --locale ja; }
expect_render_failure() { # label message
  if render63 >"$workspace/$1.out" 2>"$workspace/$1.err"; then fail "render accepted $1"; fi
  grep -Fq -- "$2" "$workspace/$1.err" || { cat "$workspace/$1.err" >&2; fail "unexpected failure for $1"; }
}
tile1="$workspace/app/goldie/ja/out/screenshots/iphone-6.3/ja/01-home.png"
tile2="$workspace/app/goldie/ja/out/screenshots/iphone-6.3/ja/02-next.png"
record63="$workspace/app/goldie/ja/out/creative-render-iphone-6.3-ja.json"

# 7a. A back layer sits under the device (hidden behind the screen), a front layer over it.
write_config "$config" '[
  { kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "雨の日も" },
    layers: [{ src: "../assets/red.png", position: "back", x: 0.45, y: 0.62, width: 0.08 },
             { src: "../assets/cyan.png", position: "back", x: 0.0, y: 0.5, width: 0.07 },
             { src: "../assets/blue.png", position: "front", x: 0.45, y: 0.62, width: 0.08, shadow: true }] },
  { kind: "screenshot", id: "next", flow: "store-ja-home", headline: { ja: "風の日も" } }]'
render63 >"$workspace/layers.json"
[[ "$(png_info "$tile1")" == "1206x2622 color2" ]] || fail "layered tile has the wrong size or an alpha channel: $(png_info "$tile1")"
[[ "$(pixels "$tile1" 255,0,0)" == 0 ]] || fail 'a back layer showed through the device'
(( $(pixels "$tile1" 0,255,255) > 2000 )) || fail 'a back layer beside the device was not drawn'
(( $(pixels "$tile1" 0,0,255) > 3000 )) || fail 'a front layer was not drawn over the device'
(( $(pixels "$tile1" 17,17,17 0.24) > 500 )) || fail 'layers hid the headline'
ruby -rjson -e 'record = JSON.parse(File.read(ARGV[0])); layers = record.fetch("layers")
  abort "layer record: #{layers}" unless layers.map { |layer| layer.values_at("scene", "position") } == [%w[home back], %w[home back], %w[home front]] &&
    layers.all? { |layer| layer.fetch("sha256").match?(/\Asha256:[0-9a-f]{64}\z/) && layer.fetch("tiles") == [1] }' "$record63"
# A back layer needs a background the tool can paint itself.
write_config "$config" '[{ kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "x" }, background: "linear-gradient(160deg, #1B3B6F 0%, #4E8CCB 100%)",
  layers: [{ src: "../assets/red.png", position: "back", x: 0.1, y: 0.7, width: 0.1 }] }]'
expect_render_failure back-gradient 'a back layer on home needs a backgroundImage or a #RRGGBB background'

# 7b. Art across the seam: up to 30% of a layer (40% for backgrounds and abstract shapes) may run into the
# next tile; a headline, face, key number or claim never crosses.
cross() { # x width role
  write_config "$config" "[
    { kind: \"screenshot\", id: \"home\", flow: \"store-ja-home\", headline: { ja: \"雨の日も\" },
      layers: [{ src: \"../assets/magenta.png\", position: \"front\", x: $1, y: 0.80, width: $2, role: \"$3\" }] },
    { kind: \"screenshot\", id: \"next\", flow: \"store-ja-home\", headline: { ja: \"風の日も\" } }]"
}
cross 0.85 0.2 decoration
render63 >"$workspace/cross.json"
(( $(pixels "$tile1" 255,0,255) > 2000 )) && (( $(pixels "$tile2" 255,0,255) > 200 )) || fail 'a layer across the seam did not continue on the next tile'
ruby -rjson -e 'layer = JSON.parse(File.read(ARGV[0])).fetch("layers").first
  abort "crossing record: #{layer}" unless layer.fetch("tiles") == [1, 2] && (layer.fetch("crossing") - 0.25).abs < 0.001' "$record63"
cross 0.9 0.2 decoration
expect_render_failure cross-too-far 'layer 1 of home crosses 50% into the next tile; at most 30%'
cross 0.87 0.2 abstract
render63 >/dev/null
cross 0.87 0.2 decoration
expect_render_failure cross-decoration 'layer 1 of home crosses 35% into the next tile; at most 30%'
cross 0.9 0.12 face
expect_render_failure cross-face 'layer 1 of home is marked face and must not cross a tile seam'
# The limits are settings of the config.
write_config "$config" '[
  { kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "雨の日も" },
    layers: [{ src: "../assets/magenta.png", position: "front", x: 0.9, y: 0.80, width: 0.2 }] },
  { kind: "screenshot", id: "next", flow: "store-ja-home", headline: { ja: "風の日も" } }]'
sed -i '' 's/layout: "classic" }/layout: "classic", crossTile: { max: 0.5, abstractMax: 0.6, protectedRoles: ["headline"] } }/' "$config"
render63 >/dev/null

# 7c. A popout magnifies a region of the real capture beside the device; the capture is never changed.
write_config "$config" '[
  { kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "カードで分かる" } },
  { kind: "screenshot", id: "next", flow: "store-ja-home", headline: { ja: "風の日も" } }]'
render63 >/dev/null
plain_yellow=$(pixels "$tile1" 255,255,0)
write_config "$config" '[
  { kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "カードで分かる" },
    popouts: [{ region: { x: 100, y: 1500, width: 400, height: 300 }, x: 0.04, y: 0.70, width: 0.5, radius: 24, shadow: true }] },
  { kind: "screenshot", id: "next", flow: "store-ja-home", headline: { ja: "風の日も" } }]'
render63 >"$workspace/popout.json"
(( $(pixels "$tile1" 255,255,0) > plain_yellow + 100000 )) || fail "the popout did not magnify the capture card ($plain_yellow before)"
[[ "$(shasum -a 256 "$workspace/iphone63-card.png")" == "$capture_before" ]] || fail 'the popout changed the raw capture'
ruby -rjson -rdigest -e 'popout = JSON.parse(File.read(ARGV[0])).fetch("popouts").first
  abort "popout record: #{popout}" unless popout.fetch("scene") == "home" && popout.fetch("capture") == File.expand_path(ARGV[1]) &&
    popout.fetch("captureSha256") == "sha256:#{Digest::SHA256.file(ARGV[1]).hexdigest}" &&
    popout.fetch("region") == {"x" => 100, "y" => 1500, "width" => 400, "height" => 300}' "$record63" "$workspace/iphone63-card.png"
write_config "$config" '[{ kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "x" },
  popouts: [{ region: { x: 1000, y: 1500, width: 400, height: 300 }, x: 0.04, y: 0.70, width: 0.5 }] }]'
expect_render_failure popout-region 'popout 1 of home region runs outside its 1206x2622 capture'

# 7d. The device frame is optional: the real device, a bare screen, or only part of the screen.
write_config "$config" '[
  { kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "画面だけ" }, frame: "bare" },
  { kind: "screenshot", id: "next", flow: "store-ja-home", headline: { ja: "一部だけ" }, frame: "crop",
    crop: { x: 100, y: 1500, width: 400, height: 300 }, screen: { x: 0.1, y: 0.4, width: 0.8 } }]'
sed -i '' "s|\"sceneId\":\"next\",\"file\":\"[^\"]*\"|\"sceneId\":\"next\",\"file\":\"$workspace/iphone63-card.png\"|" "$workspace/app/goldie/ja/out/raw/iphone-6.3/manifest.json"
render63 >"$workspace/frames.json"
[[ "$(png_info "$tile1")" == "1206x2622 color2" && "$(png_info "$tile2")" == "1206x2622 color2" ]] || fail 'bare or cropped tiles have the wrong size or alpha'
(( $(pixels "$tile1" 0,255,0) > 500000 )) || fail 'the bare screen lost its capture'
(( $(pixels "$tile2" 255,255,0) > 300000 )) && (( $(pixels "$tile2" 0,255,0) < 20000 )) || fail 'the cropped screen does not show only its region'
ruby -rjson -e 'screens = JSON.parse(File.read(ARGV[0])).fetch("screens")
  abort "screen record: #{screens}" unless screens.map { |screen| screen.values_at("scene", "frame") } == [%w[home bare], %w[next crop]] &&
    screens.last.fetch("region") == {"x" => 100, "y" => 1500, "width" => 400, "height" => 300}' "$record63"
two_scene_manifest
write_config "$config" '[{ kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "x" }, frame: "poster" }]'
expect_render_failure bad-frame 'frame of home must be device, bare or crop'

# 7e. A story: one sentence across tiles, split where the config says.
write_config "$config" '[
  { kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "仮" } },
  { kind: "screenshot", id: "next", flow: "store-ja-home", headline: { ja: "仮" } }]'
sed -i '' 's/layout: "classic" }/layout: "classic", stories: [{ scenes: ["home", "next"], text: { ja: "天気アプリは複雑すぎる。だから花に聞く。" }, breaks: { ja: [12] } }] }/' "$config"
render63 >"$workspace/story.json"
(( $(pixels "$tile1" 17,17,17 0.24) > 500 )) && (( $(pixels "$tile2" 17,17,17 0.24) > 500 )) || fail 'story tiles lost their headlines'
ruby -rjson -e 'story = JSON.parse(File.read(ARGV[0])).fetch("stories").first
  abort "story record: #{story}" unless story.fetch("scenes") == %w[home next] && story.fetch("parts").fetch("ja") == ["天気アプリは複雑すぎる。…", "…だから花に聞く。"]' "$record63"
sed -i '' 's/breaks: { ja: \[12\] }/breaks: { ja: [] }/' "$config"
expect_render_failure story-breaks 'story 1 needs 1 break for 2 scenes in ja; found 0'

# 7f. A tile with more visual layers than the guide (background, subject, headline, one accent) is marked.
write_config "$config" '[{ kind: "screenshot", id: "home", flow: "store-ja-home", headline: { ja: "多すぎる" },
  layers: [{ src: "../assets/blue.png", position: "front", x: 0.05, y: 0.75, width: 0.1 },
           { src: "../assets/cyan.png", position: "front", x: 0.2, y: 0.75, width: 0.1 },
           { src: "../assets/magenta.png", position: "front", x: 0.35, y: 0.75, width: 0.1 }] }]'
render63 >/dev/null
ruby -rjson -e 'marks = JSON.parse(File.read(ARGV[0])).fetch("marks")
  abort "layer marks: #{marks}" unless marks == ["tile 1 has 6 visual layers; the guide is 4"]' "$record63"

# 6. The installed runtime is never written to.
[[ "$(runtime_digest)" == "$before_runtime" ]] || fail 'render changed the installed Goldie runtime'

echo 'appstore-creative render extension tests passed'
