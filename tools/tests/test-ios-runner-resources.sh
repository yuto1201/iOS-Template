#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

prepare_repo case-failure
FAKE_CASE_MODE=launch-fail expect_execute_failure case-failure "case iphone-ja failed"
[[ ! -e "$draft" ]] || { echo "case failure published draft" >&2; exit 1; }
# iphone-ja runs on the leased dedicated iPhone; after its failed launch the app is terminated and the
# lease is released by shutting the device down.
/usr/bin/ruby - "$fake_log" <<'RUBY'
iphone = "00000000-0000-0000-0000-000000000001"
lines = File.readlines(ARGV.fetch(0), chomp: true).map { |line| line.split("\t") }
simctl = ->(index, command) { lines[index][2] == "simctl" && lines[index][3] == command && lines[index][4] == iphone }
failed_launch = lines.each_index.select { |index| simctl.call(index, "launch") }.last
abort "the failing iphone-ja launch was not reached" unless failed_launch
after = (failed_launch + 1...lines.length)
abort "case failure did not terminate active app" unless after.any? { |index| simctl.call(index, "terminate") }
abort "launch failure did not release the leased Simulator" unless after.any? { |index| simctl.call(index, "shutdown") }
abort "launch failure deleted a Simulator" if lines.any? { |fields| fields[2] == "simctl" && fields[3] == "delete" }
RUBY

for mode in install screenshot terminate-after-case shutdown-after-case erase-after-case; do
  prepare_repo "resource-failure-$mode"
  # The iPhone is erased when the next case leases it, so an erase failure after iphone-en surfaces as
  # the iphone-ja lease failing; every other mode fails inside iphone-en.
  failed_case=iphone-en failure_message="case iphone-en failed"
  if [[ "$mode" == erase-after-case ]]; then
    failed_case=iphone-ja failure_message="case iphone-ja Simulator allocation failed"
  fi
  FAKE_RESOURCE_FAILURE="$mode" expect_execute_failure "resource-failure-$mode" "$failure_message"
  assert_no_failed_attempts
  [[ ! -e "$draft" ]] || { echo "resource failure published draft for $mode" >&2; exit 1; }
  failure_file="$(/usr/bin/find "$(dirname "$draft")/failures" -type f -name 'failure-*.json' -print -quit)"
  [[ -n "$failure_file" ]] || { echo "resource failure lacked sanitized failure evidence for $mode" >&2; exit 1; }
  /usr/bin/ruby -rjson -e 'd = JSON.parse(File.read(ARGV.fetch(0))); abort unless d["status"] == "failed" && d["stage"].start_with?("case-#{ARGV.fetch(1)}") && !d["error"].empty?' "$failure_file" "$failed_case"
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
assert_no_failed_attempts
[[ -f "$draft" ]] || { echo "UI PID replacement did not complete verification" >&2; exit 1; }
for case_id in iphone-en iphone-ja ipad-en ipad-ja; do
  [[ -f "$(dirname "$draft")/$case_id/screenshot.png" ]] || { echo "cleanup removed canonical screenshot" >&2; exit 1; }
done
/usr/bin/awk -F '\t' '$1 == "host" && $2 == "kill" && $3 == "-0" && $4 == "9876" {found=1} END {exit found ? 0 : 1}' "$fake_log" || {
  echo "runner did not probe the reacquired UI application PID" >&2; exit 1
}

# The host process identity must be this dedicated device's installed executable (#215).
for mode in ps-other-executable ps-other-device; do
  prepare_repo "identity-$mode"
  FAKE_CASE_MODE="$mode" expect_execute_failure "identity-$mode" "case iphone-en failed: current application identity"
  [[ ! -e "$draft" ]] || { echo "process identity failure published draft for $mode" >&2; exit 1; }
done

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
