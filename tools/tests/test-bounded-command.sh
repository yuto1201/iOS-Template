#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg ruby /usr/bin/ruby

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
bounded="$repo_root/tools/lib/bounded-command.rb"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-bounded-command.XXXXXX")
unrelated_pid=''
survivor_pid=''
cleanup() {
  local pid
  for pid in "$unrelated_pid" "$survivor_pid"; do
    if [[ -n "$pid" ]]; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
  rm -rf "$workspace"
}
trap cleanup EXIT

fail() {
  echo "bounded command regression: $1" >&2
  exit 1
}

# Wait up to five seconds for a pid to disappear, so a reclaimed zombie counts as gone.
assert_gone() {
  local pid=$1 label=$2 attempt
  for attempt in $(seq 1 100); do
    kill -0 "$pid" >/dev/null 2>&1 || return 0
    /bin/sleep 0.05
  done
  fail "$label survived"
}

assert_elapsed_file() {
  local file=$1 label=$2 value
  [[ -f "$file" ]] || fail "$label did not write the elapsed file"
  value=$(<"$file")
  [[ "$value" =~ ^[0-9]+\.[0-9]{3}$ ]] || fail "$label wrote a non-measured elapsed value: $value"
}

# Run the wrapper and store its exit status in $status without tripping set -e.
run_bounded() {
  status=0
  "$@" >"$workspace/stdout" 2>"$workspace/stderr" || status=$?
}

/bin/sleep 60 &
unrelated_pid=$!

