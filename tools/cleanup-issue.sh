#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: cleanup-issue.sh --repo OWNER/REPO --issue NUMBER' >&2; exit 2; }
repo='' issue=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --issue) issue=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || usage
fail() { echo "cleanup refused: $*" >&2; exit 1; }
[[ -L "$repo_root/.artifacts" ]] || fail 'Issue worktree lacks the canonical .artifacts link'
primary_root=$(cd "$repo_root/../.." && pwd -P)
artifacts_root=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$repo_root/.artifacts") || fail 'canonical .artifacts link is broken'
[[ "$artifacts_root" == "$primary_root/.artifacts" ]] || fail 'canonical .artifacts link does not resolve to the primary checkout'
state="$repo_root/.artifacts/issues/$issue/state.json"
[[ -f "$state" && ! -L "$state" ]] || fail 'durable Issue state is missing or unsafe'
state_fields=$(jq -er '[.schemaVersion, .issue, .repository, .branch, .worktree, .state, .headSha] | @tsv' "$state") || fail 'durable Issue state is malformed'
IFS=$'\t' read -r schema_version state_issue state_repo branch worktree_relative state_name head_sha <<< "$state_fields"
[[ "$schema_version" == 1 && "$state_issue" == "$issue" && "$state_repo" == "$repo" && "$state_name" == merged ]] || fail 'durable Issue state is not a merged record'
[[ "$branch" =~ ^(codex|claude)/${issue}-[a-z0-9][a-z0-9-]*$ && "$worktree_relative" =~ ^\.worktrees/${issue}-[a-z0-9][a-z0-9-]*$ && "$head_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'durable targets are noncanonical'
worktree="$primary_root/$worktree_relative"
[[ "$repo_root" == "$worktree" && -d "$worktree" && ! -L "$worktree" ]] || fail 'cleanup must run in the exact recorded Issue worktree'
[[ "$(git -C "$worktree" branch --show-current)" == "$branch" && "$(git -C "$worktree" rev-parse HEAD)" == "$head_sha" ]] || fail 'worktree Branch or Head differs from durable state'
[[ -z "$(git -C "$worktree" status --porcelain)" ]] || fail 'recorded worktree is dirty'

"$repo_root/tools/github-account-preflight.sh" --repo "$repo" >/dev/null
pr_json=$(gh pr list --repo "$repo" --head "$branch" --state all --json number,state,headRefName,headRefOid,mergeCommit) || fail 'exact PR could not be resolved'
PR_JSON="$pr_json" BRANCH="$branch" HEAD="$head_sha" ruby -rjson -e '
  records = JSON.parse(ENV.fetch("PR_JSON")); abort "expected exactly one PR" unless records.is_a?(Array) && records.length == 1
  pr = records.fetch(0); abort "PR is not merged" unless pr["state"] == "MERGED"; abort "PR Branch mismatch" unless pr["headRefName"] == ENV.fetch("BRANCH"); abort "PR Head mismatch" unless pr["headRefOid"] == ENV.fetch("HEAD"); abort "PR has no merge commit" unless pr.dig("mergeCommit", "oid").is_a?(String) && pr.dig("mergeCommit", "oid").match?(/\A[0-9a-f]{40}\z/)
' || fail 'PR is open, unmerged, stale, or ambiguous'

"$repo_root/tools/github-account-preflight.sh" --repo "$repo" --issue "$issue" --intended-operation github.delete_branch --expected-head "$head_sha" >/dev/null
if git -C "$primary_root" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1; then
  git -C "$primary_root" push origin --delete "$branch" >/dev/null
else
  remote_status=$?
  [[ "$remote_status" == 2 ]] || fail 'remote Branch lookup failed'
fi
git -C "$primary_root" worktree remove "$worktree" >/dev/null
git -C "$primary_root" branch -D -- "$branch" >/dev/null
jq -cn --argjson issue "$issue" --arg branch "$branch" '{status:"cleaned",issue:$issue,branch:$branch}'
