#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby

# The second half of the nested stop-state resume regressions of the workflow state test (earlier-pause
# episodes, interrupted resume replay, and the superseded close) runs here as a direct test, so a targeted
# suite reaches it within its per-test limit while test-workflow-state.sh runs scoped (#411). Bash 3.2 can
# report success after an unbound variable when an EXIT trap runs, so the run must also reach the final
# assertion line.
output=$(/bin/bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/test-workflow-state.sh" nested-resume-recovery 2>&1) || {
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output"
[[ "$output" == *'PASS: nested stop-state resume recovery regressions'* ]] || {
  echo 'nested stop-state resume recovery regressions did not reach their final assertion' >&2
  exit 1
}
