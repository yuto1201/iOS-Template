#!/usr/bin/env bash
set -euo pipefail

source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-merge.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
repo_name='yuto1201/iOS-Template'
issue=42
branch='codex/42-merge-e2e'
worktree_relative='.worktrees/42-merge-e2e'
pr=57
merge_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

fail_test() { echo "FAIL: $*" >&2; exit 1; }
assert_fails() { local label=$1; shift; if "$@" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"; then fail_test "expected failure: $label"; fi; }
assert_no_mutation() { [[ ! -s "$CASE_MUTATIONS" ]] || { cat "$CASE_MUTATIONS" >&2; fail_test "$1 performed an external mutation"; }; }

make_case() {
  local name=$1 state_name=${2:-approved-for-merge} persisted_pr=${3:-none}
  CASE_ROOT="$scratch/$name"; CASE_PRIMARY="$CASE_ROOT/repo"; CASE_REMOTE="$CASE_ROOT/remote.git"
  CASE_WORKTREE="$CASE_PRIMARY/$worktree_relative"; CASE_GH="$CASE_ROOT/gh"; CASE_BIN="$CASE_ROOT/bin"
  CASE_LOG="$CASE_ROOT/operations.log"; CASE_MUTATIONS="$CASE_ROOT/mutations.log"
  mkdir -p "$CASE_ROOT" "$CASE_GH" "$CASE_BIN"
  git init --bare "$CASE_REMOTE" >/dev/null
  git init -b main "$CASE_PRIMARY" >/dev/null
  git -C "$CASE_PRIMARY" config user.name Fixture
  git -C "$CASE_PRIMARY" config user.email fixture@example.invalid
  printf 'base\n' >"$CASE_PRIMARY/README.md"
  git -C "$CASE_PRIMARY" add README.md && git -C "$CASE_PRIMARY" commit -m base >/dev/null
  CASE_BASE=$(git -C "$CASE_PRIMARY" rev-parse HEAD)
  git -C "$CASE_PRIMARY" remote add origin "$CASE_REMOTE"
  git -C "$CASE_PRIMARY" push origin main >/dev/null
  mkdir -p "$CASE_PRIMARY/.worktrees"
  git -C "$CASE_PRIMARY" worktree add -b "$branch" "$CASE_WORKTREE" main >/dev/null
  mkdir -p "$CASE_WORKTREE/tools/lib" "$CASE_PRIMARY/.artifacts/issues/$issue"
  cp "$source_root/tools/merge-issue.sh" "$source_root/tools/render-pr-body.sh" "$source_root/tools/issue-state.sh" "$CASE_WORKTREE/tools/"
  cp "$source_root/tools/lib/merge-state.rb" "$source_root/tools/lib/descriptor-files.rb" "$source_root/tools/lib/workflow.sh" "$source_root/tools/lib/workflow-json.rb" "$CASE_WORKTREE/tools/lib/"
  ln -s ../../.artifacts "$CASE_WORKTREE/.artifacts"
  printf '.artifacts\n' >>"$(git -C "$CASE_WORKTREE" rev-parse --git-path info/exclude)"

  cat >"$CASE_WORKTREE/tools/github-account-preflight.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'preflight %s\n' "$*" >>"${FAKE_LOG:?}"
if [[ "${FAIL_PREFLIGHT:-}" == "$*" ]]; then exit 41; fi
EOF
  cat >"$CASE_WORKTREE/tools/premerge-gate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gate %s\n' "$*" >>"${FAKE_LOG:?}"
[[ "${FAIL_GATE:-0}" != 1 ]]
EOF
  chmod +x "$CASE_WORKTREE/tools/"*.sh "$CASE_WORKTREE/tools/lib/merge-state.rb"
  git -C "$CASE_WORKTREE" add tools && git -C "$CASE_WORKTREE" commit -m tools >/dev/null
  CASE_HEAD=$(git -C "$CASE_WORKTREE" rev-parse HEAD)
  mkdir -p "$CASE_PRIMARY/.artifacts/issues/$issue/$CASE_HEAD"
  CONTRACT="$CASE_PRIMARY/.artifacts/issues/$issue/issue-contract.json" ruby -rjson -e '
    File.binwrite(ENV.fetch("CONTRACT"), JSON.generate({"schemaVersion"=>1,"issue"=>42,"repository"=>"yuto1201/iOS-Template","goal"=>"Merge exact verified work.","specAnchors"=>["docs/workflow.md#6-pr-body"],"acceptanceCriteria"=>[{"id"=>"AC-1","text"=>"Merge exact Head."}],"dependencies"=>[],"externalOperations"=>["github.push_branch","github.create_pr","github.merge_pr"],"fetchedAt"=>"2026-08-24T00:00:00Z"}))'
  CASE_DIGEST="sha256:$(shasum -a 256 "$CASE_PRIMARY/.artifacts/issues/$issue/issue-contract.json" | awk '{print $1}')"
  VERIFY="$CASE_PRIMARY/.artifacts/issues/$issue/$CASE_HEAD/verify.json" HEAD="$CASE_HEAD" BASE="$CASE_BASE" DIGEST="$CASE_DIGEST" ruby -rjson -e '
    value={"schemaVersion"=>1,"status"=>"not-applicable","changeClassification"=>"documentation-only","reason"=>"Only allowlisted Markdown documentation changed","issue"=>42,"baseSha"=>ENV.fetch("BASE"),"headSha"=>ENV.fetch("HEAD"),"issueContract"=>{"path"=>".artifacts/issues/42/issue-contract.json","digest"=>ENV.fetch("DIGEST")},"matrixFile"=>nil,"matrixDigest"=>nil,"executionRoute"=>"none","xcode"=>nil,"build"=>{"status"=>"not-applicable","scheme"=>nil,"warningsAdded"=>nil,"project"=>nil,"sourceTree"=>nil},"tests"=>{"status"=>"not-applicable","passed"=>nil,"failed"=>nil,"skipped"=>nil},"cases"=>[],"visualEvaluation"=>{"status"=>"not-applicable","findings"=>[]},"acceptanceEvidence"=>[{"id"=>"AC-1","status"=>"passed","evidence"=>["documents:workflow"]}],"completedAt"=>"2026-08-24T00:01:00Z"}; File.binwrite(ENV.fetch("VERIFY"),JSON.generate(value))'
  REVIEW="$CASE_PRIMARY/.artifacts/issues/$issue/$CASE_HEAD/review.json" HEAD="$CASE_HEAD" BASE="$CASE_BASE" DIGEST="$CASE_DIGEST" ruby -rjson -e '
    value={"schemaVersion"=>1,"issue"=>42,"reviewerModel"=>"claude","baseSha"=>ENV.fetch("BASE"),"headSha"=>ENV.fetch("HEAD"),"verifySha"=>ENV.fetch("HEAD"),"issueContractDigest"=>ENV.fetch("DIGEST"),"verdict"=>"approved","findings"=>[],"acceptanceAssessment"=>[{"id"=>"AC-1","status"=>"supported","evidence"=>["review.diff"]}],"reviewedAt"=>"2026-08-24T00:02:00Z"}; File.binwrite(ENV.fetch("REVIEW"),JSON.generate(value))'
  STATE="$CASE_PRIMARY/.artifacts/issues/$issue/state.json" HEAD="$CASE_HEAD" BASE="$CASE_BASE" DIGEST="$CASE_DIGEST" NAME="$state_name" PR="$persisted_pr" ruby -rjson -e '
    name=ENV.fetch("NAME"); value={"schemaVersion"=>1,"issue"=>42,"repository"=>"yuto1201/iOS-Template","branch"=>"codex/42-merge-e2e","worktree"=>".worktrees/42-merge-e2e","baseSha"=>ENV.fetch("BASE"),"primaryImplementer"=>"codex","issueContract"=>{"path"=>".artifacts/issues/42/issue-contract.json","digest"=>ENV.fetch("DIGEST")},"state"=>name,"previousState"=>name=="merged" ? "approved-for-merge" : "review-requested","resumeState"=>nil,"executor"=>"codex","headSha"=>ENV.fetch("HEAD"),"from"=>name=="merged" ? "approved-for-merge" : "review-requested","to"=>name,"transitionedAt"=>"2026-08-24T00:03:00Z"}; value["pullRequest"]=Integer(ENV.fetch("PR")) unless ENV.fetch("PR")=="none"; File.binwrite(ENV.fetch("STATE"),JSON.generate(value))'
  printf '[]\n' >"$CASE_GH/prs.json"; printf 'OPEN\n' >"$CASE_GH/issue-state"; printf 'state:approved-for-merge\n' >"$CASE_GH/issue-label"
  : >"$CASE_LOG"; : >"$CASE_MUTATIONS"

  cat >"$CASE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log=${FAKE_LOG:?}; mutations=${FAKE_MUTATIONS:?}; state=${FAKE_GH:?}; repo=${FAKE_REPO:?}; issue=${FAKE_ISSUE:?}; branch=${FAKE_BRANCH:?}; head=${FAKE_HEAD:?}; pr=${FAKE_PR:?}
printf 'gh %s\n' "$*" >>"$log"
fields='number,state,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,closingIssuesReferences,mergeCommit,url'
pr_json() { local status=$1; PR_STATE="$status" ruby -rjson -e 'state=ENV.fetch("PR_STATE"); repo=ENV.fetch("FAKE_SOURCE_REPO",ENV.fetch("FAKE_REPO")); owner=repo.split("/",2).first; issue=Integer(ENV.fetch("FAKE_CLOSING_ISSUE",ENV.fetch("FAKE_ISSUE"))); puts JSON.generate({"number"=>Integer(ENV.fetch("FAKE_PR")),"state"=>state,"baseRefName"=>"main","headRefName"=>ENV.fetch("FAKE_BRANCH"),"headRefOid"=>ENV.fetch("FAKE_HEAD"),"headRepository"=>{"nameWithOwner"=>repo},"headRepositoryOwner"=>{"login"=>owner},"isCrossRepository"=>ENV.fetch("FAKE_CROSS_REPO","false")=="true","closingIssuesReferences"=>[{"number"=>issue,"url"=>"https://github.com/#{ENV.fetch("FAKE_REPO")}/issues/#{issue}","repository"=>{"nameWithOwner"=>ENV.fetch("FAKE_REPO")}}],"mergeCommit"=>state=="MERGED" ? {"oid"=>ENV.fetch("FAKE_MERGE")} : nil,"url"=>"https://github.com/#{ENV.fetch("FAKE_REPO")}/pull/#{ENV.fetch("FAKE_PR")}"})'; }
case "$1 $2" in
  'pr list')
    [[ "$*" == "pr list --repo $repo --head $branch --state all --json $fields" || "$*" == "pr list --repo $repo --head $branch --state open --json $fields" ]] || { echo 'invalid pr list argv' >&2; exit 2; }
    cat "$state/prs.json" ;;
  'pr create')
    [[ $# == 12 && $3 == --repo && $4 == "$repo" && $5 == --base && $6 == main && $7 == --head && $8 == "$branch" && $9 == --title && ${10} == 'Issue #42: Merge exact verified work.' && ${11} == --body && ${12} == *'Closes #42'* ]] || { echo 'invalid deterministic pr create argv' >&2; exit 2; }
    printf 'pr-create\n' >>"$mutations"; pr_json OPEN | jq -s . >"$state/prs.json" ;;
  'pr view') [[ "$*" == "pr view $pr --repo $repo --json $fields" ]] || { echo 'invalid pr view argv' >&2; exit 2; }; jq -e 'length==1' "$state/prs.json" >/dev/null; jq '.[0]' "$state/prs.json" ;;
  'pr merge') [[ "$*" == "pr merge $pr --repo $repo --squash --match-head-commit $head" ]] || { echo 'invalid pr merge argv' >&2; exit 2; }; printf 'pr-merge\n' >>"$mutations"; pr_json MERGED | jq -s . >"$state/prs.json"; printf 'CLOSED\n' >"$state/issue-state" ;;
  'issue view')
    if [[ "$*" == *'--json number,state,url' ]]; then jq -cn --argjson number "$issue" --arg state "$(cat "$state/issue-state")" --arg url "https://github.com/$repo/issues/$issue" '{number:$number,state:$state,url:$url}'
    elif [[ "$*" == *'--json labels,comments' ]]; then jq -cn --arg label "$(cat "$state/issue-label")" '{labels:[{name:$label}],comments:[]}'
    else jq -cn --arg label "$(cat "$state/issue-label")" '{labels:[{name:$label}]}' ; fi ;;
  'issue edit') printf 'issue-edit\n' >>"$mutations"; printf 'state:merged\n' >"$state/issue-label" ;;
  'issue comment') printf 'issue-comment\n' >>"$mutations" ;;
  *) echo "unexpected gh: $*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$CASE_BIN/gh"
  REAL_GIT=$(command -v git)
  cat >"$CASE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "-C ${FAKE_WORKTREE:?} remote get-url origin" ]]; then printf 'https://github.com/%s.git\n' "${FAKE_REPO:?}"; exit 0; fi
