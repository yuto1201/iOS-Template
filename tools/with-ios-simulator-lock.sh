#!/bin/bash -p
set -euo pipefail

unset CDPATH ENV BASH_ENV GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

usage() {
  echo "usage: tools/with-ios-simulator-lock.sh --timeout SECONDS -- command [arguments ...]" >&2
  exit 64
}

[[ "$#" -ge 4 && "$1" == "--timeout" && "$3" == "--" ]] || usage
timeout="$2"
shift 3
[[ "$timeout" =~ ^[0-9]+$ ]] || usage
[[ "$#" -gt 0 ]] || usage

repo_root="$(/usr/bin/git -c core.fsmonitor=false -c core.hooksPath=/dev/null rev-parse --show-toplevel 2>/dev/null)" || {
  echo "Simulator lock requires a Git worktree" >&2
  exit 1
}
repo_root="$(cd "$repo_root" && /bin/pwd -P)"
common_git_dir="$(/usr/bin/git -C "$repo_root" -c core.fsmonitor=false -c core.hooksPath=/dev/null \
  rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
  echo "unable to resolve the repository identity for Simulator locking" >&2
  exit 1
}
common_git_dir="$(cd "$common_git_dir" && /bin/pwd -P)"
repo_digest="$(printf '%s' "$common_git_dir" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
[[ "$repo_digest" =~ ^[0-9a-f]{64}$ ]] || {
  echo "unable to derive the repository Simulator lock identity" >&2
  exit 1
}

lock_root="/tmp/ios-template-simulator-locks"
if [[ ! -e "$lock_root" ]]; then
  /bin/mkdir -m 700 "$lock_root" 2>/dev/null || true
fi
[[ -d "$lock_root" && ! -L "$lock_root" ]] || {
  echo "Simulator lock directory is not a regular directory" >&2
  exit 1
}
[[ "$(/usr/bin/stat -f '%u' "$lock_root")" == "$(/usr/bin/id -u)" ]] || {
  echo "Simulator lock directory is not owned by the current user" >&2
  exit 1
}
/bin/chmod 700 "$lock_root"

lock_file="$lock_root/$repo_digest.lock"
if [[ -e "$lock_file" && ( -L "$lock_file" || ! -f "$lock_file" ) ]]; then
  echo "Simulator lock path is not a regular file" >&2
  exit 1
fi

exec /usr/bin/lockf -k -t "$timeout" "$lock_file" "$@"
