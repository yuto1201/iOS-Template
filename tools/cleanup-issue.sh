#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
identity_tool="$repo_root/tools/lib/merge-state.rb"
usage() { echo 'usage: cleanup-issue.sh --repo OWNER/REPO --issue NUMBER' >&2; exit 2; }
repo='' issue=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --issue) issue=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || usage
fail() { echo "cleanup refused: $*" >&2; exit 1; }

# D-084 (#369): after the worktree is removed, reclaim the build data that belonged to it: the fixed
# DerivedData of tools/xcodebuild-in-worktree.sh whose owner record names this worktree, Xcode's default
# DerivedData folders whose info.plist WorkspacePath is inside it, and the Retained/ and leftover Attempts/
# contents of each verify Head whose .verify.lock can be taken without waiting. .verify.lock files and the
# emptied directories stay (split-lock prevention). Nothing is removed by name or age alone: every entry must
# be a real directory owned by this user at its exact path, bound by descriptor before and after. Skipped
# entries are reported; any failure exits non-zero and a rerun finishes the rest. The three roots can be
# replaced only in the explicit test mode.
reclaim_worktree_data() {
  ruby --disable-gems -rjson -rdigest -retc -ropen3 -e '
    UID = Process.uid
    $failed = 0
    $removed = 0
    $skipped = 0
    def report(message)
      warn "cleanup reclaim: #{message}"
    end
    def skip(path, reason)
      $skipped += 1
      report "skipped #{path} (#{reason})"
    end
    def failure(path, error)
      $failed += 1
      report "failed #{path}: #{error.is_a?(Exception) ? error.message : error}"
    end
    def lstat_or_nil(path)
      File.lstat(path)
    rescue Errno::ENOENT
      nil
    end
    def owned_directory?(stat)
      !stat.nil? && stat.directory? && stat.uid == UID
    end
    def open_bound_directory(path)
      before = File.lstat(path)
      raise "#{path} is not a directory owned by this user" unless owned_directory?(before)
      io = File.open(path, File::RDONLY | File::NOFOLLOW)
      bound = io.stat
      unless bound.directory? && bound.uid == UID && bound.dev == before.dev && bound.ino == before.ino
        io.close
        raise "#{path} changed while it was opened"
      end
      io
    end
    def still_bound!(path, io)
      now = File.lstat(path)
      bound = io.stat
      raise "#{path} changed during the reclaim" unless owned_directory?(now) && now.dev == bound.dev && now.ino == bound.ino
    end
    def read_owned_regular(path, limit)
      before = lstat_or_nil(path)
      return nil unless before && before.file? && before.uid == UID && before.nlink == 1 && before.size <= limit
      File.open(path, File::RDONLY | File::NOFOLLOW) do |io|
        bound = io.stat
        return nil unless bound.file? && bound.dev == before.dev && bound.ino == before.ino && bound.nlink == 1
        bytes = io.read(limit + 1).to_s
        return nil unless bytes.bytesize == bound.size
        bytes
      end
    rescue SystemCallError
      nil
    end
    # Each directory is bound by descriptor, made owner-writable through it (Xcode keeps read-only package
    # checkouts), and emptied without following a symbolic link. An entry owned by someone else stops it.
    def remove_tree(path)
      io = open_bound_directory(path)
      begin
        io.chmod(0o700)
        Dir.children(path).each do |name|
          child = File.join(path, name)
          stat = File.lstat(child)
          raise "#{child} is not owned by this user" unless stat.uid == UID
          stat.directory? ? remove_tree(child) : File.unlink(child)
        end
        still_bound!(path, io)
      ensure
        io.close
      end
      Dir.rmdir(path)
    end
    def reclaim(path, held)
      held.each { |held_path, held_io| still_bound!(held_path, held_io) }
      before = lstat_or_nil(path)
      raise "#{path} is not a directory owned by this user" unless owned_directory?(before)
      remove_tree(path)
      raise "#{path} still exists" if lstat_or_nil(path)
      $removed += 1
      report "removed #{path}"
    rescue StandardError => error
      failure(path, error)
    end
    def open_root(path)
      return nil if lstat_or_nil(path).nil?
      open_bound_directory(path)
    rescue StandardError => error
      failure(path, error)
      nil
    end

    root = ARGV.fetch(0)
    components = root.split("/", -1)
    unless root.start_with?("/") && components.length >= 3 && components.drop(1).none? { |part| part.empty? || part == "." || part == ".." } && !root.include?("\0")
      abort "cleanup reclaim: the worktree root is not a canonical absolute path"
    end
    abort "cleanup reclaim: the worktree still exists" if lstat_or_nil(root)
    parent = File.dirname(root)
    abort "cleanup reclaim: the worktree parent is not physical" unless File.realpath(parent) == parent
    worktree_id = "#{File.basename(root).gsub(/[^A-Za-z0-9_.-]/, "-")}-#{Digest::SHA256.hexdigest(root)}"
    if ENV["IOS_TEMPLATE_TEST_MODE"] == "1"
      fixed_root = ENV.fetch("IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT")
      xcode_root = ENV.fetch("IOS_TEMPLATE_TEST_XCODE_DERIVED_DATA_ROOT")
      verify_root = ENV.fetch("IOS_TEMPLATE_TEST_VERIFY_ROOT")
      abort "cleanup reclaim: test roots must be absolute" unless [fixed_root, xcode_root, verify_root].all? { |path| path.start_with?("/") }
    else
      home = Etc.getpwuid(UID).dir
      fixed_root = File.join(home, "Library", "Caches", "ios-template", "derived-data")
      xcode_root = File.join(home, "Library", "Developer", "Xcode", "DerivedData")
      verify_root = "/tmp/ios-template-verify"
    end

    # 1. The fixed DerivedData of tools/xcodebuild-in-worktree.sh, only with the exact owner record.
    begin
      if (fixed = open_root(fixed_root))
        entry = File.join(fixed_root, worktree_id)
        stat = lstat_or_nil(entry)
        if stat && !owned_directory?(stat)
          skip(entry, "not a directory owned by this user")
        elsif stat
          expected = %({"schemaVersion":1,"worktree":#{root.to_json}}\n)
          if read_owned_regular(File.join(entry, "owner.json"), 65_536) == expected
            reclaim(entry, [[fixed_root, fixed]])
          else
            skip(entry, "its owner record does not name this worktree")
          end
        end
        fixed.close
      end
    rescue StandardError => error
      failure(fixed_root, error)
    end

    # 2. Xcode default DerivedData whose info.plist WorkspacePath is inside the removed worktree.
    begin
      if (xcode = open_root(xcode_root))
        Dir.children(xcode_root).sort.each do |name|
          entry = File.join(xcode_root, name)
          next unless owned_directory?(lstat_or_nil(entry))
          bytes = read_owned_regular(File.join(entry, "info.plist"), 1_048_576)
          next if bytes.nil?
          workspace, status = Open3.capture2("/usr/bin/plutil", "-extract", "WorkspacePath", "raw", "-o", "-", "-", stdin_data: bytes, err: File::NULL)
          next unless status.success?
          workspace = workspace.chomp("\n")
          next unless workspace == root || workspace.start_with?("#{root}/")
          reclaim(entry, [[xcode_root, xcode]])
        end
        xcode.close
      end
    rescue StandardError => error
      failure(xcode_root, error)
    end

    # 3. Retained/ and leftover Attempts/ of each verify Head whose .verify.lock is free right now.
    begin
      if (verify = open_root(verify_root))
        worktree_path = File.join(verify_root, worktree_id)
        stat = lstat_or_nil(worktree_path)
        if stat && !owned_directory?(stat)
          skip(worktree_path, "not a directory owned by this user")
        elsif stat
          worktree_io = open_bound_directory(worktree_path)
          Dir.children(worktree_path).sort.each do |issue_name|
            issue_path = File.join(worktree_path, issue_name)
            next skip(issue_path, "not an Issue directory") unless issue_name.match?(/\Aissue-[1-9][0-9]*\z/) && owned_directory?(lstat_or_nil(issue_path))
            issue_io = open_bound_directory(issue_path)
            Dir.children(issue_path).sort.each do |head_name|
              head_path = File.join(issue_path, head_name)
              next skip(head_path, "not a Head directory") unless head_name.match?(/\A[0-9a-f]{40}\z/) && owned_directory?(lstat_or_nil(head_path))
              head_io = nil
              lock_io = nil
              begin
                head_io = open_bound_directory(head_path)
                lock_path = File.join(head_path, ".verify.lock")
                lock_stat = lstat_or_nil(lock_path)
                next skip(head_path, "no usable .verify.lock") unless lock_stat && lock_stat.file? && lock_stat.uid == UID && lock_stat.nlink == 1
                lock_io = File.open(lock_path, File::RDWR | File::NOFOLLOW)
                next skip(head_path, "its verification lock is held") unless lock_io.flock(File::LOCK_EX | File::LOCK_NB)
                locked = lock_io.stat
                current = File.lstat(lock_path)
                raise "#{lock_path} changed while it was locked" unless locked.file? && locked.nlink == 1 && current.dev == locked.dev && current.ino == locked.ino
                %w[Retained Attempts].each do |area|
                  area_path = File.join(head_path, area)
                  area_stat = lstat_or_nil(area_path)
                  next if area_stat.nil?
                  next skip(area_path, "not a directory owned by this user") unless owned_directory?(area_stat)
                  area_io = open_bound_directory(area_path)
                  begin
                    held = [[verify_root, verify], [worktree_path, worktree_io], [issue_path, issue_io], [head_path, head_io], [area_path, area_io]]
                    Dir.children(area_path).sort.each do |name|
                      entry = File.join(area_path, name)
                      if owned_directory?(lstat_or_nil(entry))
                        reclaim(entry, held)
                      else
                        skip(entry, "not a directory owned by this user")
                      end
                    end
                  ensure
                    area_io.close
                  end
                end
              rescue StandardError => error
                failure(head_path, error)
              ensure
                lock_io&.close
                head_io&.close
              end
            end
            issue_io.close
          end
          worktree_io.close
        end
        verify.close
      end
    rescue StandardError => error
      failure(verify_root, error)
    end
    report "removed=#{$removed} skipped=#{$skipped} failed=#{$failed}"
    exit($failed.zero? ? 0 : 1)
  ' "$1"
}

identity=$(ruby "$identity_tool" validate-primary "$repo_root" "$repo" "$issue") || fail 'durable Issue identity is invalid'
[[ "$(jq -er '.primaryRoot | strings' <<<"$identity")" == "$repo_root" ]] || fail 'cleanup must run in the primary checkout'
[[ "$(jq -er '.state | strings' <<<"$identity")" == merged ]] || fail 'cleanup requires durable merged state'
branch=$(jq -er '.branch | strings' <<<"$identity")
worktree=$(jq -er '.worktreePath | strings' <<<"$identity")
head_sha=$(jq -er '.headSha | strings' <<<"$identity")
pull_request=$(jq -er '.pullRequest' <<<"$identity") || fail 'cleanup requires a positive persisted pullRequest'
worktree_present=$(jq -r '.worktreePresent' <<<"$identity")
external_operations=$(jq -ce '.externalOperations | arrays' <<<"$identity") || fail 'durable external-operation declarations are invalid'
contract_digest=$(jq -er '.contractDigest | strings' <<<"$identity") || fail 'durable Issue contract digest is invalid'
primary_implementer=$(jq -er '.primaryImplementer | strings' <<<"$identity") || fail 'durable primary implementer is invalid'
pr_fields='number,state,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,closingIssuesReferences,mergeCommit,url'
# D-084: the durable worktree path is the physical primary root (realpath) joined with the canonical
# `.worktrees/<issue>-<slug>`, so it is the physical worktree root that the verify runner and
# tools/xcodebuild-in-worktree.sh hash. It is fixed here, before the worktree is removed, and a rerun after the
# removal gets the same value from durable state.
reclaim_root=$worktree

[[ "$(git -C "$repo_root" rev-parse --show-toplevel)" == "$repo_root" ]] || fail 'Git top-level differs from primary checkout'
[[ "$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)" == "$repo_root/.git" ]] || fail 'Git common directory differs from primary checkout'
base_sha=$(jq -er '.baseSha | strings' <<<"$identity")
[[ "$(git -C "$repo_root" cat-file -t "$base_sha")" == commit && "$(git -C "$repo_root" cat-file -t "$head_sha")" == commit ]] || fail 'durable Base or Head is not a commit'
git -C "$repo_root" merge-base --is-ancestor "$base_sha" "$head_sha" || fail 'durable Base is not an ancestor of Head'
require_origin() {
  local origin_url
  origin_url=$(git -C "$repo_root" remote get-url origin) || fail 'origin remote is missing'
  case "$origin_url" in
    "https://github.com/$repo"|"https://github.com/$repo.git"|"git@github.com:$repo"|"git@github.com:$repo.git"|"ssh://git@github.com/$repo"|"ssh://git@github.com/$repo.git") ;;
    *) fail 'origin remote does not match requested repository' ;;
  esac
}
require_origin
if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
  [[ "$(git -C "$repo_root" rev-parse "refs/heads/$branch")" == "$head_sha" ]] || fail 'local Branch was reused at a different Head'
