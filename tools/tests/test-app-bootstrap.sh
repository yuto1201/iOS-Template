#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
if [[ "$mode" != "validation" && "$mode" != "transform" ]]; then
  echo "usage: $0 validation|transform" >&2
  exit 64
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

manifest="Config/template-identity.json"
bootstrap="tools/bootstrap-app.swift"
output="$(mktemp -t app-bootstrap-output.XXXXXX)"
errors="$(mktemp -t app-bootstrap-errors.XXXXXX)"
fixture=""
escaped_fixture=""
trap 'rm -f "$output" "$errors"; [[ -z "$fixture" ]] || rm -rf "$fixture"; [[ -z "$escaped_fixture" ]] || rm -rf "$escaped_fixture"' EXIT

fixture_hash() {
  {
    find TemplateApp TemplateAppTests TemplateAppUITests TemplateApp.xcodeproj Config specs docs -type f -print
    printf '%s\n' AGENTS.md README.md
  } | LC_ALL=C sort | while IFS= read -r path; do
    shasum "$path"
  done | shasum | awk '{print $1}'
}

validate() {
  swift "$bootstrap" validate --manifest "$manifest" "$@" >"$output" 2>"$errors"
}

expect_valid() {
  if ! validate \
    --display-name 'Garden Notes' \
    --module-name 'GardenNotes' \
    --app-slug 'garden-notes' \
    --bundle-id 'com.yuto.GardenNotes'; then
    echo "valid case failed: $(<"$errors")" >&2
    exit 1
  fi

  local expected='{"appSlug":"garden-notes","bundleId":"com.yuto.GardenNotes","displayName":"Garden Notes","moduleName":"GardenNotes"}'
  local actual
  actual="$(<"$output")"
  [[ "$actual" == "$expected" ]] || {
    echo "valid case emitted unexpected JSON: $actual" >&2
    exit 1
  }
}

expect_valid_case() {
  local label="$1"
  shift

  if ! validate "$@"; then
    echo "valid case failed: $label: $(<"$errors")" >&2
    exit 1
  fi
}

expect_invalid() {
  local label="$1"
  shift
  local before after status
  before="$(fixture_hash)"
  set +e
  validate "$@"
  status=$?
  set -e
  after="$(fixture_hash)"

  [[ $status -ne 0 ]] || {
    echo "invalid case unexpectedly succeeded: $label" >&2
    exit 1
  }
  [[ "$before" == "$after" ]] || {
    echo "invalid case changed fixture: $label" >&2
    exit 1
  }
}

if [[ "$mode" == "transform" ]]; then
  source_hash_before="$(fixture_hash)"
  fixture="$(mktemp -d -t app-bootstrap-transform.XXXXXX)"
  rm -rf "$fixture"
  git clone --no-local "$root" "$fixture" >/dev/null
  git -C "$fixture" checkout -b codex/test-bootstrap >/dev/null
  historical_plan="$fixture/docs/superpowers/plans/2026-08-22-app-bootstrap.md"
  historical_plan_hash_before="$(shasum "$historical_plan" | awk '{print $1}')"
  pbx_uuid_hash_before="$(rg -o '[A-F0-9]{24}' "$fixture/TemplateApp.xcodeproj/project.pbxproj" | LC_ALL=C sort -u | shasum | awk '{print $1}')"

  if ! swift "$bootstrap" apply \
    --root "$fixture" \
    --manifest "$fixture/$manifest" \
    --display-name 'Garden Notes' \
    --module-name 'GardenNotes' \
    --app-slug 'garden-notes' \
    --bundle-id 'com.yuto.GardenNotes' >"$output" 2>"$errors"; then
    echo "transform failed: $(<"$errors")" >&2
    exit 1
  fi

  for expected_path in \
    GardenNotes.xcodeproj \
    GardenNotes.xcodeproj/xcshareddata/xcschemes/GardenNotes.xcscheme \
    GardenNotes/GardenNotesApp.swift \
    GardenNotesTests/GardenNotesTests.swift \
    GardenNotesUITests/GardenNotesUITests.swift; do
    [[ -e "$fixture/$expected_path" ]] || {
      echo "missing transformed path: $expected_path" >&2
      exit 1
    }
  done

  pbxproj="$fixture/GardenNotes.xcodeproj/project.pbxproj"
  grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.yuto.GardenNotes;' "$pbxproj"
  grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.yuto.GardenNotesTests;' "$pbxproj"
  grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.yuto.GardenNotesUITests;' "$pbxproj"
  grep -Fq 'DEVELOPMENT_TEAM = AUZ2MV247A;' "$pbxproj"
  python3 - "$pbxproj" <<'PY'
