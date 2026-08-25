#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-premerge-gate.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

repo="$scratch/repo"
git init -b main "$repo" >/dev/null
git -C "$repo" config user.name 'Gate Fixture'
git -C "$repo" config user.email 'gate-fixture@example.invalid'
mkdir -p "$repo/tools" "$repo/.artifacts/issues/42" "$repo/Config"
cp "$repo_root/tools/validate-issue-body.sh" "$repo/tools/"
cp "$repo_root/tools/validate-verify-json.swift" "$repo/tools/"
cp "$repo_root/tools/premerge-gate.sh" "$repo/tools/"
cp "$repo_root/tools/cross-model-review.sh" "$repo/tools/"
cp "$repo_root/tools/prepare-review-packet.sh" "$repo/tools/"
cp "$repo_root/tools/render-pr-body.sh" "$repo/tools/"
cp -R "$repo_root/tools/lib" "$repo/tools/"
cp -R "$repo_root/.agents" "$repo/"
cp -R "$repo_root/specs" "$repo/"
cp "$repo_root/Config/ownership.yml" "$repo/Config/"
ruby -e 'path=ARGV.fetch(0); text=File.binread(path); text.sub!("projectRef: null","projectRef: personal-project") or abort; File.binwrite(path,text)' "$repo/Config/ownership.yml"
printf '.artifacts\n' > "$repo/.gitignore"
printf 'fixture\n' > "$repo/README.md"
git -C "$repo" add .gitignore README.md Config tools .agents specs
git -C "$repo" commit -m 'base' >/dev/null
base_sha=$(git -C "$repo" rev-parse HEAD)
printf 'documentation change\n' >> "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -m 'documentation change' >/dev/null
head_sha=$(git -C "$repo" rev-parse HEAD)

mkdir -p "$repo/.artifacts/issues/42/$head_sha"

timestamp() { ruby -rtime -e 'puts (Time.now.utc + Integer(ARGV.fetch(0))).iso8601' -- "$1"; }
contract_at=$(timestamp -240)
verify_at=$(timestamp -180)
review_at=$(timestamp -120)
transition_at=$(timestamp -60)
preflight_at=$(timestamp -30)

issue_body="$scratch/issue.md"
cat > "$issue_body" <<'EOF'
## Goal

マージ安全性を決定的に保つ。

## In scope

- Verify current evidence before merging.

## Out of scope

- Change application code.

## Acceptance criteria

- AC-1: The verified Head is current.
- AC-2: Every acceptance criterion has one evidence mapping.

## Spec anchors

- [Acceptance](specs/README.md#spec-index)

## Dependencies

- None.

## UI verification

- Not applicable.

## External operations

- Operation: github.merge_pr
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

## User approvals

- None.
EOF

canonical_contract() {
  ruby "$repo/tools/lib/issue-contract.rb" --body "$issue_body" --type feature --format contract \
    --issue 42 --repo yuto1201/iOS-Template --fetched-at "$contract_at"
}
canonical_contract > "$repo/.artifacts/issues/42/issue-contract.json"
contract_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/issue-contract.json" | awk '{print $1}')"

write_verify() {
  ISSUE_CONTRACT_DIGEST="$contract_digest" HEAD="$head_sha" BASE="$base_sha" COMPLETED_AT="$verify_at" ruby -rjson -e '
    value = {"schemaVersion" => 1, "status" => "not-applicable", "changeClassification" => "documentation-only", "reason" => "Only allowlisted Markdown documentation changed", "issue" => 42, "baseSha" => ENV.fetch("BASE"), "headSha" => ENV.fetch("HEAD"), "issueContract" => {"path" => ".artifacts/issues/42/issue-contract.json", "digest" => ENV.fetch("ISSUE_CONTRACT_DIGEST")}, "matrixFile" => nil, "matrixDigest" => nil, "executionRoute" => "none", "xcode" => nil, "build" => {"status" => "not-applicable", "scheme" => nil, "warningsAdded" => nil, "project" => nil, "sourceTree" => nil}, "tests" => {"status" => "not-applicable", "passed" => nil, "failed" => nil, "skipped" => nil}, "cases" => [], "visualEvaluation" => {"status" => "not-applicable", "findings" => []}, "acceptanceEvidence" => [{"id" => "AC-1", "status" => "passed", "evidence" => ["documents:README consistency"]}, {"id" => "AC-2", "status" => "passed", "evidence" => ["links:swift tools/check-markdown-links.swift"]}], "completedAt" => ENV.fetch("COMPLETED_AT")}
    puts JSON.generate(value)
  ' > "$repo/.artifacts/issues/42/$head_sha/verify.json"
}

write_review() {
  verdict=${1:-approved}
  packet_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/$head_sha/review-packet.json" | awk '{print $1}')"
  VERDICT="$verdict" REVIEW_PACKET_DIGEST="$packet_digest" ISSUE_CONTRACT_DIGEST="$contract_digest" HEAD="$head_sha" BASE="$base_sha" REVIEWED_AT="$review_at" ruby -rjson -e '
    findings = ENV.fetch("VERDICT") == "approved" ? [] : [{"severity" => "high", "category" => "correctness", "file" => "README.md", "line" => 1, "title" => "blocking", "evidence" => "fixture", "requiredChange" => "fix"}]
    assessments = ["AC-1", "AC-2"].map { |id| {"id" => id, "status" => ENV.fetch("VERDICT") == "approved" ? "supported" : "unsupported", "evidence" => ["verify.json#acceptanceEvidence"]} }
    puts JSON.generate({"schemaVersion" => 2, "issue" => 42, "reviewerModel" => "claude", "baseSha" => ENV.fetch("BASE"), "headSha" => ENV.fetch("HEAD"), "verifySha" => ENV.fetch("HEAD"), "issueContractDigest" => ENV.fetch("ISSUE_CONTRACT_DIGEST"), "reviewPacketDigest" => ENV.fetch("REVIEW_PACKET_DIGEST"), "verdict" => ENV.fetch("VERDICT"), "findings" => findings, "acceptanceAssessment" => assessments, "reviewedAt" => ENV.fetch("REVIEWED_AT")})
  ' > "$repo/.artifacts/issues/42/$head_sha/review.json"
  write_receipt
}

write_receipt() {
  local packet="$repo/.artifacts/issues/42/$head_sha/review-packet.json"
  local review="$repo/.artifacts/issues/42/$head_sha/review.json"
  local launcher="$repo/tools/cross-model-review.sh"
  RECEIPT="$repo/.artifacts/issues/42/$head_sha/review-receipt.json" ISSUE=42 HEAD="$head_sha" PACKET="$packet" REVIEW="$review" LAUNCHER="$launcher" STARTED_AT="$review_at" COMPLETED_AT="$review_at" ruby -rjson -rdigest -e '
    digest = ->(path) { "sha256:#{Digest::SHA256.file(path).hexdigest}" }
    value={"schemaVersion"=>1,"issue"=>Integer(ENV.fetch("ISSUE")),"headSha"=>ENV.fetch("HEAD"),"primaryModel"=>"codex","reviewerModel"=>"claude","launcher"=>"tools/cross-model-review.sh","launcherDigest"=>digest.call(ENV.fetch("LAUNCHER")),"reviewerLauncher"=>"tools/cross-model-review.sh","reviewerLauncherDigest"=>digest.call(ENV.fetch("LAUNCHER")),"reviewPacketDigest"=>digest.call(ENV.fetch("PACKET")),"validatedResultDigest"=>digest.call(ENV.fetch("REVIEW")),"publishedReviewDigest"=>digest.call(ENV.fetch("REVIEW")),"startedAt"=>ENV.fetch("STARTED_AT"),"completedAt"=>ENV.fetch("COMPLETED_AT"),"exitStatus"=>0}
    File.binwrite(ENV.fetch("RECEIPT"),JSON.generate(value))
  '
}

write_review_packet() {
  rm -f "$repo/.artifacts/issues/42/$head_sha/review-packet.json" "$repo/.artifacts/issues/42/$head_sha/review.diff"
  (cd "$issue_worktree" && "$issue_worktree/tools/prepare-review-packet.sh" --primary codex --issue 42 --base-sha "$base_sha" --head-sha "$head_sha") >/dev/null
}

write_preflight() {
  local checked_at=${1:-$preflight_at}
  HEAD="$head_sha" CHECKED_AT="$checked_at" ruby -rjson -rdigest -e '
    def canonical(v); v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, canonical(v[k])] } : v; end
    value = {"account" => "yuto1201", "repository" => "yuto1201/iOS-Template", "defaultBranch" => "main", "url" => "https://github.com/yuto1201/iOS-Template", "intendedOperation" => "github.merge_pr", "issue" => 42, "headSha" => ENV.fetch("HEAD"), "checkedAt" => ENV.fetch("CHECKED_AT")}
    value["digest"] = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
    puts JSON.generate(canonical(value))
  ' > "$repo/.artifacts/issues/42/github-preflight.json"
}

