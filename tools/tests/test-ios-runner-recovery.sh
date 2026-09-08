#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

prepare_repo late-failure-retry
FAKE_CASE_MODE=late-fail expect_execute_failure late-failure-retry "case ipad-ja failed"
for case_id in iphone-en iphone-ja ipad-en ipad-ja; do
  [[ ! -e "$(dirname "$draft")/$case_id/screenshot.png" ]] || { echo "late failure exposed canonical screenshot" >&2; exit 1; }
done
run_execute
[[ -f "$draft" ]] || { echo "same-Head retry did not publish draft" >&2; exit 1; }

prepare_repo draft-collision
FAKE_COLLIDE_DRAFT=1 expect_execute_failure draft-collision "atomic staged evidence publication failed"
grep -Fq sentinel-draft "$draft" || { echo "draft collision replaced the winner" >&2; exit 1; }
for case_id in iphone-en iphone-ja ipad-en ipad-ja; do
  [[ ! -e "$(dirname "$draft")/$case_id/screenshot.png" ]] || { echo "draft collision left a partial screenshot bundle" >&2; exit 1; }
done


prepare_repo killed-draft-publication
FAKE_PUBLICATION_KILL=1 expect_execute_failure killed-draft-publication "atomic staged evidence publication failed"
run_execute
[[ -f "$draft" ]] || { echo "same-Head retry did not recover killed draft publication" >&2; exit 1; }
[[ ! -e "$(dirname "$draft")/.verify-publication-journal.json" ]] || { echo "successful retry left publication journal" >&2; exit 1; }


assert_runner_publication_cleanup
echo "recovery iOS runner tests passed"
