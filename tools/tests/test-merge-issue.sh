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
  mkdir -p "$CASE_WORKTREE/tools/lib" "$CASE_WORKTREE/Config" "$CASE_PRIMARY/.artifacts/issues/$issue"
  cp "$source_root/Config/ownership.yml" "$CASE_WORKTREE/Config/ownership.yml"
  cp "$source_root/tools/merge-issue.sh" "$source_root/tools/render-pr-body.sh" "$source_root/tools/issue-state.sh" "$source_root/tools/validate-verify-json.swift" "$source_root/tools/prepare-review-packet.sh" "$CASE_WORKTREE/tools/"
  cp "$source_root/tools/lib/merge-state.rb" "$source_root/tools/lib/descriptor-files.rb" "$source_root/tools/lib/issue-contract.rb" "$source_root/tools/lib/delivery-profile.rb" "$source_root/tools/lib/ownership.rb" "$source_root/tools/lib/workflow.sh" "$source_root/tools/lib/workflow-json.rb" "$source_root/tools/lib/review-artifacts.rb" "$source_root/tools/lib/review-contract.rb" "$source_root/tools/lib/review-sealing.rb" "$source_root/tools/lib/prepare-review-packet.rb" "$CASE_WORKTREE/tools/lib/"
  ln -s ../../.artifacts "$CASE_WORKTREE/.artifacts"
  printf '.artifacts\n' >>"$(git -C "$CASE_WORKTREE" rev-parse --git-path info/exclude)"

  cat >"$CASE_WORKTREE/tools/github-account-preflight.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'--intended-operation github.merge_pr'* ]]; then
  count_file="${FAKE_GH:?}/merge-preflight-count"; count=$(($(cat "$count_file" 2>/dev/null || printf 0)+1)); printf '%s\n' "$count" >"$count_file"
  if [[ "$count" == 1 ]]; then printf 'preflight merge-initial\n' >>"${FAKE_LOG:?}"; else printf 'preflight merge-final\n' >>"${FAKE_LOG:?}"; fi
else
  printf 'preflight %s\n' "$*" >>"${FAKE_LOG:?}"
fi
if [[ "${FAIL_PREFLIGHT:-}" == "$*" ]]; then exit 41; fi
EOF
  cat >"$CASE_WORKTREE/tools/premerge-gate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count_file="${FAKE_GH:?}/gate-count"; count=$(($(cat "$count_file" 2>/dev/null || printf 0)+1)); printf '%s\n' "$count" >"$count_file"
if [[ "$count" == 1 ]]; then label=initial; else label=final; fi
printf 'gate %s\n' "$label" >>"${FAKE_LOG:?}"
if [[ "${FAIL_GATE:-none}" == "$label" || "${FAIL_GATE:-none}" == all ]]; then exit 1; fi
if [[ "$label" == final ]]; then
  [[ "$*" == "--repo ${FAKE_REPO:?} --issue ${FAKE_ISSUE:?} --head-sha ${FAKE_HEAD:?} --merge-pr ${FAKE_PR:?}" ]] || { echo 'final Gate did not receive the exact merge lease identity' >&2; exit 2; }
  fields='number,state,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,closingIssuesReferences,mergeCommit,url'
  gh auth status --active >/dev/null
  gh repo view "$FAKE_REPO" --json nameWithOwner,defaultBranchRef,url >/dev/null
  gh pr view "$FAKE_PR" --repo "$FAKE_REPO" --json "$fields" >/dev/null
  gh pr merge "$FAKE_PR" --repo "$FAKE_REPO" --squash --match-head-commit "$FAKE_HEAD"