mutate_signed_preflight() {
  local mutation=$1
  MUTATION="$mutation" ruby -rjson -rdigest -e '
    def canonical(value); value.is_a?(Hash) ? value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] } : value; end
    path = ARGV.fetch(0); value = JSON.parse(File.binread(path)); eval(ENV.fetch("MUTATION"), binding, "preflight mutation"); unsigned = value.reject { |key, _| key == "digest" }; value["digest"] = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(unsigned)))}"; File.binwrite(path, JSON.generate(canonical(value)))
  ' "$repo/.artifacts/issues/42/github-preflight.json"
}

fake_bin="$scratch/bin"
mkdir "$fake_bin"
real_swift=$(command -v swift)
real_ruby=$(command -v ruby)
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
if [[ "$1 $2" == 'auth status' ]]; then
  printf 'Logged in to github.com account %s (keychain)\n  - Active account: true\n' "${FAKE_ACTIVE_ACCOUNT:-yuto1201}"
  exit 0
fi
if [[ "$1 $2" == 'repo view' ]]; then
  REPOSITORY="${FAKE_REPOSITORY_ID:-yuto1201/iOS-Template}" ruby -rjson -e 'repo=ENV.fetch("REPOSITORY"); puts JSON.generate({"nameWithOwner"=>repo,"defaultBranchRef"=>{"name"=>"main"},"url"=>"https://github.com/#{repo}"})'
  exit 0
fi
if [[ "$1 $2" == 'issue view' ]]; then
  if [[ -n "${CTIME_ONLY_HELD_TARGET:-}" ]]; then
    TARGET="${CTIME_ONLY_HELD_TARGET:?}" "${REAL_RUBY:?}" -e 'path=ENV.fetch("TARGET"); before=File.stat(path); File.chmod(before.mode & 0o7777,path); after=File.stat(path); abort unless before.mode==after.mode && before.mtime==after.mtime && before.ctime!=after.ctime'
  fi
  if [[ -n "${REWRITE_HELD_TARGET:-}" ]]; then
    TARGET="${REWRITE_HELD_TARGET:?}" "${REAL_RUBY:?}" -e 'path=ENV.fetch("TARGET"); bytes=File.binread(path); File.open(path,"r+b"){|io|io.write(bytes);io.flush;io.fsync}'
  fi
  ruby -rjson -e 'labels = [{"name" => ENV.fetch("FAKE_TYPE_LABEL", "type:feature"), "color" => "", "description" => ""}]; labels << {"name" => ENV["FAKE_SECOND_TYPE"], "color" => "", "description" => ""} if ENV["FAKE_SECOND_TYPE"]; puts JSON.generate({"number" => 42, "url" => "https://github.com/yuto1201/iOS-Template/issues/42", "body" => File.read(ENV.fetch("FAKE_ISSUE_BODY")), "labels" => labels})'
  exit 0
