#!/usr/bin/env bash
set -euo pipefail

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

for mode in rejected wrong-digest wrong-head missing-case case-finding wrong-screenshot-digest; do
  prepare_repo "final-$mode"
  run_execute
  write_visual "$mode"
  expect_finalize_failure "final-$mode" "visual"
done

prepare_repo screenshot-byte-mutation
run_execute
write_visual approved
screenshot_path="$(dirname "$draft")/iphone-en/screenshot.png"
/bin/chmod 0600 "$screenshot_path"
printf 'changed-after-draft' >>"$screenshot_path"
/bin/chmod 0400 "$screenshot_path"
expect_finalize_failure screenshot-byte-mutation "visual"

prepare_repo draft-mutation
run_execute
write_visual approved
/bin/chmod 0600 "$draft"
printf '\n' >>"$draft"
expect_finalize_failure draft-mutation "visual"

prepare_repo draft-nested-schema-mutation
run_execute
write_packet
/bin/chmod 0600 "$draft"
/usr/bin/ruby -rjson - "$draft" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.read(path))
document.fetch("build")["unexpected"] = true
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
write_visual approved
expect_finalize_failure draft-nested-schema-mutation "visual"

prepare_repo draft-mechanical-mutation
run_execute
write_packet
/bin/chmod 0600 "$draft"
/usr/bin/ruby -rjson - "$draft" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.read(path))
document.fetch("cases").fetch(0)["mechanicalCheck"] = "assertion:launch-succeeded"
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
write_visual approved
expect_finalize_failure draft-mechanical-mutation "visual"

prepare_repo draft-mapping-mutation
run_execute
write_packet
/bin/chmod 0600 "$draft"
/usr/bin/ruby -rjson - "$draft" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.read(path))
document.fetch("acceptanceEvidence").fetch(0)["evidence"] = ["case:iphone-en"]
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
write_visual approved
expect_finalize_failure draft-mapping-mutation "visual"

prepare_repo canonical-contract-mutation
run_execute
write_visual approved
printf '\n' >>"$contract"
expect_finalize_failure canonical-contract-mutation "visual"

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
echo "finalization iOS runner tests passed"
