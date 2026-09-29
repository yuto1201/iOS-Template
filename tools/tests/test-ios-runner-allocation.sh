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
abort "empty flags did not return its dedicated lease" unless
  receipt.fetch("schemaVersion") == 2 && receipt.fetch("kind") == "dedicated-lease" &&
  receipt.fetch("status") == "released" && receipt.dig("preparation", "erased") == true &&
  receipt.dig("cleanup", "deviceState") == "Shutdown"
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
abort "schema v2 runner created a Simulator" unless creates.empty?
abort "schema v2 runner deleted a Simulator" unless deletes.empty?
iphone = "00000000-0000-0000-0000-000000000001"
ipad = "00000000-0000-0000-0000-000000000003"
abort "schema v2 runner did not erase the dedicated device before each case" unless erases.map { |fields| fields[4] } == [iphone, iphone, ipad, ipad]
erase_indexes = commands.each_index.select { |index| commands[index][0] == "xcrun" && commands[index][2..3] == %w[simctl erase] }
erase_indexes.each_cons(2) do |previous, following|
  device = commands[following][4]
  next unless commands[previous][4] == device
  shutdown = commands[previous...following].any? { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl shutdown] && fields[4] == device }
  abort "the next case erased the dedicated device before the previous case shut it down" unless shutdown
end
expected_cases = %w[iphone-en iphone-ja ipad-en ipad-ja]

records = Dir.glob(File.join(batch_directory, "allocation-*.json")).map { |path| JSON.parse(File.read(path)) }
abort "released lease evidence is incomplete" unless records.length == 4
abort "lease evidence case order/set is wrong" unless records.map { |record| record.fetch("caseId") }.sort == expected_cases.sort
abort "lease identity was reused" unless records.map { |record| record.fetch("allocationId") }.uniq.length == 4
abort "lease evidence did not prove erase and shutdown" unless records.all? do |record|
  record.fetch("schemaVersion") == 2 && record.fetch("kind") == "dedicated-lease" && record.fetch("status") == "released" &&
    record.dig("preparation", "status") == "passed" && record.dig("preparation", "erased") == true &&
    record.dig("cleanup", "status") == "passed" && record.dig("cleanup", "deviceState") == "Shutdown" &&
    record.dig("freeSpace", "beforeLeaseBytes").is_a?(Integer) &&
    record.dig("freeSpace", "afterReleaseBytes").is_a?(Integer)
end
abort "leases used the wrong dedicated device" unless records.all? do |record|
  record.fetch("udid") == (record.fetch("caseId").start_with?("iphone-") ? iphone : ipad) &&
    record.fetch("deviceName") == (record.fetch("caseId").start_with?("iphone-") ? "Fixture iPhone" : "Fixture iPad")
end
abort "one runner used multiple session identities" unless records.map { |record| record.fetch("sessionId") }.uniq.length == 1
RUBY

