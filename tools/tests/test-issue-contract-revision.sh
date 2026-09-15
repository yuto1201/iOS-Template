#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git jq ruby sed tar

source_repo=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-contract-revision.XXXXXX")
workspace=$(cd "$workspace" && pwd -P)
primary="$workspace/repo"
issue=424338
repository='yuto1201/iOS-Template'
slug='contract-revision'
branch="codex/$issue-$slug"
worktree_relative=".worktrees/$issue-$slug"
worktree="$primary/$worktree_relative"
trap 'rm -rf "$workspace"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_fails() {
  local message=$1
  shift
  if "$@" >"$workspace/rejected.out" 2>&1; then
    fail "expected rejection: $message"
  fi
}
digest() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print "sha256:" $1}'; }

mkdir "$primary"
(cd "$source_repo" && git ls-files -z | tar --null -T - -cf "$workspace/tracked.tar")
(cd "$primary" && tar -xf "$workspace/tracked.tar")
git -C "$primary" init -q
git -C "$primary" config user.name 'Contract Revision Fixture'
git -C "$primary" config user.email 'contract-revision@example.invalid'
git -C "$primary" add .
git -C "$primary" commit -qm 'fixture base'
base_sha=$(git -C "$primary" rev-parse HEAD)
git -C "$primary" branch "$branch"
mkdir -p "$primary/.artifacts" "$primary/.worktrees"
git -C "$primary" worktree add -q "$worktree" "$branch"
ln -s ../../.artifacts "$worktree/.artifacts"
head_sha=$(git -C "$worktree" rev-parse HEAD)

body_v1="$workspace/body-v1.md"
body_v2="$workspace/body-v2.md"
body_v3="$workspace/body-v3.md"
body_v4="$workspace/body-v4.md"
body_forbidden="$workspace/body-forbidden.md"
cat > "$body_v1" <<'BODY'
## Goal

Keep one stable workflow goal.

## In scope

- Revise only audited verification evidence.

## Out of scope

- Product scope changes.

## Acceptance criteria

- AC-1: UI-direction route: not-applicable; Scope: workflow contract revision; Reason: this fixture changes no application UI. Revision text version one.
- AC-2: Repository-test scope: targeted; Reason: the fixture runs only its deterministic workflow tests.

## Spec anchors

- [Acceptance](specs/acceptance.md#3-issue-definition-of-done)

## Dependencies

None

## UI verification

Not applicable

## Delivery stage

- Stage: harden
- Time budget: 120 minutes
- Reason: Harden one workflow boundary.

## Delivery profile

- Profile: strict
- Reason: Contract identity and review evidence are security-sensitive.

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

None
BODY
sed 's/Revision text version one\./Revision text version two./' "$body_v1" > "$body_v2"
sed 's/Revision text version two\./Revision text version three./' "$body_v2" > "$body_v3"
sed 's/Revision text version three\./Revision text version four./' "$body_v3" > "$body_v4"
sed -e 's/Keep one stable workflow goal\./Replace the workflow goal./' \
    -e 's/Revision text version one\./Revision text forbidden./' "$body_v1" > "$body_forbidden"

artifact_issue="$primary/.artifacts/issues/$issue"
mkdir -p "$artifact_issue"
fetched_at='2026-09-15T00:00:00Z'
ruby "$worktree/tools/lib/issue-contract.rb" --body "$body_v1" --type feature --format contract \
  --issue "$issue" --repo "$repository" --fetched-at "$fetched_at" > "$artifact_issue/issue-contract.json"
chmod 600 "$artifact_issue/issue-contract.json"
contract_digest=$(digest "$artifact_issue/issue-contract.json")
STATE="$artifact_issue/state.json" ISSUE="$issue" REPOSITORY="$repository" BRANCH="$branch" \
WORKTREE="$worktree_relative" BASE="$base_sha" CONTRACT_DIGEST="$contract_digest" ruby -rjson -e '
  def canonical(value)
    value.is_a?(Hash) ? value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] } :
      value.is_a?(Array) ? value.map { |entry| canonical(entry) } : value
  end
  value={"schemaVersion"=>1,"issue"=>Integer(ENV.fetch("ISSUE")),"repository"=>ENV.fetch("REPOSITORY"),
    "branch"=>ENV.fetch("BRANCH"),"worktree"=>ENV.fetch("WORKTREE"),"baseSha"=>ENV.fetch("BASE"),
    "primaryImplementer"=>"codex","executor"=>"codex",
    "issueContract"=>{"path"=>".artifacts/issues/#{ENV.fetch("ISSUE")}/issue-contract.json","digest"=>ENV.fetch("CONTRACT_DIGEST")},
    "state"=>"in-progress","previousState"=>"claimed","resumeState"=>nil,"from"=>"claimed","to"=>"in-progress",
    "transitionedAt"=>"2026-09-15T00:00:10Z"}
  File.binwrite(ENV.fetch("STATE"),JSON.generate(canonical(value))+"\n")
