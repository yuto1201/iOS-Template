#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
identity_tool="$repo_root/tools/lib/merge-state.rb"
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

identity=$(ruby "$identity_tool" validate-primary "$repo_root" "$repo" "$issue") || fail 'durable Issue identity is invalid'
[[ "$(jq -er '.primaryRoot | strings' <<<"$identity")" == "$repo_root" ]] || fail 'cleanup must run in the primary checkout'
[[ "$(jq -er '.state | strings' <<<"$identity")" == merged ]] || fail 'cleanup requires durable merged state'
branch=$(jq -er '.branch | strings' <<<"$identity")
worktree=$(jq -er '.worktreePath | strings' <<<"$identity")
head_sha=$(jq -er '.headSha | strings' <<<"$identity")
pull_request=$(jq -er '.pullRequest' <<<"$identity") || fail 'cleanup requires a positive persisted pullRequest'
worktree_present=$(jq -r '.worktreePresent' <<<"$identity")

[[ "$(git -C "$repo_root" rev-parse --show-toplevel)" == "$repo_root" ]] || fail 'Git top-level differs from primary checkout'
[[ "$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)" == "$repo_root/.git" ]] || fail 'Git common directory differs from primary checkout'
base_sha=$(jq -er '.baseSha | strings' <<<"$identity")
[[ "$(git -C "$repo_root" cat-file -t "$base_sha")" == commit && "$(git -C "$repo_root" cat-file -t "$head_sha")" == commit ]] || fail 'durable Base or Head is not a commit'
git -C "$repo_root" merge-base --is-ancestor "$base_sha" "$head_sha" || fail 'durable Base is not an ancestor of Head'
require_origin() {
  local origin_url
  origin_url=$(git -C "$repo_root" remote get-url origin) || fail 'origin remote is missing'
  case "$origin_url" in
    "https://github.com/$repo"|"https://github.com/$repo.git"|"git@github.com:$repo"|"git@github.com:$repo.git"|"ssh://git@github.com/$repo"|"ssh://git@github.com/$repo.git") ;;
    *) fail 'origin remote does not match requested repository' ;;
  esac
}
require_origin
if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
  [[ "$(git -C "$repo_root" rev-parse "refs/heads/$branch")" == "$head_sha" ]] || fail 'local Branch was reused at a different Head'
fi
if [[ -e "$worktree" || -L "$worktree" ]]; then
  [[ "$worktree_present" == true && -d "$worktree" && ! -L "$worktree" ]] || fail 'recorded worktree is unsafe or dangling'
  [[ "$(git -C "$worktree" rev-parse --show-toplevel)" == "$worktree" ]] || fail 'recorded worktree Git identity differs'
  [[ "$(git -C "$worktree" branch --show-current)" == "$branch" && "$(git -C "$worktree" rev-parse HEAD)" == "$head_sha" && "$(git -C "$worktree" rev-parse "refs/heads/$branch")" == "$head_sha" ]] || fail 'worktree Branch, ref, or Head differs from durable state'
  [[ -z "$(git -C "$worktree" status --porcelain)" ]] || fail 'recorded worktree is dirty'
else
  [[ "$worktree_present" == false ]] || fail 'recorded worktree presence changed during validation'
fi

"$repo_root/tools/github-account-preflight.sh" --repo "$repo" >/dev/null || fail 'personal GitHub account or repository preflight failed'
pr_json=$(gh pr view "$pull_request" --repo "$repo" --json number,state,baseRefName,headRefName,headRefOid,mergeCommit,url) || fail 'persisted PR could not be read'
merge_commit=$(PR_JSON="$pr_json" REPO="$repo" PR="$pull_request" BRANCH="$branch" HEAD="$head_sha" ruby -rjson -e '
  pr = JSON.parse(ENV.fetch("PR_JSON")); abort unless pr.is_a?(Hash) && pr.keys.sort == %w[number state baseRefName headRefName headRefOid mergeCommit url].sort
  abort unless pr["number"] == Integer(ENV.fetch("PR")) && pr["url"] == "https://github.com/#{ENV.fetch("REPO")}/pull/#{ENV.fetch("PR")}" && pr["state"] == "MERGED"
  abort unless pr["baseRefName"] == "main" && pr["headRefName"] == ENV.fetch("BRANCH") && pr["headRefOid"] == ENV.fetch("HEAD")
  oid = pr.dig("mergeCommit", "oid"); abort unless oid.is_a?(String) && oid.match?(/\A[0-9a-f]{40}\z/); puts oid
') || fail 'persisted PR identity is open, unmerged, stale, or mismatched'
[[ "$merge_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'persisted PR merge commit is invalid'

remote_output=''
if remote_output=$(git -C "$repo_root" ls-remote --exit-code --heads origin "refs/heads/$branch" 2>/dev/null); then
  remote_sha=$(REMOTE_OUTPUT="$remote_output" BRANCH="$branch" ruby -e '
    lines = ENV.fetch("REMOTE_OUTPUT").lines.map(&:strip).reject(&:empty?); abort unless lines.length == 1
    match = lines.first.match(/\A([0-9a-f]{40})\trefs\/heads\/(.+)\z/) or abort
    abort unless match[2] == ENV.fetch("BRANCH"); puts match[1]
  ') || fail 'remote Branch lookup returned an invalid identity'
  [[ "$remote_sha" == "$head_sha" ]] || fail 'remote Branch was reused at a different Head'
  [[ -e "$worktree" && ! -L "$worktree" ]] || fail 'remote Branch still exists but exact-head worktree preflight cannot rerun'
  "$worktree/tools/github-account-preflight.sh" --repo "$repo" --issue "$issue" --intended-operation github.delete_branch --expected-head "$head_sha" >/dev/null || fail 'remote Branch deletion preflight failed'
  require_origin
  refreshed=$(git -C "$repo_root" ls-remote --exit-code --heads origin "refs/heads/$branch") || fail 'remote Branch disappeared during deletion preflight'
  refreshed_sha=$(printf '%s' "$refreshed" | awk 'NF == 2 { print $1 }')
  refreshed_ref=$(printf '%s' "$refreshed" | awk 'NF == 2 { print $2 }')
  [[ "$refreshed_sha" == "$head_sha" && "$refreshed_ref" == "refs/heads/$branch" ]] || fail 'remote Branch changed during deletion preflight'
  git -C "$repo_root" push --force-with-lease="refs/heads/$branch:$head_sha" origin ":refs/heads/$branch" >/dev/null || fail 'exact remote Branch deletion failed'
else
  remote_status=$?
  [[ "$remote_status" == 2 ]] || fail 'remote Branch lookup failed'
fi

if [[ -e "$worktree" || -L "$worktree" ]]; then
  [[ -d "$worktree" && ! -L "$worktree" ]] || fail 'recorded worktree became unsafe'
  git -C "$repo_root" worktree remove "$worktree" >/dev/null || fail 'exact worktree removal failed'
fi
if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
  [[ "$(git -C "$repo_root" rev-parse "refs/heads/$branch")" == "$head_sha" ]] || fail 'local Branch was recreated at a different Head'
  git -C "$repo_root" update-ref -d "refs/heads/$branch" "$head_sha" || fail 'exact local Branch deletion failed'
fi
jq -cn --argjson issue "$issue" --arg branch "$branch" --argjson pullRequest "$pull_request" '{status:"cleaned",issue:$issue,branch:$branch,pullRequest:$pullRequest}'
