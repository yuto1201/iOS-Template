#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git jq ruby plutil shasum chflags

source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-cleanup.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
# Reclaim fixtures include read-only directories and a user-immutable file, so the trap undoes both first.
lock_holder=''
finish() {
  if [[ -n "$lock_holder" ]]; then kill "$lock_holder" 2>/dev/null || true; wait "$lock_holder" 2>/dev/null || true; fi
  chflags -R nouchg "$scratch" 2>/dev/null || true; chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf "$scratch"
}
trap finish EXIT
repo_name='yuto1201/iOS-Template'; issue=42; branch='codex/42-cleanup-safety'; worktree_relative='.worktrees/42-cleanup-safety'; pr=57; merge_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

fail_test() { echo "FAIL: $*" >&2; exit 1; }
assert_fails() { local label=$1; shift; if "$@" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"; then fail_test "expected failure: $label"; fi; }
assert_no_mutation() { [[ ! -s "$CASE_MUTATIONS" ]] || { cat "$CASE_MUTATIONS" >&2; fail_test "$1 performed a mutation"; }; }

make_case() {
  local name=$1
  CASE_ROOT="$scratch/$name"; CASE_PRIMARY="$CASE_ROOT/repo"; CASE_REMOTE="$CASE_ROOT/remote.git"; CASE_WORKTREE="$CASE_PRIMARY/$worktree_relative"
  CASE_BIN="$CASE_ROOT/bin"; CASE_LOG="$CASE_ROOT/operations.log"; CASE_MUTATIONS="$CASE_ROOT/mutations.log"
  CASE_FIXED_ROOT="$CASE_ROOT/roots/derived-data"; CASE_XCODE_ROOT="$CASE_ROOT/roots/Xcode-DerivedData"; CASE_VERIFY_ROOT="$CASE_ROOT/roots/ios-template-verify"
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
  cp "$source_root/tools/lib/merge-state.rb" "$source_root/tools/lib/descriptor-files.rb" "$source_root/tools/lib/issue-contract.rb" "$source_root/tools/lib/issue-contract-revision.rb" "$source_root/tools/lib/ownership.rb" "$source_root/tools/lib/review-artifacts.rb" "$source_root/tools/lib/workflow-release-phase.rb" "$source_root/tools/lib/delivery-stage.rb" "$source_root/tools/lib/delivery-profile.rb" "$source_root/tools/lib/verification-scope.rb" "$CASE_PRIMARY/tools/lib/"
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
  CONTRACT="$CASE_PRIMARY/.artifacts/issues/$issue/issue-contract.json" ruby -rjson -rdigest -e 'details=[{"operation"=>"github.delete_branch","service"=>"GitHub","environment"=>"production","executor"=>"Codex","approvalRequired"=>false,"approvalReference"=>nil}]; def c(v); v.is_a?(Hash) ? v.keys.sort.to_h{|k|[k,c(v[k])]} : v.is_a?(Array) ? v.map{|e|c(e)} : v; end; digest="sha256:#{Digest::SHA256.hexdigest(JSON.generate(c(details)))}"; contract={"schemaVersion"=>1,"issue"=>42,"repository"=>"yuto1201/iOS-Template","goal"=>"Clean exact merged work.","specAnchors"=>["docs/workflow.md"],"acceptanceCriteria"=>[{"id"=>"AC-1","text"=>"Clean safely."}],"dependencies"=>[],"externalOperations"=>["github.delete_branch"],"externalOperationDetailsDigest"=>digest,"fetchedAt"=>"2026-08-24T00:00:00Z"}; File.binwrite(ENV.fetch("CONTRACT"),JSON.generate(c(contract)))'
  CASE_DIGEST="sha256:$(shasum -a 256 "$CASE_PRIMARY/.artifacts/issues/$issue/issue-contract.json" | awk '{print $1}')"
  STATE="$CASE_PRIMARY/.artifacts/issues/$issue/state.json" HEAD="$CASE_HEAD" BASE="$CASE_BASE" DIGEST="$CASE_DIGEST" ruby -rjson -e 'value={"schemaVersion"=>1,"issue"=>42,"repository"=>"yuto1201/iOS-Template","branch"=>"codex/42-cleanup-safety","worktree"=>".worktrees/42-cleanup-safety","baseSha"=>ENV.fetch("BASE"),"primaryImplementer"=>"codex","issueContract"=>{"path"=>".artifacts/issues/42/issue-contract.json","digest"=>ENV.fetch("DIGEST")},"state"=>"merged","previousState"=>"approved-for-merge","resumeState"=>nil,"executor"=>"codex","headSha"=>ENV.fetch("HEAD"),"pullRequest"=>57,"from"=>"approved-for-merge","to"=>"merged","transitionedAt"=>"2026-08-24T00:03:00Z"};File.binwrite(ENV.fetch("STATE"),JSON.generate(value))'
  : >"$CASE_LOG"; : >"$CASE_MUTATIONS"
  cat >"$CASE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"${FAKE_LOG:?}"
fields='number,state,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,closingIssuesReferences,mergeCommit,url'
[[ "$*" == "pr view ${FAKE_PR:?} --repo ${FAKE_REPO:?} --json $fields" ]] || { echo 'unexpected gh' >&2; exit 2; }
ruby -rjson -e 'state=ENV.fetch("FAKE_PR_STATE"); repo=ENV.fetch("FAKE_REPO"); owner,name=repo.split("/",2); source=ENV.fetch("FAKE_SOURCE_REPO",repo); issue=Integer(ENV.fetch("FAKE_CLOSING_ISSUE",ENV.fetch("FAKE_ISSUE"))); puts JSON.generate({"number"=>Integer(ENV.fetch("FAKE_PR_NUMBER",ENV.fetch("FAKE_PR"))),"state"=>state,"baseRefName"=>ENV.fetch("FAKE_BASE_REF","main"),"headRefName"=>ENV.fetch("FAKE_BRANCH"),"headRefOid"=>ENV.fetch("FAKE_PR_HEAD",ENV.fetch("FAKE_HEAD")),"headRepository"=>{"id"=>"R_fixture","name"=>source.split("/",2).last,"nameWithOwner"=>source},"headRepositoryOwner"=>{"id"=>"U_fixture","name"=>"Fixture","login"=>source.split("/",2).first},"isCrossRepository"=>ENV.fetch("FAKE_CROSS_REPO","false")=="true","closingIssuesReferences"=>[{"id"=>"I_fixture","number"=>issue,"url"=>"https://github.com/#{repo}/issues/#{issue}","repository"=>{"id"=>"R_fixture","name"=>name,"owner"=>{"id"=>"U_fixture","login"=>owner}}}],"mergeCommit"=>ENV.fetch("FAKE_MERGE")=="null" ? nil : {"oid"=>ENV.fetch("FAKE_MERGE")},"url"=>ENV.fetch("FAKE_PR_URL","https://github.com/#{repo}/pull/#{ENV.fetch("FAKE_PR")}")})'
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
  env PATH="$CASE_BIN:$PATH" IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT="$CASE_FIXED_ROOT" IOS_TEMPLATE_TEST_XCODE_DERIVED_DATA_ROOT="$CASE_XCODE_ROOT" IOS_TEMPLATE_TEST_VERIFY_ROOT="$CASE_VERIFY_ROOT" REAL_GIT="$REAL_GIT" FAKE_PRIMARY="$CASE_PRIMARY" FAKE_REPO="$repo_name" FAKE_ISSUE="$issue" FAKE_PR="$pr" FAKE_PR_NUMBER="${FAKE_PR_NUMBER:-$pr}" FAKE_PR_STATE="${FAKE_PR_STATE:-MERGED}" FAKE_BASE_REF="${FAKE_BASE_REF:-main}" FAKE_BRANCH="$branch" FAKE_HEAD="$CASE_HEAD" FAKE_PR_HEAD="${FAKE_PR_HEAD:-$CASE_HEAD}" FAKE_SOURCE_REPO="${FAKE_SOURCE_REPO:-$repo_name}" FAKE_CROSS_REPO="${FAKE_CROSS_REPO:-false}" FAKE_CLOSING_ISSUE="${FAKE_CLOSING_ISSUE:-$issue}" FAKE_MERGE="${FAKE_MERGE:-$merge_sha}" FAKE_PR_URL="${FAKE_PR_URL:-https://github.com/$repo_name/pull/$pr}" FAKE_LOG="$CASE_LOG" FAKE_MUTATIONS="$CASE_MUTATIONS" FAIL_STEP="${FAIL_STEP:-}" "$CASE_PRIMARY/tools/cleanup-issue.sh" --repo "$repo_name" --issue "$issue"
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
ruby -rjson -rdigest -e 'contract_path,state_path=ARGV; def c(v); v.is_a?(Hash) ? v.keys.sort.to_h{|k|[k,c(v[k])]} : v.is_a?(Array) ? v.map{|e|c(e)} : v; end; value=JSON.parse(File.binread(contract_path)); value["externalOperations"]=[]; value["externalOperationDetailsDigest"]="sha256:#{Digest::SHA256.hexdigest("[]")}"; File.binwrite(contract_path,JSON.generate(c(value))); state=JSON.parse(File.binread(state_path)); state["issueContract"]["digest"]="sha256:#{Digest::SHA256.file(contract_path).hexdigest}"; File.binwrite(state_path,JSON.generate(state))' "$CASE_PRIMARY/.artifacts/issues/42/issue-contract.json" "$CASE_PRIMARY/.artifacts/issues/42/state.json"
assert_fails 'missing delete declaration before remote delete' run_cleanup
assert_no_mutation 'missing delete declaration'

make_case retry
FAIL_STEP=remote-delete assert_fails 'remote deletion interruption' run_cleanup
git -C "$CASE_PRIMARY" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null || fail_test 'remote changed after failed lease deletion'
: >"$CASE_MUTATIONS"
FAIL_STEP=worktree-remove assert_fails 'worktree removal interruption' run_cleanup
if git -C "$CASE_PRIMARY" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1; then
  cat "$CASE_ROOT/err" >&2
  fail_test 'remote survived successful retry deletion'
fi
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

# D-084 (#369): after the worktree is removed, cleanup reclaims only that worktree's build data.
worktree_id() { printf '%s-%s' "$(basename "$1" | sed 's/[^A-Za-z0-9_.-]/-/g')" "$(printf '%s' "$1" | shasum -a 256 | cut -c1-64)"; }
write_owner() { ruby -rjson -e 'File.binwrite(ARGV[0], %({"schemaVersion":1,"worktree":#{ARGV[1].to_json}}\n))' "$1" "$2"; }
write_plist() { plutil -create binary1 "$1" && plutil -insert WorkspacePath -string "$2" "$1"; }
attempt_name='attempt-0f0e0d0c-0b0a-4908-8706-050403020100'; failure_name='failure-01020304-0506-4708-890a-0b0c0d0e0f10'
head_free=1111111111111111111111111111111111111111; head_locked=2222222222222222222222222222222222222222
# Fills the three roots for one worktree root; $2 names the Xcode folder so two worktrees do not collide.
seed_worktree_data() {
  local root=$1 label=$2 id head
  id=$(worktree_id "$root")
  mkdir -p "$CASE_FIXED_ROOT/$id/DerivedData/SourcePackages/checkouts/package" "$CASE_FIXED_ROOT/$id/Results" "$CASE_FIXED_ROOT/$id/Runs" "$CASE_FIXED_ROOT/$id/Scratch"
  [[ -f "$CASE_FIXED_ROOT/$id/owner.json" ]] || write_owner "$CASE_FIXED_ROOT/$id/owner.json" "$root"
  printf 'source\n' >"$CASE_FIXED_ROOT/$id/DerivedData/SourcePackages/checkouts/package/Package.swift"
  chmod 0555 "$CASE_FIXED_ROOT/$id/DerivedData/SourcePackages/checkouts/package"
  mkdir -p "$CASE_XCODE_ROOT/TemplateApp-$label/Build/Products"; printf 'product\n' >"$CASE_XCODE_ROOT/TemplateApp-$label/Build/Products/app"
  write_plist "$CASE_XCODE_ROOT/TemplateApp-$label/info.plist" "$root/TemplateApp.xcodeproj"
  for head in "$head_free" "$head_locked"; do
    mkdir -p "$CASE_VERIFY_ROOT/$id/issue-42/$head/Retained/$failure_name/Build.xcresult" "$CASE_VERIFY_ROOT/$id/issue-42/$head/Attempts/$attempt_name/DerivedData"
    : >"$CASE_VERIFY_ROOT/$id/issue-42/$head/.verify.lock"
    printf 'log\n' >"$CASE_VERIFY_ROOT/$id/issue-42/$head/Retained/$failure_name/build.log"
    printf 'data\n' >"$CASE_VERIFY_ROOT/$id/issue-42/$head/Attempts/$attempt_name/DerivedData/info"
  done
}
reclaim_case() {
  make_case "$1"
  REMOVED_ROOT="$CASE_WORKTREE"; OTHER_ROOT="$CASE_PRIMARY/.worktrees/43-other-work"; SIBLING_ROOT="$CASE_WORKTREE-extra"
  REMOVED_ID=$(worktree_id "$REMOVED_ROOT"); OTHER_ID=$(worktree_id "$OTHER_ROOT")
  mkdir -p "$CASE_FIXED_ROOT" "$CASE_XCODE_ROOT" "$CASE_VERIFY_ROOT"
  # The real tools/xcodebuild-in-worktree.sh creates the removed worktree's fixed DerivedData and owner record,
  # so the cleanup must agree with its worktree ID and owner.json bytes.
  printf '#!/bin/bash\nexit 0\n' >"$CASE_ROOT/fake-xcodebuild"; chmod +x "$CASE_ROOT/fake-xcodebuild"
  (cd "$REMOVED_ROOT" && IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT="$CASE_FIXED_ROOT" IOS_TEMPLATE_TEST_XCODEBUILD="$CASE_ROOT/fake-xcodebuild" \
    "$source_root/tools/xcodebuild-in-worktree.sh" -scheme TemplateApp build) || fail_test 'xcodebuild-in-worktree fixture run failed'
  [[ -f "$CASE_FIXED_ROOT/$REMOVED_ID/owner.json" && -d "$CASE_FIXED_ROOT/$REMOVED_ID/DerivedData" ]] || fail_test 'fixed DerivedData was not created at the expected worktree ID'
  seed_worktree_data "$REMOVED_ROOT" removed
  seed_worktree_data "$OTHER_ROOT" other
}
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail_test "$2 survived reclaim: $1"; }
assert_present() { [[ -e "$1" || -L "$1" ]] || fail_test "$2 was removed: $1"; }

reclaim_case reclaim
# Data that must survive: another worktree, Xcode folders without info.plist or pointing elsewhere (also at a
# sibling path that only shares the prefix), symbolic links, canonical .artifacts and failure records.
mkdir -p "$CASE_XCODE_ROOT/NoInfo-abc/Logs" "$CASE_XCODE_ROOT/Elsewhere-abc/Build" "$CASE_XCODE_ROOT/Sibling-abc/Build" "$CASE_ROOT/link-target/Build"
write_plist "$CASE_XCODE_ROOT/Elsewhere-abc/info.plist" "$CASE_ROOT/user-project/App.xcodeproj"
write_plist "$CASE_XCODE_ROOT/Sibling-abc/info.plist" "$SIBLING_ROOT/TemplateApp.xcodeproj"
write_plist "$CASE_ROOT/link-target/info.plist" "$REMOVED_ROOT/TemplateApp.xcodeproj"
ln -s "$CASE_ROOT/link-target" "$CASE_XCODE_ROOT/Linked-abc"
mkdir -p "$CASE_ROOT/plist-source"; write_plist "$CASE_ROOT/plist-source/info.plist" "$REMOVED_ROOT/TemplateApp.xcodeproj"
mkdir -p "$CASE_XCODE_ROOT/LinkedPlist-abc/Build"; ln -s "$CASE_ROOT/plist-source/info.plist" "$CASE_XCODE_ROOT/LinkedPlist-abc/info.plist"
mkdir -p "$CASE_ROOT/retained-target/kept"; ln -s "$CASE_ROOT/retained-target" "$CASE_VERIFY_ROOT/$REMOVED_ID/issue-42/$head_free/Retained/failure-link"
printf 'note\n' >"$CASE_VERIFY_ROOT/$REMOVED_ID/issue-42/$head_free/Attempts/stray-file"
printf '{}\n' >"$CASE_VERIFY_ROOT/$OTHER_ID/issue-42/$head_free/.artifacts"
mkdir -p "$CASE_PRIMARY/.artifacts/issues/42/$head_free/failures"; printf '{}\n' >"$CASE_PRIMARY/.artifacts/issues/42/$head_free/failures/failure-x.json"
# A held .verify.lock is skipped and reported; a user-immutable file makes one reclaim fail on the first run.
ruby -e 'file = File.open(ARGV[0], "r+"); file.flock(File::LOCK_EX); File.write(ARGV[1], "locked\n"); sleep 120' "$CASE_VERIFY_ROOT/$REMOVED_ID/issue-42/$head_locked/.verify.lock" "$CASE_ROOT/lock-ready" &
lock_holder=$!
for _ in $(seq 1 100); do [[ -s "$CASE_ROOT/lock-ready" ]] && break; sleep 0.1; done
[[ -s "$CASE_ROOT/lock-ready" ]] || fail_test 'lock holder did not start'
chflags uchg "$CASE_VERIFY_ROOT/$REMOVED_ID/issue-42/$head_free/Attempts/$attempt_name/DerivedData/info"
removed_verify="$CASE_VERIFY_ROOT/$REMOVED_ID/issue-42"
assert_fails 'injected reclaim failure' run_cleanup
[[ ! -s "$CASE_ROOT/out" ]] || fail_test 'failed reclaim still reported cleaned'
grep -Fq 'rerun the same command' "$CASE_ROOT/err" || { cat "$CASE_ROOT/err" >&2; fail_test 'failed reclaim did not explain the rerun'; }
grep -Fq "skipped $removed_verify/$head_locked (its verification lock is held)" "$CASE_ROOT/err" || { cat "$CASE_ROOT/err" >&2; fail_test 'held lock was not reported'; }
grep -Fq "failed $removed_verify/$head_free/Attempts/$attempt_name" "$CASE_ROOT/err" || { cat "$CASE_ROOT/err" >&2; fail_test 'reclaim failure was not reported'; }
assert_absent "$CASE_WORKTREE" 'removed worktree'
assert_absent "$CASE_FIXED_ROOT/$REMOVED_ID" 'fixed DerivedData of the removed worktree'
assert_absent "$CASE_XCODE_ROOT/TemplateApp-removed" 'Xcode DerivedData of the removed worktree'
assert_absent "$removed_verify/$head_free/Retained/$failure_name" 'Retained of a free Head'
assert_present "$removed_verify/$head_free/Attempts/$attempt_name/DerivedData/info" 'immutable attempt item'
assert_present "$removed_verify/$head_locked/Retained/$failure_name/build.log" 'Retained of a locked Head'
assert_present "$removed_verify/$head_locked/Attempts/$attempt_name/DerivedData/info" 'Attempts of a locked Head'
chflags nouchg "$removed_verify/$head_free/Attempts/$attempt_name/DerivedData/info"
kill "$lock_holder"; wait "$lock_holder" 2>/dev/null || true; lock_holder=''
: >"$CASE_MUTATIONS"
if ! run_cleanup >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"; then cat "$CASE_ROOT/err" >&2; fail_test 'reclaim rerun failed'; fi
jq -e '.status=="cleaned" and .pullRequest==57' "$CASE_ROOT/out" >/dev/null || fail_test 'reclaim rerun did not report cleaned'
assert_no_mutation 'reclaim rerun'
for head in "$head_free" "$head_locked"; do
  assert_absent "$removed_verify/$head/Retained/$failure_name" 'Retained of the removed worktree'
  assert_absent "$removed_verify/$head/Attempts/$attempt_name" 'Attempts of the removed worktree'
  [[ -f "$removed_verify/$head/.verify.lock" && -d "$removed_verify/$head/Retained" && -d "$removed_verify/$head/Attempts" ]] || fail_test '.verify.lock or emptied directories were removed'
done
assert_present "$removed_verify/$head_free/Retained/failure-link" 'symbolic link in Retained'
assert_present "$CASE_ROOT/retained-target/kept" 'symbolic link target'
assert_present "$removed_verify/$head_free/Attempts/stray-file" 'regular file in Attempts'
for path in "$CASE_FIXED_ROOT/$OTHER_ID/owner.json" "$CASE_FIXED_ROOT/$OTHER_ID/DerivedData/SourcePackages/checkouts/package/Package.swift" \
  "$CASE_XCODE_ROOT/TemplateApp-other/Build/Products/app" "$CASE_XCODE_ROOT/NoInfo-abc/Logs" "$CASE_XCODE_ROOT/Elsewhere-abc/info.plist" \
  "$CASE_XCODE_ROOT/Sibling-abc/info.plist" "$CASE_XCODE_ROOT/Linked-abc" "$CASE_ROOT/link-target/info.plist" "$CASE_XCODE_ROOT/LinkedPlist-abc/Build" \
  "$CASE_VERIFY_ROOT/$OTHER_ID/issue-42/$head_free/Retained/$failure_name/build.log" "$CASE_VERIFY_ROOT/$OTHER_ID/issue-42/$head_locked/Attempts/$attempt_name/DerivedData/info" \
  "$CASE_VERIFY_ROOT/$OTHER_ID/issue-42/$head_free/.artifacts" "$CASE_PRIMARY/.artifacts/issues/42/$head_free/failures/failure-x.json"; do
  assert_present "$path" 'data outside the removed worktree'
done
if ! run_cleanup >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"; then cat "$CASE_ROOT/err" >&2; fail_test 'idempotent reclaim rerun failed'; fi

# An entry at the removed worktree's ID whose owner record names another worktree, and a verify worktree
# directory that is a symbolic link, are both left alone.
make_case reclaim-guard
REMOVED_ID=$(worktree_id "$CASE_WORKTREE")
mkdir -p "$CASE_FIXED_ROOT/$REMOVED_ID/DerivedData" "$CASE_VERIFY_ROOT" "$CASE_XCODE_ROOT" "$CASE_ROOT/verify-target/issue-42/$head_free/Retained/$failure_name"
write_owner "$CASE_FIXED_ROOT/$REMOVED_ID/owner.json" "$CASE_PRIMARY/.worktrees/43-other-work"
: >"$CASE_ROOT/verify-target/issue-42/$head_free/.verify.lock"
ln -s "$CASE_ROOT/verify-target" "$CASE_VERIFY_ROOT/$REMOVED_ID"
if ! run_cleanup >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"; then cat "$CASE_ROOT/err" >&2; fail_test 'guarded reclaim failed'; fi
assert_present "$CASE_FIXED_ROOT/$REMOVED_ID/DerivedData" 'foreign-marked fixed DerivedData'
assert_present "$CASE_ROOT/verify-target/issue-42/$head_free/Retained/$failure_name" 'symbolic-link verify worktree target'
grep -Fq "skipped $CASE_FIXED_ROOT/$REMOVED_ID (its owner record does not name this worktree)" "$CASE_ROOT/err" || { cat "$CASE_ROOT/err" >&2; fail_test 'foreign owner record was not reported'; }

echo 'PASS: cleanup binds the exact persisted merged PR and Head, rejects reused targets, resumes each deletion boundary, and reclaims only the removed worktree build data'