fi
EOF
  chmod +x "$CASE_WORKTREE/tools/"*.sh "$CASE_WORKTREE/tools/lib/merge-state.rb"
  git -C "$CASE_WORKTREE" add tools Config && git -C "$CASE_WORKTREE" commit -m tools >/dev/null
  CASE_BASE=$(git -C "$CASE_WORKTREE" rev-parse HEAD)
  git -C "$CASE_PRIMARY" merge --ff-only "$branch" >/dev/null
  git -C "$CASE_PRIMARY" push origin main >/dev/null
  printf 'documentation change\n' >> "$CASE_WORKTREE/README.md"
  git -C "$CASE_WORKTREE" add README.md && git -C "$CASE_WORKTREE" commit -m documentation >/dev/null
  CASE_HEAD=$(git -C "$CASE_WORKTREE" rev-parse HEAD)
  mkdir -p "$CASE_PRIMARY/.artifacts/issues/$issue/$CASE_HEAD"
  CONTRACT="$CASE_PRIMARY/.artifacts/issues/$issue/issue-contract.json" ruby -rjson -rdigest -e '
    operations=["github.read_issue","github.update_issue","github.push_branch","github.create_pr","github.merge_pr"]
    details=operations.map{|operation|{"operation"=>operation,"service"=>"GitHub","environment"=>"production","executor"=>"Codex","approvalRequired"=>false,"approvalReference"=>nil}}
    def canonical(value); value.is_a?(Hash) ? value.keys.sort.to_h{|key|[key,canonical(value[key])]} : value.is_a?(Array) ? value.map{|entry|canonical(entry)} : value; end
    detail_digest="sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(details)))}"
    contract={"schemaVersion"=>1,"issue"=>42,"repository"=>"yuto1201/iOS-Template","goal"=>"Merge exact verified work.","specAnchors"=>["docs/workflow.md#6-pr-body"],"acceptanceCriteria"=>[{"id"=>"AC-1","text"=>"Merge exact Head."}],"dependencies"=>[],"externalOperations"=>operations,"externalOperationDetailsDigest"=>detail_digest,"fetchedAt"=>"2026-08-24T00:00:00Z"}
    File.binwrite(ENV.fetch("CONTRACT"), JSON.generate(canonical(contract)))'
  CASE_DIGEST="sha256:$(shasum -a 256 "$CASE_PRIMARY/.artifacts/issues/$issue/issue-contract.json" | awk '{print $1}')"
  VERIFY="$CASE_PRIMARY/.artifacts/issues/$issue/$CASE_HEAD/verify.json" HEAD="$CASE_HEAD" BASE="$CASE_BASE" DIGEST="$CASE_DIGEST" ruby -rjson -e '
    value={"schemaVersion"=>1,"status"=>"not-applicable","changeClassification"=>"documentation-only","reason"=>"Only allowlisted Markdown documentation changed","issue"=>42,"baseSha"=>ENV.fetch("BASE"),"headSha"=>ENV.fetch("HEAD"),"issueContract"=>{"path"=>".artifacts/issues/42/issue-contract.json","digest"=>ENV.fetch("DIGEST")},"matrixFile"=>nil,"matrixDigest"=>nil,"executionRoute"=>"none","xcode"=>nil,"build"=>{"status"=>"not-applicable","scheme"=>nil,"warningsAdded"=>nil,"project"=>nil,"sourceTree"=>nil},"tests"=>{"status"=>"not-applicable","passed"=>nil,"failed"=>nil,"skipped"=>nil},"cases"=>[],"visualEvaluation"=>{"status"=>"not-applicable","findings"=>[]},"acceptanceEvidence"=>[{"id"=>"AC-1","status"=>"passed","evidence"=>["documents:workflow"]}],"completedAt"=>"2026-08-24T00:01:00Z"}; File.binwrite(ENV.fetch("VERIFY"),JSON.generate(value))'
  write_review_closure
  STATE="$CASE_PRIMARY/.artifacts/issues/$issue/state.json" HEAD="$CASE_HEAD" BASE="$CASE_BASE" DIGEST="$CASE_DIGEST" NAME="$state_name" PR="$persisted_pr" ruby -rjson -e '
    name=ENV.fetch("NAME"); value={"schemaVersion"=>1,"issue"=>42,"repository"=>"yuto1201/iOS-Template","branch"=>"codex/42-merge-e2e","worktree"=>".worktrees/42-merge-e2e","baseSha"=>ENV.fetch("BASE"),"primaryImplementer"=>"codex","issueContract"=>{"path"=>".artifacts/issues/42/issue-contract.json","digest"=>ENV.fetch("DIGEST")},"state"=>name,"previousState"=>name=="merged" ? "approved-for-merge" : "review-requested","resumeState"=>nil,"executor"=>"codex","headSha"=>ENV.fetch("HEAD"),"from"=>name=="merged" ? "approved-for-merge" : "review-requested","to"=>name,"transitionedAt"=>"2026-08-24T00:03:00Z"}; value["pullRequest"]=Integer(ENV.fetch("PR")) unless ENV.fetch("PR")=="none"; File.binwrite(ENV.fetch("STATE"),JSON.generate(value))'
  printf '[]\n' >"$CASE_GH/prs.json"; printf 'OPEN\n' >"$CASE_GH/issue-state"; printf 'state:approved-for-merge\n' >"$CASE_GH/issue-label"
  : >"$CASE_LOG"; : >"$CASE_MUTATIONS"

  cat >"$CASE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log=${FAKE_LOG:?}; mutations=${FAKE_MUTATIONS:?}; state=${FAKE_GH:?}; repo=${FAKE_REPO:?}; issue=${FAKE_ISSUE:?}; branch=${FAKE_BRANCH:?}; head=${FAKE_HEAD:?}; pr=${FAKE_PR:?}
