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
  local branch=$1 worktree=$2 base_sha=$3 contract_digest=$4 state=${5:-approved}
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
    issue, repo, branch, worktree, base, agent, digest, state = ARGV
    value = {
      "schemaVersion" => 1, "issue" => Integer(issue), "repository" => repo,
      "branch" => branch, "worktree" => worktree, "baseSha" => base,
      "primaryImplementer" => agent,
      "issueContract" => {"path" => ".artifacts/issues/#{issue}/issue-contract.json", "digest" => digest},
      "state" => state, "previousState" => (state == "claimed" ? "approved" : nil), "resumeState" => nil,
      "executor" => "codex"
    }
    puts JSON.generate(canonical(value))
  ' "$issue" "$repo" "$branch" "$worktree" "$base_sha" "$agent" "$contract_digest" "$state" > "${state_file}.tmp"
  chmod 600 "${state_file}.tmp"
  mv -f "${state_file}.tmp" "$state_file"
}

claim_fail_after() {
  [[ "${IOS_TEMPLATE_CLAIM_FAIL_AFTER:-}" != "$1" ]] || { echo "injected Claim failure after $1" >&2; exit 97; }
}

workflow_github_preflight "$repo_root" "$repo" "$issue" github.read_issue || { echo 'GitHub account preflight failed before Issue read' >&2; exit 1; }
issue_json=$(gh issue view "$issue" --repo "$repo" --json title,body,labels,comments) || { echo 'Issue could not be read' >&2; exit 1; }
current_state=$(printf '%s' "$issue_json" | issue_state_from_json)
workflow_is_state "$current_state" || conflict 'Issue has an unknown current state label'
if [[ "$current_state" == approved ]]; then
  workflow_require_live_issue_operation "$repo_root" "$repo" "$issue" "$issue_json" github.read_issue || conflict 'live Issue contract does not authorize Issue reads'
elif [[ "$current_state" == claimed ]]; then
  workflow_require_sealed_issue_operation "$repo_root" "$repo" "$issue" github.read_issue || conflict 'sealed Issue contract does not authorize Issue reads'
else
  conflict "Issue state is $current_state, not approved or claimed"
fi
title=$(printf '%s' "$issue_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("title")')
body=$(mktemp "${TMPDIR:-/tmp}/ios-template-issue-body.XXXXXX")
contract_candidate=$(mktemp "${TMPDIR:-/tmp}/ios-template-issue-contract.XXXXXX")
trap 'rm -f "$body" "$contract_candidate"' EXIT
cleanup_claim_temps() {
  rm -f "$body" "$contract_candidate"
  trap - EXIT
}
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

existing_contract_path="$repo_root/.artifacts/issues/$issue/issue-contract.json"
if [[ -f "$existing_contract_path" && ! -L "$existing_contract_path" ]]; then
  fetched_at=$(jq -er '.fetchedAt | strings' "$existing_contract_path") || conflict 'sealed Issue contract has no fetchedAt'
else
  fetched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi
ruby "$repo_root/tools/lib/issue-contract.rb" \
  --body "$body" --type "$issue_type" --format contract \
  --issue "$issue" --repo "$repo" --fetched-at "$fetched_at" \
  > "$contract_candidate"
contract_digest="sha256:$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$contract_candidate")"

for required_operation in github.read_issue github.update_issue github.push_branch github.create_pr github.merge_pr github.delete_branch; do
  if [[ "$current_state" == approved ]]; then
    workflow_require_live_issue_operation "$repo_root" "$repo" "$issue" "$issue_json" "$required_operation" || conflict "normal shipping operation is undeclared: $required_operation"
  else
    workflow_require_sealed_issue_operation "$repo_root" "$repo" "$issue" "$required_operation" || conflict "sealed shipping operation is undeclared: $required_operation"
  fi
done

# The update identity is checked before any Branch/worktree/durable Claim
# publication, so an account or repository mismatch leaves user Git state alone.
workflow_github_preflight "$repo_root" "$repo" "$issue" github.update_issue || conflict 'GitHub account preflight failed before Claim publication'

git -C "$repo_root" fetch origin main >/dev/null
base_sha=$(git -C "$repo_root" rev-parse --verify 'origin/main^{commit}') || { echo 'origin/main is not a verified commit' >&2; exit 1; }

