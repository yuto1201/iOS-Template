#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
source "$repo_root/tools/lib/workflow.sh"

usage() { echo 'usage: claim-issue.sh --repo OWNER/REPO --issue NUMBER --agent codex|claude' >&2; exit 2; }
repo='' issue='' agent=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --issue) issue=${2:-}; shift 2 ;;
    --agent) agent=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$agent" == codex || "$agent" == claude ]] || usage

conflict() {
  echo "blocked:conflict: $*" >&2
  exit 1
}

canonical_title_slug() {
  ruby -e '
    title = ARGV.fetch(0).encode("ASCII", invalid: :replace, undef: :replace, replace: "")
    slug = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "").gsub(/-+/, "-")
    abort "Issue title has no ASCII branch slug" if slug.empty?
    puts slug
  ' "$1"
}

issue_state_from_json() {
  ruby -rjson -e '
    labels = JSON.parse(STDIN.read).fetch("labels")
    states = labels.map { |label| name = label.is_a?(Hash) ? label["name"] : nil; name&.start_with?("state:") ? name.delete_prefix("state:") : nil }.compact
    abort "Issue has no current state label" if states.empty?
    abort "Issue has ambiguous current state labels" unless states.length == 1
    puts states.fetch(0)
  '
}

issue_type_from_json() {
  ruby -rjson -e '
    labels = JSON.parse(STDIN.read).fetch("labels")
    types = labels.map { |label| name = label.is_a?(Hash) ? label["name"] : nil; name&.start_with?("type:") ? name.delete_prefix("type:") : nil }.compact
    abort "Issue has ambiguous type labels" if types.length > 1
    puts(types.fetch(0, "feature"))
  '
}

candidate_branches() {
  local ref branch
  while IFS= read -r ref; do
    branch=$ref
    [[ "$branch" == origin/* ]] && branch=${branch#origin/}
    [[ "$branch" =~ ^(codex|claude)/${issue}-[a-z0-9][a-z0-9-]*$ ]] && printf '%s\n' "$branch"
  done < <(git -C "$repo_root" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin)
}

worktree_candidates() {
  local entry path
  while IFS= read -r entry; do
    [[ "$entry" == worktree\ * ]] || continue
    path=${entry#worktree }
    [[ "$path" == "$repo_root/.worktrees/${issue}-"* ]] && printf '%s\n' "$path"
  done < <(git -C "$repo_root" worktree list --porcelain)
}

write_claim_state() {
  local branch=$1 worktree=$2 base_sha=$3 contract_digest=$4
  local state_file="$repo_root/.artifacts/issues/$issue/state.json"
  mkdir -p "$(dirname "$state_file")"
  ruby -rjson -rdigest -e '
    def canonical(value)
      case value
      when Hash then value.keys.sort.each_with_object({}) { |key, out| out[key] = canonical(value[key]) }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end
    issue, repo, branch, worktree, base, agent, digest = ARGV
    value = {
      "schemaVersion" => 1, "issue" => Integer(issue), "repository" => repo,
      "branch" => branch, "worktree" => worktree, "baseSha" => base,
      "primaryImplementer" => agent,
      "issueContract" => {"path" => ".artifacts/issues/#{issue}/issue-contract.json", "digest" => digest},
      "state" => "claimed", "previousState" => "approved", "resumeState" => nil,
      "executor" => "codex"
    }
    puts JSON.generate(canonical(value))
  ' "$issue" "$repo" "$branch" "$worktree" "$base_sha" "$agent" "$contract_digest" > "${state_file}.tmp"
  chmod 600 "${state_file}.tmp"
  mv -f "${state_file}.tmp" "$state_file"
}

"$repo_root/tools/github-account-preflight.sh" --repo "$repo" >/dev/null
issue_json=$(gh issue view "$issue" --repo "$repo" --json title,body,labels,comments) || { echo 'Issue could not be read' >&2; exit 1; }
current_state=$(printf '%s' "$issue_json" | issue_state_from_json)
workflow_is_state "$current_state" || conflict 'Issue has an unknown current state label'
title=$(printf '%s' "$issue_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("title")')
body=$(mktemp "${TMPDIR:-/tmp}/ios-template-issue-body.XXXXXX")
contract_candidate=$(mktemp "${TMPDIR:-/tmp}/ios-template-issue-contract.XXXXXX")
trap 'rm -f "$body" "$contract_candidate"' EXIT
printf '%s' "$issue_json" | ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("body")' > "$body"
issue_type=$(printf '%s' "$issue_json" | issue_type_from_json)
if [[ "$issue_type" == regression ]]; then
  "$repo_root/tools/validate-issue-body.sh" --type regression "$body" >/dev/null
else
  "$repo_root/tools/validate-issue-body.sh" --type feature "$body" >/dev/null
fi

slug=$(canonical_title_slug "$title")
branch="$agent/$issue-$slug"
worktree_relative=".worktrees/$issue-$slug"
worktree_path="$repo_root/$worktree_relative"
branches=$(candidate_branches | sort -u || true)
worktrees=$(worktree_candidates || true)

if [[ "$current_state" == claimed ]]; then
  [[ $(printf '%s\n' "$branches" | sed '/^$/d' | wc -l | tr -d ' ') == 1 && "$branches" == "$branch" && -n "$worktrees" ]] || conflict 'claimed Issue does not have exactly its canonical Branch and worktree'
  [[ $(printf '%s\n' "$worktrees" | sed '/^$/d' | wc -l | tr -d ' ') == 1 ]] || conflict 'claimed Issue has multiple worktree candidates'
  exec "$repo_root/tools/resume-issue.sh" --repo "$repo" --issue "$issue"
fi
[[ "$current_state" == approved ]] || conflict "Issue state is $current_state, not approved"
[[ -z "$branches" && -z "$worktrees" && ! -e "$worktree_path" ]] || conflict 'Issue already has a conflicting Branch or worktree candidate'

fetched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s' "$issue_json" | ruby -rjson -e '
  require "json"
  def canonical(value)
    case value
    when Hash then value.keys.sort.each_with_object({}) { |key, out| out[key] = canonical(value[key]) }
    when Array then value.map { |entry| canonical(entry) }
    else value
    end
  end
  issue, repo, fetched_at = ARGV
  document = JSON.parse(STDIN.read)
  body = document.fetch("body")
  headings = []
  body.each_line.with_index(1) { |line, number| match = line.match(/\A#+\s+(.+?)\s*\z/); headings << [match[1], number] if match }
  section = lambda do |name|
    index = headings.index { |heading, _| heading == name }
    abort "Issue body missing #{name}" unless index
    start_line = headings[index][1]
    stop = headings[(index + 1)..]&.first&.last || body.lines.length + 1
    body.lines[start_line...stop - 1].join.strip
  end
  goal = section.call("Goal")
  anchors = section.call("Spec anchors").scan(/\[[^\]]+\]\(([^)]+)\)/).flatten.map { |raw| raw.strip.sub(/\A<|>\z/, "") }.uniq
  abort "Issue body has no specification anchors" if anchors.empty?
  criteria = section.call("Acceptance criteria").each_line.map do |line|
    match = line.match(/^\s*[-*]\s+(AC-(\d+))\s*:\s*(\S.*?)\s*$/)
    match && {"id" => match[1], "text" => match[3]}
  end.compact
  abort "Issue body has no acceptance criteria" if criteria.empty?
  criteria.each_with_index { |criterion, index| abort "Acceptance criteria must be AC-1 through AC-n" unless criterion["id"] == "AC-#{index + 1}" }
  abort "Acceptance criteria must be unique" unless criteria.map { |criterion| criterion["id"] }.uniq.length == criteria.length
  dependencies_section = section.call("Dependencies")
  dependencies = dependencies_section.match?(/\A\s*(?:[-*]\s*)?None\.?\s*\z/i) ? [] : dependencies_section.scan(/#([1-9][0-9]*)/).flatten.map(&:to_i).uniq
  external_section = section.call("External operations")
  external = external_section.match?(/\A\s*(?:[-*]\s*)?None\.?\s*\z/i) ? [] : external_section.each_line.map { |line| line.strip.sub(/\A[-*]\s*/, "") }.reject(&:empty?).uniq
  contract = {"schemaVersion" => 1, "issue" => Integer(issue), "repository" => repo, "goal" => goal, "specAnchors" => anchors, "acceptanceCriteria" => criteria, "dependencies" => dependencies, "externalOperations" => external, "fetchedAt" => fetched_at}
  print JSON.generate(canonical(contract))
' "$issue" "$repo" "$fetched_at" > "$contract_candidate"
contract_digest="sha256:$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$contract_candidate")"