if [[ "$*" == *' push origin '* ]]; then
  [[ "$*" == "-C ${FAKE_WORKTREE:?} push origin ${FAKE_HEAD:?}:refs/heads/${FAKE_BRANCH:?}" ]] || { echo 'push did not bind exact Head' >&2; exit 2; }
  printf 'git-push\n' >>"${FAKE_MUTATIONS:?}"; printf 'git %s\n' "$*" >>"${FAKE_LOG:?}"
fi
if [[ "$*" == "-C ${FAKE_WORKTREE:?} ls-remote --exit-code --heads origin refs/heads/${FAKE_BRANCH:?}" && -n "${FAKE_REMOTE_HEAD_OVERRIDE:-}" ]]; then
  printf '%s\trefs/heads/%s\n' "$FAKE_REMOTE_HEAD_OVERRIDE" "$FAKE_BRANCH"; exit 0
fi
exec "${REAL_GIT:?}" "$@"
EOF
  chmod +x "$CASE_BIN/git"
}

run_merge() {
  env PATH="$CASE_BIN:$PATH" REAL_GIT="$REAL_GIT" FAKE_WORKTREE="$CASE_WORKTREE" FAKE_REPO="$repo_name" FAKE_ISSUE="$issue" FAKE_BRANCH="$branch" FAKE_HEAD="$CASE_HEAD" FAKE_PR="$pr" FAKE_MERGE="$merge_sha" FAKE_GH="$CASE_GH" FAKE_LOG="$CASE_LOG" FAKE_MUTATIONS="$CASE_MUTATIONS" FAIL_GATE="${FAIL_GATE:-0}" FAKE_SOURCE_REPO="${FAKE_SOURCE_REPO:-$repo_name}" FAKE_CROSS_REPO="${FAKE_CROSS_REPO:-false}" FAKE_CLOSING_ISSUE="${FAKE_CLOSING_ISSUE:-$issue}" FAKE_REMOTE_HEAD_OVERRIDE="${FAKE_REMOTE_HEAD_OVERRIDE:-}" "$CASE_WORKTREE/tools/merge-issue.sh" --repo "$repo_name" --issue "$issue"
}

