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
echo "cleanup iOS runner tests passed"
