#!/usr/bin/env bash
set -euo pipefail

source_repo=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-review-shared.XXXXXX")
workspace=$(cd "$workspace" && pwd -P)
primary="$workspace/primary"
linked="$primary/.worktrees/reviewer"
issue=424244
trap 'rm -rf "$workspace"' EXIT

assert_fails() {
  local message=$1
  shift
  if "$@" >"$workspace/output" 2>&1; then
    echo "expected failure: $message" >&2
    exit 1
  fi
}

mkdir -p "$primary"
(cd "$source_repo" && tar -cf - --exclude=.git --exclude=.artifacts --exclude=.worktrees --exclude=.superpowers .) | (cd "$primary" && tar -xf -)
git -C "$primary" init -q
git -C "$primary" config user.name 'Review Fixture'
git -C "$primary" config user.email 'review-fixture@example.invalid'
git -C "$primary" add .
git -C "$primary" commit -qm 'fixture base'
git -C "$primary" commit --allow-empty -qm 'fixture head'
mkdir -p "$primary/.worktrees" "$primary/.artifacts"
git -C "$primary" worktree add -q --detach "$linked" HEAD
ln -s ../../.artifacts "$linked/.artifacts"

head_sha=$(git -C "$linked" rev-parse HEAD)
base_sha=$(git -C "$linked" rev-parse HEAD~1)
artifact_issue="$primary/.artifacts/issues/$issue"
artifact_head="$artifact_issue/$head_sha"
mkdir -p "$artifact_head"

digest() { shasum -a 256 "$1" | awk '{print "sha256:" $1}'; }
cat > "$artifact_issue/issue-contract.json" <<JSON
{"schemaVersion":1,"issue":$issue,"repository":"yuto1201/iOS-Template","goal":"Shared review artifacts","specAnchors":["specs/acceptance.md#1"],"fetchedAt":"2026-08-24T00:00:00Z","dependencies":[],"externalOperations":[],"externalOperationDetailsDigest":"sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945","acceptanceCriteria":[{"id":"AC-1","text":"Review reads the canonical shared evidence"}]}
JSON
contract_digest=$(digest "$artifact_issue/issue-contract.json")
printf 'diff\n' > "$artifact_head/review.diff"
printf 'image\n' > "$artifact_head/iphone-en.png"
cat > "$artifact_head/verify.json" <<JSON
{"schemaVersion":1,"issue":$issue,"baseSha":"$base_sha","headSha":"$head_sha","issueContract":{"path":".artifacts/issues/$issue/issue-contract.json","digest":"$contract_digest"}}
JSON

write_packet() {
  local primary_model=$1 reviewer_model=$2
  cat > "$artifact_head/review-packet.json" <<JSON
{"schemaVersion":1,"issue":$issue,"primaryModel":"$primary_model","reviewerModel":"$reviewer_model","baseSha":"$base_sha","headSha":"$head_sha","verifySha":"$head_sha","issueContract":{"path":".artifacts/issues/$issue/issue-contract.json","digest":"$contract_digest"},"specAnchors":["specs/acceptance.md#1"],"acceptanceCriteria":[{"id":"AC-1","text":"Review reads the canonical shared evidence"}],"diffFile":".artifacts/issues/$issue/$head_sha/review.diff","verifyFile":".artifacts/issues/$issue/$head_sha/verify.json","imageFiles":["iphone-en.png"]}
JSON
}

write_result() {
  local reviewer_model=$1
  cat > "$workspace/result.json" <<JSON
{"schemaVersion":1,"issue":$issue,"reviewerModel":"$reviewer_model","baseSha":"$base_sha","headSha":"$head_sha","verifySha":"$head_sha","issueContractDigest":"$contract_digest","verdict":"approved","findings":[],"acceptanceAssessment":[{"id":"AC-1","status":"supported","evidence":["verify.json#acceptanceEvidence/0"]}],"reviewedAt":"2026-08-24T00:01:00Z"}
JSON
  export FAKE_REVIEWER_RESULT="$workspace/result.json"
}

fake_bin="$workspace/bin"
mkdir -p "$fake_bin"
cp "$linked/tools/tests/fixtures/cross-model-review/claude" "$fake_bin/claude"
cp "$linked/tools/tests/fixtures/cross-model-review/codex" "$fake_bin/codex-fixture"
"${CC:-cc}" -Wall -Werror "$linked/tools/tests/fixtures/cross-model-review/codex-native.c" -o "$fake_bin/codex"
cp "$linked/tools/tests/fixtures/gh" "$fake_bin/gh"
chmod +x "$fake_bin/claude" "$fake_bin/codex" "$fake_bin/codex-fixture" "$fake_bin/gh"
export PATH="$fake_bin:$PATH"
export FAKE_REVIEWER_LOG="$workspace/reviewer.log"
export FAKE_REVIEWER_REQUIRE_CLOSED_STDIN=1
export FAKE_GH_LOG="$workspace/gh.log"
export FAKE_GH_LABELS_FILE="$workspace/labels.json"
export FAKE_GH_COMMENTS_FILE="$workspace/comments.json"
export CODEX_HOME="$workspace/codex-home"
mkdir -p "$CODEX_HOME"
printf '[]' > "$FAKE_GH_COMMENTS_FILE"

packet_relative=".artifacts/issues/$issue/$head_sha/review-packet.json"
output_relative=".artifacts/issues/$issue/$head_sha/review.json"