import sys

with open(sys.argv[1]) as source:
    content = source.read()

display_name_setting = 'INFOPLIST_KEY_CFBundleDisplayName = "Garden Notes";'
if content.count(display_name_setting) != 2:
    raise SystemExit(f"expected exactly two App display-name settings, found {content.count(display_name_setting)}")
PY
  [[ "$pbx_uuid_hash_before" == "$(rg -o '[A-F0-9]{24}' "$pbxproj" | LC_ALL=C sort -u | shasum | awk '{print $1}')" ]] || {
    echo 'PBX UUIDs changed during transform' >&2
    exit 1
  }
  grep -Fqx '@testable import GardenNotes' "$fixture/GardenNotesTests/GardenNotesTests.swift"
  grep -Fqx 'struct GardenNotesApp: App {' "$fixture/GardenNotes/GardenNotesApp.swift"
  grep -Fqx '            Text("garden-notes.welcome")' "$fixture/GardenNotes/ContentView.swift"
  grep -Fqx '                .accessibilityIdentifier("garden-notes.welcome-title")' "$fixture/GardenNotes/ContentView.swift"
  grep -Fqx 'ios-template/garden-notes/elevenlabs/production/api-key' "$fixture/docs/security.md"
  grep -Fqx '~/Library/Application Support/iOS-Template/secrets/${appSlug}/' "$fixture/docs/security.md"
  grep -Fqx '  "file": "GardenNotes/Settings/NotificationSettings.swift",' "$fixture/docs/agent-contracts/review-packet.md"
  grep -Fqx '# Garden Notes agent contract' "$fixture/AGENTS.md" || {
    echo 'AGENTS heading was not transformed with the display name' >&2
    exit 1
  }

  python3 - "$fixture/Config/app-identity.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    actual = json.load(source)

expected = {
    "appSlug": "garden-notes",
    "bundleId": "com.yuto.GardenNotes",
    "displayName": "Garden Notes",
    "moduleName": "GardenNotes",
    "schemaVersion": 1,
    "sourceIdentityVersion": 1,
}
if actual != expected:
    raise SystemExit(f"unexpected app identity: {actual!r}")
PY

  python3 - "$fixture/Config/ownership.yml" <<'PY'
import sys

with open(sys.argv[1]) as source:
    actual = source.read()

expected = """schemaVersion: 1

github:
  login: yuto1201

supabase:
  organization: YUTO1201
  projectRef: null

cloudflare:
  accountId: null

appStore:
  teamId: null
  bundleId: com.yuto.GardenNotes
"""
if actual != expected:
    raise SystemExit(f"unexpected ownership content: {actual!r}")
PY
  [[ "$historical_plan_hash_before" == "$(shasum "$historical_plan" | awk '{print $1}')" ]] || {
    echo 'historical plan changed during transform' >&2
    exit 1
  }

  if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -list -json -project "$fixture/GardenNotes.xcodeproj" >"$output" 2>"$errors"; then
    echo "xcodebuild -list failed: $(<"$errors")" >&2
    exit 1
  fi
  python3 - "$output" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    listing = json.load(source)

project = listing["project"]
if project["name"] != "GardenNotes":
    raise SystemExit(f"unexpected project: {project['name']!r}")
if project["schemes"] != ["GardenNotes"]:
    raise SystemExit(f"unexpected schemes: {project['schemes']!r}")
