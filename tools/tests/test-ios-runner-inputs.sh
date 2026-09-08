#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

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
echo "inputs iOS runner tests passed"
