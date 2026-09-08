#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

startup_stdout="$scratch/startup.stdout"
startup_stderr="$scratch/startup.stderr"
if (cd "$scratch" && CDPATH="$scratch" test-source/tools/verify-ios-issue.sh >"$startup_stdout" 2>"$startup_stderr"); then
  echo "startup unexpectedly accepted missing arguments" >&2; exit 1
fi
[[ ! -s "$startup_stdout" ]] || { echo "hostile CDPATH contaminated startup resolution" >&2; exit 1; }
grep -Fq 'usage:' "$startup_stderr" || { echo "relative startup did not reach the trusted runner" >&2; exit 1; }
if (cd "$test_source/tools" && /bin/bash -p verify-ios-issue.sh >"$startup_stdout" 2>"$startup_stderr"); then
  echo "pathless startup unexpectedly succeeded" >&2; exit 1
fi
grep -Fq 'unsafe runner invocation path' "$startup_stderr" || { echo "pathless startup was not rejected" >&2; exit 1; }
control_runner="$test_source/tools/verify-ios-issue"$'\n'".sh"
/bin/cp "$runner" "$control_runner"
chmod +x "$control_runner"
if "$control_runner" >"$startup_stdout" 2>"$startup_stderr"; then
  echo "control-character startup unexpectedly succeeded" >&2; exit 1
fi
grep -Fq 'unsafe runner invocation path' "$startup_stderr" || { echo "control-character startup was not rejected" >&2; exit 1; }

# The guard must not depend on the locale's collation order. tools/lib/xcode.sh forces
# en_US.UTF-8 for scrubbed execution, so a range-based test would pass here while the
# real execution path stayed unguarded.
for guard_locale in C en_US.UTF-8 ja_JP.UTF-8; do
  if LC_ALL="$guard_locale" LANG="$guard_locale" "$control_runner" >"$startup_stdout" 2>"$startup_stderr"; then
    echo "control-character startup unexpectedly succeeded under $guard_locale" >&2; exit 1
  fi
  grep -Fq 'unsafe runner invocation path' "$startup_stderr" || {
    echo "control-character startup was not rejected under $guard_locale" >&2; exit 1
  }
done
if LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 "$runner" >"$startup_stdout" 2>"$startup_stderr"; then
  echo "argument-less startup unexpectedly succeeded" >&2; exit 1
fi
grep -Fq 'usage:' "$startup_stderr" || { echo "a clean path must still reach the runner" >&2; exit 1; }

swift_driver_probe="$scratch/swift-driver-probe.swift"
printf '%s\n' 'print("swift-driver-ok")' >"$swift_driver_probe"
if ! swift_driver_output="$(
  source "$test_source/tools/lib/xcode.sh"
  select_initial_xcode_environment
  run_xcode_swift "$swift_driver_probe"
)"; then
  echo "Xcode Swift dispatch did not preserve the validated driver invocation name" >&2
  exit 1
fi
[[ "$swift_driver_output" == swift-driver-ok ]] || {
  echo "Xcode Swift driver probe returned unexpected output" >&2
  exit 1
}

prepare_repo term-during-blocked-probe
FAKE_CASE_MODE=term-blocked-probe run_execute >"$scratch/term-blocked.stdout" 2>"$scratch/term-blocked.stderr" &
term_job_pid=$!
term_runner_pid=""
for _ in $(/usr/bin/jot 400); do
  term_runner_pid="$(/bin/cat "$adapter_state/term-blocked-runner-pid" 2>/dev/null || true)"
  [[ "$term_runner_pid" =~ ^[1-9][0-9]*$ ]] && break
  /bin/sleep 0.05
done
if [[ ! "$term_runner_pid" =~ ^[1-9][0-9]*$ ]]; then
  /bin/kill -KILL "$term_job_pid" >/dev/null 2>&1 || true
  wait "$term_job_pid" 2>/dev/null || true
  echo "TERM cleanup test did not reach its blocked Simulator probe" >&2
  exit 1
fi
/bin/kill -TERM "$term_runner_pid"
term_finished=0
for _ in $(/usr/bin/jot 400); do
  if ! /bin/kill -0 "$term_job_pid" >/dev/null 2>&1; then term_finished=1; break; fi
  /bin/sleep 0.05
done
if [[ "$term_finished" != 1 ]]; then
  /bin/kill -KILL "$term_job_pid" >/dev/null 2>&1 || true
  wait "$term_job_pid" 2>/dev/null || true
  echo "TERM cleanup did not finish after stopping its blocked probe" >&2
  exit 1
fi
if wait "$term_job_pid"; then
  echo "TERM-interrupted runner unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -e "$adapter_state/term-cleanup-before-probe-stop" ]] || {
  echo "TERM cleanup mutated the active Simulator before its probe group stopped" >&2
  exit 1
}
term_probe_pgid="$(/bin/cat "$adapter_state/term-blocked-probe-pgid" 2>/dev/null || true)"
if [[ "$term_probe_pgid" =~ ^[1-9][0-9]*$ ]] && /bin/kill -0 -- "-$term_probe_pgid" >/dev/null 2>&1; then
  /bin/kill -KILL -- "-$term_probe_pgid" >/dev/null 2>&1 || true
  echo "TERM cleanup left the blocked probe process group alive" >&2
  exit 1
fi
/usr/bin/ruby - "$fake_log" <<'RUBY'
lines = File.readlines(ARGV.fetch(0), chomp: true).map { |line| line.split("\t") }
probe = lines.rindex do |fields|
  fields[0] == "xcrun" && fields[2] == "simctl" && fields[3] == "spawn" &&
    fields[4] == "00000000-0000-0000-0000-000000000001" && fields[5] == "/bin/kill"
end
abort "TERM cleanup did not log its blocked probe" unless probe
mutations = lines.drop(probe + 1).select do |fields|
  fields[0] == "xcrun" && fields[2] == "simctl" && %w[terminate shutdown erase delete].include?(fields[3])
end
active = "00000000-0000-0000-0000-000000000001"
abort "TERM cleanup touched a Simulator outside the active owned case" unless mutations.all? { |fields| fields[4] == active }
abort "TERM cleanup did not reclaim exactly the active owned Simulator" unless mutations.count { |fields| fields[3] == "shutdown" } == 1 && mutations.count { |fields| fields[3] == "erase" } == 1
abort "TERM cleanup deleted an owned Simulator" if mutations.any? { |fields| fields[3] == "delete" }
RUBY
[[ ! -e "$draft" ]] || { echo "TERM-interrupted runner published a draft" >&2; exit 1; }
assert_no_failed_attempts


assert_runner_publication_cleanup
echo "startup iOS runner tests passed"