[[ -f "$draft" && ! -e "$final" ]] || { echo "schema v2 runner did not preserve draft evidence after the leases" >&2; exit 1; }
write_visual approved
run_finalize
(cd "$repo" && "$validator_binary" --file "$final" --expected-issue 42 --expected-base "$base_sha" --expected-head "$head_sha")
[[ -f "$final" ]] || { echo "schema v2 evidence did not finalize after the leases were returned" >&2; exit 1; }
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
# The validator checks dedicated-lease semantics, not only digests: a receipt that names another
# device or does not prove the shutdown is rejected even when the evidence digest is updated to match.
expect_rejected_receipt_edit() {
  local label="$1" expected="$2" edit="$3" final_mode receipt_mode
  final_mode="$(/usr/bin/stat -f '%Lp' "$final")"
  receipt_mode="$(/usr/bin/stat -f '%Lp' "$repo/$allocation_path")"
  /bin/rm -f "$scratch/final-backup.json" "$scratch/receipt-backup.json"
  /bin/cp "$final" "$scratch/final-backup.json"
  /bin/cp "$repo/$allocation_path" "$scratch/receipt-backup.json"
  /bin/chmod 0600 "$final" "$repo/$allocation_path"
  ruby -rjson -rdigest - "$final" "$repo/$allocation_path" "$edit" <<'RUBY'
final_path, receipt_path, edit = ARGV
receipt = JSON.parse(File.read(receipt_path))
case edit
when "device-name" then receipt["deviceName"] = "Other iPhone"
when "not-shut-down" then receipt["cleanup"]["deviceState"] = "Booted"
end
File.write(receipt_path, JSON.pretty_generate(receipt) + "\n")
evidence = JSON.parse(File.read(final_path))
evidence.fetch("simulatorAllocations")[0]["digest"] = "sha256:#{Digest::SHA256.file(receipt_path).hexdigest}"
File.write(final_path, JSON.pretty_generate(evidence) + "\n")
RUBY
  if (cd "$repo" && "$validator_binary" --file "$final" --expected-issue 42 \
      --expected-base "$base_sha" --expected-head "$head_sha") >"$scratch/$label.out" 2>"$scratch/$label.err"; then
    echo "final validator accepted a $label receipt" >&2
    exit 1
  fi
  grep -Fq -- "$expected" "$scratch/$label.err" || {
    echo "final validator rejected the $label receipt for the wrong reason" >&2; cat "$scratch/$label.err" >&2; exit 1
  }
  /bin/cp "$scratch/final-backup.json" "$final"
  /bin/cp "$scratch/receipt-backup.json" "$repo/$allocation_path"
  /bin/chmod "$final_mode" "$final"
  /bin/chmod "$receipt_mode" "$repo/$allocation_path"
}
expect_rejected_receipt_edit renamed-device 'identity does not match the execution' device-name
expect_rejected_receipt_edit running-device 'was shut down after the case' not-shut-down
(cd "$repo" && "$validator_binary" --file "$final" --expected-issue 42 --expected-base "$base_sha" --expected-head "$head_sha") ||
  { echo "restored lease evidence no longer validates" >&2; exit 1; }

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
[[ "$(/bin/cat "$adapter_state/device-state-00000000-0000-0000-0000-000000000001" 2>/dev/null || printf Shutdown)" == Shutdown ]] || {
  echo "failed schema v2 run left the dedicated iPhone running" >&2; exit 1
}
/usr/bin/ruby -rjson - "$fake_log" "$(dirname "$matrix")" <<'RUBY'
log_path, batch_directory = ARGV
commands = File.readlines(log_path, chomp: true).map { |line| line.split("\t") }
creates = commands.count { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl create] }
deletes = commands.count { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl delete] }
erases = commands.count { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl erase] }
abort "failed schema v2 case created or deleted a Simulator" unless creates.zero? && deletes.zero?
abort "failed schema v2 case did not erase its sole lease once" unless erases == 1
receipts = Dir.glob(File.join(batch_directory, "allocation-*.json")).map { |path| JSON.parse(File.read(path)) }
abort "failed schema v2 case did not publish one lease receipt" unless receipts.length == 1
abort "failed schema v2 case was recorded as complete" unless receipts[0].dig("cleanup", "reason") == "case-failed" &&
  receipts[0].dig("cleanup", "deviceState") == "Shutdown"
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
[[ "$(/bin/cat "$adapter_state/device-state-00000000-0000-0000-0000-000000000001" 2>/dev/null || printf Shutdown)" == Shutdown ]] || {
  echo "TERM-interrupted schema v2 run left the dedicated iPhone running" >&2; exit 1
}
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
abort "schema v2 TERM cleanup did not shut the dedicated device down exactly once" unless
  mutations.count { |fields| fields[3] == "shutdown" } == 1 &&
  mutations.none? { |fields| %w[delete erase].include?(fields[3]) }
RUBY
[[ ! -e "$draft" ]] || { echo "TERM-interrupted schema v2 run published a draft" >&2; exit 1; }
assert_no_failed_attempts

test_stubborn_probe 2 allocation-v2-timeout
# Every runner timeout message reports the measured elapsed time, never the configured limit.
if rg -n 'elapsedSeconds=\$\{?(verification_timeout_seconds|timeout_seconds|IOS_TEMPLATE_PROBE_TIMEOUT_SECONDS)' "$runner"; then
  echo "runner timeout messages report the configured limit as the elapsed time" >&2
  exit 1
fi
grep -Fq 'elapsedSeconds=$(( $(/bin/date +%s) - verification_lock_started_at ))' "$runner" || {
  echo "verification lock timeout does not measure its elapsed time" >&2
  exit 1
}
[[ ! -e "$draft" && ! -e "$final" ]] || { echo "timed-out schema v2 run published successful evidence" >&2; exit 1; }
[[ "$(/bin/cat "$adapter_state/device-state-00000000-0000-0000-0000-000000000001" 2>/dev/null || printf Shutdown)" == Shutdown ]] || {
  echo "timed-out schema v2 run left the dedicated iPhone running" >&2
  exit 1
}
/usr/bin/ruby -rjson - "$fake_log" "$(dirname "$matrix")" <<'RUBY'
log_path, batch_directory = ARGV
commands = File.readlines(log_path, chomp: true).map { |line| line.split("\t") }
creates = commands.count { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl create] }
deletes = commands.count { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl delete] }
erases = commands.count { |fields| fields[0] == "xcrun" && fields[2..3] == %w[simctl erase] }
abort "timed-out schema v2 case created or deleted a Simulator" unless creates.zero? && deletes.zero?
abort "timed-out schema v2 case did not erase its sole lease once" unless erases == 1
receipts = Dir.glob(File.join(batch_directory, "allocation-*.json")).map { |path| JSON.parse(File.read(path)) }
abort "timed-out schema v2 case did not publish one cleanup receipt" unless receipts.length == 1
receipt = receipts.fetch(0)
abort "timed-out schema v2 cleanup was not bound to the failed case" unless
  receipt.fetch("caseId") == "iphone-en" && receipt.dig("cleanup", "reason") == "case-failed" &&
    receipt.dig("cleanup", "status") == "passed" && receipt.dig("cleanup", "deviceState") == "Shutdown"
RUBY
assert_no_failed_attempts

echo "schema v2 dedicated Simulator lease runner test passed"
