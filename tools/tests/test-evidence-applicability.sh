#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git jq ruby

source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-applicability.XXXXXX")
workspace=$(cd "$workspace" && pwd -P)
trap 'rm -rf -- "$workspace"' EXIT
repo="$workspace/repo"
mkdir -p "$repo/.artifacts/issues/501" "$repo/.artifacts/issues/502"
repo=$(cd "$repo" && pwd -P)

REPO="$repo" ROOT="$source_root" ruby -I "$source_root/tools/lib" -rjson -rdigest -rtime -rfileutils -rshellwords -revidence-applicability -rworkflow-release-phase <<'RUBY'
repo = ENV.fetch("REPO")
def run!(*command)
  abort "command failed: #{command.join(' ')}" unless system(*command, out: File::NULL)
end
run!("git", "-C", repo, "init", "-q")
run!("git", "-C", repo, "config", "user.name", "Applicability Fixture")
run!("git", "-C", repo, "config", "user.email", "applicability@example.invalid")
FileUtils.mkdir_p(File.join(repo, "Config/releases/sample-v1/phase-records"))
File.binwrite(File.join(repo, "Config/releases/sample-v1/phase-records/phase5.json"), "phase5\n")
File.binwrite(File.join(repo, "Config/releases/sample-v1/phase-records/phase6.json"), "phase6\n")
File.binwrite(File.join(repo, "README.md"), "base\n")
run!("git", "-C", repo, "add", "Config", "README.md")
run!("git", "-C", repo, "commit", "-qm", "base")
base = `git -C #{repo.shellescape} rev-parse HEAD`.strip
File.binwrite(File.join(repo, "README.md"), "candidate\n")
run!("git", "-C", repo, "add", "README.md")
run!("git", "-C", repo, "commit", "-qm", "candidate")
head = `git -C #{repo.shellescape} rev-parse HEAD`.strip

phase_binding = lambda do |phase, path, byte, scope|
  value = {
    "releaseIdentifier" => "sample-v1", "revision" => 1, "phase" => phase,
    "scope" => scope, "workKind" => "implementation", "route" => "standard",
    "recordPath" => path, "recordDigest" => "sha256:#{byte * 64}",
    "reason" => "Bind Phase #{phase}."
  }
  "Release-phase binding: #{JSON.generate(IOSTemplate::ReleasePhase.canonical(value))}"
end
contract = lambda do |issue, phase, path, byte, scope|
  {
    "schemaVersion" => 1, "issue" => issue, "repository" => "yuto1201/iOS-Template",
    "goal" => "Fixture", "specAnchors" => ["specs/acceptance.md#quality"],
    "acceptanceCriteria" => [
      {"id" => "AC-1", "text" => "UI-direction route: not-applicable; Scope: workflow fixture; Reason: no application UI change."},
      {"id" => "AC-2", "text" => phase_binding.call(phase, path, byte, scope)}
    ],
    "dependencies" => [], "externalOperations" => [],
    "externalOperationDetailsDigest" => "sha256:#{"0" * 64}", "fetchedAt" => (Time.now.utc - 120).iso8601
  }
