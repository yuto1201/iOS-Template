#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-codex-transport.XXXXXX")
issue=424247
repository=yuto1201/iOS-Template
request_id="issue-$issue-create-pr-1"
artifacts="$repo_root/.artifacts"
request_dir="$artifacts/ops-requests"
result_dir="$artifacts/ops-results"
receipt_dir="$artifacts/ops-receipts"
issue_dir="$artifacts/issues/$issue"
request="$request_dir/$request_id.json"
result="$result_dir/$request_id.json"

cleanup() {
  rm -rf "$workspace" "$issue_dir" \
    "$request_dir/$request_id.json" \
    "$request_dir/$request_id.json.before-swap" \
    "$result_dir/$request_id.json" \
    "$receipt_dir/$request_id.json" \
    "$receipt_dir/$request_id.lock"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  [[ ! -f "$workspace/refusal.err" ]] || tail -n 20 "$workspace/refusal.err" >&2
  exit 1
}

assert_fails() {
  local message=$1
  shift
  if "$@" >"$workspace/refusal.out" 2>"$workspace/refusal.err"; then
    fail "$message"
  fi
}

invocations() {
  [[ -f "$workspace/codex-invocations" ]] || { printf '0\n'; return; }
  wc -l < "$workspace/codex-invocations" | tr -d ' '
}

mkdir -p "$request_dir" "$result_dir" "$receipt_dir" "$issue_dir" "$workspace/bin"

cat > "$workspace/issue-body.md" <<'EOF'
## Goal

Exercise one exact external-operation transport.

## In scope

- Create one pull request.

## Out of scope

- Every other external operation.

## Acceptance criteria

- AC-1: The declared operation can be delegated safely.

## Spec anchors

