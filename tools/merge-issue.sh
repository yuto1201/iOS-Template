#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
identity_tool="$repo_root/tools/lib/merge-state.rb"
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

identity=$(ruby "$identity_tool" validate-worktree "$repo_root" "$repo" "$issue") || fail 'durable Issue identity is invalid'
branch=$(jq -er '.branch | strings' <<<"$identity") || fail 'durable Branch is invalid'
base_sha=$(jq -er '.baseSha | strings' <<<"$identity") || fail 'durable Base is invalid'
head_sha=$(jq -er '.headSha | strings' <<<"$identity") || fail 'durable Head is invalid'
state_name=$(jq -er '.state | strings' <<<"$identity") || fail 'durable workflow state is invalid'
pull_request=$(jq -er '.pullRequest // empty' <<<"$identity") || true
title=$(jq -er '.title | strings' <<<"$identity") || fail 'deterministic PR title is invalid'
primary_root=$(jq -er '.primaryRoot | strings' <<<"$identity") || fail 'primary checkout identity is invalid'
pr_fields='number,state,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,closingIssuesReferences,mergeCommit,url'

[[ "$(git -C "$repo_root" rev-parse --show-toplevel)" == "$repo_root" ]] || fail 'Git top-level differs from the Issue worktree'
[[ "$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)" == "$primary_root/.git" ]] || fail 'Git common directory differs from the primary checkout'
[[ "$(git -C "$repo_root" branch --show-current)" == "$branch" ]] || fail 'current Branch differs from durable state'
[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$head_sha" ]] || fail 'current Head differs from durable state'
[[ "$(git -C "$repo_root" rev-parse "refs/heads/$branch")" == "$head_sha" ]] || fail 'raw Branch ref differs from durable Head'
[[ "$(git -C "$repo_root" cat-file -t "$base_sha")" == commit && "$(git -C "$repo_root" cat-file -t "$head_sha")" == commit ]] || fail 'Base or Head is not a commit'
git -C "$repo_root" merge-base --is-ancestor "$base_sha" "$head_sha" || fail 'durable Base is not an ancestor of Head'
[[ -z "$(git -C "$repo_root" status --porcelain)" ]] || fail 'Issue worktree is dirty'
require_origin() {
  local origin_url
  origin_url=$(git -C "$repo_root" remote get-url origin) || fail 'origin remote is missing'
  case "$origin_url" in
    "https://github.com/$repo"|"https://github.com/$repo.git"|"git@github.com:$repo"|"git@github.com:$repo.git"|"ssh://git@github.com/$repo"|"ssh://git@github.com/$repo.git") ;;
    *) fail 'origin remote does not match requested repository' ;;
  esac
}
require_origin

validate_pr() {
  local expected_state=$1 document=$2 expected_pr=$3
  PR_JSON="$document" REPO="$repo" ISSUE="$issue" PR="$expected_pr" BRANCH="$branch" HEAD="$head_sha" EXPECTED_STATE="$expected_state" ruby -rjson -e '
    pr = JSON.parse(ENV.fetch("PR_JSON")); abort "PR must be an object" unless pr.is_a?(Hash)
    required = %w[number state baseRefName headRefName headRefOid headRepository headRepositoryOwner isCrossRepository closingIssuesReferences mergeCommit url]
    abort "PR fields differ" unless pr.keys.sort == required.sort
    abort "PR number differs" unless pr["number"] == Integer(ENV.fetch("PR"))
    abort "PR repository differs" unless pr["url"] == "https://github.com/#{ENV.fetch("REPO")}/pull/#{ENV.fetch("PR")}"
    abort "PR Base differs" unless pr["baseRefName"] == "main"
    abort "PR Branch or Head differs" unless pr["headRefName"] == ENV.fetch("BRANCH") && pr["headRefOid"] == ENV.fetch("HEAD")
    abort "PR source repository differs" unless pr["isCrossRepository"] == false && pr.dig("headRepository", "nameWithOwner") == ENV.fetch("REPO") && pr.dig("headRepositoryOwner", "login") == ENV.fetch("REPO").split("/", 2).first
    closing = pr["closingIssuesReferences"]
    abort "PR does not close the exact Issue" unless closing.is_a?(Array) && closing.length == 1 && closing[0]["number"] == Integer(ENV.fetch("ISSUE")) && closing[0]["url"] == "https://github.com/#{ENV.fetch("REPO")}/issues/#{ENV.fetch("ISSUE")}" && closing[0].dig("repository", "nameWithOwner") == ENV.fetch("REPO")
    expected = ENV.fetch("EXPECTED_STATE")
    abort "PR state differs" unless expected == "ANY" ? %w[OPEN CLOSED MERGED].include?(pr["state"]) : pr["state"] == expected
    if pr["state"] == "MERGED"
      oid = pr.dig("mergeCommit", "oid"); abort "merged PR lacks merge commit" unless oid.is_a?(String) && oid.match?(/\A[0-9a-f]{40}\z/)
    else
      abort "unmerged PR unexpectedly has merge commit" unless pr["mergeCommit"].nil?
    end
    puts pr["state"]
  ' || fail 'PR identity is stale or mismatched'
}

