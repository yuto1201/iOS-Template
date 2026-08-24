#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-premerge-gate.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

repo="$scratch/repo"
git init -b main "$repo" >/dev/null
git -C "$repo" config user.name 'Gate Fixture'
git -C "$repo" config user.email 'gate-fixture@example.invalid'
printf 'fixture\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -m 'base' >/dev/null
base_sha=$(git -C "$repo" rev-parse HEAD)
printf 'documentation change\n' >> "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -m 'documentation change' >/dev/null
head_sha=$(git -C "$repo" rev-parse HEAD)

mkdir -p "$repo/tools" "$repo/.artifacts/issues/42/$head_sha" "$repo/.artifacts/issues/42"
cp "$repo_root/tools/validate-issue-body.sh" "$repo/tools/"
cp "$repo_root/tools/validate-verify-json.swift" "$repo/tools/"
cp "$repo_root/tools/premerge-gate.sh" "$repo/tools/"
cp "$repo_root/tools/render-pr-body.sh" "$repo/tools/"
cp -R "$repo_root/tools/lib" "$repo/tools/"
cp -R "$repo_root/.agents" "$repo/"
cp -R "$repo_root/specs" "$repo/"

issue_body="$scratch/issue.md"
cat > "$issue_body" <<'EOF'
## Goal

Keep merge safety deterministic.

## In scope

- Verify current evidence before merging.

## Out of scope

- Change application code.

## Acceptance criteria

- AC-1: The verified Head is current.
- AC-2: Every acceptance criterion has one evidence mapping.

## Spec anchors

- [Verification](docs/verification.md#7-pre-merge-conditions)

## Dependencies

- None.

## External operations

- None.

## User approvals

- None.
EOF

canonical_contract() {
  ISSUE_BODY="$issue_body" BASE="$base_sha" ruby -rjson -rdigest -e '
    def canonical(value)
      value.is_a?(Hash) ? value.keys.sort.to_h { |key| [key, canonical(value[key])] } : value.is_a?(Array) ? value.map { |item| canonical(item) } : value
    end
    value = {"schemaVersion" => 1, "issue" => 42, "repository" => "yuto1201/iOS-Template", "goal" => "Keep merge safety deterministic.", "specAnchors" => ["docs/verification.md#7-pre-merge-conditions"], "acceptanceCriteria" => [{"id" => "AC-1", "text" => "The verified Head is current."}, {"id" => "AC-2", "text" => "Every acceptance criterion has one evidence mapping."}], "dependencies" => [], "externalOperations" => [], "fetchedAt" => "2026-08-24T00:00:00Z"}
    print JSON.generate(canonical(value))
  '
}
canonical_contract > "$repo/.artifacts/issues/42/issue-contract.json"
contract_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/issue-contract.json" | awk '{print $1}')"

write_verify() {
  ISSUE_CONTRACT_DIGEST="$contract_digest" HEAD="$head_sha" BASE="$base_sha" ruby -rjson -e '
    value = {"schemaVersion" => 1, "status" => "not-applicable", "changeClassification" => "documentation-only", "reason" => "Only allowlisted Markdown documentation changed", "issue" => 42, "baseSha" => ENV.fetch("BASE"), "headSha" => ENV.fetch("HEAD"), "issueContract" => {"path" => ".artifacts/issues/42/issue-contract.json", "digest" => ENV.fetch("ISSUE_CONTRACT_DIGEST")}, "matrixFile" => nil, "matrixDigest" => nil, "executionRoute" => "none", "xcode" => nil, "build" => {"status" => "not-applicable", "scheme" => nil, "warningsAdded" => nil, "project" => nil, "sourceTree" => nil}, "tests" => {"status" => "not-applicable", "passed" => nil, "failed" => nil, "skipped" => nil}, "cases" => [], "visualEvaluation" => {"status" => "not-applicable", "findings" => []}, "acceptanceEvidence" => [{"id" => "AC-1", "status" => "passed", "evidence" => ["documents:README consistency"]}, {"id" => "AC-2", "status" => "passed", "evidence" => ["links:swift tools/check-markdown-links.swift"]}], "completedAt" => "2026-08-24T00:01:00Z"}
    puts JSON.generate(value)
  ' > "$repo/.artifacts/issues/42/$head_sha/verify.json"
}

write_review() {
  verdict=${1:-approved}
  VERDICT="$verdict" ISSUE_CONTRACT_DIGEST="$contract_digest" HEAD="$head_sha" BASE="$base_sha" ruby -rjson -e '
    findings = ENV.fetch("VERDICT") == "approved" ? [] : [{"severity" => "high", "category" => "correctness", "file" => "README.md", "line" => 1, "title" => "blocking", "evidence" => "fixture", "requiredChange" => "fix"}]
    assessments = ["AC-1", "AC-2"].map { |id| {"id" => id, "status" => ENV.fetch("VERDICT") == "approved" ? "supported" : "unsupported", "evidence" => ["verify.json#acceptanceEvidence"]} }
    puts JSON.generate({"schemaVersion" => 1, "issue" => 42, "reviewerModel" => "claude", "baseSha" => ENV.fetch("BASE"), "headSha" => ENV.fetch("HEAD"), "verifySha" => ENV.fetch("HEAD"), "issueContractDigest" => ENV.fetch("ISSUE_CONTRACT_DIGEST"), "verdict" => ENV.fetch("VERDICT"), "findings" => findings, "acceptanceAssessment" => assessments, "reviewedAt" => "2026-08-24T00:02:00Z"})
  ' > "$repo/.artifacts/issues/42/$head_sha/review.json"
}

write_preflight() {
  local checked_at=${1:-2026-08-24T00:03:00Z}
  HEAD="$head_sha" CHECKED_AT="$checked_at" ruby -rjson -rdigest -e '
    def canonical(v); v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, canonical(v[k])] } : v; end
    value = {"account" => "yuto1201", "repository" => "yuto1201/iOS-Template", "defaultBranch" => "main", "url" => "https://github.com/yuto1201/iOS-Template", "intendedOperation" => "github.merge_pr", "issue" => 42, "headSha" => ENV.fetch("HEAD"), "checkedAt" => ENV.fetch("CHECKED_AT")}
    value["digest"] = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
    puts JSON.generate(canonical(value))
  ' > "$repo/.artifacts/issues/42/github-preflight.json"
}

