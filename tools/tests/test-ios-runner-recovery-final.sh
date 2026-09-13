#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

prepare_repo kill-before-final
run_execute
assert_no_failed_attempts
write_visual approved
FAKE_PUBLICATION_KILL_TARGET=verify.json expect_finalize_failure kill-before-final "visual result is invalid"
run_finalize
[[ -f "$final" ]] || { echo "final retry failed after kill before canonical rename" >&2; exit 1; }

prepare_repo kill-after-final
run_execute
assert_no_failed_attempts
write_visual approved
if FAKE_PUBLICATION_KILL_AFTER_TARGET=verify.json run_finalize >"$scratch/kill-after-final.stdout" 2>"$scratch/kill-after-final.stderr"; then
  echo "kill-after-final fixture unexpectedly returned success" >&2; exit 1
fi
[[ -f "$final" ]] || { echo "kill after final rename did not leave canonical evidence" >&2; exit 1; }
run_finalize
[[ -f "$final" ]] || { echo "final retry did not accept exact canonical evidence" >&2; exit 1; }

prepare_repo corrupt-after-final
run_execute
assert_no_failed_attempts
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
echo "recovery-final iOS runner tests passed"
