#!/usr/bin/env bash

workflow_is_state() {
  case "$1" in
    proposed|approved|claimed|in-progress|verify-passed|review-requested|changes-requested|approved-for-merge|merged|done|paused|superseded|blocked:user|blocked:ops|blocked:review|blocked:conflict|blocked:dependency|blocked:environment|blocked:repeated-failure) return 0 ;;
    *) return 1 ;;
  esac
}

workflow_is_blocked() {
  [[ "$1" == blocked:* ]] && workflow_is_state "$1"
}

workflow_github_preflight() {
  local repo_root=$1 repo=$2 issue=$3 operation=$4 head
  head=$(git -C "$repo_root" rev-parse HEAD) || return 1
  "$repo_root/tools/github-account-preflight.sh" \
    --repo "$repo" --issue "$issue" --intended-operation "$operation" --expected-head "$head" >/dev/null
}

workflow_issue_type_from_json() {
  ruby -rjson -e '
    labels = JSON.parse(STDIN.read).fetch("labels")
    types = labels.map { |label| name = label.is_a?(Hash) ? label["name"] : nil; name&.start_with?("type:") ? name.delete_prefix("type:") : nil }.compact
    abort "Issue has ambiguous type labels" if types.length > 1
    type = types.fetch(0, "feature")
    abort "Issue type is not supported" unless %w[feature regression docs release].include?(type)
    puts type
  '
}

workflow_require_live_issue_operation() {
  local repo_root=$1 repo=$2 issue=$3 issue_json=$4 operation=$5 issue_type body_file envelope
  issue_type=$(printf '%s' "$issue_json" | workflow_issue_type_from_json) || return 1
  body_file=$(mktemp "${TMPDIR:-/tmp}/ios-template-live-issue.XXXXXX") || return 1
  printf '%s' "$issue_json" | ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("body")' > "$body_file" || { rm -f "$body_file"; return 1; }
  envelope=$(ruby "$repo_root/tools/lib/issue-contract.rb" \
    --body "$body_file" --type "$issue_type" --format envelope \
    --issue "$issue" --repo "$repo" --fetched-at 2000-01-01T00:00:00Z) || { rm -f "$body_file"; return 1; }
  rm -f "$body_file"
  OPERATION="$operation" ruby -rjson -e '
    value = JSON.parse(STDIN.read).fetch("contract").fetch("externalOperations")
    abort "required external operation is not declared: #{ENV.fetch("OPERATION")}" unless value.include?(ENV.fetch("OPERATION"))
  ' <<< "$envelope"
}

workflow_require_sealed_issue_operation() {
  local repo_root=$1 repo=$2 issue=$3 operation=$4 contract="$repo_root/.artifacts/issues/$issue/issue-contract.json"
  [[ -f "$contract" && ! -L "$contract" ]] || { echo 'sealed Issue contract is missing or unsafe' >&2; return 1; }
  ruby -I"$repo_root/tools/lib" -rissue-contract -rjson -rdigest -e '
    path, issue, repo, operation = ARGV
    bytes = File.binread(path)
    value = JSON.parse(bytes)
    IOSTemplate::IssueContract.validate_snapshot!(value, issue: Integer(issue), repository: repo)
    abort "sealed Issue contract is not canonical" unless bytes == IOSTemplate::IssueContract.canonical_json(value)
    abort "required external operation is not declared: #{operation}" unless IOSTemplate::IssueContract.operation_declared?(value, operation)
  ' "$contract" "$issue" "$repo" "$operation" || return 1
  local state_file="$repo_root/.artifacts/issues/$issue/state.json"
  if [[ -f "$state_file" && ! -L "$state_file" ]]; then
    local expected_digest actual_digest
    expected_digest=$(jq -er '.issueContract.digest | strings' "$state_file") || return 1
    actual_digest="sha256:$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$contract")"
    [[ "$expected_digest" == "$actual_digest" ]] || { echo 'sealed Issue contract digest differs from durable state' >&2; return 1; }
  fi
}

