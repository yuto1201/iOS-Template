#!/usr/bin/env bash
set -euo pipefail

source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-cleanup.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
repo_name='yuto1201/iOS-Template'; issue=42; branch='codex/42-cleanup-safety'; worktree_relative='.worktrees/42-cleanup-safety'; pr=57; merge_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

fail_test() { echo "FAIL: $*" >&2; exit 1; }
assert_fails() { local label=$1; shift; if "$@" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"; then fail_test "expected failure: $label"; fi; }
assert_no_mutation() { [[ ! -s "$CASE_MUTATIONS" ]] || { cat "$CASE_MUTATIONS" >&2; fail_test "$1 performed a mutation"; }; }

make_case() {
  local name=$1
  CASE_ROOT="$scratch/$name"; CASE_PRIMARY="$CASE_ROOT/repo"; CASE_REMOTE="$CASE_ROOT/remote.git"; CASE_WORKTREE="$CASE_PRIMARY/$worktree_relative"
  CASE_BIN="$CASE_ROOT/bin"; CASE_LOG="$CASE_ROOT/operations.log"; CASE_MUTATIONS="$CASE_ROOT/mutations.log"
  mkdir -p "$CASE_ROOT" "$CASE_BIN"
  git init --bare "$CASE_REMOTE" >/dev/null
  git init -b main "$CASE_PRIMARY" >/dev/null
  git -C "$CASE_PRIMARY" config user.name Fixture; git -C "$CASE_PRIMARY" config user.email fixture@example.invalid
  printf 'base\n' >"$CASE_PRIMARY/README.md"; git -C "$CASE_PRIMARY" add README.md; git -C "$CASE_PRIMARY" commit -m base >/dev/null
  CASE_BASE=$(git -C "$CASE_PRIMARY" rev-parse HEAD)
  git -C "$CASE_PRIMARY" remote add origin "$CASE_REMOTE"; git -C "$CASE_PRIMARY" push origin main >/dev/null
  mkdir -p "$CASE_PRIMARY/.worktrees"; git -C "$CASE_PRIMARY" worktree add -b "$branch" "$CASE_WORKTREE" main >/dev/null
  mkdir -p "$CASE_PRIMARY/tools/lib" "$CASE_WORKTREE/tools" "$CASE_PRIMARY/.artifacts/issues/$issue"
  cp "$source_root/tools/cleanup-issue.sh" "$CASE_PRIMARY/tools/"
  cp "$source_root/tools/lib/merge-state.rb" "$source_root/tools/lib/descriptor-files.rb" "$source_root/tools/lib/issue-contract.rb" "$CASE_PRIMARY/tools/lib/"
  cat >"$CASE_PRIMARY/tools/github-account-preflight.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'preflight-primary %s\n' "$*" >>"${FAKE_LOG:?}"
EOF
  cat >"$CASE_WORKTREE/tools/github-account-preflight.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'preflight-worktree %s\n' "$*" >>"${FAKE_LOG:?}"
EOF
  chmod +x "$CASE_PRIMARY/tools/"*.sh "$CASE_PRIMARY/tools/lib/merge-state.rb" "$CASE_WORKTREE/tools/"*.sh
  printf 'issue work\n' >"$CASE_WORKTREE/issue.md"; git -C "$CASE_WORKTREE" add issue.md tools; git -C "$CASE_WORKTREE" commit -m issue >/dev/null
  CASE_HEAD=$(git -C "$CASE_WORKTREE" rev-parse HEAD); git -C "$CASE_WORKTREE" push origin "$branch" >/dev/null
  ln -s ../../.artifacts "$CASE_WORKTREE/.artifacts"; printf '.artifacts\n' >>"$(git -C "$CASE_WORKTREE" rev-parse --git-path info/exclude)"
  CONTRACT="$CASE_PRIMARY/.artifacts/issues/$issue/issue-contract.json" ruby -rjson -rdigest -e 'details=[{"operation"=>"github.delete_branch","service"=>"GitHub","environment"=>"production","executor"=>"Codex","approvalRequired"=>false,"approvalReference"=>nil}]; def c(v); v.is_a?(Hash) ? v.keys.sort.to_h{|k|[k,c(v[k])]} : v.is_a?(Array) ? v.map{|e|c(e)} : v; end; digest="sha256:#{Digest::SHA256.hexdigest(JSON.generate(c(details)))}"; File.binwrite(ENV.fetch("CONTRACT"),JSON.generate({"schemaVersion"=>1,"issue"=>42,"repository"=>"yuto1201/iOS-Template","goal"=>"Clean exact merged work.","specAnchors"=>["docs/workflow.md"],"acceptanceCriteria"=>[{"id"=>"AC-1","text"=>"Clean safely."}],"dependencies"=>[],"externalOperations"=>["github.delete_branch"],"externalOperationDetailsDigest"=>digest,"fetchedAt"=>"2026-08-24T00:00:00Z"}))'
  CASE_DIGEST="sha256:$(shasum -a 256 "$CASE_PRIMARY/.artifacts/issues/$issue/issue-contract.json" | awk '{print $1}')"
  STATE="$CASE_PRIMARY/.artifacts/issues/$issue/state.json" HEAD="$CASE_HEAD" BASE="$CASE_BASE" DIGEST="$CASE_DIGEST" ruby -rjson -e 'value={"schemaVersion"=>1,"issue"=>42,"repository"=>"yuto1201/iOS-Template","branch"=>"codex/42-cleanup-safety","worktree"=>".worktrees/42-cleanup-safety","baseSha"=>ENV.fetch("BASE"),"primaryImplementer"=>"codex","issueContract"=>{"path"=>".artifacts/issues/42/issue-contract.json","digest"=>ENV.fetch("DIGEST")},"state"=>"merged","previousState"=>"approved-for-merge","resumeState"=>nil,"executor"=>"codex","headSha"=>ENV.fetch("HEAD"),"pullRequest"=>57,"from"=>"approved-for-merge","to"=>"merged","transitionedAt"=>"2026-08-24T00:03:00Z"};File.binwrite(ENV.fetch("STATE"),JSON.generate(value))'
  : >"$CASE_LOG"; : >"$CASE_MUTATIONS"
  cat >"$CASE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"${FAKE_LOG:?}"
fields='number,state,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,closingIssuesReferences,mergeCommit,url'
[[ "$*" == "pr view ${FAKE_PR:?} --repo ${FAKE_REPO:?} --json $fields" ]] || { echo 'unexpected gh' >&2; exit 2; }
ruby -rjson -e 'state=ENV.fetch("FAKE_PR_STATE"); repo=ENV.fetch("FAKE_REPO"); source=ENV.fetch("FAKE_SOURCE_REPO",repo); issue=Integer(ENV.fetch("FAKE_CLOSING_ISSUE",ENV.fetch("FAKE_ISSUE"))); puts JSON.generate({"number"=>Integer(ENV.fetch("FAKE_PR_NUMBER",ENV.fetch("FAKE_PR"))),"state"=>state,"baseRefName"=>ENV.fetch("FAKE_BASE_REF","main"),"headRefName"=>ENV.fetch("FAKE_BRANCH"),"headRefOid"=>ENV.fetch("FAKE_PR_HEAD",ENV.fetch("FAKE_HEAD")),"headRepository"=>{"nameWithOwner"=>source},"headRepositoryOwner"=>{"login"=>source.split("/",2).first},"isCrossRepository"=>ENV.fetch("FAKE_CROSS_REPO","false")=="true","closingIssuesReferences"=>[{"number"=>issue,"url"=>"https://github.com/#{repo}/issues/#{issue}","repository"=>{"nameWithOwner"=>repo}}],"mergeCommit"=>ENV.fetch("FAKE_MERGE")=="null" ? nil : {"oid"=>ENV.fetch("FAKE_MERGE")},"url"=>ENV.fetch("FAKE_PR_URL","https://github.com/#{repo}/pull/#{ENV.fetch("FAKE_PR")}")})'
EOF
  chmod +x "$CASE_BIN/gh"
  REAL_GIT=$(command -v git)
  cat >"$CASE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "-C ${FAKE_PRIMARY:?} remote get-url origin" ]]; then printf 'https://github.com/%s.git\n' "${FAKE_REPO:?}"; exit 0; fi
if [[ "$*" == *' ls-remote --exit-code --heads origin '* ]]; then printf 'git %s\n' "$*" >>"${FAKE_LOG:?}"; fi
if [[ "$*" == *' push --force-with-lease='* ]]; then printf 'remote-delete\n' >>"${FAKE_MUTATIONS:?}"; printf 'git %s\n' "$*" >>"${FAKE_LOG:?}"; [[ "${FAIL_STEP:-}" != remote-delete ]] || exit 42; fi
if [[ "$*" == *' worktree remove '* ]]; then printf 'worktree-remove\n' >>"${FAKE_MUTATIONS:?}"; printf 'git %s\n' "$*" >>"${FAKE_LOG:?}"; [[ "${FAIL_STEP:-}" != worktree-remove ]] || exit 43; fi
if [[ "$*" == *' update-ref -d '* ]]; then printf 'local-delete\n' >>"${FAKE_MUTATIONS:?}"; printf 'git %s\n' "$*" >>"${FAKE_LOG:?}"; [[ "${FAIL_STEP:-}" != local-delete ]] || exit 44; fi
exec "${REAL_GIT:?}" "$@"
EOF
  chmod +x "$CASE_BIN/git"
}

run_cleanup() {
  env PATH="$CASE_BIN:$PATH" REAL_GIT="$REAL_GIT" FAKE_PRIMARY="$CASE_PRIMARY" FAKE_REPO="$repo_name" FAKE_ISSUE="$issue" FAKE_PR="$pr" FAKE_PR_NUMBER="${FAKE_PR_NUMBER:-$pr}" FAKE_PR_STATE="${FAKE_PR_STATE:-MERGED}" FAKE_BASE_REF="${FAKE_BASE_REF:-main}" FAKE_BRANCH="$branch" FAKE_HEAD="$CASE_HEAD" FAKE_PR_HEAD="${FAKE_PR_HEAD:-$CASE_HEAD}" FAKE_SOURCE_REPO="${FAKE_SOURCE_REPO:-$repo_name}" FAKE_CROSS_REPO="${FAKE_CROSS_REPO:-false}" FAKE_CLOSING_ISSUE="${FAKE_CLOSING_ISSUE:-$issue}" FAKE_MERGE="${FAKE_MERGE:-$merge_sha}" FAKE_PR_URL="${FAKE_PR_URL:-https://github.com/$repo_name/pull/$pr}" FAKE_LOG="$CASE_LOG" FAKE_MUTATIONS="$CASE_MUTATIONS" FAIL_STEP="${FAIL_STEP:-}" "$CASE_PRIMARY/tools/cleanup-issue.sh" --repo "$repo_name" --issue "$issue"
}

make_case open-pr
FAKE_PR_STATE=OPEN assert_fails 'open persisted PR' run_cleanup
assert_no_mutation 'open PR mismatch'

make_case wrong-pr-head
FAKE_PR_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb assert_fails 'stale exact PR Head' run_cleanup
assert_no_mutation 'stale PR Head'

make_case foreign-fork
FAKE_SOURCE_REPO='foreign/project' FAKE_CROSS_REPO=true assert_fails 'foreign-fork persisted PR' run_cleanup
assert_no_mutation 'foreign-fork persisted PR'

make_case wrong-closing-issue
FAKE_CLOSING_ISSUE=43 assert_fails 'persisted PR closes wrong Issue' run_cleanup
assert_no_mutation 'persisted PR wrong closing Issue'

make_case missing-pr
ruby -rjson -e 'p=ARGV[0];v=JSON.parse(File.binread(p));v.delete("pullRequest");File.binwrite(p,JSON.generate(v))' "$CASE_PRIMARY/.artifacts/issues/42/state.json"
assert_fails 'missing persisted PR' run_cleanup
[[ ! -s "$CASE_LOG" ]] || fail_test 'missing PR reached external calls'
assert_no_mutation 'missing PR'

make_case hardlinked-state
ln "$CASE_PRIMARY/.artifacts/issues/42/state.json" "$CASE_PRIMARY/.artifacts/issues/42/state.link"
assert_fails 'hardlinked state' run_cleanup
[[ ! -s "$CASE_LOG" ]] || fail_test 'hardlinked state reached external calls'
assert_no_mutation 'hardlinked state'

make_case dangling-worktree
git -C "$CASE_PRIMARY" worktree remove "$CASE_WORKTREE" >/dev/null
ln -s "$CASE_ROOT/missing" "$CASE_WORKTREE"
assert_fails 'dangling worktree path' run_cleanup
[[ ! -s "$CASE_LOG" ]] || fail_test 'dangling worktree reached external calls'
assert_no_mutation 'dangling worktree'

make_case absent-worktree-remote-present
git -C "$CASE_PRIMARY" worktree remove "$CASE_WORKTREE" >/dev/null
assert_fails 'remote exists without exact-head worktree preflight' run_cleanup
assert_no_mutation 'absent worktree with remote Branch'

make_case remote-reused
git -C "$CASE_REMOTE" update-ref "refs/heads/$branch" "$CASE_BASE"
assert_fails 'remote Branch reused at another SHA' run_cleanup
assert_no_mutation 'reused remote Branch'

make_case missing-delete-declaration
ruby -rjson -rdigest -e 'contract_path,state_path=ARGV; value=JSON.parse(File.binread(contract_path)); value["externalOperations"]=[]; value["externalOperationDetailsDigest"]="sha256:#{Digest::SHA256.hexdigest("[]")}"; File.binwrite(contract_path,JSON.generate(value)); state=JSON.parse(File.binread(state_path)); state["issueContract"]["digest"]="sha256:#{Digest::SHA256.file(contract_path).hexdigest}"; File.binwrite(state_path,JSON.generate(state))' "$CASE_PRIMARY/.artifacts/issues/42/issue-contract.json" "$CASE_PRIMARY/.artifacts/issues/42/state.json"
assert_fails 'missing delete declaration before remote delete' run_cleanup
assert_no_mutation 'missing delete declaration'

make_case retry
FAIL_STEP=remote-delete assert_fails 'remote deletion interruption' run_cleanup
git -C "$CASE_PRIMARY" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null || fail_test 'remote changed after failed lease deletion'
: >"$CASE_MUTATIONS"
FAIL_STEP=worktree-remove assert_fails 'worktree removal interruption' run_cleanup
if git -C "$CASE_PRIMARY" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1; then fail_test 'remote survived successful retry deletion'; fi
[[ -d "$CASE_WORKTREE" ]] || fail_test 'worktree vanished after injected failure'
: >"$CASE_MUTATIONS"
FAIL_STEP=local-delete assert_fails 'local ref deletion interruption' run_cleanup
[[ ! -e "$CASE_WORKTREE" && ! -L "$CASE_WORKTREE" ]] || fail_test 'worktree survived successful retry removal'
git -C "$CASE_PRIMARY" show-ref --verify --quiet "refs/heads/$branch" || fail_test 'local ref vanished after injected failure'
: >"$CASE_MUTATIONS"
if ! run_cleanup >"$CASE_ROOT/result.json" 2>"$CASE_ROOT/final.err"; then cat "$CASE_ROOT/final.err" >&2; fail_test 'final cleanup retry failed'; fi
jq -e '.status=="cleaned" and .pullRequest==57' "$CASE_ROOT/result.json" >/dev/null
if git -C "$CASE_PRIMARY" show-ref --verify --quiet "refs/heads/$branch"; then fail_test 'local Branch was not deleted'; fi
if ! run_cleanup >"$CASE_ROOT/retry-result.json" 2>"$CASE_ROOT/idempotent.err"; then cat "$CASE_ROOT/idempotent.err" >&2; fail_test 'idempotent cleanup retry failed'; fi
jq -e '.status=="cleaned"' "$CASE_ROOT/retry-result.json" >/dev/null

echo 'PASS: cleanup binds the exact persisted merged PR and Head, rejects reused targets, and resumes each deletion boundary'
