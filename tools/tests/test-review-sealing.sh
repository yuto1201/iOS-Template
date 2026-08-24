#!/usr/bin/env bash
set -euo pipefail

source_repo=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-review-sealing.XXXXXX")
workspace=$(cd "$workspace" && pwd -P)
repo="$workspace/repo"
issue=424249
trap 'rm -rf "$workspace"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_fails() {
  local message=$1
  shift
  if "$@" >"$workspace/output" 2>&1; then
    fail "expected rejection: $message"
  fi
}
digest() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print "sha256:" $1}'; }

mkdir "$repo"
(cd "$source_repo" && tar -cf - --exclude=.git --exclude=.artifacts --exclude=.worktrees --exclude=.superpowers .) | (cd "$repo" && tar -xf -)
git -C "$repo" init -q
git -C "$repo" config user.name 'Review Seal Fixture'
git -C "$repo" config user.email 'review-seal@example.invalid'
printf 'base\n' > "$repo/review-seal-fixture.txt"
git -C "$repo" add .
git -C "$repo" commit -qm 'fixture base'
base_sha=$(git -C "$repo" rev-parse HEAD)
printf 'head\n' > "$repo/review-seal-fixture.txt"
git -C "$repo" add review-seal-fixture.txt
git -C "$repo" commit -qm 'fixture head'
head_sha=$(git -C "$repo" rev-parse HEAD)

artifact_issue="$repo/.artifacts/issues/$issue"
artifact_head="$artifact_issue/$head_sha"
mkdir -p "$artifact_head/iphone-en"
printf 'sealed-image-A\n' > "$artifact_head/iphone-en/screenshot.png"
image_digest=$(digest "$artifact_head/iphone-en/screenshot.png")
cat > "$artifact_issue/issue-contract.json" <<JSON
{"schemaVersion":1,"issue":$issue,"repository":"yuto1201/iOS-Template","goal":"Seal exact review evidence","specAnchors":["specs/acceptance.md#品質ゲート"],"acceptanceCriteria":[{"id":"AC-1","text":"Review binds exact evidence"}],"dependencies":[],"externalOperations":[],"externalOperationDetailsDigest":"sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945","fetchedAt":"2026-08-24T00:00:00Z"}
JSON
ruby -rjson -e '
  path=ARGV.fetch(0); value=JSON.parse(File.binread(path))
  value["verification"]={
    "bundleIdentifier"=>"com.example.TemplateApp",
    "unitTestIdentifier"=>"TemplateAppTests/UnitSmokeTests/testUnit",
    "cases"=>[
      {"id"=>"iphone-en","testIdentifier"=>"TemplateAppUITests/SmokeTests/testLaunch"},
      {"id"=>"iphone-ja","assertion"=>{"kind"=>"launch-succeeded"}},
      {"id"=>"ipad-en","testIdentifier"=>"TemplateAppUITests/SmokeTests/testLaunch"},
      {"id"=>"ipad-ja","assertion"=>{"kind"=>"launch-succeeded"}}
    ],
    "acceptanceMappings"=>[{"id"=>"AC-1","checks"=>["stage:build","stage:unit-tests","case:iphone-en","case:iphone-ja","case:ipad-en","case:ipad-ja","visual:iphone-en","visual:iphone-ja","visual:ipad-en","visual:ipad-ja"]}]
  }
  File.binwrite(path,JSON.generate(value))
' "$artifact_issue/issue-contract.json"
contract_digest=$(digest "$artifact_issue/issue-contract.json")
write_verify() {
  local marker=$1
  cat > "$artifact_head/verify.json" <<JSON
{"schemaVersion":1,"status":"passed","issue":$issue,"baseSha":"$base_sha","headSha":"$head_sha","issueContract":{"path":".artifacts/issues/$issue/issue-contract.json","digest":"$contract_digest"},"visualEvaluation":{"status":"passed","cases":[{"id":"iphone-en","images":[{"state":"primary","path":"iphone-en/screenshot.png","digest":"$image_digest","status":"passed","findings":[]}]}],"findings":[]},"acceptanceEvidence":[{"id":"AC-1","status":"passed","evidence":["visual:iphone-en"]}],"completedAt":"2026-08-24T00:01:00Z","testMarker":"$marker"}
JSON
}
write_verify A

