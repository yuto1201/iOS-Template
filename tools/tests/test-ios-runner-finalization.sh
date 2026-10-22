#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

for mode in rejected wrong-digest wrong-head missing-case case-finding wrong-screenshot-digest; do
  prepare_repo "final-$mode"
  run_execute
  write_visual "$mode"
  expect_finalize_failure "final-$mode" "visual"
done


assert_runner_publication_cleanup
echo "finalization iOS runner tests passed"
