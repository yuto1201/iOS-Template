#!/usr/bin/env bash
set -euo pipefail

[[ $# == 0 || ( $# == 1 && ( "$1" == scoped || "$1" == stubborn || "$1" == all ) ) ]] || exit 64
if [[ "${1-}" == all ]]; then
  runner_tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  for runner_test in "$runner_tests_dir/test-ios-runner.sh" "$runner_tests_dir"/test-ios-runner-*.sh; do
    /usr/bin/ruby --disable-gems "$runner_tests_dir/../lib/bounded-command.rb" \
      --stage runner-regression-group --timeout-seconds 900 -- /bin/bash "$runner_test"
  done
  echo "all iOS runner groups passed"
  exit 0
fi

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

if [[ "${1-}" == stubborn ]]; then
  test_stubborn_probe
  echo "stubborn probe runner test passed"
  exit 0
fi

prepare_repo shape-valid valid present shape
run_execute
[[ -e "$final" ]] || { echo "shape runner did not publish verify.json" >&2; exit 1; }
[[ ! -e "$draft" ]] || { echo "shape runner incorrectly created visual-review draft" >&2; exit 1; }
/usr/bin/ruby -rjson - "$final" "$fake_log" <<'RUBY'
final = JSON.parse(File.read(ARGV.fetch(0)))
abort "shape route is wrong" unless final.fetch("executionRoute") == "xcodebuild-stage"
abort "shape claimed release readiness" unless final.fetch("reason") == "Delivery stage shape passed; not release-ready."
abort "shape cases are wrong" unless final.fetch("cases") == [{"id" => "iphone-ja", "mechanicalCheck" => "test:TemplateAppUITests/SmokeTests/testLaunch", "status" => "passed"}]
abort "shape visual result is wrong" unless final.fetch("visualEvaluation") == {"findings" => [], "status" => "not-applicable"}
commands = File.readlines(ARGV.fetch(1)).map { |line| line.chomp.split("\t") }
abort "shape captured a screenshot" if commands.any? { |fields| fields[2..3] == ["simctl", "io"] }
RUBY
prepare_repo scoped-valid valid present iphone-ja
run_execute
write_visual approved
run_finalize
(cd "$repo" && "$validator_binary" --file "$final" --expected-issue 42 --expected-base "$base_sha" --expected-head "$head_sha")
/usr/bin/ruby -rjson - "$final" "$fake_log" <<'RUBY'
final = JSON.parse(File.read(ARGV.fetch(0)))
abort "final must have only Japanese iPhone" unless final["cases"].map { |entry| entry["id"] } == ["iphone-ja"]
abort "visual must have only Japanese iPhone" unless final["visualEvaluation"]["cases"].map { |entry| entry["id"] } == ["iphone-ja"]
commands = File.readlines(ARGV.fetch(1)).map { |line| line.chomp.split("\t") }
screenshots = commands.select { |fields| fields[2..3] == ["simctl", "io"] }
abort "must capture exactly one screenshot" unless screenshots.length == 1 && screenshots.first[4].end_with?("000002")
mutations = commands.select { |fields| fields[2] == "simctl" && !%w[list].include?(fields[3]) }
abort "touched an English or iPad Simulator" unless mutations.all? { |fields| fields[4] == "00000000-0000-0000-0000-000000000002" }
puts "scoped runner: 1 case, 1 screenshot, 1 visual case; no English/iPad Simulator operations"
RUBY
prepare_repo scoped-mismatch valid present iphone-ja
write_matrix "$matrix" full
expect_execute_failure scoped-mismatch "verification contract is absent or incomplete"
! rg -q 'build-for-testing|simctl' "$fake_log"
prepare_repo scoped-foundation valid present iphone-ja
printf '%s\n' REQUIRED-FULL >"$repo/Config/Feature.xcconfig"
git -C "$repo" add Config/Feature.xcconfig
git -C "$repo" commit -q -m foundation
refresh_head_paths
expect_execute_failure scoped-foundation "full verification is required"
! rg -q 'build-for-testing|simctl' "$fake_log"

prepare_repo shape-timeout valid present shape
timeout_hold="$scratch/shape-timeout-hold"
/bin/sleep 60 &
unrelated_timeout_pid=$!
if IOS_TEMPLATE_XCODEBUILD_TIMEOUT_SECONDS=1 FAKE_HOLD_BUILD_FILE="$timeout_hold" run_execute >"$scratch/shape-timeout.stdout" 2>"$scratch/shape-timeout.stderr"; then
  echo "shape timeout unexpectedly returned success" >&2; exit 1
fi
grep -Fq 'timed out at build' "$scratch/shape-timeout.stderr"
grep -Fq 'elapsedSeconds=' "$scratch/shape-timeout.stderr"
/bin/kill -0 "$unrelated_timeout_pid" || { echo "timeout terminated an unrelated project process" >&2; exit 1; }
[[ ! -e "$final" && ! -e "$draft" ]] || { echo "timeout published successful evidence" >&2; exit 1; }
/usr/bin/ruby - "$fake_log" <<'RUBY'
lines = File.readlines(ARGV.fetch(0), chomp: true).map { |line| line.split("\t") }
mutations = lines.select { |fields| fields[0] == "xcrun" && fields[2] == "simctl" && %w[terminate shutdown erase delete].include?(fields[3]) }
owned = "00000000-0000-0000-0000-000000000002"
abort "timeout cleanup touched a Simulator outside the invocation-owned shape case" unless mutations.all? { |fields| fields[4] == owned }
abort "timeout cleanup did not reclaim the invocation-owned Simulator" unless mutations.any? { |fields| fields[3] == "shutdown" } && mutations.any? { |fields| fields[3] == "erase" }
RUBY
/bin/kill "$unrelated_timeout_pid"
wait "$unrelated_timeout_pid" 2>/dev/null || true
unrelated_timeout_pid=''

prepare_repo shape-lock-timeout valid present shape
lock_timeout_hold="$scratch/shape-lock-timeout-hold"
(
  for _ in $(/usr/bin/jot 2000); do
    [[ ! -e "$lock_timeout_hold.started" ]] || break
    /bin/sleep 0.01
  done
  [[ -e "$lock_timeout_hold.started" ]] || exit 1
  /bin/sleep 2
  : >"$lock_timeout_hold.release"
) &
lock_timeout_release_pid=$!
if IOS_TEMPLATE_VERIFICATION_TIMEOUT_SECONDS=1 FAKE_HOLD_BUILD_FILE="$lock_timeout_hold" \
    run_execute >"$scratch/shape-lock-timeout.stdout" 2>"$scratch/shape-lock-timeout.stderr"; then
  wait "$lock_timeout_release_pid" || true
  echo "expired verification lock unexpectedly allowed success" >&2
  exit 1
fi
wait "$lock_timeout_release_pid"
grep -Fq 'timed out at verification-lock' "$scratch/shape-lock-timeout.stderr" || {
  echo "verification lock timeout did not report its bounded stage" >&2
  exit 1
}
[[ ! -e "$final" && ! -e "$draft" ]] || {
  echo "verification lock timeout published successful evidence" >&2
  exit 1
}
assert_no_failed_attempts


assert_runner_publication_cleanup
echo "scoped iOS runner tests passed"
