#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)

if [[ "${IOS_TEMPLATE_REVIEW_FIXTURE_READY:-0}" != 1 ]]; then
  fixture_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-cross-model-fixture.XXXXXX")
  fixture_workspace=$(cd "$fixture_workspace" && pwd -P)
  fixture_primary="$fixture_workspace/primary"
  fixture_linked="$fixture_primary/.worktrees/reviewer"
  trap 'rm -rf "$fixture_workspace"' EXIT

  mkdir -p "$fixture_primary"
  (cd "$repo_root" && git ls-files -z | tar --null -T - -cf -) | (cd "$fixture_primary" && tar -xf -)
  git -C "$fixture_primary" init -q
  git -C "$fixture_primary" config user.name 'Review Fixture'
  git -C "$fixture_primary" config user.email 'review-fixture@example.invalid'
  git -C "$fixture_primary" add .
  git -C "$fixture_primary" commit -qm 'fixture base'
  git -C "$fixture_primary" commit --allow-empty -qm 'fixture head'
  mkdir -p "$fixture_primary/.worktrees" "$fixture_primary/.artifacts"
  git -C "$fixture_primary" worktree add -q --detach "$fixture_linked" HEAD
  ln -s ../../.artifacts "$fixture_linked/.artifacts"

  (cd "$fixture_linked" && IOS_TEMPLATE_REVIEW_FIXTURE_READY=1 bash tools/tests/test-cross-model-review.sh)
  exit 0
fi

workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-cross-model-review.XXXXXX")
issue=424243
head_sha=$(git -C "$repo_root" rev-parse HEAD)
base_sha=$(git -C "$repo_root" rev-parse HEAD~1)
artifact_issue="$repo_root/.artifacts/issues/$issue"
artifact_root="$artifact_issue/$head_sha"
artifact_sibling_lexical="$repo_root/.artifacts/issues/${issue}9"
trap 'rm -rf "$workspace" "$artifact_issue" "$artifact_sibling_lexical"' EXIT
[[ ! -e "$artifact_issue" ]] || { echo "refusing to overwrite $artifact_issue" >&2; exit 1; }

