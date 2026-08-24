#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: premerge-gate.sh --repo OWNER/REPO --issue NUMBER --head-sha SHA' >&2; exit 2; }
fail() { echo "pre-merge gate failed: $*" >&2; exit 1; }

repo='' issue='' head_sha=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ -z "$repo" && $# -ge 2 ]] || usage; repo=$2; shift 2 ;;
    --issue) [[ -z "$issue" && $# -ge 2 ]] || usage; issue=$2; shift 2 ;;
    --head-sha) [[ -z "$head_sha" && $# -ge 2 ]] || usage; head_sha=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ && "$head_sha" =~ ^[0-9a-f]{40}$ ]] || usage

# Durable identity is the first operation. It uses descriptor-bound state and
# contract reads and must complete before any provider CLI can be reached.
identity_json=$(ruby "$repo_root/tools/lib/merge-state.rb" validate-worktree "$repo_root" "$repo" "$issue") || exit 1
identity_field() { jq -er "$1 | strings" <<<"$identity_json"; }
[[ "$(identity_field '.state')" == approved-for-merge ]] || fail 'durable Issue state is not approved-for-merge'
[[ "$(identity_field '.repository')" == "$repo" && "$(jq -er '.issue' <<<"$identity_json")" == "$issue" ]] || fail 'durable repository or Issue differs from the caller'
branch=$(identity_field '.branch')
base_sha=$(identity_field '.baseSha')
[[ "$(identity_field '.headSha')" == "$head_sha" ]] || fail 'durable Head differs from --head-sha'
[[ "$(identity_field '.worktreePath')" == "$repo_root" ]] || fail 'gate is not running in the durable Issue worktree'

git_clean_env=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null)
git_value() { "${git_clean_env[@]}" /usr/bin/git -C "$repo_root" "$@"; }
[[ "$(git_value rev-parse --show-toplevel)" == "$repo_root" ]] || fail 'Git top level differs from the Issue worktree'
[[ "$(git_value symbolic-ref -q HEAD)" == "refs/heads/$branch" ]] || fail 'current branch/ref differs from durable identity'
[[ "$(git_value rev-parse HEAD)" == "$head_sha" ]] || fail 'current Git Head differs from --head-sha'
[[ "$(git_value rev-parse "$base_sha^{commit}")" == "$base_sha" && "$(git_value rev-parse "$head_sha^{commit}")" == "$head_sha" ]] || fail 'base or Head commit is unavailable'
git_value merge-base --is-ancestor "$base_sha" "$head_sha" || fail 'durable Base is not an ancestor of Head'
[[ -z "$(git_value status --porcelain=v1 --untracked-files=all)" ]] || fail 'Issue worktree must be clean'

PREMERGE_IDENTITY_JSON="$identity_json" ruby "$repo_root/tools/lib/premerge-gate.rb" "$repo_root" "$repo" "$issue" "$head_sha"
