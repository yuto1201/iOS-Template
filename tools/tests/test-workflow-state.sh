#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-workflow-state.XXXXXX")
test_issue=424249
artifact_issue="$repo_root/.artifacts/issues/$test_issue"
request_dir="$repo_root/.artifacts/ops-requests"
result_dir="$repo_root/.artifacts/ops-results"
[[ ! -e "$artifact_issue" ]] || { echo "refusing to overwrite existing $artifact_issue" >&2; exit 1; }
state_worktree=''
cleanup() {
  if [[ -n "$state_worktree" && -e "$state_worktree" ]]; then git -C "$repo_root" worktree remove --force "$state_worktree" >/dev/null 2>&1 || true; fi
  git -C "$repo_root" branch -D "codex/$test_issue-workflow-state" >/dev/null 2>&1 || true
  rm -rf "$workspace" "$artifact_issue" "$request_dir/issue-424249-create-pr-1.json" "$request_dir/create-issue.json" "$request_dir/bad.json" "$request_dir/cloudflare-deploy.json" "$request_dir/elevenlabs-audio.json" "$request_dir/appstore-build.json" "$request_dir/supabase-migrations.json" "$request_dir/path-link" "$result_dir/issue-424249-create-pr-1.json"
}
trap cleanup EXIT

fake_bin="$workspace/bin"
mkdir -p "$fake_bin" "$request_dir" "$result_dir"
cp "$repo_root/tools/tests/fixtures/gh" "$fake_bin/gh"
chmod +x "$fake_bin/gh"
cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_CODEX_REQUIRE_CLOSED_STDIN:-}" ]]; then
  ruby -e 'exit(STDIN.stat.rdev == File.stat("/dev/null").rdev ? 0 : 1)' || exit 97
fi
if [[ -n "${FAKE_CODEX_MUTATE_REQUEST:-}" ]]; then
  cp "${FAKE_CODEX_MUTATION_FILE:?FAKE_CODEX_MUTATION_FILE is required}" "$FAKE_CODEX_MUTATE_REQUEST"
fi
printf '%s\n' '{"status":"succeeded","executor":"codex","verifiedAccount":"yuto1201","target":"yuto1201/iOS-Template","operation":"github.create_pr","resultReference":"https://github.com/yuto1201/iOS-Template/pull/424249","executedAt":"2026-08-24T00:00:00Z","token":"must-not-survive"}'
EOF
chmod +x "$fake_bin/codex"
real_git=$(command -v git)
cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_GIT_HEAD_WORKTREE:-}" && "$*" == "-C $FAKE_GIT_HEAD_WORKTREE rev-parse HEAD" ]]; then
  count_file=${FAKE_GIT_HEAD_COUNT_FILE:?}; count=$(($(cat "$count_file" 2>/dev/null || printf 0)+1)); printf '%s' "$count" >"$count_file"
  if [[ -n "${FAKE_GIT_HEAD_CHANGE_AFTER_EDIT:-}" ]] && rg -q '^issue edit ' "${FAKE_GH_LOG:?}"; then printf '0000000000000000000000000000000000000000\n'; exit 0; fi
  if [[ -n "${FAKE_GIT_HEAD_RACE_AFTER:-}" && "$count" -gt "$FAKE_GIT_HEAD_RACE_AFTER" ]]; then printf '0000000000000000000000000000000000000000\n'; exit 0; fi
fi
exec "${REAL_GIT:?}" "$@"
EOF
chmod +x "$fake_bin/git"

export PATH="$fake_bin:$PATH"
export FAKE_GH_LOG="$workspace/gh.log"
export FAKE_GH_LABELS_FILE="$workspace/labels.json"
export FAKE_GH_COMMENTS_FILE="$workspace/comments.json"
export FAKE_GH_VIEW_COUNT_FILE="$workspace/issue-view-count"
export REAL_GIT="$real_git"
export FAKE_GH_ISSUE_BODY="$workspace/issue-body.md"
cat > "$FAKE_GH_ISSUE_BODY" <<'EOF'
## Goal

Exercise authenticated workflow state.

## In scope

