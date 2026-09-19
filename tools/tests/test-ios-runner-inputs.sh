#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

inputs_requested_shard=''
case "$#" in
  0) ;;
  1)
    [[ "$1" == --application-fixture-only ]] || exit 64
    inputs_requested_shard=application
    ;;
  *) exit 64 ;;
esac
inputs_fixture_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

run_inputs_shard() {
local inputs_shard="$1" inputs_shard_started="$SECONDS"
case "$inputs_shard" in
  application|legacy-preflight|legacy-execution) ;;
  *) echo "unknown internal inputs iOS runner shard: $inputs_shard" >&2; return 64 ;;
esac
source "$inputs_fixture_path"

if [[ "$inputs_shard" == application ]]; then
prepare_application_fixture_repo application-fixture-positive
fixture_receipt="$(run_application_fixture_snapshot)"
IFS=$'\t' read -r fixture_config fixture_digest _ <<<"$fixture_receipt"
fixture_project="$("$validator_binary" --runner-config --config "$fixture_config" --digest "$fixture_digest" --get project.path)"
[[ "$fixture_project" == tools/tests/fixtures/admob-integration/AdMobFixtureApp.xcodeproj ]] || {
  echo 'Application-fixture snapshot did not seal the declared project' >&2
  exit 1
}
[[ ! -s "$fake_log" ]] || { echo 'Application-fixture snapshot reached Xcode or Simulator' >&2; exit 1; }
clean_application_fixture_snapshot "$fixture_receipt"
assert_no_failed_attempts

prepare_application_fixture_repo application-fixture-binding-declarations
/bin/cp "$contract" "$scratch/application-fixture-canonical-contract.json"
/usr/bin/ruby -I"$source_repo/tools/lib" -rissue-contract -rjson - "$contract" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.binread(path))
declaration = document.fetch("acceptanceCriteria").find do |criterion|
  criterion.fetch("text").start_with?(IOSTemplate::IssueContract::APPLICATION_FIXTURE_DECLARATION_PREFIX)
end or abort "fixture binding declaration is missing"
duplicate = document.fetch("acceptanceCriteria").find { |criterion| criterion.fetch("id") == "AC-2" }
duplicate.fetch("text")
duplicate["text"] = declaration.fetch("text")
File.binwrite(path, IOSTemplate::IssueContract.canonical_json(document))
RUBY
expect_application_fixture_snapshot_failure application-fixture-duplicate-binding \
  'issueContract must contain at most one Application-fixture binding declaration'

/bin/cp "$scratch/application-fixture-canonical-contract.json" "$contract"
/usr/bin/ruby -I"$source_repo/tools/lib" -rissue-contract -rjson - "$contract" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.binread(path))
declaration = document.fetch("acceptanceCriteria").find do |criterion|
  criterion.fetch("text").start_with?(IOSTemplate::IssueContract::APPLICATION_FIXTURE_DECLARATION_PREFIX)
end or abort "fixture binding declaration is missing"
prefix = IOSTemplate::IssueContract::APPLICATION_FIXTURE_DECLARATION_PREFIX + " "
payload = declaration.fetch("text").delete_prefix(prefix)
declaration["text"] = prefix + payload.sub("{", "{ ")
File.binwrite(path, IOSTemplate::IssueContract.canonical_json(document))
RUBY
expect_application_fixture_snapshot_failure application-fixture-noncanonical-binding \
  'Application-fixture binding declaration must use canonical JSON'

prepare_application_fixture_repo application-fixture-marker-missing
git -C "$repo" rm -q -- .agents/skills/admob-monetization/application-fixture.json
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-marker-missing \
  'Application-fixture Head ownership marker must be regular 100644 exact canonical binding bytes'

prepare_application_fixture_repo application-fixture-marker-bytes
printf '\n' >>"$repo/.agents/skills/admob-monetization/application-fixture.json"
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-marker-bytes \
  'Application-fixture Head ownership marker must be regular 100644 exact canonical binding bytes'

