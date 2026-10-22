#!/usr/bin/env bash
# repository-test-execution: exclusive
# #411: the canonical repository runner runs independent tests in several workers, runs a test declared
# exclusive alone, keeps each test in its own process group and bound, reaps only that group on a timeout or
# an interruption, reports results as one-by-one runs would, and refuses an invalid worker count before start.
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" jq git ruby perl

source_repo=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-repository-parallel.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
repo="$scratch/repo"
trap 'rm -rf -- "$scratch"' EXIT
export IOS_TEMPLATE_REPOSITORY_TEST_OUTPUT_ROOT="$scratch/kept-output"
unset IOS_TEMPLATE_REPOSITORY_TEST_JOBS

git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
mkdir -p "$repo/tools/lib" "$repo/tools/tests" "$repo/.artifacts/issues"
cp "$source_repo/tools/run-repository-tests.sh" "$repo/tools/"
for library in run-repository-tests review-artifacts review-contract evidence-applicability review-route \
  repository-test-plan delivery-profile verification-scope delivery-stage review-sealing descriptor-files \
  issue-contract issue-contract-revision ownership prepare-review-packet; do
  cp "$source_repo/tools/lib/$library.rb" "$repo/tools/lib/"
done
chmod +x "$repo/tools/run-repository-tests.sh"
printf '%s\n' /.artifacts >"$repo/.gitignore"
printf '%s\n' base >"$repo/README.md"
git -C "$repo" add .gitignore README.md
git -C "$repo" commit -q -m base
base_sha=$(git -C "$repo" rev-parse HEAD)

# Each fixture test records when it started and ended under PARALLEL_LOG, leaves a child with redirected output
# when named in LEAK_TESTS, fails when named in FAIL_TESTS,
# and when named in HANG_TESTS leaves a background child in its process group and waits for it; a test named in
# STUBBORN_TESTS also leaves a child that ignores TERM.
for name in alpha beta delta gamma; do
  {
    printf '%s\n' '#!/usr/bin/env bash'
    [[ "$name" != delta ]] || printf '%s\n' '# repository-test-execution: exclusive'
    printf '%s\n' 'set -euo pipefail' "name=$name" 'log=${PARALLEL_LOG:?}'
    cat <<'EOF'
[[ -z ${IOS_TEMPLATE_REPOSITORY_TEST_JOBS+x} ]] || { echo 'the worker count reached a test' >&2; exit 3; }
perl -MTime::HiRes=time -e 'printf "%.6f\n", time' >"$log/$name.start"
case " ${LEAK_TESTS:-} " in
  *" $name "*) sleep 120 >/dev/null 2>&1 & printf '%s\n' "$!" >"$log/$name.leak" ;;
esac
case " ${FAIL_TESTS:-} " in *" $name "*) exit 5 ;; esac
case " ${STUBBORN_TESTS:-} " in
  *" $name "*) ( trap '' TERM; exec sleep 120 ) & printf '%s\n' "$!" >"$log/$name.stubborn" ;;
esac
case " ${HANG_TESTS:-} " in
  *" $name "*) sleep 120 & printf '%s\n' "$!" >"$log/$name.child"; wait ;;
esac
sleep "${SLEEP_SECONDS:-2}"
perl -MTime::HiRes=time -e 'printf "%.6f\n", time' >"$log/$name.end"
EOF
  } >"$repo/tools/tests/test-$name.sh"
  chmod +x "$repo/tools/tests/test-$name.sh"
done
git -C "$repo" add tools
git -C "$repo" commit -q -m head
head_sha=$(git -C "$repo" rev-parse HEAD)