cat >"$workspace/hang.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
/bin/sleep 30 &
child=$!
printf '%s\n' "$child" >"${BOUNDED_CHILD_PID_FILE:?}"
wait "$child"
SH
cat >"$workspace/leave.sh" <<'SH'
#!/usr/bin/env bash
/bin/sleep 30 &
printf '%s\n' "$!" >"${BOUNDED_CHILD_PID_FILE:?}"
exit 0
SH
cat >"$workspace/leave-stubborn.sh" <<'SH'
#!/usr/bin/env bash
(trap '' TERM; exec /bin/sleep 30) &
printf '%s\n' "$!" >"${BOUNDED_CHILD_PID_FILE:?}"
/bin/sleep 0.2
exit "${BOUNDED_LEADER_STATUS:-0}"
SH
cat >"$workspace/hang-stubborn.sh" <<'SH'
#!/usr/bin/env bash
(trap '' TERM; exec /bin/sleep 30) &
printf '%s\n' "$!" >"${BOUNDED_CHILD_PID_FILE:?}"
/bin/sleep 30
SH
cat >"$workspace/stubborn-leader.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" >"${BOUNDED_CHILD_PID_FILE:?}"
exec /bin/sleep 30
SH
chmod +x "$workspace"/*.sh

# Normal success and normal failure keep the leader status and record the measured elapsed time.
run_bounded ruby "$bounded" --stage ok --timeout-seconds 5 --elapsed-file "$workspace/ok.elapsed" -- /usr/bin/true
[[ "$status" -eq 0 ]] || fail "normal success returned $status"
assert_elapsed_file "$workspace/ok.elapsed" 'normal success'
run_bounded ruby "$bounded" --stage failing --timeout-seconds 5 -- /bin/sh -c 'exit 3'
[[ "$status" -eq 3 ]] || fail "normal failure returned $status"
[[ ! -s "$workspace/stderr" ]] || fail 'normal failure printed a wrapper diagnostic'

# Timeout reclaims the owned group only and reports the measured elapsed time.
started=$(date +%s)
BOUNDED_CHILD_PID_FILE="$workspace/child.pid" \
  run_bounded ruby "$bounded" --stage unit-tests --timeout-seconds 1 --grace-seconds 1 \
  --elapsed-file "$workspace/timeout.elapsed" -- "$workspace/hang.sh"
elapsed=$(( $(date +%s) - started ))
[[ "$status" -eq 124 ]] || fail "unexpected timeout status: $status"
[[ "$elapsed" -lt 8 ]] || fail "timeout was not finite: ${elapsed}s"
rg -q 'stage=unit-tests' "$workspace/stderr" || fail 'timeout diagnostic lacks the stage'
rg -q 'elapsedSeconds=[0-9]+\.[0-9]{3}' "$workspace/stderr" || fail 'timeout diagnostic lacks the measured elapsed time'
assert_elapsed_file "$workspace/timeout.elapsed" 'timeout'
assert_gone "$(<"$workspace/child.pid")" 'invocation-owned child after timeout'

# A TERM-ignoring member left behind when the leader dies within grace is escalated to KILL.
BOUNDED_CHILD_PID_FILE="$workspace/stubborn-timeout.pid" \
  run_bounded ruby "$bounded" --stage stubborn-timeout --timeout-seconds 1 --grace-seconds 1 -- "$workspace/hang-stubborn.sh"
[[ "$status" -eq 124 ]] || fail "stubborn timeout returned $status"
assert_gone "$(<"$workspace/stubborn-timeout.pid")" 'TERM-ignoring member after timeout'

# A member left in the group after the leader exits normally is reclaimed and fails the run.
started=$(date +%s)
BOUNDED_CHILD_PID_FILE="$workspace/leave.pid" \
  run_bounded ruby "$bounded" --stage residual --timeout-seconds 10 --grace-seconds 1 \
  --elapsed-file "$workspace/residual.elapsed" -- "$workspace/leave.sh"
elapsed=$(( $(date +%s) - started ))
[[ "$status" -eq 122 ]] || fail "residual member returned $status"
[[ "$elapsed" -lt 10 ]] || fail "residual reclaim was not bounded: ${elapsed}s"
rg -q 'stage=residual' "$workspace/stderr" || fail 'residual diagnostic lacks the stage'
rg -q 'residualMembers=1' "$workspace/stderr" || fail 'residual diagnostic lacks the member count'
rg -q 'elapsedSeconds=[0-9]+\.[0-9]{3}' "$workspace/stderr" || fail 'residual diagnostic lacks the measured elapsed time'
rg -q 'leaderStatus=0' "$workspace/stderr" || fail 'residual diagnostic lacks the leader status'
assert_elapsed_file "$workspace/residual.elapsed" 'residual'
assert_gone "$(<"$workspace/leave.pid")" 'residual member'

# A TERM-ignoring residual member is escalated to KILL; a failing leader still reports the residual.
BOUNDED_CHILD_PID_FILE="$workspace/leave-stubborn.pid" BOUNDED_LEADER_STATUS=4 \
  run_bounded ruby "$bounded" --stage residual-stubborn --timeout-seconds 10 --grace-seconds 1 -- "$workspace/leave-stubborn.sh"
[[ "$status" -eq 122 ]] || fail "stubborn residual returned $status"
rg -q 'leaderStatus=4' "$workspace/stderr" || fail 'stubborn residual diagnostic lacks the failing leader status'
assert_gone "$(<"$workspace/leave-stubborn.pid")" 'TERM-ignoring residual member'

# A member that survives the final signal fails with its own status and count. The test hook only
# weakens the final signal, so it can make the wrapper fail but never report success.
BOUNDED_CHILD_PID_FILE="$workspace/survivor.pid" IOS_TEMPLATE_BOUNDED_COMMAND_TEST_FINAL_SIGNAL=0 \
  run_bounded ruby "$bounded" --stage unreclaimable --timeout-seconds 10 --grace-seconds 1 -- "$workspace/leave-stubborn.sh"
survivor_pid=$(<"$workspace/survivor.pid")
[[ "$status" -eq 123 ]] || fail "unreclaimable member returned $status"
rg -q 'stage=unreclaimable' "$workspace/stderr" || fail 'unreclaimable diagnostic lacks the stage'
rg -q 'residualMembers=1' "$workspace/stderr" || fail 'unreclaimable diagnostic lacks the surviving count'
kill -0 "$survivor_pid" >/dev/null 2>&1 || fail 'the survivor fixture did not survive the weakened final signal'
kill -KILL "$survivor_pid" >/dev/null 2>&1 || true
assert_gone "$survivor_pid" 'survivor fixture cleanup'
survivor_pid=''
# A TERM-ignoring leader that outlives grace is killed and the timeout is still reported.
BOUNDED_CHILD_PID_FILE="$workspace/stubborn-leader.pid" \
  run_bounded ruby "$bounded" --stage stubborn-leader --timeout-seconds 1 --grace-seconds 1 -- "$workspace/stubborn-leader.sh"
[[ "$status" -eq 124 ]] || fail "TERM-ignoring leader returned $status"
assert_gone "$(<"$workspace/stubborn-leader.pid")" 'TERM-ignoring leader after KILL'

# A leader that is still unreaped after the final signal ends the wait at its deadline and fails
# with the unreclaimed status. The hook only weakens the signal; the waiting logic is unchanged.
started=$(date +%s)
BOUNDED_CHILD_PID_FILE="$workspace/unreaped-leader.pid" IOS_TEMPLATE_BOUNDED_COMMAND_TEST_FINAL_SIGNAL=0 \
  run_bounded ruby "$bounded" --stage unreaped-leader --timeout-seconds 1 --grace-seconds 1 -- "$workspace/stubborn-leader.sh"
elapsed=$(( $(date +%s) - started ))
survivor_pid=$(<"$workspace/unreaped-leader.pid")
[[ "$status" -eq 123 ]] || fail "unreaped leader returned $status"
[[ "$elapsed" -lt 12 ]] || fail "the post-signal leader wait was not bounded: ${elapsed}s"
rg -q 'could not reclaim process-group members: stage=unreaped-leader' "$workspace/stderr" || fail 'unreaped leader diagnostic lacks the stage'
rg -q 'residualMembers=1' "$workspace/stderr" || fail 'unreaped leader diagnostic lacks the surviving count'
rg -q 'timeoutSeconds=1' "$workspace/stderr" || fail 'unreaped leader diagnostic lacks the timeout'
kill -0 "$survivor_pid" >/dev/null 2>&1 || fail 'the unreaped leader fixture did not survive the weakened final signal'
kill -KILL "$survivor_pid" >/dev/null 2>&1 || true
assert_gone "$survivor_pid" 'unreaped leader fixture cleanup'
survivor_pid=''

# No leader wait may block without WNOHANG, so every path reaches its deadline and diagnostic.
if rg -n 'waitpid2?\(child\)' "$bounded"; then
  fail 'bounded-command.rb waits for the leader without a deadline'
fi

run_bounded env IOS_TEMPLATE_BOUNDED_COMMAND_TEST_FINAL_SIGNAL=HUP ruby "$bounded" --stage bad-hook --timeout-seconds 5 -- /usr/bin/true
[[ "$status" -eq 2 ]] || fail "an unknown final-signal hook value returned $status"

# INT and TERM delivered to the wrapper are forwarded to the group and reclaim it.
for forwarded in TERM INT; do
  expected=143
  [[ "$forwarded" == INT ]] && expected=130
  rm -f "$workspace/forward.pid"
  ( trap - INT; exec env BOUNDED_CHILD_PID_FILE="$workspace/forward.pid" \
      ruby "$bounded" --stage "forward-$forwarded" --timeout-seconds 30 --grace-seconds 1 -- "$workspace/hang.sh" ) \
    >"$workspace/stdout" 2>"$workspace/stderr" &
  wrapper_pid=$!
  for attempt in $(seq 1 100); do
    [[ -s "$workspace/forward.pid" ]] && break
    /bin/sleep 0.05
  done
  [[ -s "$workspace/forward.pid" ]] || fail "forward-$forwarded fixture did not start"
  kill -"$forwarded" "$wrapper_pid"
  status=0
  wait "$wrapper_pid" || status=$?
  [[ "$status" -eq "$expected" ]] || fail "forwarded $forwarded returned $status"
  assert_gone "$(<"$workspace/forward.pid")" "child after forwarded $forwarded"
done

kill -0 "$unrelated_pid" >/dev/null 2>&1 || fail 'an unrelated process was terminated'

# The Xcode wrappers report the measured elapsed time, not the configured timeout.
cat >"$workspace/fake-xcodebuild" <<'SH'
#!/bin/bash
/bin/sleep 30
SH
chmod +x "$workspace/fake-xcodebuild"
xcode_message=$(
  source "$repo_root/tools/lib/xcode.sh"
  XCODEBUILD_PATH="$workspace/fake-xcodebuild"
  XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  IOS_TEMPLATE_XCODEBUILD_TIMEOUT_SECONDS=1
  code=0
  run_xcodebuild -version >/dev/null 2>&1 || code=$?
  [[ "$code" -eq 124 ]] || { echo "unexpected run_xcodebuild status $code"; exit 0; }
  printf '%s\n' "$IOS_TEMPLATE_LAST_TIMEOUT_MESSAGE"
)
[[ "$xcode_message" =~ ^timed\ out\ at\ xcodebuild\;\ elapsedSeconds=[0-9]+\.[0-9]{3}\;\ timeoutSeconds=1$ ]] ||
  fail "run_xcodebuild timeout message is not measured: $xcode_message"
if rg -n 'elapsedSeconds=\$timeout_seconds' "$repo_root/tools/lib/xcode.sh"; then
  fail 'xcode.sh still reports the configured timeout as the elapsed time'
fi

if rg -n 'simctl[[:space:]]+shutdown[[:space:]]+(all|booted)' "$repo_root/tools" --glob '!**/tests/**'; then
  echo 'global Simulator shutdown is forbidden' >&2
  exit 1
fi
rg -Fq 'active_case_id="${case_ids[0]}"' "$repo_root/tools/verify-ios-issue.sh"

echo 'bounded command tests passed'
