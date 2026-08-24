#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-cleanup.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

remote="$scratch/remote.git"
repo="$scratch/repo"
git init --bare "$remote" >/dev/null
git init -b main "$repo" >/dev/null
git -C "$repo" config user.name 'Cleanup Fixture'
git -C "$repo" config user.email 'cleanup-fixture@example.invalid'
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -m 'base' >/dev/null
git -C "$repo" remote add origin "$remote"
git -C "$repo" push origin main >/dev/null

branch='codex/42-cleanup-safety'
worktree="$repo/.worktrees/42-cleanup-safety"
git -C "$repo" worktree add -b "$branch" "$worktree" main >/dev/null
printf 'issue work\n' > "$worktree/issue.md"
git -C "$worktree" add issue.md
git -C "$worktree" commit -m 'issue work' >/dev/null
head_sha=$(git -C "$worktree" rev-parse HEAD)
git -C "$worktree" push origin "$branch" >/dev/null
git -C "$repo" worktree add -b 'codex/unrelated' "$repo/.worktrees/unrelated" main >/dev/null
ln -s ../../.artifacts "$worktree/.artifacts"

mkdir -p "$repo/.artifacts/issues/42"
HEAD="$head_sha" ruby -rjson -e 'puts JSON.generate({"schemaVersion" => 1, "issue" => 42, "repository" => "yuto1201/iOS-Template", "branch" => "codex/42-cleanup-safety", "worktree" => ".worktrees/42-cleanup-safety", "baseSha" => "0" * 40, "primaryImplementer" => "codex", "issueContract" => {"path" => ".artifacts/issues/42/issue-contract.json", "digest" => "sha256:" + "0" * 64}, "state" => "merged", "previousState" => "approved-for-merge", "resumeState" => nil, "executor" => "codex", "headSha" => ENV.fetch("HEAD")})' > "$repo/.artifacts/issues/42/state.json"

fake_bin="$scratch/bin"
mkdir "$fake_bin"
mkdir -p "$repo/tools" "$repo/Config"
cp "$repo_root/tools/cleanup-issue.sh" "$repo/tools/"
cp "$repo_root/tools/github-account-preflight.sh" "$repo/tools/"
cp -R "$repo_root/tools/lib" "$repo/tools/"
cp "$repo_root/Config/ownership.yml" "$repo/Config/"
cp -R "$repo/tools" "$worktree/"
cp -R "$repo/Config" "$worktree/"
cp "$repo_root/.gitignore" "$worktree/.gitignore"
printf '.artifacts\n' >> "$(git -C "$worktree" rev-parse --git-path info/exclude)"
git -C "$worktree" add tools Config .gitignore
git -C "$worktree" commit -m 'fixture tools' >/dev/null
head_sha=$(git -C "$worktree" rev-parse HEAD)
HEAD="$head_sha" ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.read(path)); value["headSha"] = ENV.fetch("HEAD"); File.write(path, JSON.generate(value))' "$repo/.artifacts/issues/42/state.json"
export FAKE_HEAD="$head_sha"
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
if [[ "$1 $2" == 'auth status' ]]; then
  echo 'Logged in to github.com account yuto1201 (keychain)'
  exit 0
fi
if [[ "$1 $2" == 'repo view' ]]; then
  echo '{"nameWithOwner":"yuto1201/iOS-Template","defaultBranchRef":{"name":"main"},"url":"https://github.com/yuto1201/iOS-Template"}'
  exit 0
fi
if [[ "$1 $2" == 'pr list' ]]; then
  ruby -rjson -e 'puts JSON.generate([{"number" => 57, "state" => ENV.fetch("FAKE_PR_STATE"), "headRefName" => "codex/42-cleanup-safety", "headRefOid" => ENV.fetch("FAKE_HEAD"), "mergeCommit" => ENV.fetch("FAKE_MERGE") == "null" ? nil : {"oid" => ENV.fetch("FAKE_MERGE")} }])'
  exit 0
fi
echo "unexpected gh command: $*" >&2
exit 2
EOF
chmod +x "$fake_bin/gh"
export PATH="$fake_bin:$PATH" FAKE_GH_LOG="$scratch/gh.log" FAKE_HEAD="$head_sha" FAKE_PR_STATE=MERGED FAKE_MERGE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

assert_fails() {
  local label=$1
  shift
  if "$@" >"$scratch/output" 2>&1; then
    echo "expected failure: $label" >&2
    exit 1
  fi
}

run_cleanup() {
  (cd "$worktree" && "$worktree/tools/cleanup-issue.sh" --repo yuto1201/iOS-Template --issue 42)
}
run_cleanup_primary() {
  (cd "$repo" && "$repo/tools/cleanup-issue.sh" --repo yuto1201/iOS-Template --issue 42)
}

# RED was observed before cleanup-issue.sh existed. First prove it refuses every
# non-merged or stale record without touching the Issue or unrelated worktree.
FAKE_PR_STATE=OPEN assert_fails 'open PR is refused' run_cleanup
FAKE_PR_STATE=CLOSED assert_fails 'closed unmerged PR is refused' run_cleanup
FAKE_PR_STATE=MERGED FAKE_MERGE=null assert_fails 'merged PR without merge commit is refused' run_cleanup
FAKE_PR_STATE=MERGED FAKE_MERGE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa FAKE_HEAD="$(printf '0%.0s' {1..40})" assert_fails 'stale PR Head is refused' run_cleanup
printf 'dirty\n' >> "$worktree/issue.md"
assert_fails 'dirty worktree is refused' run_cleanup
git -C "$worktree" checkout -- issue.md
run_cleanup > "$scratch/cleanup.json"
jq -e '.status == "cleaned" and .issue == 42' "$scratch/cleanup.json" >/dev/null
[[ ! -e "$worktree" && -d "$repo/.worktrees/unrelated" ]] || { echo 'cleanup affected the wrong worktree' >&2; exit 1; }
git -C "$repo" show-ref --verify --quiet refs/heads/codex/unrelated || { echo 'cleanup removed an unrelated Branch' >&2; exit 1; }
run_cleanup_primary > "$scratch/retry.json"
jq -e '.status == "cleaned" and .branch == "codex/42-cleanup-safety"' "$scratch/retry.json" >/dev/null

echo 'PASS: cleanup fixture is ready for merged confirmation, stale head, dirty worktree, and unrelated-worktree preservation cases'
