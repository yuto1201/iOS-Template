#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
artifacts_root="$repo_root/.artifacts"
json_tool="$repo_root/tools/lib/workflow-json.rb"

usage() { echo 'usage: github-account-preflight.sh --repo OWNER/REPO [--issue NUMBER --intended-operation OPERATION --expected-head SHA]' >&2; exit 2; }
[[ $# -ge 2 ]] || usage
repo='' issue='' intended_operation='' expected_head=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --issue) issue=${2:-}; shift 2 ;;
    --intended-operation) intended_operation=${2:-}; shift 2 ;;
    --expected-head) expected_head=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'invalid repository' >&2; exit 1; }
if [[ -n "$issue$intended_operation$expected_head" ]] && [[ -z "$issue" || -z "$intended_operation" || -z "$expected_head" ]]; then usage; fi
if [[ -n "$issue" ]]; then
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid issue' >&2; exit 1; }
  [[ "$intended_operation" =~ ^github\.(push_branch|create_pr|merge_pr|delete_branch|sync_labels|read_issue|create_issue|update_issue)$ ]] || { echo 'invalid intended operation' >&2; exit 1; }
  [[ "$expected_head" =~ ^[0-9a-f]{40}$ ]] || { echo 'invalid expected head' >&2; exit 1; }
fi

expected_account=$(ruby -ne 'puts $1 if /^\s*login:\s*([A-Za-z0-9-]+)\s*$/' "$repo_root/Config/ownership.yml")
[[ -n "$expected_account" ]] || { echo 'configured GitHub login is missing' >&2; exit 1; }
auth_status=$(gh auth status --active 2>&1) || { echo 'GitHub authentication preflight failed' >&2; exit 1; }
active_account=$(ruby -ne 'if /account\s+([^\s(]+)/; puts $1; exit; end' <<< "$auth_status")
[[ "$active_account" == "$expected_account" ]] || { echo 'active GitHub account does not match configured personal account' >&2; exit 1; }
repo_json=$(gh repo view "$repo" --json nameWithOwner,defaultBranchRef,url)
actual_repo=$(jq -er '.nameWithOwner | strings' <<< "$repo_json")
default_branch=$(jq -er '.defaultBranchRef.name | strings' <<< "$repo_json")
url=$(jq -er '.url | strings' <<< "$repo_json")
[[ "$actual_repo" == "$repo" ]] || { echo 'repository identity does not match requested repository' >&2; exit 1; }

if [[ -z "$issue" ]]; then
  jq -cn --arg account "$active_account" --arg repository "$actual_repo" --arg defaultBranch "$default_branch" --arg url "$url" '{account:$account,repository:$repository,defaultBranch:$defaultBranch,url:$url}'
  exit 0
fi

local_head=$(git -C "$repo_root" rev-parse HEAD)
[[ "$local_head" == "$expected_head" ]] || { echo 'local Head does not match expected Head' >&2; exit 1; }
checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
document=$(ruby "$json_tool" preflight "$active_account" "$actual_repo" "$default_branch" "$url" "$intended_operation" "$issue" "$local_head" "$checked_at")
destination="$artifacts_root/issues/$issue/github-preflight.json"
mkdir -p "$(dirname "$destination")"
artifacts_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$artifacts_root")
destination_parent_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$(dirname "$destination")")
[[ "$destination_parent_real" == "$artifacts_real/issues/"* ]] || { echo 'preflight artifact path escapes .artifacts' >&2; exit 1; }
destination="$destination_parent_real/github-preflight.json"
temporary=$(mktemp "${destination}.tmp.XXXXXX")
trap 'rm -f "$temporary"' EXIT
printf '%s\n' "$document" > "$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$destination"
trap - EXIT
printf '%s\n' "$document"
