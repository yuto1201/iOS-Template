#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-bounded-command.XXXXXX")
unrelated_pid=''
cleanup() {
  if [[ -n "$unrelated_pid" ]]; then
    kill "$unrelated_pid" >/dev/null 2>&1 || true
    wait "$unrelated_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$workspace"
}
trap cleanup EXIT

/bin/sleep 30 &
unrelated_pid=$!

cat >"$workspace/hang.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
/bin/sleep 30 &
child=$!
printf '%s\n' "$child" >"${BOUNDED_CHILD_PID_FILE:?}"
wait "$child"
SH
chmod +x "$workspace/hang.sh"

started=$(date +%s)
if BOUNDED_CHILD_PID_FILE="$workspace/child.pid" \
  ruby "$repo_root/tools/lib/bounded-command.rb" --stage unit-tests --timeout-seconds 1 --grace-seconds 1 -- \
  "$workspace/hang.sh" >"$workspace/stdout" 2>"$workspace/stderr"; then
  echo 'timed command unexpectedly succeeded' >&2
  exit 1
else
  status=$?
fi
elapsed=$(( $(date +%s) - started ))
[[ "$status" -eq 124 ]] || { echo "unexpected timeout status: $status" >&2; exit 1; }
[[ "$elapsed" -lt 8 ]] || { echo "timeout was not finite: ${elapsed}s" >&2; exit 1; }
rg -q 'stage=unit-tests' "$workspace/stderr"
rg -q 'elapsedSeconds=' "$workspace/stderr"
kill -0 "$unrelated_pid" >/dev/null 2>&1 || { echo 'unrelated process was terminated' >&2; exit 1; }
child_pid=$(<"$workspace/child.pid")
if kill -0 "$child_pid" >/dev/null 2>&1; then
  echo 'invocation-owned child survived timeout cleanup' >&2
  exit 1
fi

if rg -n 'simctl[[:space:]]+shutdown[[:space:]]+(all|booted)' "$repo_root/tools" --glob '!tests/**'; then
  echo 'global Simulator shutdown is forbidden' >&2
  exit 1
fi
rg -Fq 'active_case_id="${case_ids[0]}"' "$repo_root/tools/verify-ios-issue.sh"

echo 'bounded command tests passed'