fields='number,state,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,closingIssuesReferences,mergeCommit,url'
pr_json() { local status=$1; PR_STATE="$status" ruby -rjson -e 'state=ENV.fetch("PR_STATE"); repo=ENV.fetch("FAKE_SOURCE_REPO",ENV.fetch("FAKE_REPO")); owner=repo.split("/",2).first; target_owner,target_name=ENV.fetch("FAKE_REPO").split("/",2); issue=Integer(ENV.fetch("FAKE_CLOSING_ISSUE",ENV.fetch("FAKE_ISSUE"))); puts JSON.generate({"number"=>Integer(ENV.fetch("FAKE_PR")),"state"=>state,"baseRefName"=>"main","headRefName"=>ENV.fetch("FAKE_BRANCH"),"headRefOid"=>ENV.fetch("FAKE_HEAD"),"headRepository"=>{"nameWithOwner"=>repo},"headRepositoryOwner"=>{"login"=>owner},"isCrossRepository"=>ENV.fetch("FAKE_CROSS_REPO","false")=="true","closingIssuesReferences"=>[{"number"=>issue,"url"=>"https://github.com/#{ENV.fetch("FAKE_REPO")}/issues/#{issue}","repository"=>{"id"=>"R_fixture","name"=>target_name,"owner"=>{"id"=>"U_fixture","login"=>target_owner}}}],"mergeCommit"=>state=="MERGED" ? {"oid"=>ENV.fetch("FAKE_MERGE")} : nil,"url"=>"https://github.com/#{ENV.fetch("FAKE_REPO")}/pull/#{ENV.fetch("FAKE_PR")}"})'; }
case "$1 $2" in
  'auth status') [[ "$*" == 'auth status --active' ]] || exit 2; printf 'gh auth status active\n' >>"$log"; printf 'Logged in to github.com account yuto1201 (keychain)\n  - Active account: true\n' ;;
  'repo view') [[ "$*" == "repo view $repo --json nameWithOwner,defaultBranchRef,url" ]] || exit 2; printf 'gh repo view exact\n' >>"$log"; jq -cn --arg repo "$repo" '{nameWithOwner:$repo,defaultBranchRef:{name:"main"},url:("https://github.com/"+$repo)}' ;;
  'pr list')
    [[ "$*" == "pr list --repo $repo --head $branch --state all --json $fields" || "$*" == "pr list --repo $repo --head $branch --state open --json $fields" ]] || { echo 'invalid pr list argv' >&2; exit 2; }
    printf 'gh pr list %s\n' "$8" >>"$log"
    cat "$state/prs.json" ;;
  'pr create')
    [[ $# == 12 && $3 == --repo && $4 == "$repo" && $5 == --base && $6 == main && $7 == --head && $8 == "$branch" && $9 == --title && ${10} == 'Issue #42: Merge exact verified work.' && ${11} == --body && ${12} == *'Closes #42'* ]] || { echo 'invalid deterministic pr create argv' >&2; exit 2; }
    printf 'gh pr create exact\n' >>"$log"; printf 'pr-create\n' >>"$mutations"; pr_json OPEN | jq -s . >"$state/prs.json" ;;
  'pr view') [[ "$*" == "pr view $pr --repo $repo --json $fields" ]] || { echo 'invalid pr view argv' >&2; exit 2; }; printf 'gh pr view %s\n' "$pr" >>"$log"; jq -e 'length==1' "$state/prs.json" >/dev/null; jq '.[0]' "$state/prs.json" ;;
  'pr merge') [[ "$*" == "pr merge $pr --repo $repo --squash --match-head-commit $head" ]] || { echo 'invalid pr merge argv' >&2; exit 2; }; printf 'gh pr merge %s exact-squash\n' "$pr" >>"$log"; printf 'pr-merge\n' >>"$mutations"; pr_json MERGED | jq -s . >"$state/prs.json"; printf 'CLOSED\n' >"$state/issue-state" ;;
  'issue view')
    if [[ "$*" == *'--json number,state,url' ]]; then printf 'gh issue view identity\n' >>"$log"; jq -cn --argjson number "$issue" --arg state "$(cat "$state/issue-state")" --arg url "https://github.com/$repo/issues/$issue" '{number:$number,state:$state,url:$url}'
    elif [[ "$*" == *'labels,comments'* ]]; then printf 'gh issue view labels-comments\n' >>"$log"; jq -cn --arg label "$(cat "$state/issue-label")" '{title:"Merge exact verified work",body:"fixture",labels:[{name:$label}],comments:[]}'
    else printf 'gh issue view labels\n' >>"$log"; jq -cn --arg label "$(cat "$state/issue-label")" '{labels:[{name:$label}]}' ; fi ;;
  'issue edit') printf 'gh issue edit approved-to-merged\n' >>"$log"; printf 'issue-edit\n' >>"$mutations"; printf 'state:merged\n' >"$state/issue-label" ;;
  'issue comment') printf 'gh issue comment transition\n' >>"$log"; printf 'issue-comment\n' >>"$mutations" ;;
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
  printf 'git ls-remote exact\n' >>"${FAKE_LOG:?}"
  printf '%s\trefs/heads/%s\n' "$FAKE_REMOTE_HEAD_OVERRIDE" "$FAKE_BRANCH"; exit 0