packet_relative=".artifacts/issues/$issue/$head_sha/review-packet.json"
review_relative=".artifacts/issues/$issue/$head_sha/review.json"
"$repo/tools/prepare-review-packet.sh" --primary codex --issue "$issue" --base-sha "$base_sha" --head-sha "$head_sha" > "$workspace/prepared.json"
[[ $(jq -er '.path' "$workspace/prepared.json") == "$packet_relative" ]] || fail 'producer returned a noncanonical packet path'
packet_digest=$(digest "$artifact_head/review-packet.json")
cat > "$workspace/result.json" <<JSON
{"schemaVersion":2,"issue":$issue,"reviewerModel":"claude","baseSha":"$base_sha","headSha":"$head_sha","verifySha":"$head_sha","issueContractDigest":"$contract_digest","verdict":"approved","findings":[],"acceptanceAssessment":[{"id":"AC-1","status":"supported","evidence":["verify.json#acceptanceEvidence/0"]}],"reviewedAt":"2026-08-24T00:02:00Z","reviewPacketDigest":"$packet_digest"}
JSON
"$repo/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$workspace/result.json" >/dev/null

cp "$artifact_issue/issue-contract.json" "$workspace/contract.good"
CONTRACT="$artifact_issue/issue-contract.json" ruby -rjson -e 'path=ENV.fetch("CONTRACT"); value=JSON.parse(File.binread(path)); value["unexpected"]=true; File.binwrite(path,JSON.generate(value))'
assert_fails 'unknown application contract field' "$repo/tools/prepare-review-packet.sh" --primary codex --issue "$issue" --base-sha "$base_sha" --head-sha "$head_sha"
cp "$workspace/contract.good" "$artifact_issue/issue-contract.json"

cp "$artifact_head/review.diff" "$workspace/review.diff.good"
cp "$artifact_head/verify.json" "$workspace/verify.good"
cp "$artifact_head/iphone-en/screenshot.png" "$workspace/image.good"
cp "$artifact_head/review-packet.json" "$workspace/packet.good"
cp "$workspace/result.json" "$workspace/result.good"

printf 'bogus diff\n' > "$artifact_head/review.diff"
assert_fails 'bogus diff bytes' "$repo/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$workspace/result.json"
: > "$artifact_head/review.diff"
assert_fails 'empty diff bytes' "$repo/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$workspace/result.json"
cp "$workspace/review.diff.good" "$artifact_head/review.diff"

write_verify B
assert_fails 'verify A to B under the same Head' "$repo/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$workspace/result.json"
cp "$workspace/verify.good" "$artifact_head/verify.json"

printf 'sealed-image-B\n' > "$artifact_head/iphone-en/screenshot.png"
assert_fails 'verified image swap' "$repo/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$workspace/result.json"
cp "$workspace/image.good" "$artifact_head/iphone-en/screenshot.png"

PACKET="$artifact_head/review-packet.json" ruby -rjson -e 'path=ENV.fetch("PACKET"); value=JSON.parse(File.binread(path)); value["specAnchors"]=["specs/other.md#swap"]; File.binwrite(path,JSON.generate(value))'
assert_fails 'review packet swap' "$repo/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$workspace/result.json"
cp "$workspace/packet.good" "$artifact_head/review-packet.json"

RESULT="$workspace/result.json" ruby -rjson -e 'path=ENV.fetch("RESULT"); value=JSON.parse(File.binread(path)); value["reviewPacketDigest"]="sha256:"+("f"*64); File.binwrite(path,JSON.generate(value))'
assert_fails 'packet and result mismatch' "$repo/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$workspace/result.json"
cp "$workspace/result.good" "$workspace/result.json"