end
source_contract = JSON.generate(IOSTemplate::EvidenceApplicability.canonical(
  contract.call(501, 5, "Config/releases/sample-v1/phase-records/phase5.json", "5", %w[core settings])
))
target_contract = JSON.generate(IOSTemplate::EvidenceApplicability.canonical(
  contract.call(502, 6, "Config/releases/sample-v1/phase-records/phase6.json", "6", ["core"])
))
source_contract_path = File.join(repo, ".artifacts/issues/501/issue-contract.json")
target_contract_path = File.join(repo, ".artifacts/issues/502/issue-contract.json")
File.binwrite(source_contract_path, source_contract)
File.binwrite(target_contract_path, target_contract)
source_head_root = File.join(repo, ".artifacts/issues/501", head)
target_head_root = File.join(repo, ".artifacts/issues/502", head)
FileUtils.mkdir_p(source_head_root)
FileUtils.mkdir_p(target_head_root)
completed = (Time.now.utc - 60).iso8601
source_verify = {
  "schemaVersion" => 1, "status" => "passed", "issue" => 501,
  "baseSha" => base, "headSha" => head,
  "issueContract" => {
    "path" => ".artifacts/issues/501/issue-contract.json",
    "digest" => IOSTemplate::EvidenceApplicability.digest(source_contract)
  },
  "completedAt" => completed
}
File.binwrite(File.join(source_head_root, "verify.json"), JSON.generate(source_verify))
context = {
  "artifactDigest" => "sha256:#{"a" * 64}", "configurationDigest" => "sha256:#{"b" * 64}",
  "sdkDigest" => "sha256:#{"c" * 64}", "signingDigest" => "sha256:#{"d" * 64}", "scope" => ["core"]
}
input = {
  "schemaVersion" => 1,
  "sourceVerify" => ".artifacts/issues/501/#{head}/verify.json",
  "sourceContext" => context, "targetContext" => context,
  "impact" => [], "reason" => "The exact Phase 5 candidate and conditions are unchanged.",
  "evaluatedAt" => Time.now.utc.iso8601
}
File.binwrite(File.join(repo, "input.json"), JSON.generate(input))
File.binwrite(File.join(repo, "facts.json"), JSON.generate("base" => base, "head" => head))
RUBY

base=$(jq -er '.base' "$repo/facts.json")
head=$(jq -er '.head' "$repo/facts.json")
published=$(/usr/bin/ruby "$source_root/tools/lib/evidence-applicability-cli.rb" \
  "$repo" 502 "$base" "$head" "$repo/input.json")
[[ $(jq -er '.decision' <<<"$published") == reuse ]] || { echo 'same candidate was not reused' >&2; exit 1; }
record="$repo/.artifacts/issues/502/$head/evidence-applicability.json"
[[ -f "$record" && ! -L "$record" ]] || { echo 'canonical applicability record was not published' >&2; exit 1; }
if /usr/bin/ruby "$source_root/tools/lib/evidence-applicability-cli.rb" \
  "$repo" 502 "$base" "$head" "$repo/input.json" >"$workspace/repeat.out" 2>&1; then
  echo 'same-Head applicability record was overwritten' >&2
  exit 1
fi

REPO="$repo" ROOT="$source_root" BASE="$base" SOURCE_HEAD="$head" RECORD="$record" ruby -I "$source_root/tools/lib" -rjson -rdigest -rtime -rfileutils -rshellwords -revidence-applicability -rprepare-review-packet -rissue-contract <<'RUBY'
repo = ENV.fetch("REPO")
source_head = ENV.fetch("SOURCE_HEAD")
source_contract = File.binread(File.join(repo, ".artifacts/issues/501/issue-contract.json"))
target_contract = File.binread(File.join(repo, ".artifacts/issues/502/issue-contract.json"))
source_path = ".artifacts/issues/501/#{source_head}/verify.json"
source_verify = File.binread(File.join(repo, source_path))
record_bytes = File.binread(ENV.fetch("RECORD"))
record = IOSTemplate::EvidenceApplicability.validate!(
  record_bytes: record_bytes, repo: repo, target_contract_bytes: target_contract,
  source_verify_bytes: source_verify, source_contract_bytes: source_contract
)
abort "reuse record validation failed" unless record.dig("decision", "action") == "reuse"