'
chmod 600 "$artifact_issue/state.json"

live="$workspace/live.json"
BODY_FILE="$body_v1" LIVE="$live" ISSUE="$issue" REPOSITORY="$repository" ruby -rjson -e '
  File.binwrite(ENV.fetch("LIVE"),JSON.generate({"number"=>Integer(ENV.fetch("ISSUE")),
    "url"=>"https://github.com/#{ENV.fetch("REPOSITORY")}/issues/#{ENV.fetch("ISSUE")}",
    "title"=>"Contract revision fixture","body"=>File.binread(ENV.fetch("BODY_FILE")),
    "labels"=>[{"name"=>"state:in-progress"},{"name"=>"type:feature"}],"comments"=>[]}))
'

tool="$worktree/tools/lib/issue-contract-revision.rb"
ruby "$tool" validate --repo-root "$worktree" --repo "$repository" --issue "$issue" > "$workspace/original.json"
[[ $(jq -er '.status' "$workspace/original.json") == original ]] || fail 'initial contract was not accepted as original revision 1'

marker=$(ruby "$tool" marker --repo-root "$worktree" --repo "$repository" --issue "$issue" \
  --body "$body_v2" --live-json "$live" --trigger user-explicit --reason 'User approved exact AC correction' | jq -er '.marker')
comment_url="https://github.com/$repository/issues/$issue#issuecomment-1001"
comment_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MARKER="$marker" URL="$comment_url" LIVE="$live" COMMENT_AT="$comment_at" ruby -rjson -e '
  value=JSON.parse(File.binread(ENV.fetch("LIVE")))
  value["comments"]=[{"author"=>{"login"=>"yuto1201"},"createdAt"=>ENV.fetch("COMMENT_AT"),
    "url"=>ENV.fetch("URL"),"body"=>"Approved.\n#{ENV.fetch("MARKER")}"}]
  File.binwrite(ENV.fetch("LIVE"),JSON.generate(value))
'

assert_fails 'non-owner user authority' env LIVE="$live" ruby -rjson -I "$worktree/tools/lib" -rissue-contract-revision -e '
  value=JSON.parse(File.binread(ENV.fetch("LIVE"))); value["comments"][0]["author"]["login"]="attacker"
  IOSTemplate::IssueContractRevision.build_revision!(repo_root:ARGV[0],issue:Integer(ARGV[1]),repository:ARGV[2],
    proposed_body:File.binread(ARGV[3]),live_document:value,trigger:"user-explicit",authority_reference:ARGV[4],
    reason:"User approved exact AC correction",delegate:nil)
' "$worktree" "$issue" "$repository" "$body_v2" "$comment_url"
assert_fails 'forbidden Goal change' ruby "$tool" marker --repo-root "$worktree" --repo "$repository" --issue "$issue" \
  --body "$body_forbidden" --live-json "$live" --trigger user-explicit --reason 'Forbidden scope'

