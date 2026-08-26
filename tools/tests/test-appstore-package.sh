#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-appstore-package.XXXXXX")
trap 'rm -rf -- "$test_workspace"' EXIT
validator="$repo_root/tools/validate-appstore-package.sh"
requirements="$repo_root/tools/tests/fixtures/appstore/requirements.json"
fixture_project="$test_workspace/project"
package_root="$fixture_project/App Store"

write_valid_fixture() {
  rm -rf -- "$fixture_project"
  mkdir -p "$package_root/metadata/localizations" "$package_root/privacy" "$package_root/legal" \
    "$package_root/review" "$package_root/release-notes" "$package_root/submission" \
    "$package_root/screenshots/en-US/iphone-6.9" "$package_root/screenshots/en-US/ipad-13" \
    "$package_root/screenshots/ja/iphone-6.9" "$package_root/screenshots/ja/ipad-13"
  cat > "$package_root/metadata/app.yml" <<'EOF'
schemaVersion: 1
bundleId: "com.yuto.TemplateApp"
version: "1.0"
primaryLocale: "en-US"
platforms:
  iphone: true
  ipad: true
category: "Utilities"
copyright: "2026 Yuto"
supportURL: "https://example.com/support"
privacyPolicyURL: "https://example.com/privacy"
reviewContactReference: "keychain://app-store-connect/review-contact"
accountsSupported: false
EOF
  cat > "$package_root/metadata/localizations/en-US.yml" <<'EOF'
name: "Template App"
subtitle: "A focused utility"
description: "A truthful description of this fixture app."
keywords: "utility,focus"
promotionalText: "A concise fixture message."
EOF
  cat > "$package_root/metadata/localizations/ja.yml" <<'EOF'
name: "テンプレートアプリ"
subtitle: "集中できるユーティリティ"
description: "このフィクスチャアプリの実態に沿った説明です。"
keywords: "ユーティリティ,集中"
promotionalText: "簡潔なフィクスチャメッセージです。"
EOF
  cat > "$package_root/privacy/data-use.yml" <<'EOF'
schemaVersion: 1
collectsData: false
tracking: false
dataTypes: []
thirdPartySDKs: []
permissions: []
accountDeletion:
  required: false
  reason: "The app has no accounts."
EOF
  cat > "$package_root/legal/privacy-policy.md" <<'EOF'
# Privacy Policy

Status: Draft

Derived from `privacy/data-use.yml`; confirm before first publication.
EOF
  cat > "$package_root/legal/terms-of-use.md" <<'EOF'
# Terms of Use

Status: Draft

Confirm before first publication.
EOF
  cat > "$package_root/review/review-notes.md" <<'EOF'
# Review Notes

No account is required. Credential reference: none.
EOF
  printf '%s\n' '# Release Notes' '' 'Initial fixture release.' > "$package_root/release-notes/en-US.md"
  printf '%s\n' '# リリースノート' '' '初回フィクスチャリリース。' > "$package_root/release-notes/ja.md"
  cat > "$package_root/submission/checklist.yml" <<'EOF'
schemaVersion: 1
metadataValidated: true
privacyAudited: true
legalConfirmedForFirstPublication: false
screenshotsAudited: true
releaseAuditorApproved: false
EOF
  /bin/cp "$requirements" "$package_root/submission/requirements.json"
  for locale in en-US ja; do
    for family in iphone-6.9 ipad-13; do
      printf 'fixture image bytes' > "$package_root/screenshots/$locale/$family/01-primary.png"
    done
  done
}

assert_invalid() {
  local label=$1 expected_path=$2 forbidden_value=${3:-}
  set +e
  output=$("$validator" --root "$package_root" --project-root "$fixture_project" \
    --bundle-id com.yuto.TemplateApp --version 1.0 --requirements "$requirements" 2>"$test_workspace/stderr")
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *"$expected_path"* ]] || {
    echo "expected precise package failure: $label: $output" >&2
    exit 1
  }
  if [[ -n "$forbidden_value" && "$output" == *"$forbidden_value"* ]]; then
    echo "package failure leaked input value: $label" >&2
    exit 1
  fi
}

write_valid_fixture
ready=$("$validator" --root "$package_root" --project-root "$fixture_project" \
  --bundle-id com.yuto.TemplateApp --version 1.0 --requirements "$requirements")
[[ "$ready" == *'"status":"ready"'* && "$ready" == *'"errors":[]'* ]] || { echo "valid package failed: $ready" >&2; exit 1; }

write_valid_fixture
/usr/bin/sed -i '' '/^subtitle:/d' "$package_root/metadata/localizations/ja.yml"
assert_invalid 'missing Japanese subtitle' 'metadata/localizations/ja.yml.subtitle'

write_valid_fixture
ruby -e 'path=ARGV.fetch(0); text=File.binread(path); File.binwrite(path,text.sub(/description: .*/, "description: \\\"#{"x"*4001}\\\""))' "$package_root/metadata/localizations/en-US.yml"
assert_invalid 'over-limit description' 'metadata/localizations/en-US.yml.description'

write_valid_fixture
/usr/bin/sed -i '' 's#supportURL: "https://example.com/support"#supportURL: ""#' "$package_root/metadata/app.yml"
assert_invalid 'missing support URL' 'metadata/app.yml.supportURL'

write_valid_fixture
printf '%s\n' 'FirebaseAnalytics' > "$fixture_project/linked-sdk.txt"
assert_invalid 'privacy and linked SDK mismatch' 'privacy/data-use.yml.collectsData'

write_valid_fixture
rm -rf -- "$package_root/screenshots/ja/ipad-13"
assert_invalid 'missing screenshot family' 'screenshots/ja/ipad-13'

write_valid_fixture
secret_fixture='actual-secret-value-42'
printf '%s\n' "Password: $secret_fixture" >> "$package_root/review/review-notes.md"
assert_invalid 'secret-like review credential' 'review/review-notes.md.credentials' "$secret_fixture"

echo 'PASS: App Store package validation catches localized limits, privacy mismatches, missing families, URLs, and review credentials'