- State transitions.

## Out of scope

- Application behavior.

## Acceptance criteria

- AC-1: State changes are authorized.

## Spec anchors

- [Issue Definition of Ready](specs/acceptance.md#2-issue-definition-of-ready)

## Dependencies

- None.

## UI verification

- Not applicable.

## External operations

- Operation: github.read_issue
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

- Operation: github.update_issue
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

## User approvals

- No additional approval.
EOF
printf '["state:approved"]' > "$FAKE_GH_LABELS_FILE"
printf '[]' > "$FAKE_GH_COMMENTS_FILE"

assert_fails() {
  local message=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "expected failure: $message" >&2
    exit 1
  fi
}

assert_json() {
  local path=$1 code=$2
  ruby -rjson -e "$code" "$path"
}

cd "$repo_root"
mkdir -p "$artifact_issue"

# Before Claim there is no sealed contract. Reads and the proposed -> approved
# transition must be authorized from the freshly read Issue body and exact argv.
printf '["state:proposed"]' > "$FAKE_GH_LABELS_FILE"
"$repo_root/tools/issue-state.sh" get --repo yuto1201/iOS-Template --issue "$test_issue" >/dev/null
"$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from proposed --to approved >/dev/null
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:approved"]'

printf '["state:claimed"]' > "$FAKE_GH_LABELS_FILE"
assert_fails 'stale minimal pre-Claim state cannot authorize a post-Claim live read' "$repo_root/tools/issue-state.sh" get --repo yuto1201/iOS-Template --issue "$test_issue"
printf '["state:approved"]' > "$FAKE_GH_LABELS_FILE"
ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["timestamp"]="not-a-time"; File.binwrite(path,JSON.generate(value))' "$artifact_issue/state.json"
assert_fails 'malformed unsealed pre-Claim state cannot authorize a live read' "$repo_root/tools/issue-state.sh" get --repo yuto1201/iOS-Template --issue "$test_issue"
cat > "$artifact_issue/state.json" <<EOF
{"schemaVersion":1,"issue":$test_issue,"repository":"yuto1201/iOS-Template","branch":"codex/$test_issue-workflow-state","worktree":".worktrees/$test_issue-workflow-state","baseSha":"$(git -C "$repo_root" rev-parse HEAD)","primaryImplementer":"codex","issueContract":{"path":".artifacts/issues/$test_issue/issue-contract.json","digest":"sha256:$(printf '0%.0s' {1..64})"},"state":"approved","previousState":null,"resumeState":null,"executor":"codex"}
EOF
assert_fails 'full state without its sealed contract cannot fall back to the live Issue' "$repo_root/tools/issue-state.sh" get --repo yuto1201/iOS-Template --issue "$test_issue"
rm -f "$artifact_issue/state.json"
printf '["state:blocked:review"]' > "$FAKE_GH_LABELS_FILE"
assert_fails 'post-Claim state without durable evidence cannot recreate live authorization' "$repo_root/tools/issue-state.sh" get --repo yuto1201/iOS-Template --issue "$test_issue"
printf '["state:approved"]' > "$FAKE_GH_LABELS_FILE"
rm -f "$artifact_issue/state.json" "$artifact_issue/state-transition.pending.json"
printf '[]' > "$FAKE_GH_COMMENTS_FILE"

ruby "$repo_root/tools/lib/issue-contract.rb" --body "$FAKE_GH_ISSUE_BODY" --type feature --format contract \
  --issue "$test_issue" --repo yuto1201/iOS-Template --fetched-at 2026-08-24T00:00:00Z \
  > "$artifact_issue/issue-contract.json"

# A wrong account must prevent the preflight artifact from being written.
export FAKE_GH_LOGIN=company-account
assert_fails 'company GitHub account is rejected' "$repo_root/tools/github-account-preflight.sh" --repo yuto1201/iOS-Template
[[ ! -e ".artifacts/issues/$test_issue/github-preflight.json" ]]
unset FAKE_GH_LOGIN

# Inspect mode is read-only and returns only safe repository identity fields.
"$repo_root/tools/github-account-preflight.sh" --repo yuto1201/iOS-Template > "$workspace/preflight-inspect.json"
assert_json "$workspace/preflight-inspect.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value.keys.sort == %w[account defaultBranch repository url]; abort unless value["account"] == "yuto1201"'
[[ ! -e ".artifacts/issues/$test_issue/github-preflight.json" ]]

export FAKE_GH_REPO_OWNER=other/iOS-Template
assert_fails 'repository owner mismatch is rejected' "$repo_root/tools/github-account-preflight.sh" --repo yuto1201/iOS-Template
unset FAKE_GH_REPO_OWNER

# Every authenticated Issue read has a fresh exact personal-account/repository
# preflight. Outside the exact approved -> claimed path, authorization comes
# from the sealed contract rather than an ambient live-body switch.
: > "$FAKE_GH_LOG"
"$repo_root/tools/issue-state.sh" get --repo yuto1201/iOS-Template --issue "$test_issue" >/dev/null
ruby -e '
  lines = File.readlines(ARGV[0], chomp: true)
  read = lines.index { |line| line.start_with?("issue view ") } or abort "missing Issue read"
  abort "Issue read lacked immediate fresh preflight" unless lines[(read - 2)...read].any? { |line| line.start_with?("auth status --active") } && lines[(read - 2)...read].any? { |line| line.start_with?("repo view yuto1201/iOS-Template") }
' "$FAKE_GH_LOG"

cp "$FAKE_GH_ISSUE_BODY" "$workspace/issue-body-valid.md"
ruby -e 'path=ARGV.fetch(0); text=File.read(path); text.sub!(/- Operation: github\.read_issue\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n/, ""); File.write(path,text)' "$FAKE_GH_ISSUE_BODY"
rm -f ".artifacts/issues/$test_issue/state.json"
: > "$FAKE_GH_LOG"
assert_fails 'approved to claimed requires github.read_issue in the live contract' "$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from approved --to claimed
! rg -q '^issue edit |^issue comment ' "$FAKE_GH_LOG"
cp "$workspace/issue-body-valid.md" "$FAKE_GH_ISSUE_BODY"

ruby -e 'path=ARGV.fetch(0); text=File.read(path); text.sub!(/- Operation: github\.update_issue\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n?/, ""); File.write(path,text)' "$FAKE_GH_ISSUE_BODY"
: > "$FAKE_GH_LOG"
assert_fails 'Issue mutation without github.update_issue declaration is rejected' "$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from approved --to claimed
! rg -q '^issue edit |^issue comment ' "$FAKE_GH_LOG"
cp "$workspace/issue-body-valid.md" "$FAKE_GH_ISSUE_BODY"

head_sha=$(git -C "$repo_root" rev-parse HEAD)
"$repo_root/tools/github-account-preflight.sh" --repo yuto1201/iOS-Template --issue "$test_issue" --intended-operation github.create_pr --expected-head "$head_sha"
assert_json ".artifacts/issues/$test_issue/github-preflight.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["issue"] == 424249 && value["headSha"] =~ /\A[0-9a-f]{40}\z/ && value["digest"] =~ /\Asha256:[0-9a-f]{64}\z/; abort if value.to_json.include?("token")'

# A merge preflight has no evidence shortcut: both canonical records must be present and older than the new check.
merge_evidence=".artifacts/issues/$test_issue/$head_sha"
mkdir -p "$merge_evidence"
assert_fails 'merge preflight rejects missing evidence' "$repo_root/tools/github-account-preflight.sh" --repo yuto1201/iOS-Template --issue "$test_issue" --intended-operation github.merge_pr --expected-head "$head_sha"
printf '{"completedAt":"2999-01-01T00:00:00Z"}' > "$merge_evidence/verify.json"
printf '{"reviewedAt":"2999-01-01T00:00:00Z"}' > "$merge_evidence/review.json"
assert_fails 'merge preflight rejects stale evidence' "$repo_root/tools/github-account-preflight.sh" --repo yuto1201/iOS-Template --issue "$test_issue" --intended-operation github.merge_pr --expected-head "$head_sha"
printf '{"completedAt":"2000-01-01T00:00:00Z"}' > "$merge_evidence/verify.json"
printf '{"reviewedAt":"2000-01-01T00:00:00Z"}' > "$merge_evidence/review.json"
"$repo_root/tools/github-account-preflight.sh" --repo yuto1201/iOS-Template --issue "$test_issue" --intended-operation github.merge_pr --expected-head "$head_sha" > "$workspace/merge-preflight.json"
assert_json "$workspace/merge-preflight.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["intendedOperation"] == "github.merge_pr"'

export FAKE_GH_ISSUE_MISSING=1
assert_fails 'missing issue is rejected' "$repo_root/tools/issue-state.sh" get --repo yuto1201/iOS-Template --issue "$test_issue"
unset FAKE_GH_ISSUE_MISSING

printf '["state:not-a-workflow-state"]' > "$FAKE_GH_LABELS_FILE"
assert_fails 'unknown Issue state label is rejected' "$repo_root/tools/issue-state.sh" get --repo yuto1201/iOS-Template --issue "$test_issue"
printf '["state:approved"]' > "$FAKE_GH_LABELS_FILE"

assert_fails 'invalid transition is rejected' "$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from approved --to merged
"$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from approved --to claimed > "$workspace/transition.json"
assert_json "$workspace/transition.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["from"] == "approved" && value["to"] == "claimed" && value["executor"] == "codex"'
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:claimed"]'
assert_json ".artifacts/issues/$test_issue/state.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["state"] == "claimed" && value["resumeState"].nil?'

# A concurrent state change before edit must stop the requested mutation.
printf '[]' > "$FAKE_GH_COMMENTS_FILE"
printf '[]' > "$FAKE_GH_LOG"
printf '0' > "$FAKE_GH_VIEW_COUNT_FILE"
printf '["state:approved"]' > "$FAKE_GH_LABELS_FILE"
rm -f ".artifacts/issues/$test_issue/state.json" ".artifacts/issues/$test_issue/state-transition.pending.json"
export FAKE_GH_RACE_BEFORE_EDIT_VIEW=2
export FAKE_GH_RACE_BEFORE_EDIT_LABELS='["state:in-progress"]'
assert_fails 'transition recheck rejects a changed current state' "$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from approved --to claimed
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:in-progress"]'
! rg -q '^issue edit ' "$FAKE_GH_LOG"
unset FAKE_GH_RACE_BEFORE_EDIT_VIEW FAKE_GH_RACE_BEFORE_EDIT_LABELS
rm -f ".artifacts/issues/$test_issue/state-transition.pending.json"

# The postcondition is checked before a marker or local durable state is written.
printf '[]' > "$FAKE_GH_COMMENTS_FILE"
printf '0' > "$FAKE_GH_VIEW_COUNT_FILE"
printf '["state:approved"]' > "$FAKE_GH_LABELS_FILE"
rm -f ".artifacts/issues/$test_issue/state.json" ".artifacts/issues/$test_issue/state-transition.pending.json"
export FAKE_GH_RACE_AFTER_EDIT_LABELS='["state:in-progress"]'
assert_fails 'transition post-read rejects a changed result state' "$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from approved --to claimed
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:in-progress"]'
assert_json "$FAKE_GH_COMMENTS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])).empty?'
unset FAKE_GH_RACE_AFTER_EDIT_LABELS
rm -f ".artifacts/issues/$test_issue/state-transition.pending.json"

printf '["state:blocked:ops"]' > "$FAKE_GH_LABELS_FILE"
printf '[]' > "$FAKE_GH_COMMENTS_FILE"
rm -f ".artifacts/issues/$test_issue/state.json"
mkdir -p ".artifacts/issues/$test_issue"
ruby "$repo_root/tools/lib/issue-contract.rb" --body "$FAKE_GH_ISSUE_BODY" --type feature --format contract \
  --issue "$test_issue" --repo yuto1201/iOS-Template --fetched-at 2026-08-24T00:00:00Z \
  > ".artifacts/issues/$test_issue/issue-contract.json"
assert_fails 'blocked resume without history fails closed' "$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from blocked:ops --to in-progress
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:blocked:conflict"]'

# Once Claim has created the full Task 4 identity record, every Task 2
# transition must retain it exactly while changing only transition metadata.
head_sha=$(git -C "$repo_root" rev-parse HEAD)
state_worktree="$repo_root/.worktrees/$test_issue-workflow-state"
git -C "$repo_root" worktree add -b "codex/$test_issue-workflow-state" "$state_worktree" "$head_sha" >/dev/null
ln -s ../../.artifacts "$state_worktree/.artifacts"
cp "$repo_root/tools/issue-state.sh" "$state_worktree/tools/issue-state.sh"
cp "$repo_root/tools/lib/workflow-json.rb" "$repo_root/tools/lib/workflow.sh" "$state_worktree/tools/lib/"
export FAKE_GIT_HEAD_WORKTREE="$state_worktree" FAKE_GIT_HEAD_COUNT_FILE="$workspace/head-count"
contract_digest="sha256:$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' ".artifacts/issues/$test_issue/issue-contract.json")"
cat > ".artifacts/issues/$test_issue/state.json" <<EOF
{"schemaVersion":1,"issue":$test_issue,"repository":"yuto1201/iOS-Template","branch":"codex/$test_issue-workflow-state","worktree":".worktrees/$test_issue-workflow-state","baseSha":"$head_sha","primaryImplementer":"codex","issueContract":{"path":".artifacts/issues/$test_issue/issue-contract.json","digest":"$contract_digest"},"state":"claimed","previousState":"approved","resumeState":null,"executor":"codex","pullRequest":424249}
EOF
printf '["state:claimed"]' > "$FAKE_GH_LABELS_FILE"
printf '[]' > "$FAKE_GH_COMMENTS_FILE"

# An attacker-controlled environment variable must not switch any post-Claim
# transition back to the mutable live Issue body. The live body authorizes the
# mutation, while this sealed contract intentionally does not.
cp ".artifacts/issues/$test_issue/issue-contract.json" "$workspace/contract-before-ambient-env.json"
cp ".artifacts/issues/$test_issue/state.json" "$workspace/state-before-ambient-env.json"
cp "$FAKE_GH_ISSUE_BODY" "$workspace/sealed-read-only-body.md"
ruby -e 'path=ARGV.fetch(0); text=File.read(path); text.sub!(/- Operation: github\.update_issue\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n?/, ""); File.write(path,text)' "$workspace/sealed-read-only-body.md"
ruby "$repo_root/tools/lib/issue-contract.rb" --body "$workspace/sealed-read-only-body.md" --type feature --format contract \
  --issue "$test_issue" --repo yuto1201/iOS-Template --fetched-at 2026-08-24T00:00:00Z \
  > ".artifacts/issues/$test_issue/issue-contract.json"
assert_json ".artifacts/issues/$test_issue/issue-contract.json" 'abort if JSON.parse(File.read(ARGV[0])).fetch("externalOperations").include?("github.update_issue")'
restricted_contract_digest="sha256:$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' ".artifacts/issues/$test_issue/issue-contract.json")"
DIGEST="$restricted_contract_digest" ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value.fetch("issueContract")["digest"]=ENV.fetch("DIGEST"); File.binwrite(path,JSON.generate(value))' ".artifacts/issues/$test_issue/state.json"
: > "$FAKE_GH_LOG"
WORKFLOW_USE_LIVE_ISSUE_CONTRACT=1 assert_fails 'ambient live-contract variable cannot authorize a later transition' "$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from claimed --to in-progress
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:claimed"]'
! rg -q '^issue edit |^issue comment ' "$FAKE_GH_LOG"
cp "$workspace/contract-before-ambient-env.json" ".artifacts/issues/$test_issue/issue-contract.json"
cp "$workspace/state-before-ambient-env.json" ".artifacts/issues/$test_issue/state.json"

assert_fails 'Head argument is forbidden outside in-progress to verify-passed' "$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from claimed --to in-progress --head-sha "$head_sha"
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from claimed --to in-progress >/dev/null

: > "$FAKE_GH_LOG"
cp ".artifacts/issues/$test_issue/state.json" "$workspace/in-progress-state.json"
assert_fails 'verify-passed requires an explicit Head' "$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from in-progress --to verify-passed
assert_fails 'verify-passed rejects a wrong explicit Head' "$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from in-progress --to verify-passed --head-sha 0000000000000000000000000000000000000000
cmp -s "$workspace/in-progress-state.json" ".artifacts/issues/$test_issue/state.json"
! rg -q '^issue edit ' "$FAKE_GH_LOG"

printf '0' > "$FAKE_GIT_HEAD_COUNT_FILE"
export FAKE_GIT_HEAD_RACE_AFTER=1
assert_fails 'Head change before GitHub mutation is rejected' "$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from in-progress --to verify-passed --head-sha "$head_sha"
unset FAKE_GIT_HEAD_RACE_AFTER
cmp -s "$workspace/in-progress-state.json" ".artifacts/issues/$test_issue/state.json"
! rg -q '^issue edit ' "$FAKE_GH_LOG"

printf '0' > "$FAKE_GIT_HEAD_COUNT_FILE"
: > "$FAKE_GH_LOG"
cp "$FAKE_GH_COMMENTS_FILE" "$workspace/comments-before-head-race.json"
export FAKE_GIT_HEAD_CHANGE_AFTER_EDIT=1
assert_fails 'Head change after label mutation stops comment and durable write' "$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from in-progress --to verify-passed --head-sha "$head_sha"
unset FAKE_GIT_HEAD_CHANGE_AFTER_EDIT
rg -q '^issue edit ' "$FAKE_GH_LOG"
cmp -s "$workspace/comments-before-head-race.json" "$FAKE_GH_COMMENTS_FILE"
cmp -s "$workspace/in-progress-state.json" ".artifacts/issues/$test_issue/state.json"
printf '["state:in-progress"]' > "$FAKE_GH_LABELS_FILE"
rm -f ".artifacts/issues/$test_issue/state-transition.pending.json"

printf '0' > "$FAKE_GIT_HEAD_COUNT_FILE"
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from in-progress --to verify-passed --head-sha "$head_sha" >/dev/null
EXPECTED_HEAD="$head_sha" assert_json ".artifacts/issues/$test_issue/state.json" 'value=JSON.parse(File.read(ARGV[0])); abort unless value["state"]=="verify-passed" && value["headSha"]==ENV.fetch("EXPECTED_HEAD")'

"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from verify-passed --to in-progress >/dev/null
assert_json ".artifacts/issues/$test_issue/state.json" 'value=JSON.parse(File.read(ARGV[0])); abort unless value["state"]=="in-progress" && !value.key?("headSha")'
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from in-progress --to verify-passed --head-sha "$head_sha" >/dev/null

for transition in 'verify-passed review-requested' 'review-requested approved-for-merge'; do
  read -r from to <<< "$transition"
  "$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from "$from" --to "$to" >/dev/null
  EXPECTED_STATE="$to" EXPECTED_HEAD="$head_sha" EXPECTED_CONTRACT_DIGEST="$contract_digest" assert_json ".artifacts/issues/$test_issue/state.json" '
    value = JSON.parse(File.read(ARGV[0]))
    abort unless value["schemaVersion"] == 1 && value["issue"] == 424249 && value["repository"] == "yuto1201/iOS-Template"
    abort unless value["branch"] == "codex/424249-workflow-state" && value["worktree"] == ".worktrees/424249-workflow-state"
    abort unless value["primaryImplementer"] == "codex" && value.dig("issueContract", "path") == ".artifacts/issues/424249/issue-contract.json"
    abort unless value.dig("issueContract", "digest") == ENV.fetch("EXPECTED_CONTRACT_DIGEST")
    abort unless value["headSha"] == ENV.fetch("EXPECTED_HEAD") && value["pullRequest"] == 424249
    abort unless value["state"] == ENV.fetch("EXPECTED_STATE") && value["previousState"]
  '
done
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from approved-for-merge --to in-progress >/dev/null
assert_json ".artifacts/issues/$test_issue/state.json" 'value=JSON.parse(File.read(ARGV[0])); abort unless value["state"]=="in-progress" && !value.key?("headSha")'
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from in-progress --to verify-passed --head-sha "$head_sha" >/dev/null
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from verify-passed --to review-requested >/dev/null
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from review-requested --to approved-for-merge >/dev/null
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from approved-for-merge --to merged >/dev/null

# Blocked/resume recovery uses the durable marker and retains the same identity.
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from merged --to done >/dev/null
printf '["state:in-progress"]' > "$FAKE_GH_LABELS_FILE"
ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.read(path)); value["state"] = "in-progress"; value["previousState"] = "claimed"; value.delete("headSha"); File.write(path, JSON.generate(value))' ".artifacts/issues/$test_issue/state.json"
printf '[]' > "$FAKE_GH_COMMENTS_FILE"
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from in-progress --to blocked:ops >/dev/null
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from blocked:ops --to in-progress >/dev/null
assert_json ".artifacts/issues/$test_issue/state.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["state"] == "in-progress" && value["previousState"] == "blocked:ops" && value["resumeState"] == "in-progress" && !value.key?("headSha") && value["pullRequest"] == 424249'

