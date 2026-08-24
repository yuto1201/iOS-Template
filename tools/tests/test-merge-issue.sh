#!/usr/bin/env bash
set -euo pipefail

source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-merge.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

repo_name='yuto1201/iOS-Template'
issue=42
branch='codex/42-merge-e2e'
worktree_relative='.worktrees/42-merge-e2e'
pr_number=57
merge_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

fail_test() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_fails() {
  local label=$1
  shift
  if "$@" >"$scratch/command.out" 2>"$scratch/command.err"; then
    fail_test "expected failure: $label"
  fi
}

write_fake_gh() {
  local destination=$1
  cat > "$scratch/fake-gh.patch-source" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir=${FAKE_GH_STATE:?}
log=${FAKE_OPERATION_LOG:?}
head=${FAKE_HEAD:?}
branch=${FAKE_BRANCH:?}
repo=${FAKE_REPO:?}
issue=${FAKE_ISSUE:?}
pr_number=${FAKE_PR_NUMBER:?}
merge_sha=${FAKE_MERGE_SHA:?}

die() { echo "unexpected fake gh invocation: $*" >&2; exit 2; }
expect_args() {
  local expected=$1
  shift
  [[ "$*" == "$expected" ]] || die "expected [$expected], got [$*]"
}
log_line() { printf '%s\n' "$1" >> "$log"; }
read_prs() { cat "$state_dir/prs.json"; }
current_pr_state() { jq -er 'if length == 1 then .[0].state else "NONE" end' "$state_dir/prs.json"; }

case "${1:-} ${2:-}" in
  'pr list')
    if [[ "$*" == "pr list --repo $repo --head $branch --state all --json number,state,headRefName,headRefOid" ]]; then
      log_line "gh pr list --repo $repo --head $branch --state all --json number,state,headRefName,headRefOid"
      read_prs
    elif [[ "$*" == "pr list --repo $repo --head $branch --state open --json number,state,headRefName,headRefOid" ]]; then
      log_line "gh pr list --repo $repo --head $branch --state open --json number,state,headRefName,headRefOid"
      if [[ "$(current_pr_state)" == OPEN ]]; then read_prs; else printf '[]\n'; fi
    else
      die 'invalid PR list arguments'
    fi
    ;;
  'pr create')
    [[ $# == 10 && $3 == --repo && $4 == "$repo" && $5 == --base && $6 == main && $7 == --head && $8 == "$branch" && $9 == --body ]] || die 'invalid PR create arguments'
    body_digest=$(printf '%s' "${10}" | shasum -a 256 | awk '{print $1}')
    [[ "$body_digest" == "${FAKE_EXPECTED_BODY_DIGEST:?}" ]] || die 'PR body differs from deterministic renderer output'
    [[ "$(current_pr_state)" == NONE ]] || die 'PR create was not idempotent'
    log_line "gh pr create --repo $repo --base main --head $branch --body sha256:$body_digest"
    HEAD_SHA="$head" BRANCH="$branch" PR="$pr_number" ruby -rjson -e 'puts JSON.generate([{"number" => Integer(ENV.fetch("PR")), "state" => "OPEN", "headRefName" => ENV.fetch("BRANCH"), "headRefOid" => ENV.fetch("HEAD_SHA")}])' > "$state_dir/prs.json"
    printf 'https://github.com/%s/pull/%s\n' "$repo" "$pr_number"
    ;;
  'pr merge')
    expect_args "pr merge $pr_number --repo $repo --squash --match-head-commit $head" "$@"
    [[ "$(current_pr_state)" == OPEN ]] || die 'only an open PR may be merged'
    log_line "gh pr merge $pr_number --repo $repo --squash --match-head-commit $head"
    HEAD_SHA="$head" BRANCH="$branch" PR="$pr_number" ruby -rjson -e 'puts JSON.generate([{"number" => Integer(ENV.fetch("PR")), "state" => "MERGED", "headRefName" => ENV.fetch("BRANCH"), "headRefOid" => ENV.fetch("HEAD_SHA")}])' > "$state_dir/prs.json"
    printf 'CLOSED\n' > "$state_dir/issue-state"
    ;;
  'pr view')
    expect_args "pr view $pr_number --repo $repo --json state,headRefOid,mergeCommit" "$@"
    [[ "$(current_pr_state)" == MERGED ]] || die 'PR confirmation requested for an unmerged PR'
    log_line "gh pr view $pr_number --repo $repo --json state,headRefOid,mergeCommit"
    HEAD_SHA="$head" MERGE_SHA="$merge_sha" ruby -rjson -e 'puts JSON.generate({"state" => "MERGED", "headRefOid" => ENV.fetch("HEAD_SHA"), "mergeCommit" => {"oid" => ENV.fetch("MERGE_SHA")}})'
    ;;
  'issue view')
    if [[ "$*" == "issue view $issue --repo $repo --json state" ]]; then
      log_line "gh issue view $issue --repo $repo --json state"
      jq -cn --arg state "$(cat "$state_dir/issue-state")" '{state:$state}'
    elif [[ "$*" == "issue view $issue --repo $repo --json labels" ]]; then
      log_line "gh issue view $issue --repo $repo --json labels"
      jq -cn --arg label "$(cat "$state_dir/issue-label")" '{labels:[{name:$label}]}'
    elif [[ "$*" == "issue view $issue --repo $repo --json labels,comments" ]]; then
      log_line "gh issue view $issue --repo $repo --json labels,comments"
      jq -cn --arg label "$(cat "$state_dir/issue-label")" '{labels:[{name:$label}],comments:[]}'
    else
      die 'invalid Issue view arguments'
    fi
    ;;
  'issue edit')
    expect_args "issue edit $issue --repo $repo --remove-label state:approved-for-merge --add-label state:merged" "$@"
    [[ "$(cat "$state_dir/issue-label")" == state:approved-for-merge ]] || die 'Issue transition started from the wrong label'
    log_line "gh issue edit $issue --repo $repo --remove-label state:approved-for-merge --add-label state:merged"
    printf 'state:merged\n' > "$state_dir/issue-label"
    ;;
  'issue comment')
    [[ $# == 7 && $3 == "$issue" && $4 == --repo && $5 == "$repo" && $6 == --body ]] || die 'invalid Issue comment arguments'
    MARKER=$7 ruby -rjson -e '
      match = ENV.fetch("MARKER").match(/\A<!-- ios-template-state (\{.*\}) -->\z/) or abort "invalid state marker"
      value = JSON.parse(match[1]); abort "wrong state marker" unless value["executor"] == "codex" && value["from"] == "approved-for-merge" && value["to"] == "merged" && value["resumeState"].nil? && value["timestamp"].is_a?(String)
    '
    log_line "gh issue comment $issue --repo $repo --body <approved-for-merge-to-merged-marker>"
    ;;
  *) die "$*" ;;
esac
EOF
  cp "$scratch/fake-gh.patch-source" "$destination"
  chmod +x "$destination"
}

