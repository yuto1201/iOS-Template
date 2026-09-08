#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

for source in contract matrix; do
  prepare_repo "final-publication-race-$source"
  run_execute
  write_visual approved
  FAKE_PUBLICATION_RACE="$source" expect_finalize_failure "final-publication-race-$source" "visual result is invalid"
done

prepare_repo final-publication-race-candidate
run_execute
write_visual approved
FAKE_PUBLICATION_RACE=candidate expect_finalize_failure final-publication-race-candidate "visual result is invalid"
[[ ! -e "$final" ]] || { echo "publication-boundary candidate substitution became canonical" >&2; exit 1; }

prepare_repo final-collision
run_execute
write_visual approved
if FAKE_COLLIDE_FINAL=1 run_finalize >"$scratch/final-collision.stdout" 2>"$scratch/final-collision.stderr"; then
  echo "finalizer replaced an existing canonical winner" >&2; exit 1
fi
grep -Fq "canonical verify.json already exists" "$scratch/final-collision.stderr"
grep -Fq sentinel-final "$final" || { echo "final collision changed the winner" >&2; exit 1; }

prepare_repo candidate-substitution
run_execute
write_visual approved
FAKE_CANDIDATE_MODE=substitute expect_finalize_failure candidate-substitution "visual result is invalid"
[[ ! -e "$final" ]] || { echo "substituted candidate became canonical" >&2; exit 1; }

prepare_repo stale-head
run_execute
write_visual approved
printf '%s\n' '# New head' >"$repo/docs/new-head.md"
git -C "$repo" add -- docs/new-head.md
git -C "$repo" commit -q -m new-head
expect_finalize_failure stale-head "current Git Head"

prepare_repo canonical-paths
run_execute
write_visual approved
if (cd "$repo" && "$runner" --finalize --issue 42 --expected-base "$base_sha" --draft "$draft" --visual-result "$visual") >"$scratch/path.stdout" 2>"$scratch/path.stderr"; then
  echo "finalizer accepted absolute non-interface paths" >&2; exit 1
fi
grep -Fq "canonical" "$scratch/path.stderr"


assert_runner_publication_cleanup
echo "finalization-integrity iOS runner tests passed"
