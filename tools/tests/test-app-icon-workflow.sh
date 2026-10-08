#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git jq ruby python3 /usr/bin/xcrun

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-app-icon.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT

skill="$repo_root/.agents/skills/app-icon/SKILL.md"
installer="$repo_root/tools/install-app-icon.sh"
validator="$repo_root/tools/validate-app-icon.sh"

assert_fails() {
  local label=$1
  shift
  if "$@" >"$workspace/stdout" 2>"$workspace/stderr"; then
    echo "expected failure: $label" >&2
    exit 1
  fi
}

make_png() {
  local path=$1 width=$2 height=$3 alpha=$4 red=$5
  python3 - "$path" "$width" "$height" "$alpha" "$red" <<'PY'
import struct
import sys
import zlib

path, width, height, alpha, red = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

pixel = bytes((red, 64, 96, alpha))
raw = b"".join(b"\x00" + pixel * width for _ in range(height))
png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw))
    + chunk(b"IEND", b"")
)
with open(path, "wb") as output:
    output.write(png)
PY
}

make_fixture() {
  local fixture=$1 branch=${2:-codex/123-app-icon}
  mkdir -p "$fixture/Config" "$fixture/GardenNotes/Assets.xcassets/AppIcon.appiconset"
  cat >"$fixture/Config/app-identity.json" <<'JSON'
{"appSlug":"garden-notes","bundleId":"com.yuto.GardenNotes","displayName":"Garden Notes","moduleName":"GardenNotes","schemaVersion":1,"sourceIdentityVersion":1}
JSON
  cat >"$fixture/GardenNotes/Assets.xcassets/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images" : [
    {
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
  git -C "$fixture" init -q -b main
  git -C "$fixture" config user.name fixture
  git -C "$fixture" config user.email fixture@example.invalid
  git -C "$fixture" add .
  git -C "$fixture" commit -qm fixture
  git -C "$fixture" switch -qc "$branch"
}

[[ -f "$skill" ]] || { echo 'app-icon skill is missing' >&2; exit 1; }
[[ -x "$installer" && -x "$validator" ]] || { echo 'app-icon tools are missing or not executable' >&2; exit 1; }
[[ -L "$repo_root/.claude/skills/app-icon" ]] || { echo 'Claude app-icon skill link is missing' >&2; exit 1; }
[[ "$(readlink "$repo_root/.claude/skills/app-icon")" == '../../.agents/skills/app-icon' ]] || { echo 'Claude app-icon skill link target differs' >&2; exit 1; }

ruby -ryaml -e '
  text=File.binread(ARGV.fetch(0)); match=text.match(/\A---\n(.*?)\n---\n/m) or abort
  value=YAML.safe_load(match[1], permitted_classes: [], aliases: false)
  abort unless value.is_a?(Hash) && value.keys.sort == %w[description name]
  abort unless value["name"] == "app-icon" && value["description"].is_a?(String) && !value["description"].empty?
' "$skill"

grep -Fq 'exactly two' "$skill"
grep -Fq 'built-in image generation' "$skill"
grep -Fq 'one centered recognizable subject' "$skill"
grep -Fq 'no text, initials' "$skill"
grep -Fq 'new immutable revision' "$skill"
grep -Fq 'does not satisfy the UI Direction Gate' "$skill"
grep -Fq 'separate from the initial App Icon Issue' "$skill"
grep -Fq -- '--replace-accepted' "$skill"
grep -Fq '"selection":"user-explicit"' "$skill"
grep -Fq 'explicitly confirms they hold the rights' "$skill"
grep -Fq 'Keep the reference image outside Git' "$skill"

valid_png="$workspace/valid.png"
alternate_png="$workspace/alternate.png"
transparent_png="$workspace/transparent.png"
wrong_size_png="$workspace/wrong-size.png"
prompt_file="$workspace/prompt.txt"
printf '%s\n' 'One centered leaf mark on a calm solid background; no text, no mask, no fine detail.' >"$prompt_file"
make_png "$valid_png" 1024 1024 255 32
make_png "$alternate_png" 1024 1024 255 200
make_png "$transparent_png" 1024 1024 128 32
make_png "$wrong_size_png" 1023 1024 255 32

fixture="$workspace/valid-app"
make_fixture "$fixture"
result=$("$installer" --root "$fixture" --source "$valid_png" --concept-id concept-a --prompt-file "$prompt_file" --generator builtin-imagegen)
[[ "$result" == *'"status":"applied"'* ]] || { echo "unexpected install result: $result" >&2; exit 1; }
asset="$fixture/GardenNotes/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
record="$fixture/Config/app-icon.json"
[[ -f "$asset" && -f "$record" ]] || { echo 'accepted icon or record is missing' >&2; exit 1; }

validation=$("$validator" --root "$fixture")
[[ "$validation" == *'"status":"valid"'* && "$validation" == *'"conceptId":"concept-a"'* ]] || {
  echo "unexpected validation result: $validation" >&2
  exit 1
}

python3 - "$fixture" <<'PY'
import hashlib
import json
import os
import sys

root = sys.argv[1]
record_path = os.path.join(root, "Config", "app-icon.json")
with open(record_path, encoding="utf-8") as source:
    record = json.load(source)
expected_keys = {
    "schemaVersion", "displayName", "conceptId", "promptSummary", "generator",
    "widthPixels", "heightPixels", "format", "assetPath", "sha256"
}
if set(record) != expected_keys:
    raise SystemExit(f"record keys differ: {sorted(record)}")
if record["displayName"] != "Garden Notes" or record["conceptId"] != "concept-a":
    raise SystemExit("record identity differs")
if record["generator"] != "builtin-imagegen" or record["widthPixels"] != 1024 or record["heightPixels"] != 1024:
    raise SystemExit("record generation metadata differs")
asset = os.path.join(root, record["assetPath"])
digest = "sha256:" + hashlib.sha256(open(asset, "rb").read()).hexdigest()
if record["sha256"] != digest:
    raise SystemExit("record digest differs")
with open(os.path.join(root, "GardenNotes", "Assets.xcassets", "AppIcon.appiconset", "Contents.json"), encoding="utf-8") as source:
    contents = json.load(source)
default = [entry for entry in contents["images"] if "appearances" not in entry]
if len(default) != 1 or default[0].get("filename") != "AppIcon-1024.png":
    raise SystemExit("default asset entry differs")
appearances = [entry for entry in contents["images"] if "appearances" in entry]
if len(appearances) != 2 or any("filename" in entry for entry in appearances):
    raise SystemExit("optional appearance entries were changed")
PY

before=$(git -C "$fixture" status --porcelain=v1 | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
rerun=$("$installer" --root "$fixture" --source "$valid_png" --concept-id concept-a --prompt-file "$prompt_file" --generator builtin-imagegen)
after=$(git -C "$fixture" status --porcelain=v1 | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
[[ "$rerun" == *'"status":"already-complete"'* && "$before" == "$after" ]] || { echo 'same-input rerun was not idempotent' >&2; exit 1; }
accepted_digest=$(/usr/bin/shasum -a 256 "$asset" | /usr/bin/awk '{print $1}')
assert_fails 'conflicting accepted icon' "$installer" --root "$fixture" --source "$alternate_png" --concept-id concept-b --prompt-file "$prompt_file" --generator builtin-imagegen
[[ "$(/usr/bin/shasum -a 256 "$asset" | /usr/bin/awk '{print $1}')" == "$accepted_digest" ]] || { echo 'conflicting input replaced the accepted icon' >&2; exit 1; }

# Replacement of an accepted icon requires the declared accepted digest, an explicit selection record in a
# new immutable revision, the selected candidate bytes, a clean worktree, and rights for any reference image.
sha_of() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print "sha256:" $1}'; }
write_selection() {
  local directory=$1 revision=$2 selected=$3 selection=${4:-user-explicit}
  shift 4
  python3 - "$directory/selection.json" "$revision" "$selected" "$selection" "$@" <<'PY'
import hashlib
import json
import os
import sys

path, revision, selected, selection = sys.argv[1:5]
candidates = []
for candidate in sys.argv[5:]:
    concept = os.path.splitext(os.path.basename(candidate))[0]
    digest = "sha256:" + hashlib.sha256(open(candidate, "rb").read()).hexdigest()
    candidates.append({"conceptId": concept, "sha256": digest})
value = {"schemaVersion": 1, "revision": revision, "candidates": candidates, "selectedConceptId": selected, "selection": selection}
with open(path, "w", encoding="utf-8") as output:
    json.dump(value, output)
PY
}
record_field() { jq -c "$2" "$1/Config/app-icon.json"; }
assert_unchanged() {
  local fixture=$1 label=$2 expected_asset=$3 expected_record=$4
  [[ "$(sha_of "$fixture/GardenNotes/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")" == "$expected_asset" ]] || { echo "$label changed the accepted icon" >&2; exit 1; }
  [[ "$(sha_of "$fixture/Config/app-icon.json")" == "$expected_record" ]] || { echo "$label changed the accepted record" >&2; exit 1; }
}

replace_fixture="$workspace/replace-app"
make_fixture "$replace_fixture"
"$installer" --root "$replace_fixture" --source "$valid_png" --concept-id concept-a --prompt-file "$prompt_file" --generator builtin-imagegen >/dev/null
git -C "$replace_fixture" add -A
git -C "$replace_fixture" commit -qm 'accept concept-a'
replace_asset="$replace_fixture/GardenNotes/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
replace_record="$replace_fixture/Config/app-icon.json"
first_digest=$(sha_of "$replace_asset")
first_record=$(sha_of "$replace_record")
[[ "$(jq -r '.sha256' "$replace_record")" == "$first_digest" ]] || { echo 'initial record digest differs from the accepted asset' >&2; exit 1; }

revision_two="$workspace/candidates/r2"
mkdir -p "$revision_two"
make_png "$revision_two/concept-c.png" 1024 1024 255 120
make_png "$revision_two/concept-d.png" 1024 1024 255 160
write_selection "$revision_two" r2 concept-c user-explicit "$revision_two/concept-c.png" "$revision_two/concept-d.png"
replacement_prompt="$workspace/replacement-prompt.txt"
printf '%s\n' 'One centered sprout mark on a warm solid background; no text, no mask, no fine detail.' >"$replacement_prompt"
replace_with() {
  "$installer" --root "$replace_fixture" --prompt-file "$replacement_prompt" "$@"
}

assert_fails 'declared digest mismatch' replace_with --source "$revision_two/concept-c.png" --concept-id concept-c --generator builtin-imagegen --replace-accepted "sha256:$(printf '0%.0s' {1..64})" --selection "$revision_two/selection.json"
grep -Fq 'declared accepted digest differs' "$workspace/stderr" || { echo 'digest mismatch was not explained' >&2; exit 1; }
assert_unchanged "$replace_fixture" 'declared digest mismatch' "$first_digest" "$first_record"
assert_fails 'replacement without selection' replace_with --source "$revision_two/concept-c.png" --concept-id concept-c --generator builtin-imagegen --replace-accepted "$first_digest"
assert_fails 'unselected candidate source' replace_with --source "$revision_two/concept-d.png" --concept-id concept-c --generator builtin-imagegen --replace-accepted "$first_digest" --selection "$revision_two/selection.json"
grep -Fq 'source is not the selected candidate' "$workspace/stderr" || { echo 'unselected source was not explained' >&2; exit 1; }
assert_fails 'unselected candidate concept' replace_with --source "$revision_two/concept-d.png" --concept-id concept-d --generator builtin-imagegen --replace-accepted "$first_digest" --selection "$revision_two/selection.json"
grep -Fq 'concept ID differs from the explicit selection' "$workspace/stderr" || { echo 'unselected concept was not explained' >&2; exit 1; }
implicit_revision="$workspace/implicit/r2"
mkdir -p "$implicit_revision"
cp "$revision_two/concept-c.png" "$implicit_revision/concept-c.png"
write_selection "$implicit_revision" r2 concept-c assistant-default "$implicit_revision/concept-c.png"
assert_fails 'implicit selection' replace_with --source "$implicit_revision/concept-c.png" --concept-id concept-c --generator builtin-imagegen --replace-accepted "$first_digest" --selection "$implicit_revision/selection.json"
grep -Fq 'selection must record the user explicit choice' "$workspace/stderr" || { echo 'implicit selection was not explained' >&2; exit 1; }
cp "$revision_two/concept-c.png" "$workspace/concept-c.png"
assert_fails 'source outside the selection revision' replace_with --source "$workspace/concept-c.png" --concept-id concept-c --generator builtin-imagegen --replace-accepted "$first_digest" --selection "$revision_two/selection.json"
reference_image="$workspace/user-reference.png"
make_png "$reference_image" 512 512 255 240
assert_fails 'unconfirmed reference rights' replace_with --source "$revision_two/concept-c.png" --concept-id concept-c --generator builtin-imagegen-reference-edit --reference-image "$reference_image" --replace-accepted "$first_digest" --selection "$revision_two/selection.json"
grep -Fq 'reference image rights must be explicitly confirmed by the user' "$workspace/stderr" || { echo 'unconfirmed rights were not explained' >&2; exit 1; }
assert_fails 'assumed reference rights' replace_with --source "$revision_two/concept-c.png" --concept-id concept-c --generator builtin-imagegen-reference-edit --reference-image "$reference_image" --reference-rights assumed --replace-accepted "$first_digest" --selection "$revision_two/selection.json"
assert_fails 'reference without the edit generator' replace_with --source "$revision_two/concept-c.png" --concept-id concept-c --generator builtin-imagegen --reference-image "$reference_image" --reference-rights user-confirmed --replace-accepted "$first_digest" --selection "$revision_two/selection.json"
printf '%s\n' dirty >"$replace_fixture/unrelated.txt"
assert_fails 'dirty replacement' replace_with --source "$revision_two/concept-c.png" --concept-id concept-c --generator builtin-imagegen --replace-accepted "$first_digest" --selection "$revision_two/selection.json"
grep -Fq 'caller worktree must be clean before replacement' "$workspace/stderr" || { echo 'dirty replacement was not explained' >&2; exit 1; }
rm "$replace_fixture/unrelated.txt"
assert_unchanged "$replace_fixture" 'rejected replacement' "$first_digest" "$first_record"
[[ -z "$(git -C "$replace_fixture" status --porcelain=v1)" ]] || { echo 'rejected replacements left repository changes' >&2; exit 1; }

replaced=$(replace_with --source "$revision_two/concept-c.png" --concept-id concept-c --generator builtin-imagegen --replace-accepted "$first_digest" --selection "$revision_two/selection.json")
[[ "$replaced" == *'"status":"replaced"'* && "$replaced" == *"\"supersedes\":\"$first_digest\""* ]] || { echo "unexpected replacement result: $replaced" >&2; exit 1; }
[[ "$(git -C "$replace_fixture" status --porcelain=v1 | sort)" == "$(printf '%s\n' ' M Config/app-icon.json' ' M GardenNotes/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png')" ]] || { echo 'replacement changed files other than the asset and record' >&2; exit 1; }
second_digest=$(sha_of "$replace_asset")
[[ "$second_digest" != "$first_digest" ]] || { echo 'replacement did not change the accepted icon' >&2; exit 1; }
[[ "$(record_field "$replace_fixture" '[.schemaVersion, .conceptId, .generator, .sha256, .selectionRevision, .referenceSha256]')" == "[2,\"concept-c\",\"builtin-imagegen\",\"$second_digest\",\"r2\",null]" ]] || { echo 'replacement record values differ' >&2; exit 1; }
[[ "$(record_field "$replace_fixture" '.supersedes')" == "{\"conceptId\":\"concept-a\",\"generator\":\"builtin-imagegen\",\"sha256\":\"$first_digest\"}" ]] || { echo 'replacement record does not trace the superseded icon' >&2; exit 1; }
validation=$("$validator" --root "$replace_fixture")
[[ "$validation" == *'"status":"valid"'* && "$validation" == *'"conceptId":"concept-c"'* ]] || { echo "unexpected replacement validation: $validation" >&2; exit 1; }
second_record=$(sha_of "$replace_record")
rerun=$(replace_with --source "$revision_two/concept-c.png" --concept-id concept-c --generator builtin-imagegen --replace-accepted "$first_digest" --selection "$revision_two/selection.json")
[[ "$rerun" == *'"status":"already-complete"'* ]] || { echo "replacement rerun was not idempotent: $rerun" >&2; exit 1; }
assert_unchanged "$replace_fixture" 'replacement rerun' "$second_digest" "$second_record"
git -C "$replace_fixture" add -A
git -C "$replace_fixture" commit -qm 'replace with concept-c'

reused_revision="$workspace/reused/r2"
mkdir -p "$reused_revision"
cp "$revision_two/concept-d.png" "$reused_revision/concept-d.png"
write_selection "$reused_revision" r2 concept-d user-explicit "$reused_revision/concept-d.png"
assert_fails 'reused selection revision' replace_with --source "$reused_revision/concept-d.png" --concept-id concept-d --generator builtin-imagegen --replace-accepted "$second_digest" --selection "$reused_revision/selection.json"
grep -Fq 'replacement must come from a new selection revision' "$workspace/stderr" || { echo 'reused revision was not explained' >&2; exit 1; }
assert_unchanged "$replace_fixture" 'reused selection revision' "$second_digest" "$second_record"

revision_three="$workspace/candidates/r3"
mkdir -p "$revision_three"
make_png "$revision_three/concept-e.png" 1024 1024 255 90
write_selection "$revision_three" r3 concept-e user-explicit "$revision_three/concept-e.png"
cp "$reference_image" "$replace_fixture/tracked-reference.png"
git -C "$replace_fixture" add tracked-reference.png
git -C "$replace_fixture" commit -qm 'track a reference by mistake'
assert_fails 'tracked reference image' replace_with --source "$revision_three/concept-e.png" --concept-id concept-e --generator builtin-imagegen-reference-edit --reference-image "$replace_fixture/tracked-reference.png" --reference-rights user-confirmed --replace-accepted "$second_digest" --selection "$revision_three/selection.json"
grep -Fq 'reference image must not be tracked by Git' "$workspace/stderr" || { echo 'tracked reference was not explained' >&2; exit 1; }
git -C "$replace_fixture" rm -q tracked-reference.png
git -C "$replace_fixture" commit -qm 'remove the tracked reference'
assert_fails 'reference used as the icon' replace_with --source "$revision_three/concept-e.png" --concept-id concept-e --generator builtin-imagegen-reference-edit --reference-image "$revision_three/concept-e.png" --reference-rights user-confirmed --replace-accepted "$second_digest" --selection "$revision_three/selection.json"
edited=$(replace_with --source "$revision_three/concept-e.png" --concept-id concept-e --generator builtin-imagegen-reference-edit --reference-image "$reference_image" --reference-rights user-confirmed --replace-accepted "$second_digest" --selection "$revision_three/selection.json")
[[ "$edited" == *'"status":"replaced"'* ]] || { echo "unexpected reference-edit replacement: $edited" >&2; exit 1; }
[[ "$(record_field "$replace_fixture" '[.generator, .referenceSha256, .selectionRevision, .supersedes.conceptId, .supersedes.sha256]')" == "[\"builtin-imagegen-reference-edit\",\"$(sha_of "$reference_image")\",\"r3\",\"concept-c\",\"$second_digest\"]" ]] || { echo 'reference-edit record values differ' >&2; exit 1; }
"$validator" --root "$replace_fixture" >/dev/null
[[ -z "$(git -C "$replace_fixture" ls-files -- '*reference*')" && ! -e "$replace_fixture/user-reference.png" ]] || { echo 'reference image entered the repository' >&2; exit 1; }
git -C "$replace_fixture" add -A
git -C "$replace_fixture" commit -qm 'replace with concept-e'

# A revision accepted before the current one stays used: r2 was accepted, then superseded by r3.
third_digest=$(sha_of "$replace_asset")
third_record=$(sha_of "$replace_record")
assert_fails 'earlier selection revision reuse' replace_with --source "$revision_two/concept-c.png" --concept-id concept-c --generator builtin-imagegen --replace-accepted "$third_digest" --selection "$revision_two/selection.json"
grep -Fq 'replacement must come from a new selection revision' "$workspace/stderr" || { echo 'earlier revision reuse was not explained' >&2; exit 1; }
assert_unchanged "$replace_fixture" 'earlier selection revision reuse' "$third_digest" "$third_record"
[[ -z "$(git -C "$replace_fixture" status --porcelain=v1)" ]] || { echo 'earlier revision reuse left repository changes' >&2; exit 1; }

reference_fixture="$workspace/reference-app"
make_fixture "$reference_fixture"
assert_fails 'initial reference edit without rights' "$installer" --root "$reference_fixture" --source "$valid_png" --concept-id concept-a --prompt-file "$prompt_file" --generator builtin-imagegen-reference-edit --reference-image "$reference_image"
[[ ! -e "$reference_fixture/Config/app-icon.json" ]] || { echo 'unconfirmed reference rights wrote a record' >&2; exit 1; }
"$installer" --root "$reference_fixture" --source "$valid_png" --concept-id concept-a --prompt-file "$prompt_file" --generator builtin-imagegen-reference-edit --reference-image "$reference_image" --reference-rights user-confirmed >/dev/null
[[ "$(record_field "$reference_fixture" '[.schemaVersion, .generator, .referenceSha256, .selectionRevision, .supersedes]')" == "[2,\"builtin-imagegen-reference-edit\",\"$(sha_of "$reference_image")\",null,null]" ]] || { echo 'initial reference-edit record differs' >&2; exit 1; }
"$validator" --root "$reference_fixture" >/dev/null

tamper_record() {
  local label=$1 filter=$2
  cp "$replace_record" "$workspace/record.backup"
  jq -c "$filter" "$workspace/record.backup" >"$replace_record"
  assert_fails "$label" "$validator" --root "$replace_fixture"
  cp "$workspace/record.backup" "$replace_record"
}
tamper_record 'superseded digest equals the accepted icon' '.supersedes.sha256 = .sha256'
tamper_record 'reference digest without the edit generator' '.generator = "builtin-imagegen"'
tamper_record 'reference edit without a reference digest' '.referenceSha256 = null'
tamper_record 'schema 2 without a reference or supersedes' '.generator = "builtin-imagegen" | .referenceSha256 = null | .supersedes = null | .selectionRevision = null'
tamper_record 'revision without a superseded icon' '.supersedes = null'
tamper_record 'schema 1 with replacement fields' '.schemaVersion = 1'
tamper_record 'superseded icon with extra fields' '.supersedes.promptSummary = "kept"'
"$validator" --root "$replace_fixture" >/dev/null

for case_name in transparent wrong-size; do
  case_fixture="$workspace/$case_name-app"
  make_fixture "$case_fixture"
  case_source="$transparent_png"
  [[ "$case_name" == wrong-size ]] && case_source="$wrong_size_png"
  assert_fails "$case_name input" "$installer" --root "$case_fixture" --source "$case_source" --concept-id concept-a --prompt-file "$prompt_file" --generator builtin-imagegen
  [[ ! -e "$case_fixture/Config/app-icon.json" && ! -e "$case_fixture/GardenNotes/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" ]] || { echo "$case_name input left partial output" >&2; exit 1; }
done

symlink_fixture="$workspace/symlink-app"
make_fixture "$symlink_fixture"
ln -s "$valid_png" "$workspace/source-link.png"
assert_fails 'symlinked source' "$installer" --root "$symlink_fixture" --source "$workspace/source-link.png" --concept-id concept-a --prompt-file "$prompt_file" --generator builtin-imagegen

secret_prompt_fixture="$workspace/secret-prompt-app"
make_fixture "$secret_prompt_fixture"
printf '%s\n' 'A simple icon with API_KEY=do-not-store' >"$workspace/secret-prompt.txt"
assert_fails 'credential-like prompt summary' "$installer" --root "$secret_prompt_fixture" --source "$valid_png" --concept-id concept-a --prompt-file "$workspace/secret-prompt.txt" --generator builtin-imagegen
[[ ! -e "$secret_prompt_fixture/Config/app-icon.json" ]] || { echo 'credential-like prompt was written to the repository' >&2; exit 1; }

# A Japanese UTF-8 summary is recorded as the same UTF-8 text without its surrounding spaces, even
# from a shell without a locale, and the same input reruns as already complete.
japanese_fixture="$workspace/japanese-prompt-app"
make_fixture "$japanese_fixture"
japanese_summary='落ち着いた単色の背景に、中央の葉のマーク。文字なし。'
printf '%s\n' "  $japanese_summary  " >"$workspace/japanese-prompt.txt"
japanese_install() {
  env -u LANG -u LC_ALL -u LC_CTYPE "$installer" --root "$japanese_fixture" --source "$valid_png" --concept-id concept-a \
    --prompt-file "$workspace/japanese-prompt.txt" --generator builtin-imagegen
}
japanese_result=$(japanese_install)
[[ "$japanese_result" == *'"status":"applied"'* ]] || { echo "Japanese prompt summary was not installed: $japanese_result" >&2; exit 1; }
[[ "$("$validator" --root "$japanese_fixture")" == *'"status":"valid"'* ]] || { echo 'Japanese prompt summary record did not validate' >&2; exit 1; }
python3 - "$japanese_fixture/Config/app-icon.json" "$japanese_summary" <<'PY'
import json
import sys

raw = open(sys.argv[1], "rb").read()
expected = sys.argv[2]
if json.loads(raw.decode("utf-8"))["promptSummary"] != expected:
    raise SystemExit("Japanese prompt summary differs")
if expected.encode("utf-8") not in raw:
    raise SystemExit("Japanese prompt summary is not stored as UTF-8 text")
PY
git -C "$japanese_fixture" add -A
git -C "$japanese_fixture" commit -qm icon
japanese_rerun=$(japanese_install)
[[ "$japanese_rerun" == *'"status":"already-complete"'* && -z "$(git -C "$japanese_fixture" status --porcelain=v1)" ]] ||
  { echo "Japanese prompt summary rerun was not idempotent: $japanese_rerun" >&2; exit 1; }

# An invalid UTF-8 byte sequence is refused before anything is written.
invalid_utf8_fixture="$workspace/invalid-utf8-prompt-app"
make_fixture "$invalid_utf8_fixture"
printf 'A leaf mark \xe8\xaa on a calm background\n' >"$workspace/invalid-utf8-prompt.txt"
assert_fails 'invalid UTF-8 prompt summary' env -u LANG -u LC_ALL -u LC_CTYPE "$installer" --root "$invalid_utf8_fixture" --source "$valid_png" \
  --concept-id concept-a --prompt-file "$workspace/invalid-utf8-prompt.txt" --generator builtin-imagegen
grep -Fq 'prompt summary is invalid' "$workspace/stderr" || { echo 'invalid UTF-8 was not refused as an invalid prompt summary' >&2; cat "$workspace/stderr" >&2; exit 1; }
[[ -z "$(git -C "$invalid_utf8_fixture" status --porcelain=v1 --untracked-files=all)" ]] ||
  { echo 'invalid UTF-8 prompt summary changed the repository' >&2; exit 1; }

default_fixture="$workspace/default-app"
make_fixture "$default_fixture" main-work
git -C "$default_fixture" switch -q main
assert_fails 'default branch' "$installer" --root "$default_fixture" --source "$valid_png" --concept-id concept-a --prompt-file "$prompt_file" --generator builtin-imagegen

dirty_fixture="$workspace/dirty-app"
make_fixture "$dirty_fixture"
printf '%s\n' dirty >"$dirty_fixture/unrelated.txt"
assert_fails 'dirty start' "$installer" --root "$dirty_fixture" --source "$valid_png" --concept-id concept-a --prompt-file "$prompt_file" --generator builtin-imagegen

missing_identity_fixture="$workspace/missing-identity-app"
make_fixture "$missing_identity_fixture"
rm "$missing_identity_fixture/Config/app-identity.json"
git -C "$missing_identity_fixture" add -u
git -C "$missing_identity_fixture" commit -qm 'remove identity'
assert_fails 'pre-bootstrap repository' "$installer" --root "$missing_identity_fixture" --source "$valid_png" --concept-id concept-a --prompt-file "$prompt_file" --generator builtin-imagegen

escaping_fixture="$workspace/escaping-app"
make_fixture "$escaping_fixture"
python3 - "$escaping_fixture/Config/app-identity.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    value = json.load(source)
value["moduleName"] = "../Escape"
with open(path, "w", encoding="utf-8") as output:
    json.dump(value, output, separators=(",", ":"), sort_keys=True)
PY
git -C "$escaping_fixture" add Config/app-identity.json
git -C "$escaping_fixture" commit -qm 'malformed escaping identity'
assert_fails 'escaping module identity' "$installer" --root "$escaping_fixture" --source "$valid_png" --concept-id concept-a --prompt-file "$prompt_file" --generator builtin-imagegen
[[ ! -e "$workspace/Escape/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" ]] || { echo 'escaping identity wrote outside the repository' >&2; exit 1; }

echo 'PASS: app-icon workflow requires simple generated selection and validates deterministic asset-catalog integration'