fi
if [[ "$*" == "-C ${FAKE_WORKTREE:?} ls-remote --exit-code --heads origin refs/heads/${FAKE_BRANCH:?}" ]]; then printf 'git ls-remote exact\n' >>"${FAKE_LOG:?}"; fi
exec "${REAL_GIT:?}" "$@"
EOF
  chmod +x "$CASE_BIN/git"
}

write_review_closure() {
  local artifact_head="$CASE_PRIMARY/.artifacts/issues/$issue/$CASE_HEAD"
  rm -f "$artifact_head/review.diff" "$artifact_head/review-packet.json" "$artifact_head/review.json"
  (cd "$CASE_WORKTREE" && "$CASE_WORKTREE/tools/prepare-review-packet.sh" --primary codex --issue "$issue" --base-sha "$CASE_BASE" --head-sha "$CASE_HEAD") >/dev/null
  local packet_digest
  packet_digest="sha256:$(shasum -a 256 "$artifact_head/review-packet.json" | awk '{print $1}')"
  REVIEW="$artifact_head/review.json" HEAD="$CASE_HEAD" BASE="$CASE_BASE" DIGEST="$CASE_DIGEST" PACKET_DIGEST="$packet_digest" ruby -rjson -e '
    value={"schemaVersion"=>2,"issue"=>42,"reviewerModel"=>"claude","baseSha"=>ENV.fetch("BASE"),"headSha"=>ENV.fetch("HEAD"),"verifySha"=>ENV.fetch("HEAD"),"issueContractDigest"=>ENV.fetch("DIGEST"),"verdict"=>"approved","findings"=>[],"acceptanceAssessment"=>[{"id"=>"AC-1","status"=>"supported","evidence"=>["review.diff"]}],"reviewedAt"=>"2026-08-24T00:02:00Z","reviewPacketDigest"=>ENV.fetch("PACKET_DIGEST")}; File.binwrite(ENV.fetch("REVIEW"),JSON.generate(value))'
}

