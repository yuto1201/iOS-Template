#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'usage: validate-issue-body.sh [--type feature|regression|docs|release] [--allow-legacy-delivery-stage] ISSUE_BODY.md' >&2
  exit 2
}

issue_type=feature
allow_legacy=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) issue_type=${2:-}; shift 2 ;;
    --allow-legacy-delivery-stage) allow_legacy=1; shift ;;
    *) break ;;
  esac
done
[[ "$issue_type" == feature || "$issue_type" == regression || "$issue_type" == docs || "$issue_type" == release ]] || usage
[[ $# -eq 1 ]] || usage
issue_body=$1
[[ -f "$issue_body" ]] || { echo "Issue body file not found: $issue_body" >&2; exit 2; }

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)

if [[ "$allow_legacy" -eq 1 ]]; then
  ruby "$repo_root/tools/lib/issue-contract.rb" --body "$issue_body" --type "$issue_type" --format validate --allow-legacy-delivery-stage
else
  ruby "$repo_root/tools/lib/issue-contract.rb" --body "$issue_body" --type "$issue_type" --format validate
fi

"$repo_root/.agents/skills/spec-workflow/scripts/check-spec-state.sh" "$issue_body"
