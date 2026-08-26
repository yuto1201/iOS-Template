#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-audio-skill.XXXXXX")
trap 'rm -rf -- "$test_workspace"' EXIT

skill_root="$repo_root/.agents/skills/ios-audio-assets"
validator="$skill_root/scripts/validate-audio.sh"
capability_check="$skill_root/scripts/check-elevenlabs-capability.sh"
fixture_repo="$test_workspace/app"
audio_directory="$fixture_repo/Resources/Audio"
mkdir -p "$audio_directory"

assert_fails() {
  local label=$1
  shift
  if "$@" >"$test_workspace/stdout" 2>"$test_workspace/stderr"; then
    echo "expected failure: $label" >&2
    exit 1
  fi
}

python3 - "$audio_directory/tone.wav" "$audio_directory/loop.wav" "$audio_directory/discontinuous.wav" <<'PY'
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

write_manifest() {
  local audio_relative=$1 audio_file=$2 loop_value=$3 threshold_value=$4 duration_value=$5
  local digest
  digest=$(printf 'sha256:%s' "$(/usr/bin/shasum -a 256 "$audio_file" | /usr/bin/awk '{print $1}')")
  cat > "$fixture_repo/audio-manifest.yml" <<EOF
schemaVersion: 1
purpose: "Confirm a successful in-app action"
prompt: "A soft tactile confirmation click without speech"
model: "eleven_text_to_sound_v2"
durationSeconds: $duration_value
loop: $loop_value
loopDiscontinuityThreshold: $threshold_value
format: "wav"
assetPath: "$audio_relative"
licenseNote: "Generated with ElevenLabs for this app asset"
sha256: "$digest"
generatedAt: "2026-08-26T06:20:00Z"
EOF
}

write_manifest Resources/Audio/tone.wav "$audio_directory/tone.wav" false null 1.0
validation_output=$("$validator" --root "$fixture_repo" --manifest audio-manifest.yml)
[[ "$validation_output" == *'"status":"valid"'* && "$validation_output" == *'"durationSeconds":1.0'* ]] || {
  echo "unexpected audio validation output: $validation_output" >&2
  exit 1
}

/usr/bin/sed -i '' 's/sha256:[0-9a-f]*/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$fixture_repo/audio-manifest.yml"
assert_fails 'audio hash mismatch' "$validator" --root "$fixture_repo" --manifest audio-manifest.yml
write_manifest Resources/Audio/tone.wav "$audio_directory/tone.wav" false null 2.0
assert_fails 'duration mismatch' "$validator" --root "$fixture_repo" --manifest audio-manifest.yml
write_manifest Resources/Audio/tone.wav "$audio_directory/tone.wav" false null 1.0
/usr/bin/sed -i '' 's/A soft tactile confirmation click without speech/xi-api-key: fixture-secret/' "$fixture_repo/audio-manifest.yml"
assert_fails 'API key pattern in manifest' "$validator" --root "$fixture_repo" --manifest audio-manifest.yml

write_manifest Resources/Audio/loop.wav "$audio_directory/loop.wav" true 0.01 1.0
"$validator" --root "$fixture_repo" --manifest audio-manifest.yml >/dev/null
write_manifest Resources/Audio/discontinuous.wav "$audio_directory/discontinuous.wav" true 0.01 1.0
assert_fails 'audible loop discontinuity' "$validator" --root "$fixture_repo" --manifest audio-manifest.yml

/bin/cp "$audio_directory/tone.wav" "$audio_directory/tone.txt"
write_manifest Resources/Audio/tone.txt "$audio_directory/tone.txt" false null 1.0
/usr/bin/sed -i '' 's/format: "wav"/format: "txt"/' "$fixture_repo/audio-manifest.yml"
assert_fails 'unsupported audio format' "$validator" --root "$fixture_repo" --manifest audio-manifest.yml

capability_root="$test_workspace/capabilities"
mkdir -p "$capability_root/generating-elevenlabs-audio"
cat > "$capability_root/generating-elevenlabs-audio/SKILL.md" <<'EOF'
---
name: generating-elevenlabs-audio
description: Generate ElevenLabs sound effects and music.
---
EOF
available=$(IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_SKILL_ROOTS="$capability_root" \
  "$capability_check" --capability sound-effect --provider-status available)
[[ "$available" == '{"capability":"sound-effect","source":"test","status":"available"}' ]] || {
  echo "unexpected capability response: $available" >&2
  exit 1
}

set +e
blocked=$(IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_SKILL_ROOTS="$capability_root" \
  "$capability_check" --capability music --provider-status paid_plan_required 2>"$test_workspace/capability-stderr")
blocked_status=$?
set -e
[[ "$blocked_status" -ne 0 && "$blocked" == '{"capability":"music","reason":"paid_plan_required","retry":false,"status":"blocked:ops"}' ]] || {
  echo "paid plan result was not one non-retried blocked record: $blocked" >&2
  exit 1
}
[[ ! -s "$test_workspace/capability-stderr" ]] || { echo 'paid plan result wrote duplicate diagnostics' >&2; exit 1; }
assert_fails 'missing Codex capability' env IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_SKILL_ROOTS="$test_workspace/missing" \
  "$capability_check" --capability sound-effect --provider-status available

[[ -L "$repo_root/.claude/skills/ios-audio-assets" ]] || { echo 'Claude audio skill link is missing' >&2; exit 1; }
[[ "$(readlink "$repo_root/.claude/skills/ios-audio-assets")" == '../../.agents/skills/ios-audio-assets' ]] || { echo 'Claude audio skill link target differs' >&2; exit 1; }
ruby -ryaml -e '
  text=File.binread(ARGV.fetch(0)); match=text.match(/\A---\n(.*?)\n---\n/m) or abort
  value=YAML.safe_load(match[1], permitted_classes: [], aliases: false)
  abort unless value.is_a?(Hash) && value.keys.sort == %w[description name]
  abort unless value["name"] == "ios-audio-assets" && value["description"].is_a?(String) && !value["description"].empty?
' "$skill_root/SKILL.md"

echo 'PASS: audio assets require the Codex ElevenLabs capability and validated manifest, media, hash, duration, and loop evidence'