write_pr() {
  local state=$1 source_repo=${2:-$repo_name} cross=${3:-false} closing_issue=${4:-$issue}
  STATE="$state" SOURCE_REPO="$source_repo" CROSS="$cross" CLOSING_ISSUE="$closing_issue" REPO="$repo_name" PR="$pr" BRANCH="$branch" HEAD="$CASE_HEAD" MERGE="$merge_sha" ruby -rjson -e '
    state=ENV.fetch("STATE"); source=ENV.fetch("SOURCE_REPO"); closing=Integer(ENV.fetch("CLOSING_ISSUE")); repo=ENV.fetch("REPO")
    value={"number"=>Integer(ENV.fetch("PR")),"state"=>state,"baseRefName"=>"main","headRefName"=>ENV.fetch("BRANCH"),"headRefOid"=>ENV.fetch("HEAD"),"headRepository"=>{"nameWithOwner"=>source},"headRepositoryOwner"=>{"login"=>source.split("/",2).first},"isCrossRepository"=>ENV.fetch("CROSS")=="true","closingIssuesReferences"=>[{"number"=>closing,"url"=>"https://github.com/#{repo}/issues/#{closing}","repository"=>{"nameWithOwner"=>repo}}],"mergeCommit"=>state=="MERGED" ? {"oid"=>ENV.fetch("MERGE")} : nil,"url"=>"https://github.com/#{repo}/pull/#{ENV.fetch("PR")}"}; puts JSON.generate([value])
  ' >"$CASE_GH/prs.json"
}

