#!/usr/bin/env bash
set -euo pipefail

# The post-Claim pending-recovery and successor-transition regressions of the workflow state test run
# here as a direct test, so a targeted suite reaches them while test-workflow-state.sh runs scoped.
# Bash 3.2 can report success after an unbound variable when an EXIT trap runs, so the run must also
# reach the final assertion line.
output=$(/bin/bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/test-workflow-state.sh" post-claim 2>&1) || {
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output"
[[ "$output" == *'PASS: GitHub preflight and model-neutral durable state transitions'* ]] || {
  echo 'post-Claim workflow state regressions did not reach their final assertion' >&2
  exit 1
}