run_merge() {
  env PATH="$CASE_BIN:$PATH" REAL_GIT="$REAL_GIT" FAKE_WORKTREE="$CASE_WORKTREE" FAKE_REPO="$repo_name" FAKE_ISSUE="$issue" FAKE_BRANCH="$branch" FAKE_HEAD="$CASE_HEAD" FAKE_PR="$pr" FAKE_MERGE="$merge_sha" FAKE_GH="$CASE_GH" FAKE_LOG="$CASE_LOG" FAKE_MUTATIONS="$CASE_MUTATIONS" FAIL_GATE="${FAIL_GATE:-0}" FAKE_SOURCE_REPO="${FAKE_SOURCE_REPO:-$repo_name}" FAKE_CROSS_REPO="${FAKE_CROSS_REPO:-false}" FAKE_CLOSING_ISSUE="${FAKE_CLOSING_ISSUE:-$issue}" FAKE_REMOTE_HEAD_OVERRIDE="${FAKE_REMOTE_HEAD_OVERRIDE:-}" "$CASE_WORKTREE/tools/merge-issue.sh" --repo "$repo_name" --issue "$issue"
}

write_pr() {
  local state=$1 source_repo=${2:-$repo_name} cross=${3:-false} closing_issue=${4:-$issue}
  STATE="$state" SOURCE_REPO="$source_repo" CROSS="$cross" CLOSING_ISSUE="$closing_issue" REPO="$repo_name" PR="$pr" BRANCH="$branch" HEAD="$CASE_HEAD" MERGE="$merge_sha" ruby -rjson -e '
    state=ENV.fetch("STATE"); source=ENV.fetch("SOURCE_REPO"); closing=Integer(ENV.fetch("CLOSING_ISSUE")); repo=ENV.fetch("REPO")
    owner,name=repo.split("/",2); value={"number"=>Integer(ENV.fetch("PR")),"state"=>state,"baseRefName"=>"main","headRefName"=>ENV.fetch("BRANCH"),"headRefOid"=>ENV.fetch("HEAD"),"headRepository"=>{"nameWithOwner"=>source},"headRepositoryOwner"=>{"login"=>source.split("/",2).first},"isCrossRepository"=>ENV.fetch("CROSS")=="true","closingIssuesReferences"=>[{"number"=>closing,"url"=>"https://github.com/#{repo}/issues/#{closing}","repository"=>{"id"=>"R_fixture","name"=>name,"owner"=>{"id"=>"U_fixture","login"=>owner}}}],"mergeCommit"=>state=="MERGED" ? {"oid"=>ENV.fetch("MERGE")} : nil,"url"=>"https://github.com/#{repo}/pull/#{ENV.fetch("PR")}"}; puts JSON.generate([value])
  ' >"$CASE_GH/prs.json"
}

set_contract_operations() {
  OPERATIONS_JSON="$1" CONTRACT="$CASE_PRIMARY/.artifacts/issues/42/issue-contract.json" STATE="$CASE_PRIMARY/.artifacts/issues/42/state.json" VERIFY="$CASE_PRIMARY/.artifacts/issues/42/$CASE_HEAD/verify.json" ruby -rjson -rdigest -e '
    operations=(["github.read_issue","github.update_issue"]+JSON.parse(ENV.fetch("OPERATIONS_JSON"))).uniq; contract_path=ENV.fetch("CONTRACT")
    contract=JSON.parse(File.binread(contract_path)); contract["externalOperations"]=operations
    details=operations.map{|operation|{"operation"=>operation,"service"=>"GitHub","environment"=>"production","executor"=>"Codex","approvalRequired"=>false,"approvalReference"=>nil}}
    def canonical(value); value.is_a?(Hash) ? value.keys.sort.to_h{|key|[key,canonical(value[key])]} : value.is_a?(Array) ? value.map{|entry|canonical(entry)} : value; end
    contract["externalOperationDetailsDigest"]="sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(details)))}"
    File.binwrite(contract_path,JSON.generate(contract)); digest="sha256:#{Digest::SHA256.file(contract_path).hexdigest}"
    state=JSON.parse(File.binread(ENV.fetch("STATE"))); state["issueContract"]["digest"]=digest; File.binwrite(ENV.fetch("STATE"),JSON.generate(state))
    verify=JSON.parse(File.binread(ENV.fetch("VERIFY"))); verify["issueContract"]["digest"]=digest; File.binwrite(ENV.fetch("VERIFY"),JSON.generate(verify))
  '
  CASE_DIGEST="sha256:$(shasum -a 256 "$CASE_PRIMARY/.artifacts/issues/42/issue-contract.json" | awk '{print $1}')"
  write_review_closure
}