make_case new
body=$("$CASE_WORKTREE/tools/render-pr-body.sh" --issue 42 --head-sha "$CASE_HEAD")
grep -Fq 'Verify digest: `sha256:' <<<"$body" || fail_test 'PR body omits verify digest'
grep -Fq 'Reviewer model: `claude`' <<<"$body" || fail_test 'PR body omits reviewer model'
grep -Fq 'iPhone Pro / English: `not-applicable`' <<<"$body" || fail_test 'PR body omits iPhone English matrix result'
grep -Fq '`docs/workflow.md#6-pr-body`' <<<"$body" || fail_test 'PR body omits spec anchors'
run_merge >"$CASE_ROOT/result.json"
jq -e '.status=="merged" and .pullRequest==57' "$CASE_ROOT/result.json" >/dev/null
jq -e '.state=="merged" and .pullRequest==57' "$CASE_PRIMARY/.artifacts/issues/42/state.json" >/dev/null
first=$(head -1 "$CASE_LOG"); [[ "$first" == "preflight --repo $repo_name" ]] || fail_test 'account/repository inspect was not first'
gate_line=$(grep -n '^gate ' "$CASE_LOG" | head -1 | cut -d: -f1); push_line=$(grep -n '^git .* push ' "$CASE_LOG" | head -1 | cut -d: -f1); create_line=$(grep -n '^gh pr create ' "$CASE_LOG" | cut -d: -f1)
[[ "$gate_line" -lt "$push_line" && "$gate_line" -lt "$create_line" ]] || fail_test 'gate did not precede push and PR creation'