view_exact_pr() {
  gh pr view "$1" --repo "$repo" --json "$pr_fields"
}

confirm_issue_closed() {
  local issue_json
  issue_json=$(gh issue view "$issue" --repo "$repo" --json number,state,url) || fail 'Issue close confirmation failed'
  ISSUE_JSON="$issue_json" REPO="$repo" ISSUE="$issue" ruby -rjson -e '
    value = JSON.parse(ENV.fetch("ISSUE_JSON")); expected = Integer(ENV.fetch("ISSUE"))
    abort unless value.keys.sort == %w[number state url].sort && value["number"] == expected && value["state"] == "CLOSED" && value["url"] == "https://github.com/#{ENV.fetch("REPO")}/issues/#{expected}"
  ' || fail 'Issue was not closed with exact identity'
}

confirm_remote_merged_workflow() {
  local workflow_json workflow_state
  workflow_json=$(gh issue view "$issue" --repo "$repo" --json labels) || fail 'Issue workflow confirmation failed'
  workflow_state=$(printf '%s' "$workflow_json" | ruby "$repo_root/tools/lib/workflow-json.rb" state-from-issue) || fail 'Issue workflow labels are invalid'
  [[ "$workflow_state" == merged ]] || fail 'Issue workflow state is not merged'
}

converge_merged_state() {
  local pr=$1 remote_document remote_state transition_time durable_state
  remote_document=$(gh issue view "$issue" --repo "$repo" --json labels) || fail 'Issue workflow state could not be confirmed'
  remote_state=$(printf '%s' "$remote_document" | ruby "$repo_root/tools/lib/workflow-json.rb" state-from-issue) || fail 'Issue workflow state is invalid'
  durable_state=$(ruby "$identity_tool" validate-worktree "$repo_root" "$repo" "$issue" | jq -er '.state') || fail 'durable state changed before convergence'
  if [[ "$durable_state" == approved-for-merge && "$remote_state" == approved-for-merge ]]; then
    "$repo_root/tools/issue-state.sh" transition --repo "$repo" --issue "$issue" --from approved-for-merge --to merged >/dev/null
  elif [[ "$remote_state" != merged || ( "$durable_state" != approved-for-merge && "$durable_state" != merged ) ]]; then
    fail 'remote and durable workflow states cannot converge to merged'
  fi
  transition_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ruby "$identity_tool" mark-merged "$repo_root" "$repo" "$issue" "$pr" "$head_sha" "$transition_time" >/dev/null || fail 'merged state persistence failed'
}

"$repo_root/tools/github-account-preflight.sh" --repo "$repo" >/dev/null || fail 'personal GitHub account or repository preflight failed'

