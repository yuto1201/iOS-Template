#!/bin/bash
set -euo pipefail

# #434 (D-093): tools/appstore-creative-compose.sh draws App Store tiles from JSON declarations with
# headless Chromium. Every image is made inside the test; nothing is committed and no network is used.
# It checks the store sizes, the declared headline, device, popout and layer placement in the pixels,
# a popout centered on its region of a turned device within 2 px, the refusals (URLs, materials the
# user did not adopt or that changed, fonts outside brand.json or the allowed folders, a decoration limit
# outside the style), the render record that the proposal sheet reads as `renders`, the quality marks
# and the 220 px thumbnail sheet, and the reference sheet kept outside Git.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby python3 ffmpeg git shasum

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
tool="$repo_root/tools/appstore-creative-compose.sh"
chrome=${APPSTORE_CREATIVE_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}
if [[ ! -x "$chrome" ]]; then
  printf "test prerequisite unavailable (%s): missing headless Chromium at '%s'; see docs/verification.md (test prerequisites)\n" \
    "${0##*/}" "$chrome" >&2
  exit 69
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/appstore-creative-compose.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

fail() { echo "appstore-creative-compose: $*" >&2; exit 1; }
image() { ffmpeg -nostdin -loglevel error -y -f lavfi -i "color=c=$1:s=$2" ${3:+-vf "$3"} -frames:v 1 -pix_fmt rgb24 "$4"; }
expect_refused() {
  local label=$1 message=$2
  shift 2
  if "$@" >"$work/$label.out" 2>&1; then fail "$label was accepted"; fi
  grep -Fq -- "$message" "$work/$label.out" || { cat "$work/$label.out" >&2; fail "$label: unexpected message"; }
}

[[ -x "$tool" ]] || fail 'the tool must be executable'

# Inputs: a real capture stand-in with a magenta region, adopted and unadopted materials, brand.json.
mkdir -p "$work/app/goldie/assets" "$work/app/fonts"
image 0x3366CC 1206x2622 "drawbox=x=300:y=900:w=400:h=300:color=0xFF00FF:t=fill" "$work/app/capture.png"
image 0x22AA44 400x400 "" "$work/app/goldie/assets/leaf.png"
image 0xFF8800 300x300 "" "$work/app/goldie/assets/sun.png"
image 0xAA22AA 300x300 "" "$work/app/goldie/assets/rejected.png"
digest() { printf 'sha256:%s' "$(shasum -a 256 "$1" | cut -d' ' -f1)"; }
cat >"$work/app/goldie/assets/provenance.json" <<EOF
{"schemaVersion":1,"images":[
 {"file":"leaf.png","sha256":"$(digest "$work/app/goldie/assets/leaf.png")","materialReview":{"decision":"adopted"}},
 {"file":"sun.png","sha256":"$(digest "$work/app/goldie/assets/sun.png")","materialReview":{"decision":"adopted"}},
 {"file":"rejected.png","sha256":"$(digest "$work/app/goldie/assets/rejected.png")","materialReview":{"decision":"rejected"}}]}
EOF
printf '%s\n' '{"fonts":[{"role":"headline","family":"Hiragino Sans","source":"macOS","license":"system","paid":false},
  {"role":"body","family":"Sample Sans","source":"fixture","license":"fixture","paid":false}]}' >"$work/app/brand.json"
printf 'not a real font\n' >"$work/app/fonts/sample.ttf"
printf 'not a real font\n' >"$work/stray.ttf"

