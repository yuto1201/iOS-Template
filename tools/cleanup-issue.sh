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
# emptied directories stay (split-lock prevention). Nothing is removed by name or age alone. Every step is
# anchored to directory descriptors opened with O_NOFOLLOW|O_DIRECTORY from the root down (openat, fstatat,
# fdopendir, unlinkat), so a renamed or substituted path never redirects a removal; the owner record or
# info.plist is validated through the same descriptor that is emptied and is removed last, so an interrupted
# removal keeps the evidence that a rerun needs. Skipped entries are reported; any failure exits non-zero and
# a rerun finishes the rest. The three roots and a step hook can be replaced only in the explicit test mode.
reclaim_worktree_data() {
  local expected_owner
  # The owner record bytes come from the same generator that tools/xcodebuild-in-worktree.sh uses.
  expected_owner=$(ruby --disable-gems -rjson -e 'print %({"schemaVersion":1,"worktree":#{ARGV.fetch(0).to_json}})' "$1") || return 1
  /usr/bin/python3 -I - "$1" "$expected_owner" <<'PY'
import errno, fcntl, hashlib, os, pwd, re, stat, subprocess, sys

UID = os.getuid()
DIRECTORY_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY | os.O_CLOEXEC
TEST_MODE = os.environ.get("IOS_TEMPLATE_TEST_MODE") == "1"
HOOK = os.environ.get("IOS_TEMPLATE_TEST_RECLAIM_HOOK") if TEST_MODE else None
counts = {"removed": 0, "skipped": 0, "failed": 0}


class ReclaimError(Exception):
    pass


def report(message):
    sys.stderr.write("cleanup reclaim: %s\n" % message)


def skip(path, reason):
    counts["skipped"] += 1
    report("skipped %s (%s)" % (path, reason))


def failure(path, error):
    counts["failed"] += 1
    report("failed %s: %s" % (path, error))


def hook(step, path):
    if HOOK:
        subprocess.run([HOOK, step, path], check=True)


def stat_at(parent, name):
    try:
        return os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return None


def owned_directory(info):
    return info is not None and stat.S_ISDIR(info.st_mode) and info.st_uid == UID


def same_identity(left, right):
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def open_directory_at(parent, name):
    before = stat_at(parent, name)
    if not owned_directory(before):
        raise ReclaimError("%s is not a directory owned by this user" % name)
    descriptor = os.open(name, DIRECTORY_FLAGS, dir_fd=parent)
    bound = os.fstat(descriptor)
    if not (owned_directory(bound) and same_identity(before, bound)):
        os.close(descriptor)
        raise ReclaimError("%s changed while it was opened" % name)
    return descriptor


def still_at(parent, name, descriptor, path):
    now = stat_at(parent, name)
    if not (owned_directory(now) and same_identity(now, os.fstat(descriptor))):
        raise ReclaimError("%s changed during the reclaim" % path)


def read_regular_at(parent, name, limit):
    """Returns the bytes of a single-link regular file owned by this user, or None when it is absent or unsafe."""
    before = stat_at(parent, name)
    if before is None or not stat.S_ISREG(before.st_mode) or before.st_uid != UID or before.st_nlink != 1 or before.st_size > limit:
        return None
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
    except OSError:
        return None
    try:
        bound = os.fstat(descriptor)
        if not (stat.S_ISREG(bound.st_mode) and same_identity(before, bound) and bound.st_nlink == 1):
            return None
        data = os.read(descriptor, limit + 1)
        return data if len(data) == bound.st_size else None
    finally:
        os.close(descriptor)


def remove_child(parent, name, path):
    info = stat_at(parent, name)
    if info is None:
        raise ReclaimError("%s disappeared during the reclaim" % path)
    if info.st_uid != UID:
        raise ReclaimError("%s is not owned by this user" % path)
    if stat.S_ISDIR(info.st_mode):
        descriptor = open_directory_at(parent, name)
        try:
            empty_directory(descriptor, path)
            still_at(parent, name, descriptor, path)
        finally:
            os.close(descriptor)
        os.rmdir(name, dir_fd=parent)
    else:
        os.unlink(name, dir_fd=parent)


def empty_directory(descriptor, path, last=None):
    """Empties the directory behind the descriptor; `last` (the ownership evidence) goes only after the rest."""
    info = os.fstat(descriptor)
    if not owned_directory(info):
        raise ReclaimError("%s is not a directory owned by this user" % path)
    # Xcode keeps read-only package checkouts, so the owner regains write access through the descriptor.
    os.fchmod(descriptor, 0o700)
    # Test mode can substitute the path here, between opening and enumeration, to prove nothing follows it.
    hook("opened", path)
    names = sorted(os.listdir(descriptor))
    for name in names:
        if name != last:
            remove_child(descriptor, name, "%s/%s" % (path, name))
    remaining = os.listdir(descriptor)
    if any(name != last for name in remaining):
        raise ReclaimError("%s gained entries during the reclaim" % path)
    if last is not None and last in remaining:
        os.unlink(last, dir_fd=descriptor)


def reclaim(parent, name, descriptor, path, last=None):
    """Removes one validated entry through the descriptor that was validated."""
    try:
        empty_directory(descriptor, path, last)
        still_at(parent, name, descriptor, path)
        os.rmdir(name, dir_fd=parent)
        counts["removed"] += 1
        report("removed %s" % path)
    except Exception as error:  # noqa: BLE001 - every failure is reported and makes the cleanup fail
        failure(path, error)


def open_root(path):
    """Opens a root directory (its own last component never a symbolic link), or returns None when absent."""
    try:
        parent = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    except FileNotFoundError:
        return None
    try:
        if stat_at(parent, os.path.basename(path)) is None:
            return None
        return open_directory_at(parent, os.path.basename(path))
    finally:
        os.close(parent)


def canonical_components(value):
    """Splits an absolute path without empty, `.` or `..` components; returns None for anything else."""
    if not value.startswith(b"/") or b"\0" in value:
        return None
    parts = value.split(b"/")[1:]
    if not parts or any(part in (b"", b".", b"..") for part in parts):
        return None
    return parts


root = sys.argv[1]
expected_owner = os.fsencode(sys.argv[2]) + b"\n"
root_bytes = os.fsencode(root)
root_parts = canonical_components(root_bytes)
if root_parts is None or len(root_parts) < 2:
    sys.exit("cleanup reclaim: the worktree root is not a canonical absolute path")
if os.path.lexists(root):
    sys.exit("cleanup reclaim: the worktree still exists")
if os.path.realpath(os.path.dirname(root)) != os.path.dirname(root):
    sys.exit("cleanup reclaim: the worktree parent is not physical")
worktree_id = "%s-%s" % (re.sub(r"[^A-Za-z0-9_.-]", "-", os.path.basename(root)), hashlib.sha256(root_bytes).hexdigest())
if TEST_MODE:
    roots = [os.environ.get(name, "") for name in ("IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT", "IOS_TEMPLATE_TEST_XCODE_DERIVED_DATA_ROOT", "IOS_TEMPLATE_TEST_VERIFY_ROOT")]
    if not all(path.startswith("/") for path in roots):
        sys.exit("cleanup reclaim: test mode needs three absolute roots")
    fixed_root, xcode_root, verify_root = roots
else:
    home = pwd.getpwuid(UID).pw_dir
    fixed_root = os.path.join(home, "Library", "Caches", "ios-template", "derived-data")
    xcode_root = os.path.join(home, "Library", "Developer", "Xcode", "DerivedData")
    verify_root = "/tmp/ios-template-verify"

# 1. The fixed DerivedData of tools/xcodebuild-in-worktree.sh, only with the exact owner record.
try:
    fixed = open_root(fixed_root)
    if fixed is not None:
        try:
            path = os.path.join(fixed_root, worktree_id)
            info = stat_at(fixed, worktree_id)
            if info is not None and not owned_directory(info):
                skip(path, "not a directory owned by this user")
            elif info is not None:
                entry = open_directory_at(fixed, worktree_id)
                try:
                    if stat_at(entry, "owner.json") is None:
                        # The owner record is removed last, so only an emptied directory may lack it.
                        if os.listdir(entry):
                            failure(path, "it holds data without an owner record, so its ownership cannot be proved")
                        else:
                            reclaim(fixed, worktree_id, entry, path)
                    elif read_regular_at(entry, "owner.json", 65536) == expected_owner:
                        reclaim(fixed, worktree_id, entry, path, last="owner.json")
                    else:
                        skip(path, "its owner record does not name this worktree")
                finally:
                    os.close(entry)
        finally:
            os.close(fixed)
except Exception as error:  # noqa: BLE001
    failure(fixed_root, error)

# 2. Xcode default DerivedData whose info.plist WorkspacePath is inside the removed worktree.
try:
    xcode = open_root(xcode_root)
    if xcode is not None:
        try:
            for name in sorted(os.listdir(xcode)):
                path = os.path.join(xcode_root, name)
                try:
                    if not owned_directory(stat_at(xcode, name)):
                        continue
                    entry = open_directory_at(xcode, name)
                    try:
                        data = read_regular_at(entry, "info.plist", 1048576)
                        if data is None:
                            continue
                        result = subprocess.run(["/usr/bin/plutil", "-extract", "WorkspacePath", "raw", "-o", "-", "-"],
                                                input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                        if result.returncode != 0:
                            continue
                        workspace = result.stdout[:-1] if result.stdout.endswith(b"\n") else result.stdout
                        parts = canonical_components(workspace)
                        if parts is None:
                            if workspace.startswith(root_bytes):
                                skip(path, "its WorkspacePath is not a canonical absolute path")
                            continue
                        if parts[:len(root_parts)] != root_parts:
                            continue
                        reclaim(xcode, name, entry, path, last="info.plist")
                    finally:
                        os.close(entry)
                except Exception as error:  # noqa: BLE001
                    failure(path, error)
        finally:
            os.close(xcode)
except Exception as error:  # noqa: BLE001
    failure(xcode_root, error)

# 3. Retained/ and leftover Attempts/ of each verify Head whose .verify.lock is free right now.
try:
    verify = open_root(verify_root)
    if verify is not None:
        try:
            worktree_path = os.path.join(verify_root, worktree_id)
            info = stat_at(verify, worktree_id)
            if info is not None and not owned_directory(info):
                skip(worktree_path, "not a directory owned by this user")
            elif info is not None:
                worktree = open_directory_at(verify, worktree_id)
                try:
                    for issue_name in sorted(os.listdir(worktree)):
                        issue_path = os.path.join(worktree_path, issue_name)
                        if not (re.fullmatch(r"issue-[1-9][0-9]*", issue_name) and owned_directory(stat_at(worktree, issue_name))):
                            skip(issue_path, "not an Issue directory")
                            continue
                        issue = open_directory_at(worktree, issue_name)
                        try:
                            for head_name in sorted(os.listdir(issue)):
                                head_path = os.path.join(issue_path, head_name)
                                if not (re.fullmatch(r"[0-9a-f]{40}", head_name) and owned_directory(stat_at(issue, head_name))):
                                    skip(head_path, "not a Head directory")
                                    continue
                                head = lock = None
                                try:
                                    head = open_directory_at(issue, head_name)
                                    lock_info = stat_at(head, ".verify.lock")
                                    if lock_info is None or not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != UID or lock_info.st_nlink != 1:
                                        skip(head_path, "no usable .verify.lock")
                                        continue
                                    lock = os.open(".verify.lock", os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=head)
                                    try:
                                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                                    except BlockingIOError:
                                        skip(head_path, "its verification lock is held")
                                        continue
                                    locked = os.fstat(lock)
                                    current = stat_at(head, ".verify.lock")
                                    if not (stat.S_ISREG(locked.st_mode) and locked.st_nlink == 1 and current is not None and same_identity(current, locked)):
                                        raise ReclaimError("%s/.verify.lock changed while it was locked" % head_path)
                                    for area_name in ("Retained", "Attempts"):
                                        area_path = os.path.join(head_path, area_name)
                                        area_info = stat_at(head, area_name)
                                        if area_info is None:
                                            continue
                                        if not owned_directory(area_info):
                                            skip(area_path, "not a directory owned by this user")
                                            continue
                                        area = open_directory_at(head, area_name)
                                        try:
                                            for name in sorted(os.listdir(area)):
                                                path = os.path.join(area_path, name)
                                                if not owned_directory(stat_at(area, name)):
                                                    skip(path, "not a directory owned by this user")
                                                    continue
                                                try:
                                                    entry = open_directory_at(area, name)
                                                except Exception as error:  # noqa: BLE001
                                                    failure(path, error)
                                                    continue
                                                try:
                                                    reclaim(area, name, entry, path)
                                                finally:
                                                    os.close(entry)
                                        finally:
                                            os.close(area)
                                except Exception as error:  # noqa: BLE001
                                    failure(head_path, error)
                                finally:
                                    if lock is not None:
                                        os.close(lock)
                                    if head is not None:
                                        os.close(head)
                        finally:
                            os.close(issue)
                finally:
                    os.close(worktree)
        finally:
            os.close(verify)
except Exception as error:  # noqa: BLE001
    failure(verify_root, error)

report("removed=%d skipped=%d failed=%d" % (counts["removed"], counts["skipped"], counts["failed"]))
sys.exit(1 if counts["failed"] else 0)
PY
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
