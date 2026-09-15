#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
source "$repo_root/tools/lib/workflow.sh"

usage() {
  echo 'usage: revise-issue-verification.sh marker|apply|validate --repo OWNER/REPO --issue NUMBER [--body PATH --trigger user-explicit|user-delegated|review-finding --reason TEXT [--authority-reference URL|ARTIFACT#finding] [--delegate codex|claude]]' >&2
  exit 2
}

command=${1:-}
shift || true
[[ "$command" == marker || "$command" == apply || "$command" == validate ]] || usage

repo='' issue='' body='' trigger='' reason='' authority_reference='' delegate=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ -z "$repo" && $# -ge 2 ]] || usage; repo=$2; shift 2 ;;
    --issue) [[ -z "$issue" && $# -ge 2 ]] || usage; issue=$2; shift 2 ;;
    --body) [[ -z "$body" && $# -ge 2 ]] || usage; body=$2; shift 2 ;;
    --trigger) [[ -z "$trigger" && $# -ge 2 ]] || usage; trigger=$2; shift 2 ;;
    --reason) [[ -z "$reason" && $# -ge 2 ]] || usage; reason=$2; shift 2 ;;
    --authority-reference) [[ -z "$authority_reference" && $# -ge 2 ]] || usage; authority_reference=$2; shift 2 ;;
    --delegate) [[ -z "$delegate" && $# -ge 2 ]] || usage; delegate=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || usage
revision_tool="$repo_root/tools/lib/issue-contract-revision.rb"

if [[ "$command" == validate ]]; then
  [[ -z "$body$trigger$reason$authority_reference$delegate" ]] || usage
  exec ruby "$revision_tool" validate --repo-root "$repo_root" --repo "$repo" --issue "$issue"
fi

[[ -n "$body" && -f "$body" && ! -L "$body" && -n "$trigger" && -n "$reason" ]] || usage
case "$trigger" in
  user-explicit)
    [[ -z "$delegate" ]] || { echo 'user-explicit cannot name --delegate' >&2; exit 2; }
    ;;
  user-delegated)
    [[ "$delegate" == codex || "$delegate" == claude ]] || { echo 'user-delegated requires --delegate codex|claude' >&2; exit 2; }
    ;;
  review-finding)
    [[ -z "$delegate" ]] || { echo 'review-finding cannot name --delegate' >&2; exit 2; }
    ;;
  *) usage ;;
esac
if [[ "$command" == marker ]]; then
  [[ "$trigger" == user-explicit || "$trigger" == user-delegated ]] || { echo 'marker supports only user-explicit or user-delegated' >&2; exit 2; }
  [[ -z "$authority_reference" ]] || usage
else
  [[ -n "$authority_reference" ]] || usage
fi

live_json=$(mktemp "${TMPDIR:-/tmp}/ios-template-contract-revision-live.XXXXXX")
trap 'rm -f "$live_json"' EXIT
read_live_issue() {
  workflow_github_preflight "$repo_root" "$repo" "$issue" github.read_issue || {
    echo 'GitHub account preflight failed before Issue read' >&2
    exit 1
  }
  gh issue view "$issue" --repo "$repo" --json number,url,title,body,labels,comments > "$live_json" || {
    echo 'Issue could not be read' >&2
    exit 1
  }
}

common=(--repo-root "$repo_root" --repo "$repo" --issue "$issue" --body "$body" --live-json "$live_json" --trigger "$trigger" --reason "$reason")
[[ -z "$delegate" ]] || common+=(--delegate "$delegate")

read_live_issue
if [[ "$command" == marker ]]; then
  ruby "$revision_tool" marker "${common[@]}" | jq -er '.marker'
  exit 0
fi

pending="$repo_root/.artifacts/issues/$issue/issue-contract-revision.pending.json"
if [[ -e "$pending" || -L "$pending" ]]; then
  preparation=$(ruby "$revision_tool" resume "${common[@]}" --authority-reference "$authority_reference")
else
  preparation=$(ruby "$revision_tool" prepare "${common[@]}" --authority-reference "$authority_reference")
fi
live_side=$(jq -er '.liveBody | select(. == "before" or . == "after")' <<< "$preparation")

if [[ "$live_side" == before ]]; then
  workflow_github_preflight "$repo_root" "$repo" "$issue" github.update_issue || {
    echo 'GitHub account preflight failed before Issue body revision' >&2
    exit 1
  }
  gh issue edit "$issue" --repo "$repo" --body-file "$body" >/dev/null
  [[ "${IOS_TEMPLATE_REVISION_FAIL_AFTER_REMOTE:-0}" != 1 ]] || {
    echo 'injected failure after remote Issue revision' >&2
    exit 97
  }
  read_live_issue
fi

result=$(ruby "$revision_tool" activate "${common[@]}" --authority-reference "$authority_reference")
printf '%s\n' "$result"