workflow_issue_has_sealed_identity() {
  local repo_root=$1 issue=$2
  local contract="$repo_root/.artifacts/issues/$issue/issue-contract.json"
  local state_file="$repo_root/.artifacts/issues/$issue/state.json"
  if [[ -e "$contract" || -L "$contract" ]]; then
    return 0
  fi
  if [[ ! -e "$state_file" && ! -L "$state_file" ]]; then
    return 1
  fi
  [[ -f "$state_file" && ! -L "$state_file" ]] || return 0
  # Only the exact minimal record produced before Claim may continue to use the
  # live Issue contract. Any full or malformed record requires sealed evidence
  # and therefore fails closed when the contract is absent.
  ruby -rjson -rtime -e '
    begin
      value = JSON.parse(File.binread(ARGV.fetch(0)))
      minimal = %w[executor from resumeState state timestamp to]
      states = %w[proposed approved claimed in-progress verify-passed review-requested changes-requested approved-for-merge merged done paused superseded blocked:user blocked:ops blocked:review blocked:conflict blocked:dependency blocked:environment blocked:repeated-failure]
      valid = value.is_a?(Hash) && value.keys.sort == minimal && value["executor"] == "codex" &&
        states.include?(value["state"]) && (value["from"].nil? || states.include?(value["from"])) &&
        states.include?(value["to"]) && (value["resumeState"].nil? || states.include?(value["resumeState"]))
      Time.iso8601(value["timestamp"]) if valid
      exit(valid ? 1 : 0)
    rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, ArgumentError, TypeError
      exit 0
    end
  ' "$state_file"
}

workflow_require_issue_operation() {
  local repo_root=$1 repo=$2 issue=$3 issue_json=$4 operation=$5 authorization=${6:-sealed}
  local expected_from=${7:-} expected_to=${8:-} state
  case "$authorization" in
    sealed)
      workflow_require_sealed_issue_operation "$repo_root" "$repo" "$issue" "$operation"
      ;;
    pre-claim-read)
      if workflow_issue_has_sealed_identity "$repo_root" "$issue"; then
        workflow_require_sealed_issue_operation "$repo_root" "$repo" "$issue" "$operation" || return 1
        return
      fi
      state=$(printf '%s' "$issue_json" | ruby "$repo_root/tools/lib/workflow-json.rb" state-from-issue) || return 1
      workflow_is_state "$state" || return 1
      [[ "$state" != claimed && "$state" != in-progress && "$state" != verify-passed &&
         "$state" != review-requested && "$state" != changes-requested &&
         "$state" != approved-for-merge && "$state" != merged && "$state" != done ]] || return 1
      workflow_require_live_issue_operation "$repo_root" "$repo" "$issue" "$issue_json" "$operation"
      ;;
    transition)
      [[ -n "$expected_from" && -n "$expected_to" ]] || return 1
      if workflow_issue_has_sealed_identity "$repo_root" "$issue"; then
        workflow_require_sealed_issue_operation "$repo_root" "$repo" "$issue" "$operation" || return 1
        # Claim publishes the first remote state only after both the sealed
        # snapshot and the freshly fetched live Issue still authorize it.
        if [[ "$expected_from" == approved && "$expected_to" == claimed ]]; then
          state=$(printf '%s' "$issue_json" | ruby "$repo_root/tools/lib/workflow-json.rb" state-from-issue) || return 1
          [[ "$state" == approved || "$state" == claimed ]] || return 1
          workflow_require_live_issue_operation "$repo_root" "$repo" "$issue" "$issue_json" "$operation"
        fi
        return
      fi
      state=$(printf '%s' "$issue_json" | ruby "$repo_root/tools/lib/workflow-json.rb" state-from-issue) || return 1
      [[ "$state" == "$expected_from" || "$state" == "$expected_to" ]] || return 1
      if [[ ! -e "$repo_root/.artifacts/issues/$issue/state.json" &&
            "$expected_from" != proposed && "$expected_from" != approved ]]; then
        return 1
      fi
      workflow_require_live_issue_operation "$repo_root" "$repo" "$issue" "$issue_json" "$operation"
      ;;
    *)
      return 1
      ;;
  esac
}

