#!/bin/bash
set -euo pipefail

# D-090: ios-design-image-asset is the repository adapter over the shared Mac skill. It keeps the gates for this
# repository (when it may be used, verification, evidence) and leaves the authoring procedures to the
# shared skill, which this test does not require to exist.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" python3 ruby /usr/bin/xcrun

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)

[[ -L "$repo_root/.claude/skills/ios-design-image-asset" &&
   "$(readlink "$repo_root/.claude/skills/ios-design-image-asset")" == "../../.agents/skills/ios-design-image-asset" ]] || {
  echo "Claude alias for ios-design-image-asset must point to the shared skill" >&2
  exit 1
}

python3 - "$repo_root/.agents/skills/ios-design-image-asset/SKILL.md" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.match(r"\A---\n(.*?)\n---\n", text, re.S)
if not match:
    sys.exit("ios-design-image-asset: frontmatter is missing")
keys = [line.split(":", 1)[0] for line in match.group(1).splitlines() if line and not line.startswith(" ")]
if keys != ["name", "description"] or "name: ios-design-image-asset\n" not in match.group(0):
    sys.exit("ios-design-image-asset: frontmatter must hold exactly name and description")
required = (
    "`design-image-asset`",
    "`~/.agents/skills/design-image-asset/`",
    "this adapter, D-090, and `AGENTS.md` take precedence over the shared skill",
    "stop as `blocked:environment` before authoring",
    "`codex`, `vector`, or `elevenlabs`",
    "built-in `image_gen`",
    "Never draw text into the image",
    "Light and Dark",
    "maximum file size",
    "rights",
    "validate-visual.sh",
    "`image`",
    "PNG",
    "`blocked:user`",
    "[`app-icon`](../app-icon/SKILL.md)",
    "`appstore-creative`",
    "`ios-design-2d-asset`",
    "`ios-design-3d-asset`",
    "`transparency`",
    "`cutout`",
    "`edge-touching`",
    "`hasAlpha` only says the channel exists",
    "four corner pixels to have alpha 0",
    "`fringePixels`",
    "A checkerboard drawn into the image is not transparency",
    "WebP is not accepted",
)
failures = [f"ios-design-image-asset lacks {anchor!r}" for anchor in required if anchor not in text]
if len(text.splitlines()) > 90:
    failures.append("ios-design-image-asset must stay a thin adapter (90 lines or fewer)")
if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
PY

# #457: the PNG and MP4 manifest validator moved here from the audio adapter. ios-design-2d-asset uses it for video.
test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-image-skill.XXXXXX")
trap 'rm -rf -- "$test_workspace"' EXIT
visual_validator="$repo_root/.agents/skills/ios-design-image-asset/scripts/validate-visual.sh"
[[ -x "$visual_validator" && -f "$repo_root/.agents/skills/ios-design-image-asset/scripts/inspect-visual.swift" && -f "$repo_root/.agents/skills/ios-design-image-asset/templates/visual-manifest.yml" ]] || {
  echo "image adapter lacks the visual validator, inspector, or manifest template" >&2
  exit 1
}
fixture_repo="$test_workspace/app"
media_directory="$fixture_repo/Feature/Resources/Media"
mkdir -p "$media_directory"

assert_fails() {
  local label=$1
  shift
  if "$@" >"$test_workspace/stdout" 2>"$test_workspace/stderr"; then
    echo "expected failure: $label" >&2
    exit 1
  fi
}

python3 - "$media_directory/image.png" <<'PY'
import struct
import sys
import zlib

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