fi
if [[ "$1 $2" == 'pr view' ]]; then
  if [[ -n "${FINAL_GATE_SWAP_TARGET:-}" ]]; then
    cp "$FINAL_GATE_SWAP_TARGET" "$FINAL_GATE_SWAP_TARGET.swap"
    mv -f "$FINAL_GATE_SWAP_TARGET.swap" "$FINAL_GATE_SWAP_TARGET"
  fi
  HEAD="${FAKE_HEAD:?}" ruby -rjson -e 'puts JSON.generate({"number"=>57,"state"=>"OPEN","baseRefName"=>"main","headRefName"=>"codex/42-gate-evidence","headRefOid"=>ENV.fetch("HEAD"),"headRepository"=>{"nameWithOwner"=>"yuto1201/iOS-Template"},"headRepositoryOwner"=>{"login"=>"yuto1201"},"isCrossRepository"=>false,"closingIssuesReferences"=>[{"number"=>42,"url"=>"https://github.com/yuto1201/iOS-Template/issues/42","repository"=>{"nameWithOwner"=>"yuto1201/iOS-Template"}}],"mergeCommit"=>nil,"url"=>"https://github.com/yuto1201/iOS-Template/pull/57"})'
  exit 0
fi
if [[ "$1 $2" == 'pr merge' ]]; then
  printf 'merged\n' >> "${FAKE_MERGE_MUTATIONS:?}"
  exit 0
fi
echo "unexpected gh command: $*" >&2
exit 2
EOF
cat > "$fake_bin/swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${SWAP_TARGET:-}" ]]; then
  cp "$SWAP_TARGET" "$SWAP_TARGET.swap"
  mv -f "$SWAP_TARGET.swap" "$SWAP_TARGET"
fi
if [[ "${FAKE_SKIP_SWIFT:-0}" == 1 ]]; then
  exit 0
fi
exec "${REAL_SWIFT:?}" "$@"
EOF
cat > "$fake_bin/ruby" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'/tools/lib/merge-state.rb validate-worktree '* && -n "${STATE_AFTER_VALIDATE_MODE:-}" ]]; then
  output=$("${REAL_RUBY:?}" "$@")
  case "$STATE_AFTER_VALIDATE_MODE" in
    swap)
      cp "${FAKE_STATE_PATH:?}" "${FAKE_STATE_PATH}.replacement"
      mv -f "${FAKE_STATE_PATH}.replacement" "$FAKE_STATE_PATH"
      ;;
    primary)
      STATE_PATH="${FAKE_STATE_PATH:?}" "${REAL_RUBY:?}" -e 'path=ENV.fetch("STATE_PATH"); bytes=File.binread(path); changed=bytes.sub(%q{"primaryImplementer":"codex"},%q{"primaryImplementer":"claud"}); abort if changed==bytes || changed.bytesize!=bytes.bytesize; File.open(path,"r+b"){|io|io.write(changed);io.flush;io.fsync}'
      ;;
    timestamp)
      STATE_PATH="${FAKE_STATE_PATH:?}" "${REAL_RUBY:?}" -e 'path=ENV.fetch("STATE_PATH"); bytes=File.binread(path); changed=bytes.sub(/("transitionedAt":"[^"]*?)(\d)(Z")/){"#{$1}#{(Integer($2)+1)%10}#{$3}"}; abort if changed==bytes || changed.bytesize!=bytes.bytesize; File.open(path,"r+b"){|io|io.write(changed);io.flush;io.fsync}'
      ;;
    ctime)
      STATE_PATH="${FAKE_STATE_PATH:?}" "${REAL_RUBY:?}" -e 'path=ENV.fetch("STATE_PATH"); before=File.stat(path); File.chmod(before.mode & 0o7777,path); after=File.stat(path); abort unless before.mode==after.mode && before.mtime==after.mtime && before.ctime!=after.ctime'
      ;;
    *) exit 97 ;;
  esac
  printf '%s\n' "$output"
  exit 0
fi
exec "${REAL_RUBY:?}" "$@"
EOF
chmod +x "$fake_bin/gh" "$fake_bin/swift" "$fake_bin/ruby"
export PATH="$fake_bin:$PATH" REAL_SWIFT="$real_swift" REAL_RUBY="$real_ruby" FAKE_GH_LOG="$scratch/gh.log" FAKE_ISSUE_BODY="$issue_body" FAKE_MERGE_MUTATIONS="$scratch/merge-mutations.log" FAKE_HEAD="$head_sha"

issue_worktree="$repo/.worktrees/42-gate-evidence"
mkdir -p "$repo/.worktrees"
git -C "$repo" worktree add -b codex/42-gate-evidence "$issue_worktree" "$head_sha" >/dev/null
ln -s ../../.artifacts "$issue_worktree/.artifacts"
HEAD="$head_sha" BASE="$base_sha" DIGEST="$contract_digest" TRANSITIONED_AT="$transition_at" ruby -rjson -e 'puts JSON.generate({"schemaVersion" => 1, "issue" => 42, "repository" => "yuto1201/iOS-Template", "branch" => "codex/42-gate-evidence", "worktree" => ".worktrees/42-gate-evidence", "baseSha" => ENV.fetch("BASE"), "primaryImplementer" => "codex", "issueContract" => {"path" => ".artifacts/issues/42/issue-contract.json", "digest" => ENV.fetch("DIGEST")}, "state" => "approved-for-merge", "previousState" => "review-requested", "resumeState" => nil, "executor" => "codex", "headSha" => ENV.fetch("HEAD"), "pullRequest" => 57, "from" => "review-requested", "to" => "approved-for-merge", "transitionedAt" => ENV.fetch("TRANSITIONED_AT")})' > "$repo/.artifacts/issues/42/state.json"
export FAKE_STATE_PATH="$repo/.artifacts/issues/42/state.json"

assert_fails() {
  local label=$1
  shift
  if "$@" >"$scratch/output" 2>&1; then
    echo "expected failure: $label" >&2
    exit 1
  fi
}

assert_fails_with() {
  local label=$1 diagnostic=$2
  shift 2
  assert_fails "$label" "$@"
  grep -Fq "$diagnostic" "$scratch/output" || {
    echo "unexpected diagnostic for $label" >&2
    cat "$scratch/output" >&2
    exit 1
  }
}

run_gate() {
  (cd "$issue_worktree" && "$issue_worktree/tools/premerge-gate.sh" --repo yuto1201/iOS-Template --issue 42 --head-sha "$head_sha")
}

run_gate_merge() {
  (cd "$issue_worktree" && "$issue_worktree/tools/premerge-gate.sh" --repo yuto1201/iOS-Template --issue 42 --head-sha "$head_sha" --merge-pr 57)
}

