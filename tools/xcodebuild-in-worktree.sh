#!/bin/bash -p
set -euo pipefail

# D-084 (#368): runs one ad-hoc `xcodebuild` outside the verify runners with the single fixed DerivedData
# of the current worktree, so verification work does not leave a new DerivedData or result bundle per task.
# The location is `~/Library/Caches/ios-template/derived-data/<worktree ID>/`, where the worktree ID is the
# verify runner's: the last component of the physical worktree root with every character outside
# [A-Za-z0-9_.-] replaced by `-`, then `-` and the SHA-256 of the physical root. `owner.json` records the
# physical root. Every result bundle goes to a per-run folder that is removed on exit; `--keep-result`
# keeps it in `Results/` with the newest three per worktree. `--scratch` uses a separate DerivedData (for
# mutation checks) that is removed on exit. INT and TERM also remove them.

usage() {
  echo 'usage: xcodebuild-in-worktree.sh [--keep-result] [--scratch] [--] XCODEBUILD_ARGUMENTS...' >&2
  exit 2
}
fail() { echo "xcodebuild-in-worktree: $*" >&2; exit 2; }

keep_result=0 scratch=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-result) keep_result=1; shift ;;
    --scratch) scratch=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[[ $# -gt 0 ]] || usage
# xcodebuild accepts -derivedDataPath only with -scheme, -testProductsPath or -xctestrun, so the tool is for
# build and test actions that name one of them.
has_scheme=0
for argument in "$@"; do
  case "$argument" in
    -derivedDataPath|-resultBundlePath) fail "this tool sets $argument itself" ;;
    -scheme|-testProductsPath|-xctestrun) has_scheme=1 ;;
  esac
done
[[ "$has_scheme" == 1 ]] || fail 'name -scheme, -testProductsPath or -xctestrun; xcodebuild accepts -derivedDataPath only with one of them'

script_dir="${BASH_SOURCE[0]%/*}"
script_dir="$(builtin cd "$script_dir" && /bin/pwd -P)"
source "$script_dir/lib/xcode.sh"

repository_root="$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null)" || fail 'run it inside a Git worktree'
repository_root="$(builtin cd "$repository_root" && /bin/pwd -P)"
common_git_dir="$(/usr/bin/git -C "$repository_root" rev-parse --path-format=absolute --git-common-dir)"
common_git_dir="$(builtin cd "$common_git_dir" && /bin/pwd -P)"
worktree_name="$(/usr/bin/basename "$repository_root" | /usr/bin/sed 's/[^A-Za-z0-9_.-]/-/g')"
worktree_digest="$(printf '%s' "$repository_root" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-64)"
worktree_id="$worktree_name-$worktree_digest"

initialize_trusted_environment || fail 'the user environment could not be verified'
user_home="${TRUSTED_BASE_ENV[0]#HOME=}"
if [[ "${IOS_TEMPLATE_TEST_MODE:-}" == 1 ]]; then
  derived_data_root="${IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT:?}"
  xcodebuild_path="${IOS_TEMPLATE_TEST_XCODEBUILD:?}"
  [[ -f "$xcodebuild_path" && -x "$xcodebuild_path" ]] || fail 'the test xcodebuild is not executable'
  XCODE_DEVELOPER_DIR=''
else
  derived_data_root="$user_home/Library/Caches/ios-template/derived-data"
fi