mkdir -p "$artifact_issue/$head_sha"
printf 'old verification evidence\n' > "$artifact_issue/$head_sha/verify.json"
printf 'old review evidence\n' > "$artifact_issue/$head_sha/review.json"
ruby "$tool" prepare --repo-root "$worktree" --repo "$repository" --issue "$issue" --body "$body_v2" \
  --live-json "$live" --trigger user-explicit --reason 'User approved exact AC correction' \
  --authority-reference "$comment_url" > "$workspace/prepared-v2.json"
[[ $(jq -er '.revision' "$workspace/prepared-v2.json") == 2 ]] || fail 'first revision was not revision 2'
pending="$artifact_issue/issue-contract-revision.pending.json"
[[ -f "$pending" ]] || fail 'prepare did not publish a pending record'
cp "$pending" "$workspace/pending.good"
printf 'tampered\n' > "$pending"
assert_fails 'tampered pending record' ruby "$tool" resume --repo-root "$worktree" --repo "$repository" --issue "$issue" \
  --body "$body_v2" --live-json "$live" --trigger user-explicit --reason 'User approved exact AC correction' \
  --authority-reference "$comment_url"
cp "$workspace/pending.good" "$pending"
chmod 600 "$pending"

BODY_FILE="$body_v2" LIVE="$live" ruby -rjson -e '
  value=JSON.parse(File.binread(ENV.fetch("LIVE"))); value["body"]=File.binread(ENV.fetch("BODY_FILE"));
  File.binwrite(ENV.fetch("LIVE"),JSON.generate(value))
'
assert_fails 'injected activation interruption' env IOS_TEMPLATE_REVISION_FAIL_AFTER=contract ruby "$tool" activate \
  --repo-root "$worktree" --repo "$repository" --issue "$issue" --body "$body_v2" --live-json "$live" \
  --trigger user-explicit --reason 'User approved exact AC correction' --authority-reference "$comment_url"
[[ -f "$pending" ]] || fail 'interrupted activation removed pending recovery state'
ruby "$tool" activate --repo-root "$worktree" --repo "$repository" --issue "$issue" --body "$body_v2" \
  --live-json "$live" --trigger user-explicit --reason 'User approved exact AC correction' \
  --authority-reference "$comment_url" > "$workspace/activated-v2.json"
[[ ! -e "$pending" ]] || fail 'completed activation retained pending state'
[[ -f "$artifact_issue/$head_sha/verify.json" && -f "$artifact_issue/$head_sha/review.json" ]] || fail 'old evidence artifacts were deleted'
[[ $(jq -er '.issueContractRevision.revision' "$artifact_issue/state.json") == 2 ]] || fail 'durable state did not bind revision 2'
[[ $(jq -er 'has("headSha") | not' "$artifact_issue/state.json") == true ]] || fail 'stale Head binding was retained'
ruby "$tool" validate --repo-root "$worktree" --repo "$repository" --issue "$issue" >/dev/null

# A delegated owner comment must bind the current executor, exact scope, body,
# source Head, reason, and prior contract digest.
BODY_FILE="$body_v2" LIVE="$live" ruby -rjson -e '
  value=JSON.parse(File.binread(ENV.fetch("LIVE"))); value["body"]=File.binread(ENV.fetch("BODY_FILE")); value["comments"]=[];
  File.binwrite(ENV.fetch("LIVE"),JSON.generate(value))
'
delegated_marker=$(ruby "$tool" marker --repo-root "$worktree" --repo "$repository" --issue "$issue" \
  --body "$body_v3" --live-json "$live" --trigger user-delegated --delegate codex --reason 'Delegate exact AC correction' | jq -er '.marker')
delegated_url="https://github.com/$repository/issues/$issue#issuecomment-1002"
delegated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MARKER="$delegated_marker" URL="$delegated_url" LIVE="$live" COMMENT_AT="$delegated_at" ruby -rjson -e '
  value=JSON.parse(File.binread(ENV.fetch("LIVE")))
  value["comments"]=[{"author"=>{"login"=>"yuto1201"},"createdAt"=>ENV.fetch("COMMENT_AT"),
    "url"=>ENV.fetch("URL"),"body"=>ENV.fetch("MARKER")}]
  File.binwrite(ENV.fetch("LIVE"),JSON.generate(value))