write_verify
write_review_packet
write_review
write_preflight

# RED was observed before premerge-gate.sh existed. Matching evidence now opens
# the GREEN cycle; later assertions deliberately mutate exactly one invariant.
run_gate > "$scratch/gate.json"
jq -e --arg head "$head_sha" '.status == "passed" and .headSha == $head' "$scratch/gate.json" >/dev/null
expected_gh="issue view 42 --repo yuto1201/iOS-Template --json number,url,body,labels"
[[ "$(tail -n 1 "$FAKE_GH_LOG")" == "$expected_gh" ]] || { echo 'gate used an unexpected gh command' >&2; exit 1; }
CTIME_ONLY_HELD_TARGET="$repo/.artifacts/issues/42/github-preflight.json" run_gate >/dev/null

rm "$repo/.artifacts/issues/42/$head_sha/review-receipt.json"
assert_fails 'approved review without an opposite-model execution receipt is rejected' run_gate
write_receipt

: > "$FAKE_GH_LOG"
: > "$FAKE_MERGE_MUTATIONS"
FINAL_GATE_SWAP_TARGET="$repo/.artifacts/issues/42/state.json" assert_fails 'state swap after final validation is rejected before merge' run_gate_merge
grep -Fxq 'pr view 57 --repo yuto1201/iOS-Template --json number,state,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,closingIssuesReferences,mergeCommit,url' "$FAKE_GH_LOG" || { echo 'final Gate did not reach the exact PR refresh' >&2; exit 1; }
[[ ! -s "$FAKE_MERGE_MUTATIONS" ]] || { echo 'final Gate merged after its held state was swapped' >&2; exit 1; }
mv "$repo/.artifacts/issues/42/state.json.swap" "$repo/.artifacts/issues/42/state.json" 2>/dev/null || true
: > "$FAKE_GH_LOG"
run_gate_merge >/dev/null
expected_final_gate=$(cat <<EOF
issue view 42 --repo yuto1201/iOS-Template --json number,url,body,labels
auth status --active
repo view yuto1201/iOS-Template --json nameWithOwner,defaultBranchRef,url
pr view 57 --repo yuto1201/iOS-Template --json number,state,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,closingIssuesReferences,mergeCommit,url
pr merge 57 --repo yuto1201/iOS-Template --squash --match-head-commit $head_sha
EOF
)
[[ "$(cat "$FAKE_GH_LOG")" == "$expected_final_gate" ]] || { echo 'final Gate PR refresh and merge argv/order differed' >&2; diff -u <(printf '%s\n' "$expected_final_gate") "$FAKE_GH_LOG" >&2; exit 1; }
: > "$FAKE_MERGE_MUTATIONS"
FAKE_ACTIVE_ACCOUNT=company assert_fails 'active account change inside final lease is rejected' run_gate_merge
[[ ! -s "$FAKE_MERGE_MUTATIONS" ]] || { echo 'wrong active account reached merge' >&2; exit 1; }
FAKE_REPOSITORY_ID=company/iOS-Template assert_fails 'repository change inside final lease is rejected' run_gate_merge
[[ ! -s "$FAKE_MERGE_MUTATIONS" ]] || { echo 'wrong repository identity reached merge' >&2; exit 1; }
RECEIPT="$repo/.artifacts/issues/42/$head_sha/review-receipt.json" ruby -rjson -e 'path=ENV.fetch("RECEIPT"); value=JSON.parse(File.binread(path)); value["publishedReviewDigest"]="sha256:"+("0"*64); File.binwrite(path,JSON.generate(value))'
assert_fails 'forged review receipt is rejected' run_gate
write_receipt

# Application contracts add one canonical verification object to the exact
# live-Issue snapshot. The strict Gate must preserve that optional object while
# still rejecting every other extra top-level field.
CONTRACT="$repo/.artifacts/issues/42/issue-contract.json" ruby -rjson -e '
  def canonical(value); value.is_a?(Hash) ? value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] } : value.is_a?(Array) ? value.map { |entry| canonical(entry) } : value; end
  path=ENV.fetch("CONTRACT"); value=JSON.parse(File.binread(path))
  value["verification"]={"bundleIdentifier"=>"com.example.TemplateApp","unitTestIdentifier"=>"TemplateAppTests/UnitSmokeTests/testUnit","cases"=>[{"id"=>"iphone-en","testIdentifier"=>"TemplateAppUITests/SmokeTests/testLaunch"},{"id"=>"iphone-ja","assertion"=>{"kind"=>"launch-succeeded"}},{"id"=>"ipad-en","testIdentifier"=>"TemplateAppUITests/SmokeTests/testLaunch"},{"id"=>"ipad-ja","assertion"=>{"kind"=>"launch-succeeded"}}],"acceptanceMappings"=>[{"id"=>"AC-1","checks"=>["stage:build","stage:unit-tests"]},{"id"=>"AC-2","checks"=>["case:iphone-en","case:iphone-ja","case:ipad-en","case:ipad-ja","visual:iphone-en","visual:iphone-ja","visual:ipad-en","visual:ipad-ja"]}]}
  File.binwrite(path,JSON.generate(canonical(value)))
'
contract_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/issue-contract.json" | awk '{print $1}')"
DIGEST="$contract_digest" ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["issueContract"]["digest"]=ENV.fetch("DIGEST"); File.binwrite(path,JSON.generate(value))' "$repo/.artifacts/issues/42/state.json"
write_verify
write_review_packet
write_review
write_preflight
run_gate >/dev/null