# A linked Issue worktree executes at its own Git Head, while durable evidence
# stays in the primary checkout. The link target is intentionally fixed by the
# canonical .worktrees/<issue>-<slug> layout; callers never supply a path.
workflow_shared_artifacts_link() {
  local mode=$1 primary_root=$2 worktree_path=$3 issue=$4 slug=$5 branch=$6
  [[ "$mode" == install || "$mode" == validate ]] || return 1
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  [[ "$branch" =~ ^(codex|claude)/${issue}-${slug}$ ]] || return 1
  [[ -d "$primary_root" && ! -L "$primary_root" && -d "$primary_root/.worktrees" && ! -L "$primary_root/.worktrees" ]] || return 1
  [[ "$worktree_path" == "$primary_root/.worktrees/${issue}-${slug}" && -d "$worktree_path" && ! -L "$worktree_path" ]] || return 1

  local primary_common worktree_common
  primary_common=$(ruby -e 'root, value = ARGV; puts File.realpath(File.expand_path(value, root))' "$primary_root" "$(git -C "$primary_root" rev-parse --git-common-dir)") || return 1
  worktree_common=$(ruby -e 'root, value = ARGV; puts File.realpath(File.expand_path(value, root))' "$worktree_path" "$(git -C "$worktree_path" rev-parse --git-common-dir)") || return 1
  [[ "$primary_common" == "$worktree_common" ]] || return 1

  local listed_path='' listed_branch='' entry_path='' entry_branch='' matches=0 line
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) entry_path=${line#worktree }; entry_branch='' ;;
      branch\ refs/heads/*)
        entry_branch=${line#branch refs/heads/}
        if [[ "$entry_path" == "$worktree_path" && "$entry_branch" == "$branch" ]]; then
          matches=$((matches + 1))
          listed_path=$entry_path
          listed_branch=$entry_branch
        fi
        ;;
    esac
  done < <(git -C "$primary_root" worktree list --porcelain)
  [[ "$matches" == 1 && "$listed_path" == "$worktree_path" && "$listed_branch" == "$branch" ]] || return 1

  local artifacts_root="$primary_root/.artifacts" link="$worktree_path/.artifacts" target='../../.artifacts'
  if [[ "$mode" == install && ! -e "$artifacts_root" && ! -L "$artifacts_root" ]]; then
    mkdir -p "$artifacts_root" || return 1
  fi
  [[ -d "$artifacts_root" && ! -L "$artifacts_root" ]] || return 1
  if [[ -e "$link" || -L "$link" ]]; then
    [[ -L "$link" && "$(readlink "$link")" == "$target" ]] || return 1
  elif [[ "$mode" == install ]]; then
    ln -s "$target" "$link" || return 1
  else
    return 1
  fi

  local artifacts_real link_real
  artifacts_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$artifacts_root") || return 1
  link_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$link") || return 1
  [[ "$artifacts_real" == "$link_real" ]]
}

# The state table is the complete table in docs/workflow.md.  Recovery from a
# blocked or paused state is checked separately against its durable marker.
workflow_transition_allowed() {
  local from=$1 to=$2
  workflow_is_state "$from" && workflow_is_state "$to" || return 1
  case "$from:$to" in
    proposed:approved|proposed:blocked:user|proposed:superseded|approved:claimed|approved:blocked:dependency|approved:paused|approved:superseded|claimed:in-progress|claimed:blocked:conflict|claimed:paused|in-progress:verify-passed|in-progress:paused|verify-passed:review-requested|verify-passed:in-progress|verify-passed:blocked:review|review-requested:changes-requested|review-requested:approved-for-merge|review-requested:blocked:review|changes-requested:in-progress|changes-requested:blocked:user|changes-requested:paused|approved-for-merge:merged|approved-for-merge:in-progress|approved-for-merge:blocked:conflict|approved-for-merge:blocked:ops|merged:done) return 0 ;;
    in-progress:blocked:*) workflow_is_blocked "$to" ;;
    blocked:*) [[ "$to" == paused || "$to" == superseded ]] || workflow_is_state "$to" ;;
    paused:*) [[ "$to" == superseded ]] || workflow_is_state "$to" ;;
    *) return 1 ;;
  esac
}