if [[ "$state_name" == merged ]]; then
  [[ "$pull_request" =~ ^[1-9][0-9]*$ ]] || fail 'merged recovery requires a positive persisted pullRequest'
  pr_document=$(view_exact_pr "$pull_request") || fail 'persisted merged PR could not be read'
  [[ "$(validate_pr MERGED "$pr_document" "$pull_request")" == MERGED ]] || fail 'persisted PR is not merged'
  confirm_issue_closed
  confirm_remote_merged_workflow
  jq -cn --argjson issue "$issue" --argjson pr "$pull_request" --arg headSha "$head_sha" '{status:"already-merged",issue:$issue,pullRequest:$pr,headSha:$headSha}'
  exit 0
fi
[[ "$state_name" == approved-for-merge ]] || fail 'normal merge requires approved-for-merge state'

"$repo_root/tools/github-account-preflight.sh" --repo "$repo" --issue "$issue" --intended-operation github.merge_pr --expected-head "$head_sha" >/dev/null || fail 'initial merge evidence preflight failed'
"$repo_root/tools/premerge-gate.sh" --issue "$issue" --head-sha "$head_sha" >/dev/null || fail 'pre-merge gate failed before publication'
body=$("$repo_root/tools/render-pr-body.sh" --issue "$issue" --head-sha "$head_sha") || fail 'PR body rendering failed'

pr_number=''
pr_state=''
if [[ -n "$pull_request" ]]; then
  pr_number=$pull_request
  pr_document=$(view_exact_pr "$pr_number") || fail 'persisted PR could not be read'
  pr_state=$(validate_pr ANY "$pr_document" "$pr_number")