fi
if [[ -e "$worktree" || -L "$worktree" ]]; then
  [[ "$worktree_present" == true && -d "$worktree" && ! -L "$worktree" ]] || fail 'recorded worktree is unsafe or dangling'
  [[ "$(git -C "$worktree" rev-parse --show-toplevel)" == "$worktree" ]] || fail 'recorded worktree Git identity differs'
  [[ "$(git -C "$worktree" branch --show-current)" == "$branch" && "$(git -C "$worktree" rev-parse HEAD)" == "$head_sha" && "$(git -C "$worktree" rev-parse "refs/heads/$branch")" == "$head_sha" ]] || fail 'worktree Branch, ref, or Head differs from durable state'
  [[ -z "$(git -C "$worktree" status --porcelain)" ]] || fail 'recorded worktree is dirty'
else
  [[ "$worktree_present" == false ]] || fail 'recorded worktree presence changed during validation'
fi

"$repo_root/tools/github-account-preflight.sh" --repo "$repo" >/dev/null || fail 'personal GitHub account or repository preflight failed'
pr_json=$(gh pr view "$pull_request" --repo "$repo" --json "$pr_fields") || fail 'persisted PR could not be read'
merge_commit=$(PR_JSON="$pr_json" REPO="$repo" ISSUE="$issue" PR="$pull_request" BRANCH="$branch" HEAD="$head_sha" ruby -rjson -e '
  pr = JSON.parse(ENV.fetch("PR_JSON")); abort unless pr.is_a?(Hash) && pr.keys.sort == %w[number state baseRefName headRefName headRefOid headRepository headRepositoryOwner isCrossRepository closingIssuesReferences mergeCommit url].sort
  abort unless pr["number"] == Integer(ENV.fetch("PR")) && pr["url"] == "https://github.com/#{ENV.fetch("REPO")}/pull/#{ENV.fetch("PR")}" && pr["state"] == "MERGED"
  abort unless pr["baseRefName"] == "main" && pr["headRefName"] == ENV.fetch("BRANCH") && pr["headRefOid"] == ENV.fetch("HEAD")
  abort unless pr["isCrossRepository"] == false && pr.dig("headRepository", "nameWithOwner") == ENV.fetch("REPO") && pr.dig("headRepositoryOwner", "login") == ENV.fetch("REPO").split("/", 2).first
  closing = pr["closingIssuesReferences"]
  target_owner, target_name = ENV.fetch("REPO").split("/", 2)
  closing_repository = closing.is_a?(Array) && closing.length == 1 ? closing[0]["repository"] : nil
  abort unless closing.is_a?(Array) && closing.length == 1 && closing[0]["number"] == Integer(ENV.fetch("ISSUE")) && closing[0]["url"] == "https://github.com/#{ENV.fetch("REPO")}/issues/#{ENV.fetch("ISSUE")}" && closing_repository.is_a?(Hash) && closing_repository["name"] == target_name && closing_repository.dig("owner", "login") == target_owner
  oid = pr.dig("mergeCommit", "oid"); abort unless oid.is_a?(String) && oid.match?(/\A[0-9a-f]{40}\z/); puts oid
') || fail 'persisted PR identity is open, unmerged, stale, or mismatched'
[[ "$merge_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'persisted PR merge commit is invalid'

remote_output=''
if remote_output=$(git -C "$repo_root" ls-remote --exit-code --heads origin "refs/heads/$branch" 2>/dev/null); then
  remote_sha=$(REMOTE_OUTPUT="$remote_output" BRANCH="$branch" ruby -e '
    lines = ENV.fetch("REMOTE_OUTPUT").lines.map(&:strip).reject(&:empty?); abort unless lines.length == 1
    match = lines.first.match(/\A([0-9a-f]{40})\trefs\/heads\/(.+)\z/) or abort
    abort unless match[2] == ENV.fetch("BRANCH"); puts match[1]
  ') || fail 'remote Branch lookup returned an invalid identity'
  [[ "$remote_sha" == "$head_sha" ]] || fail 'remote Branch was reused at a different Head'
  [[ -e "$worktree" && ! -L "$worktree" ]] || fail 'remote Branch still exists but exact-head worktree preflight cannot rerun'
  jq -e 'index("github.delete_branch") != null' <<<"$external_operations" >/dev/null || fail 'Issue contract does not declare github.delete_branch'
  "$worktree/tools/github-account-preflight.sh" --repo "$repo" --issue "$issue" --intended-operation github.delete_branch --expected-head "$head_sha" >/dev/null || fail 'remote Branch deletion preflight failed'
  require_origin
  refreshed=$(git -C "$repo_root" ls-remote --exit-code --heads origin "refs/heads/$branch") || fail 'remote Branch disappeared during deletion preflight'
  refreshed_sha=$(printf '%s' "$refreshed" | awk 'NF == 2 { print $1 }')
  refreshed_ref=$(printf '%s' "$refreshed" | awk 'NF == 2 { print $2 }')
  [[ "$refreshed_sha" == "$head_sha" && "$refreshed_ref" == "refs/heads/$branch" ]] || fail 'remote Branch changed during deletion preflight'
  current_identity=$(ruby "$identity_tool" validate-primary "$repo_root" "$repo" "$issue") || fail 'durable identity changed before remote Branch deletion'
  jq -e --arg branch "$branch" --arg base "$base_sha" --arg head "$head_sha" \
    --arg contract "$contract_digest" --arg primary "$primary_implementer" --argjson pr "$pull_request" '
    .state == "merged" and .branch == $branch and .baseSha == $base and .headSha == $head and
    .pullRequest == $pr and .contractDigest == $contract and .primaryImplementer == $primary and
    (.externalOperations | index("github.delete_branch") != null)
  ' <<<"$current_identity" >/dev/null || fail 'current Issue contract does not declare github.delete_branch'
  git -C "$repo_root" push --force-with-lease="refs/heads/$branch:$head_sha" origin ":refs/heads/$branch" >/dev/null || fail 'exact remote Branch deletion failed'
else
  remote_status=$?
  [[ "$remote_status" == 2 ]] || fail 'remote Branch lookup failed'
fi

if [[ -e "$worktree" || -L "$worktree" ]]; then
  [[ -d "$worktree" && ! -L "$worktree" ]] || fail 'recorded worktree became unsafe'
  git -C "$repo_root" worktree remove "$worktree" >/dev/null || fail 'exact worktree removal failed'
fi
if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
  [[ "$(git -C "$repo_root" rev-parse "refs/heads/$branch")" == "$head_sha" ]] || fail 'local Branch was recreated at a different Head'
  git -C "$repo_root" update-ref -d "refs/heads/$branch" "$head_sha" || fail 'exact local Branch deletion failed'
fi
[[ ! -e "$worktree" && ! -L "$worktree" ]] || fail 'recorded worktree still exists before reclaiming its data'
reclaim_worktree_data "$reclaim_root" || fail 'the removed worktree data was not fully reclaimed; rerun the same command to finish'
jq -cn --argjson issue "$issue" --arg branch "$branch" --argjson pullRequest "$pull_request" '{status:"cleaned",issue:$issue,branch:$branch,pullRequest:$pullRequest}'