# A review-fix cycle preserves the old verified Head while returning to
# in-progress, then the next explicit verification replaces it with current HEAD.
ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["state"]="changes-requested"; value["previousState"]="review-requested"; value["from"]="review-requested"; value["to"]="changes-requested"; File.binwrite(path,JSON.generate(value))' ".artifacts/issues/$test_issue/state.json"
printf '["state:changes-requested"]' > "$FAKE_GH_LABELS_FILE"
printf 'review fix\n' > "$state_worktree/review-fix.txt"
git -C "$state_worktree" add tools review-fix.txt
git -C "$state_worktree" -c user.name=Fixture -c user.email=fixture@example.invalid commit -m 'review fix' >/dev/null
updated_head=$(git -C "$state_worktree" rev-parse HEAD)
[[ "$updated_head" != "$head_sha" ]]
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from changes-requested --to in-progress >/dev/null
assert_json ".artifacts/issues/$test_issue/state.json" 'value=JSON.parse(File.read(ARGV[0])); abort unless value["state"]=="in-progress" && !value.key?("headSha")'
"$state_worktree/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from in-progress --to verify-passed --head-sha "$updated_head" >/dev/null
EXPECTED_HEAD="$updated_head" assert_json ".artifacts/issues/$test_issue/state.json" 'value=JSON.parse(File.read(ARGV[0])); abort unless value["state"]=="verify-passed" && value["headSha"]==ENV.fetch("EXPECTED_HEAD")'