- [Authority](specs/automation.md#external-operations)

## Dependencies

- None.

## External operations

- Operation: github.create_pr
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

## User approvals

- No additional approval.
EOF

fetched_at=2026-08-24T00:00:00Z
ruby "$repo_root/tools/lib/issue-contract.rb" \
  --body "$workspace/issue-body.md" --type feature --format contract \
  --issue "$issue" --repo "$repository" --fetched-at "$fetched_at" \
  > "$issue_dir/issue-contract.json"
contract_digest="sha256:$(shasum -a 256 "$issue_dir/issue-contract.json" | awk '{print $1}')"
head_sha=$(git -C "$repo_root" rev-parse HEAD)
base_sha=$(git -C "$repo_root" rev-parse HEAD^)
CONTRACT_DIGEST="$contract_digest" HEAD_SHA="$head_sha" BASE_SHA="$base_sha" ruby -rjson -e '
  value = {
    "schemaVersion" => 1, "issue" => ARGV.fetch(1).to_i,
    "repository" => ARGV.fetch(2), "branch" => "codex/#{ARGV.fetch(1)}-transport",
    "worktree" => ".worktrees/#{ARGV.fetch(1)}-transport", "baseSha" => ENV.fetch("BASE_SHA"),
    "primaryImplementer" => "codex",
    "issueContract" => {"path" => ".artifacts/issues/#{ARGV.fetch(1)}/issue-contract.json", "digest" => ENV.fetch("CONTRACT_DIGEST")},
    "state" => "in-progress", "previousState" => "claimed", "resumeState" => nil,
    "executor" => "codex", "headSha" => ENV.fetch("HEAD_SHA")
  }
  File.binwrite(ARGV.fetch(0), JSON.generate(value.sort.to_h))
' "$issue_dir/state.json" "$issue" "$repository"

cat > "$request" <<EOF
{"requestVersion":1,"requestId":"$request_id","issue":$issue,"operation":"github.create_pr","target":{"kind":"repository","identifier":"$repository"},"environment":"production","expectedAccount":"yuto1201","inputs":{"base":"main","head":"codex/$issue-transport"},"reason":"verified work is ready"}
EOF

cat > "$workspace/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
if [[ "${1:-}" == auth && "${2:-}" == status && "${3:-}" == --active ]]; then
  printf 'Logged in to github.com account %s (keychain)\n  - Active account: true\n' "${FAKE_GH_LOGIN:-yuto1201}"
elif [[ "${1:-}" == repo && "${2:-}" == view ]]; then
  ruby -rjson -e 'puts JSON.generate({"nameWithOwner"=>ARGV[0],"defaultBranchRef"=>{"name"=>"main"},"url"=>"https://github.com/#{ARGV[0]}"})' "${FAKE_REPOSITORY:?}"
elif [[ "${1:-}" == issue && "${2:-}" == view ]]; then
  ruby -rjson -e 'puts JSON.generate({"number"=>ARGV[0].to_i,"url"=>"https://github.com/#{ARGV[1]}/issues/#{ARGV[0]}","body"=>File.binread(ARGV[2]),"labels"=>[{"name"=>"type:feature","color"=>"1d76db","description"=>"Feature work"}]})' "${FAKE_ISSUE:?}" "${FAKE_REPOSITORY:?}" "${FAKE_ISSUE_BODY:?}"
else
  echo "unexpected gh invocation: $*" >&2
  exit 2
fi
EOF
chmod +x "$workspace/bin/gh"

cat > "$workspace/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'invoked\n' >> "${FAKE_CODEX_INVOCATIONS:?}"
[[ "$*" == *'Provider idempotency key: ios-template:'* ]] || exit 93
if [[ -n "${FAKE_CODEX_SWAP_PATH:-}" ]]; then
  mv "$FAKE_CODEX_SWAP_PATH" "$FAKE_CODEX_SWAP_PATH.before-swap"
  cp "${FAKE_CODEX_SWAP_SOURCE:?}" "$FAKE_CODEX_SWAP_PATH"
fi
while [[ -n "${FAKE_CODEX_BLOCK_FILE:-}" && -e "$FAKE_CODEX_BLOCK_FILE" ]]; do
  sleep 0.05
done
[[ -z "${FAKE_CODEX_CRASH:-}" ]] || exit 42
if [[ -n "${FAKE_CODEX_OUTPUT_FILE:-}" ]]; then
  cat "$FAKE_CODEX_OUTPUT_FILE"
else
  printf '%s\n' '{"status":"succeeded","executor":"codex","verifiedAccount":"yuto1201","target":"yuto1201/iOS-Template","operation":"github.create_pr","resultReference":"https://github.com/yuto1201/iOS-Template/pull/57","executedAt":"2026-08-24T00:01:00Z"}'
fi
EOF
chmod +x "$workspace/bin/codex"

export PATH="$workspace/bin:$PATH"
export FAKE_GH_LOG="$workspace/gh.log"
export FAKE_REPOSITORY="$repository"
export FAKE_ISSUE="$issue"
export FAKE_ISSUE_BODY="$workspace/issue-body.md"
export FAKE_CODEX_INVOCATIONS="$workspace/codex-invocations"

cd "$repo_root"

write_create_pr_request() {
  local environment=${1:-production} account=${2:-yuto1201} target=${3:-$repository} reason=${4:-verified-work-is-ready}
  cat > "$request" <<EOF
{"requestVersion":1,"requestId":"$request_id","issue":$issue,"operation":"github.create_pr","target":{"kind":"repository","identifier":"$target"},"environment":"$environment","expectedAccount":"$account","inputs":{"base":"main","head":"codex/$issue-transport"},"reason":"$reason"}
EOF
}

clear_attempt() {
  rm -f "$result" "$receipt_dir/$request_id.json" "$receipt_dir/$request_id.lock" "$workspace/codex-invocations"
  unset FAKE_CODEX_OUTPUT_FILE FAKE_CODEX_BLOCK_FILE FAKE_CODEX_CRASH FAKE_CODEX_SWAP_PATH FAKE_CODEX_SWAP_SOURCE
}

reseal_issue() {
  ruby "$repo_root/tools/lib/issue-contract.rb" \
    --body "$workspace/issue-body.md" --type feature --format contract \
    --issue "$issue" --repo "$repository" --fetched-at "$fetched_at" \
    > "$issue_dir/issue-contract.json"
  local digest
  digest="sha256:$(shasum -a 256 "$issue_dir/issue-contract.json" | awk '{print $1}')"
  CONTRACT_DIGEST="$digest" ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["issueContract"]["digest"]=ENV.fetch("CONTRACT_DIGEST"); File.binwrite(path,JSON.generate(value.sort.to_h))' "$issue_dir/state.json"
}

# A requester-controlled success file must never become the Codex result source.
printf '%s\n' '{"status":"succeeded","executor":"codex","verifiedAccount":"yuto1201","target":"yuto1201/iOS-Template","operation":"github.create_pr","resultReference":"forged","executedAt":"2026-08-24T00:00:01Z"}' > "$result"
assert_fails 'a preseeded result was accepted or Codex was invoked' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rg -q 'result already exists without a completed receipt' "$workspace/refusal.err" || fail 'preseeded result failed for the wrong reason'
[[ "$(invocations)" == 0 ]] || fail 'Codex ran despite a preseeded result'
rm "$result"

# Structural allowlisting is insufficient: the operation must be in the exact
# sealed contract reconstructed from the current live Issue.
ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["operation"]="github.delete_branch"; value["inputs"]={"branch"=>"codex/424247-transport"}; File.binwrite(path,JSON.generate(value))' "$request"
assert_fails 'an undeclared operation was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rg -q 'operation is not declared by the sealed current Issue' "$workspace/refusal.err" || fail 'undeclared operation failed for the wrong reason'
[[ "$(invocations)" == 0 ]] || fail 'Codex ran for an undeclared operation'

# Config and the live contract, not requester-chosen values, select provider,
# account, target, and environment.
write_create_pr_request production company-account "$repository"
assert_fails 'a company account was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rg -q 'expectedAccount does not match configured account' "$workspace/refusal.err" || fail 'company account failed for the wrong reason'
[[ "$(invocations)" == 0 ]] || fail 'Codex ran for a company account'

write_create_pr_request production yuto1201 company/iOS-Template
assert_fails 'a company repository target was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
[[ "$(invocations)" == 0 ]] || fail 'Codex ran for a company target'

write_create_pr_request staging
assert_fails 'an environment differing from the Issue contract was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rg -q 'environment differs from the Issue contract' "$workspace/refusal.err" || fail 'environment mismatch failed for the wrong reason'
[[ "$(invocations)" == 0 ]] || fail 'Codex ran for an environment mismatch'

perl -0pi -e 's/Approval required: no/Approval required: yes/; s/No additional approval\./Approval reference: #73/' "$workspace/issue-body.md"
reseal_issue
write_create_pr_request
assert_fails 'approval-required operation trusted an Issue reference' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rg -q 'requires a separately verified Codex approval receipt' "$workspace/refusal.err" || fail 'approval requirement failed for the wrong reason'
[[ "$(invocations)" == 0 ]] || fail 'Codex ran without a verified approval receipt'
perl -0pi -e 's/Approval required: yes/Approval required: no/; s/Approval reference: #73/No additional approval./' "$workspace/issue-body.md"
reseal_issue

# Result provenance is stdout from the fixed child only, with an exact safe
# schema. Unknown secret fields and local filesystem references are refused.
clear_attempt
write_create_pr_request
cat > "$workspace/secret-result.json" <<EOF
{"status":"succeeded","executor":"codex","verifiedAccount":"yuto1201","target":"$repository","operation":"github.create_pr","resultReference":"https://github.com/$repository/pull/57","executedAt":"2026-08-24T00:01:00Z","token":"must-not-survive"}
EOF
export FAKE_CODEX_OUTPUT_FILE="$workspace/secret-result.json"
assert_fails 'a result carrying a secret field was sanitized into success' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rg -q 'unknown or missing fields' "$workspace/refusal.err" || fail 'secret result failed for the wrong reason'
[[ ! -e "$result" ]] || fail 'secret-bearing result was published'
[[ "$(invocations)" == 1 ]] || fail 'secret result did not use one fixed child'

clear_attempt
cat > "$workspace/path-result.json" <<EOF
{"status":"succeeded","executor":"codex","verifiedAccount":"yuto1201","target":"$repository","operation":"github.create_pr","resultReference":"/Users/requester/secret.json","executedAt":"2026-08-24T00:01:00Z"}
EOF
export FAKE_CODEX_OUTPUT_FILE="$workspace/path-result.json"
assert_fails 'a result carrying a local path was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rg -q 'contains a local path' "$workspace/refusal.err" || fail 'local path result failed for the wrong reason'
[[ ! -e "$result" ]] || fail 'local-path result was published'

# A completed receipt is replayed locally, without a second Codex invocation.
clear_attempt
first_result=$("$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result")
[[ "$(invocations)" == 1 ]] || fail 'first successful attempt did not invoke Codex exactly once'
second_result=$("$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result")
[[ "$second_result" == "$first_result" ]] || fail 'completed replay returned different sanitized bytes'
[[ "$(invocations)" == 1 ]] || fail 'sequential duplicate invoked Codex again'

write_create_pr_request production yuto1201 "$repository" changed-reason
assert_fails 'a changed request reused the old request ID receipt' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rg -q 'receipt request identity differs' "$workspace/refusal.err" || fail 'request digest change failed for the wrong reason'
[[ "$(invocations)" == 1 ]] || fail 'changed request ID digest invoked Codex'

# A nonblocking descriptor lock refuses a concurrent duplicate, while the
# original process can complete exactly once.
clear_attempt
write_create_pr_request
touch "$workspace/block-codex"
export FAKE_CODEX_BLOCK_FILE="$workspace/block-codex"
"$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result" > "$workspace/first.out" 2> "$workspace/first.err" &
first_pid=$!
for _ in $(seq 1 100); do
  [[ "$(invocations)" == 1 ]] && break
  sleep 0.05
done
[[ "$(invocations)" == 1 ]] || fail 'first concurrent attempt did not reach Codex'
if "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result" > "$workspace/concurrent.out" 2> "$workspace/concurrent.err"; then
  fail 'concurrent duplicate was accepted'
fi
rg -q 'already in flight' "$workspace/concurrent.err" || fail 'concurrent duplicate failed for the wrong reason'
rm "$workspace/block-codex"
wait "$first_pid"
[[ "$(invocations)" == 1 ]] || fail 'concurrent duplicate caused another Codex invocation'

# Once execution becomes ambiguous, the durable in-flight receipt blocks every
# replay using that request ID and digest.
clear_attempt
export FAKE_CODEX_CRASH=1
assert_fails 'a crashed child was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rg -q 'replay is blocked' "$workspace/refusal.err" || fail 'crashed child failed for the wrong reason'
[[ "$(invocations)" == 1 ]] || fail 'crash fixture did not invoke Codex once'
unset FAKE_CODEX_CRASH
assert_fails 'an ambiguous in-flight request was replayed' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rg -q 'in flight or ambiguous' "$workspace/refusal.err" || fail 'ambiguous retry failed for the wrong reason'
[[ "$(invocations)" == 1 ]] || fail 'ambiguous retry invoked Codex'

# Every requester-controlled leaf is opened no-follow and single-link. An
# atomic path replacement while the child is running is detected before any
# success result can be published.
clear_attempt
cp "$request" "$workspace/request-real.json"
rm "$request"
ln -s "$workspace/request-real.json" "$request"
assert_fails 'a symlink request was accepted' \
  "$repo_root/tools/validate-codex-op-request.sh" --request "$request"
rm "$request"
cp "$workspace/request-real.json" "$request"
ln "$request" "$workspace/request-hardlink.json"
assert_fails 'a hard-linked request was accepted' \
  "$repo_root/tools/validate-codex-op-request.sh" --request "$request"
rm "$workspace/request-hardlink.json"

printf 'forged\n' > "$workspace/forged-result"
ln -s "$workspace/forged-result" "$result"
assert_fails 'a symlink result was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rm "$result"
ln "$workspace/forged-result" "$result"
assert_fails 'a hard-linked result was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rm "$result"

printf '{}\n' > "$workspace/forged-receipt"
ln -s "$workspace/forged-receipt" "$receipt_dir/$request_id.json"
assert_fails 'a symlink receipt was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rm "$receipt_dir/$request_id.json"
ln "$workspace/forged-receipt" "$receipt_dir/$request_id.json"
assert_fails 'a hard-linked receipt was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rm "$receipt_dir/$request_id.json"

chmod 600 "$workspace/forged-receipt"
rm "$receipt_dir/$request_id.lock"
ln -s "$workspace/forged-receipt" "$receipt_dir/$request_id.lock"
assert_fails 'a symlink operation lock was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rm "$receipt_dir/$request_id.lock"
ln "$workspace/forged-receipt" "$receipt_dir/$request_id.lock"
assert_fails 'a hard-linked operation lock was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rm "$receipt_dir/$request_id.lock"

clear_attempt
cp "$request" "$workspace/request-swap.json"
ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["reason"]="swapped requester bytes"; File.binwrite(path,JSON.generate(value))' "$workspace/request-swap.json"
export FAKE_CODEX_SWAP_PATH="$request"
export FAKE_CODEX_SWAP_SOURCE="$workspace/request-swap.json"
assert_fails 'a request path swap during execution was accepted' \
  "$repo_root/tools/request-codex-op.sh" --request "$request" --result "$result"
rg -q -e 'descriptor changed' -e 'path identity changed' "$workspace/refusal.err" || fail 'request swap failed for the wrong reason'
[[ ! -e "$result" ]] || fail 'result was published after a request path swap'
[[ "$(invocations)" == 1 ]] || fail 'swap fixture did not invoke one fixed child'
mv "$request.before-swap" "$request"

echo 'PASS: fixed Codex operation transport fails closed'
