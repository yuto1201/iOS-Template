#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
source "$repo_root/tools/lib/workflow.sh"
usage() { echo 'usage: resume-issue.sh --repo OWNER/REPO --issue NUMBER' >&2; exit 2; }
repo='' issue=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --issue) issue=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || usage

blocked() { echo "blocked:conflict: $*" >&2; exit 1; }
canonical_title_slug() {
  ruby -e '
    title = ARGV.fetch(0).encode("ASCII", invalid: :replace, undef: :replace, replace: "")
    slug = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "").gsub(/-+/, "-")
    abort "Issue title has no ASCII branch slug" if slug.empty?
    puts slug
  ' "$1"
}
"$repo_root/tools/github-account-preflight.sh" --repo "$repo" >/dev/null
issue_json=$(gh issue view "$issue" --repo "$repo" --json title,body,labels,comments) || { echo 'Issue could not be read' >&2; exit 1; }

marker=$(printf '%s' "$issue_json" | ruby -rjson -e '
  document = JSON.parse(STDIN.read)
  states = document.fetch("labels").map { |label| name = label.is_a?(Hash) ? label["name"] : nil; name&.start_with?("state:") ? name.delete_prefix("state:") : nil }.compact
  abort "Issue has no current state label" if states.empty?
  abort "Issue has ambiguous current state labels" unless states.length == 1
  current = states.fetch(0)
  found = nil
  document.fetch("comments").reverse_each do |comment|
    body = comment.is_a?(Hash) ? comment["body"] : nil
    next unless body.is_a?(String)
    next unless body.include?("<!-- ios-template-state")
    matches = body.scan(/<!-- ios-template-state (.*?) -->/m)
    abort "latest state-transition marker is malformed or ambiguous" unless matches.length == 1
    begin
      value = JSON.parse(matches.fetch(0).fetch(0))
    rescue JSON::ParserError
      abort "latest state-transition marker is malformed or ambiguous"
    end
    abort "latest state-transition marker is malformed or ambiguous" unless value.is_a?(Hash) && value.keys.sort == %w[executor from resumeState timestamp to] && value["executor"] == "codex" && value["from"].is_a?(String) && value["to"].is_a?(String) && (value["resumeState"].nil? || value["resumeState"].is_a?(String)) && value["timestamp"].is_a?(String)
    found = value
    break
  end
  abort "no current-state transition marker" unless found
  puts JSON.generate({"state" => current, "from" => found.fetch("from"), "to" => found.fetch("to"), "resumeState" => found.fetch("resumeState")})
') || blocked 'required state-transition marker is missing or ambiguous'
state=$(printf '%s' "$marker" | jq -er '.state')
workflow_is_state "$state" || blocked 'Issue has an unknown current state label'
marker_from=$(printf '%s' "$marker" | jq -er '.from')
marker_to=$(printf '%s' "$marker" | jq -er '.to')
resume_state_json=$(printf '%s' "$marker" | jq -c '.resumeState')
if [[ "$resume_state_json" == null ]]; then
  resume_state=''
  state_resume=null
else
  resume_state=$(printf '%s' "$marker" | jq -er '.resumeState')
  workflow_is_state "$resume_state" || blocked 'state-transition marker has an invalid resume state'
  state_resume=$resume_state
fi
[[ "$marker_to" == "$state" ]] || blocked 'latest state-transition marker does not match the current Issue state'
workflow_is_state "$marker_from" && workflow_is_state "$marker_to" && workflow_transition_allowed "$marker_from" "$marker_to" || blocked 'state-transition marker is not a legal workflow transition'
if workflow_is_blocked "$marker_from" || [[ "$marker_from" == paused ]]; then
  if [[ "$marker_to" != paused && "$marker_to" != superseded ]]; then
    [[ -n "$resume_state" && "$marker_to" == "$resume_state" ]] || blocked 'state-transition marker has an invalid blocked or paused resume state'
  fi
fi
if workflow_is_blocked "$marker_to" || [[ "$marker_to" == paused ]]; then
  [[ "$resume_state" == "$marker_from" ]] || blocked 'state-transition marker has an invalid blocked or paused resume state'
fi

title=$(printf '%s' "$issue_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("title")')
slug=$(canonical_title_slug "$title")
worktree_relative=".worktrees/$issue-$slug"

branches=()
while IFS= read -r ref; do
  branch=$ref
  [[ "$branch" == origin/* ]] && branch=${branch#origin/}
  [[ "$branch" =~ ^(codex|claude)/${issue}-${slug}$ ]] && branches+=("$branch")
done < <(git -C "$repo_root" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin)
unique_branches=$(printf '%s\n' "${branches[@]:-}" | sed '/^$/d' | sort -u)
[[ $(printf '%s\n' "$unique_branches" | sed '/^$/d' | wc -l | tr -d ' ') == 1 ]] || blocked 'expected exactly one local or remote Issue branch candidate'
branch=$(printf '%s\n' "$unique_branches" | sed '/^$/d')
git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch" || blocked 'canonical Issue branch is not local'

worktree_path=''
worktree_count=0
current_path=''
current_branch=''
while IFS= read -r line; do
  case "$line" in
    worktree\ *) current_path=${line#worktree }; current_branch='' ;;
    branch\ refs/heads/*)
      current_branch=${line#branch refs/heads/}
      if [[ "$current_branch" == "$branch" ]]; then
        worktree_path=$current_path
        worktree_count=$((worktree_count + 1))
      fi
      ;;
  esac
done < <(git -C "$repo_root" worktree list --porcelain)
[[ "$worktree_count" == 1 && "$worktree_path" == "$repo_root/$worktree_relative" ]] || blocked 'expected exactly one canonical Issue worktree candidate'
worktree_relative=${worktree_path#"$repo_root/"}
workflow_shared_artifacts_link install "$repo_root" "$worktree_path" "$issue" "$slug" "$branch" || blocked 'canonical shared artifact link is missing or unsafe'
base_sha=$(git -C "$repo_root" merge-base "$branch" origin/main) || blocked 'cannot reconstruct Base SHA from Branch and origin/main'
contract_path="$repo_root/.artifacts/issues/$issue/issue-contract.json"
[[ -f "$contract_path" && ! -L "$contract_path" ]] || blocked 'canonical Issue contract is missing'
contract_digest="sha256:$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$contract_path")"
agent=${branch%%/*}
previous_state=$marker_from
state_file="$repo_root/.artifacts/issues/$issue/state.json"
artifacts_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$repo_root/.artifacts") || blocked 'canonical artifact root cannot be resolved'
state_parent_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$(dirname "$state_file")") || blocked 'canonical state directory cannot be resolved'
[[ "$state_parent_real" == "$artifacts_real/issues/"* ]] || blocked 'state artifact path escapes the canonical store'
state_file="$state_parent_real/state.json"
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -e "$state_file" || -L "$state_file" ]]; then
  record=$(ruby "$repo_root/tools/lib/workflow-json.rb" transition-state-record "$state_file" "$issue" "$repo" "$state" "$previous_state" "$state" "$state_resume" "$timestamp" null) || blocked 'existing durable state identity is malformed or mismatched'
else
  record=$(ruby -rjson -e '
    def canonical(value)
      case value
      when Hash then value.keys.sort.each_with_object({}) { |key, out| out[key] = canonical(value[key]) }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end
    issue, repo, branch, worktree, base, agent, digest, state, previous, resume, timestamp = ARGV
    value = {"schemaVersion" => 1, "issue" => Integer(issue), "repository" => repo, "branch" => branch, "worktree" => worktree, "baseSha" => base, "primaryImplementer" => agent, "issueContract" => {"path" => ".artifacts/issues/#{issue}/issue-contract.json", "digest" => digest}, "state" => state, "previousState" => previous, "resumeState" => (resume == "null" ? nil : resume), "executor" => "codex", "from" => previous, "to" => state, "transitionedAt" => timestamp}
    puts JSON.generate(canonical(value))
  ' "$issue" "$repo" "$branch" "$worktree_relative" "$base_sha" "$agent" "$contract_digest" "$state" "$previous_state" "$state_resume" "$timestamp")
fi
temporary=$(mktemp "${state_file}.tmp.XXXXXX")
printf '%s\n' "$record" > "$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$state_file"
jq -cn --arg repository "$repo" --argjson issue "$issue" --arg branch "$branch" --arg worktree "$worktree_relative" --arg baseSha "$base_sha" --arg agent "$agent" --arg digest "$contract_digest" --arg state "$state" --arg previousState "$previous_state" --argjson resumeState "$resume_state_json" '{repository:$repository,issue:$issue,branch:$branch,worktree:$worktree,baseSha:$baseSha,primaryImplementer:$agent,issueContract:{path:(".artifacts/issues/" + ($issue|tostring) + "/issue-contract.json"),digest:$digest},state:$state,previousState:$previousState,resumeState:$resumeState,executor:"codex"}'