expected_candidates=$(printf '%s\n' "$branches" | sed '/^$/d' | sort -u)
if [[ -n "$expected_candidates" && "$expected_candidates" != "$branch" ]]; then conflict 'Issue has a conflicting Branch candidate'; fi
if [[ -n "$worktrees" && "$worktrees" != "$worktree_path" ]]; then conflict 'Issue has a conflicting worktree candidate'; fi

if ! git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$repo_root" branch "$branch" "$base_sha" >/dev/null
fi
[[ "$(git -C "$repo_root" rev-parse "refs/heads/$branch")" == "$base_sha" ]] || conflict 'canonical Claim Branch does not match origin/main Base'
claim_fail_after branch

mkdir -p "$repo_root/.worktrees"
if [[ ! -d "$worktree_path" ]]; then
  [[ ! -e "$worktree_path" && ! -L "$worktree_path" ]] || conflict 'canonical worktree path is occupied'
  git -C "$repo_root" worktree add "$worktree_path" "$branch" >/dev/null
fi
[[ "$(git -C "$worktree_path" branch --show-current)" == "$branch" ]] || conflict 'canonical worktree Branch differs'
claim_fail_after worktree

workflow_shared_artifacts_link install "$repo_root" "$worktree_path" "$issue" "$slug" "$branch" || conflict 'canonical shared artifact link could not be installed safely'
claim_fail_after link

contract_path="$repo_root/.artifacts/issues/$issue/issue-contract.json"
mkdir -p "$(dirname "$contract_path")"
if [[ -e "$contract_path" || -L "$contract_path" ]]; then
  [[ -f "$contract_path" && ! -L "$contract_path" ]] || conflict 'canonical Issue contract path is unsafe'
  cmp -s "$contract_candidate" "$contract_path" || conflict 'live Issue contract differs from the sealed Claim contract'
else
  contract_temporary=$(mktemp "${contract_path}.tmp.XXXXXX")
  cp "$contract_candidate" "$contract_temporary"
  chmod 600 "$contract_temporary"
  mv -f "$contract_temporary" "$contract_path"
fi
claim_fail_after contract

state_file="$repo_root/.artifacts/issues/$issue/state.json"
if [[ -e "$state_file" || -L "$state_file" ]]; then
  ruby "$repo_root/tools/lib/workflow-json.rb" validate-claim-state "$state_file" "$issue" "$repo" "$branch" "$worktree_relative" "$base_sha" "$agent" "$contract_digest" >/dev/null || conflict 'durable Claim state differs from this exact agent or contract'
else
  write_claim_state "$branch" "$worktree_relative" "$base_sha" "$contract_digest" approved
fi
claim_fail_after state

state_fail_after_label=0
state_fail_after_comment=0
[[ "${IOS_TEMPLATE_CLAIM_FAIL_AFTER:-}" != remote-label ]] || state_fail_after_label=1
[[ "${IOS_TEMPLATE_CLAIM_FAIL_AFTER:-}" != remote-comment ]] || state_fail_after_comment=1
if [[ "$current_state" == approved || -e "$(dirname "$state_file")/state-transition.pending.json" ]]; then
  IOS_TEMPLATE_STATE_FAIL_AFTER_LABEL="$state_fail_after_label" \
    IOS_TEMPLATE_STATE_FAIL_AFTER_COMMENT="$state_fail_after_comment" \
    "$repo_root/tools/issue-state.sh" transition --repo "$repo" --issue "$issue" --from approved --to claimed >/dev/null
fi

if [[ "$current_state" == claimed && ! -e "$(dirname "$state_file")/state-transition.pending.json" ]]; then
  cleanup_claim_temps
  exec "$repo_root/tools/resume-issue.sh" --repo "$repo" --issue "$issue"
fi

cleanup_claim_temps
jq -cn --arg repository "$repo" --argjson issue "$issue" --arg branch "$branch" --arg worktree "$worktree_relative" --arg baseSha "$base_sha" --arg agent "$agent" --arg digest "$contract_digest" '{repository:$repository,issue:$issue,branch:$branch,worktree:$worktree,baseSha:$baseSha,primaryImplementer:$agent,issueContract:{path:(".artifacts/issues/" + ($issue|tostring) + "/issue-contract.json"),digest:$digest},state:"claimed",previousState:"approved",resumeState:null,executor:"codex"}'