'
assert_fails 'delegation to another executor' ruby "$tool" prepare --repo-root "$worktree" --repo "$repository" --issue "$issue" \
  --body "$body_v3" --live-json "$live" --trigger user-delegated --delegate claude \
  --reason 'Delegate exact AC correction' --authority-reference "$delegated_url"
ruby "$tool" prepare --repo-root "$worktree" --repo "$repository" --issue "$issue" --body "$body_v3" \
  --live-json "$live" --trigger user-delegated --delegate codex --reason 'Delegate exact AC correction' \
  --authority-reference "$delegated_url" >/dev/null
BODY_FILE="$body_v3" LIVE="$live" ruby -rjson -e '
  value=JSON.parse(File.binread(ENV.fetch("LIVE"))); value["body"]=File.binread(ENV.fetch("BODY_FILE"));
  File.binwrite(ENV.fetch("LIVE"),JSON.generate(value))
'
ruby "$tool" activate --repo-root "$worktree" --repo "$repository" --issue "$issue" --body "$body_v3" \
  --live-json "$live" --trigger user-delegated --delegate codex --reason 'Delegate exact AC correction' \
  --authority-reference "$delegated_url" >/dev/null
[[ $(jq -er '.issueContractRevision.revision' "$artifact_issue/state.json") == 3 ]] || fail 'delegated revision did not advance monotonically'

# Simulate the exact workflow state after a canonical changes-requested review
# was returned to in-progress. The injected validator is a test seam; the
# production default invokes both the canonical result and launcher-receipt
# validators before trusting the finding.
STATE="$artifact_issue/state.json" ruby -rjson -e '
  path=ENV.fetch("STATE"); value=JSON.parse(File.binread(path));
  value["state"]="in-progress"; value["previousState"]="changes-requested"; value["from"]="changes-requested";
  value["to"]="in-progress"; value["transitionedAt"]="2026-09-15T00:03:00Z"; value.delete("headSha")
  def canonical(entry); entry.is_a?(Hash) ? entry.keys.sort.to_h{|key|[key,canonical(entry[key])]} : entry.is_a?(Array) ? entry.map{|v|canonical(v)} : entry end
  File.binwrite(path,JSON.generate(canonical(value))+"\n")
'
current_contract_digest=$(digest "$artifact_issue/issue-contract.json")
cat > "$artifact_issue/$head_sha/review.json" <<JSON
{"schemaVersion":2,"issue":$issue,"reviewerModel":"claude","baseSha":"$base_sha","headSha":"$head_sha","verifySha":"$head_sha","issueContractDigest":"$current_contract_digest","reviewPacketDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","verdict":"changes-requested","findings":[{"severity":"high","category":"correctness","file":"tools/lib/issue-contract-revision.rb","line":1,"title":"Exact revision gap","evidence":"Current Head evidence","requiredChange":"Fix exact mapping"}],"acceptanceAssessment":[{"id":"AC-1","status":"unsupported","evidence":[]},{"id":"AC-2","status":"supported","evidence":["repository-tests.json#acceptanceEvidence/1"]}],"reviewedAt":"2026-09-15T00:02:30Z"}
JSON
review_reference=".artifacts/issues/$issue/$head_sha/review.json#findings/0"
REPO_ROOT="$worktree" ISSUE="$issue" REPOSITORY="$repository" BODY="$body_v4" LIVE="$live" REF="$review_reference" ruby -I "$worktree/tools/lib" -rissue-contract-revision -rjson -e '
  live=JSON.parse(File.binread(ENV.fetch("LIVE"))); live["body"]=File.binread(ENV.fetch("BODY").sub("v4","v3"))
  validator=lambda { |**values| abort "wrong review identity" unless values[:head_sha] == `git -C #{ENV.fetch("REPO_ROOT")} rev-parse HEAD`.strip }
  result=IOSTemplate::IssueContractRevision.build_revision!(repo_root:ENV.fetch("REPO_ROOT"),issue:Integer(ENV.fetch("ISSUE")),repository:ENV.fetch("REPOSITORY"),
    proposed_body:File.binread(ENV.fetch("BODY")),live_document:live,trigger:"review-finding",authority_reference:ENV.fetch("REF"),
    reason:"Fix exact mapping",delegate:nil,review_validator:validator)
  puts JSON.generate(result)
