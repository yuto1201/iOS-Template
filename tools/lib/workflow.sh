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