make_case gate-failure
FAIL_GATE=1 assert_fails 'gate before publication' run_merge
assert_no_mutation 'gate failure'

make_case persisted-open approved-for-merge 57
write_pr OPEN
run_merge >"$CASE_ROOT/open-result.json"
jq -e '.status=="merged" and .pullRequest==57' "$CASE_ROOT/open-result.json" >/dev/null

make_case persisted-closed approved-for-merge 57
write_pr CLOSED
assert_fails 'persisted closed-unmerged PR' run_merge
assert_no_mutation 'persisted closed-unmerged PR'

make_case foreign-fork approved-for-merge 57
write_pr OPEN 'foreign/project' true
assert_fails 'foreign-fork PR source' run_merge
assert_no_mutation 'foreign-fork PR source'

make_case wrong-closing-issue approved-for-merge 57
write_pr OPEN "$repo_name" false 43
assert_fails 'PR closes wrong Issue' run_merge
assert_no_mutation 'wrong closing Issue'

make_case discovered-merged
write_pr MERGED
cp "$CASE_PRIMARY/.artifacts/issues/42/state.json" "$CASE_ROOT/state.before"
assert_fails 'discovered merged PR without durable identity first run' run_merge
cmp -s "$CASE_ROOT/state.before" "$CASE_PRIMARY/.artifacts/issues/42/state.json" || fail_test 'first discovered-merged refusal changed state bytes'
assert_fails 'discovered merged PR without durable identity second run' run_merge
cmp -s "$CASE_ROOT/state.before" "$CASE_PRIMARY/.artifacts/issues/42/state.json" || fail_test 'second discovered-merged refusal changed state bytes'
assert_no_mutation 'discovered merged PR without durable identity'