' > "$workspace/prepared-v4.json"
BODY_FILE="$body_v4" LIVE="$live" ruby -rjson -e '
  value=JSON.parse(File.binread(ENV.fetch("LIVE"))); value["body"]=File.binread(ENV.fetch("BODY_FILE")); value["comments"]=[];
  File.binwrite(ENV.fetch("LIVE"),JSON.generate(value))
'
REPO_ROOT="$worktree" ISSUE="$issue" REPOSITORY="$repository" BODY="$body_v4" LIVE="$live" REF="$review_reference" ruby -I "$worktree/tools/lib" -rissue-contract-revision -rjson -e '
  validator=lambda { |**_values| true }
  result=IOSTemplate::IssueContractRevision.activate_pending!(repo_root:ENV.fetch("REPO_ROOT"),issue:Integer(ENV.fetch("ISSUE")),repository:ENV.fetch("REPOSITORY"),
    proposed_body:File.binread(ENV.fetch("BODY")),live_document:JSON.parse(File.binread(ENV.fetch("LIVE"))),trigger:"review-finding",
    authority_reference:ENV.fetch("REF"),reason:"Fix exact mapping",delegate:nil,review_validator:validator)
  puts JSON.generate(result)
' > "$workspace/activated-v4.json"
[[ $(jq -er '.issueContractRevision.revision' "$artifact_issue/state.json") == 4 ]] || fail 'review-finding revision was not accepted'

# A later current-Head verification binding is valid and retains the revision
# chain. Removing the chain reference or changing any immutable record is not.
cp "$artifact_issue/state.json" "$workspace/state.good"
STATE="$artifact_issue/state.json" HEAD_SHA="$head_sha" ruby -rjson -e '
  path=ENV.fetch("STATE"); value=JSON.parse(File.binread(path)); value["state"]="verify-passed"; value["previousState"]="in-progress";
  value["from"]="in-progress"; value["to"]="verify-passed"; value["headSha"]=ENV.fetch("HEAD_SHA");
  def canonical(entry); entry.is_a?(Hash) ? entry.keys.sort.to_h{|key|[key,canonical(entry[key])]} : entry.is_a?(Array) ? entry.map{|v|canonical(v)} : entry end
  File.binwrite(path,JSON.generate(canonical(value))+"\n")
'
ruby "$tool" validate --repo-root "$worktree" --repo "$repository" --issue "$issue" >/dev/null
STATE="$artifact_issue/state.json" ruby -rjson -e '
  path=ENV.fetch("STATE"); value=JSON.parse(File.binread(path)); value.delete("issueContractRevision")
  def canonical(entry); entry.is_a?(Hash) ? entry.keys.sort.to_h{|key|[key,canonical(entry[key])]} : entry.is_a?(Array) ? entry.map{|v|canonical(v)} : entry end
  File.binwrite(path,JSON.generate(canonical(value))+"\n")
'
assert_fails 'revision history without state reference' ruby "$tool" validate --repo-root "$worktree" --repo "$repository" --issue "$issue"
cp "$workspace/state.good" "$artifact_issue/state.json"

record="$artifact_issue/issue-contract-revisions/records/revision-0004.json"
cp "$record" "$workspace/record.good"
RECORD="$record" ruby -rjson -e 'path=ENV.fetch("RECORD"); value=JSON.parse(File.binread(path)); value["reason"]="tampered"; File.binwrite(path,JSON.generate(value))'
assert_fails 'tampered immutable revision record' ruby "$tool" validate --repo-root "$worktree" --repo "$repository" --issue "$issue"
cp "$workspace/record.good" "$record"

echo 'PASS: audited Issue contract revisions enforce three authority routes, immutable chains, bounded fields, recovery, and evidence invalidation'