else
  candidates=$(gh pr list --repo "$repo" --head "$branch" --state all --json "$pr_fields") || fail 'PR discovery failed'
  selected=$(PRS="$candidates" REPO="$repo" ISSUE="$issue" BRANCH="$branch" HEAD="$head_sha" ruby -rjson -e '
    records = JSON.parse(ENV.fetch("PRS")); abort "PR discovery must return an array" unless records.is_a?(Array); abort "ambiguous PR discovery" if records.length > 1
    if records.length == 1
      pr = records.fetch(0); abort "discovered PR fields differ" unless pr.keys.sort == %w[number state baseRefName headRefName headRefOid headRepository headRepositoryOwner isCrossRepository closingIssuesReferences mergeCommit url].sort
      closing = pr["closingIssuesReferences"]
      abort "discovered PR identity differs" unless pr["number"].is_a?(Integer) && pr["number"].positive? && pr["url"] == "https://github.com/#{ENV.fetch("REPO")}/pull/#{pr["number"]}" && pr["baseRefName"] == "main" && pr["headRefName"] == ENV.fetch("BRANCH") && pr["headRefOid"] == ENV.fetch("HEAD") && pr["isCrossRepository"] == false && pr.dig("headRepository", "nameWithOwner") == ENV.fetch("REPO") && pr.dig("headRepositoryOwner", "login") == ENV.fetch("REPO").split("/", 2).first && closing.is_a?(Array) && closing.length == 1 && closing[0]["number"] == Integer(ENV.fetch("ISSUE")) && closing[0]["url"] == "https://github.com/#{ENV.fetch("REPO")}/issues/#{ENV.fetch("ISSUE")}" && closing[0].dig("repository", "nameWithOwner") == ENV.fetch("REPO")
      puts JSON.generate(pr)
    end
  ') || fail 'PR discovery was ambiguous or mismatched'
  if [[ -n "$selected" ]]; then
    pr_number=$(jq -er '.number' <<<"$selected")
    pr_state=$(validate_pr ANY "$selected" "$pr_number")
    [[ "$pr_state" != MERGED ]] || fail 'discovered merged PR requires a previously persisted pullRequest'
    ruby "$identity_tool" persist-pr "$repo_root" "$repo" "$issue" "$pr_number" >/dev/null || fail 'discovered PR identity could not be persisted'
  fi
fi

if [[ "$pr_state" == MERGED ]]; then
  [[ -n "$pull_request" ]] || fail 'merged recovery requires a previously persisted pullRequest'
  confirm_issue_closed
  converge_merged_state "$pr_number"
  jq -cn --argjson issue "$issue" --argjson pr "$pr_number" --arg headSha "$head_sha" '{status:"already-merged",issue:$issue,pullRequest:$pr,headSha:$headSha}'
  exit 0
fi
[[ -z "$pr_state" || "$pr_state" == OPEN ]] || fail 'persisted or discovered PR is closed without merge'

"$repo_root/tools/github-account-preflight.sh" --repo "$repo" --issue "$issue" --intended-operation github.push_branch --expected-head "$head_sha" >/dev/null || fail 'push preflight failed'
require_origin
git -C "$repo_root" push origin "$head_sha:refs/heads/$branch" || fail 'exact Head push failed'

if [[ -z "$pr_number" ]]; then
  remote_head=$(git -C "$repo_root" ls-remote --exit-code --heads origin "refs/heads/$branch") || fail 'pushed remote Branch could not be confirmed'
  REMOTE_HEAD="$remote_head" BRANCH="$branch" HEAD="$head_sha" ruby -e '
    lines = ENV.fetch("REMOTE_HEAD").lines.map(&:strip).reject(&:empty?); abort unless lines.length == 1
    match = lines[0].match(/\A([0-9a-f]{40})\trefs\/heads\/(.+)\z/) or abort
    abort unless match[1] == ENV.fetch("HEAD") && match[2] == ENV.fetch("BRANCH")
  ' || fail 'remote Branch moved after exact Head push'
  "$repo_root/tools/github-account-preflight.sh" --repo "$repo" --issue "$issue" --intended-operation github.create_pr --expected-head "$head_sha" >/dev/null || fail 'PR creation preflight failed'
  gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body "$body" >/dev/null || fail 'PR creation failed'
  created=$(gh pr list --repo "$repo" --head "$branch" --state open --json "$pr_fields") || fail 'created PR could not be resolved'
  selected=$(PRS="$created" ruby -rjson -e 'items = JSON.parse(ENV.fetch("PRS")); abort unless items.is_a?(Array) && items.length == 1; puts JSON.generate(items.fetch(0))') || fail 'created PR is ambiguous'
  pr_number=$(jq -er '.number' <<<"$selected") || fail 'created PR number is invalid'
  [[ "$(validate_pr OPEN "$selected" "$pr_number")" == OPEN ]] || fail 'created PR identity differs'
  ruby "$identity_tool" persist-pr "$repo_root" "$repo" "$issue" "$pr_number" >/dev/null || fail 'created PR identity could not be persisted'
fi

"$repo_root/tools/github-account-preflight.sh" --repo "$repo" --issue "$issue" --intended-operation github.merge_pr --expected-head "$head_sha" >/dev/null || fail 'merge preflight failed'
"$repo_root/tools/premerge-gate.sh" --issue "$issue" --head-sha "$head_sha" >/dev/null || fail 'pre-merge gate failed'
pr_document=$(view_exact_pr "$pr_number") || fail 'PR identity could not be refreshed before merge'
[[ "$(validate_pr OPEN "$pr_document" "$pr_number")" == OPEN ]] || fail 'PR identity changed before merge'
gh pr merge "$pr_number" --repo "$repo" --squash --match-head-commit "$head_sha" || fail 'Squash Merge failed'
pr_document=$(view_exact_pr "$pr_number") || fail 'merged PR could not be confirmed'
[[ "$(validate_pr MERGED "$pr_document" "$pr_number")" == MERGED ]] || fail 'merged PR confirmation mismatched'
confirm_issue_closed
converge_merged_state "$pr_number"
jq -cn --argjson issue "$issue" --argjson pr "$pr_number" --arg headSha "$head_sha" '{status:"merged",issue:$issue,pullRequest:$pr,headSha:$headSha}'
