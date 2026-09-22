#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

# Exercise the production empty array with the real Bash entrypoint. The adapter
# flags are injected only after each unchanged resource call has expanded its
# arguments, so the usual nonempty test array cannot hide a Bash 3.2 failure.
/bin/cp "$runner" "$scratch/runner-with-adapter-flags.sh"
empty_flags_log="$scratch/empty-resource-calls.jsonl"
/usr/bin/ruby --disable-gems -rshellwords - "$runner" "$empty_flags_log" <<'RUBY'
path, log = ARGV
source = File.binread(path)
selection = 'if [[ "$TRUSTED_XCRUN" != "/usr/bin/xcrun" ]]; then'
entry = "run_simulator_resource() {\n"
abort "resource test-flag selection changed" unless source.scan(selection).length == 1
abort "resource call boundary changed" unless source.scan(entry).length == 1
source.sub!(selection, "if false; then")
injection = <<~'SH'
  /usr/bin/ruby --disable-gems -rjson -e 'File.open(ARGV.shift, "a") { |file| file.puts(JSON.generate(ARGV)) }' @LOG@ "$@"
  set -- "$@" --test-mode --state-root "$attempt_root/SimulatorResourceState" --xcrun "$TRUSTED_XCRUN" --minimum-free-bytes 0
SH
source.sub!(entry, entry + injection.sub("@LOG@", Shellwords.escape(log)))
# The no-expected-state helper branch is normally reached only by legacy
# reclamation. Call that existing branch while the schema v2 allocation is live.
build_stage = "stage=\"build\"\n"
abort "build stage boundary changed" unless source.scan(build_stage).length == 1
source.sub!(build_stage, <<~'SH' + build_stage)
  capture_simulator_identities "empty-flags-before-build" "$active_case_id" || fail "empty-flags identity probe failed"
SH
File.binwrite(path, source)
RUBY

prepare_repo allocation-v2-empty-flags valid present shape 2
run_execute
[[ -f "$final" && ! -e "$draft" ]] || {
  echo "empty resource flags did not publish shape evidence" >&2; exit 1
}
(cd "$repo" && "$validator_binary" --file "$final" --expected-issue 42 \
  --expected-base "$base_sha" --expected-head "$head_sha")
/usr/bin/ruby --disable-gems -rjson - "$empty_flags_log" "$final" "$repo" <<'RUBY'
log, final, repository = ARGV
calls = File.readlines(log).map { |line| JSON.parse(line) }
abort "empty flags introduced an empty argument" if calls.any? { |args| args.any?(&:empty?) }
abort "production call supplied test flags" if calls.any? do |args|
  !(args & %w[--test-mode --state-root --xcrun --minimum-free-bytes]).empty?
end
%w[recover allocate release].each do |operation|
  abort "empty flags did not reach #{operation}" unless calls.any? { |args| args.first == operation }
end
validations = calls.select { |args| args.first == "validate" }
abort "empty flags did not reach both validation branches" unless
  validations.any? { |args| args.include?("--expected-state") } &&
  validations.any? { |args| !args.include?("--expected-state") }
evidence = JSON.parse(File.binread(final))
abort "empty flags did not complete the shape stages" unless
  evidence.fetch("executionRoute") == "xcodebuild-stage" &&
  evidence.dig("build", "status") == "passed" && evidence.dig("tests", "passed") == 1 &&
  evidence.fetch("cases").map { |entry| [entry.fetch("id"), entry.fetch("status")] } == [["iphone-ja", "passed"]]
allocations = evidence.fetch("simulatorAllocations")
abort "empty flags did not use exactly one allocation" unless allocations.length == 1
receipt = JSON.parse(File.binread(File.join(repository, allocations.first.fetch("path"))))
abort "empty flags did not clean up its allocation" unless
  receipt.fetch("status") == "released" && receipt.dig("cleanup", "deviceAbsent") == true &&
  receipt.dig("cleanup", "dataPathAbsent") == true
RUBY
assert_no_failed_attempts
/bin/cp "$scratch/runner-with-adapter-flags.sh" "$runner"

prepare_repo allocation-v2 valid present full 2
run_execute

/usr/bin/ruby -rjson - "$matrix" "$fake_log" "$(dirname "$matrix")" <<'RUBY'
matrix_path, log_path, batch_directory = ARGV
matrix = JSON.parse(File.read(matrix_path))
abort "runner allocation test did not use schema v2" unless matrix.fetch("schemaVersion") == 2
abort "schema v2 matrix retained an execution UDID" if matrix.fetch("cases").any? { |entry| entry.key?("udid") }