# The strict review packet embeds the same immutable decision and its source
# references; approval time is ordered after both the current Issue evidence
# and the applicability evaluation.
FileUtils.mkdir_p(File.join(repo, "tools/lib"))
FileUtils.cp(File.join(ENV.fetch("ROOT"), "tools/lib/review-artifacts.rb"), File.join(repo, "tools/lib/review-artifacts.rb"))
target_contract_digest = IOSTemplate::EvidenceApplicability.digest(target_contract)
target_verify = {
  "schemaVersion" => 1, "status" => "not-applicable", "changeClassification" => "documentation-only",
  "issue" => 502, "baseSha" => ENV.fetch("BASE"), "headSha" => source_head,
  "issueContract" => {"path" => ".artifacts/issues/502/issue-contract.json", "digest" => target_contract_digest},
  "visualEvaluation" => {"status" => "not-applicable", "findings" => []},
  "completedAt" => (Time.parse(record.fetch("evaluatedAt")) - 1).utc.iso8601
}
target_head_root = File.join(repo, ".artifacts/issues/502", source_head)
File.binwrite(File.join(target_head_root, "verify.json"), JSON.generate(target_verify))
state = {
  "schemaVersion" => 1, "issue" => 502, "repository" => "yuto1201/iOS-Template",
  "branch" => "codex/502-applicability", "worktree" => ".worktrees/502-applicability",
  "baseSha" => ENV.fetch("BASE"), "primaryImplementer" => "codex",
  "issueContract" => {"path" => ".artifacts/issues/502/issue-contract.json", "digest" => target_contract_digest},
  "state" => "verify-passed", "previousState" => "in-progress", "resumeState" => nil,
  "executor" => "codex", "headSha" => source_head, "from" => "in-progress", "to" => "verify-passed",
  "transitionedAt" => Time.now.utc.iso8601(6)
}
File.binwrite(File.join(repo, ".artifacts/issues/502/state.json"), JSON.generate(IOSTemplate::EvidenceApplicability.canonical(state)))
prepared = IOSTemplate::PrepareReviewPacket.prepare(
  repo: repo, primary: "codex", issue: 502, base_sha: ENV.fetch("BASE"), head_sha: source_head
)
packet_path = File.join(repo, prepared.fetch("path"))
packet_bytes = File.binread(packet_path)
packet = JSON.parse(packet_bytes)
abort "review packet omitted applicability" unless
  packet.dig("evidenceApplicability", "decision", "action") == "reuse" &&
  packet.dig("evidenceApplicabilityFile", "path") == ".artifacts/issues/502/#{source_head}/evidence-applicability.json"
references = IOSTemplate::ReviewContract.strict_references!(packet_bytes: packet_bytes, issue: 502, head_sha: source_head)
abort "review packet omitted Phase 5 closure" unless references.keys.sort.include?("evidenceSourceVerify") && references.keys.sort.include?("evidenceSourceContract")
reviewed_at = (Time.parse(record.fetch("evaluatedAt")) + 1).utc.iso8601
result = {
  "schemaVersion" => 2, "issue" => 502, "reviewerModel" => "claude",
  "baseSha" => ENV.fetch("BASE"), "headSha" => source_head, "verifySha" => source_head,
  "issueContractDigest" => target_contract_digest, "verdict" => "approved", "findings" => [],
  "acceptanceAssessment" => %w[AC-1 AC-2].map { |id| {"id" => id, "status" => "supported", "evidence" => ["evidence-applicability.json#decision"]} },
  "reviewedAt" => reviewed_at, "reviewPacketDigest" => IOSTemplate::ReviewContract.digest(packet_bytes)
}
IOSTemplate::ReviewContract.validate!(
  packet_bytes: packet_bytes, result_bytes: JSON.generate(result),
  verify_bytes: JSON.generate(target_verify), contract_bytes: target_contract,
  primary: "codex", issue: 502, base_sha: ENV.fetch("BASE"), head_sha: source_head,
  now: Time.parse(reviewed_at), require_temporal_order: true, strict: true,
  diff_bytes: File.binread(File.join(target_head_root, "review.diff")), image_bytes: {},
  actual_diff_bytes: IOSTemplate::ReviewContract.actual_diff(repo: repo, base_sha: ENV.fetch("BASE"), head_sha: source_head),
  evidence_applicability_bytes: record_bytes, evidence_source_verify_bytes: source_verify,
  evidence_source_contract_bytes: source_contract, evidence_repo: repo
)
stale_result = Marshal.load(Marshal.dump(result))
stale_result["reviewedAt"] = record.fetch("evaluatedAt")
begin
  IOSTemplate::ReviewContract.validate!(
    packet_bytes: packet_bytes, result_bytes: JSON.generate(stale_result),
    verify_bytes: JSON.generate(target_verify), contract_bytes: target_contract,
    primary: "codex", issue: 502, base_sha: ENV.fetch("BASE"), head_sha: source_head,
    now: Time.parse(reviewed_at), require_temporal_order: true, strict: true,
    diff_bytes: File.binread(File.join(target_head_root, "review.diff")), image_bytes: {},
    actual_diff_bytes: IOSTemplate::ReviewContract.actual_diff(repo: repo, base_sha: ENV.fetch("BASE"), head_sha: source_head),
    evidence_applicability_bytes: record_bytes, evidence_source_verify_bytes: source_verify,
    evidence_source_contract_bytes: source_contract, evidence_repo: repo
  )
  abort "review at the applicability evaluation time was accepted"