width, height = 2, 3
raw = b"".join(b"\x00" + b"\x20\x40\x60\xff" * width for _ in range(height))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
image_digest=$(printf 'sha256:%s' "$(/usr/bin/shasum -a 256 "$media_directory/image.png" | /usr/bin/awk '{print $1}')")
cat > "$fixture_repo/visual-manifest.yml" <<EOF
schemaVersion: 1
mode: "image"
purpose: "Create an approved decorative image"
prompt: "An original geometric gradient without text"
model: "fixture-image-model"
sourceDigests: []
widthPixels: 2
heightPixels: 3
durationSeconds: null
format: "png"
assetPath: "Feature/Resources/Media/image.png"
licenseNote: "Original generated fixture"
sha256: "$image_digest"
processedAt: "2026-08-29T00:00:00Z"
EOF
image_output=$("$visual_validator" --root "$fixture_repo" --manifest visual-manifest.yml)
[[ "$image_output" == *'"mode":"image"'* && "$image_output" == *'"status":"valid"'* ]] || { echo "unexpected image validation: $image_output" >&2; exit 1; }
/usr/bin/sed -i '' 's/widthPixels: 2/widthPixels: 4/' "$fixture_repo/visual-manifest.yml"
assert_fails 'image dimensions mismatch' "$visual_validator" --root "$fixture_repo" --manifest visual-manifest.yml