prepare_issue() {
  local issue=$1
  mkdir -p "$repo/.artifacts/issues/$issue/$head_sha"
  cat >"$repo/.artifacts/issues/$issue/issue-contract.json" <<JSON
{"schemaVersion":1,"issue":$issue,"repository":"example/repo","goal":"Parallel","specAnchors":["specs/test.md#parallel"],"acceptanceCriteria":[{"id":"AC-1","text":"First tests pass"},{"id":"AC-2","text":"Second tests pass"}],"dependencies":[],"externalOperations":[],"externalOperationDetailsDigest":"sha256:$(printf '0%.0s' {1..64})","fetchedAt":"2026-08-25T00:00:00Z","deliveryStage":{"name":"harden","timeBudgetMinutes":60,"reason":"Workflow-only fixture."},"deliveryProfile":{"name":"strict","reason":"Canonical workflow evidence."}}
JSON
  ruby -I "$repo/tools/lib" -rjson -rissue-contract - "$repo/.artifacts/issues/$issue/issue-contract.json" <<'RUBY'
path = ARGV.fetch(0)
File.binwrite(path, IOSTemplate::IssueContract.canonical_json(JSON.parse(File.binread(path))))
RUBY
  mkdir -p "$scratch/log-$issue"
}

# run_suite ISSUE FIRST_TESTS SECOND_TESTS [VARIABLE=VALUE...]: runs the canonical runner for ISSUE with the
# given comma-separated test names mapped to AC-1 and AC-2, writing its streams under the scratch area.
run_suite() {
  local issue=$1 first=$2 second=$3
  shift 3
  local first_paths second_paths
  first_paths=$(printf 'tools/tests/test-%s.sh,' ${first//,/ })
  second_paths=$(printf 'tools/tests/test-%s.sh,' ${second//,/ })
  (cd "$repo" && env PARALLEL_LOG="$scratch/log-$issue" "$@" tools/run-repository-tests.sh --issue "$issue" \
    --expected-base "$base_sha" --map "AC-1=${first_paths%,}" --map "AC-2=${second_paths%,}") \
    >"$scratch/$issue.out" 2>"$scratch/$issue.err"
}

# check_intervals ISSUE EXPRESSION: evaluates a Ruby expression over the recorded start/end times.
check_intervals() {
  ruby - "$scratch/log-$1" "$2" <<'RUBY'
log, expression = ARGV
times = Hash.new { |hash, key| hash[key] = {} }
Dir.glob(File.join(log, "*.{start,end}")).each do |path|
  name, kind = File.basename(path).split(".")
  times[name][kind] = Float(File.read(path))
end
overlap = ->(a, b) { times[a]["start"] < times[b]["end"] && times[b]["start"] < times[a]["end"] }
abort "interval check failed: #{expression} #{times.inspect}" unless eval(expression)
RUBY
}

evidence_paths() {
  jq -c '[.tests[].path]' "$repo/.artifacts/issues/$1/$head_sha/repository-tests.json"
}

# Several workers: the two non-exclusive tests overlap, the exclusive test runs alone, and the evidence
# lists every test once in plan order.
prepare_issue 101
run_suite 101 alpha,beta delta,gamma IOS_TEMPLATE_REPOSITORY_TEST_JOBS=3
[[ $(evidence_paths 101) == '["tools/tests/test-alpha.sh","tools/tests/test-beta.sh","tools/tests/test-delta.sh","tools/tests/test-gamma.sh"]' ]] ||
  { echo 'parallel evidence is not in plan order' >&2; exit 1; }
jq -e '[.tests[].status] == ["passed","passed","passed","passed"]' "$repo/.artifacts/issues/101/$head_sha/repository-tests.json" >/dev/null
check_intervals 101 'overlap.("alpha", "beta") && %w[alpha beta gamma].none? { |name| overlap.("delta", name) }'
grep -Fq '"unexecutedTests":[]' "$scratch/101.err"

# Independent tests all run at once with enough workers.
prepare_issue 102
started=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
run_suite 102 alpha,beta gamma IOS_TEMPLATE_REPOSITORY_TEST_JOBS=3 SLEEP_SECONDS=3
finished=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
check_intervals 102 'overlap.("alpha", "beta") && overlap.("beta", "gamma") && overlap.("alpha", "gamma")'
ruby -e 'exit(Float(ARGV[1]) - Float(ARGV[0]) < 9 ? 0 : 1)' "$started" "$finished" ||
  { echo 'three three-second tests did not run together' >&2; exit 1; }

# One worker: the same sequential run as before, in plan order with no overlap.
prepare_issue 103
run_suite 103 alpha,beta delta,gamma IOS_TEMPLATE_REPOSITORY_TEST_JOBS=1 SLEEP_SECONDS=1
[[ $(evidence_paths 103) == '["tools/tests/test-alpha.sh","tools/tests/test-beta.sh","tools/tests/test-delta.sh","tools/tests/test-gamma.sh"]' ]]
check_intervals 103 '%w[alpha beta delta gamma].each_cons(2).all? { |a, b| times[a]["end"] <= times[b]["start"] }'

# The default worker count runs tests together without the variable.
prepare_issue 104
run_suite 104 alpha beta
check_intervals 104 'overlap.("alpha", "beta")'

# An invalid worker count stops before any test, evidence, or failure record.
issue=105
for value in 0 9 x '' 01 -1; do
  prepare_issue "$issue"
  if run_suite "$issue" alpha beta IOS_TEMPLATE_REPOSITORY_TEST_JOBS="$value"; then
    echo "worker count '$value' was accepted" >&2
    exit 1
  fi
  grep -Fq 'IOS_TEMPLATE_REPOSITORY_TEST_JOBS must be an integer from 1 to 8' "$scratch/$issue.err"
  [[ -z $(ls -A "$scratch/log-$issue") && -z $(ls -A "$repo/.artifacts/issues/$issue/$head_sha") ]] ||
    { echo "worker count '$value' started tests or wrote evidence" >&2; exit 1; }
  issue=$((issue + 1))
done

# A failure stops new tests; a running test still finishes, the tests that never started are recorded as
# unexecuted, and the failure is the first one in plan order. A child that the failed test left running with its
# output redirected is stopped, and an unrelated process survives.
prepare_issue 120
sleep 120 &
unrelated=$!
if run_suite 120 alpha,beta delta,gamma IOS_TEMPLATE_REPOSITORY_TEST_JOBS=2 FAIL_TESTS=alpha LEAK_TESTS=alpha; then
  echo 'a failed parallel test was accepted' >&2
  exit 1
fi
grep -Fq 'repository test failed: tools/tests/test-alpha.sh' "$scratch/120.err"
leak=$(cat "$scratch/log-120/alpha.leak")
! kill -0 "$leak" 2>/dev/null || { kill "$leak"; echo 'a child left by the failed test was not stopped' >&2; exit 1; }
kill -0 "$unrelated" 2>/dev/null || { echo 'the failure cleanup stopped an unrelated process' >&2; exit 1; }
kill "$unrelated"
wait "$unrelated" 2>/dev/null || true
[[ -f "$scratch/log-120/beta.end" && ! -e "$scratch/log-120/delta.start" && ! -e "$scratch/log-120/gamma.start" ]] ||
  { echo 'a failure changed a running test or started another one' >&2; exit 1; }
jq -e '.failedTest == "tools/tests/test-alpha.sh" and .timedOut == false and
  .unexecutedTestPaths == ["tools/tests/test-delta.sh", "tools/tests/test-gamma.sh"]' \
  "$repo/.artifacts/issues/120/$head_sha/repository-test-failure-attempt-1.json" >/dev/null
[[ ! -e "$repo/.artifacts/issues/120/$head_sha/repository-tests.json" ]]

# A timeout reaps only the timed-out test's process group, including a member that ignores TERM and keeps the
# output open after the leader exits, within a bounded time; the other running test passes unchanged and an
# unrelated process survives.
prepare_issue 121
sleep 120 &
unrelated=$!
timeout_started=$SECONDS
if run_suite 121 alpha,beta delta,gamma IOS_TEMPLATE_REPOSITORY_TEST_JOBS=2 HANG_TESTS=alpha STUBBORN_TESTS=alpha \
  SLEEP_SECONDS=1 IOS_TEMPLATE_REPOSITORY_TEST_TIMEOUT_SECONDS=4; then
  echo 'a timed-out parallel test was accepted' >&2
  exit 1
fi
(( SECONDS - timeout_started < 40 )) || { echo 'a timed-out test with a TERM-ignoring member was not bounded' >&2; exit 1; }
grep -Fq 'repository test timed out: tools/tests/test-alpha.sh' "$scratch/121.err"
child=$(cat "$scratch/log-121/alpha.child")
! kill -0 "$child" 2>/dev/null || { kill "$child"; echo 'the timed-out process group was not reaped' >&2; exit 1; }
stubborn=$(cat "$scratch/log-121/alpha.stubborn")
! kill -0 "$stubborn" 2>/dev/null || { kill -KILL "$stubborn"; echo 'a TERM-ignoring member survived the timeout' >&2; exit 1; }
kill -0 "$unrelated" 2>/dev/null || { echo 'the timeout stopped an unrelated process' >&2; exit 1; }
kill "$unrelated"
wait "$unrelated" 2>/dev/null || true
[[ -f "$scratch/log-121/beta.end" && ! -e "$scratch/log-121/delta.start" ]] ||
  { echo 'a timeout changed the other running test or started another one' >&2; exit 1; }
jq -e '.failedTest == "tools/tests/test-alpha.sh" and .timedOut == true and
  .unexecutedTestPaths == ["tools/tests/test-delta.sh", "tools/tests/test-gamma.sh"]' \
  "$repo/.artifacts/issues/121/$head_sha/repository-test-failure-attempt-1.json" >/dev/null

# An interruption reaps every running test's process group, killing members that ignore TERM, leaves an
# unrelated process alone, and removes the detached worktrees.
prepare_issue 122
sleep 120 &
unrelated=$!
(cd "$repo" && exec env PARALLEL_LOG="$scratch/log-122" IOS_TEMPLATE_REPOSITORY_TEST_JOBS=2 HANG_TESTS='alpha beta' STUBBORN_TESTS=alpha \
  tools/run-repository-tests.sh --issue 122 --expected-base "$base_sha" \
  --map AC-1=tools/tests/test-alpha.sh --map AC-2=tools/tests/test-beta.sh) >"$scratch/122.out" 2>"$scratch/122.err" &
runner=$!
for _ in $(seq 1 100); do
  [[ -s "$scratch/log-122/alpha.child" && -s "$scratch/log-122/beta.child" && -s "$scratch/log-122/alpha.stubborn" ]] && break
  sleep 0.2
done
[[ -s "$scratch/log-122/alpha.child" && -s "$scratch/log-122/beta.child" ]] || { kill "$runner"; echo 'interrupted tests did not start' >&2; exit 1; }
kill -TERM "$runner"
for _ in $(seq 1 150); do kill -0 "$runner" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$runner" 2>/dev/null; then kill -KILL "$runner"; echo 'the interrupted runner did not stop' >&2; exit 1; fi
{ wait "$runner"; } 2>/dev/null && { echo 'an interrupted runner reported success' >&2; exit 1; } || true
stubborn=$(cat "$scratch/log-122/alpha.stubborn")
! kill -0 "$stubborn" 2>/dev/null || { kill -KILL "$stubborn"; echo 'a TERM-ignoring test process survived the interruption' >&2; exit 1; }
kill -0 "$unrelated" 2>/dev/null || { echo 'the interruption stopped an unrelated process' >&2; exit 1; }
kill "$unrelated"
wait "$unrelated" 2>/dev/null || true
for name in alpha beta; do
  child=$(cat "$scratch/log-122/$name.child")
  ! kill -0 "$child" 2>/dev/null || { kill "$child"; echo "the interrupted $name process group was not reaped" >&2; exit 1; }
done
[[ $(git -C "$repo" worktree list --porcelain | grep -c '^worktree ') == 1 ]] ||
  { echo 'an interrupted runner left detached worktrees' >&2; exit 1; }
[[ ! -e "$repo/.artifacts/issues/122/$head_sha/repository-tests.json" ]]

# Deterministic interruption windows, driven inside the runner's own process: an interruption between a worker
# reserving a test and registering its process group, and an interruption while the workers are being created.
# Every group that started is gone afterwards and the detached worktrees are removed.
cat >"$scratch/interrupt-windows.rb" <<'RUBY'
require "run-repository-tests"
repo, head, log, mode = ARGV
mod = IOSTemplate::RepositoryTests
alive = lambda do |pid|
  Process.kill(0, -pid)
  true
rescue Errno::ESRCH
  false
end
started_groups = Queue.new
original = mod.method(:capture3_bounded)
case mode
when "reservation"
  reserved = Queue.new
  release = Queue.new
  mod.define_singleton_method(:capture3_bounded) do |*arguments, on_start: nil, **options|
    reserved << true
    release.pop
    original.call(*arguments, **options, on_start: lambda { |pid| started_groups << pid; on_start&.call(pid) })
  end
  main = Thread.current
  Thread.new do
    reserved.pop
    main.raise(Interrupt)
    # Spawn only after the runner's grace period, so that only the worker's own check can stop the group.
    sleep 7
    release << true
  end
  tests = ["tools/tests/test-alpha.sh"]
when "creation"
  mod.define_singleton_method(:capture3_bounded) do |*arguments, on_start: nil, **options|
    original.call(*arguments, **options, on_start: lambda { |pid| started_groups << pid; on_start&.call(pid) })
  end
  # The runner resolves Thread inside its module first; the second worker's creation on the main thread is
  # interrupted once the first worker's test has started its TERM-ignoring member.
  creation_log = log
  mod.const_set(:Thread, Class.new(::Thread) do
    @main_calls = 0
    define_singleton_method(:new) do |*arguments, &block|
      if ::Thread.current == ::Thread.main
        @main_calls += 1
        if @main_calls == 2
          400.times { break if File.size?(File.join(creation_log, "alpha.stubborn")); sleep 0.05 }
          abort "the first worker did not start its test" unless File.size?(File.join(creation_log, "alpha.stubborn"))
          raise Interrupt
        end
      end
      super(*arguments, &block)
    end
  end)
  tests = ["tools/tests/test-alpha.sh", "tools/tests/test-beta.sh"]
end
begin
  mod.execute_in_detached_worktree(repo, head, tests, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120,
    child_timeout_seconds: 60, execution_scope: "legacy-head")
  abort "#{mode}: the run was not interrupted"
rescue Interrupt
  nil
end
groups = []
groups << started_groups.pop until started_groups.empty?
abort "#{mode}: no test process group started" if groups.empty?
abort "#{mode}: a test process group survived the interruption" if groups.any? { |pid| alive.call(pid) }
puts "#{mode}: #{groups.length} group(s) reaped"
RUBY
for mode in reservation creation; do
  mkdir -p "$scratch/log-$mode"
  (cd "$repo" && env PARALLEL_LOG="$scratch/log-$mode" IOS_TEMPLATE_REPOSITORY_TEST_JOBS=2 HANG_TESTS='alpha beta' \
    STUBBORN_TESTS=alpha ruby -I "$repo/tools/lib" "$scratch/interrupt-windows.rb" "$repo" "$head_sha" \
    "$scratch/log-$mode" "$mode") >"$scratch/$mode.out" 2>"$scratch/$mode.err" ||
    { cat "$scratch/$mode.err" >&2; echo "the $mode interruption window was not handled" >&2; exit 1; }
  grep -Fq "$mode: " "$scratch/$mode.out"
  if [[ -s "$scratch/log-$mode/alpha.stubborn" ]]; then
    stubborn=$(cat "$scratch/log-$mode/alpha.stubborn")
    ! kill -0 "$stubborn" 2>/dev/null || { kill -KILL "$stubborn"; echo "a TERM-ignoring member survived the $mode interruption" >&2; exit 1; }
  fi
  [[ $(git -C "$repo" worktree list --porcelain | grep -c '^worktree ') == 1 ]] ||
    { echo "the $mode interruption left detached worktrees" >&2; exit 1; }
done
[[ -s "$scratch/log-creation/alpha.stubborn" ]] || { echo 'the creation window did not start a TERM-ignoring member' >&2; exit 1; }

echo 'PASS: repository tests run in parallel workers, exclusive tests alone, with per-test process groups, bounds, and plan-order results'
