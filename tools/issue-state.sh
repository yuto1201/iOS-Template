#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
source "$repo_root/tools/lib/workflow.sh"
json_tool="$repo_root/tools/lib/workflow-json.rb"
usage() { echo 'usage: issue-state.sh get|transition --repo OWNER/REPO --issue NUMBER [--from STATE --to STATE]' >&2; exit 2; }

command=${1:-}; shift || true
[[ "$command" == get || "$command" == transition ]] || usage
repo='' issue='' from='' to=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --issue) issue=${2:-}; shift 2 ;;
    --from) from=${2:-}; shift 2 ;;
    --to) to=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || usage
if [[ "$command" == get ]]; then [[ -z "$from$to" ]] || usage; else [[ -n "$from" && -n "$to" ]] || usage; fi

read_issue() {
  gh issue view "$issue" --repo "$repo" --json labels,comments || { echo 'Issue could not be read' >&2; exit 1; }
}
state_from_issue() {
  local document=$1 state
  state=$(printf '%s' "$document" | ruby "$json_tool" state-from-issue)
  workflow_is_state "$state" || { echo 'Issue has an unknown current state label' >&2; exit 1; }
  printf '%s\n' "$state"
}
require_current_state() {
  local expected=$1 document state
  document=$(read_issue)
  state=$(state_from_issue "$document")
  [[ "$state" == "$expected" ]] || { echo "compare-and-set conflict: expected state:$expected, found state:$state" >&2; exit 1; }
  printf '%s\n' "$document"
}

issue_json=$(read_issue)
current=$(state_from_issue "$issue_json")
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
state_file="$repo_root/.artifacts/issues/$issue/state.json"
write_state() {
  local state=$1 record_from=$2 record_to=$3 resume_state=$4
  local record temporary
  record=$(ruby "$json_tool" state-record "$state" "$record_from" "$record_to" "$resume_state" "$timestamp")
  mkdir -p "$(dirname "$state_file")"
  local artifacts_real state_parent_real
  artifacts_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$repo_root/.artifacts")
  state_parent_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$(dirname "$state_file")")
  [[ "$state_parent_real" == "$artifacts_real/issues/"* ]] || { echo 'state artifact path escapes .artifacts' >&2; exit 1; }
  state_file="$state_parent_real/state.json"
  temporary=$(mktemp "${state_file}.tmp.XXXXXX")
  printf '%s\n' "$record" > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$state_file"
  printf '%s\n' "$record"
}

if [[ "$command" == get ]]; then
  resume_state=null
  if workflow_is_blocked "$current" || [[ "$current" == paused ]]; then
    resume_state=$(printf '%s' "$issue_json" | ruby "$json_tool" resume-from-comments "$current" 2>/dev/null || true)
    [[ -n "$resume_state" ]] || resume_state=null
  fi
  write_state "$current" null "$current" "$resume_state" >/dev/null
  jq -cn --arg repository "$repo" --argjson issue "$issue" --arg state "$current" '{repository:$repository,issue:$issue,state:$state}'
  exit 0
fi

[[ "$current" == "$from" ]] || { echo "compare-and-set failed: expected state:$from, found state:$current" >&2; exit 1; }
workflow_transition_allowed "$from" "$to" || { echo "invalid transition: $from -> $to" >&2; exit 1; }
resume_state=null
if workflow_is_blocked "$from" || [[ "$from" == paused ]]; then
  resume_state=$(printf '%s' "$issue_json" | ruby "$json_tool" resume-from-comments "$from" 2>/dev/null || true)
  if [[ "$to" != paused && "$to" != superseded && ( -z "$resume_state" || "$to" != "$resume_state" ) ]]; then
    conflict=blocked:conflict
    require_current_state "$from" >/dev/null
    gh issue edit "$issue" --repo "$repo" --remove-label "state:$from" --add-label "state:$conflict"
    require_current_state "$conflict" >/dev/null
    marker=$(ruby "$json_tool" state-marker "$from" "$conflict" null "$timestamp")
    gh issue comment "$issue" --repo "$repo" --body "$marker"
    write_state "$conflict" "$from" "$conflict" null >/dev/null
    echo 'blocked resume history is missing or ambiguous; moved to blocked:conflict' >&2
    exit 1
  fi
fi
if workflow_is_blocked "$to" || [[ "$to" == paused ]]; then resume_state=$from; fi
require_current_state "$from" >/dev/null
gh issue edit "$issue" --repo "$repo" --remove-label "state:$from" --add-label "state:$to"
require_current_state "$to" >/dev/null
marker=$(ruby "$json_tool" state-marker "$from" "$to" "$resume_state" "$timestamp")
gh issue comment "$issue" --repo "$repo" --body "$marker"
write_state "$to" "$from" "$to" "$resume_state"