prepare_application_fixture_repo application-fixture-marker-mode
chmod +x "$repo/.agents/skills/admob-monetization/application-fixture.json"
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-marker-mode \
  'Application-fixture Head ownership marker must be regular 100644 exact canonical binding bytes'

FAKE_BASE_PROVIDER_MODE=unowned prepare_application_fixture_repo application-fixture-base-unowned
expect_application_fixture_snapshot_failure application-fixture-base-unowned \
  'pre-existing Application-fixture provider requires the same Base ownership marker'

FAKE_BASE_PROVIDER_MODE=core-tool-unowned prepare_application_fixture_repo application-fixture-base-core-tool-unowned
/usr/bin/ruby -I"$source_repo/tools/lib" -rissue-contract -rjson - \
  "$contract" "$repo/.agents/skills/admob-monetization/application-fixture.json" <<'RUBY'
contract_path, marker_path = ARGV
document = JSON.parse(File.binread(contract_path))
declaration = document.fetch("acceptanceCriteria").find do |criterion|
  criterion.fetch("text").start_with?(IOSTemplate::IssueContract::APPLICATION_FIXTURE_DECLARATION_PREFIX)
end or abort "fixture binding declaration is missing"
prefix = IOSTemplate::IssueContract::APPLICATION_FIXTURE_DECLARATION_PREFIX + " "
binding = JSON.parse(declaration.fetch("text").delete_prefix(prefix))
binding.fetch("toolPaths").map! do |path|
  path == "tools/lib/admob-activation.rb" ? "tools/lib/secret-admob.rb" : path
end
binding.fetch("toolPaths").sort!
binding_json = IOSTemplate::IssueContract.canonical_json(binding)
declaration["text"] = prefix + binding_json
File.binwrite(contract_path, IOSTemplate::IssueContract.canonical_json(document))
File.binwrite(marker_path, binding_json)
RUBY
git -C "$repo" rm -q -- tools/lib/admob-activation.rb
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-base-core-tool-unowned \
  'pre-existing Application-fixture provider requires the same Base ownership marker'

FAKE_BASE_PROVIDER_MODE=fixture-unowned prepare_application_fixture_repo application-fixture-base-fixture-unowned
expect_application_fixture_snapshot_failure application-fixture-base-fixture-unowned \
  'pre-existing Application-fixture provider requires the same Base ownership marker'

FAKE_BASE_PROVIDER_MODE=alias-unowned prepare_application_fixture_repo application-fixture-base-alias-unowned
expect_application_fixture_snapshot_failure application-fixture-base-alias-unowned \
  'pre-existing Application-fixture provider requires the same Base ownership marker'

FAKE_BASE_PROVIDER_MODE=marker-only prepare_application_fixture_repo application-fixture-base-marker-only
expect_application_fixture_snapshot_failure application-fixture-base-marker-only \
  'new Application-fixture provider must not have a Base ownership marker'

FAKE_BASE_PROVIDER_MODE=owned prepare_application_fixture_repo application-fixture-base-owned
fixture_receipt="$(run_application_fixture_snapshot)"
clean_application_fixture_snapshot "$fixture_receipt"
assert_no_failed_attempts

prepare_application_fixture_repo application-fixture-skill-missing
git -C "$repo" rm -q -- .agents/skills/admob-monetization/SKILL.md
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-skill-missing \
  'Application-fixture Head provider skill must be a regular 100644 SKILL.md'

prepare_application_fixture_repo application-fixture-tool-missing
git -C "$repo" rm -q -- tools/lib/admob-activation.rb
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-tool-missing \
  'Application-fixture Head toolPaths must be regular 100644 or 100755 blobs'

prepare_application_fixture_repo application-fixture-alias-missing
git -C "$repo" rm -q -- .claude/skills/admob-monetization
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-alias-missing \
  'Application-fixture Head Claude skill alias must be an exact provider symlink'