# Tile 1: a turned device that runs off the bottom, a cyan-bordered popout over the magenta region, a
# front layer over the device and a back layer under it. Tile 2: a weak tile for the quality marks.
cat >"$work/app/spec.json" <<'EOF'
{"schemaVersion":1,"device":"iphone-6.3","locale":"ja","style":"editorial","decorationLimit":3,
 "fonts":[{"family":"Hiragino Sans"}],
 "tiles":[{"id":"home","background":{"color":"#FFD60A","grain":0.04},
   "headline":{"lines":["給料日まで","あといくら？"],"size":130,"color":"#1C1C1E","top":150,"highlight":{"text":"あといくら","band":"#FFFFFF"}},
   "device":{"capture":"capture.png","width":930,"centerX":603,"top":700,"rotate":-4},
   "popouts":[{"region":[300,900,400,300],"scale":1.15,"rotate":5,"border":"#00FFFF"}],
   "layers":[{"src":"goldie/assets/leaf.png","x":1000,"y":1600,"width":300,"z":"front"},
             {"src":"goldie/assets/sun.png","x":150,"y":2000,"width":300,"z":"back"}]},
  {"id":"weak","background":{"gradient":{"from":"#202020","to":"#303030","angle":180}},
   "headline":{"lines":["短い"],"size":80,"color":"#333333","top":200},
   "device":{"capture":"capture.png","width":500,"centerX":603,"top":800},
   "layers":[{"src":"goldie/assets/leaf.png","x":200,"y":2200,"width":100,"z":"front"},
             {"src":"goldie/assets/leaf.png","x":400,"y":2200,"width":100,"z":"front"},
             {"src":"goldie/assets/sun.png","x":600,"y":2200,"width":100,"z":"front"},
             {"src":"goldie/assets/sun.png","x":800,"y":2200,"width":100,"z":"front"}]}]}
EOF
compose() { "$tool" compose --spec "$1" --brand "$work/app/brand.json" --provenance "$work/app/goldie/assets/provenance.json" --out "$2"; }
compose "$work/app/spec.json" "$work/out" >"$work/compose.json" || fail "compose failed: $(cat "$work/compose.json")"
record="$work/out/creative-render-iphone-6.3-ja.json"
[[ -f "$record" && -f "$work/out/tile-1.png" && -f "$work/out/tile-2.png" && -f "$work/out/thumbnails.png" ]] || fail 'the outputs are missing'

# A decoder for the RGB PNGs this test writes (8-bit, no interlace), with the checks on the pixels.
cat >"$work/pixels.py" <<'PY'
import json, math, struct, sys, zlib

def read(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, chunks = 8, {}
    idat = b""
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", body[:10])
            assert depth == 8 and color == 2, ("not 8-bit RGB", depth, color)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = width * 3
    rows, prev = [], bytearray(stride)
    for y in range(height):
        kind = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - 3] if x >= 3 else 0
            b = prev[x]
            c = prev[x - 3] if x >= 3 else 0
            if kind == 1: line[x] = (line[x] + a) & 255
            elif kind == 2: line[x] = (line[x] + b) & 255
            elif kind == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line
    return width, height, rows

def pixel(rows, x, y):
    row = rows[int(y)]
    return tuple(row[int(x) * 3:int(x) * 3 + 3])

def near(color, target, tolerance=40):
    return all(abs(a - b) <= tolerance for a, b in zip(color, target))

command = sys.argv[1]
if command == "size":
    width, height, _ = read(sys.argv[2])
    print(f"{width}x{height}")
elif command == "at":
    _, _, rows = read(sys.argv[2])
    print("%02X%02X%02X" % pixel(rows, int(sys.argv[3]), int(sys.argv[4])))
elif command == "near":
    # Chromium's color management moves colors by a few steps, so colors are compared within a tolerance.
    _, _, rows = read(sys.argv[2])
    target = tuple(int(sys.argv[5][i:i + 2], 16) for i in (0, 2, 4))
    sys.exit(0 if near(pixel(rows, int(sys.argv[3]), int(sys.argv[4])), target, 12) else 1)
