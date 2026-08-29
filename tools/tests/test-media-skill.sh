#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-media-skill.XXXXXX")
trap 'rm -rf -- "$test_workspace"' EXIT

skill_root="$repo_root/.agents/skills/ios-media-assets"
audio_validator="$skill_root/scripts/validate-audio.sh"
transcript_validator="$skill_root/scripts/validate-transcript.sh"
visual_validator="$skill_root/scripts/validate-visual.sh"
capability_check="$skill_root/scripts/check-elevenlabs-capability.sh"
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

python3 - "$media_directory/tone.wav" "$media_directory/loop.wav" "$media_directory/discontinuous.wav" <<'PY'
import math
import struct
import sys
import wave

rate = 44100

def write(path, samples):
    with wave.open(path, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(b"".join(struct.pack("<h", sample) for sample in samples))

write(sys.argv[1], [int(1200 * math.sin(2 * math.pi * 440 * index / rate)) for index in range(rate)])
write(sys.argv[2], [0 for _ in range(rate)])
samples = [0 for _ in range(rate)]
samples[-1000:] = [28000 for _ in range(1000)]
write(sys.argv[3], samples)
PY

write_audio_manifest() {
  local mode=$1 relative=$2 audio_file=$3 loop_value=$4 threshold_value=$5 duration_value=$6 source_value=$7 voice_value=$8
  local digest
  digest=$(printf 'sha256:%s' "$(/usr/bin/shasum -a 256 "$audio_file" | /usr/bin/awk '{print $1}')")
  cat > "$fixture_repo/audio-manifest.yml" <<EOF
schemaVersion: 2
mode: "$mode"
purpose: "Confirm a successful in-app action"
requestSummary: "A soft tactile confirmation without credentials"
model: "fixture-model"
sourceSha256: $source_value
voiceId: $voice_value
durationSeconds: $duration_value
loop: $loop_value
loopDiscontinuityThreshold: $threshold_value
format: "wav"
assetPath: "$relative"
licenseNote: "Generated or processed with ElevenLabs for this app asset"
sha256: "$digest"
processedAt: "2026-08-29T00:00:00Z"
EOF
}

write_audio_manifest sound-effect Feature/Resources/Media/tone.wav "$media_directory/tone.wav" false null 1.0 null null
audio_output=$("$audio_validator" --root "$fixture_repo" --manifest audio-manifest.yml)
[[ "$audio_output" == *'"mode":"sound-effect"'* && "$audio_output" == *'"status":"valid"'* ]] || { echo "unexpected audio validation: $audio_output" >&2; exit 1; }

/usr/bin/sed -i '' 's/sha256:[0-9a-f]*/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$fixture_repo/audio-manifest.yml"
assert_fails 'audio hash mismatch' "$audio_validator" --root "$fixture_repo" --manifest audio-manifest.yml
write_audio_manifest text-to-speech Feature/Resources/Media/tone.wav "$media_directory/tone.wav" false null 1.0 null '"fixture-voice"'
"$audio_validator" --root "$fixture_repo" --manifest audio-manifest.yml >/dev/null
write_audio_manifest audio-isolation Feature/Resources/Media/tone.wav "$media_directory/tone.wav" false null 1.0 null null
assert_fails 'missing isolation source digest' "$audio_validator" --root "$fixture_repo" --manifest audio-manifest.yml
write_audio_manifest sound-effect Feature/Resources/Media/loop.wav "$media_directory/loop.wav" true 0.01 1.0 null null
"$audio_validator" --root "$fixture_repo" --manifest audio-manifest.yml >/dev/null
write_audio_manifest sound-effect Feature/Resources/Media/discontinuous.wav "$media_directory/discontinuous.wav" true 0.01 1.0 null null
assert_fails 'audible loop discontinuity' "$audio_validator" --root "$fixture_repo" --manifest audio-manifest.yml

printf '%s\n' '{"language_code":"en","text":"Welcome to the app","words":[]}' > "$media_directory/transcript.json"
transcript_digest=$(printf 'sha256:%s' "$(/usr/bin/shasum -a 256 "$media_directory/transcript.json" | /usr/bin/awk '{print $1}')")
cat > "$fixture_repo/transcript-manifest.yml" <<EOF
schemaVersion: 1
mode: "speech-to-text"
purpose: "Create approved captions"
model: "scribe_v2"
languageCode: "en"
sourceSha256: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
format: "json"
transcriptPath: "Feature/Resources/Media/transcript.json"
sha256: "$transcript_digest"
licenseNote: "The fixture source is consented"
processedAt: "2026-08-29T00:00:00Z"
EOF
transcript_output=$("$transcript_validator" --root "$fixture_repo" --manifest transcript-manifest.yml)
[[ "$transcript_output" == *'"mode":"speech-to-text"'* && "$transcript_output" == *'"status":"valid"'* ]] || { echo "unexpected transcript validation: $transcript_output" >&2; exit 1; }
printf '%s\n' '{"text":"api_key=fixture-secret"}' > "$media_directory/transcript.json"
assert_fails 'credential-like transcript' "$transcript_validator" --root "$fixture_repo" --manifest transcript-manifest.yml

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

for capability in text-to-speech speech-to-speech speech-to-text sound-effect audio-isolation music image video; do
  available=$("$capability_check" --capability "$capability" --provider-status available)
  [[ "$available" == "{\"capability\":\"$capability\",\"source\":\"repository\",\"status\":\"available\"}" ]] || { echo "unexpected capability response: $available" >&2; exit 1; }
done
set +e
blocked=$("$capability_check" --capability video --provider-status paid_plan_required 2>"$test_workspace/capability-stderr")
blocked_status=$?
set -e
[[ "$blocked_status" -eq 3 && "$blocked" == '{"capability":"video","reason":"paid_plan_required","retry":false,"status":"blocked:ops"}' ]] || { echo "unexpected paid-plan result: $blocked" >&2; exit 1; }
[[ ! -s "$test_workspace/capability-stderr" ]] || { echo 'paid-plan result wrote duplicate diagnostics' >&2; exit 1; }
assert_fails 'invalid capability' "$capability_check" --capability dubbing --provider-status available

[[ -L "$repo_root/.claude/skills/ios-media-assets" ]] || { echo 'Claude media skill link is missing' >&2; exit 1; }
[[ "$(readlink "$repo_root/.claude/skills/ios-media-assets")" == '../../.agents/skills/ios-media-assets' ]] || { echo 'Claude media skill link target differs' >&2; exit 1; }
[[ ! -e "$repo_root/.agents/skills/ios-audio-assets" && ! -e "$repo_root/.claude/skills/ios-audio-assets" ]] || { echo 'Overlapping audio skill remains' >&2; exit 1; }
ruby -ryaml -e '
  text=File.binread(ARGV.fetch(0)); match=text.match(/\A---\n(.*?)\n---\n/m) or abort
  value=YAML.safe_load(match[1], permitted_classes: [], aliases: false)
  abort unless value.is_a?(Hash) && value.keys.sort == %w[description name]
  abort unless value["name"] == "ios-media-assets" && value["description"].is_a?(String) && !value["description"].empty?
' "$skill_root/SKILL.md"

echo 'PASS: one shared media skill routes and validates eight conditional ElevenLabs modes without authenticated provider calls'