write_preflight_stub() {
  local destination=$1
  cat > "$scratch/preflight-stub.patch-source" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 8 && $1 == --repo && $2 == "${FAKE_REPO:?}" && $3 == --issue && $4 == "${FAKE_ISSUE:?}" && $5 == --intended-operation && $7 == --expected-head && $8 == "${FAKE_HEAD:?}" ]] || { echo "preflight arguments differ: [$*]" >&2; exit 2; }
case "$6" in github.push_branch|github.create_pr|github.merge_pr) ;; *) echo "unexpected preflight operation: $6" >&2; exit 2 ;; esac
printf 'preflight %s\n' "$*" >> "${FAKE_OPERATION_LOG:?}"
EOF
  cp "$scratch/preflight-stub.patch-source" "$destination"
  chmod +x "$destination"
}

write_gate_stub() {
  local destination=$1
  cat > "$scratch/gate-stub.patch-source" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
expected="--issue ${FAKE_ISSUE:?} --head-sha ${FAKE_HEAD:?}"
[[ "$*" == "$expected" ]] || { echo "gate arguments differ: [$*]" >&2; exit 2; }
printf 'gate %s\n' "$*" >> "${FAKE_OPERATION_LOG:?}"
printf '{"status":"passed"}\n'
EOF
  cp "$scratch/gate-stub.patch-source" "$destination"
  chmod +x "$destination"
}

