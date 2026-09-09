#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: record-merged-pr.sh --repo OWNER/REPO --issue NUMBER --pull-request NUMBER --expected-head SHA' >&2; exit 2; }
repo='' issue='' pull_request='' expected_head=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ -z "$repo" ]] || usage; repo=${2:-}; shift 2 ;;
    --issue) [[ -z "$issue" ]] || usage; issue=${2:-}; shift 2 ;;
    --pull-request) [[ -z "$pull_request" ]] || usage; pull_request=${2:-}; shift 2 ;;
    --expected-head) [[ -z "$expected_head" ]] || usage; expected_head=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ && "$pull_request" =~ ^[1-9][0-9]*$ && "$expected_head" =~ ^[0-9a-f]{40}$ ]] || usage
exec /usr/bin/ruby "$repo_root/tools/lib/bounded-command.rb" --stage record-merged-pr --timeout-seconds 600 -- \
  /usr/bin/ruby "$repo_root/tools/lib/merge-state.rb" recover-merged-pr "$repo_root" "$repo" "$issue" "$pull_request" "$expected_head"