write_cas_patch() {
  cat >"$CASE_ROOT/cas-patch.rb" <<'RUBY'
module DescriptorFiles
  class << self
    alias_method :cas_original_atomic_replace_at, :atomic_replace_at
    alias_method :cas_original_exchange_replace_at, :exchange_replace_at
    def atomic_replace_at(directory, destination, bytes, expected_bytes, expected_stat)
      if ENV["CAS_INJECTION"] == "inplace"
        path = ENV.fetch("CAS_STATE_PATH"); current = File.binread(path)
        mutated = current.sub("2026-08-24T00:03:00Z", "2026-08-24T00:03:01Z")
        raise "in-place fixture did not preserve size" unless mutated.bytesize == current.bytesize && mutated != current
        File.open(path, "r+b") { |file| file.write(mutated); file.flush; file.fsync }
      end
      cas_original_atomic_replace_at(directory, destination, bytes, expected_bytes, expected_stat)
    end
    def exchange_replace_at(directory, temporary, destination, expected_bytes, expected_stat)
      if ENV["CAS_INJECTION"] == "swap"
        File.rename(ENV.fetch("CAS_REPLACEMENT_PATH"), ENV.fetch("CAS_STATE_PATH"))
      end
      cas_original_exchange_replace_at(directory, temporary, destination, expected_bytes, expected_stat)
    end
  end
end
RUBY
}

run_persist_pr_with_injection() {
  env RUBYOPT="-I$CASE_WORKTREE/tools/lib -rdescriptor-files -r$CASE_ROOT/cas-patch.rb" CAS_INJECTION="$1" CAS_STATE_PATH="$CASE_PRIMARY/.artifacts/issues/42/state.json" CAS_REPLACEMENT_PATH="${2:-$CASE_ROOT/unused}" ruby "$CASE_WORKTREE/tools/lib/merge-state.rb" persist-pr "$CASE_WORKTREE" "$repo_name" "$issue" "$pr"
}

make_case cas-inplace
write_cas_patch
state_path="$CASE_PRIMARY/.artifacts/issues/42/state.json"
before_inode=$(stat -f '%i' "$state_path")
assert_fails 'same-inode same-size state rewrite' run_persist_pr_with_injection inplace
[[ "$(stat -f '%i' "$state_path")" == "$before_inode" ]] || fail_test 'same-inode injection unexpectedly replaced state'
jq -e '(.transitionedAt=="2026-08-24T00:03:01Z") and (has("pullRequest")|not)' "$state_path" >/dev/null || fail_test 'same-inode rewrite was overwritten'

make_case cas-destination-swap
write_cas_patch
state_path="$CASE_PRIMARY/.artifacts/issues/42/state.json"
cp "$state_path" "$CASE_ROOT/replacement.json"
ruby -rjson -e 'p=ARGV[0];v=JSON.parse(File.binread(p));v["transitionedAt"]="2026-08-24T00:03:02Z";File.binwrite(p,JSON.generate(v))' "$CASE_ROOT/replacement.json"
cp "$CASE_ROOT/replacement.json" "$CASE_ROOT/replacement.expected"
assert_fails 'destination replacement between validation and exchange' run_persist_pr_with_injection swap "$CASE_ROOT/replacement.json"
cmp -s "$CASE_ROOT/replacement.expected" "$state_path" || fail_test 'destination replacement was overwritten instead of restored'
jq -e 'has("pullRequest")|not' "$state_path" >/dev/null || fail_test 'failed exchange published pullRequest'
if find "$CASE_PRIMARY/.artifacts/issues/42" -maxdepth 1 -name '.state.json.tmp.*' -print -quit | grep -q .; then fail_test 'failed CAS left a temporary state file'; fi

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
cat >"$CASE_ROOT/expected-new.log" <<EOF
preflight --repo $repo_name
preflight merge-initial
gate initial
gh pr list all
preflight --repo $repo_name --issue $issue --intended-operation github.push_branch --expected-head $CASE_HEAD
git -C $CASE_WORKTREE push origin $CASE_HEAD:refs/heads/$branch
git ls-remote exact
preflight --repo $repo_name --issue $issue --intended-operation github.create_pr --expected-head $CASE_HEAD
gh pr create exact
gh pr list open
preflight merge-final
gate final
gh auth status active
gh repo view exact
gh pr view $pr
gh pr merge $pr exact-squash
gh pr view $pr
gh issue view identity
gh issue view labels
preflight --repo $repo_name --issue $issue --intended-operation github.read_issue --expected-head $CASE_HEAD
gh issue view labels-comments
preflight --repo $repo_name --issue $issue --intended-operation github.read_issue --expected-head $CASE_HEAD
gh issue view labels-comments
preflight --repo $repo_name --issue $issue --intended-operation github.update_issue --expected-head $CASE_HEAD
gh issue edit approved-to-merged
preflight --repo $repo_name --issue $issue --intended-operation github.read_issue --expected-head $CASE_HEAD
gh issue view labels-comments
preflight --repo $repo_name --issue $issue --intended-operation github.update_issue --expected-head $CASE_HEAD
gh issue comment transition
EOF
diff -u "$CASE_ROOT/expected-new.log" "$CASE_LOG" || fail_test 'complete new-PR operation order differed'