make_case() {
  local name=$1 initial_pr_state=$2 expected_body
  CASE_ROOT="$scratch/$name"
  CASE_PRIMARY="$CASE_ROOT/repo"
  CASE_REMOTE="$CASE_ROOT/remote.git"
  CASE_WORKTREE="$CASE_PRIMARY/$worktree_relative"
  CASE_STATE="$CASE_PRIMARY/.artifacts/issues/$issue/state.json"
  CASE_GH_STATE="$CASE_ROOT/gh-state"
  CASE_LOG="$CASE_ROOT/operations.log"
  CASE_BIN="$CASE_ROOT/bin"
  mkdir -p "$CASE_ROOT" "$CASE_GH_STATE" "$CASE_BIN"

  git init --bare "$CASE_REMOTE" >/dev/null
  git init -b main "$CASE_PRIMARY" >/dev/null
  git -C "$CASE_PRIMARY" config user.name 'Merge Fixture'
  git -C "$CASE_PRIMARY" config user.email 'merge-fixture@example.invalid'
  printf 'base\n' > "$CASE_PRIMARY/README.md"
  git -C "$CASE_PRIMARY" add README.md
  git -C "$CASE_PRIMARY" commit -m base >/dev/null
  CASE_BASE=$(git -C "$CASE_PRIMARY" rev-parse HEAD)
  git -C "$CASE_PRIMARY" remote add origin "$CASE_REMOTE"
  git -C "$CASE_PRIMARY" push origin main >/dev/null
  mkdir -p "$CASE_PRIMARY/.worktrees"
  git -C "$CASE_PRIMARY" worktree add -b "$branch" "$CASE_WORKTREE" main >/dev/null

  mkdir -p "$CASE_WORKTREE/tools/lib" "$CASE_PRIMARY/.artifacts/issues/$issue"
  cp "$source_root/tools/merge-issue.sh" "$source_root/tools/render-pr-body.sh" "$source_root/tools/issue-state.sh" "$CASE_WORKTREE/tools/"
  cp "$source_root/tools/lib/workflow.sh" "$source_root/tools/lib/workflow-json.rb" "$CASE_WORKTREE/tools/lib/"
  write_preflight_stub "$CASE_WORKTREE/tools/github-account-preflight.sh"
  write_gate_stub "$CASE_WORKTREE/tools/premerge-gate.sh"
  ln -s ../../.artifacts "$CASE_WORKTREE/.artifacts"
  git -C "$CASE_WORKTREE" add tools
  git -C "$CASE_WORKTREE" commit -m 'install merge workflow' >/dev/null
  CASE_HEAD=$(git -C "$CASE_WORKTREE" rev-parse HEAD)

  mkdir -p "$CASE_PRIMARY/.artifacts/issues/$issue/$CASE_HEAD"
  CONTRACT_PATH="$CASE_PRIMARY/.artifacts/issues/$issue/issue-contract.json" ruby -rjson -e '
    value = {"schemaVersion" => 1, "issue" => 42, "repository" => "yuto1201/iOS-Template", "goal" => "Merge verified work.", "specAnchors" => ["docs/workflow.md"], "acceptanceCriteria" => [{"id" => "AC-1", "text" => "Merge the exact verified Head."}], "dependencies" => [], "externalOperations" => [], "fetchedAt" => "2026-08-24T00:00:00Z"}
    File.binwrite(ENV.fetch("CONTRACT_PATH"), JSON.generate(value))
  '
  CASE_DIGEST="sha256:$(shasum -a 256 "$CASE_PRIMARY/.artifacts/issues/$issue/issue-contract.json" | awk '{print $1}')"
  HEAD_SHA="$CASE_HEAD" BASE_SHA="$CASE_BASE" DIGEST="$CASE_DIGEST" VERIFY_PATH="$CASE_PRIMARY/.artifacts/issues/$issue/$CASE_HEAD/verify.json" ruby -rjson -e '
    value = {"status" => "not-applicable", "headSha" => ENV.fetch("HEAD_SHA"), "baseSha" => ENV.fetch("BASE_SHA"), "issueContract" => {"digest" => ENV.fetch("DIGEST")}, "matrixFile" => nil, "matrixDigest" => nil, "acceptanceEvidence" => [{"id" => "AC-1", "status" => "passed", "evidence" => ["documents:workflow"]}]}
    File.binwrite(ENV.fetch("VERIFY_PATH"), JSON.generate(value))
  '
  HEAD_SHA="$CASE_HEAD" DIGEST="$CASE_DIGEST" REVIEW_PATH="$CASE_PRIMARY/.artifacts/issues/$issue/$CASE_HEAD/review.json" ruby -rjson -e '
    value = {"headSha" => ENV.fetch("HEAD_SHA"), "verifySha" => ENV.fetch("HEAD_SHA"), "issueContractDigest" => ENV.fetch("DIGEST"), "verdict" => "approved", "findings" => []}
    File.binwrite(ENV.fetch("REVIEW_PATH"), JSON.generate(value))
  '
  HEAD_SHA="$CASE_HEAD" BASE_SHA="$CASE_BASE" DIGEST="$CASE_DIGEST" STATE_PATH="$CASE_STATE" ruby -rjson -e '
    value = {"schemaVersion" => 1, "issue" => 42, "repository" => "yuto1201/iOS-Template", "branch" => "codex/42-merge-e2e", "worktree" => ".worktrees/42-merge-e2e", "baseSha" => ENV.fetch("BASE_SHA"), "primaryImplementer" => "codex", "issueContract" => {"path" => ".artifacts/issues/42/issue-contract.json", "digest" => ENV.fetch("DIGEST")}, "state" => "approved-for-merge", "previousState" => "review-requested", "resumeState" => nil, "executor" => "codex", "headSha" => ENV.fetch("HEAD_SHA"), "from" => "review-requested", "to" => "approved-for-merge", "transitionedAt" => "2026-08-24T00:02:30Z"}
    File.binwrite(ENV.fetch("STATE_PATH"), JSON.generate(value))
  '

  case "$initial_pr_state" in
    NONE) printf '[]\n' > "$CASE_GH_STATE/prs.json" ;;
    OPEN|CLOSED|MERGED)
      STATE="$initial_pr_state" HEAD_SHA="$CASE_HEAD" BRANCH="$branch" PR="$pr_number" ruby -rjson -e 'puts JSON.generate([{"number" => Integer(ENV.fetch("PR")), "state" => ENV.fetch("STATE"), "headRefName" => ENV.fetch("BRANCH"), "headRefOid" => ENV.fetch("HEAD_SHA")}])' > "$CASE_GH_STATE/prs.json"
      ;;
    *) fail_test "invalid fixture PR state: $initial_pr_state" ;;
  esac
  if [[ "$initial_pr_state" == MERGED ]]; then printf 'CLOSED\n' > "$CASE_GH_STATE/issue-state"; else printf 'OPEN\n' > "$CASE_GH_STATE/issue-state"; fi
  printf 'state:approved-for-merge\n' > "$CASE_GH_STATE/issue-label"
  : > "$CASE_LOG"
  write_fake_gh "$CASE_BIN/gh"

  expected_body=$("$CASE_WORKTREE/tools/render-pr-body.sh" --issue "$issue" --head-sha "$CASE_HEAD")
  printf '%s' "$expected_body" > "$CASE_ROOT/expected-body.md"
  CASE_BODY_DIGEST=$(shasum -a 256 "$CASE_ROOT/expected-body.md" | awk '{print $1}')
}