# Publication is a separate descriptor-bound boundary from result validation.
write_result claude
published=$("$linked/tools/lib/publish-review-result.rb" "$linked" "$issue" "$head_sha" "$workspace/result.json")
[[ $(jq -er '.path' <<<"$published") == "$artifact_head/review.json" ]]
cmp -s "$workspace/result.json" "$artifact_head/review.json" || {
  shasum -a 256 "$workspace/result.json" "$artifact_head/review.json" >&2
  wc -c "$workspace/result.json" "$artifact_head/review.json" >&2
  exit 1
}
rm "$artifact_head/review.json"

# The production change that makes this pass is accepting only the exact shared
# worktree topology and mapping canonical artifact paths to the primary store.
write_packet codex claude
validated_packet=$("$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative")
validated_repository=$(jq -r '.issueContractRepository // "MISSING"' <<<"$validated_packet")
[[ "$validated_repository" == yuto1201/iOS-Template ]] || { echo 'validated packet omitted the descriptor-bound repository identity' >&2; exit 1; }
"$primary/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" >/dev/null

export FAKE_REVIEWER_MODE=approved
write_result claude
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
(cd "$linked" && tools/cross-model-review.sh --primary codex --packet "$packet_relative" --output "$output_relative" >/dev/null)
[[ -f "$artifact_head/review.json" && ! -L "$artifact_head/review.json" ]]
[[ $(stat -f '%l' "$artifact_head/review.json") == 1 ]]

rm "$artifact_head/review.json"
write_packet claude codex
write_result codex
printf '["state:review-requested"]' > "$FAKE_GH_LABELS_FILE"
(cd "$linked" && tools/cross-model-review.sh --primary claude --packet "$packet_relative" --output "$output_relative" >/dev/null)
[[ -f "$artifact_head/review.json" && ! -L "$artifact_head/review.json" ]]
# The strict Codex fixture rejects any permission profile other than the exact
# Issue root, so reaching a valid output proves the store-wide root was absent.

rm "$artifact_head/review.json"
write_packet codex claude

cp "$artifact_head/review-packet.json" "$artifact_head/alternate-packet.json"
assert_fails 'a noncanonical packet filename is rejected' "$linked/tools/validate-review-result.sh" --primary codex --packet ".artifacts/issues/$issue/$head_sha/alternate-packet.json"
rm "$artifact_head/alternate-packet.json"

rm "$linked/.artifacts"
ln -s ../../../outside-artifacts "$linked/.artifacts"
assert_fails 'an arbitrary top-level artifact link is rejected' "$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative"
rm "$linked/.artifacts"
ln -s ../../.artifacts "$linked/.artifacts"

mv "$artifact_head/review.diff" "$artifact_head/review.diff.real"
ln -s review.diff.real "$artifact_head/review.diff"
assert_fails 'a final artifact symlink is rejected' "$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative"
rm "$artifact_head/review.diff"
mv "$artifact_head/review.diff.real" "$artifact_head/review.diff"

mv "$artifact_head" "$artifact_issue/head.real"
ln -s head.real "$artifact_head"
assert_fails 'a nested artifact directory symlink is rejected' "$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative"
write_result claude
assert_fails 'publication refuses a swapped Head parent component' "$linked/tools/lib/publish-review-result.rb" "$linked" "$issue" "$head_sha" "$workspace/result.json"
[[ ! -e "$artifact_issue/head.real/review.json" ]]
rm "$artifact_head"
mv "$artifact_issue/head.real" "$artifact_head"

ln "$artifact_head/review.diff" "$workspace/review.diff.hardlink"
assert_fails 'a hard-linked artifact is rejected' "$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative"
rm "$workspace/review.diff.hardlink"

ln "$artifact_head/review-packet.json" "$workspace/packet.hardlink"
assert_fails 'a hard-linked packet is rejected' "$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative"
rm "$workspace/packet.hardlink"

ln "$artifact_issue/issue-contract.json" "$workspace/contract.hardlink"
assert_fails 'a hard-linked contract is rejected' "$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative"
rm "$workspace/contract.hardlink"

ln "$artifact_head/verify.json" "$workspace/verify.hardlink"
assert_fails 'a hard-linked verify file is rejected' "$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative"
rm "$workspace/verify.hardlink"

write_result claude
mkdir "$workspace/result-parent"
cp "$workspace/result.json" "$workspace/result-parent/review.json"
ln -s result-parent "$workspace/result-parent-link"
assert_fails 'a review result with a symlinked parent is rejected' "$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$workspace/result-parent-link/review.json"

cp "$workspace/result.json" "$artifact_head/noncanonical-review.json"
assert_fails 'a published review must use the exact canonical Head review path' "$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$artifact_head/noncanonical-review.json"

ln "$workspace/result.json" "$workspace/result-hardlink.json"
assert_fails 'a hard-linked review result is rejected' "$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$workspace/result-hardlink.json"

rm "$workspace/result-hardlink.json"
cp "$workspace/result.json" "$artifact_head/review.json"
ln "$artifact_head/review.json" "$workspace/review.hardlink.json"
assert_fails 'a hard-linked canonical review is rejected' "$linked/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$artifact_head/review.json"

echo 'PASS: exact shared review artifacts work in both directions and unsafe links fail closed'
