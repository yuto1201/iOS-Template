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


assert_runner_publication_cleanup
echo "finalization iOS runner tests passed"