prepare_application_fixture_repo application-fixture-manifest-schema
/usr/bin/ruby -rjson - "$repo/Config/repository-tests.json" <<'RUBY'
path = ARGV.fetch(0)
manifest = JSON.parse(File.binread(path))
manifest["schemaVersion"] = 2
File.binwrite(path, JSON.generate(manifest))
RUBY
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-manifest-schema \
  'Application-fixture repository-test manifest must not change schemaVersion'

prepare_application_fixture_repo application-fixture-manifest-head-all
/usr/bin/ruby -rjson - "$repo/Config/repository-tests.json" <<'RUBY'
path = ARGV.fetch(0)
manifest = JSON.parse(File.binread(path))
manifest.fetch("headAllPaths") << "README.md"
File.binwrite(path, JSON.generate(manifest))
RUBY
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-manifest-head-all \
  'Application-fixture repository-test manifest must not change headAllPaths'

prepare_application_fixture_repo application-fixture-manifest-existing-domain
/usr/bin/ruby -rjson - "$repo/Config/repository-tests.json" <<'RUBY'
path = ARGV.fetch(0)
manifest = JSON.parse(File.binread(path))
manifest.fetch("domainRules").find { |entry| entry.fetch("domain") == "base" }.fetch("paths") << "docs/base.md"
File.binwrite(path, JSON.generate(manifest))
RUBY
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-manifest-existing-domain \
  'Application-fixture repository-test manifest must exactly retain existing domainRules'

prepare_application_fixture_repo application-fixture-manifest-existing-test
/usr/bin/ruby -rjson - "$repo/Config/repository-tests.json" <<'RUBY'
path = ARGV.fetch(0)
manifest = JSON.parse(File.binread(path))
manifest.fetch("tests").find { |entry| entry.fetch("path") == "tools/tests/test-base-fixture.sh" }["domains"] = ["admob-integration"]
File.binwrite(path, JSON.generate(manifest))
RUBY
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-manifest-existing-test \
  'Application-fixture repository-test manifest must exactly retain existing tests'

prepare_application_fixture_repo application-fixture-manifest-provider-path
/usr/bin/ruby -rjson - "$repo/Config/repository-tests.json" <<'RUBY'
path = ARGV.fetch(0)
manifest = JSON.parse(File.binread(path))
rule = manifest.fetch("domainRules").find { |entry| entry.fetch("domain") == "admob-integration" }
rule.fetch("paths") << "docs/admob-integration.md"
rule.fetch("paths").sort!
File.binwrite(path, JSON.generate(manifest))
RUBY
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-manifest-provider-path \
  'new repository-test domain coverage must be additive and provider-bound'

prepare_application_fixture_repo application-fixture-manifest-domain-name
/usr/bin/ruby -rjson - "$repo/Config/repository-tests.json" <<'RUBY'
path = ARGV.fetch(0)
manifest = JSON.parse(File.binread(path))
rule = manifest.fetch("domainRules").find { |entry| entry.fetch("domain") == "admob-integration" }
rule["domain"] = "AdMob-integration"
manifest.fetch("tests").find { |entry| entry.fetch("path") == "tools/tests/test-admob-integration.sh" }["domains"] = ["AdMob-integration"]
manifest.fetch("domainRules").sort_by! { |entry| entry.fetch("domain") }
File.binwrite(path, JSON.generate(manifest))
RUBY
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-manifest-domain-name \
  'new repository-test domain must use the Application-fixture provider namespace'

prepare_application_fixture_repo application-fixture-manifest-path-escape
/usr/bin/ruby -rjson - "$repo/Config/repository-tests.json" <<'RUBY'
path = ARGV.fetch(0)
manifest = JSON.parse(File.binread(path))
rule = manifest.fetch("domainRules").find { |entry| entry.fetch("domain") == "admob-integration" }
rule.fetch("paths") << "tools/tests/fixtures/admob-integration/../escape"
rule.fetch("paths").sort!
File.binwrite(path, JSON.generate(manifest))
RUBY
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-manifest-path-escape \
  'new repository-test domain.paths'