if project["targets"] != ["GardenNotes", "GardenNotesTests", "GardenNotesUITests"]:
    raise SystemExit(f"unexpected targets: {project['targets']!r}")
PY

  escaped_fixture="$(mktemp -d -t app-bootstrap-escaped.XXXXXX)"
  rm -rf "$escaped_fixture"
  git clone --no-local "$root" "$escaped_fixture" >/dev/null
  git -C "$escaped_fixture" checkout -b codex/test-bootstrap-escaped >/dev/null
  escaped_display_name='Garden "Notes" \ Draft'
  if ! swift "$bootstrap" apply \
    --root "$escaped_fixture" \
    --manifest "$escaped_fixture/$manifest" \
    --display-name "$escaped_display_name" \
    --module-name 'QuotedGardenNotes' \
    --app-slug 'quoted-garden-notes' \
    --bundle-id 'com.yuto.QuotedGardenNotes' >"$output" 2>"$errors"; then
    echo "quoted display-name transform failed: $(<"$errors")" >&2
    exit 1
  fi
  python3 - "$escaped_fixture/QuotedGardenNotes.xcodeproj/project.pbxproj" <<'PY'
import sys

with open(sys.argv[1]) as source:
    content = source.read()

display_name_setting = r'INFOPLIST_KEY_CFBundleDisplayName = "Garden \"Notes\" \\ Draft";'
if content.count(display_name_setting) != 2:
    raise SystemExit(f"expected exactly two escaped display-name settings, found {content.count(display_name_setting)}")
PY
  if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -list -json -project "$escaped_fixture/QuotedGardenNotes.xcodeproj" >"$output" 2>"$errors"; then
    echo "quoted display-name xcodebuild -list failed: $(<"$errors")" >&2
    exit 1
  fi
  [[ "$source_hash_before" == "$(fixture_hash)" ]] || {
    echo 'apply changed content outside its staging root' >&2
    exit 1
  }

  echo 'transform tests passed'
  exit 0
fi

expect_valid

display_30='123456789012345678901234567890'
display_31='1234567890123456789012345678901'
module_50="$(printf 'M%.0s' {1..50})"
module_51="${module_50}M"
slug_50="$(printf 'a%.0s' {1..50})"
slug_51="${slug_50}a"

expect_valid_case 'display name at 30 characters' \
  --display-name "$display_30" --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_valid_case 'display name with quotes and backslash' \
  --display-name 'Garden "Notes" \ Draft' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'display name at 31 characters' \
  --display-name "$display_31" --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_valid_case 'module name at 50 characters' \
  --display-name 'Garden Notes' --module-name "$module_50" --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module name at 51 characters' \
  --display-name 'Garden Notes' --module-name "$module_51" --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_valid_case 'app slug at 50 characters' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug "$slug_50" --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'app slug at 51 characters' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug "$slug_51" --bundle-id 'com.yuto.GardenNotes'
expect_valid_case 'bundle segment beginning with a digit' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.3yuto.GardenNotes'

expect_invalid 'empty display name' \
  --display-name '' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'display name containing slash' \
  --display-name 'Garden/Notes' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module beginning with a digit' \
  --display-name 'Garden Notes' --module-name '1GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module name with one character' \
  --display-name 'Garden Notes' --module-name 'A' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module name beginning with an underscore' \
  --display-name 'Garden Notes' --module-name '_Garden' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module name containing an underscore' \
  --display-name 'Garden Notes' --module-name 'Garden_Notes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module containing whitespace' \
  --display-name 'Garden Notes' --module-name 'Garden Notes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module equal to TemplateApp' \
  --display-name 'Garden Notes' --module-name 'TemplateApp' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'Swift keyword as module' \
  --display-name 'Garden Notes' --module-name 'class' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'uppercase app slug' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'Garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'slug with adjacent hyphens' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'garden--notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'bundle ID without a dot' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'comyutoGardenNotes'
expect_invalid 'bundle segment beginning with a hyphen' \
  --display-name 'Garden Notes' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.-GardenNotes'

echo 'validation tests passed'