CONTRACT="$repo/.artifacts/issues/42/issue-contract.json" STATE="$repo/.artifacts/issues/42/state.json" VERIFY="$repo/.artifacts/issues/42/$head_sha/verify.json" PACKET="$repo/.artifacts/issues/42/$head_sha/review-packet.json" REVIEW="$repo/.artifacts/issues/42/$head_sha/review.json" ruby -rjson -rdigest -e '
  contract=JSON.parse(File.binread(ENV.fetch("CONTRACT"))); contract["unexpected"]=true; File.binwrite(ENV.fetch("CONTRACT"),JSON.generate(contract)); contract_digest="sha256:#{Digest::SHA256.file(ENV.fetch("CONTRACT")).hexdigest}"
  state=JSON.parse(File.binread(ENV.fetch("STATE"))); state.fetch("issueContract")["digest"]=contract_digest; File.binwrite(ENV.fetch("STATE"),JSON.generate(state))
  verify=JSON.parse(File.binread(ENV.fetch("VERIFY"))); verify.fetch("issueContract")["digest"]=contract_digest; File.binwrite(ENV.fetch("VERIFY"),JSON.generate(verify)); verify_digest="sha256:#{Digest::SHA256.file(ENV.fetch("VERIFY")).hexdigest}"
  packet=JSON.parse(File.binread(ENV.fetch("PACKET"))); packet.fetch("issueContract")["digest"]=contract_digest; packet.fetch("verify")["digest"]=verify_digest; File.binwrite(ENV.fetch("PACKET"),JSON.generate(packet)); packet_digest="sha256:#{Digest::SHA256.file(ENV.fetch("PACKET")).hexdigest}"
  review=JSON.parse(File.binread(ENV.fetch("REVIEW"))); review["issueContractDigest"]=contract_digest; review["reviewPacketDigest"]=packet_digest; File.binwrite(ENV.fetch("REVIEW"),JSON.generate(review))
'
assert_fails_with 'unknown application contract field is rejected by strict Gate' 'Issue contract has unknown fields: unexpected' run_gate

canonical_contract > "$repo/.artifacts/issues/42/issue-contract.json"
contract_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/issue-contract.json" | awk '{print $1}')"
DIGEST="$contract_digest" ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["issueContract"]["digest"]=ENV.fetch("DIGEST"); File.binwrite(path,JSON.generate(value))' "$repo/.artifacts/issues/42/state.json"
write_verify
write_review_packet
write_review
write_preflight

: > "$FAKE_GH_LOG"
cp "$repo/.artifacts/issues/42/issue-contract.json" "$scratch/contract.with-merge"
ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["externalOperations"]=[]; value["externalOperationDetailsDigest"]="sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"; File.binwrite(path,JSON.generate(value.sort.to_h))' "$repo/.artifacts/issues/42/issue-contract.json"
missing_merge_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/issue-contract.json" | awk '{print $1}')"
DIGEST="$missing_merge_digest" ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["issueContract"]["digest"]=ENV.fetch("DIGEST"); File.binwrite(path,JSON.generate(value))' "$repo/.artifacts/issues/42/state.json"
assert_fails 'missing github.merge_pr declaration is rejected before gh' run_gate
[[ ! -s "$FAKE_GH_LOG" ]] || { echo 'missing merge declaration reached gh' >&2; exit 1; }
cp "$scratch/contract.with-merge" "$repo/.artifacts/issues/42/issue-contract.json"
DIGEST="$contract_digest" ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["issueContract"]["digest"]=ENV.fetch("DIGEST"); File.binwrite(path,JSON.generate(value))' "$repo/.artifacts/issues/42/state.json"

cp "$repo/.artifacts/issues/42/state.json" "$scratch/state.before-identity-races"
for race in swap primary timestamp; do
  : > "$FAKE_GH_LOG"
  STATE_AFTER_VALIDATE_MODE="$race" assert_fails "state $race after validate-worktree is rejected before gh" run_gate
  [[ ! -s "$FAKE_GH_LOG" ]] || { echo "state $race reached gh" >&2; exit 1; }
  cp "$scratch/state.before-identity-races" "$repo/.artifacts/issues/42/state.json"
done
STATE_AFTER_VALIDATE_MODE=ctime run_gate >/dev/null

: > "$FAKE_GH_LOG"
assert_fails 'caller repository mismatch is rejected before gh' \
  "$issue_worktree/tools/premerge-gate.sh" --repo another/repository --issue 42 --head-sha "$head_sha"
[[ ! -s "$FAKE_GH_LOG" ]] || { echo 'repository mismatch reached gh' >&2; exit 1; }
cp "$repo/.artifacts/issues/42/state.json" "$scratch/state.valid"
ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.binread(path)); value["state"] = "review-requested"; File.binwrite(path, JSON.generate(value))' "$repo/.artifacts/issues/42/state.json"
assert_fails 'non-approved state is rejected before gh' run_gate
[[ ! -s "$FAKE_GH_LOG" ]] || { echo 'non-approved state reached gh' >&2; exit 1; }
cp "$scratch/state.valid" "$repo/.artifacts/issues/42/state.json"
run_gate >/dev/null
[[ "$(cat "$FAKE_GH_LOG")" == "$expected_gh" ]] || { echo 'successful gate gh log is not exact and ordered' >&2; exit 1; }

mutate_json() {
  local code=$1
  ruby -rjson -e "$code" "$repo/.artifacts/issues/42/$head_sha/verify.json"
}

