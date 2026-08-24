#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-workflow-state.XXXXXX")
test_issue=424242
artifact_issue="$repo_root/.artifacts/issues/$test_issue"
request_dir="$repo_root/.artifacts/ops-requests"
result_dir="$repo_root/.artifacts/ops-results"
[[ ! -e "$artifact_issue" ]] || { echo "refusing to overwrite existing $artifact_issue" >&2; exit 1; }
trap 'rm -rf "$workspace" "$artifact_issue" "$request_dir/issue-424242-create-pr-1.json" "$request_dir/bad.json" "$request_dir/cloudflare-deploy.json" "$request_dir/elevenlabs-audio.json" "$request_dir/appstore-build.json" "$request_dir/supabase-migrations.json" "$request_dir/path-link" "$result_dir/issue-424242-create-pr-1.json"' EXIT

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
printf '%s\n' '{"status":"succeeded","executor":"codex","verifiedAccount":"yuto1201","target":"yuto1201/iOS-Template","operation":"github.create_pr","resultReference":"https://github.com/yuto1201/iOS-Template/pull/424242","executedAt":"2026-08-24T00:00:00Z","token":"must-not-survive"}'
EOF
chmod +x "$fake_bin/codex"

export PATH="$fake_bin:$PATH"
export FAKE_GH_LOG="$workspace/gh.log"
export FAKE_GH_LABELS_FILE="$workspace/labels.json"
export FAKE_GH_COMMENTS_FILE="$workspace/comments.json"
export FAKE_GH_VIEW_COUNT_FILE="$workspace/issue-view-count"
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
export FAKE_GH_RACE_BEFORE_EDIT_VIEW=2
export FAKE_GH_RACE_BEFORE_EDIT_LABELS='["state:in-progress"]'
assert_fails 'transition recheck rejects a changed current state' "$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from approved --to claimed
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:in-progress"]'
! rg -q '^issue edit ' "$FAKE_GH_LOG"
unset FAKE_GH_RACE_BEFORE_EDIT_VIEW FAKE_GH_RACE_BEFORE_EDIT_LABELS

# The postcondition is checked before a marker or local durable state is written.
printf '[]' > "$FAKE_GH_COMMENTS_FILE"
printf '0' > "$FAKE_GH_VIEW_COUNT_FILE"
printf '["state:approved"]' > "$FAKE_GH_LABELS_FILE"
export FAKE_GH_RACE_AFTER_EDIT_LABELS='["state:in-progress"]'
assert_fails 'transition post-read rejects a changed result state' "$repo_root/tools/issue-state.sh" transition --repo yuto1201/iOS-Template --issue "$test_issue" --from approved --to claimed
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:in-progress"]'
assert_json "$FAKE_GH_COMMENTS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])).empty?'
unset FAKE_GH_RACE_AFTER_EDIT_LABELS

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

cat > "$request_dir/cloudflare-deploy.json" <<'EOF'
{"requestVersion":1,"requestId":"cloudflare-deploy","issue":424242,"operation":"cloudflare.deploy","target":{"kind":"cloudflare-project","identifier":"example"},"environment":"production","expectedAccount":"yuto1201","inputs":{"source":"/tmp/escape"},"reason":"deploy"}
EOF
assert_fails 'Cloudflare source path must be contained in the repository' "$repo_root/tools/validate-codex-op-request.sh" --request "$request_dir/cloudflare-deploy.json"
ln -s /tmp "$request_dir/path-link"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["inputs"]["source"] = ".artifacts/ops-requests/path-link"; File.write(ARGV[0], JSON.generate(value))' "$request_dir/cloudflare-deploy.json"
assert_fails 'Cloudflare source symlink escape is rejected' "$repo_root/tools/validate-codex-op-request.sh" --request "$request_dir/cloudflare-deploy.json"
cat > "$request_dir/elevenlabs-audio.json" <<'EOF'
{"requestVersion":1,"requestId":"elevenlabs-audio","issue":424242,"operation":"elevenlabs.generate_audio","target":{"kind":"elevenlabs-project","identifier":"example"},"environment":"production","expectedAccount":"yuto1201","inputs":{"outputPath":"/tmp/audio.mp3","text":"hello","voice":"voice"},"reason":"generate"}
EOF
assert_fails 'ElevenLabs output path must use an allowed Resource directory' "$repo_root/tools/validate-codex-op-request.sh" --request "$request_dir/elevenlabs-audio.json"
cat > "$request_dir/appstore-build.json" <<'EOF'
{"requestVersion":1,"requestId":"appstore-build","issue":424242,"operation":"appstore.upload_build","target":{"kind":"appstore-app","identifier":"example"},"environment":"production","expectedAccount":"yuto1201","inputs":{"buildPath":"../escape.ipa"},"reason":"upload"}
EOF
assert_fails 'App Store build path must use its artifact root' "$repo_root/tools/validate-codex-op-request.sh" --request "$request_dir/appstore-build.json"
cat > "$request_dir/supabase-migrations.json" <<'EOF'
{"requestVersion":1,"requestId":"supabase-migrations","issue":424242,"operation":"supabase.apply_migrations","target":{"kind":"supabase-project","identifier":"example"},"environment":"production","expectedAccount":"yuto1201","inputs":{"migrations":["../escape.sql"]},"reason":"migrate"}
EOF
assert_fails 'migration input must not contain a path escape' "$repo_root/tools/validate-codex-op-request.sh" --request "$request_dir/supabase-migrations.json"

printf '{"requestVersion":1}' > .artifacts/ops-requests/bad.json
assert_fails 'malformed operation request is rejected' "$repo_root/tools/validate-codex-op-request.sh" --request .artifacts/ops-requests/bad.json
assert_fails 'request path escape is rejected' "$repo_root/tools/validate-codex-op-request.sh" --request ../outside.json
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["approval"] = "approved"; File.write(ARGV[0], JSON.generate(value))' "$request"
assert_fails 'request-selected approval is rejected' "$repo_root/tools/validate-codex-op-request.sh" --request "$request"
sed -i '' 's/,"approval":"approved"//' "$request"

cat > "$workspace/mutated-request.json" <<'EOF'
{"requestVersion":1,"requestId":"issue-424242-create-pr-1","issue":424242,"operation":"github.delete_branch","target":{"kind":"repository","identifier":"yuto1201/iOS-Template"},"environment":"production","expectedAccount":"yuto1201","inputs":{"branch":"codex/424242-workflow"},"reason":"mutated"}
EOF
export FAKE_CODEX_REQUIRE_CLOSED_STDIN=1
export FAKE_CODEX_MUTATE_REQUEST="$repo_root/$request"
export FAKE_CODEX_MUTATION_FILE="$workspace/mutated-request.json"
"$repo_root/tools/request-codex-op.sh" --request "$request" --result .artifacts/ops-results/issue-424242-create-pr-1.json
unset FAKE_CODEX_REQUIRE_CLOSED_STDIN FAKE_CODEX_MUTATE_REQUEST FAKE_CODEX_MUTATION_FILE
assert_json .artifacts/ops-results/issue-424242-create-pr-1.json 'value = JSON.parse(File.read(ARGV[0])); abort unless value.keys.sort == %w[executedAt executor operation resultReference status target verifiedAccount]; abort unless value["status"] == "succeeded"; abort if value.to_json.include?("must-not-survive")'
assert_json "$request" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["operation"] == "github.delete_branch"'

echo 'PASS: GitHub preflight, durable state transitions, and fixed Codex operation transport'