run_merge() {
  FAKE_REPO="$repo_name" FAKE_ISSUE="$issue" FAKE_BRANCH="$branch" FAKE_HEAD="$CASE_HEAD" FAKE_PR_NUMBER="$pr_number" FAKE_MERGE_SHA="$merge_sha" FAKE_GH_STATE="$CASE_GH_STATE" FAKE_OPERATION_LOG="$CASE_LOG" FAKE_EXPECTED_BODY_DIGEST="$CASE_BODY_DIGEST" GIT_TERMINAL_PROMPT=0 PATH="$CASE_BIN:$PATH" \
    "$CASE_WORKTREE/tools/merge-issue.sh" --repo "$repo_name" --issue "$issue"
}

assert_merged_state() {
  jq -e --arg head "$CASE_HEAD" --argjson pr "$pr_number" '
    .state == "merged" and .previousState == "approved-for-merge" and .from == "approved-for-merge" and .to == "merged" and
    (.transitionedAt | type == "string") and .headSha == $head and .pullRequest == $pr
  ' "$CASE_STATE" >/dev/null || fail_test 'durable merged state did not persist exact transition, Head, and PR identity'
}

assert_log() {
  local expected=$1
  diff -u "$expected" "$CASE_LOG" || fail_test 'operation log order or arguments differed'
}

make_case new-pr NONE
run_merge > "$CASE_ROOT/result.json"
jq -e --arg head "$CASE_HEAD" --argjson pr "$pr_number" '.status == "merged" and .issue == 42 and .pullRequest == $pr and .headSha == $head' "$CASE_ROOT/result.json" >/dev/null
assert_merged_state
cat > "$CASE_ROOT/expected.log" <<EOF
gh pr list --repo $repo_name --head $branch --state all --json number,state,headRefName,headRefOid
preflight --repo $repo_name --issue $issue --intended-operation github.push_branch --expected-head $CASE_HEAD
preflight --repo $repo_name --issue $issue --intended-operation github.create_pr --expected-head $CASE_HEAD
gh pr create --repo $repo_name --base main --head $branch --body sha256:$CASE_BODY_DIGEST
gh pr list --repo $repo_name --head $branch --state open --json number,state,headRefName,headRefOid
preflight --repo $repo_name --issue $issue --intended-operation github.merge_pr --expected-head $CASE_HEAD
gate --issue $issue --head-sha $CASE_HEAD
gh pr merge $pr_number --repo $repo_name --squash --match-head-commit $CASE_HEAD
gh pr view $pr_number --repo $repo_name --json state,headRefOid,mergeCommit
gh issue view $issue --repo $repo_name --json state
gh issue view $issue --repo $repo_name --json labels
gh issue view $issue --repo $repo_name --json labels,comments
gh issue view $issue --repo $repo_name --json labels,comments
gh issue edit $issue --repo $repo_name --remove-label state:approved-for-merge --add-label state:merged
gh issue view $issue --repo $repo_name --json labels,comments
gh issue comment $issue --repo $repo_name --body <approved-for-merge-to-merged-marker>
EOF
assert_log "$CASE_ROOT/expected.log"