mutate_json 'path = ARGV.fetch(0); value = JSON.parse(File.read(path)); value["headSha"] = "0" * 40; File.write(path, JSON.generate(value))'
assert_fails 'stale Verify SHA is rejected' run_gate
write_verify
HEAD="$head_sha" ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.read(path)); value["headSha"] = "0" * 40; File.write(path, JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/review.json"
assert_fails 'stale Review SHA is rejected' run_gate
write_review
HEAD="$head_sha" ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.binread(path)); value["baseSha"] = "0" * 40; File.binwrite(path, JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/review-packet.json"
assert_fails 'review packet Base mismatch is rejected' run_gate
write_review_packet
ruby -rjson -e '
  packet_path, result_path = ARGV
  packet=JSON.parse(File.binread(packet_path)); packet["schemaVersion"]=1
  packet["diffFile"]=packet.delete("diff").fetch("path"); packet["verifyFile"]=packet.delete("verify").fetch("path"); packet["imageFiles"]=packet.fetch("imageFiles").map { |entry| entry.fetch("path") }
  File.binwrite(packet_path,JSON.generate(packet))
  result=JSON.parse(File.binread(result_path)); result["schemaVersion"]=1; result.delete("reviewPacketDigest"); File.binwrite(result_path,JSON.generate(result))
' "$repo/.artifacts/issues/42/$head_sha/review-packet.json" "$repo/.artifacts/issues/42/$head_sha/review.json"
assert_fails_with 'schema v1 review closure is never merge-ready' 'merge-ready review requires packet schemaVersion 2' run_gate
write_review_packet
write_review
ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.binread(path)); value["reviewerModel"] = "codex"; File.binwrite(path, JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/review-packet.json"
assert_fails 'same-model review packet is rejected' run_gate
write_review_packet
ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["reviewPacketDigest"]="sha256:"+("0"*64); File.binwrite(path,JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/review.json"
assert_fails_with 'review result must bind exact packet bytes' 'reviewPacketDigest does not match exact packet bytes' run_gate
write_review
printf 'self-consistent but wrong diff\n' > "$repo/.artifacts/issues/42/$head_sha/review.diff"
wrong_diff_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/$head_sha/review.diff" | awk '{print $1}')"
DIGEST="$wrong_diff_digest" ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value.fetch("diff")["digest"]=ENV.fetch("DIGEST"); File.binwrite(path,JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/review-packet.json"
write_review
assert_fails_with 'self-consistent wrong review diff is rejected' 'not the deterministic actual Base..Head diff' run_gate
write_review_packet
write_review

image_target="$repo/.artifacts/issues/42/$head_sha/review-image.real"
image_path="$repo/.artifacts/issues/42/$head_sha/review-image.png"
printf 'review image fixture\n' > "$image_target"
image_digest="sha256:$(shasum -a 256 "$image_target" | awk '{print $1}')"
ln -s "$(basename "$image_target")" "$image_path"
PATH_VALUE=".artifacts/issues/42/$head_sha/review-image.png" DIGEST="$image_digest" ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["imageFiles"]=[{"path"=>ENV.fetch("PATH_VALUE"),"digest"=>ENV.fetch("DIGEST")}]; File.binwrite(path,JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/review-packet.json"
write_review
assert_fails_with 'declared review image symlink leaf is rejected' 'not a descriptor-bound regular single-link file' run_gate
rm "$image_path"
ln "$image_target" "$image_path"
assert_fails_with 'declared review image hardlink leaf is rejected' 'not a descriptor-bound regular single-link file' run_gate
rm "$image_path" "$image_target"
write_review_packet
write_review

mkdir "$repo/.artifacts/issues/42/$head_sha/review-images-real"
printf 'component image fixture\n' > "$repo/.artifacts/issues/42/$head_sha/review-images-real/screenshot.png"
component_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/$head_sha/review-images-real/screenshot.png" | awk '{print $1}')"
ln -s review-images-real "$repo/.artifacts/issues/42/$head_sha/review-images"
PATH_VALUE=".artifacts/issues/42/$head_sha/review-images/screenshot.png" DIGEST="$component_digest" ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["imageFiles"]=[{"path"=>ENV.fetch("PATH_VALUE"),"digest"=>ENV.fetch("DIGEST")}]; File.binwrite(path,JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/review-packet.json"
write_review
assert_fails_with 'declared review image symlink component is rejected' 'not a descriptor-bound physical directory' run_gate
rm "$repo/.artifacts/issues/42/$head_sha/review-images"
rm -r "$repo/.artifacts/issues/42/$head_sha/review-images-real"
write_review_packet
write_review

ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.binread(path)); value["unexpected"] = true; File.binwrite(path, JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/review.json"
assert_fails 'review result schema extension is rejected' run_gate
write_review
ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.binread(path)); value["findings"] = [{"severity" => "low", "category" => "correctness", "file" => "README.md", "line" => 1, "title" => "nonblocking", "evidence" => "fixture", "requiredChange" => "clarify"}]; File.binwrite(path, JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/review.json"
assert_fails 'approved review with findings is rejected' run_gate
write_review
future_review_at=$(timestamp 600)
FUTURE="$future_review_at" ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.binread(path)); value["reviewedAt"] = ENV.fetch("FUTURE"); File.binwrite(path, JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/review.json"
assert_fails 'future review timestamp is rejected' run_gate
write_review
write_review changes-requested
assert_fails 'changes-requested review is rejected' run_gate
assert_fails 'changes-requested review is refused by renderer' \
  "$issue_worktree/tools/render-pr-body.sh" --issue 42 --head-sha "$head_sha"
write_review
cp "$issue_body" "$scratch/issue-body.original"
ruby -e 'path = ARGV.fetch(0); text = File.read(path); text.sub!("- AC-2: Every acceptance criterion has one evidence mapping.\n", "- AC-2: Every acceptance criterion has one evidence mapping.\n- AC-3: A live Issue edit invalidates the snapshot.\n"); File.write(path, text)' "$issue_body"
assert_fails 'live Issue contract staleness is rejected' run_gate
cp "$scratch/issue-body.original" "$issue_body"
run_gate >/dev/null
"$issue_worktree/tools/render-pr-body.sh" --issue 42 --head-sha "$head_sha" > "$scratch/pr-body.md"
grep -Fq "Closes #42" "$scratch/pr-body.md"
grep -Fq "Head SHA: \`$head_sha\`" "$scratch/pr-body.md"
grep -Fq 'AC-1: `passed`' "$scratch/pr-body.md"
if grep -Fq 'Pre-merge gate is pending.' "$scratch/pr-body.md"; then
  echo 'approved PR body incorrectly claims the gate is pending' >&2
  exit 1
fi
HEAD="$head_sha" ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.read(path)); value["acceptanceEvidence"].pop; File.write(path, JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/verify.json"
assert_fails 'missing AC evidence is rejected' run_gate
write_verify
HEAD="$head_sha" ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.read(path)); value["acceptanceEvidence"] << value["acceptanceEvidence"].first; File.write(path, JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/verify.json"
assert_fails 'duplicate AC evidence is rejected' run_gate
write_verify
HEAD="$head_sha" ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.read(path)); value["changeClassification"] = "application-code"; value["status"] = "passed"; value["tests"]["status"] = "failed"; File.write(path, JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/verify.json"
assert_fails 'failed matrix case is rejected' run_gate
write_verify
HEAD="$head_sha" ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.read(path)); value["matrixDigest"] = "sha256:" + "0" * 64; File.write(path, JSON.generate(value))' "$repo/.artifacts/issues/42/$head_sha/verify.json"
assert_fails 'changed matrix digest is rejected' run_gate
write_verify
rm "$repo/.artifacts/issues/42/github-preflight.json"
assert_fails 'absent merge preflight is rejected' run_gate
write_preflight
ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.read(path)); value["digest"] = "sha256:" + "0" * 64; File.write(path, JSON.generate(value))' "$repo/.artifacts/issues/42/github-preflight.json"
assert_fails 'digest-mismatched merge preflight is rejected' run_gate
write_preflight
mutate_signed_preflight 'value["account"] = "another-account"'
assert_fails 'wrong GitHub preflight account is rejected' run_gate
write_preflight
mutate_signed_preflight 'value["repository"] = "another/repository"'
assert_fails 'wrong GitHub preflight repository is rejected' run_gate
write_preflight
future_preflight_at=$(timestamp 600)
FUTURE="$future_preflight_at" mutate_signed_preflight 'value["checkedAt"] = ENV.fetch("FUTURE")'
assert_fails 'future GitHub preflight is rejected' run_gate
write_preflight
write_preflight "$contract_at"
assert_fails 'stale merge preflight is rejected' run_gate
write_preflight
run_gate >/dev/null
FAKE_TYPE_LABEL=type:docs run_gate >/dev/null
FAKE_TYPE_LABEL=type:release run_gate >/dev/null
FAKE_TYPE_LABEL=state:approved-for-merge assert_fails 'missing Issue type label is rejected' run_gate
FAKE_SECOND_TYPE=type:regression assert_fails 'ambiguous Issue type labels are rejected' run_gate

enable_supabase_preflight() {
  ruby -e 'path = ARGV.fetch(0); text = File.read(path); anchor = "- Approval required: no\n\n## User approvals"; replacement = "- Approval required: no\n\n- Operation: supabase.inspect_project\n- Service: Supabase\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n## User approvals"; text.sub!(anchor, replacement) or abort "external operations fixture section missing"; File.write(path, text)' "$issue_body"
  canonical_contract > "$repo/.artifacts/issues/42/issue-contract.json"
  contract_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/issue-contract.json" | awk '{print $1}')"
  DIGEST="$contract_digest" ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.binread(path)); value["issueContract"]["digest"] = ENV.fetch("DIGEST"); File.binwrite(path, JSON.generate(value))' "$repo/.artifacts/issues/42/state.json"
  write_verify
  write_review_packet
  write_review
  write_preflight
}

write_supabase_preflight() {
  local account=${1:-YUTO1201} target=${2:-personal-project} environment=${3:-production}
  mkdir -p "$repo/.artifacts/issues/42/provider-preflights"
  ACCOUNT="$account" TARGET="$target" ENVIRONMENT="$environment" CHECKED_AT="$preflight_at" ruby -rjson -rdigest -e '
    def canonical(value); value.is_a?(Hash) ? value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] } : value; end
    path = ARGV.fetch(0)
    value = {"schemaVersion" => 1, "issue" => 42, "provider" => "supabase", "account" => ENV.fetch("ACCOUNT"), "target" => ENV.fetch("TARGET"), "environment" => ENV.fetch("ENVIRONMENT"), "operation" => "supabase.inspect_project", "health" => "healthy", "checkedAt" => ENV.fetch("CHECKED_AT")}
    value["digest"] = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
    File.binwrite(path, JSON.generate(canonical(value)))
  ' "$repo/.artifacts/issues/42/provider-preflights/supabase.json"
}

