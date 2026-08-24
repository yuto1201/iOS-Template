#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-workflow-state.XXXXXX")
test_issue=424242
artifact_issue="$repo_root/.artifacts/issues/$test_issue"
request_dir="$repo_root/.artifacts/ops-requests"
result_dir="$repo_root/.artifacts/ops-results"
[[ ! -e "$artifact_issue" ]] || { echo "refusing to overwrite existing $artifact_issue" >&2; exit 1; }
trap 'rm -rf "$workspace" "$artifact_issue" "$request_dir/issue-424242-create-pr-1.json" "$request_dir/bad.json" "$result_dir/issue-424242-create-pr-1.json"' EXIT

fake_bin="$workspace/bin"
mkdir -p "$fake_bin"
cp "$repo_root/tools/tests/fixtures/gh" "$fake_bin/gh"
chmod +x "$fake_bin/gh"
cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"status":"succeeded","executor":"codex","verifiedAccount":"yuto1201","target":"yuto1201/iOS-Template","operation":"github.create_pr","resultReference":"https://github.com/yuto1201/iOS-Template/pull/424242","executedAt":"2026-08-24T00:00:00Z","token":"must-not-survive"}'
EOF
chmod +x "$fake_bin/codex"

export PATH="$fake_bin:$PATH"
export FAKE_GH_LOG="$workspace/gh.log"
export FAKE_GH_LABELS_FILE="$workspace/labels.json"
export FAKE_GH_COMMENTS_FILE="$workspace/comments.json"
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

head_sha=$(git -C "$repo_root" rev-parse HEAD)
"$repo_root/tools/github-account-preflight.sh" --repo yuto1201/iOS-Template --issue "$test_issue" --intended-operation github.create_pr --expected-head "$head_sha"
assert_json ".artifacts/issues/$test_issue/github-preflight.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["issue"] == 424242 && value["headSha"] =~ /\A[0-9a-f]{40}\z/ && value["digest"] =~ /\Asha256:[0-9a-f]{64}\z/; abort if value.to_json.include?("token")'

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

printf '["state:blocked:ops"]' > "$FAKE_GH_LABELS_FILE"
printf '[]' > "$FAKE_GH_COMMENTS_FILE"
rm -f ".artifacts/issues/$test_issue/state.json"
assert_fails 'blocked resume without history fails closed' "$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from blocked:ops --to in-progress
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:blocked:conflict"]'

request=.artifacts/ops-requests/issue-424242-create-pr-1.json
cat > "$request" <<'EOF'
{"requestVersion":1,"requestId":"issue-424242-create-pr-1","issue":424242,"operation":"github.create_pr","target":{"kind":"repository","identifier":"yuto1201/iOS-Template"},"environment":"production","expectedAccount":"yuto1201","inputs":{"base":"main","head":"codex/424242-workflow"},"reason":"ready"}
EOF
"$repo_root/tools/validate-codex-op-request.sh" --request "$request"

printf '{"requestVersion":1}' > .artifacts/ops-requests/bad.json
assert_fails 'malformed operation request is rejected' "$repo_root/tools/validate-codex-op-request.sh" --request .artifacts/ops-requests/bad.json
assert_fails 'request path escape is rejected' "$repo_root/tools/validate-codex-op-request.sh" --request ../outside.json
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["approval"] = "approved"; File.write(ARGV[0], JSON.generate(value))' "$request"
assert_fails 'request-selected approval is rejected' "$repo_root/tools/validate-codex-op-request.sh" --request "$request"
sed -i '' 's/,"approval":"approved"//' "$request"

"$repo_root/tools/request-codex-op.sh" --request "$request" --result .artifacts/ops-results/issue-424242-create-pr-1.json
assert_json .artifacts/ops-results/issue-424242-create-pr-1.json 'value = JSON.parse(File.read(ARGV[0])); abort unless value.keys.sort == %w[executedAt executor operation resultReference status target verifiedAccount]; abort unless value["status"] == "succeeded"; abort if value.to_json.include?("must-not-survive")'

echo 'PASS: GitHub preflight, durable state transitions, and fixed Codex operation transport'
