#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: merge-issue.sh --repo OWNER/REPO --issue NUMBER' >&2; exit 2; }
repo='' issue=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --issue) issue=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || usage
fail() { echo "merge refused: $*" >&2; exit 1; }
[[ -L "$repo_root/.artifacts" ]] || fail 'Issue worktree lacks the canonical .artifacts link'
primary_root=$(cd "$repo_root/../.." && pwd -P)
artifacts_root=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$repo_root/.artifacts") || fail 'canonical .artifacts link is broken'
[[ "$artifacts_root" == "$primary_root/.artifacts" ]] || fail 'canonical .artifacts link does not resolve to the primary checkout'
state="$repo_root/.artifacts/issues/$issue/state.json"
[[ -f "$state" && ! -L "$state" ]] || fail 'durable Issue state is missing'
branch=$(jq -er '.branch | strings' "$state") || fail 'state Branch is invalid'
worktree_relative=$(jq -er '.worktree | strings' "$state") || fail 'state worktree is invalid'
[[ "$branch" =~ ^(codex|claude)/${issue}-[a-z0-9][a-z0-9-]*$ && "$worktree_relative" =~ ^\.worktrees/${issue}-[a-z0-9][a-z0-9-]*$ ]] || fail 'durable targets are noncanonical'
worktree="$primary_root/$worktree_relative"
[[ "$repo_root" == "$worktree" && -d "$worktree" && ! -L "$worktree" ]] || fail 'merge must run in the exact recorded Issue worktree'
head_sha=$(git -C "$repo_root" rev-parse HEAD)

persist_merged_state() {
  local pull_request=$1 transition_from=$2
  if [[ "$transition_from" == approved-for-merge ]]; then
    "$repo_root/tools/issue-state.sh" transition --repo "$repo" --issue "$issue" --from approved-for-merge --to merged >/dev/null
  elif [[ "$transition_from" != merged ]]; then
    fail 'durable Issue state cannot converge to merged'
  fi
  local temporary="$state.tmp.$$"
  HEAD="$head_sha" PR="$pull_request" ruby -rjson -e '
    path, output = ARGV; value = JSON.parse(File.binread(path))
    required = %w[baseSha branch executor issue issueContract previousState primaryImplementer repository resumeState schemaVersion state worktree]
    optional = %w[from headSha pullRequest to transitionedAt]
    abort "state has unknown or missing fields" unless (value.keys - required - optional).empty? && required.all? { |key| value.key?(key) }
    abort "state transition did not converge" unless value["state"] == "merged" && value["previousState"] == "approved-for-merge"
    value["headSha"] = ENV.fetch("HEAD"); value["pullRequest"] = Integer(ENV.fetch("PR"))
    File.binwrite(output, JSON.generate(value))
  ' "$state" "$temporary" || { rm -f "$temporary"; fail 'merged state persistence validation failed'; }
  chmod 600 "$temporary"
  mv -f "$temporary" "$state"
}

confirm_merged_pr_and_issue() {
  local number=$1 confirmation issue_state
  confirmation=$(gh pr view "$number" --repo "$repo" --json state,headRefOid,mergeCommit) || fail 'merged PR could not be confirmed'
  CONFIRMATION="$confirmation" HEAD="$head_sha" ruby -rjson -e 'pr = JSON.parse(ENV.fetch("CONFIRMATION")); abort "PR was not merged" unless pr["state"] == "MERGED" && pr["headRefOid"] == ENV.fetch("HEAD") && pr.dig("mergeCommit", "oid").is_a?(String) && pr.dig("mergeCommit", "oid").match?(/\A[0-9a-f]{40}\z/)' || fail 'merged PR confirmation mismatched'
  issue_state=$(gh issue view "$issue" --repo "$repo" --json state | jq -er '.state') || fail 'Issue close confirmation failed'
  [[ "$issue_state" == CLOSED ]] || fail 'Issue was not closed'
}

body=$("$repo_root/tools/render-pr-body.sh" --issue "$issue" --head-sha "$head_sha")
prs=$(gh pr list --repo "$repo" --head "$branch" --state all --json number,state,headRefName,headRefOid) || fail 'PR lookup failed'
pr_record=$(PRS="$prs" BRANCH="$branch" HEAD="$head_sha" ruby -rjson -e 'items = JSON.parse(ENV.fetch("PRS")); abort "ambiguous PR" if items.length > 1; if items.length == 1; item = items.fetch(0); abort "existing PR differs from Issue Head" unless item["headRefName"] == ENV.fetch("BRANCH") && item["headRefOid"] == ENV.fetch("HEAD"); puts JSON.generate(item); end') || fail 'existing PR is ambiguous or stale'
pr_number=''
if [[ -n "$pr_record" ]]; then
  pr_number=$(printf '%s' "$pr_record" | jq -er '.number')
  pr_state=$(printf '%s' "$pr_record" | jq -er '.state')
  if [[ "$pr_state" == MERGED ]]; then
    confirm_merged_pr_and_issue "$pr_number"
    persist_merged_state "$pr_number" "$(jq -er '.state | strings' "$state")"
    jq -cn --argjson issue "$issue" --argjson pr "$pr_number" --arg headSha "$head_sha" '{status:"already-merged",issue:$issue,pullRequest:$pr,headSha:$headSha}'
    exit 0
  fi
  [[ "$pr_state" == OPEN ]] || fail 'existing PR is closed without merge'
fi
"$repo_root/tools/github-account-preflight.sh" --repo "$repo" --issue "$issue" --intended-operation github.push_branch --expected-head "$head_sha" >/dev/null
git -C "$repo_root" push origin "$branch"
if [[ -z "$pr_number" ]]; then
  "$repo_root/tools/github-account-preflight.sh" --repo "$repo" --issue "$issue" --intended-operation github.create_pr --expected-head "$head_sha" >/dev/null
  gh pr create --repo "$repo" --base main --head "$branch" --body "$body" >/dev/null || fail 'PR creation failed'
  created=$(gh pr list --repo "$repo" --head "$branch" --state open --json number,state,headRefName,headRefOid) || fail 'created PR could not be resolved'
  pr_number=$(PRS="$created" BRANCH="$branch" HEAD="$head_sha" ruby -rjson -e 'items = JSON.parse(ENV.fetch("PRS")); abort "created PR is ambiguous" unless items.length == 1; item = items.fetch(0); abort "created PR differs from Issue Head" unless item["state"] == "OPEN" && item["headRefName"] == ENV.fetch("BRANCH") && item["headRefOid"] == ENV.fetch("HEAD"); puts item.fetch("number")') || fail 'created PR is ambiguous or stale'
fi
"$repo_root/tools/github-account-preflight.sh" --repo "$repo" --issue "$issue" --intended-operation github.merge_pr --expected-head "$head_sha" >/dev/null
"$repo_root/tools/premerge-gate.sh" --issue "$issue" --head-sha "$head_sha" >/dev/null
gh pr merge "$pr_number" --repo "$repo" --squash --match-head-commit "$head_sha"
confirm_merged_pr_and_issue "$pr_number"
persist_merged_state "$pr_number" "$(jq -er '.state | strings' "$state")"
jq -cn --argjson issue "$issue" --argjson pr "$pr_number" --arg headSha "$head_sha" '{status:"merged",issue:$issue,pullRequest:$pr,headSha:$headSha}'