enable_supabase_preflight
write_supabase_preflight
run_gate >/dev/null

write_supabase_preflight 'Company'
assert_fails 'company provider account is rejected' run_gate
write_supabase_preflight 'yuto1201'
assert_fails 'case-mismatched provider account is rejected' run_gate
write_supabase_preflight YUTO1201 'other-project'
assert_fails 'wrong provider target is rejected' run_gate
write_supabase_preflight YUTO1201 'Personal-project'
assert_fails 'case-mismatched provider target is rejected' run_gate
write_supabase_preflight '   '
assert_fails 'blank provider account is rejected' run_gate
write_supabase_preflight YUTO1201 ' personal-project '
assert_fails 'untrimmed provider target is rejected' run_gate
write_supabase_preflight YUTO1201 personal-project ' production '
assert_fails 'untrimmed provider environment is rejected' run_gate
long_account=$(printf 'a%.0s' {1..257})
write_supabase_preflight "$long_account"
assert_fails 'overlong provider account is rejected' run_gate
write_supabase_preflight YUTO1201 '<project-ref>'
assert_fails 'unsafe provider target characters are rejected' run_gate
write_supabase_preflight YUTO1201 personal-project qa
assert_fails 'unknown provider environment is rejected' run_gate
write_supabase_preflight

mv "$repo/.artifacts/issues/42/provider-preflights" "$repo/.artifacts/issues/42/provider-preflights-real"
ln -s provider-preflights-real "$repo/.artifacts/issues/42/provider-preflights"
assert_fails 'provider preflight symlink component is rejected' run_gate
rm "$repo/.artifacts/issues/42/provider-preflights"
mv "$repo/.artifacts/issues/42/provider-preflights-real" "$repo/.artifacts/issues/42/provider-preflights"
run_gate >/dev/null

artifact_leaves=(
  "$repo/.artifacts/issues/42/state.json"
  "$repo/.artifacts/issues/42/issue-contract.json"
  "$repo/.artifacts/issues/42/$head_sha/verify.json"
  "$repo/.artifacts/issues/42/$head_sha/review-packet.json"
  "$repo/.artifacts/issues/42/$head_sha/review.diff"
  "$repo/.artifacts/issues/42/$head_sha/review.json"
  "$repo/.artifacts/issues/42/$head_sha/review-receipt.json"
  "$repo/.artifacts/issues/42/github-preflight.json"
  "$repo/.artifacts/issues/42/provider-preflights/supabase.json"
)
for artifact in "${artifact_leaves[@]}"; do
  saved="$artifact.saved"
  mv "$artifact" "$saved"
  ln -s "$(basename "$saved")" "$artifact"
  assert_fails "$(basename "$artifact") symlink leaf is rejected" run_gate
  rm "$artifact"
  mv "$saved" "$artifact"

  mv "$artifact" "$saved"
  ln "$saved" "$artifact"
  assert_fails "$(basename "$artifact") hardlink leaf is rejected" run_gate
  rm "$artifact"
  mv "$saved" "$artifact"