commands = File.readlines(log_path, chomp: true).map { |line| line.split("\t") }
simctl = commands.select { |fields| fields[0] == "xcrun" && fields[2] == "simctl" }
creates = simctl.select { |fields| fields[3] == "create" }
deletes = simctl.select { |fields| fields[3] == "delete" }
erases = simctl.select { |fields| fields[3] == "erase" }
abort "schema v2 runner did not create exactly four sequential devices" unless creates.length == 4
abort "schema v2 runner did not delete exactly four devices" unless deletes.length == 4
abort "schema v2 runner used legacy erase" unless erases.empty?
expected_cases = %w[iphone-en iphone-ja ipad-en ipad-ja]
abort "allocation order changed" unless creates.map { |fields| expected_cases.find { |id| fields[4].include?("-#{id}-") } } == expected_cases
expected_udids = (1..4).map { |slot| format("00000000-0000-0000-0000-%012d", slot) }
abort "delete order changed" unless deletes.map { |fields| fields[4] } == expected_udids
expected_udids.each_cons(2) do |current, following|
  delete_index = commands.index { |fields| fields[0] == "xcrun" && fields[2] == "simctl" && fields[3] == "delete" && fields[4] == current }
  create_index = commands.index { |fields| fields[0] == "xcrun" && fields[2] == "simctl" && fields[3] == "create" && fields[4].include?(following.end_with?("2") ? "-iphone-ja-" : following.end_with?("3") ? "-ipad-en-" : "-ipad-ja-") }
  abort "next Simulator was created before deletion confirmation" unless delete_index && create_index && delete_index < create_index
end

records = Dir.glob(File.join(batch_directory, "allocation-*.json")).map { |path| JSON.parse(File.read(path)) }
abort "released allocation evidence is incomplete" unless records.length == 4
abort "allocation evidence case order/set is wrong" unless records.map { |record| record.fetch("caseId") }.sort == expected_cases.sort
abort "allocation identity was reused" unless records.map { |record| record.fetch("allocationId") }.uniq.length == 4
abort "allocation evidence did not prove deletion" unless records.all? do |record|
  record.fetch("schemaVersion") == 1 && record.fetch("status") == "released" &&
    record.dig("cleanup", "status") == "passed" && record.dig("cleanup", "deviceAbsent") == true &&
    record.dig("cleanup", "dataPathAbsent") == true &&
    record.dig("freeSpace", "beforeCreateBytes").is_a?(Integer) &&
    record.dig("freeSpace", "afterDeleteBytes").is_a?(Integer)
end
abort "one runner used multiple session identities" unless records.map { |record| record.fetch("sessionId") }.uniq.length == 1
RUBY

[[ -f "$draft" && ! -e "$final" ]] || { echo "schema v2 runner did not preserve draft evidence after deletion" >&2; exit 1; }
write_visual approved
run_finalize
(cd "$repo" && "$validator_binary" --file "$final" --expected-issue 42 --expected-base "$base_sha" --expected-head "$head_sha")
[[ -f "$final" ]] || { echo "schema v2 evidence did not finalize after Simulator deletion" >&2; exit 1; }
assert_no_failed_attempts

allocation_path="$(jq -r '.simulatorAllocations[0].path' "$final")"
ruby -rjson -rdigest - "$final" "$repo" <<'RUBY'
final_path, repository = ARGV
evidence = JSON.parse(File.read(final_path))
allocations = evidence.fetch("simulatorAllocations")
abort "final evidence did not bind every allocation" unless allocations.length == 4
abort "final allocation case order changed" unless allocations.map { |entry| entry.fetch("caseId") } == %w[iphone-en iphone-ja ipad-en ipad-ja]
allocations.each do |entry|
  path = File.join(repository, entry.fetch("path"))
  abort "final allocation artifact is missing" unless File.file?(path)
  digest = "sha256:#{Digest::SHA256.file(path).hexdigest}"
  abort "final allocation digest changed" unless entry.fetch("digest") == digest
end
RUBY
ruby - "$repo/$allocation_path" <<'RUBY'
path = ARGV.fetch(0)
File.chmod(0o600, path)
File.open(path, "ab") { |file| file.write("\n") }
RUBY
if (cd "$repo" && "$validator_binary" --file "$final" --expected-issue 42 \
    --expected-base "$base_sha" --expected-head "$head_sha") >"$scratch/allocation-tamper.out" 2>"$scratch/allocation-tamper.err"; then
  echo "final validator accepted a changed allocation receipt" >&2
  exit 1
fi
grep -Fq 'digest does not match exact file bytes' "$scratch/allocation-tamper.err"

prepare_repo allocation-v2-failure valid present full 2
FAKE_RESOURCE_FAILURE=install expect_execute_failure allocation-v2-failure "case iphone-en failed"
[[ ! -e "$draft" ]] || { echo "failed schema v2 run published successful evidence" >&2; exit 1; }
if /usr/bin/find "$adapter_state" -maxdepth 1 -type f -name 'allocated-*' -print -quit | /usr/bin/grep -q .; then
  echo "failed schema v2 run retained its Simulator" >&2; exit 1