# A malformed identity is rejected before an external state-label mutation.
printf '["state:claimed"]' > "$FAKE_GH_LABELS_FILE"
printf '[]' > "$FAKE_GH_COMMENTS_FILE"
printf '[]' > "$FAKE_GH_LOG"
printf '{"state":"claimed","unexpected":"must-fail-closed"}' > ".artifacts/issues/$test_issue/state.json"
assert_fails 'malformed durable identity stops before GitHub mutation' "$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from claimed --to in-progress
! rg -q '^issue edit ' "$FAKE_GH_LOG"

request=.artifacts/ops-requests/issue-424249-create-pr-1.json
cat > "$request" <<'EOF'
{"requestVersion":1,"requestId":"issue-424249-create-pr-1","issue":424249,"operation":"github.create_pr","target":{"kind":"repository","identifier":"yuto1201/iOS-Template"},"environment":"production","expectedAccount":"yuto1201","inputs":{"base":"main","head":"codex/424249-workflow"},"reason":"ready"}
EOF
"$repo_root/tools/validate-codex-op-request.sh" --request "$request"

cat > "$request_dir/create-issue.json" <<'EOF'
{"requestVersion":1,"requestId":"create-issue","issue":424249,"operation":"github.create_issue","target":{"kind":"repository","identifier":"yuto1201/iOS-Template"},"environment":"production","expectedAccount":"yuto1201","inputs":{"title":"Release notes","body":"First paragraph.\n\n- A Markdown item\n- Another item"},"reason":"document release"}
EOF
"$repo_root/tools/validate-codex-op-request.sh" --request "$request_dir/create-issue.json" > "$workspace/create-issue.json"
assert_json "$workspace/create-issue.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value.dig("inputs", "body") == "First paragraph.\n\n- A Markdown item\n- Another item"'

