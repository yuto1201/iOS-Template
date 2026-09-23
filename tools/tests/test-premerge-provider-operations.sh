#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git jq ruby swift /usr/bin/swiftc

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
[[ $# == 0 || ( $# == 1 && "$1" == scoped ) ]] || exit 64
scope="${1:-full}"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-premerge-gate.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

repo="$scratch/repo"
git init -b main "$repo" >/dev/null
git -C "$repo" config user.name 'Gate Fixture'
git -C "$repo" config user.email 'gate-fixture@example.invalid'
mkdir -p "$repo/tools" "$repo/.artifacts/issues/42" "$repo/Config"
cp "$repo_root/tools/validate-issue-body.sh" "$repo/tools/"
cp "$repo_root/tools/validate-verify-json.swift" "$repo/tools/"
cp "$repo_root/tools/validate-review-result.sh" "$repo/tools/"
cp "$repo_root/tools/premerge-gate.sh" "$repo/tools/"
cp "$repo_root/tools/cross-model-review.sh" "$repo/tools/"
cp "$repo_root/tools/request-grok-review.sh" "$repo/tools/"
cp "$repo_root/tools/prepare-review-packet.sh" "$repo/tools/"
cp "$repo_root/tools/run-repository-tests.sh" "$repo/tools/"
cp "$repo_root/tools/record-release-disposition.sh" "$repo/tools/"
mkdir -p "$repo/tools/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tools/tests/test-gate-probe.sh"
cp "$repo_root/tools/render-pr-body.sh" "$repo/tools/"
cp -R "$repo_root/tools/lib" "$repo/tools/"
cp -R "$repo_root/.agents" "$repo/"
cp -R "$repo_root/specs" "$repo/"
cp "$repo_root/Config/ownership.yml" "$repo/Config/"
ruby -e 'path=ARGV.fetch(0); text=File.binread(path); text.sub!("projectRef: null","projectRef: personal-project") or abort; text.sub!("appStore:\n  teamId: null\n  bundleId: null","appStore:\n  teamId: PERSONALTEAM\n  bundleId: com.yuto1201.personal") or abort; File.binwrite(path,text)' "$repo/Config/ownership.yml"
mkdir -p "$repo/Config/releases/premerge-v1/phase-records"
PHASE_RECORD="$repo/Config/releases/premerge-v1/phase-records/phase6.json" ruby -I "$repo/tools/lib" -rworkflow-release-phase -e '
  bytes=IOSTemplate::ReleasePhase.create(release_identifier:"premerge-v1",revision:1,scope:["workflow"],goal:"Validate release workflow gates.",actor:"yuto1201",reason:"Start the fixture release.",recorded_at:"2026-09-15T08:00:00Z")
  (1..5).each do |phase|
    user=[1,3,4,5].include?(phase)
    event={"event"=>"phase-completed","revision"=>1,"phase"=>phase,"scope"=>["workflow"],"authority"=>user ? "user" : "delegated","actor"=>user ? "yuto1201" : "codex","approvalReference"=>user ? "issue-42-phase-#{phase}" : "D-038","reason"=>"Phase #{phase} fixture exit.","evidence"=>["fixture:phase-#{phase}"],"knownDefects"=>[],"omittedTests"=>[],"unverified"=>[],"carryovers"=>[],"recordedAt"=>format("2026-09-15T08:%02d:00Z",phase)}
    bytes=IOSTemplate::ReleasePhase.append(bytes,event)
  end
  File.binwrite(ENV.fetch("PHASE_RECORD"),bytes)
'
cat > "$repo/Config/repository-tests.json" <<'JSON'
{"schemaVersion":1,"headAllPaths":[],"headAllPrefixes":[],"domainRules":[{"domain":"gate","paths":["README.md"],"prefixes":[]}],"tests":[{"path":"tools/tests/test-gate-probe.sh","domains":["gate"]}]}
JSON
printf '.artifacts\n' > "$repo/.gitignore"
printf 'fixture\n' > "$repo/README.md"
git -C "$repo" add .gitignore README.md Config tools .agents specs
git -C "$repo" commit -m 'base' >/dev/null
base_sha=$(git -C "$repo" rev-parse HEAD)
printf 'documentation change\n' >> "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -m 'documentation change' >/dev/null
head_sha=$(git -C "$repo" rev-parse HEAD)
phase6_record_digest="sha256:$(shasum -a 256 "$repo/Config/releases/premerge-v1/phase-records/phase6.json" | awk '{print $1}')"

mkdir -p "$repo/.artifacts/issues/42/$head_sha"

timestamp() { ruby -rtime -e 'puts (Time.now.utc + Integer(ARGV.fetch(0))).iso8601' -- "$1"; }
contract_at=$(timestamp -240)
verify_at=$(timestamp -180)
review_at=$(timestamp -120)
transition_at=$(timestamp -60)
preflight_at=$(timestamp -30)
reviewer_model=claude

issue_body="$scratch/issue.md"
cat > "$issue_body" <<'EOF'
## Goal

マージ安全性を決定的に保つ。

## In scope

- Verify current evidence before merging.

## Out of scope

- Change application code.

## Acceptance criteria

- AC-1: UI-direction route: not-applicable; Scope: premerge safety fixture; Reason: this fixture validates workflow gating without changing application UI; the verified Head is current; 日本語を含むpacketも同一bytesとして保持する。
- AC-2: Every acceptance criterion has one evidence mapping.

## Spec anchors

- [Acceptance](specs/README.md#spec-index)

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

- Operation: github.merge_pr
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

## User approvals

- None.
EOF

canonical_contract() {
  ruby "$repo/tools/lib/issue-contract.rb" --allow-legacy-delivery-stage --body "$issue_body" --type feature --format contract \
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
  VERDICT="$verdict" REVIEWER="$reviewer_model" REVIEW_PACKET_DIGEST="$packet_digest" ISSUE_CONTRACT_DIGEST="$contract_digest" HEAD="$head_sha" BASE="$base_sha" REVIEWED_AT="$review_at" CONTRACT="$repo/.artifacts/issues/42/issue-contract.json" ruby -rjson -e '
    findings = ENV.fetch("VERDICT") == "approved" ? [] : [{"severity" => "high", "category" => "correctness", "file" => "README.md", "line" => 1, "title" => "blocking", "evidence" => "fixture", "requiredChange" => "fix"}]
    ids=JSON.parse(File.binread(ENV.fetch("CONTRACT"))).fetch("acceptanceCriteria").map{|entry|entry.fetch("id")}
    assessments = ids.map { |id| {"id" => id, "status" => ENV.fetch("VERDICT") == "approved" ? "supported" : "unsupported", "evidence" => ["verify.json#acceptanceEvidence"]} }
    puts JSON.generate({"schemaVersion" => 2, "issue" => 42, "reviewerModel" => ENV.fetch("REVIEWER"), "baseSha" => ENV.fetch("BASE"), "headSha" => ENV.fetch("HEAD"), "verifySha" => ENV.fetch("HEAD"), "issueContractDigest" => ENV.fetch("ISSUE_CONTRACT_DIGEST"), "reviewPacketDigest" => ENV.fetch("REVIEW_PACKET_DIGEST"), "verdict" => ENV.fetch("VERDICT"), "findings" => findings, "acceptanceAssessment" => assessments, "reviewedAt" => ENV.fetch("REVIEWED_AT")})
  ' > "$repo/.artifacts/issues/42/$head_sha/review.json"
  write_receipt
}

write_receipt() {
  local packet="$repo/.artifacts/issues/42/$head_sha/review-packet.json"
  local review="$repo/.artifacts/issues/42/$head_sha/review.json"
  RECEIPT="$repo/.artifacts/issues/42/$head_sha/review-receipt.json" REPO="$repo" ISSUE=42 HEAD="$head_sha" PACKET="$packet" REVIEW="$review" STARTED_AT="$review_at" COMPLETED_AT="$review_at" ruby -I "$repo/tools/lib" -rjson -rreview-receipt -e '
    packet_bytes = File.binread(ENV.fetch("PACKET"))
    review_bytes = File.binread(ENV.fetch("REVIEW"))
    value = IOSTemplate::ReviewReceipt.build(repo: ENV.fetch("REPO"), primary: "codex", issue: Integer(ENV.fetch("ISSUE")), head_sha: ENV.fetch("HEAD"), packet_bytes: packet_bytes, validated_result_bytes: review_bytes, published_review_bytes: review_bytes, started_at: ENV.fetch("STARTED_AT"), completed_at: ENV.fetch("COMPLETED_AT"))
    File.binwrite(ENV.fetch("RECEIPT"),JSON.generate(value))
  '
}

write_review_packet() {
  rm -f "$repo/.artifacts/issues/42/$head_sha/review-packet.json" "$repo/.artifacts/issues/42/$head_sha/review.diff"
  (cd "$issue_worktree" && "$issue_worktree/tools/prepare-review-packet.sh" --primary codex --issue 42 --base-sha "$base_sha" --head-sha "$head_sha") >/dev/null
}

publish_review_through_entrypoints() {
  local canonical_review="$repo/.artifacts/issues/42/$head_sha/review.json"
  local canonical_receipt="$repo/.artifacts/issues/42/$head_sha/review-receipt.json"
  local physical_scratch
  physical_scratch=$(cd "$scratch" && pwd -P)
  local physical_repo physical_worktree
  physical_repo=$(cd "$repo" && pwd -P)
  physical_worktree=$(cd "$issue_worktree" && pwd -P)
  local provider_result="$physical_scratch/review-provider-result.json"
  local validated_result="$physical_scratch/review-validated-result.json"
  write_review
  ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value["acceptanceAssessment"].each_with_index{|entry,index|entry["evidence"]=["repository-tests.json#acceptanceEvidence/#{index}"]}; File.binwrite(path,JSON.generate(value))' "$canonical_review"
  cp "$canonical_review" "$provider_result"
  rm "$canonical_review" "$canonical_receipt"
  (cd "$issue_worktree" && tools/validate-review-result.sh --primary codex \
    --packet ".artifacts/issues/42/$head_sha/review-packet.json" --result "$provider_result") > "$validated_result"
  ruby "$physical_worktree/tools/lib/publish-review-result.rb" "$physical_worktree" 42 "$head_sha" \
    "$validated_result" "$physical_repo/.artifacts/issues/42/$head_sha/review-packet.json" codex "$review_at" "$review_at" >/dev/null
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
# Compile the exact validator once for this fixture. Every invocation still
# validates fresh evidence; a changed source falls back to the real interpreter.
cached_validator_source="$scratch/validate-verify-json.swift"
cached_validator="$scratch/validate-verify-json"
cp "$repo_root/tools/validate-verify-json.swift" "$cached_validator_source"
/usr/bin/swiftc "$cached_validator_source" -o "$cached_validator"
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
  if [[ -n "${CREATE_ABSENT_TARGET:-}" ]]; then
    printf '%s\n' '{"appeared":true}' > "$CREATE_ABSENT_TARGET"
  fi
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
  HEAD="${FAKE_HEAD:?}" ruby -rjson -e 'puts JSON.generate({"number"=>57,"state"=>"OPEN","baseRefName"=>"main","headRefName"=>"codex/42-gate-evidence","headRefOid"=>ENV.fetch("HEAD"),"headRepository"=>{"id"=>"R_fixture","name"=>"iOS-Template","nameWithOwner"=>"yuto1201/iOS-Template"},"headRepositoryOwner"=>{"id"=>"U_fixture","name"=>"Fixture","login"=>"yuto1201"},"isCrossRepository"=>false,"closingIssuesReferences"=>[{"number"=>42,"url"=>"https://github.com/yuto1201/iOS-Template/issues/42","repository"=>{"id"=>"R_fixture","name"=>"iOS-Template","owner"=>{"id"=>"U_fixture","login"=>"yuto1201"}}}],"mergeCommit"=>nil,"url"=>"https://github.com/yuto1201/iOS-Template/pull/57"})'
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
if [[ -f "${1-}" ]] && /usr/bin/cmp -s "$1" "${GATE_TEST_VALIDATOR_SOURCE:?}"; then
  shift
  exec "${GATE_TEST_VALIDATOR_BINARY:?}" "$@"
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
export GATE_TEST_VALIDATOR_SOURCE="$cached_validator_source" GATE_TEST_VALIDATOR_BINARY="$cached_validator"

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

run_result_validation() {
  (cd "$issue_worktree" && tools/validate-review-result.sh --primary codex \
    --packet ".artifacts/issues/42/$head_sha/review-packet.json" \
    --result ".artifacts/issues/42/$head_sha/review.json")
}

run_renderer() {
  (cd "$issue_worktree" && tools/render-pr-body.sh --issue 42 --head-sha "$head_sha")
}

write_verify
write_review_packet
write_review
write_preflight

# Keep the general gate fixture local to this dedicated test. Every operation
# below is represented by its own signed, descriptor-bound preflight leaf.
refresh_provider_contract() {
  canonical_contract > "$repo/.artifacts/issues/42/issue-contract.json"
  contract_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/issue-contract.json" | awk '{print $1}')"
  DIGEST="$contract_digest" ruby -rjson -e 'path=ARGV.fetch(0); value=JSON.parse(File.binread(path)); value.fetch("issueContract")["digest"]=ENV.fetch("DIGEST"); File.binwrite(path,JSON.generate(value))' "$repo/.artifacts/issues/42/state.json"
  write_verify
  write_review_packet
  write_review
  write_preflight
}

write_appstore_preflight() {
  local operation=$1 recorded_operation=${2:-$1} account=${3:-PERSONALTEAM} target=${4:-com.yuto1201.personal}
  mkdir -p "$repo/.artifacts/issues/42/provider-preflights"
  OPERATION="$recorded_operation" ACCOUNT="$account" TARGET="$target" CHECKED_AT="$preflight_at" ruby -rjson -rdigest -e '
    def canonical(v); v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, canonical(v[k])] } : v; end
    value={"schemaVersion"=>2,"issue"=>42,"executor"=>"codex","provider"=>"app-store","account"=>ENV.fetch("ACCOUNT"),"target"=>ENV.fetch("TARGET"),"environment"=>"production","operation"=>ENV.fetch("OPERATION"),"health"=>"healthy","checkedAt"=>ENV.fetch("CHECKED_AT")}
    value["digest"]="sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
    File.binwrite(ARGV.fetch(0),JSON.generate(canonical(value)))
  ' "$repo/.artifacts/issues/42/provider-preflights/app-store-${operation#appstore.}.json"
}

cp "$issue_body" "$scratch/before-appstore.md"
ruby -e 'path=ARGV.fetch(0); text=File.binread(path); block="- Operation: appstore.inspect_app\n- Service: App Store Connect\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n- Operation: appstore.update_metadata\n- Service: App Store Connect\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n"; text.sub!("## User approvals",block+"## User approvals") or abort; File.binwrite(path,text)' "$issue_body"
refresh_provider_contract
write_appstore_preflight appstore.inspect_app
write_appstore_preflight appstore.update_metadata
FAKE_SKIP_SWIFT=1 run_gate > "$scratch/appstore-gate.json"
jq -e '.status == "passed"' "$scratch/appstore-gate.json" >/dev/null

mv "$repo/.artifacts/issues/42/provider-preflights/app-store-update_metadata.json" "$scratch/app-store-update_metadata.json"
FAKE_SKIP_SWIFT=1 assert_fails_with 'one of two App Store preflights is missing' 'appstore.update_metadata provider preflight' run_gate
mv "$scratch/app-store-update_metadata.json" "$repo/.artifacts/issues/42/provider-preflights/app-store-update_metadata.json"
write_appstore_preflight appstore.update_metadata appstore.inspect_app
FAKE_SKIP_SWIFT=1 assert_fails_with 'App Store preflight operation differs from its filename' 'provider operation does not match the Issue contract' run_gate
write_appstore_preflight appstore.update_metadata appstore.update_metadata OTHERTEAM
FAKE_SKIP_SWIFT=1 assert_fails_with 'App Store account differs from configured ownership' 'provider account differs from Config ownership' run_gate
write_appstore_preflight appstore.update_metadata appstore.update_metadata PERSONALTEAM com.yuto1201.other
FAKE_SKIP_SWIFT=1 assert_fails_with 'App Store target differs from configured ownership' 'provider target differs from Config ownership' run_gate
write_appstore_preflight appstore.update_metadata
FAKE_SKIP_SWIFT=1 run_gate >/dev/null

cp "$scratch/before-appstore.md" "$issue_body"
ruby -e 'path=ARGV.fetch(0); text=File.binread(path); block="- Operation: supabase.inspect_project\n- Service: Supabase\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n- Operation: supabase.apply_migrations\n- Service: Supabase\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n"; text.sub!("## User approvals",block+"## User approvals") or abort; File.binwrite(path,text)' "$issue_body"
refresh_provider_contract
CHECKED_AT="$preflight_at" ruby -rjson -rdigest -e '
  def canonical(v); v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, canonical(v[k])] } : v; end
  value={"schemaVersion"=>2,"issue"=>42,"executor"=>"codex","provider"=>"supabase","account"=>"kmjpkzaqlewqnypyqwkg","target"=>"personal-project","environment"=>"production","operation"=>"supabase.inspect_project","health"=>"healthy","checkedAt"=>ENV.fetch("CHECKED_AT")}
  value["digest"]="sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
  File.binwrite(ARGV.fetch(0),JSON.generate(canonical(value)))
' "$repo/.artifacts/issues/42/provider-preflights/supabase.json"
FAKE_SKIP_SWIFT=1 assert_fails_with 'non-App Store provider still rejects multiple operations' 'multiple operations for provider supabase' run_gate

echo 'PASS: per-operation App Store evidence is required while other providers retain one-operation gating'