prepare_application_fixture_repo application-fixture-manifest-prefix-escape
/usr/bin/ruby -rjson - "$repo/Config/repository-tests.json" <<'RUBY'
path = ARGV.fetch(0)
manifest = JSON.parse(File.binread(path))
rule = manifest.fetch("domainRules").find { |entry| entry.fetch("domain") == "admob-integration" }
rule.fetch("prefixes") << "tools/tests/fixtures/admob-integration/../"
rule.fetch("prefixes").sort!
File.binwrite(path, JSON.generate(manifest))
RUBY
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-manifest-prefix-escape \
  'new repository-test domain.prefixes'

prepare_application_fixture_repo application-fixture-manifest-domain-test
/usr/bin/ruby -rjson - "$repo/Config/repository-tests.json" <<'RUBY'
path = ARGV.fetch(0)
manifest = JSON.parse(File.binread(path))
manifest.fetch("domainRules") << {
  "domain" => "admob-secondary", "paths" => [],
  "prefixes" => ["tools/tests/fixtures/admob-integration/"]
}
manifest.fetch("domainRules").sort_by! { |entry| entry.fetch("domain") }
File.binwrite(path, JSON.generate(manifest))
RUBY
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-manifest-domain-test \
  'every new repository-test domain requires a new provider test'

prepare_application_fixture_repo application-fixture-cli-project
FAKE_PROJECT_PATH=TemplateApp.xcodeproj \
  expect_application_fixture_snapshot_failure application-fixture-cli-project \
  '--project must exactly match the sealed Application-fixture binding'

prepare_application_fixture_repo application-fixture-visual
/usr/bin/ruby -I"$source_repo/tools/lib" -rissue-contract -rjson - "$contract" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.binread(path))
document.fetch("deliveryStage")["name"] = "harden"
document.fetch("verificationScope")["name"] = "targeted"
document.fetch("verification").fetch("acceptanceMappings").fetch(1).fetch("checks") << "visual:iphone-ja"
File.binwrite(path, IOSTemplate::IssueContract.canonical_json(document))
RUBY
expect_application_fixture_snapshot_failure application-fixture-visual \
  'Application-fixture binding must retain xcodebuild-stage without visual evidence'

prepare_application_fixture_repo application-fixture-live-app
printf '%s\n' CHANGED-LIVE-SOURCE >"$repo/Sources/App.swift"
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-live-app \
  'Application-fixture diff path is not declared by the sealed binding: Sources/App.swift'

prepare_application_fixture_repo application-fixture-root-project
printf '%s\n' CHANGED-ROOT-PROJECT >"$repo/TemplateApp.xcodeproj/project.pbxproj"
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-root-project \
  'Application-fixture diff path is not declared by the sealed binding: TemplateApp.xcodeproj/project.pbxproj'

prepare_application_fixture_repo application-fixture-other-provider
mkdir -p "$repo/.agents/skills/stripe-monetization"
printf '%s\n' '# Stripe provider skill' >"$repo/.agents/skills/stripe-monetization/SKILL.md"
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-other-provider \
  'Application-fixture diff path is not declared by the sealed binding: .agents/skills/stripe-monetization/SKILL.md'

prepare_application_fixture_repo application-fixture-core-tool
printf '%s\n' '#!/bin/sh' 'exit 0' >"$repo/tools/verify-ios-issue.sh"
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-core-tool \
  'Application-fixture diff path is not declared by the sealed binding: tools/verify-ios-issue.sh'

prepare_application_fixture_repo application-fixture-delete
git -C "$repo" rm -q -- docs/base.md
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-delete \
  'Application-fixture diff must not delete, copy, or rename tracked paths'

prepare_application_fixture_repo application-fixture-rename
git -C "$repo" mv docs/base.md docs/base-renamed.md
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-rename \
  'Application-fixture diff must not delete, copy, or rename tracked paths'

