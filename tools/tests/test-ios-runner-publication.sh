#!/usr/bin/env bash
set -euo pipefail

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

prepare_repo final-publication-race-image-bytes
run_execute
write_additional_png "$(dirname "$draft")/iphone-en/screenshot.png" "$(dirname "$draft")/iphone-en/settings-open.png"
write_visual approved
FAKE_PUBLICATION_RACE=image-bytes expect_finalize_failure final-publication-race-image-bytes "visual result is invalid"

prepare_repo final-publication-race-image-set
run_execute
write_visual approved
FAKE_PUBLICATION_RACE=image-set expect_finalize_failure final-publication-race-image-set "visual result is invalid"

prepare_repo final-publication-race-packet
run_execute
write_visual approved
FAKE_PUBLICATION_RACE=packet expect_finalize_failure final-publication-race-packet "visual result is invalid"

prepare_repo final-publication-race-visual-result
run_execute
write_visual approved
FAKE_PUBLICATION_RACE=visual-result expect_finalize_failure final-publication-race-visual-result "visual result is invalid"

for source in contract matrix; do
  prepare_repo "mutated-after-case-$source"
  FAKE_MUTATE_AFTER_CASE="$source" expect_execute_failure "mutated-after-case-$source" "$source changed during verification"
  if /usr/bin/awk -F '\t' '
    $3 == "simctl" && $4 == "io" && $5 == "00000000-0000-0000-0000-000000000001" {screenshot=1}
    screenshot && $3 == "simctl" && $4 == "terminate" && $5 == "00000000-0000-0000-0000-000000000001" {boundary=1; next}
    boundary && $3 == "simctl" && $5 == "00000000-0000-0000-0000-000000000002" {found=1}
    END {exit found ? 0 : 1}
  ' "$fake_log"; then
    echo "runner issued later-case Simulator commands after $source mutation" >&2; exit 1
  fi
done

for source in contract matrix; do
  prepare_repo "publication-race-$source"
  FAKE_PUBLICATION_RACE="$source" expect_execute_failure "publication-race-$source" "atomic staged evidence publication failed"
  [[ ! -e "$draft" ]] || { echo "publication race emitted a stale draft" >&2; exit 1; }
  for case_id in iphone-en iphone-ja ipad-en ipad-ja; do
    [[ ! -e "$(dirname "$draft")/$case_id/screenshot.png" ]] || { echo "publication race left a screenshot" >&2; exit 1; }
  done
done


assert_runner_publication_cleanup
echo "publication iOS runner tests passed"