rescue IOSTemplate::ReviewContract::ValidationError
end
missing = Marshal.load(Marshal.dump(packet))
missing.delete("evidenceApplicability")
missing.delete("evidenceApplicabilityFile")
begin
  IOSTemplate::ReviewContract.validate_evidence_applicability!(
    packet: missing, contract: JSON.parse(target_contract), verify: target_verify, issue: 502,
    base_sha: ENV.fetch("BASE"), head_sha: source_head, repo: repo
  )
  abort "Phase 6 packet without applicability was accepted"
rescue IOSTemplate::ReviewContract::ValidationError
end

tampered = JSON.parse(record_bytes)
tampered.fetch("decision")["action"] = "targeted-reverify"
begin
  IOSTemplate::EvidenceApplicability.validate!(
    record_bytes: JSON.generate(IOSTemplate::EvidenceApplicability.canonical(tampered)), repo: repo,
    target_contract_bytes: target_contract, source_verify_bytes: source_verify, source_contract_bytes: source_contract
  )
  abort "tampered decision was accepted"
rescue IOSTemplate::EvidenceApplicability::ValidationError
end

FileUtils.mkdir_p(File.join(repo, "Sources"))
File.binwrite(File.join(repo, "Sources/Changed.swift"), "struct Changed {}\n")
abort "git add failed" unless system("git", "-C", repo, "add", "Sources/Changed.swift", out: File::NULL)
abort "git commit failed" unless system("git", "-C", repo, "commit", "-qm", "changed candidate", out: File::NULL)
target_head = `git -C #{repo.shellescape} rev-parse HEAD`.strip
target_context = Marshal.load(Marshal.dump(record.fetch("targetContext")))
target_context["configurationDigest"] = "sha256:#{"e" * 64}"
changed_bytes = `git -C #{repo.shellescape} show #{target_head}:Sources/Changed.swift`
affected = [{
  "path" => "Sources/Changed.swift", "classification" => "affected", "scopes" => ["core"],
  "dependencies" => [{"path" => "Sources/Changed.swift", "status" => "present",
                       "digest" => IOSTemplate::EvidenceApplicability.digest(changed_bytes)}],
  "reason" => "The candidate source and configuration changed."
}]
targeted = IOSTemplate::EvidenceApplicability.build(
  repo: repo, target_issue: 502, target_base_sha: ENV.fetch("BASE"), target_head_sha: target_head,
  target_contract_bytes: target_contract, source_verify_path: source_path, source_verify_bytes: source_verify,
  source_contract_bytes: source_contract, source_context: record.fetch("sourceContext"), target_context: target_context,
  impact_entries: affected, reason: "Reverify the affected core scope.", evaluated_at: Time.now.utc.iso8601
)
abort "source/config change did not require targeted reverify" unless targeted.dig("decision", "action") == "targeted-reverify"

unknown = Marshal.load(Marshal.dump(affected))
unknown.first["classification"] = "unknown"
unknown.first["dependencies"] = [{"path" => "Sources/Missing.swift", "status" => "missing", "digest" => nil}]
expanded = IOSTemplate::EvidenceApplicability.build(
  repo: repo, target_issue: 502, target_base_sha: ENV.fetch("BASE"), target_head_sha: target_head,
  target_contract_bytes: target_contract, source_verify_path: source_path, source_verify_bytes: source_verify,
  source_contract_bytes: source_contract, source_context: record.fetch("sourceContext"), target_context: record.fetch("targetContext"),
  impact_entries: unknown, reason: "Expand verification because impact and dependency resolution are incomplete.",
  evaluated_at: Time.now.utc.iso8601
)
abort "unknown impact or missing dependency did not expand verification" unless expanded.dig("decision", "action") == "expanded-verification"