make_case remote-ref-race
FAKE_REMOTE_HEAD_OVERRIDE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb assert_fails 'remote ref moved after exact push' run_merge
if grep -Eq '^(pr-create|pr-merge)$' "$CASE_MUTATIONS"; then fail_test 'ref move race created or merged a PR'; fi

make_case invalid-state in-progress
assert_fails 'non-approved normal state' run_merge
[[ ! -s "$CASE_LOG" ]] || fail_test 'invalid durable state reached an external call'
assert_no_mutation 'invalid durable state'

make_case bad-digest
cp "$CASE_PRIMARY/.artifacts/issues/42/state.json" "$CASE_ROOT/state.good"
ruby -rjson -e 'p=ARGV[0];v=JSON.parse(File.binread(p));v["issueContract"]["digest"]="sha256:"+"0"*64;File.binwrite(p,JSON.generate(v))' "$CASE_PRIMARY/.artifacts/issues/42/state.json"
assert_fails 'contract digest mismatch' run_merge
[[ ! -s "$CASE_LOG" ]] || fail_test 'contract mismatch reached external calls'
assert_no_mutation 'contract mismatch'

make_case mismatched-slug
ruby -rjson -e 'p=ARGV[0];v=JSON.parse(File.binread(p));v["worktree"]=".worktrees/42-other-slug";File.binwrite(p,JSON.generate(v))' "$CASE_PRIMARY/.artifacts/issues/42/state.json"
assert_fails 'Branch/worktree slug mismatch' run_merge
[[ ! -s "$CASE_LOG" ]] || fail_test 'slug mismatch reached external calls'
assert_no_mutation 'Branch/worktree slug mismatch'

make_case missing-transition-time
ruby -rjson -e 'p=ARGV[0];v=JSON.parse(File.binread(p));v.delete("transitionedAt");File.binwrite(p,JSON.generate(v))' "$CASE_PRIMARY/.artifacts/issues/42/state.json"
assert_fails 'approved state missing transition timestamp' run_merge
[[ ! -s "$CASE_LOG" ]] || fail_test 'missing transition timestamp reached external calls'
assert_no_mutation 'missing transition timestamp'

make_case bad-link
rm "$CASE_WORKTREE/.artifacts" && ln -s ../../../.artifacts "$CASE_WORKTREE/.artifacts"
assert_fails 'raw artifact link mismatch' run_merge
[[ ! -s "$CASE_LOG" ]] || fail_test 'artifact-link mismatch reached external calls'
assert_no_mutation 'artifact-link mismatch'

make_case merged-recovery merged 57
write_pr MERGED
printf 'CLOSED\n' >"$CASE_GH/issue-state"; printf 'state:merged\n' >"$CASE_GH/issue-label"
run_merge >"$CASE_ROOT/recovery.json"
jq -e '.status=="already-merged" and .pullRequest==57' "$CASE_ROOT/recovery.json" >/dev/null
[[ "$(head -1 "$CASE_LOG")" == "preflight --repo $repo_name" ]] || fail_test 'recovery skipped account preflight'
assert_no_mutation 'already-merged recovery'

make_case merged-without-pr merged none
assert_fails 'merged state without persisted PR' run_merge
[[ ! -s "$CASE_LOG" ]] || fail_test 'invalid merged state reached external calls'
assert_no_mutation 'merged state without PR'

echo 'PASS: merge binds durable identity, gates before publication, uses deterministic PR metadata, and safely recovers exact merged PRs'