cat > "$request_dir/cloudflare-deploy.json" <<'EOF'
{"requestVersion":1,"requestId":"cloudflare-deploy","issue":424249,"operation":"cloudflare.deploy","target":{"kind":"cloudflare-project","identifier":"example"},"environment":"production","expectedAccount":"yuto1201","inputs":{"source":"/tmp/escape"},"reason":"deploy"}
EOF
assert_fails 'Cloudflare source path must be contained in the repository' "$repo_root/tools/validate-codex-op-request.sh" --request "$request_dir/cloudflare-deploy.json"
ln -s /tmp "$request_dir/path-link"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["inputs"]["source"] = ".artifacts/ops-requests/path-link"; File.write(ARGV[0], JSON.generate(value))' "$request_dir/cloudflare-deploy.json"
assert_fails 'Cloudflare source symlink escape is rejected' "$repo_root/tools/validate-codex-op-request.sh" --request "$request_dir/cloudflare-deploy.json"
cat > "$request_dir/elevenlabs-audio.json" <<'EOF'
{"requestVersion":1,"requestId":"elevenlabs-audio","issue":424249,"operation":"elevenlabs.generate_audio","target":{"kind":"elevenlabs-project","identifier":"example"},"environment":"production","expectedAccount":"yuto1201","inputs":{"outputPath":"/tmp/audio.mp3","text":"hello","voice":"voice"},"reason":"generate"}
EOF
assert_fails 'ElevenLabs output path must use an allowed Resource directory' "$repo_root/tools/validate-codex-op-request.sh" --request "$request_dir/elevenlabs-audio.json"
cat > "$request_dir/appstore-build.json" <<'EOF'
{"requestVersion":1,"requestId":"appstore-build","issue":424249,"operation":"appstore.upload_build","target":{"kind":"appstore-app","identifier":"example"},"environment":"production","expectedAccount":"yuto1201","inputs":{"buildPath":"../escape.ipa"},"reason":"upload"}
EOF
assert_fails 'App Store build path must use its artifact root' "$repo_root/tools/validate-codex-op-request.sh" --request "$request_dir/appstore-build.json"
cat > "$request_dir/supabase-migrations.json" <<'EOF'
{"requestVersion":1,"requestId":"supabase-migrations","issue":424249,"operation":"supabase.apply_migrations","target":{"kind":"supabase-project","identifier":"example"},"environment":"production","expectedAccount":"yuto1201","inputs":{"migrations":["../escape.sql"]},"reason":"migrate"}
EOF
assert_fails 'migration input must not contain a path escape' "$repo_root/tools/validate-codex-op-request.sh" --request "$request_dir/supabase-migrations.json"

printf '{"requestVersion":1}' > .artifacts/ops-requests/bad.json
assert_fails 'malformed operation request is rejected' "$repo_root/tools/validate-codex-op-request.sh" --request .artifacts/ops-requests/bad.json
assert_fails 'request path escape is rejected' "$repo_root/tools/validate-codex-op-request.sh" --request ../outside.json
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["approval"] = "approved"; File.write(ARGV[0], JSON.generate(value))' "$request"
assert_fails 'request-selected approval is rejected' "$repo_root/tools/validate-codex-op-request.sh" --request "$request"
sed -i '' 's/,"approval":"approved"//' "$request"

# The end-to-end transport contract has its own isolated fixture because it now
# binds to an exact sealed Issue contract, a fresh live Issue reconstruction,
# and a durable replay receipt. Keep the state tests independent of those
# transport artifacts while still making this aggregate suite exercise them.
"$repo_root/tools/tests/test-codex-op-transport.sh"

echo 'PASS: GitHub preflight, durable state transitions, and fixed Codex operation transport'
