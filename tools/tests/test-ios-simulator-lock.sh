#!/usr/bin/env bash
set -euo pipefail

source_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
wrapper="$source_repo/tools/with-ios-simulator-lock.sh"
scratch="$(mktemp -d -t ios-simulator-lock.XXXXXX)"
scratch="$(cd "$scratch" && pwd -P)"
holder_pid=""
cleanup() {
  if [[ -n "$holder_pid" ]]; then
    /bin/kill "$holder_pid" >/dev/null 2>&1 || true
    wait "$holder_pid" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$scratch"
}
trap cleanup EXIT

if [[ ! -x "$wrapper" ]]; then
  echo "iOS Simulator lock RED: production wrapper is absent" >&2
  exit 1
fi

repo="$scratch/repository"
/bin/mkdir -p "$repo"
/usr/bin/git -C "$repo" init -q
/usr/bin/git -C "$repo" config user.name 'Simulator Lock Test'
/usr/bin/git -C "$repo" config user.email 'simulator-lock@example.invalid'
printf '%s\n' base >"$repo/README.md"
/usr/bin/git -C "$repo" add -- README.md
/usr/bin/git -C "$repo" commit -q -m base
linked_worktree="$scratch/linked-worktree"
/usr/bin/git -C "$repo" worktree add -q -b lock-contender "$linked_worktree"

run_locked() {
  (cd "$repo" && "$wrapper" "$@")
}

run_locked_from_linked_worktree() {
  (cd "$linked_worktree" && "$wrapper" "$@")
}

output="$(run_locked --timeout 0 -- /bin/sh -c 'printf success')"
[[ "$output" == "success" ]] || { echo "lock wrapper lost command output" >&2; exit 1; }

set +e
run_locked --timeout 0 -- /bin/sh -c 'exit 23'
failure_status="$?"
set -e
[[ "$failure_status" -eq 23 ]] || {
  echo "lock wrapper did not propagate command exit status" >&2
  exit 1
}

# A failed command must release the kernel lock for the next process.
run_locked --timeout 0 -- /usr/bin/true

ready="$scratch/ready"
release="$scratch/release"
/usr/bin/mkfifo "$release"
(
  cd "$repo"
  "$wrapper" --timeout 5 -- /bin/sh -c 'printf ready >"$1"; read -r _ <"$2"' lock-holder "$ready" "$release"
) &
holder_pid="$!"

for _ in {1..100}; do
  [[ -s "$ready" ]] && break
  /bin/sleep 0.02
done
[[ -s "$ready" ]] || { echo "lock holder did not acquire the lock" >&2; exit 1; }

contender_marker="$scratch/contender-ran"
if run_locked_from_linked_worktree --timeout 0 -- /bin/sh -c 'printf ran >"$1"' contender "$contender_marker" \
    >"$scratch/contender.stdout" 2>"$scratch/contender.stderr"; then
  echo "second Simulator verification acquired an already-held repository lock" >&2
  exit 1
fi
[[ ! -e "$contender_marker" ]] || { echo "contending command executed without the lock" >&2; exit 1; }

printf '%s\n' release >"$release" &
wait "$holder_pid"
holder_pid=""

# The lock is crash-released by the kernel when the holder command exits.
run_locked --timeout 0 -- /usr/bin/true

echo "iOS Simulator lock tests passed"
