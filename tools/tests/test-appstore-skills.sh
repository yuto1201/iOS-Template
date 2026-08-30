#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-appstore-skills.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT
prepare_skill="$repo_root/.agents/skills/prepare-appstore-assets"
submit_skill="$repo_root/.agents/skills/submit-appstore-release"
seal="$prepare_skill/scripts/seal-package.sh"
record="$submit_skill/scripts/record-section.sh"
requirements_source="$repo_root/tools/tests/fixtures/appstore/requirements.json"
source_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
build_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
team_id=YUTO-PERSONAL-TEAM
bundle_id=com.yuto.TemplateApp
version=1.0

[[ -f "$prepare_skill/SKILL.md" && -x "$seal" && -f "$submit_skill/SKILL.md" && -x "$record" ]] || {
  echo 'App Store skill scripts are incomplete' >&2; exit 1
}
[[ -L "$repo_root/.claude/skills/prepare-appstore-assets" && "$(readlink "$repo_root/.claude/skills/prepare-appstore-assets")" == ../../.agents/skills/prepare-appstore-assets ]] || {
  echo 'prepare skill symlink is invalid' >&2; exit 1
}
[[ -L "$repo_root/.claude/skills/submit-appstore-release" && "$(readlink "$repo_root/.claude/skills/submit-appstore-release")" == ../../.agents/skills/submit-appstore-release ]] || {
  echo 'submission skill symlink is invalid' >&2; exit 1
}
! rg -q 'TODO|\[TODO' "$prepare_skill/SKILL.md" "$submit_skill/SKILL.md"
rg -q 'Codex and Claude may perform' "$submit_skill/SKILL.md" && ! rg -q 'Claude.*delegate|Claude.*委託' "$submit_skill/SKILL.md"
rg -q 'first.publication|first publication|初回公開' "$prepare_skill/SKILL.md"

project="$workspace/project"; package="$project/App Store"
audit="$workspace/release-audit.json"; approval="$workspace/legal-approval.json"; preflight="$workspace/app-store-preflight.json"

package_digest() {
  PACKAGE="$package" ruby -rdigest -e '
    root=ENV.fetch("PACKAGE"); entries=[]
    Dir.glob(File.join(root,"**","*"),File::FNM_DOTMATCH).sort.each do |path|
      next if [".",".."].include?(File.basename(path)); relative=path.delete_prefix(root+File::SEPARATOR)
      next unless File.file?(path) && !File.symlink?(path)
      next if relative.match?(%r{\Asubmission/[0-9]+(?:\.[0-9]+){1,2}-(?:package|result)\.json\z})
      entries << "#{relative}\0#{Digest::SHA256.file(path).hexdigest}\0"
    end
    puts "sha256:#{Digest::SHA256.hexdigest(entries.join)}"
  '
}

