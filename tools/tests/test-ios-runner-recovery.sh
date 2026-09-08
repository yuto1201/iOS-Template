#!/usr/bin/env bash
set -euo pipefail

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

for canonical_name in .verify-publication-journal.json screenshot.png verify-draft.json; do
  label="kill-before-${canonical_name//[^A-Za-z0-9]/-}"
  prepare_repo "$label"
  FAKE_PUBLICATION_KILL_TARGET="$canonical_name" expect_execute_failure "$label" "atomic staged evidence publication failed"
  run_execute
  [[ -f "$draft" ]] || { echo "same-Head retry failed after kill before $canonical_name" >&2; exit 1; }
done

for canonical_name in .verify-publication-journal.json screenshot.png verify-draft.json; do
  label="kill-after-${canonical_name//[^A-Za-z0-9]/-}"
  prepare_repo "$label"
  FAKE_PUBLICATION_KILL_AFTER_TARGET="$canonical_name" expect_execute_failure "$label" "atomic staged evidence publication failed"
  : >"$fake_log"
  run_execute
  [[ -f "$draft" ]] || { echo "same-Head retry failed after kill after $canonical_name" >&2; exit 1; }
  if [[ "$canonical_name" == verify-draft.json ]] && /usr/bin/awk -F '\t' '$1 == "xcodebuild" {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
    echo "complete canonical draft transaction was re-executed" >&2; exit 1
  fi
done

prepare_repo kill-before-final
run_execute
write_visual approved
FAKE_PUBLICATION_KILL_TARGET=verify.json expect_finalize_failure kill-before-final "visual result is invalid"
run_finalize
[[ -f "$final" ]] || { echo "final retry failed after kill before canonical rename" >&2; exit 1; }

prepare_repo kill-after-final
run_execute
write_visual approved
if FAKE_PUBLICATION_KILL_AFTER_TARGET=verify.json run_finalize >"$scratch/kill-after-final.stdout" 2>"$scratch/kill-after-final.stderr"; then
  echo "kill-after-final fixture unexpectedly returned success" >&2; exit 1
fi
[[ -f "$final" ]] || { echo "kill after final rename did not leave canonical evidence" >&2; exit 1; }
run_finalize
[[ -f "$final" ]] || { echo "final retry did not accept exact canonical evidence" >&2; exit 1; }

prepare_repo corrupt-after-final
run_execute
write_visual approved
if FAKE_PUBLICATION_KILL_AFTER_TARGET=verify.json run_finalize >"$scratch/corrupt-after-final.stdout" 2>"$scratch/corrupt-after-final.stderr"; then
  echo "corrupt-after-final fixture unexpectedly returned success" >&2; exit 1
fi
/bin/chmod 0600 "$final"
printf '%s\n' corrupt-final >"$final"
/bin/chmod 0400 "$final"
if run_finalize >"$scratch/corrupt-final-retry.stdout" 2>"$scratch/corrupt-final-retry.stderr"; then
  echo "finalizer accepted corrupt existing canonical evidence" >&2; exit 1
fi
grep -Fq 'canonical verify.json already exists' "$scratch/corrupt-final-retry.stderr" || { echo "corrupt final retry reported the wrong error" >&2; exit 1; }


assert_runner_publication_cleanup
echo "recovery iOS runner tests passed"