fake_bin="$scratch/bin"
mkdir "$fake_bin"
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
if [[ "$1 $2" == 'issue view' ]]; then
  ruby -rjson -e 'puts JSON.generate({"body" => File.read(ENV.fetch("FAKE_ISSUE_BODY"))})'
  exit 0
fi
echo "unexpected gh command: $*" >&2
exit 2
EOF
chmod +x "$fake_bin/gh"
export PATH="$fake_bin:$PATH" FAKE_GH_LOG="$scratch/gh.log" FAKE_ISSUE_BODY="$issue_body"

issue_worktree="$repo/.worktrees/42-gate-evidence"
mkdir -p "$repo/.worktrees"
git -C "$repo" worktree add -b codex/42-gate-evidence "$issue_worktree" "$head_sha" >/dev/null
ln -s ../../.artifacts "$issue_worktree/.artifacts"
cp -R "$repo/tools" "$issue_worktree/"
cp -R "$repo/.agents" "$issue_worktree/"
HEAD="$head_sha" BASE="$base_sha" DIGEST="$contract_digest" ruby -rjson -e 'puts JSON.generate({"schemaVersion" => 1, "issue" => 42, "repository" => "yuto1201/iOS-Template", "branch" => "codex/42-gate-evidence", "worktree" => ".worktrees/42-gate-evidence", "baseSha" => ENV.fetch("BASE"), "primaryImplementer" => "codex", "issueContract" => {"path" => ".artifacts/issues/42/issue-contract.json", "digest" => ENV.fetch("DIGEST")}, "state" => "approved-for-merge", "previousState" => "review-requested", "resumeState" => nil, "executor" => "codex", "headSha" => ENV.fetch("HEAD"), "pullRequest" => 57, "from" => "review-requested", "to" => "approved-for-merge", "transitionedAt" => "2026-08-24T00:02:30Z"})' > "$repo/.artifacts/issues/42/state.json"

assert_fails() {
  local label=$1
  shift
  if "$@" >"$scratch/output" 2>&1; then
    echo "expected failure: $label" >&2
    exit 1
  fi
}

run_gate() {
  (cd "$issue_worktree" && "$issue_worktree/tools/premerge-gate.sh" --issue 42 --head-sha "$head_sha")
}

write_verify
write_review
write_preflight

# RED was observed before premerge-gate.sh existed. Matching evidence now opens
# the GREEN cycle; later assertions deliberately mutate exactly one invariant.
run_gate > "$scratch/gate.json"
jq -e --arg head "$head_sha" '.status == "passed" and .headSha == $head' "$scratch/gate.json" >/dev/null

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
write_review changes-requested
assert_fails 'changes-requested review is rejected' run_gate
"$issue_worktree/tools/render-pr-body.sh" --issue 42 --head-sha "$head_sha" > "$scratch/failed-pr-body.md"
grep -Fq 'Verification or opposite-model review is not merge-ready.' "$scratch/failed-pr-body.md"
if grep -Fq -- '- None.' "$scratch/failed-pr-body.md"; then
  echo 'rendered PR body overclaimed Remaining work' >&2
  exit 1