fi
/usr/bin/ruby -rjson - "$fake_log" "$(dirname "$matrix")" <<'RUBY'
log_path, batch_directory = ARGV
commands = File.readlines(log_path, chomp: true).map { |line| line.split("\t") }
creates = commands.count { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl create] }
deletes = commands.count { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl delete] }
abort "failed schema v2 case did not delete its sole allocation" unless creates == 1 && deletes == 1
receipts = Dir.glob(File.join(batch_directory, "allocation-*.json")).map { |path| JSON.parse(File.read(path)) }
abort "failed schema v2 case did not publish one cleanup receipt" unless receipts.length == 1
abort "failed schema v2 case was recorded as complete" unless receipts[0].dig("cleanup", "reason") == "case-failed"
RUBY
assert_no_failed_attempts

prepare_repo allocation-v2-term valid present full 2
FAKE_CASE_MODE=term-blocked-probe run_execute >"$scratch/allocation-term.stdout" 2>"$scratch/allocation-term.stderr" &
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
  echo "schema v2 TERM test did not reach its bounded Simulator probe" >&2
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
  echo "schema v2 TERM cleanup did not finish" >&2
  exit 1
fi
if wait "$term_job_pid"; then
  echo "TERM-interrupted schema v2 runner unexpectedly succeeded" >&2
  exit 1
fi
if /usr/bin/find "$adapter_state" -maxdepth 1 -type f -name 'allocated-*' -print -quit | /usr/bin/grep -q .; then
  echo "TERM-interrupted schema v2 run retained its Simulator" >&2; exit 1
fi
/usr/bin/ruby - "$fake_log" <<'RUBY'
commands = File.readlines(ARGV.fetch(0), chomp: true).map { |line| line.split("\t") }
probe = commands.rindex do |fields|
  fields[0] == "xcrun" && fields[2..3] == %w[simctl spawn] && fields[5] == "/bin/kill"
end
abort "schema v2 TERM probe was not recorded" unless probe
mutations = commands.drop(probe + 1).select do |fields|
  fields[0] == "xcrun" && fields[2] == "simctl" && %w[terminate shutdown erase delete].include?(fields[3])
end
owned = "00000000-0000-0000-0000-000000000001"
abort "schema v2 TERM cleanup touched another device" unless mutations.all? { |fields| fields[4] == owned }
abort "schema v2 TERM cleanup did not shutdown and delete exactly once" unless
  mutations.count { |fields| fields[3] == "shutdown" } == 1 &&
  mutations.count { |fields| fields[3] == "delete" } == 1 &&
  mutations.none? { |fields| fields[3] == "erase" }
RUBY
[[ ! -e "$draft" ]] || { echo "TERM-interrupted schema v2 run published a draft" >&2; exit 1; }
assert_no_failed_attempts

test_stubborn_probe 2 allocation-v2-timeout
[[ ! -e "$draft" && ! -e "$final" ]] || { echo "timed-out schema v2 run published successful evidence" >&2; exit 1; }
if /usr/bin/find "$adapter_state" -maxdepth 1 -type f -name 'allocated-*' -print -quit | /usr/bin/grep -q .; then
  echo "timed-out schema v2 run retained its Simulator" >&2
  exit 1
fi
/usr/bin/ruby -rjson - "$fake_log" "$(dirname "$matrix")" <<'RUBY'
log_path, batch_directory = ARGV
commands = File.readlines(log_path, chomp: true).map { |line| line.split("\t") }
creates = commands.count { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl create] }
deletes = commands.count { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl delete] }
erases = commands.count { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl erase] }
abort "timed-out schema v2 case did not delete its sole allocation" unless creates == 1 && deletes == 1
abort "timed-out schema v2 case used legacy erase" unless erases.zero?
receipts = Dir.glob(File.join(batch_directory, "allocation-*.json")).map { |path| JSON.parse(File.read(path)) }
abort "timed-out schema v2 case did not publish one cleanup receipt" unless receipts.length == 1
receipt = receipts.fetch(0)
abort "timed-out schema v2 cleanup was not bound to the failed case" unless
  receipt.fetch("caseId") == "iphone-en" && receipt.dig("cleanup", "reason") == "case-failed" &&
    receipt.dig("cleanup", "status") == "passed" && receipt.dig("cleanup", "deviceAbsent") == true &&
    receipt.dig("cleanup", "dataPathAbsent") == true
RUBY
assert_no_failed_attempts

echo "schema v2 sequential Simulator allocation runner test passed"