git -C "$repo_root" fetch origin main >/dev/null
base_sha=$(git -C "$repo_root" rev-parse --verify 'origin/main^{commit}') || { echo 'origin/main is not a verified commit' >&2; exit 1; }
"$repo_root/tools/issue-state.sh" transition --repo "$repo" --issue "$issue" --from approved --to claimed >/dev/null
mkdir -p "$repo_root/.worktrees"
git -C "$repo_root" worktree add -b "$branch" "$worktree_path" "$base_sha" >/dev/null
if ! workflow_shared_artifacts_link install "$repo_root" "$worktree_path" "$issue" "$slug" "$branch"; then
  git -C "$repo_root" worktree remove "$worktree_path" >/dev/null 2>&1 || true
  git -C "$repo_root" branch -D -- "$branch" >/dev/null 2>&1 || true
  "$repo_root/tools/issue-state.sh" transition --repo "$repo" --issue "$issue" --from claimed --to blocked:conflict >/dev/null 2>&1 || true
  conflict 'canonical shared artifact link could not be installed; local worktree creation was rolled back'
fi

contract_path="$repo_root/.artifacts/issues/$issue/issue-contract.json"
mkdir -p "$(dirname "$contract_path")"
mv -f "$contract_candidate" "$contract_path"
write_claim_state "$branch" "$worktree_relative" "$base_sha" "$contract_digest"
trap - EXIT
jq -cn --arg repository "$repo" --argjson issue "$issue" --arg branch "$branch" --arg worktree "$worktree_relative" --arg baseSha "$base_sha" --arg agent "$agent" --arg digest "$contract_digest" '{repository:$repository,issue:$issue,branch:$branch,worktree:$worktree,baseSha:$baseSha,primaryImplementer:$agent,issueContract:{path:(".artifacts/issues/" + ($issue|tostring) + "/issue-contract.json"),digest:$digest},state:"claimed",previousState:"approved",resumeState:null,executor:"codex"}'
