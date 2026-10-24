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

echo "ios-design-image-asset adapter tests passed"