fake_bin="$workspace/bin"
mkdir -p "$fake_bin" "$artifact_root"
real_codex=$(command -v codex)
[[ "$real_codex" == /* && $(/usr/bin/file -b "$real_codex") == Mach-O* ]] || { echo 'installed Codex must be a native Mach-O executable for sandbox probes' >&2; exit 1; }
cp "$repo_root/tools/tests/fixtures/cross-model-review/claude" "$fake_bin/claude"
cp "$repo_root/tools/tests/fixtures/cross-model-review/codex" "$fake_bin/codex-fixture"
"${CC:-cc}" -Wall -Werror "$repo_root/tools/tests/fixtures/cross-model-review/codex-native.c" -o "$fake_bin/codex"
cp "$repo_root/tools/tests/fixtures/gh" "$fake_bin/gh"
chmod +x "$fake_bin/claude" "$fake_bin/codex" "$fake_bin/codex-fixture" "$fake_bin/gh"
export PATH="$fake_bin:$PATH"
export FAKE_REVIEWER_LOG="$workspace/reviewer.log"
export FAKE_REVIEWER_REQUIRE_CLOSED_STDIN=1
export FAKE_GH_LOG="$workspace/gh.log"
export FAKE_GH_LABELS_FILE="$workspace/labels.json"
export FAKE_GH_COMMENTS_FILE="$workspace/comments.json"
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
printf '[]' > "$FAKE_GH_COMMENTS_FILE"
fake_codex_home="$workspace/fake-codex-home"
mkdir -p "$fake_codex_home"
fake_codex_home=$(cd "$fake_codex_home" && pwd -P)
printf 'must-not-be-readable-by-reviewer\n' > "$fake_codex_home/sentinel"
export CODEX_HOME="$fake_codex_home"

digest() { shasum -a 256 "$1" | awk '{print "sha256:" $1}'; }
assert_json() { ruby -rjson -e "$2" "$1"; }
assert_fails() {
  local message=$1
  shift
  if "$@" >"$workspace/output" 2>&1; then
    echo "expected failure: $message" >&2
    exit 1
  fi
}

cat > "$artifact_issue/issue-contract.json" <<'JSON'
{"schemaVersion":1,"issue":424243,"repository":"yuto1201/iOS-Template","goal":"Review automation","specAnchors":["specs/acceptance.md#1"],"fetchedAt":"2026-08-24T00:00:00Z","dependencies":[],"externalOperations":[],"acceptanceCriteria":[{"id":"AC-1","text":"A result is tied to the reviewed Head"}]}
JSON
contract_digest=$(digest "$artifact_issue/issue-contract.json")
printf 'diff\n' > "$artifact_root/review.diff"
printf 'image\n' > "$artifact_root/iphone-en.png"
cat > "$artifact_root/verify.json" <<JSON
{"schemaVersion":1,"issue":$issue,"baseSha":"$base_sha","headSha":"$head_sha","issueContract":{"path":".artifacts/issues/$issue/issue-contract.json","digest":"$contract_digest"}}
JSON
cat > "$artifact_root/review-packet.json" <<JSON
{"schemaVersion":1,"issue":$issue,"primaryModel":"codex","reviewerModel":"claude","baseSha":"$base_sha","headSha":"$head_sha","verifySha":"$head_sha","issueContract":{"path":".artifacts/issues/$issue/issue-contract.json","digest":"$contract_digest"},"specAnchors":["specs/acceptance.md#1"],"acceptanceCriteria":[{"id":"AC-1","text":"A result is tied to the reviewed Head"}],"diffFile":".artifacts/issues/$issue/$head_sha/review.diff","verifyFile":".artifacts/issues/$issue/$head_sha/verify.json","imageFiles":["iphone-en.png"]}
JSON

git_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --absolute-git-dir)
git_common=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)
artifact_issue_physical=$(cd "$artifact_issue" && pwd -P)
artifacts_physical=$(cd "$repo_root/.artifacts" && pwd -P)
artifact_sibling_physical="$artifacts_physical/issues/${issue}9"
artifact_head_physical="$artifact_issue_physical/$head_sha"
artifact_contract_physical="$artifact_issue_physical/issue-contract.json"
artifact_stale_head_physical="$artifact_issue_physical/$(printf 'f%.0s' {1..40})"
sandbox_filesystem="permissions.reviewer.filesystem={\":root\"=\"deny\",\":minimal\"=\"read\",\"$repo_root\"=\"read\",\"$repo_root/.artifacts\"=\"deny\",\"$git_dir\"=\"read\",\"$git_common\"=\"read\",\"$artifact_contract_physical\"=\"read\",\"$artifact_head_physical\"=\"read\"}"
reviewer_sandbox() {
  "$real_codex" sandbox -c 'default_permissions="reviewer"' -c 'permissions.reviewer.extends=":read-only"' -c "$sandbox_filesystem" -c 'permissions.reviewer.network={enabled=false}' -P reviewer -- "$@"
}
reviewer_sandbox /bin/cat "$artifact_issue_physical/$head_sha/review-packet.json" >/dev/null
reviewer_sandbox /bin/cat "$artifact_contract_physical" >/dev/null
reviewer_sandbox /bin/cat "$artifact_head_physical/review.diff" >/dev/null
reviewer_sandbox /bin/cat "$artifact_head_physical/verify.json" >/dev/null
reviewer_sandbox /bin/cat "$repo_root/README.md" >/dev/null
mkdir -p "$artifact_sibling_physical"
printf 'must-not-be-readable-by-reviewer\n' > "$artifact_sibling_physical/sentinel"
mkdir -p "$artifact_stale_head_physical"
printf 'must-not-be-readable-by-reviewer\n' > "$artifact_stale_head_physical/sentinel"
assert_fails 'custom reviewer profile denies sibling Issue physical artifacts' reviewer_sandbox /bin/cat "$artifact_sibling_physical/sentinel"
assert_fails 'custom reviewer profile denies sibling Issue artifacts through the linked lexical path' reviewer_sandbox /bin/cat "$artifact_sibling_lexical/sentinel"
assert_fails 'custom reviewer profile denies stale Head artifacts' reviewer_sandbox /bin/cat "$artifact_stale_head_physical/sentinel"
assert_fails 'custom reviewer profile denies the retained CODEX_HOME sentinel' reviewer_sandbox /bin/cat "$fake_codex_home/sentinel"
assert_fails 'custom reviewer profile denies absolute executable socket creation' reviewer_sandbox /usr/bin/ruby -rsocket -e 'Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0); exit 0'

review_anchor='specs/acceptance.md#1'
write_packet() {
  local primary=$1 reviewer=$2
  PRIMARY="$primary" REVIEWER="$reviewer" PACKET="$artifact_root/review-packet.json" ISSUE="$issue" BASE="$base_sha" HEAD="$head_sha" DIGEST="$contract_digest" ANCHOR="$review_anchor" ruby -rjson -e '
    File.write(ENV.fetch("PACKET"), JSON.generate({"schemaVersion" => 1, "issue" => ENV.fetch("ISSUE").to_i, "primaryModel" => ENV.fetch("PRIMARY"), "reviewerModel" => ENV.fetch("REVIEWER"), "baseSha" => ENV.fetch("BASE"), "headSha" => ENV.fetch("HEAD"), "verifySha" => ENV.fetch("HEAD"), "issueContract" => {"path" => ".artifacts/issues/#{ENV.fetch("ISSUE")}/issue-contract.json", "digest" => ENV.fetch("DIGEST")}, "specAnchors" => [ENV.fetch("ANCHOR")], "acceptanceCriteria" => [{"id" => "AC-1", "text" => "A result is tied to the reviewed Head"}], "diffFile" => ".artifacts/issues/#{ENV.fetch("ISSUE")}/#{ENV.fetch("HEAD")}/review.diff", "verifyFile" => ".artifacts/issues/#{ENV.fetch("ISSUE")}/#{ENV.fetch("HEAD")}/verify.json", "imageFiles" => ["iphone-en.png"]}))
  '
}

set_anchor() {
  review_anchor=$1
  ANCHOR="$review_anchor" CONTRACT="$artifact_issue/issue-contract.json" ruby -rjson -e 'path = ENV.fetch("CONTRACT"); value = JSON.parse(File.read(path)); value["specAnchors"] = [ENV.fetch("ANCHOR")]; File.write(path, JSON.generate(value))'
  contract_digest=$(digest "$artifact_issue/issue-contract.json")
  DIGEST="$contract_digest" VERIFY="$artifact_root/verify.json" ruby -rjson -e 'path = ENV.fetch("VERIFY"); value = JSON.parse(File.read(path)); value.fetch("issueContract")["digest"] = ENV.fetch("DIGEST"); File.write(path, JSON.generate(value))'
}

write_result() {
  local verdict=$1 reviewer=${2:-claude} result="$workspace/result.json"
  RESULT="$result" VERDICT="$verdict" REVIEWER="$reviewer" ISSUE="$issue" BASE="$base_sha" HEAD="$head_sha" DIGEST="$contract_digest" ruby -rjson -e '
    assessment = {"id" => "AC-1", "status" => (ENV.fetch("VERDICT") == "approved" ? "supported" : "unsupported"), "evidence" => ["verify.json#acceptanceEvidence/0"]}
    findings = ENV.fetch("VERDICT") == "approved" ? [] : [{"severity" => "high", "category" => "correctness", "file" => "README.md", "line" => 1, "title" => "Fix required", "evidence" => "fixture", "requiredChange" => "fix it"}]
    File.write(ENV.fetch("RESULT"), JSON.generate({"schemaVersion" => 1, "issue" => ENV.fetch("ISSUE").to_i, "reviewerModel" => ENV.fetch("REVIEWER"), "baseSha" => ENV.fetch("BASE"), "headSha" => ENV.fetch("HEAD"), "verifySha" => ENV.fetch("HEAD"), "issueContractDigest" => ENV.fetch("DIGEST"), "verdict" => ENV.fetch("VERDICT"), "findings" => findings, "acceptanceAssessment" => [assessment], "reviewedAt" => "2026-08-24T00:01:00Z"}))
  '
  export FAKE_REVIEWER_RESULT="$result"
}

run_review() {
  local primary=${1:-codex}
  "$repo_root/tools/cross-model-review.sh" --primary "$primary" --packet ".artifacts/issues/$issue/$head_sha/review-packet.json" --output ".artifacts/issues/$issue/$head_sha/review.json" >/dev/null
}

script_launcher_bin="$workspace/script-launcher"
mkdir "$script_launcher_bin"
cp "$repo_root/tools/tests/fixtures/cross-model-review/codex" "$script_launcher_bin/codex"
chmod +x "$script_launcher_bin/codex"
write_packet claude codex
CODEX_HOME="$repo_root" assert_fails 'CODEX_HOME overlapping the allowed worktree fails closed' "$repo_root/tools/request-codex-review.sh" --packet ".artifacts/issues/$issue/$head_sha/review-packet.json" --output ".artifacts/issues/$issue/$head_sha/review.json"
[[ $(cat "$workspace/output") == *'blocked:environment:'* ]] || { echo 'overlapping CODEX_HOME did not fail as blocked:environment' >&2; exit 1; }
PATH="$script_launcher_bin:$fake_bin:$PATH" assert_fails 'script Codex launchers fail closed before review' "$repo_root/tools/request-codex-review.sh" --packet ".artifacts/issues/$issue/$head_sha/review-packet.json" --output ".artifacts/issues/$issue/$head_sha/review.json"
[[ $(cat "$workspace/output") == *'blocked:environment:'* ]] || { echo 'script Codex launcher did not fail as blocked:environment' >&2; exit 1; }
write_packet codex claude

# RED was observed with the previous assertion while the production tool was absent.
export FAKE_REVIEWER_MODE=approved
write_result approved
run_review
assert_json "$artifact_root/review.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["verdict"] == "approved" && value["headSha"] =~ /\A[0-9a-f]{40}\z/'
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:approved-for-merge"]'
[[ "$(cat "$FAKE_REVIEWER_LOG")" == *"--print"* ]] || { echo 'Claude was not invoked noninteractively' >&2; exit 1; }

rm -f "$artifact_root/review.json"
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
export FAKE_REVIEWER_MODE=envelope
write_result approved
run_review
assert_json "$artifact_root/review.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value.keys.sort == %w[acceptanceAssessment baseSha findings headSha issue issueContractDigest reviewedAt reviewerModel schemaVersion verdict verifySha].sort'

rm -f "$artifact_root/review.json"
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
: > "$FAKE_REVIEWER_LOG"
export FAKE_REVIEWER_MODE=changes
write_result changes-requested
run_review
assert_json "$artifact_root/review.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["verdict"] == "changes-requested" && value["findings"].length == 1'
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:changes-requested"]'

rm -f "$artifact_root/review.json"
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
export FAKE_REVIEWER_MODE=malformed
printf '{not json' > "$workspace/result.json"
export FAKE_REVIEWER_RESULT="$workspace/result.json"
assert_fails 'malformed reviewer JSON is rejected' run_review
[[ ! -e "$artifact_root/review.json" ]]
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:review-requested"]'

rm -f "$artifact_root/review.json"
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
export FAKE_REVIEWER_MODE=mismatch
write_result approved
HEAD="$head_sha" RESULT="$workspace/result.json" ruby -rjson -e 'path = ENV.fetch("RESULT"); value = JSON.parse(File.read(path)); value["headSha"] = "0" * 40; File.write(path, JSON.generate(value))'
assert_fails 'mismatched reviewer Head SHA is rejected' run_review
[[ ! -e "$artifact_root/review.json" ]]

rm -f "$artifact_root/review.json"
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
export FAKE_REVIEWER_MODE=timeout
assert_fails 'reviewer timeout becomes blocked review' run_review
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:blocked:review"]'

rm -f "$artifact_root/review.json"
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
export FAKE_REVIEWER_MODE=write
export FAKE_REVIEWER_WRITE_PATH="$artifact_root/reviewer-write.txt"
write_result approved
assert_fails 'reviewer write attempt is rejected' run_review
[[ -f "$FAKE_REVIEWER_WRITE_PATH" && ! -e "$artifact_root/review.json" ]]
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:review-requested"]'
unset FAKE_REVIEWER_WRITE_PATH

rm -f "$artifact_root/review.json"
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
set_anchor external-attempt
write_packet claude codex
export GH_TOKEN=must-not-reach-reviewer
export SUPABASE_ACCESS_TOKEN=must-not-reach-reviewer
run_review claude
unset GH_TOKEN SUPABASE_ACCESS_TOKEN
assert_json "$artifact_root/review.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["reviewerModel"] == "codex" && value["verdict"] == "approved"'

rm -f "$artifact_root/review.json"
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
set_anchor 'specs/acceptance.md#1'
write_packet claude codex
export FAKE_GH_ISSUE_MISSING=1
assert_fails 'transition failure leaves a reusable canonical review' run_review claude
unset FAKE_GH_ISSUE_MISSING
[[ -f "$artifact_root/review.json" ]]
cp "$repo_root/tools/tests/fixtures/cross-model-review/codex-must-not-run" "$fake_bin/codex"
chmod +x "$fake_bin/codex"
run_review claude
assert_json "$FAKE_GH_LABELS_FILE" 'abort unless JSON.parse(File.read(ARGV[0])) == ["state:approved-for-merge"]'
run_review claude

echo 'PASS: approved, envelope, changes-requested, malformed, SHA mismatch, timeout, write-attempt, native hardened Codex sandbox probes, and idempotent retry cases'
