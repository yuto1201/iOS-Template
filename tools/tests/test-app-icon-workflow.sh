#!/bin/bash
set -euo pipefail

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