elif command == "centroid":
    # The centroid of the pixels near a color, inside an optional box.
    _, height, rows = read(sys.argv[2])
    target = tuple(int(sys.argv[3][i:i + 2], 16) for i in (0, 2, 4))
    top = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    sx = sy = n = 0
    for y in range(top, height):
        row = rows[y]
        for x in range(len(row) // 3):
            if near(tuple(row[x * 3:x * 3 + 3]), target, 30):
                sx += x; sy += y; n += 1
    print(json.dumps({"x": sx / n if n else None, "y": sy / n if n else None, "n": n}))
PY
px() { python3 "$work/pixels.py" "$@"; }

# AC-3: store size, RGB without alpha, and the declared drawing.
[[ "$(px size "$work/out/tile-1.png")" == 1206x2622 ]] || fail 'tile 1 is not 1206x2622'
yellow=FFD60A
# The device runs off the bottom edge: the bottom row under its center is the frame or the screen, not the background.
! px near "$work/out/tile-1.png" 603 2620 "$yellow" || fail "the device does not run off the bottom ($(px at "$work/out/tile-1.png" 603 2620))"
# The front layer covers the device; the back layer is under the device where they overlap.
px near "$work/out/tile-1.png" 1000 1600 22AA44 || fail "the front layer is not drawn over the device ($(px at "$work/out/tile-1.png" 1000 1600))"
! px near "$work/out/tile-1.png" 280 2000 FF8800 || fail "the back layer is drawn over the device"
px near "$work/out/tile-1.png" 30 2000 FF8800 || fail "the back layer outside the device is missing ($(px at "$work/out/tile-1.png" 30 2000))"
# The headline is drawn at its size: two lines of 130 px at line height 1.2.
RECORD="$record" ruby -rjson -e '
  record = JSON.parse(File.read(ENV.fetch("RECORD")))
  lines = record.fetch("tiles")[0].fetch("metrics").fetch("lines")
  abort "headline lines #{lines}" unless lines.size == 2 && lines.all? { |box| (box["height"] - 156).abs <= 2 }
  abort "headline top" unless (lines[0]["top"] - 150).abs <= 2
' || fail 'the headline is not drawn as declared'
# The iPad size.
sed -e 's/"iphone-6.3"/"ipad-13"/' -e 's/"width":930,"centerX":603/"width":1500,"centerX":1032/' -e 's/"width":500,"centerX":603/"width":800,"centerX":1032/' \
  "$work/app/spec.json" >"$work/app/ipad.json"
compose "$work/app/ipad.json" "$work/ipad" >/dev/null || fail 'the iPad compose failed'
[[ "$(px size "$work/ipad/tile-1.png")" == 2064x2752 && -f "$work/ipad/creative-render-ipad-13-ja.json" ]] || fail 'the iPad tile is not 2064x2752'

# AC-4: the popout sits over its region on the turned device. The test carries the region's center
# through the device geometry itself and compares it with the cyan border's centroid in the pixels.
expected=$(python3 - <<'PY'
import math
width = 930.0; bezel = width * 0.034; screen = width - 2 * bezel
factor = screen / 1206.0; height = screen * 2622.0 / 1206.0 + 2 * bezel
left = 603 - width / 2; top = 700.0; cx, cy = left + width / 2, top + height / 2
px, py = left + bezel + (300 + 200) * factor, top + bezel + (900 + 150) * factor
a = math.radians(-4); dx, dy = px - cx, py - cy
print(f"{cx + dx * math.cos(a) - dy * math.sin(a):.3f} {cy + dx * math.sin(a) + dy * math.cos(a):.3f}")
PY
)
read -r expected_x expected_y <<<"$expected"
centroid=$(px centroid "$work/out/tile-1.png" 00FFFF 600)
CENTROID="$centroid" EX="$expected_x" EY="$expected_y" RECORD="$record" ruby -rjson -e '
  c = JSON.parse(ENV.fetch("CENTROID"))
  abort "no border pixels" unless c["n"] > 1000
  ex, ey = ENV.fetch("EX").to_f, ENV.fetch("EY").to_f
  abort "popout center #{c} vs #{ex},#{ey}" unless (c["x"] - ex).abs <= 2 && (c["y"] - ey).abs <= 2
  center = JSON.parse(File.read(ENV.fetch("RECORD"))).fetch("popouts")[0].fetch("center")
  abort "recorded center #{center}" unless (center[0] - ex).abs <= 0.5 && (center[1] - ey).abs <= 0.5
' || fail "the popout is not centered on its region: $centroid, expected $expected"
px near "$work/out/tile-1.png" "${expected_x%.*}" "${expected_y%.*}" FF00FF ||
  fail "the popout does not show the magnified region ($(px at "$work/out/tile-1.png" "${expected_x%.*}" "${expected_y%.*}"))"

# AC-5: the record lists inputs and outputs with SHA-256 and is accepted as `renders` by the proposal sheet.
RECORD="$record" OUT="$work/out" ruby -rjson -rdigest -e '
  record = JSON.parse(File.read(ENV.fetch("RECORD")))
  sha = ->(path) { "sha256:#{Digest::SHA256.file(path).hexdigest}" }
  abort "inventory" unless record["inputInventory"] == "complete-v1" && record["specSha256"] == sha.(record["spec"])
  record.fetch("files").each { |file| abort "file digest" unless file["sha256"] == sha.(file["path"]) }
  record.fetch("layers").each { |layer| abort "layer digest" unless layer["sha256"] == sha.(layer["src"]) }
  record.fetch("captures").each { |capture| abort "capture digest" unless capture["sha256"] == sha.(capture["path"]) }
  record.fetch("tiles").each { |tile| abort "html digest" unless tile["htmlSha256"] == sha.(tile["html"]) }
  abort "thumbnails digest" unless record.dig("thumbnails", "sha256") == sha.(record.dig("thumbnails", "path"))
' || fail 'the render record digests differ'
ruby -r"$repo_root/tools/lib/appstore-creative-sheet.rb" -e '
  index = AppStoreCreativeSheet.render_index([ARGV[0]], File.dirname(ARGV[0]))
  inputs = index.values.flatten.map { |entry| File.basename(entry["path"]) }.uniq.sort
  abort "render index #{inputs}" unless index.size == 2 && inputs == %w[leaf.png sun.png]
' "$record" || fail 'the proposal sheet does not read the record as renders'
# No network: every page allows only file and data URLs, names no remote resource, and a URL is refused.
for page in "$work/out/html/"*.html; do
  grep -Fq "default-src 'none'" "$page" || fail "$(basename "$page") has no content security policy"
  ! grep -Eq "(src=|url\\()[\"']?https?:" "$page" || fail "$(basename "$page") names a remote resource"
done
url_spec() { sed -e "s#$1#$2#" "$work/app/spec.json" >"$work/app/$3.json"; }
url_spec '"capture.png","width":930' '"https://example.com/capture.png","width":930' url-capture
expect_refused url-capture 'must be a local file, not a URL' compose "$work/app/url-capture.json" "$work/r1"
url_spec 'goldie/assets/leaf.png","x":1000' 'file:///etc/hosts","x":1000' url-layer
expect_refused url-layer 'must be a local file, not a URL' compose "$work/app/url-layer.json" "$work/r2"
# Materials the user did not adopt, or changed after adopting, are refused.
url_spec 'goldie/assets/leaf.png","x":1000' 'goldie/assets/rejected.png","x":1000' rejected
expect_refused rejected 'is not an adopted material in provenance.json' compose "$work/app/rejected.json" "$work/r3"
cp "$work/app/capture.png" "$work/app/loose.png"
url_spec 'goldie/assets/leaf.png","x":1000' 'loose.png","x":1000' loose
expect_refused loose 'is not an adopted material in provenance.json' compose "$work/app/loose.json" "$work/r4"
cp "$work/app/goldie/assets/sun.png" "$work/sun.orig"
image 0xFF0000 300x300 "" "$work/app/goldie/assets/sun.png"
expect_refused changed 'changed after it was adopted' compose "$work/app/spec.json" "$work/r5"
cp "$work/sun.orig" "$work/app/goldie/assets/sun.png"
# Fonts: a family outside brand.json, and a file outside the allowed folders, are refused; one in fonts/ is read.
url_spec '"fonts":\[{"family":"Hiragino Sans"}\]' '"fonts":[{"family":"Unlisted Sans"}]' font-family
expect_refused font-family 'is not a brand.json font' compose "$work/app/font-family.json" "$work/r6"
url_spec '"fonts":\[{"family":"Hiragino Sans"}\]' "\"fonts\":[{\"family\":\"Sample Sans\",\"file\":\"$work/stray.ttf\"}]" font-stray
expect_refused font-stray 'is outside the allowed font folders' compose "$work/app/font-stray.json" "$work/r7"
url_spec '"fonts":\[{"family":"Hiragino Sans"}\]' '"fonts":[{"family":"Sample Sans","file":"fonts/sample.ttf"}]' font-ok
compose "$work/app/font-ok.json" "$work/font-ok" >/dev/null || fail 'a brand font in fonts/ was refused'
grep -Fq 'sample.ttf' "$work/font-ok/html/tile-1.html" || fail 'the allowed font file is not used'
# An existing output folder is never replaced.
expect_refused existing-out 'must be a new folder' compose "$work/app/spec.json" "$work/out"

# AC-6: the decoration limit follows the style, and the quality bar marks the weak tile only.
url_spec '"decorationLimit":3' '"decorationLimit":6' editorial-six
expect_refused editorial-six 'decorationLimit of a editorial style must be 2..5' compose "$work/app/editorial-six.json" "$work/r8"
url_spec '"style":"editorial","decorationLimit":3' '"style":"minimal","decorationLimit":1' minimal-one
expect_refused minimal-one 'decorationLimit of a minimal style must be 0..0' compose "$work/app/minimal-one.json" "$work/r9"
RECORD="$record" ruby -rjson -e '
  tiles = JSON.parse(File.read(ENV.fetch("RECORD"))).fetch("tiles")
  abort "tile 1 marks #{tiles[0]["marks"]}" unless tiles[0]["marks"].empty?
  marks = tiles[1]["marks"].join("\n")
  ["the device fills", "the headline spans", "an empty band of", "headline contrast is", "4 decorations; the editorial style allows 3"].each do |text|
    abort "tile 2 lacks #{text}: #{marks}" unless marks.include?(text)
  end
' || fail 'the quality marks differ'
[[ "$(px size "$work/out/thumbnails.png")" == "$((2 * 244 + 24))x$(( (220 * 2622 + 1205) / 1206 + 48 ))" ]] ||
  fail "the thumbnail sheet is $(px size "$work/out/thumbnails.png")"

# AC-7: reference images are laid out per app (first five), beside the proposal, and never inside Git.
for app in alpha beta; do
  mkdir -p "$work/refs/$app"
  for n in 1 2 3 4 5 6; do image 0x88$((n + 1))0C0 600x1300 "" "$work/refs/$app/$n.png"; done
done
"$tool" research-sheet --refs "$work/refs" --mine "$work/out" --out "$work/research" >/dev/null || fail 'the research sheet failed'
RESEARCH="$work/research/research-sheet.json" ruby -rjson -e '
  rows = JSON.parse(File.read(ENV.fetch("RESEARCH"))).fetch("rows")
  abort "rows #{rows.map { |row| [row["label"], row["images"].size] }}" unless rows.map { |row| [row["label"], row["images"].size] } == [["alpha", 5], ["beta", 5], ["proposal", 2]]
  abort "sixth image used" if rows.any? { |row| row["images"].any? { |image| File.basename(image["path"]) == "6.png" } }
' || fail 'the research sheet rows differ'
git init -q "$work/repo"
expect_refused research-in-git 'is inside the Git working tree' "$tool" research-sheet --refs "$work/refs" --out "$work/repo/refs-sheet"
printf 'refs-sheet/\n' >"$work/repo/.gitignore"
"$tool" research-sheet --refs "$work/refs" --out "$work/repo/refs-sheet" >/dev/null || fail 'an ignored folder was refused'

echo "appstore-creative compose tests passed"