scope_context = Marshal.load(Marshal.dump(record.fetch("targetContext")))
scope_context["scope"] = %w[core settings]
expanded_contract = JSON.parse(target_contract)
expanded_binding = IOSTemplate::ReleasePhase.binding_from_contract!(expanded_contract)
expanded_binding["scope"] = %w[core settings]
expanded_contract.fetch("acceptanceCriteria").last["text"] =
  "Release-phase binding: #{JSON.generate(IOSTemplate::ReleasePhase.canonical(expanded_binding))}"
expanded_contract_bytes = IOSTemplate::IssueContract.canonical_json(expanded_contract)
expanded_scope = IOSTemplate::EvidenceApplicability.build(
  repo: repo, target_issue: 502, target_base_sha: ENV.fetch("BASE"), target_head_sha: target_head,
  target_contract_bytes: expanded_contract_bytes, source_verify_path: source_path, source_verify_bytes: source_verify,
  source_contract_bytes: source_contract, source_context: record.fetch("sourceContext"), target_context: scope_context,
  impact_entries: affected, reason: "Expand verification for the larger current scope.", evaluated_at: Time.now.utc.iso8601
)
abort "scope expansion did not expand verification" unless expanded_scope.dig("decision", "action") == "expanded-verification"
RUBY

# Release/package preflight keeps its full-proof requirement, but resolves the
# proof through the exact applicability record instead of rerunning Phase 5.
release_repo="$workspace/release-repo"
mkdir -p "$release_repo"
"$source_root/tools/tests/test-ios-evidence.sh" --export-fixture "$release_repo" full >/dev/null
release_base=$(git -C "$release_repo" rev-parse HEAD^)
release_head=$(git -C "$release_repo" rev-parse HEAD)
REPO="$release_repo" ROOT="$source_root" BASE="$release_base" HEAD="$release_head" ruby -I "$source_root/tools/lib" -rjson -rdigest -rtime -rfileutils -revidence-applicability -rworkflow-release-phase -rissue-contract -rrelease-verification <<'RUBY'
repo = File.realpath(ENV.fetch("REPO"))
base = ENV.fetch("BASE")
head = ENV.fetch("HEAD")
source_issue = 42
target_issue = 43
source_contract_path = File.join(repo, ".artifacts/issues/42/issue-contract.json")
source_verify_path = File.join(repo, ".artifacts/issues/42", head, "verify.json")
binding = lambda do |phase, byte|
  value = {
    "releaseIdentifier" => "release-fixture-v1", "revision" => 1, "phase" => phase,
    "scope" => ["application"], "workKind" => "implementation", "route" => "standard",
    "recordPath" => "Config/releases/release-fixture-v1/phase-records/phase#{phase}.json",
    "recordDigest" => "sha256:#{byte * 64}", "reason" => "Bind release fixture Phase #{phase}."
  }
  "Release-phase binding: #{JSON.generate(IOSTemplate::ReleasePhase.canonical(value))}"
end
source_contract = JSON.parse(File.binread(source_contract_path))
source_contract_bytes = File.binread(source_contract_path)
source_verify_bytes = File.binread(source_verify_path)