write_valid_fixture() {
  rm -rf -- "$project"; mkdir -p "$project/tools" "$package/metadata/localizations" "$package/privacy" "$package/legal" "$package/review" \
    "$package/release-notes" "$package/submission" "$package/screenshots/en-US/iphone-6.9" "$package/screenshots/en-US/ipad-13" \
    "$package/screenshots/ja/iphone-6.9" "$package/screenshots/ja/ipad-13"
  /bin/cp "$repo_root/tools/validate-appstore-package.sh" "$project/tools/validate-appstore-package.sh"
  chmod +x "$project/tools/validate-appstore-package.sh"
  cat > "$package/metadata/app.yml" <<EOF
schemaVersion: 1
bundleId: "$bundle_id"
version: "$version"
primaryLocale: "en-US"
platforms:
  iphone: true
  ipad: true
category: "Utilities"
copyright: "2026 Yuto"
supportURL: "https://example.com/support"
privacyPolicyURL: "https://example.com/privacy"
reviewContactReference: "none"
accountsSupported: false
EOF
  cat > "$package/metadata/localizations/en-US.yml" <<'EOF'
name: "Template App"
subtitle: "A focused utility"
description: "A truthful fixture description."
keywords: "utility,focus"
promotionalText: "A concise fixture message."
EOF
  cat > "$package/metadata/localizations/ja.yml" <<'EOF'
name: "テンプレートアプリ"
subtitle: "集中用ユーティリティ"
description: "実態に沿ったフィクスチャ説明です。"
keywords: "ユーティリティ,集中"
promotionalText: "簡潔なフィクスチャメッセージです。"
EOF
  cat > "$package/privacy/data-use.yml" <<'EOF'
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
  printf '%s\n' '# Privacy Policy' '' 'Status: Confirmed' '' 'No data is collected.' > "$package/legal/privacy-policy.md"
  printf '%s\n' '# Terms of Use' '' 'Status: Confirmed' '' 'Use the app lawfully.' > "$package/legal/terms-of-use.md"
  printf '%s\n' '# Review Notes' '' 'No account is required.' > "$package/review/review-notes.md"
  printf '%s\n' '# Release Notes' '' 'Initial release.' > "$package/release-notes/en-US.md"
  printf '%s\n' '# リリースノート' '' '初回リリース。' > "$package/release-notes/ja.md"
  cat > "$package/submission/checklist.yml" <<'EOF'
schemaVersion: 1
metadataValidated: true
privacyAudited: true
legalConfirmedForFirstPublication: true
screenshotsAudited: true
releaseAuditorApproved: true
EOF
  /bin/cp "$requirements_source" "$package/submission/requirements.json"
  local locale family counter=1
  for locale in en-US ja; do
    for family in iphone-6.9 ipad-13; do
      printf 'release screenshot %s\n' "$counter" > "$package/screenshots/$locale/$family/01-primary.png"; counter=$((counter+1))
    done
  done
  PACKAGE="$package" REQUIREMENTS="$package/submission/requirements.json" SOURCE_SHA="$source_sha" BUILD_DIGEST="$build_digest" ruby -rjson -rdigest -e '
    root=ENV.fetch("PACKAGE"); cases=[]
    [["en-US","iphone-6.9"],["en-US","ipad-13"],["ja","iphone-6.9"],["ja","ipad-13"]].each do |locale,family|
      relative="#{locale}/#{family}/01-primary.png"; absolute=File.join(root,"screenshots",relative)
      cases << {"locale"=>locale,"family"=>family,"state"=>"primary","order"=>1,"path"=>relative,"digest"=>"sha256:#{Digest::SHA256.file(absolute).hexdigest}"}
    end
    value={"schemaVersion"=>1,"sourceSha"=>ENV.fetch("SOURCE_SHA"),"buildDigest"=>ENV.fetch("BUILD_DIGEST"),
      "requirementsDigest"=>"sha256:#{Digest::SHA256.file(ENV.fetch("REQUIREMENTS")).hexdigest}","cases"=>cases}
    File.binwrite(File.join(root,"screenshots","manifest.json"),JSON.generate(value))
  '
}

write_attestations() {
  local digest=$1
  DIGEST="$digest" AUDIT="$audit" APPROVAL="$approval" SOURCE_SHA="$source_sha" BUILD_DIGEST="$build_digest" BUNDLE="$bundle_id" VERSION="$version" ruby -rjson -e '
    audit={"schemaVersion"=>1,"status"=>"approved","role"=>"release-auditor","sourceSha"=>ENV.fetch("SOURCE_SHA"),
      "buildDigest"=>ENV.fetch("BUILD_DIGEST"),"packageDigest"=>ENV.fetch("DIGEST"),"findings"=>[]}
    approval={"schemaVersion"=>1,"status"=>"approved","scope"=>"first-publication-legal","bundleId"=>ENV.fetch("BUNDLE"),
      "version"=>ENV.fetch("VERSION"),"packageDigest"=>ENV.fetch("DIGEST"),"approvedAt"=>"2026-08-26T01:00:00Z"}
    File.binwrite(ENV.fetch("AUDIT"),JSON.generate(audit)); File.binwrite(ENV.fetch("APPROVAL"),JSON.generate(approval))
  '
}

seal_package() {
  "$seal" --repo "$project" --package-root "$package" --requirements "$package/submission/requirements.json" \
    --bundle-id "$bundle_id" --version "$version" --source-sha "$source_sha" --build-digest "$build_digest" \
    --audit "$audit" --first-publication yes --legal-approval "$approval" \
    --output "$package/submission/$version-package.json" --now 2026-08-26T02:00:00Z
}

assert_seal_failure() {
  local label=$1 expected=$2
  set +e; output=$(seal_package 2>&1); command_status=$?; set -e
  [[ "$command_status" -ne 0 && "$output" == *"$expected"* ]] || { echo "expected preparation failure: $label: $output" >&2; exit 1; }
}