prepare_application_fixture_repo application-fixture-gitlink
git -C "$repo" update-index --add --cacheinfo "160000,$head_sha,tools/tests/fixtures/admob-integration/vendor"
git -C "$repo" commit -q -m fixture-gitlink
refresh_head_paths
: >"$fake_log"
expect_application_fixture_snapshot_failure application-fixture-gitlink \
  'Head tree contains a gitlink, special mode, or unsafe path'

prepare_application_fixture_repo application-fixture-mode
chmod +x "$repo/tools/tests/fixtures/admob-integration/AdMobFixtureApp.xcodeproj/project.pbxproj"
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-mode \
  'Application-fixture binding project must contain a committed project.pbxproj'

prepare_application_fixture_repo application-fixture-link
/bin/rm "$repo/.claude/skills/admob-monetization"
/bin/ln -s ../../.agents/skills/stripe-monetization "$repo/.claude/skills/admob-monetization"
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-link \
  'Application-fixture Head Claude skill alias must be an exact provider symlink'

prepare_application_fixture_repo application-fixture-second-project
mkdir -p "$repo/tools/tests/fixtures/admob-integration/AdMobOther.xcodeproj"
printf '%s\n' '{}' >"$repo/tools/tests/fixtures/admob-integration/AdMobOther.xcodeproj/project.pbxproj"
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-second-project \
  'Application-fixture binding fixtureRoot must contain exactly its one committed project'

prepare_application_fixture_repo application-fixture-nested-project
mkdir -p "$repo/tools/tests/fixtures/admob-integration/AdMobFixtureApp.xcodeproj/Nested/Other.xcodeproj"
printf '%s\n' '{}' \
  >"$repo/tools/tests/fixtures/admob-integration/AdMobFixtureApp.xcodeproj/Nested/Other.xcodeproj/project.pbxproj"
commit_application_fixture_mutation
expect_application_fixture_snapshot_failure application-fixture-nested-project \
  'Application-fixture binding fixtureRoot must contain exactly its one committed project'

prepare_application_fixture_repo application-fixture-execute 2
if ! FAKE_APPLICATION_FIXTURE=1 FAKE_OBSERVE_CLEANUP=1 run_execute \
    >"$scratch/application-fixture-execute.stdout" \
    2>"$scratch/application-fixture-execute.stderr"; then
  echo 'Application-fixture execute failed' >&2
  /bin/cat "$scratch/application-fixture-execute.stderr" >&2
  exit 1
fi
[[ "$(/bin/cat "$scratch/application-fixture-execute.stdout")" == "$final" ]] || {
  echo 'Application-fixture execute did not publish canonical stage evidence' >&2
  /bin/cat "$scratch/application-fixture-execute.stdout" >&2
  exit 1
}
[[ -f "$final" && ! -e "$draft" ]] || {
  echo 'Application-fixture execute did not retain only final nonvisual evidence' >&2
  exit 1
}
/usr/bin/jq -e '
  .executionRoute == "xcodebuild-stage" and
  .changeClassification == "application-code" and
  .reason == "Delivery stage shape passed; not release-ready." and
  .build.status == "passed" and
  .build.scheme == "AdMobFixtureApp" and
  .build.project.path == "tools/tests/fixtures/admob-integration/AdMobFixtureApp.xcodeproj" and
  .tests == {"failed":0,"passed":1,"skipped":0,"status":"passed"} and
  .cases == [{"id":"iphone-ja","mechanicalCheck":"test:AdMobFixtureAppUITests/AdMobFixtureSmokeTests/testJapaneseSmoke()","status":"passed"}] and
  .visualEvaluation == {"findings":[],"status":"not-applicable"} and
  (.simulatorAllocations | length) == 1 and
  any(.acceptanceEvidence[].evidence[]; . == "stage:build") and
  any(.acceptanceEvidence[].evidence[]; . == "stage:unit-tests") and
  any(.acceptanceEvidence[].evidence[]; . == "case:iphone-ja") and
  all(.cases[]; (has("screenshot") | not) and (has("screenshotDigest") | not))