# The worktree directory and every component below the root must be real directories that this user owns.
worktree_root="$(/usr/bin/ruby --disable-gems -rjson -rfileutils -e '
  root, id, repository, common = ARGV
  def stop(message)
    warn "xcodebuild-in-worktree: #{message}"
    exit 2
  end
  stop("the location must be an absolute path") unless root.start_with?("/")
  [repository, common].each do |protected|
    stop("the location must be outside the repository") if root == protected || root.start_with?("#{protected}/")
  end
  owned = lambda do |path|
    stat = File.lstat(path)
    stop("#{path} is not a directory owned by this user") unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
  end
  # Before creating anything, the deepest existing ancestor must be a real path that this user owns, so a
  # symbolic link on the way can never place a new directory somewhere else (another worktree, for example).
  missing = []
  existing = root
  until File.exist?(existing) || File.symlink?(existing)
    missing.unshift(File.basename(existing))
    existing = File.dirname(existing)
  end
  stop("the location must not pass through a symbolic link") unless File.realpath(existing) == existing
  owned.call(existing)
  missing.each do |component|
    existing = File.join(existing, component)
    begin
      Dir.mkdir(existing, 0o700)
    rescue Errno::EEXIST
    end
    owned.call(existing)
  end
  worktree = File.join(root, id)
  created = begin
    Dir.mkdir(worktree, 0o700)
    true
  rescue Errno::EEXIST
    false
  end
  owned.call(worktree)
  # An existing directory must carry the owner record of this worktree before anything in it changes.
  marker = File.join(worktree, "owner.json")
  expected = %({"schemaVersion":1,"worktree":#{repository.to_json}}\n)
  if File.exist?(marker) || File.symlink?(marker)
    stat = File.lstat(marker)
    stop("owner.json is not a regular file owned by this user") unless stat.file? && stat.uid == Process.uid && stat.nlink == 1
    stop("#{worktree} belongs to another worktree") unless File.binread(marker) == expected
  elsif created || Dir.empty?(worktree)
    File.open(marker, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |file| file.write(expected) }
  else
    stop("#{worktree} has no owner record")
  end
  File.chmod(0o700, worktree)
  %w[DerivedData Results Runs Scratch].each do |name|
    path = File.join(worktree, name)
    begin
      Dir.mkdir(path, 0o700)
    rescue Errno::EEXIST
    end
    owned.call(path)
  end
  puts worktree
' "$derived_data_root" "$worktree_id" "$repository_root" "$common_git_dir")" || exit 2

# Xcode is located only after the location is verified, because locating it runs `xcodebuild -version`.
if [[ "${IOS_TEMPLATE_TEST_MODE:-}" != 1 ]]; then
  resolve_xcode_environment || fail 'Xcode is not available'
  xcodebuild_path="$XCODEBUILD_PATH"
fi

run_folder="" scratch_folder="" child_pid=""
remove_owned_folder() {
  local folder=$1 parent=$2
  [[ -n "$folder" && "$folder" == "$parent/"* && -d "$folder" && ! -L "$folder" ]] || return 0
  /bin/rm -rf -- "$folder"
}
cleanup() {
  remove_owned_folder "$run_folder" "$worktree_root/Runs"
  remove_owned_folder "$scratch_folder" "$worktree_root/Scratch"
}
# The cancellation goes to the bounded supervisor, which reclaims the xcodebuild process group (TERM, a
# grace period, then KILL) before it exits, and the cleanup waits for it, so nothing in that group writes
# after the run folders are removed. A watchdog keeps the wait finite.
stop_on_signal() {
  if [[ -n "$child_pid" ]]; then
    local supervisor watchdog
    for supervisor in $(/usr/bin/pgrep -P "$child_pid"); do
      kill -TERM "$supervisor" 2>/dev/null || true
    done
    (
      sleep 60
      /usr/bin/pkill -KILL -P "$child_pid" 2>/dev/null || true
      kill -KILL "$child_pid" 2>/dev/null || true
    ) &
    watchdog=$!
    wait "$child_pid" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
  fi
  exit "$1"
}
trap cleanup EXIT
trap 'stop_on_signal 130' INT
trap 'stop_on_signal 143' TERM

run_folder="$(/usr/bin/mktemp -d "$worktree_root/Runs/run.XXXXXX")"
derived_data="$worktree_root/DerivedData"
if [[ "$scratch" == 1 ]]; then
  scratch_folder="$(/usr/bin/mktemp -d "$worktree_root/Scratch/scratch.XXXXXX")"
  derived_data="$scratch_folder/DerivedData"
fi
result_bundle="$run_folder/Result.xcresult"

XCODEBUILD_PATH="$xcodebuild_path"
status=0
{
  command_status=0
  run_xcodebuild "$@" -derivedDataPath "$derived_data" -resultBundlePath "$result_bundle" || command_status=$?
  [[ -z "${IOS_TEMPLATE_LAST_TIMEOUT_MESSAGE:-}" ]] || echo "xcodebuild-in-worktree: $IOS_TEMPLATE_LAST_TIMEOUT_MESSAGE" >&2
  exit "$command_status"
} &
child_pid=$!
wait "$child_pid" || status=$?
child_pid=""

if [[ "$keep_result" == 1 && -d "$result_bundle" && ! -L "$result_bundle" ]]; then
  # Names sort in completion order: nanosecond UTC time, then the process ID as a fixed tie-breaker.
  kept="$worktree_root/Results/result-$(/usr/bin/ruby --disable-gems -e 'print Time.now.utc.strftime("%Y%m%dT%H%M%S.%9NZ")')-$(printf '%010d' "$$").xcresult"
  /bin/mv -- "$result_bundle" "$kept"
  /usr/bin/ruby --disable-gems -rfileutils -e '
    results = ARGV.fetch(0)
    kept = Dir.children(results).grep(/\Aresult-\d{8}T\d{6}\.\d{9}Z-\d{10}\.xcresult\z/).sort
    kept[0...-3].each do |name|
      path = File.join(results, name)
      stat = File.lstat(path)
      next unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
      FileUtils.rm_rf(path)
    end
  ' "$worktree_root/Results"
  echo "xcodebuild-in-worktree: kept the result bundle at $kept" >&2
fi
exit "$status"