write_valid_fixture; digest=$(package_digest); write_attestations "$digest"
prepared=$(seal_package)
[[ "$prepared" == *'"status":"prepared"'* && -f "$package/submission/$version-package.json" ]] || { echo "complete preparation failed: $prepared" >&2; exit 1; }

write_valid_fixture; /usr/bin/sed -i '' 's/Status: Confirmed/Status: Draft/' "$package/legal/privacy-policy.md"
digest=$(package_digest); write_attestations "$digest"
assert_seal_failure 'unconfirmed legal text' 'legal'

write_valid_fixture; digest=$(package_digest); write_attestations "$digest"; rm -f -- "$approval"
assert_seal_failure 'missing first publication approval' 'approval'

write_preflight() {
  local account=$1 executor=${2:-codex}
  ACCOUNT="$account" EXECUTOR="$executor" TARGET="$bundle_id" FILE="$preflight" ruby -rjson -rdigest -e '
    value={"schemaVersion"=>2,"issue"=>8,"executor"=>ENV.fetch("EXECUTOR"),"provider"=>"app-store","account"=>ENV.fetch("ACCOUNT"),"target"=>ENV.fetch("TARGET"),
      "environment"=>"production","operation"=>"appstore.inspect_app","health"=>"healthy","checkedAt"=>"2026-08-26T02:05:00Z"}
    canonical=lambda{|item| item.is_a?(Hash) ? item.keys.sort.to_h{|key| [key,canonical.call(item.fetch(key))]} : item}
    value["digest"]="sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical.call(value)))}"
    File.binwrite(ENV.fetch("FILE"),JSON.generate(canonical.call(value)))
  '
}

record_section() {
  local section=$1 expected_build=${2:-$build_digest} resume=${3:-no} primary_model=${4:-codex}
  "$record" --repo "$project" --package-root "$package" --package-manifest "$package/submission/$version-package.json" \
    --preflight "$preflight" --audit "$audit" --result "$package/submission/$version-result.json" \
    --team-id "$team_id" --bundle-id "$bundle_id" --version "$version" --build-id 42 --source-sha "$source_sha" \
    --build-digest "$expected_build" --primary-model "$primary_model" --section "$section" \
    --remote-reference "asc://apps/$bundle_id/versions/$version/$section" \
    --readback-digest sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
    --resume-readback "$resume" --now 2026-08-26T02:10:00Z
}

write_valid_fixture; digest=$(package_digest); write_attestations "$digest"; seal_package >/dev/null
write_preflight COMPANY-TEAM
set +e; output=$(record_section app-information 2>&1); command_status=$?; set -e
[[ "$command_status" -ne 0 && "$output" == *'team'* ]] || { echo "Team mismatch was not blocked: $output" >&2; exit 1; }

write_preflight "$team_id"
changed_build=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
set +e; output=$(record_section app-information "$changed_build" 2>&1); command_status=$?; set -e
[[ "$command_status" -ne 0 && "$output" == *'build'* ]] || { echo "changed build was not blocked: $output" >&2; exit 1; }

printf '\nchanged after preparation\n' >> "$package/metadata/app.yml"
set +e; output=$(record_section app-information 2>&1); command_status=$?; set -e
[[ "$command_status" -ne 0 && "$output" == *'package digest'* ]] || { echo "stale package digest was not blocked: $output" >&2; exit 1; }

write_valid_fixture; digest=$(package_digest); write_attestations "$digest"; seal_package >/dev/null; write_preflight "$team_id"
first=$(record_section app-information)
[[ "$first" == *'"status":"in-progress"'* ]] || { echo "first submission section failed: $first" >&2; exit 1; }
set +e; output=$(record_section localization "$build_digest" no 2>&1); command_status=$?; set -e
[[ "$command_status" -ne 0 && "$output" == *'readback'* ]] || { echo "resume without readback was not blocked: $output" >&2; exit 1; }
second=$(record_section localization "$build_digest" yes)
[[ "$second" == *'"lastCompletedSection":"localization"'* ]] || { echo "resume with readback failed: $second" >&2; exit 1; }

rm -f -- "$package/submission/$version-result.json"
write_preflight "$team_id" claude
claude_result=$(record_section app-information "$build_digest" no claude)
[[ "$claude_result" == *'"primaryModel":"claude"'* ]] || { echo "Claude submission executor was not preserved: $claude_result" >&2; exit 1; }

echo 'PASS: App Store skills apply the same configured-account, legal, digest, build, and resume gates to Codex and Claude'