' "$final" >/dev/null || {
  echo 'Application-fixture final stage evidence is incomplete' >&2
  /bin/cat "$final" >&2
  exit 1
}
(cd "$repo" && "$validator_binary" --file ".artifacts/issues/42/$head_sha/verify.json" \
  --expected-issue 42 --expected-base "$base_sha" --expected-head "$head_sha") \
  >"$scratch/application-fixture-execute.validate.stdout" \
  2>"$scratch/application-fixture-execute.validate.stderr" || {
  echo 'Application-fixture canonical final evidence did not revalidate' >&2
  /bin/cat "$scratch/application-fixture-execute.validate.stderr" >&2
  exit 1
}
[[ "$(/bin/cat "$scratch/application-fixture-execute.validate.stdout")" == 'verification evidence is valid' ]] || {
  echo 'Application-fixture canonical final validation returned the wrong result' >&2
  exit 1
}
for selector in \
  'build-for-testing' \
  '-only-testing:AdMobFixtureAppTests/AdMobFixtureTests/testActivation()' \
  '-only-testing:AdMobFixtureAppUITests/AdMobFixtureSmokeTests/testJapaneseSmoke()'; do
  /usr/bin/grep -Fq -- "$selector" "$fake_log" || {
    echo "Application-fixture execute omitted $selector" >&2
    /bin/cat "$fake_log" >&2
    exit 1
  }
done
create_count="$(/usr/bin/awk -F '\t' '$1 == "xcrun" && $3 == "simctl" && $4 == "create" { count++ } END { print count + 0 }' "$fake_log")"
delete_count="$(/usr/bin/awk -F '\t' '$1 == "xcrun" && $3 == "simctl" && $4 == "delete" { count++ } END { print count + 0 }' "$fake_log")"
[[ "$create_count" == 1 && "$delete_count" == 1 ]] || {
  echo 'Application-fixture execute did not create and delete exactly one disposable Simulator' >&2
  /bin/cat "$fake_log" >&2
  exit 1
}
if /usr/bin/awk -F '\t' '$1 == "xcrun" && $3 == "simctl" && $4 == "io" && $6 == "screenshot" { found=1 } END { exit found ? 0 : 1 }' "$fake_log"; then
  echo 'Application-fixture nonvisual execute captured a screenshot' >&2
  exit 1
fi
[[ "$(/bin/cat "$adapter_state/cleanup-observation/checked")" == 'lock, config, directory mode, and no screenshots' ]] || {
  echo 'Application-fixture attempt cleanup was not observed' >&2
  exit 1
}
if /usr/bin/find "$adapter_state" -maxdepth 1 -type f -name 'allocated-*' -print -quit | /usr/bin/grep -q . ||
   { [[ -d "$adapter_state/data" ]] && /usr/bin/find "$adapter_state/data" -mindepth 1 -print -quit | /usr/bin/grep -q .; }; then
  echo 'Application-fixture execute retained its disposable Simulator' >&2
  exit 1
fi
assert_no_failed_attempts

prepare_application_fixture_repo application-fixture-final-project
write_mismatched_application_fixture_evidence
if (cd "$repo" && "$validator_binary" --file ".artifacts/issues/42/$head_sha/verify.json" \
    --expected-issue 42 --expected-base "$base_sha" --expected-head "$head_sha") \
    >"$scratch/application-fixture-final-project.stdout" \
    2>"$scratch/application-fixture-final-project.stderr"; then
  echo 'canonical evidence accepted a build project outside the sealed Application-fixture binding' >&2
  exit 1
fi
/usr/bin/grep -Fq 'build.project.path must exactly match the sealed Application-fixture binding' \
  "$scratch/application-fixture-final-project.stderr" || {
  echo 'canonical evidence rejected the mismatched build project for the wrong reason' >&2
  /bin/cat "$scratch/application-fixture-final-project.stderr" >&2
  exit 1
}
[[ ! -s "$fake_log" ]] || { echo 'canonical evidence check reached Xcode or Simulator' >&2; exit 1; }

