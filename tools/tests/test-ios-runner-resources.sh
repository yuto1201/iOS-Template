#!/usr/bin/env bash
set -euo pipefail

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

prepare_repo case-failure
FAKE_CASE_MODE=launch-fail expect_execute_failure case-failure "case iphone-ja failed"
[[ ! -e "$draft" ]] || { echo "case failure published draft" >&2; exit 1; }
/usr/bin/awk -F '\t' '$3 == "simctl" && $4 == "terminate" && $5 == "00000000-0000-0000-0000-000000000002" {count++} END {exit count >= 2 ? 0 : 1}' "$fake_log" || { echo "case failure did not terminate active app" >&2; exit 1; }
/usr/bin/awk -F '\t' '$3 == "simctl" && $4 == "erase" && $5 == "00000000-0000-0000-0000-000000000002" {count++} END {exit count >= 2 ? 0 : 1}' "$fake_log" || { echo "launch failure did not reclaim the active Simulator" >&2; exit 1; }

for mode in install screenshot terminate-after-case shutdown-after-case erase-after-case; do
  prepare_repo "resource-failure-$mode"
  FAKE_RESOURCE_FAILURE="$mode" expect_execute_failure "resource-failure-$mode" "case iphone-en failed"
  [[ ! -e "$draft" ]] || { echo "resource failure published draft for $mode" >&2; exit 1; }
  failure_file="$(/usr/bin/find "$(dirname "$draft")/failures" -type f -name 'failure-*.json' -print -quit)"
  [[ -n "$failure_file" ]] || { echo "resource failure lacked sanitized failure evidence for $mode" >&2; exit 1; }
  /usr/bin/ruby -rjson -e 'd = JSON.parse(File.read(ARGV.fetch(0))); abort unless d["status"] == "failed" && d["stage"].start_with?("case-iphone-en") && !d["error"].empty?' "$failure_file"
  if /usr/bin/awk -F '\t' '$1 == "xcrun" && $3 == "simctl" && $4 == "delete" {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
    echo "resource cleanup deleted a Simulator for $mode" >&2; exit 1
  fi
done

prepare_repo case-crash
FAKE_CASE_MODE=crash expect_execute_failure case-crash "case iphone-ja failed"

prepare_repo post-ui-crash
FAKE_CASE_MODE=post-ui-crash expect_execute_failure post-ui-crash "case iphone-en failed"

prepare_repo ui-pid-replacement
FAKE_CASE_MODE=pid-replacement run_execute
[[ -f "$draft" ]] || { echo "UI PID replacement did not complete verification" >&2; exit 1; }
/usr/bin/awk -F '\t' '$3 == "simctl" && $4 == "spawn" && $5 == "00000000-0000-0000-0000-000000000001" && $6 == "/bin/kill" && $8 == "9876" {found=1} END {exit found ? 0 : 1}' "$fake_log" || {
  echo "runner did not probe the reacquired UI application PID" >&2; exit 1
}

prepare_repo app-plist-symlink
FAKE_BUILD_MODE=plist-symlink expect_execute_failure app-plist-symlink "built application"

prepare_repo app-nested-symlink
FAKE_APP_MODE=nested-symlink expect_execute_failure app-nested-symlink "built application"

prepare_repo app-special-file
FAKE_APP_MODE=special-file expect_execute_failure app-special-file "built application"

prepare_repo app-content-mutation
FAKE_APP_MODE=mutate-after-install expect_execute_failure app-content-mutation "built application"

prepare_repo app-path-replacement
FAKE_APP_MODE=replace-after-install expect_execute_failure app-path-replacement "built application"

prepare_repo app-structural-collision
FAKE_APP_MODE=structural-collision expect_execute_failure app-structural-collision "built application"


assert_runner_publication_cleanup
echo "resources iOS runner tests passed"