target_contract = Marshal.load(Marshal.dump(source_contract))
target_contract["issue"] = target_issue
target_contract.fetch("acceptanceCriteria").last["text"] = binding.call(6, "6")
target_contract_bytes = IOSTemplate::IssueContract.canonical_json(target_contract)
target_issue_root = File.join(repo, ".artifacts/issues", target_issue.to_s)
target_head_root = File.join(target_issue_root, head)
FileUtils.mkdir_p(target_head_root)
File.binwrite(File.join(target_issue_root, "issue-contract.json"), target_contract_bytes)
artifact_digest = "sha256:#{"a" * 64}"
context = {
  "artifactDigest" => artifact_digest, "configurationDigest" => "sha256:#{"b" * 64}",
  "sdkDigest" => "sha256:#{"c" * 64}", "signingDigest" => "sha256:#{"d" * 64}",
  "scope" => ["application"]
}
record = IOSTemplate::EvidenceApplicability.build(
  repo: repo, target_issue: target_issue, target_base_sha: base, target_head_sha: head,
  target_contract_bytes: target_contract_bytes,
  source_verify_path: ".artifacts/issues/42/#{head}/verify.json", source_verify_bytes: source_verify_bytes,
  source_contract_bytes: source_contract_bytes, source_context: context, target_context: context,
  impact_entries: [], reason: "The release candidate and all sealed contexts are identical.",
  evaluated_at: Time.now.utc.iso8601
)
record_bytes = IOSTemplate::EvidenceApplicability.canonical_bytes(record)
record_path = File.join(target_head_root, "evidence-applicability.json")
File.binwrite(record_path, record_bytes)
published = false
reference = IOSTemplate::ReleaseVerification.with_full_proof(
  repo: repo, issue: target_issue, base: base, head: head,
  bundle: "com.example.TemplateApp", artifact_digest: artifact_digest,
  publish: ->(_) { published = true }
) { |value| value }
abort "release reuse did not publish" unless published
abort "release manifest did not bind applicability" unless reference == {
  "issue" => target_issue, "baseSha" => base,
  "path" => ".artifacts/issues/43/#{head}/evidence-applicability.json",
  "digest" => IOSTemplate::EvidenceApplicability.digest(record_bytes)
}
begin
  IOSTemplate::ReleaseVerification.with_full_proof(
    repo: repo, issue: target_issue, base: base, head: head, bundle: "com.example.TemplateApp",
    publish: ->(_) { abort "release without an artifact digest published" }
  ) { |value| value }
  abort "release without the applicability artifact digest was accepted"
rescue IOSTemplate::ReleaseVerification::InvalidProof
end

package_dir = File.join(repo, "App Store/submission")
FileUtils.mkdir_p(package_dir)
manifest_path = File.join(package_dir, "1.0-package.json")
manifest = {
  "schemaVersion" => 2, "status" => "prepared", "version" => "1.0",
  "sourceSha" => head, "bundleId" => "com.example.TemplateApp",
  "buildDigest" => artifact_digest, "verification" => reference
}
File.binwrite(manifest_path, JSON.generate(manifest))
abort "release verification CLI rejected reusable proof" unless system(
  "/usr/bin/ruby", File.join(ENV.fetch("ROOT"), "tools/lib/release-verification.rb"),
  repo, manifest_path, head, "com.example.TemplateApp", out: File::NULL
)
begin
  IOSTemplate::ReleaseVerification.with_full_proof(
    repo: repo, issue: target_issue, base: base, head: head,
    bundle: "com.example.TemplateApp", artifact_digest: "sha256:#{"f" * 64}",
    publish: ->(_) { abort "mismatched artifact published" }
  ) { |value| value }
  abort "mismatched release artifact was accepted"
rescue IOSTemplate::ReleaseVerification::InvalidProof
end
tampered = JSON.parse(record_bytes)
tampered.fetch("decision")["reason"] = "Tampered after approval."
File.binwrite(record_path, IOSTemplate::EvidenceApplicability.canonical_bytes(tampered))
begin
  IOSTemplate::ReleaseVerification.with_full_proof(
    repo: repo, issue: target_issue, base: base, head: head,
    bundle: "com.example.TemplateApp", artifact_digest: artifact_digest,
    expected_reference: reference,
    publish: ->(_) { abort "tampered record published" }
  ) { |value| value }
  abort "tampered release applicability was accepted"
rescue IOSTemplate::ReleaseVerification::InvalidProof
end
RUBY

echo 'PASS: Phase 5 evidence is reused only for the same Phase 6 candidate and conditions; source, context, unknown impact, missing dependency, and scope changes invalidate reuse'