assert_runner_publication_cleanup
echo 'Application-fixture runner-input tests passed'
echo "inputs iOS runner application shard passed in $((SECONDS - inputs_shard_started))s"
return 0
fi

if [[ "$inputs_shard" == legacy-preflight ]]; then
for mode in absent missing-unit-test missing-case missing-action both-actions missing-mapping unknown-mapping; do
  prepare_repo "contract-$mode" "$mode"
  expect_execute_failure "contract-$mode" "verification"
  [[ ! -s "$fake_log" ]] || { echo "invalid contract reached Xcode for $mode" >&2; cat "$fake_log" >&2; exit 1; }
done

for mode in wrong duplicate missing unavailable wrong-type wrong-runtime; do
  prepare_repo "simulator-identity-$mode"
  FAKE_SIMULATOR_IDENTITY_MODE="$mode" expect_execute_failure "simulator-identity-$mode" "dedicated Simulator ownership validation failed"
  if /usr/bin/awk -F '\t' '($1 == "xcodebuild" && ($0 ~ /build-for-testing$/ || $0 ~ /test-without-building$/)) || ($1 == "xcrun" && $3 == "simctl" && ($4 == "shutdown" || $4 == "erase" || $4 == "delete")) {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
    echo "invalid full-set Simulator identity reached Xcode or destructive mutation for $mode" >&2; exit 1
  fi
  [[ ! -e "$draft" ]] || { echo "invalid Simulator identity published draft for $mode" >&2; exit 1; }
done

prepare_repo dirty-range
printf '%s\n' dirty >>"$repo/docs/head.md"
expect_execute_failure dirty-range "working tree must be clean"
dirty_failure="$(/usr/bin/find "$(dirname "$draft")/failures" -type f -name 'failure-*.json' -print -quit)"
[[ -n "$dirty_failure" ]] || { echo "dirty preflight did not publish failure evidence" >&2; exit 1; }
/usr/bin/ruby -rjson -e 'd = JSON.parse(File.read(ARGV.fetch(0))); abort unless d["stage"] == "preflight" && d["error"] == "working tree must be clean"' "$dirty_failure"
if /usr/bin/awk -F '\t' '$1 == "xcodebuild" && ($0 ~ /build-for-testing$/ || $0 ~ /test-without-building$/) || ($1 == "xcrun" && $3 == "simctl") {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
  echo "dirty range reached Build or Simulator" >&2; exit 1
fi

prepare_repo invalid-base
invalid_base="ffffffffffffffffffffffffffffffffffffffff"
FAKE_EXPECTED_BASE="$invalid_base" expect_execute_failure invalid-base "expected Base is not a commit"
invalid_base_failure="$(/usr/bin/find "$(dirname "$draft")/failures" -type f -name 'failure-*.json' -print -quit)"
[[ -n "$invalid_base_failure" ]] || { echo "invalid Base preflight did not publish failure evidence" >&2; exit 1; }
/usr/bin/ruby -rjson -e 'd = JSON.parse(File.read(ARGV.fetch(0))); abort unless d["stage"] == "preflight" && d["baseSha"] == ARGV.fetch(1)' "$invalid_base_failure" "$invalid_base"

assert_runner_publication_cleanup
echo "inputs iOS runner legacy-preflight shard passed in $((SECONDS - inputs_shard_started))s"
return 0
fi

prepare_repo warning
FAKE_BUILD_MODE=warning expect_execute_failure warning "build warnings are not allowed"
[[ ! -e "$draft" ]] || { echo "warning failure published draft" >&2; exit 1; }

for mode in failed skipped zero command-fail; do
  prepare_repo "tests-$mode"
  FAKE_TEST_MODE="$mode" expect_execute_failure "tests-$mode" "unit tests"
  [[ ! -e "$draft" ]] || { echo "test failure published draft" >&2; exit 1; }
done

prepare_repo tests-wrong-selector
FAKE_TEST_MODE=wrong-selector expect_execute_failure tests-wrong-selector "unit tests"