printf 'wrong but self-consistent diff\n' > "$artifact_head/review.diff"
wrong_diff_digest=$(digest "$artifact_head/review.diff")
PACKET="$artifact_head/review-packet.json" DIGEST="$wrong_diff_digest" ruby -rjson -e 'path=ENV.fetch("PACKET"); value=JSON.parse(File.binread(path)); value.fetch("diff")["digest"]=ENV.fetch("DIGEST"); File.binwrite(path,JSON.generate(value))'
wrong_packet_digest=$(digest "$artifact_head/review-packet.json")
RESULT="$workspace/result.json" DIGEST="$wrong_packet_digest" ruby -rjson -e 'path=ENV.fetch("RESULT"); value=JSON.parse(File.binread(path)); value["reviewPacketDigest"]=ENV.fetch("DIGEST"); File.binwrite(path,JSON.generate(value))'
assert_fails 'diff digest matching the wrong actual diff' "$repo/tools/validate-review-result.sh" --primary codex --packet "$packet_relative" --result "$workspace/result.json"
cp "$workspace/review.diff.good" "$artifact_head/review.diff"
cp "$workspace/packet.good" "$artifact_head/review-packet.json"
cp "$workspace/result.good" "$workspace/result.json"

# The producer callback is an internal test seam, not a CLI/environment option.
# Swap a verified image at the exact publication boundary; held descriptors and
# path identity must reject it and leave neither canonical packet nor diff.
rm "$artifact_head/review-packet.json" "$artifact_head/review.diff"
REPO="$repo" ISSUE="$issue" BASE="$base_sha" HEAD="$head_sha" ruby -I "$repo/tools/lib" -rprepare-review-packet -e '
  image=File.join(ENV.fetch("REPO"),".artifacts","issues",ENV.fetch("ISSUE"),ENV.fetch("HEAD"),"iphone-en","screenshot.png")
  begin
    IOSTemplate::PrepareReviewPacket.prepare(repo: ENV.fetch("REPO"), primary: "codex", issue: Integer(ENV.fetch("ISSUE")), base_sha: ENV.fetch("BASE"), head_sha: ENV.fetch("HEAD"), before_publish: lambda {
      replacement=image+".replacement"; File.binwrite(replacement,"atomic-swap\n"); File.rename(replacement,image)
    })
    abort "atomic swap unexpectedly published"
  rescue IOSTemplate::PrepareReviewPacket::PreparationError
  end
'
[[ ! -e "$artifact_head/review-packet.json" && ! -e "$artifact_head/review.diff" ]] || fail 'atomic swap left partial publication'
cp "$workspace/image.good" "$artifact_head/iphone-en/screenshot.png"

# Recreate the exact closure and prove result publication binds the exact packet.
"$repo/tools/prepare-review-packet.sh" --primary codex --issue "$issue" --base-sha "$base_sha" --head-sha "$head_sha" >/dev/null
packet_digest=$(digest "$artifact_head/review-packet.json")
RESULT="$workspace/result.json" DIGEST="$packet_digest" ruby -rjson -e 'path=ENV.fetch("RESULT"); value=JSON.parse(File.binread(path)); value["reviewPacketDigest"]=ENV.fetch("DIGEST"); File.binwrite(path,JSON.generate(value))'
assert_fails 'schema-v2 publication without fixed launcher execution identity' "$repo/tools/lib/publish-review-result.rb" "$repo" "$issue" "$head_sha" "$workspace/result.json" "$artifact_head/review-packet.json"
[[ ! -e "$artifact_head/review.json" ]] || fail 'schema-v2 result bypassed launcher receipt publication'
"$repo/tools/lib/publish-review-result.rb" "$repo" "$issue" "$head_sha" "$workspace/result.json" "$artifact_head/review-packet.json" codex 2026-08-24T00:01:00Z 2026-08-24T00:02:00Z >/dev/null
[[ -f "$artifact_head/review.json" && -f "$artifact_head/review-receipt.json" ]] || fail 'exact packet-bound result/receipt pair was not published'
rm "$artifact_head/review.json" "$artifact_head/review-receipt.json"
PACKET="$artifact_head/review-packet.json" ruby -rjson -e 'path=ENV.fetch("PACKET"); value=JSON.parse(File.binread(path)); value["verifySha"]="0"*40; File.binwrite(path,JSON.generate(value))'
assert_fails 'publication with packet/result mismatch' "$repo/tools/lib/publish-review-result.rb" "$repo" "$issue" "$head_sha" "$workspace/result.json" "$artifact_head/review-packet.json" codex 2026-08-24T00:01:00Z 2026-08-24T00:02:00Z
[[ ! -e "$artifact_head/review.json" ]] || fail 'mismatched packet published a review result'

echo 'PASS: strict review closure rejects bogus diff, same-Head evidence swaps, packet/result mismatch, wrong actual diff, and publication swaps'
