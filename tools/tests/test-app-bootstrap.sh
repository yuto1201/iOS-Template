#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "validation" ]]; then
  echo "usage: $0 validation" >&2
  exit 64
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

manifest="Config/template-identity.json"
bootstrap="tools/bootstrap-app.swift"
output="$(mktemp -t app-bootstrap-output.XXXXXX)"
errors="$(mktemp -t app-bootstrap-errors.XXXXXX)"
trap 'rm -f "$output" "$errors"' EXIT

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

expect_valid

expect_invalid 'empty display name' \
  --display-name '' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'display name containing slash' \
  --display-name 'Garden/Notes' --module-name 'GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
expect_invalid 'module beginning with a digit' \
  --display-name 'Garden Notes' --module-name '1GardenNotes' --app-slug 'garden-notes' --bundle-id 'com.yuto.GardenNotes'
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