make_case missing-merge-declaration
set_contract_operations '["github.push_branch","github.create_pr"]'
assert_fails 'missing merge declaration' run_merge
assert_no_mutation 'missing merge declaration'

make_case missing-push-declaration
set_contract_operations '["github.create_pr","github.merge_pr"]'
assert_fails 'missing push declaration' run_merge
assert_no_mutation 'missing push declaration'

make_case missing-create-declaration
set_contract_operations '["github.push_branch","github.merge_pr"]'
assert_fails 'missing create declaration for new PR path' run_merge
assert_no_mutation 'missing create declaration for new PR path'

make_case existing-pr-without-create approved-for-merge 57
set_contract_operations '["github.push_branch","github.merge_pr"]'
write_pr OPEN
run_merge >"$CASE_ROOT/existing-without-create.json"
jq -e '.status=="merged" and .pullRequest==57' "$CASE_ROOT/existing-without-create.json" >/dev/null
if grep -Fxq 'pr-create' "$CASE_MUTATIONS"; then fail_test 'persisted PR path created another PR'; fi

make_case gate-failure
FAIL_GATE=initial assert_fails 'initial gate before publication' run_merge
assert_no_mutation 'gate failure'

make_case final-gate-failure
FAIL_GATE=final assert_fails 'final gate after PR publication' run_merge
grep -Fxq 'pr-create' "$CASE_MUTATIONS" || fail_test 'final gate fixture never reached PR creation'
if grep -Fxq 'pr-merge' "$CASE_MUTATIONS"; then fail_test 'final gate failure still merged the PR'; fi
[[ "$(tail -1 "$CASE_LOG")" == 'gate final' ]] || fail_test 'final gate was not the last operation before refusal'

make_case persisted-open approved-for-merge 57
write_pr OPEN
run_merge >"$CASE_ROOT/open-result.json"
jq -e '.status=="merged" and .pullRequest==57' "$CASE_ROOT/open-result.json" >/dev/null

make_case approved-merged-remote-approved approved-for-merge 57
write_pr MERGED
printf 'CLOSED\n' >"$CASE_GH/issue-state"; printf 'state:approved-for-merge\n' >"$CASE_GH/issue-label"
run_merge >"$CASE_ROOT/recovery-approved.json"
jq -e '.status=="already-merged" and .pullRequest==57' "$CASE_ROOT/recovery-approved.json" >/dev/null
jq -e '.state=="merged" and .pullRequest==57' "$CASE_PRIMARY/.artifacts/issues/42/state.json" >/dev/null
grep -Fxq 'gh issue edit approved-to-merged' "$CASE_LOG" || fail_test 'approved remote label did not converge during persisted-MERGED recovery'

make_case approved-merged-remote-merged approved-for-merge 57
write_pr MERGED
printf 'CLOSED\n' >"$CASE_GH/issue-state"; printf 'state:merged\n' >"$CASE_GH/issue-label"
run_merge >"$CASE_ROOT/recovery-merged.json"
jq -e '.status=="already-merged" and .pullRequest==57' "$CASE_ROOT/recovery-merged.json" >/dev/null
jq -e '.state=="merged" and .pullRequest==57' "$CASE_PRIMARY/.artifacts/issues/42/state.json" >/dev/null
if grep -Fxq 'gh issue edit approved-to-merged' "$CASE_LOG"; then fail_test 'already-merged remote label was edited again'; fi

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
