#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

prepare_repo concurrent-lock
hold_file="$scratch/concurrent-hold"
FAKE_HOLD_BUILD_FILE="$hold_file" run_execute >"$scratch/concurrent-first.stdout" 2>"$scratch/concurrent-first.stderr" &
first_runner_pid=$!
for _ in $(/usr/bin/jot 600); do
  [[ ! -e "$hold_file.started" ]] || break
  /bin/sleep 0.05
done
[[ -e "$hold_file.started" ]] || { echo "first concurrent runner did not reach Build" >&2; exit 1; }
expect_execute_failure concurrent-lock "lock"
workspace="$(runner_workspace)"
attempt_count="$(/usr/bin/find "$workspace/Attempts" -mindepth 1 -maxdepth 1 -type d -name 'attempt-*' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$attempt_count" == 1 ]] || { echo "lock loser retained a private attempt" >&2; exit 1; }
: >"$hold_file.release"
wait "$first_runner_pid"
[[ -f "$draft" ]] || { echo "concurrent lock winner did not publish draft" >&2; exit 1; }

prepare_repo killed-lock-owner
killed_hold="$scratch/killed-lock-hold"
FAKE_HOLD_BUILD_FILE="$killed_hold" run_execute >"$scratch/killed-lock.stdout" 2>"$scratch/killed-lock.stderr" &
killed_runner_pid=$!
for _ in $(/usr/bin/jot 600); do
  [[ ! -e "$killed_hold.started" ]] || break
  /bin/sleep 0.05
done
[[ -e "$killed_hold.started" ]] || { echo "kill fixture did not acquire lock" >&2; exit 1; }
killed_owner_pid="$(/bin/cat "$killed_hold.owner")"
[[ "$killed_owner_pid" =~ ^[1-9][0-9]*$ ]] || { echo "kill fixture recorded an invalid runner owner" >&2; exit 1; }
/bin/kill -KILL "$killed_owner_pid"
wait "$killed_runner_pid" 2>/dev/null || true
run_execute
: >"$killed_hold.release"
[[ -f "$draft" ]] || { echo "retry after killed owner did not publish draft" >&2; exit 1; }

prepare_repo prebooted
FAKE_PREBOOTED=1 run_execute

prepare_repo fallback
fallback_developer="$scratch/FallbackXcode/Contents/Developer"
mkdir -p "$fallback_developer/usr/bin" "$fallback_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
/bin/cp "$fake_developer/usr/bin/xcodebuild" "$fallback_developer/usr/bin/xcodebuild"
/bin/cp "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" "$fallback_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
/usr/bin/ruby -rjson - "$matrix" "$fallback_developer" <<'RUBY'
path, developer = ARGV
document = JSON.parse(File.read(path))
document.fetch("xcode")["path"] = developer
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
FAKE_PREFERRED_XCODE_INVALID=1 FAKE_FALLBACK_DEVELOPER_DIR="$fallback_developer" run_execute
grep -Fq $'xcode-select\tDEVELOPER_DIR=\t-p' "$fake_log"
/usr/bin/awk -F '\t' -v expected="DEVELOPER_DIR=$fallback_developer" '$1 == "xcodebuild" || $1 == "xcrun" {last=$2} END {exit last == expected ? 0 : 1}' "$fake_log"


assert_runner_publication_cleanup
echo "locking iOS runner tests passed"
