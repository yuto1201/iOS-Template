#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
source "$repo_root/tools/lib/workflow.sh"
json_tool="$repo_root/tools/lib/workflow-json.rb"
usage() { echo 'usage: issue-state.sh get|transition --repo OWNER/REPO --issue NUMBER [--from STATE --to STATE [--head-sha SHA]]' >&2; exit 2; }

command=${1:-}; shift || true
[[ "$command" == get || "$command" == transition ]] || usage
repo='' issue='' from='' to='' head_sha=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --issue) issue=${2:-}; shift 2 ;;
    --from) from=${2:-}; shift 2 ;;
    --to) to=${2:-}; shift 2 ;;
    --head-sha) head_sha=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || usage
if [[ "$command" == get ]]; then
  [[ -z "$from$to$head_sha" ]] || usage
else
  [[ -n "$from" && -n "$to" ]] || usage
  if [[ "$from" == in-progress && "$to" == verify-passed ]]; then
    [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'in-progress -> verify-passed requires --head-sha with an exact SHA' >&2; exit 1; }
  else
    [[ -z "$head_sha" ]] || { echo '--head-sha is allowed only for in-progress -> verify-passed' >&2; exit 1; }
  fi
fi

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
prepare_state() {
  local state=$1 record_from=$2 record_to=$3 resume_state=$4 record_head=${5:-null}
  if [[ ! -e "$repo_root/.artifacts" && ! -L "$repo_root/.artifacts" ]]; then
    mkdir -p "$repo_root/.artifacts"
  fi
  [[ -d "$repo_root/.artifacts" ]] || { echo 'canonical .artifacts is not a directory' >&2; exit 1; }
  if [[ -L "$repo_root/.artifacts" ]]; then
    local primary_root primary_artifacts_real linked_artifacts_real
    primary_root=$(cd "$repo_root/../.." && pwd -P)
    [[ "$repo_root" == "$primary_root/.worktrees/"* && "$(readlink "$repo_root/.artifacts")" == '../../.artifacts' && -d "$primary_root/.artifacts" && ! -L "$primary_root/.artifacts" ]] || { echo 'canonical .artifacts link is unsafe' >&2; exit 1; }
    primary_artifacts_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$primary_root/.artifacts")
    linked_artifacts_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$repo_root/.artifacts")
    [[ "$linked_artifacts_real" == "$primary_artifacts_real" ]] || { echo 'canonical .artifacts link escapes the primary store' >&2; exit 1; }
  fi
  mkdir -p "$(dirname "$state_file")"
  local artifacts_real state_parent_real
  artifacts_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$repo_root/.artifacts")
  state_parent_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$(dirname "$state_file")")
  [[ "$state_parent_real" == "$artifacts_real/issues/"* ]] || { echo 'state artifact path escapes .artifacts' >&2; exit 1; }
  state_file="$state_parent_real/state.json"
  ruby "$json_tool" transition-state-record "$state_file" "$issue" "$repo" "$state" "$record_from" "$record_to" "$resume_state" "$timestamp" "$record_head"
}