prepare_repo tests-two-summary
FAKE_TEST_MODE=two-summary expect_execute_failure tests-two-summary "unit tests"

prepare_repo tests-warning
FAKE_TEST_MODE=warning expect_execute_failure tests-warning "unit test warnings are not allowed"
[[ ! -e "$draft" ]] || { echo "unit-test warning published draft" >&2; exit 1; }

for mode in zero skipped warning; do
  prepare_repo "ui-$mode"
  FAKE_UI_MODE="$mode" expect_execute_failure "ui-$mode" "case iphone-en failed"
  [[ ! -e "$draft" ]] || { echo "invalid UI result published draft" >&2; exit 1; }
done

prepare_repo ui-wrong-selector
FAKE_UI_MODE=wrong-selector expect_execute_failure ui-wrong-selector "case iphone-en failed"

prepare_repo corrupt-png
FAKE_PNG_MODE=corrupt expect_execute_failure corrupt-png "case iphone-en failed"
[[ ! -d "$(dirname "$draft")/iphone-en" ]] || { echo "corrupt PNG was published" >&2; exit 1; }

prepare_repo mutable-config
FAKE_CONFIG_MODE=mutate expect_execute_failure mutable-config "config"
[[ ! -e "$draft" ]] || { echo "mutable config published draft" >&2; exit 1; }

prepare_repo build-failure
printf '%s\n' sentinel >"$draft"
FAKE_BUILD_MODE=fail expect_execute_failure build-failure "build command failed"
grep -Fq sentinel "$draft" || { echo "failed execution replaced existing draft" >&2; exit 1; }
failure_count="$(find "$(dirname "$draft")/failures" -type f -name '*.json' | wc -l | tr -d ' ')"
FAKE_BUILD_MODE=fail expect_execute_failure build-failure-repeat "build command failed"
new_failure_count="$(find "$(dirname "$draft")/failures" -type f -name '*.json' | wc -l | tr -d ' ')"
[[ "$new_failure_count" -gt "$failure_count" ]] || { echo "failure records are not unique" >&2; exit 1; }
if rg -n 'TOKEN-super-secret|configured build failure' "$(dirname "$draft")/failures"; then
  echo "failure record leaked command output" >&2; exit 1
fi

for source in contract matrix; do
  prepare_repo "mutated-$source"
  FAKE_MUTATE_INPUT="$source" expect_execute_failure "mutated-$source" "$source changed during verification"
  [[ ! -e "$draft" ]] || { echo "mutated input published draft" >&2; exit 1; }
done


assert_runner_publication_cleanup
echo "inputs iOS runner legacy-execution shard passed in $((SECONDS - inputs_shard_started))s"
}

if [[ "$inputs_requested_shard" == application ]]; then
  run_inputs_shard application
  exit $?
fi

inputs_parent_started="$SECONDS"
inputs_shard_names=(application legacy-preflight legacy-execution)
inputs_shard_pids=()
cleanup_input_shards() {
  local pid
  for pid in "${inputs_shard_pids[@]}"; do
    /bin/kill "$pid" >/dev/null 2>&1 || true
  done
  for pid in "${inputs_shard_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}
for inputs_shard_name in "${inputs_shard_names[@]}"; do
  (run_inputs_shard "$inputs_shard_name") &
  inputs_shard_pids+=("$!")
done
trap cleanup_input_shards EXIT INT TERM
inputs_shard_status=0
for inputs_shard_index in "${!inputs_shard_pids[@]}"; do
  if ! wait "${inputs_shard_pids[$inputs_shard_index]}"; then
    echo "inputs iOS runner shard failed: ${inputs_shard_names[$inputs_shard_index]}" >&2
    inputs_shard_status=1
  fi
done
inputs_shard_pids=()
trap - EXIT INT TERM
[[ "$inputs_shard_status" == 0 ]] || exit 1
echo "inputs iOS runner tests passed in $((SECONDS - inputs_parent_started))s"