make_case existing-open OPEN
run_merge > "$CASE_ROOT/result.json"
assert_merged_state
cat > "$CASE_ROOT/expected.log" <<EOF
gh pr list --repo $repo_name --head $branch --state all --json number,state,headRefName,headRefOid
preflight --repo $repo_name --issue $issue --intended-operation github.push_branch --expected-head $CASE_HEAD
preflight --repo $repo_name --issue $issue --intended-operation github.merge_pr --expected-head $CASE_HEAD
gate --issue $issue --head-sha $CASE_HEAD
gh pr merge $pr_number --repo $repo_name --squash --match-head-commit $CASE_HEAD
gh pr view $pr_number --repo $repo_name --json state,headRefOid,mergeCommit
gh issue view $issue --repo $repo_name --json state
gh issue view $issue --repo $repo_name --json labels
gh issue view $issue --repo $repo_name --json labels,comments
gh issue view $issue --repo $repo_name --json labels,comments
gh issue edit $issue --repo $repo_name --remove-label state:approved-for-merge --add-label state:merged
gh issue view $issue --repo $repo_name --json labels,comments
gh issue comment $issue --repo $repo_name --body <approved-for-merge-to-merged-marker>
EOF
assert_log "$CASE_ROOT/expected.log"

make_case closed-unmerged CLOSED
state_before=$(shasum -a 256 "$CASE_STATE" | awk '{print $1}')
assert_fails 'closed-unmerged PR is refused' run_merge
[[ "$(shasum -a 256 "$CASE_STATE" | awk '{print $1}')" == "$state_before" ]] || fail_test 'closed-unmerged refusal changed durable state'
cat > "$CASE_ROOT/expected.log" <<EOF
gh pr list --repo $repo_name --head $branch --state all --json number,state,headRefName,headRefOid
EOF
assert_log "$CASE_ROOT/expected.log"

make_case already-merged MERGED
run_merge > "$CASE_ROOT/result.json"
jq -e --arg head "$CASE_HEAD" --argjson pr "$pr_number" '.status == "already-merged" and .pullRequest == $pr and .headSha == $head' "$CASE_ROOT/result.json" >/dev/null
assert_merged_state
cat > "$CASE_ROOT/expected.log" <<EOF
gh pr list --repo $repo_name --head $branch --state all --json number,state,headRefName,headRefOid
gh pr view $pr_number --repo $repo_name --json state,headRefOid,mergeCommit
gh issue view $issue --repo $repo_name --json state
gh issue view $issue --repo $repo_name --json labels
gh issue view $issue --repo $repo_name --json labels,comments
gh issue view $issue --repo $repo_name --json labels,comments
gh issue edit $issue --repo $repo_name --remove-label state:approved-for-merge --add-label state:merged
gh issue view $issue --repo $repo_name --json labels,comments
gh issue comment $issue --repo $repo_name --body <approved-for-merge-to-merged-marker>
EOF
assert_log "$CASE_ROOT/expected.log"

make_case already-merged-remote-state MERGED
printf 'state:merged\n' > "$CASE_GH_STATE/issue-label"
run_merge > "$CASE_ROOT/result.json"
jq -e --arg head "$CASE_HEAD" --argjson pr "$pr_number" '.status == "already-merged" and .pullRequest == $pr and .headSha == $head' "$CASE_ROOT/result.json" >/dev/null
assert_merged_state
cat > "$CASE_ROOT/expected.log" <<EOF
gh pr list --repo $repo_name --head $branch --state all --json number,state,headRefName,headRefOid
gh pr view $pr_number --repo $repo_name --json state,headRefOid,mergeCommit
gh issue view $issue --repo $repo_name --json state
gh issue view $issue --repo $repo_name --json labels
EOF
assert_log "$CASE_ROOT/expected.log"

echo 'PASS: merge workflow covers new, open, closed-unmerged, and both already-merged convergence paths'