# #477: transparency. A manifest without the key means "none" (above). Each fixture row is a string of pixels:
# "." alpha 0, "#" opaque color, "w" white at alpha 128, "1" black at the smallest nonzero alpha (1/255 or
# 1/65535). An optional fourth argument 16 writes 16 bits per channel.
write_png() {
  python3 - "$media_directory/$1" "$2" "$3" "${4:-8}" <<'PY'
import struct
import sys
import zlib

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

path, color_type, rows, depth = sys.argv[1], int(sys.argv[2]), sys.argv[3].split("/"), int(sys.argv[4])
top = (1 << depth) - 1
levels = {".": (0, 0, 0, 0), "#": (0x20, 0x40, 0x60, 255), "w": (255, 255, 255, 128), "1": (0, 0, 0, None)}
def sample(pixel):
    values = [round(value * top / 255) if value is not None else 1 for value in levels[pixel]]
    return b"".join(value.to_bytes(depth // 8, "big") for value in values)
size = 4 if color_type == 6 else 3
raw = b"".join(b"\x00" + b"".join(b"".join(sample(p)[i * depth // 8:(i + 1) * depth // 8] for i in range(size)) for p in row) for row in rows)
header = struct.pack(">IIBBBBB", len(rows[0]), len(rows), depth, color_type, 0, 0, 0)
open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PY
}

write_transparency_manifest() {
  local file=$1 width=$2 height=$3 transparency=$4 digest
  digest=$(printf 'sha256:%s' "$(/usr/bin/shasum -a 256 "$media_directory/$file" | /usr/bin/awk '{print $1}')")
  cat > "$fixture_repo/visual-manifest.yml" <<EOF
schemaVersion: 1
mode: "image"
purpose: "Create an approved transparent image"
prompt: "An original geometric cutout without text"
model: "fixture-image-model"
sourceDigests: []
widthPixels: $width
heightPixels: $height
durationSeconds: null
format: "png"
transparency: "$transparency"
assetPath: "Feature/Resources/Media/$file"
licenseNote: "Original generated fixture"
sha256: "$digest"
processedAt: "2026-08-29T00:00:00Z"
EOF
}

validate_visual() {
  "$visual_validator" --root "$fixture_repo" --manifest visual-manifest.yml 2>"$test_workspace/stderr"
}

expect_rejected() {
  local label=$1 reason=$2
  assert_fails "$label" "$visual_validator" --root "$fixture_repo" --manifest visual-manifest.yml
  grep -Fq "$reason" "$test_workspace/stderr" || { echo "$label: expected '$reason'" >&2; cat "$test_workspace/stderr" >&2; exit 1; }
}

write_transparency_manifest image.png 2 3 none
output=$(validate_visual)
[[ "$output" == "$image_output" ]] || { echo "explicit none changed the image result: $output" >&2; exit 1; }
write_transparency_manifest image.png 2 3 cutout
expect_rejected 'opaque RGBA as cutout' 'image is fully opaque'
write_transparency_manifest image.png 2 3 edge-touching
expect_rejected 'opaque RGBA as edge-touching' 'image is fully opaque'
write_transparency_manifest image.png 2 3 shadow
expect_rejected 'unknown transparency' 'transparency is invalid'

write_png rgb.png 2 '##/##'
write_transparency_manifest rgb.png 2 2 cutout
expect_rejected 'RGB without alpha as cutout' 'image has no alpha channel'

write_png cutout.png 6 '..../.##./.##./....'
write_transparency_manifest cutout.png 4 4 cutout
output=$(validate_visual)
[[ "$output" == *'"status":"valid"'* && "$output" == *'"transparency":"cutout"'* && "$output" == *'"transparentCorners":4'* && "$output" == *'"fringePixels":0'* ]] || { echo "unexpected cutout validation: $output" >&2; exit 1; }
[[ ! -s "$test_workspace/stderr" ]] || { echo 'a clean cutout must not warn' >&2; exit 1; }

write_png corner.png 6 '...#/.##./.##./....'
write_transparency_manifest corner.png 4 4 cutout
expect_rejected 'opaque corner as cutout' 'cutout corners are not fully transparent'
write_transparency_manifest corner.png 4 4 edge-touching
output=$(validate_visual)
[[ "$output" == *'"status":"valid"'* && "$output" == *'"transparency":"edge-touching"'* && "$output" == *'"transparentCorners":3'* ]] || { echo "unexpected edge-touching validation: $output" >&2; exit 1; }

write_png fringe.png 6 '...../.www./.w#w./.www./.....'
write_transparency_manifest fringe.png 5 5 cutout
output=$(validate_visual)
[[ "$output" == *'"status":"valid"'* && "$output" == *'"fringePixels":8'* && "$output" == *'"fringeRatio":0.32'* ]] || { echo "unexpected fringe validation: $output" >&2; exit 1; }
grep -Fq 'visual validation warning: 8 semi-transparent near-white fringe pixels' "$test_workspace/stderr" || { echo 'fringe must warn' >&2; exit 1; }

# A 16-bit PNG keeps its exact alpha: a corner at alpha 1/65535 is not transparent, and alpha 0 corners are.
write_png cutout16.png 6 '..../.##./.##./....' 16
write_transparency_manifest cutout16.png 4 4 cutout
output=$(validate_visual)
[[ "$output" == *'"status":"valid"'* && "$output" == *'"transparentCorners":4'* ]] || { echo "unexpected 16-bit cutout validation: $output" >&2; exit 1; }
write_png faint16.png 6 '...1/.##./.##./....' 16
write_transparency_manifest faint16.png 4 4 cutout
expect_rejected '16-bit corner at alpha 1/65535 as cutout' 'cutout corners are not fully transparent'
write_png faint8.png 6 '1.../.##./.##./....'
write_transparency_manifest faint8.png 4 4 cutout
expect_rejected '8-bit corner at alpha 1/255 as cutout' 'cutout corners are not fully transparent'

/usr/bin/xcrun swift "$repo_root/tools/tests/helpers/create-test-video.swift" "$media_directory/video.mp4"
video_digest=$(printf 'sha256:%s' "$(/usr/bin/shasum -a 256 "$media_directory/video.mp4" | /usr/bin/awk '{print $1}')")
cat > "$fixture_repo/visual-manifest.yml" <<EOF
schemaVersion: 1
mode: "video"
purpose: "Create an approved motion fixture"
prompt: "An original neutral motion test"
model: "fixture-video-model"
sourceDigests: []
widthPixels: 160
heightPixels: 90
durationSeconds: 1.0
format: "mp4"
assetPath: "Feature/Resources/Media/video.mp4"
licenseNote: "Original generated fixture"
sha256: "$video_digest"
processedAt: "2026-08-29T00:00:00Z"
EOF
video_output=$("$visual_validator" --root "$fixture_repo" --manifest visual-manifest.yml)
[[ "$video_output" == *'"mode":"video"'* && "$video_output" == *'"status":"valid"'* ]] || { echo "unexpected video validation: $video_output" >&2; exit 1; }
/usr/bin/sed -i '' 's/^format: "mp4"$/format: "mp4"\
transparency: "none"/' "$fixture_repo/visual-manifest.yml"
[[ "$("$visual_validator" --root "$fixture_repo" --manifest visual-manifest.yml)" == "$video_output" ]] || { echo 'explicit none changed the video result' >&2; exit 1; }
/usr/bin/sed -i '' 's/^transparency: "none"$/transparency: "cutout"/' "$fixture_repo/visual-manifest.yml"
expect_rejected 'video with transparency' 'transparency is invalid'

echo "ios-design-image-asset adapter tests passed"