fi
write_review
cp "$issue_body" "$scratch/issue-body.original"
ruby -e 'path = ARGV.fetch(0); text = File.read(path); text.sub!("- AC-2: Every acceptance criterion has one evidence mapping.\n", "- AC-2: Every acceptance criterion has one evidence mapping.\n- AC-3: A live Issue edit invalidates the snapshot.\n"); File.write(path, text)' "$issue_body"
assert_fails 'live Issue contract staleness is rejected' run_gate
cp "$scratch/issue-body.original" "$issue_body"
run_gate >/dev/null
"$issue_worktree/tools/render-pr-body.sh" --issue 42 --head-sha "$head_sha" > "$scratch/pr-body.md"
grep -Fq "Closes #42." "$scratch/pr-body.md"
grep -Fq "Head SHA: \`$head_sha\`" "$scratch/pr-body.md"
grep -Fq 'AC-1: passed' "$scratch/pr-body.md"
grep -Fq 'Pre-merge gate is pending.' "$scratch/pr-body.md"
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
write_preflight 2026-08-24T00:00:00Z
assert_fails 'stale merge preflight is rejected' run_gate
write_preflight
run_gate >/dev/null

enable_supabase_preflight() {
  ruby -e 'path = ARGV.fetch(0); text = File.read(path); text.sub!("## External operations\n\n- None.", "## External operations\n\n- supabase.inspect_project") or abort "external operations fixture section missing"; File.write(path, text)' "$issue_body"
  ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.binread(path)); value["externalOperations"] = ["supabase.inspect_project"]; File.binwrite(path, JSON.generate(value))' "$repo/.artifacts/issues/42/issue-contract.json"
  contract_digest="sha256:$(shasum -a 256 "$repo/.artifacts/issues/42/issue-contract.json" | awk '{print $1}')"
  DIGEST="$contract_digest" ruby -rjson -e 'path = ARGV.fetch(0); value = JSON.parse(File.binread(path)); value["issueContract"]["digest"] = ENV.fetch("DIGEST"); File.binwrite(path, JSON.generate(value))' "$repo/.artifacts/issues/42/state.json"
  write_verify
  write_review
  write_preflight
}

write_supabase_preflight() {
  local account=${1:-personal-account} target=${2:-project-ref} environment=${3:-production}
  mkdir -p "$repo/.artifacts/issues/42/provider-preflights"
  ACCOUNT="$account" TARGET="$target" ENVIRONMENT="$environment" ruby -rjson -rdigest -e '
    def canonical(value); value.is_a?(Hash) ? value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] } : value; end
    path = ARGV.fetch(0)
    value = {"schemaVersion" => 1, "issue" => 42, "provider" => "supabase", "account" => ENV.fetch("ACCOUNT"), "target" => ENV.fetch("TARGET"), "environment" => ENV.fetch("ENVIRONMENT"), "operation" => "supabase.inspect_project", "health" => "healthy", "checkedAt" => "2026-08-24T00:03:00Z"}
    value["digest"] = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
    File.binwrite(path, JSON.generate(canonical(value)))
  ' "$repo/.artifacts/issues/42/provider-preflights/supabase.json"
}

enable_supabase_preflight
write_supabase_preflight
run_gate >/dev/null

write_supabase_preflight '   '
assert_fails 'blank provider account is rejected' run_gate
write_supabase_preflight personal-account ' project-ref '
assert_fails 'untrimmed provider target is rejected' run_gate
write_supabase_preflight personal-account project-ref ' production '
assert_fails 'untrimmed provider environment is rejected' run_gate
long_account=$(printf 'a%.0s' {1..257})
write_supabase_preflight "$long_account"
assert_fails 'overlong provider account is rejected' run_gate
write_supabase_preflight personal-account '<project-ref>'
assert_fails 'unsafe provider target characters are rejected' run_gate
write_supabase_preflight personal-account project-ref qa
assert_fails 'unknown provider environment is rejected' run_gate
write_supabase_preflight

mv "$repo/.artifacts/issues/42/provider-preflights" "$repo/.artifacts/issues/42/provider-preflights-real"
ln -s provider-preflights-real "$repo/.artifacts/issues/42/provider-preflights"
assert_fails 'provider preflight symlink component is rejected' run_gate
rm "$repo/.artifacts/issues/42/provider-preflights"
mv "$repo/.artifacts/issues/42/provider-preflights-real" "$repo/.artifacts/issues/42/provider-preflights"
run_gate >/dev/null

echo 'PASS: gate covers canonical evidence, strict provider fields, provider containment, and documentation-only cases'
