#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

for canonical_name in .verify-publication-journal.json screenshot.png verify-draft.json; do
  label="kill-after-${canonical_name//[^A-Za-z0-9]/-}"
  prepare_repo "$label"
  FAKE_PUBLICATION_KILL_AFTER_TARGET="$canonical_name" expect_execute_failure "$label" "atomic staged evidence publication failed"
  : >"$fake_log"
  run_execute
  assert_no_failed_attempts
  [[ -f "$draft" ]] || { echo "same-Head retry failed after kill after $canonical_name" >&2; exit 1; }
  if [[ "$canonical_name" == verify-draft.json ]] && /usr/bin/awk -F '\t' '$1 == "xcodebuild" {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
    echo "complete canonical draft transaction was re-executed" >&2; exit 1
  fi
done


assert_runner_publication_cleanup
echo "recovery-after-rename iOS runner tests passed"
