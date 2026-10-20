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
  resolve_xcode_environment || fail 'Xcode is not available'
  xcodebuild_path="$XCODEBUILD_PATH"
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
  FileUtils.mkdir_p(root, mode: 0o700)
  stop("the location must not pass through a symbolic link") unless File.realpath(root) == root
  owned = lambda do |path|
    stat = File.lstat(path)
    stop("#{path} is not a directory owned by this user") unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
  end
  owned.call(root)
  worktree = File.join(root, id)
  begin
    Dir.mkdir(worktree, 0o700)
  rescue Errno::EEXIST
  end
  owned.call(worktree)
  File.chmod(0o700, worktree)
  marker = File.join(worktree, "owner.json")
  expected = %({"schemaVersion":1,"worktree":#{repository.to_json}}\n)
  if File.exist?(marker) || File.symlink?(marker)
    stat = File.lstat(marker)
    stop("owner.json is not a regular file owned by this user") unless stat.file? && stat.uid == Process.uid && stat.nlink == 1
    stop("#{worktree} belongs to another worktree") unless File.binread(marker) == expected
  else
    File.open(marker, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |file| file.write(expected) }
  end
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
stop_on_signal() {
  if [[ -n "$child_pid" ]]; then
    /usr/bin/pkill -TERM -P "$child_pid" 2>/dev/null || true
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
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
  kept="$worktree_root/Results/result-$(/bin/date -u +%Y%m%dT%H%M%SZ)-${run_folder##*.}.xcresult"
  /bin/mv -- "$result_bundle" "$kept"
  /usr/bin/ruby --disable-gems -rfileutils -e '
    results = ARGV.fetch(0)
    kept = Dir.children(results).grep(/\Aresult-\d{8}T\d{6}Z-[A-Za-z0-9]+\.xcresult\z/).sort
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
