#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-cross-model-review.XXXXXX")
issue=424243
head_sha=$(git -C "$repo_root" rev-parse HEAD)
base_sha=$(git -C "$repo_root" rev-parse HEAD~1)
artifact_issue="$repo_root/.artifacts/issues/$issue"
artifact_root="$artifact_issue/$head_sha"
trap 'rm -rf "$workspace" "$artifact_issue"' EXIT
[[ ! -e "$artifact_issue" ]] || { echo "refusing to overwrite $artifact_issue" >&2; exit 1; }

fake_bin="$workspace/bin"
mkdir -p "$fake_bin" "$artifact_root"
cp "$repo_root/tools/tests/fixtures/cross-model-review/claude" "$fake_bin/claude"
cp "$repo_root/tools/tests/fixtures/cross-model-review/codex" "$fake_bin/codex"
cp "$repo_root/tools/tests/fixtures/gh" "$fake_bin/gh"
chmod +x "$fake_bin/claude" "$fake_bin/codex" "$fake_bin/gh"
export PATH="$fake_bin:$PATH"
export FAKE_REVIEWER_LOG="$workspace/reviewer.log"
export FAKE_REVIEWER_REQUIRE_CLOSED_STDIN=1
export FAKE_GH_LOG="$workspace/gh.log"
export FAKE_GH_LABELS_FILE="$workspace/labels.json"
export FAKE_GH_COMMENTS_FILE="$workspace/comments.json"
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
printf '[]' > "$FAKE_GH_COMMENTS_FILE"

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

write_packet() {
  local primary=$1 reviewer=$2
  PRIMARY="$primary" REVIEWER="$reviewer" PACKET="$artifact_root/review-packet.json" ISSUE="$issue" BASE="$base_sha" HEAD="$head_sha" DIGEST="$contract_digest" ruby -rjson -e '
    File.write(ENV.fetch("PACKET"), JSON.generate({"schemaVersion" => 1, "issue" => ENV.fetch("ISSUE").to_i, "primaryModel" => ENV.fetch("PRIMARY"), "reviewerModel" => ENV.fetch("REVIEWER"), "baseSha" => ENV.fetch("BASE"), "headSha" => ENV.fetch("HEAD"), "verifySha" => ENV.fetch("HEAD"), "issueContract" => {"path" => ".artifacts/issues/#{ENV.fetch("ISSUE")}/issue-contract.json", "digest" => ENV.fetch("DIGEST")}, "specAnchors" => ["specs/acceptance.md#1"], "acceptanceCriteria" => [{"id" => "AC-1", "text" => "A result is tied to the reviewed Head"}], "diffFile" => ".artifacts/issues/#{ENV.fetch("ISSUE")}/#{ENV.fetch("HEAD")}/review.diff", "verifyFile" => ".artifacts/issues/#{ENV.fetch("ISSUE")}/#{ENV.fetch("HEAD")}/verify.json", "imageFiles" => ["iphone-en.png"]}))
  '
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
write_packet claude codex
export FAKE_REVIEWER_MODE=approved
write_result approved codex
run_review claude
assert_json "$artifact_root/review.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["reviewerModel"] == "codex" && value["verdict"] == "approved"'
[[ "$(cat "$FAKE_REVIEWER_LOG")" == *"exec --sandbox read-only --ephemeral --"* ]] || { echo 'fixed Codex read-only wrapper was not invoked' >&2; exit 1; }

echo 'PASS: approved, changes-requested, malformed, SHA mismatch, timeout, write-attempt, and fixed Codex review cases'