done

mv "$repo/.artifacts/issues/42" "$repo/.artifacts/issues/42-real"
ln -s 42-real "$repo/.artifacts/issues/42"
assert_fails 'Issue artifact directory symlink is rejected' run_gate
rm "$repo/.artifacts/issues/42"
mv "$repo/.artifacts/issues/42-real" "$repo/.artifacts/issues/42"

mv "$repo/.artifacts/issues/42/$head_sha" "$repo/.artifacts/issues/42/$head_sha-real"
ln -s "$head_sha-real" "$repo/.artifacts/issues/42/$head_sha"
assert_fails 'Head artifact directory symlink is rejected' run_gate
rm "$repo/.artifacts/issues/42/$head_sha"
mv "$repo/.artifacts/issues/42/$head_sha-real" "$repo/.artifacts/issues/42/$head_sha"

SWAP_TARGET="$repo/.artifacts/issues/42/$head_sha/verify.json" assert_fails 'same-byte atomic swap callback is rejected' run_gate
REWRITE_HELD_TARGET="$repo/.artifacts/issues/42/$head_sha/review.diff" assert_fails 'same-inode same-byte review diff rewrite while held is rejected' run_gate
REWRITE_HELD_TARGET="$repo/.artifacts/issues/42/state.json" assert_fails 'same-inode same-byte state rewrite while held is rejected' run_gate
run_gate >/dev/null

# The final PR refresh occurs inside the Gate process. Replacing any held merge
# input from that refresh boundary must prevent the merge command itself.
final_lease_leaves=(
  "$repo/.artifacts/issues/42/state.json"
  "$repo/.artifacts/issues/42/issue-contract.json"
  "$repo/.artifacts/issues/42/$head_sha/verify.json"
  "$repo/.artifacts/issues/42/$head_sha/review-packet.json"
  "$repo/.artifacts/issues/42/$head_sha/review.diff"
  "$repo/.artifacts/issues/42/$head_sha/review.json"
  "$repo/.artifacts/issues/42/$head_sha/review-receipt.json"
  "$repo/.artifacts/issues/42/github-preflight.json"
  "$repo/.artifacts/issues/42/provider-preflights/supabase.json"
)
for artifact in "${final_lease_leaves[@]}"; do
  cp "$artifact" "$scratch/final-lease.saved"
  : > "$FAKE_GH_LOG"
  : > "$FAKE_MERGE_MUTATIONS"
  FINAL_GATE_SWAP_TARGET="$artifact" assert_fails "$(basename "$artifact") swap after final PR validation" run_gate_merge
  grep -Fq 'pr view 57 --repo yuto1201/iOS-Template' "$FAKE_GH_LOG" || { echo "final lease fixture did not reach PR refresh for $artifact" >&2; exit 1; }
  [[ ! -s "$FAKE_MERGE_MUTATIONS" ]] || { echo "final lease merged after $artifact changed" >&2; exit 1; }
  cp "$scratch/final-lease.saved" "$artifact"
done
: > "$FAKE_MERGE_MUTATIONS"
run_gate_merge >/dev/null
[[ $(cat "$FAKE_MERGE_MUTATIONS") == merged ]] || { echo 'valid final lease did not perform exactly one merge' >&2; exit 1; }

# Exercise the same final-refresh lease with a packet-bound image. The full
# visual-evidence validator has its own canonical packet/result tests; this
# focused case supplies the already-validated visual closure so it can isolate
# the descriptor lifetime between final PR read and merge.
final_image="$repo/.artifacts/issues/42/$head_sha/final-review-image.png"
printf 'final review image fixture\n' > "$final_image"
final_image_digest="sha256:$(shasum -a 256 "$final_image" | awk '{print $1}')"
VERIFY="$repo/.artifacts/issues/42/$head_sha/verify.json" IMAGE_DIGEST="$final_image_digest" ruby -rjson -e '
  path=ENV.fetch("VERIFY"); value=JSON.parse(File.binread(path));
  value["visualEvaluation"]={"status"=>"passed","cases"=>[{"id"=>"lease-image","images"=>[{"path"=>"final-review-image.png","digest"=>ENV.fetch("IMAGE_DIGEST")}]}],"findings"=>[]};
  File.binwrite(path,JSON.generate(value))
'
verify_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/$head_sha/verify.json" | awk '{print $1}')"
PACKET="$repo/.artifacts/issues/42/$head_sha/review-packet.json" VERIFY_DIGEST="$verify_digest" IMAGE_DIGEST="$final_image_digest" ruby -rjson -e '
  path=ENV.fetch("PACKET"); value=JSON.parse(File.binread(path));
  value.fetch("verify")["digest"]=ENV.fetch("VERIFY_DIGEST");
  value["imageFiles"]=[{"path"=>".artifacts/issues/42/#{value.fetch("headSha")}/final-review-image.png","digest"=>ENV.fetch("IMAGE_DIGEST")}];
  File.binwrite(path,JSON.generate(value))
'
write_review
: > "$FAKE_GH_LOG"
: > "$FAKE_MERGE_MUTATIONS"
FAKE_SKIP_SWIFT=1 FINAL_GATE_SWAP_TARGET="$final_image" assert_fails 'packet-bound image swap after final PR validation' run_gate_merge
grep -Fq 'pr view 57 --repo yuto1201/iOS-Template' "$FAKE_GH_LOG" || { echo 'final image lease fixture did not reach PR refresh' >&2; exit 1; }
[[ ! -s "$FAKE_MERGE_MUTATIONS" ]] || { echo 'final lease merged after packet-bound image changed' >&2; exit 1; }

echo 'PASS: gate binds caller identity, live Issue, descriptor snapshots, review, provider, and GitHub preflight evidence'
