#!/usr/bin/env bash
set -euo pipefail
source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc
[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

# AC-1 / AC-5: publication survives disposal of all private run state.
prepare_repo successful-attempt-cleanup
FAKE_OBSERVE_CLEANUP=1 run_execute
[[ -f "$adapter_state/cleanup-observation/checked" ]] || { echo "cleanup ownership observation missing" >&2; exit 1; }
assert_no_failed_attempts
[[ -f "$draft" ]] || { echo "cleanup removed canonical draft" >&2; exit 1; }
for case_id in iphone-en iphone-ja ipad-en ipad-ja; do
  [[ -f "$(dirname "$draft")/$case_id/screenshot.png" ]] || { echo "cleanup removed canonical screenshot" >&2; exit 1; }
done

# AC-3/4/5: only sealed, descriptor-owned attempts in this worktree are eligible.
prepare_repo orphan-boundaries
receipt="$(cd "$repo" && "$validator_binary" --runner-snapshot --issue 42 --expected-base "$base_sha" --expected-head "$head_sha" --issue-contract .artifacts/issues/42/issue-contract.json --matrix .artifacts/batches/runner-fixture/simulator-matrix.json --project TemplateApp.xcodeproj)"
IFS=$'\t' read -r seed_config seed_digest workspace seed_attempt _ <<<"$receipt"
worktree_workspace="$(dirname "$(dirname "$workspace")")"
other_head="$worktree_workspace/issue-43/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
locked_head="$worktree_workspace/issue-42/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
foreign_root="$scratch/foreign-repository"
mkdir -p "$foreign_root"
foreign_workspace="/tmp/ios-template-verify/foreign-repository-$(/usr/bin/ruby -rdigest -e 'print Digest::SHA256.hexdigest(ARGV.fetch(0))' "$foreign_root")"
foreign_head="$foreign_workspace/issue-42/cccccccccccccccccccccccccccccccccccccccc"
# This foreign root is fixture-owned and explicitly removed by this test only.
make_orphan() {
  /usr/bin/ruby -rjson -rfileutils -rsecurerandom - "$seed_config" "$1" <<'RUBY'
source, head = ARGV
config = JSON.parse(File.read(source))
root = head + '/Attempts/attempt-' + SecureRandom.uuid
FileUtils.mkdir_p(root, mode: 0700)
File.write(head + '/.verify.lock', '')
File.chmod(0600, head + '/.verify.lock')
old_root = config.fetch('attemptRoot')
old_workspace = config.fetch('workspaceRoot')
replace = lambda do |value|
  case value
  when Hash then value.transform_values { |v| replace.call(v) }
  when Array then value.map { |v| replace.call(v) }
  when String then value.gsub(old_root, root).gsub(old_workspace, head)
  else value
  end
end
File.write(root + '/config.json', JSON.generate(replace.call(config)) + "\n")
File.chmod(0400, root + '/config.json')
File.write(root + '/owned-marker', 'owned')
puts root
RUBY
}
owned_orphan="$(make_orphan "$other_head")"
locked_orphan="$(make_orphan "$locked_head")"
failed_orphan="$(make_orphan "$worktree_workspace/issue-42/dddddddddddddddddddddddddddddddddddddddd")"
# An immutable fixture-owned child makes recursive deletion fail without
# compromising another attempt or failing the verification.
cleanup_immutable_file="$failed_orphan/owned-marker"
chflags uchg "$cleanup_immutable_file"
foreign_orphan="$(make_orphan "$foreign_head")"
/usr/bin/ruby -rjson - "$foreign_orphan/config.json" "$foreign_root" <<'RUBY'
path, root = ARGV
config = JSON.parse(File.read(path))
config['repositoryRoot'] = root
File.chmod(0600, path)
File.write(path, JSON.generate(config) + "\n")
File.chmod(0400, path)
RUBY
unknown="$workspace/Attempts/attempt-11111111-1111-4111-8111-111111111111"
symlink="$workspace/Attempts/attempt-22222222-2222-4222-8222-222222222222"
invalid="$workspace/Attempts/attempt-33333333-3333-4333-8333-333333333333"
mismatch="$workspace/Attempts/attempt-44444444-4444-4444-8444-444444444444"
mkdir -p "$unknown" "$scratch/symlink-target" "$invalid" "$mismatch"
printf keep >"$unknown/marker"
printf keep >"$scratch/symlink-target/marker"
ln -s "$scratch/symlink-target" "$symlink"
printf '{}\n' >"$invalid/config.json"
chmod 0400 "$invalid/config.json"
cp "$seed_config" "$mismatch/config.json"
chmod 0400 "$mismatch/config.json"
/usr/bin/ruby - "$locked_head/.verify.lock" "$scratch/orphan-lock-ready" <<'RUBY' &
lock, ready = ARGV
File.open(lock, File::RDWR) do |file|
  abort unless file.flock(File::LOCK_EX | File::LOCK_NB)
  File.write(ready, 'ready')
  sleep 600
end
RUBY
cleanup_lock_pid=$!
for ((i=0; i<200; i++)); do
  [[ ! -f "$scratch/orphan-lock-ready" ]] || break
  sleep 0.05
done
[[ -f "$scratch/orphan-lock-ready" ]] || { echo "fixture lock was not acquired" >&2; exit 1; }
lock_inode="$(stat -f '%i' "$workspace/.verify.lock")"
run_execute >"$scratch/orphan-run.stdout" 2>"$scratch/orphan-run.stderr"
[[ -f "$failed_orphan/owned-marker" ]] || { echo "fixture did not exercise deletion failure" >&2; exit 1; }
chflags nouchg "$cleanup_immutable_file"
cleanup_immutable_file=''
rm -rf "$failed_orphan"
grep -Eq '^runner orphan cleanup: removed=[0-9]+ skipped=[0-9]+ failed=1$' "$scratch/orphan-run.stderr"
[[ ! -e "$seed_attempt" && ! -e "$owned_orphan" ]] || { echo "owned orphan was not collected" >&2; exit 1; }
[[ -f "$locked_orphan/owned-marker" && -f "$foreign_orphan/owned-marker" ]] || { echo "cleanup escaped an inactive owned Head" >&2; exit 1; }
[[ -f "$unknown/marker" && -L "$symlink" && -f "$scratch/symlink-target/marker" && -f "$invalid/config.json" && -f "$mismatch/config.json" ]] || { echo "cleanup followed or removed an unidentified attempt" >&2; exit 1; }
[[ "$(stat -f '%i' "$workspace/.verify.lock")" == "$lock_inode" ]] || { echo "cleanup replaced the lock inode" >&2; exit 1; }
[[ -f "$draft" && -f "$(dirname "$draft")/iphone-en/screenshot.png" ]] || { echo "orphan cleanup affected publication" >&2; exit 1; }
grep -Eq '^runner orphan cleanup: removed=[0-9]+ skipped=[0-9]+ failed=[0-9]+$' "$scratch/orphan-run.stderr"
if grep -Fq "$worktree_workspace" "$scratch/orphan-run.stderr"; then
  echo "orphan cleanup disclosed a path" >&2; exit 1
fi
/bin/kill "$cleanup_lock_pid"
wait "$cleanup_lock_pid" 2>/dev/null || true
cleanup_lock_pid=''
# A later Head can collect the released lock owner's orphan without changing
# the prior Head's published evidence.
previous_draft="$draft"
printf '%s\n' '# Next Head' >"$repo/docs/next.md"
git -C "$repo" add docs/next.md
git -C "$repo" commit -q -m next
refresh_head_paths
run_execute
[[ ! -e "$locked_orphan" ]] || { echo "released Head orphan was not collected" >&2; exit 1; }
[[ -f "$previous_draft" && -f "$draft" ]] || { echo "cleanup removed published evidence" >&2; exit 1; }
# Remove only test-created sentinels; production intentionally left them untouched.
rm -rf "$foreign_workspace" "$unknown" "$invalid" "$mismatch"
rm "$symlink"
assert_no_failed_attempts
assert_runner_publication_cleanup

# #262: a failed Build, Unit Test or UI case keeps only that stage's result bundle and log, private to
# this user and outside the repository and the canonical evidence, under the failure record's UUID.
retained_root() { printf '%s/Retained\n' "$(runner_workspace)"; }
failure_ids() {
  /usr/bin/find "$(dirname "$draft")/failures" -type f -name 'failure-*.json' 2>/dev/null |
    /usr/bin/sed -E 's|.*/failure-(.*)\.json$|\1|' | LC_ALL=C /usr/bin/sort
}
retained_items() { (cd "$1" && /bin/ls -A | LC_ALL=C /usr/bin/sort | /usr/bin/paste -sd ' ' -); }

assert_retained() {
  local stage=$1 ids id retained expected
  shift
  ids="$(failure_ids)"
  [[ -n "$ids" && "$(printf '%s\n' "$ids" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 1 ]] || { echo "expected one failure record for $stage" >&2; exit 1; }
  id="$ids"
  retained="$(retained_root)/failure-$id"
  [[ -d "$retained" && ! -L "$retained" && ! -L "$(retained_root)" ]] || { echo "the $stage failure was not retained under its record UUID" >&2; exit 1; }
  [[ "$(/usr/bin/stat -f '%Lp %u' "$(retained_root)")" == "700 $(/usr/bin/id -u)" &&
     "$(/usr/bin/stat -f '%Lp %u' "$retained")" == "700 $(/usr/bin/id -u)" ]] || { echo "retained $stage diagnostics are not private" >&2; exit 1; }
  [[ -z "$(/usr/bin/find "$retained" -type l -print -quit)" ]] || { echo "retained $stage diagnostics contain a link" >&2; exit 1; }
  expected="$(printf '%s\n' retained.json "$@" | LC_ALL=C /usr/bin/sort | /usr/bin/paste -sd ' ' -)"
  [[ "$(retained_items "$retained")" == "$expected" ]] || { echo "retained $stage items: $(retained_items "$retained"), expected $expected" >&2; exit 1; }
  /usr/bin/ruby -rjson - "$retained/retained.json" "$id" "$stage" "$(runner_workspace)" "$repo" "$(dirname "$draft")/failures/failure-$id.json" "$@" <<'RUBY'
record_path, id, stage, workspace, repository, failure_path, *items = ARGV
record = JSON.parse(File.read(record_path))
abort "retained record keys: #{record.keys}" unless record.keys.sort == %w[failureId items repositoryRoot retainedAt schemaVersion stage workspaceRoot]
abort "retained record: #{record}" unless record.values_at("schemaVersion", "failureId", "stage", "workspaceRoot", "repositoryRoot") ==
  [1, id, stage, workspace, File.realpath(repository)] && record["items"].sort == items.sort
failure = JSON.parse(File.read(failure_path))
abort "failure record schema changed: #{failure.keys}" unless failure.keys.sort == %w[baseSha error headSha issue recordedAt schemaVersion stage status]
abort "failure record stage: #{failure["stage"]}" unless failure["stage"] == stage && failure["status"] == "failed"
RUBY
  assert_no_failed_attempts
  if /usr/bin/grep -rqF -- 'Retained' "$repo/.artifacts" 2>/dev/null; then
    echo "canonical artifacts refer to retained $stage diagnostics" >&2; exit 1
  fi
}

prepare_repo retained-build
FAKE_BUILD_MODE=warning expect_execute_failure retained-build "build warnings are not allowed"
assert_retained build Build.xcresult build.log
[[ ! -e "$(retained_root)/failure-$(failure_ids)/DerivedData" ]] || { echo "DerivedData was retained" >&2; exit 1; }

prepare_repo retained-build-command
FAKE_BUILD_MODE=fail expect_execute_failure retained-build-command "build command failed"
assert_retained build build.log
/usr/bin/grep -Fq 'configured build failure' "$(retained_root)/failure-$(failure_ids)/build.log" || { echo "the retained build log differs" >&2; exit 1; }

prepare_repo retained-unit-tests
FAKE_TEST_MODE=failed expect_execute_failure retained-unit-tests "unit tests"
assert_retained unit-tests Tests.xcresult tests.log

prepare_repo retained-ui-case
FAKE_UI_MODE=zero expect_execute_failure retained-ui-case "case iphone-en failed"
assert_retained case-iphone-en iphone-en.xcresult iphone-en-ui-test.log

# A failure outside those stages keeps nothing, and a successful run keeps nothing.
prepare_repo retained-none
FAKE_APP_MODE=nested-symlink expect_execute_failure retained-other-stage "built application"
run_execute >/dev/null
[[ ! -e "$(retained_root)" ]] || { echo "a run kept diagnostics without a failed Build, Unit Test or UI case" >&2; exit 1; }

# Only the newest retained failure of a Head is kept: the next run removes older ones that prove their
# ownership, and leaves unknown names, links, records of another workspace and other repositories alone.
prepare_repo retained-limit
FAKE_BUILD_MODE=fail expect_execute_failure retained-limit-first "build command failed"
first_id="$(failure_ids)"
FAKE_BUILD_MODE=fail expect_execute_failure retained-limit-second "build command failed"
second_id="$(failure_ids | /usr/bin/grep -vx "$first_id")"
[[ -d "$(retained_root)/failure-$first_id" && -d "$(retained_root)/failure-$second_id" ]] || { echo "each failure was not retained" >&2; exit 1; }
make_retained() {
  /usr/bin/ruby -rjson -rfileutils -rsecurerandom - "$1" "$2" "$(cd "$repo" && /bin/pwd -P)" "$3" <<'RUBY'
retained, workspace, repository, retained_at = ARGV
id = SecureRandom.uuid
directory = File.join(retained, "failure-#{id}")
FileUtils.mkdir_p(directory, mode: 0700)
File.chmod(0700, retained)
File.write(File.join(directory, "build.log"), "kept\n")
File.write(File.join(directory, "retained.json"), JSON.generate({
  "failureId" => id, "items" => ["build.log"], "repositoryRoot" => repository, "retainedAt" => retained_at,
  "schemaVersion" => 1, "stage" => "build", "workspaceRoot" => workspace
}) + "\n")
File.chmod(0400, File.join(directory, "retained.json"))
puts directory
RUBY
}
other_head_workspace="$(dirname "$(runner_workspace)")/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
mkdir -p "$other_head_workspace/Retained"
: >"$other_head_workspace/.verify.lock"
other_old="$(make_retained "$other_head_workspace/Retained" "$other_head_workspace" 2026-10-01T00:00:00.000Z)"
other_new="$(make_retained "$other_head_workspace/Retained" "$other_head_workspace" 2026-10-02T00:00:00.000Z)"
mismatched="$(make_retained "$(retained_root)" "$other_head_workspace" 2000-01-01T00:00:00.000Z)"
mkdir -p "$(retained_root)/notes" "$scratch/retained-link-target"
printf keep >"$(retained_root)/notes/marker"
printf keep >"$scratch/retained-link-target/marker"
ln -s "$scratch/retained-link-target" "$(retained_root)/failure-55555555-5555-4555-8555-555555555555"
foreign_retained_root="$scratch/foreign-retained-repository"
mkdir -p "$foreign_retained_root"
foreign_retained_workspace="/tmp/ios-template-verify/foreign-retained-repository-$(/usr/bin/ruby -rdigest -e 'print Digest::SHA256.hexdigest(ARGV.fetch(0))' "$foreign_retained_root")/issue-42/$head_sha"
mkdir -p "$foreign_retained_workspace/Retained"
foreign_old="$(make_retained "$foreign_retained_workspace/Retained" "$foreign_retained_workspace" 2000-01-01T00:00:00.000Z)"
foreign_new="$(make_retained "$foreign_retained_workspace/Retained" "$foreign_retained_workspace" 2026-10-02T00:00:00.000Z)"
run_execute >"$scratch/retained-limit-run.stdout" 2>"$scratch/retained-limit-run.stderr"
[[ ! -e "$(retained_root)/failure-$first_id" ]] || { echo "the older retained failure was not collected" >&2; exit 1; }
[[ -d "$(retained_root)/failure-$second_id" ]] || { echo "the newest retained failure was collected" >&2; exit 1; }
[[ ! -e "$other_old" && -d "$other_new" ]] || { echo "another inactive Head kept more than its newest retained failure" >&2; exit 1; }
[[ -f "$mismatched/retained.json" && -f "$(retained_root)/notes/marker" && -L "$(retained_root)/failure-55555555-5555-4555-8555-555555555555" &&
   -f "$scratch/retained-link-target/marker" ]] || { echo "retained cleanup removed an unidentified entry or followed a link" >&2; exit 1; }
[[ -d "$foreign_old" && -d "$foreign_new" ]] || { echo "retained cleanup reached another repository" >&2; exit 1; }
[[ -f "$draft" ]] || { echo "retained cleanup affected publication" >&2; exit 1; }
if /usr/bin/grep -rqF -- 'Retained' "$repo/.artifacts"; then
  echo "canonical evidence refers to retained diagnostics" >&2; exit 1
fi
if /usr/bin/grep -Fq "$(dirname "$(runner_workspace)")" "$scratch/retained-limit-run.stderr"; then
  echo "retained cleanup disclosed a path" >&2; exit 1
fi
# Remove only test-created sentinels; production intentionally left them untouched.
rm -rf "$(dirname "$(dirname "$foreign_retained_workspace")")" "$mismatched" "$(retained_root)/notes"
rm "$(retained_root)/failure-55555555-5555-4555-8555-555555555555"
echo "cleanup iOS runner tests passed"
