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