require_transition_head() {
  [[ -n "$head_sha" ]] || return 0
  local identity branch worktree primary_root expected_worktree common_dir primary_common_dir
  identity=$(ruby "$json_tool" state-head-identity "$state_file" "$issue" "$repo") || { echo 'durable state cannot bind verification Head' >&2; exit 1; }
  branch=$(jq -er '.branch | strings' <<<"$identity") || exit 1
  worktree=$(jq -er '.worktree | strings' <<<"$identity") || exit 1
  primary_root=$(cd "$repo_root/../.." && pwd -P)
  expected_worktree="$primary_root/$worktree"
  [[ "$repo_root" == "$expected_worktree" && "$repo_root" == "$primary_root/.worktrees/"* ]] || { echo 'verification Head must be bound from the canonical Issue worktree' >&2; exit 1; }
  [[ -L "$repo_root/.artifacts" && "$(readlink "$repo_root/.artifacts")" == '../../.artifacts' ]] || { echo 'verification Head worktree has no canonical artifact link' >&2; exit 1; }
  [[ "$(git -C "$repo_root" rev-parse --show-toplevel)" == "$repo_root" ]] || { echo 'verification Head Git top-level differs from Issue worktree' >&2; exit 1; }
  [[ "$(git -C "$primary_root" rev-parse --show-toplevel)" == "$primary_root" ]] || { echo 'verification Head primary Git top-level is invalid' >&2; exit 1; }
  common_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)
  primary_common_dir=$(git -C "$primary_root" rev-parse --path-format=absolute --git-common-dir)
  [[ "$common_dir" == "$primary_common_dir" ]] || { echo 'verification Head Git common directory differs from primary checkout' >&2; exit 1; }
  [[ "$(git -C "$repo_root" branch --show-current)" == "$branch" ]] || { echo 'verification Head Branch differs from durable state' >&2; exit 1; }
  [[ "$(git -C "$repo_root" rev-parse HEAD)" == "$head_sha" ]] || { echo 'verification Head differs from current Issue worktree HEAD' >&2; exit 1; }
  [[ "$(git -C "$repo_root" rev-parse "refs/heads/$branch")" == "$head_sha" ]] || { echo 'verification Branch ref differs from explicit Head' >&2; exit 1; }
}
write_state() {
  local record=$1 temporary
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
  record=$(prepare_state "$current" null "$current" "$resume_state")
  write_state "$record" >/dev/null
  jq -cn --arg repository "$repo" --argjson issue "$issue" --arg state "$current" '{repository:$repository,issue:$issue,state:$state}'
  exit 0
fi

[[ "$current" == "$from" ]] || { echo "compare-and-set failed: expected state:$from, found state:$current" >&2; exit 1; }
workflow_transition_allowed "$from" "$to" || { echo "invalid transition: $from -> $to" >&2; exit 1; }
# Validate the durable record before any GitHub mutation. This preserves Task 4
# identity records and makes malformed or escaping state fail closed.
prepare_state "$current" null "$current" null >/dev/null
require_transition_head
resume_state=null
if workflow_is_blocked "$from" || [[ "$from" == paused ]]; then
  resume_state=$(printf '%s' "$issue_json" | ruby "$json_tool" resume-from-comments "$from" 2>/dev/null || true)
  if [[ "$to" != paused && "$to" != superseded && ( -z "$resume_state" || "$to" != "$resume_state" ) ]]; then
    conflict=blocked:conflict
    conflict_record=$(prepare_state "$conflict" "$from" "$conflict" null)
    require_current_state "$from" >/dev/null
    gh issue edit "$issue" --repo "$repo" --remove-label "state:$from" --add-label "state:$conflict"
    require_current_state "$conflict" >/dev/null
    marker=$(ruby "$json_tool" state-marker "$from" "$conflict" null "$timestamp")
    gh issue comment "$issue" --repo "$repo" --body "$marker"
    write_state "$conflict_record" >/dev/null
    echo 'blocked resume history is missing or ambiguous; moved to blocked:conflict' >&2
    exit 1
  fi
fi
if workflow_is_blocked "$to" || [[ "$to" == paused ]]; then resume_state=$from; fi
transition_record=$(prepare_state "$to" "$from" "$to" "$resume_state" "${head_sha:-null}")
require_current_state "$from" >/dev/null
require_transition_head
gh issue edit "$issue" --repo "$repo" --remove-label "state:$from" --add-label "state:$to"
require_transition_head
require_current_state "$to" >/dev/null
require_transition_head
marker=$(ruby "$json_tool" state-marker "$from" "$to" "$resume_state" "$timestamp")
gh issue comment "$issue" --repo "$repo" --body "$marker"
require_transition_head
write_state "$transition_record"
