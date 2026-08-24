#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: render-pr-body.sh --issue NUMBER --head-sha SHA' >&2; exit 2; }
issue='' head_sha=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) issue=${2:-}; shift 2 ;;
    --head-sha) head_sha=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$issue" =~ ^[1-9][0-9]*$ && "$head_sha" =~ ^[0-9a-f]{40}$ ]] || usage

ruby -rjson -rdigest -rtime -I"$repo_root/tools/lib" -rdescriptor-files - "$repo_root" "$issue" "$head_sha" <<'RUBY'
repo, issue_text, head = ARGV
issue = Integer(issue_text)

def reject(message)
  warn "PR body rendering refused: #{message}"
  exit 1
end

def parse_owned(directory, name, at)
  bytes, = DescriptorFiles.read_regular_at(directory, name)
  [JSON.parse(bytes), bytes]
rescue JSON::ParserError, IOError, SystemCallError, ArgumentError => error
  reject("#{at} is unavailable or invalid: #{error.message}")
end

repo = File.realpath(repo)
link = File.join(repo, ".artifacts")
reject(".artifacts is not the canonical raw link") unless File.symlink?(link) && File.readlink(link) == "../../.artifacts"
primary = File.realpath(File.join(repo, "..", ".."))
reject("Issue worktree is outside .worktrees") unless repo.start_with?(File.join(primary, ".worktrees") + File::SEPARATOR)
reject("canonical artifact link escapes the primary store") unless File.realpath(link) == File.join(primary, ".artifacts") && !File.symlink?(File.join(primary, ".artifacts"))
issue_root = File.join(primary, ".artifacts", "issues", issue.to_s)
head_root = File.join(issue_root, head)
handles = DescriptorFiles.open_components(primary, [".artifacts", "issues", issue.to_s, head])
issue_directory = handles[-2]
head_directory = handles[-1]
contract, contract_bytes = parse_owned(issue_directory, "issue-contract.json", "Issue contract")
verify, verify_bytes = parse_owned(head_directory, "verify.json", "verify.json")
review, = parse_owned(head_directory, "review.json", "review.json")
contract_digest = "sha256:#{Digest::SHA256.hexdigest(contract_bytes)}"
verify_digest = "sha256:#{Digest::SHA256.hexdigest(verify_bytes)}"
reject("contract identity mismatch") unless contract.is_a?(Hash) && contract["schemaVersion"] == 1 && contract["issue"] == issue
reject("verification identity mismatch") unless verify.is_a?(Hash) && verify["schemaVersion"] == 1 && verify["issue"] == issue && verify["headSha"] == head && verify.dig("issueContract", "path") == ".artifacts/issues/#{issue}/issue-contract.json" && verify.dig("issueContract", "digest") == contract_digest
reject("review identity mismatch") unless review.is_a?(Hash) && review["schemaVersion"] == 1 && review["issue"] == issue && review["baseSha"] == verify["baseSha"] && review["headSha"] == head && review["verifySha"] == head && review["issueContractDigest"] == contract_digest
begin
  completed_at = Time.iso8601(verify.fetch("completedAt"))
  reviewed_at = Time.iso8601(review.fetch("reviewedAt"))
  reject("verification or review timestamp is implausibly in the future") if completed_at > Time.now + 300 || reviewed_at > Time.now + 300
  reject("review timestamp precedes verification") if reviewed_at < completed_at
rescue KeyError, ArgumentError, TypeError
  reject("verification or review timestamp is incomplete")
end
reviewer = review["reviewerModel"]
reject("reviewer model is invalid") unless %w[codex claude].include?(reviewer)
reject("review verdict is not approved") unless review["verdict"] == "approved" && review["findings"] == []
anchors = contract["specAnchors"]
reject("spec anchors are missing") unless anchors.is_a?(Array) && !anchors.empty? && anchors.all? { |entry| entry.is_a?(String) && !entry.empty? }
criteria = contract["acceptanceCriteria"]
evidence = verify["acceptanceEvidence"]
reject("acceptance evidence is malformed") unless criteria.is_a?(Array) && evidence.is_a?(Array)
reject("acceptance evidence count differs from the Issue contract") unless evidence.length == criteria.length
criteria.each_with_index do |criterion, index|
  item = evidence[index]
  reject("acceptance evidence order or readiness differs") unless item.is_a?(Hash) && item["id"] == criterion["id"] && item["status"] == "passed" && item["evidence"].is_a?(Array) && !item["evidence"].empty?
end
assessments = review["acceptanceAssessment"]
reject("review acceptance assessment is not fully supported") unless assessments.is_a?(Array) && assessments.length == criteria.length && assessments.each_with_index.all? { |item, index| item.is_a?(Hash) && item["id"] == criteria[index]["id"] && item["status"] == "supported" && item["evidence"].is_a?(Array) && !item["evidence"].empty? }
build = verify["build"]
tests = verify["tests"]
cases = verify["cases"]
case_ids = %w[iphone-en iphone-ja ipad-en ipad-ja]
if verify["changeClassification"] == "documentation-only"
  reject("documentation verification readiness differs") unless verify["status"] == "not-applicable" && build.is_a?(Hash) && build["status"] == "not-applicable" && tests.is_a?(Hash) && tests["status"] == "not-applicable" && cases == [] && verify["matrixFile"].nil? && verify["matrixDigest"].nil?
else
  reject("application Verify status is not passed") unless verify["status"] == "passed"
  reject("application Build is not passed") unless build.is_a?(Hash) && build["status"] == "passed"
  reject("application Tests are not passed") unless tests.is_a?(Hash) && tests["status"] == "passed" && tests["passed"].is_a?(Integer) && tests["passed"].positive? && tests["failed"] == 0
  reject("application matrix is not exactly four passed cases") unless cases.is_a?(Array) && cases.map { |item| item["id"] } == case_ids && cases.all? { |item| item.is_a?(Hash) && item["status"] == "passed" } && verify["matrixFile"].is_a?(String) && !verify["matrixFile"].empty? && verify["matrixDigest"].is_a?(String) && verify["matrixDigest"].match?(/\Asha256:[0-9a-f]{64}\z/)
  visual = verify["visualEvaluation"]
  reject("application visual evaluation is not passed") unless visual.is_a?(Hash) && visual["status"] == "passed" && visual["findings"] == []
end

puts "Closes ##{issue}"
puts
puts "## Summary"
puts
puts "- #{contract.fetch("goal")}"
puts
puts "## Specification"
puts
anchors.each { |anchor| puts "- `#{anchor}`" }
puts "- Issue contract digest: `#{contract_digest}`"
puts
puts "## Verification"
puts
puts "- Head SHA: `#{head}`"
puts "- Verify status: `#{verify["status"]}`"
puts "- Verify digest: `#{verify_digest}`"
build ||= {}
tests ||= {}
puts "- Build: `#{build["status"]}` (scheme: `#{build["scheme"] || "not-applicable"}`, warnings added: `#{build["warningsAdded"].nil? ? "not-applicable" : build["warningsAdded"]}`)"
puts "- Tests: `#{tests["status"]}` (passed: `#{tests["passed"].nil? ? "not-applicable" : tests["passed"]}`, failed: `#{tests["failed"].nil? ? "not-applicable" : tests["failed"]}`, skipped: `#{tests["skipped"].nil? ? "not-applicable" : tests["skipped"]}`)"
puts "- Matrix file: `#{verify["matrixFile"] || "not-applicable"}`"
puts "- Matrix digest: `#{verify["matrixDigest"] || "not-applicable"}`"
case_labels = {"iphone-en" => "iPhone Pro / English", "iphone-ja" => "iPhone Pro / Japanese", "ipad-en" => "iPad Air / English", "ipad-ja" => "iPad Air / Japanese"}
if cases.is_a?(Array) && !cases.empty?
  case_labels.each do |id, label|
    item = cases.find { |entry| entry.is_a?(Hash) && entry["id"] == id }
    reject("matrix result is missing #{id}") unless item
    puts "  - #{label} (`#{id}`): `#{item["status"]}`"
  end
else
  case_labels.each_value { |label| puts "  - #{label}: `not-applicable` (#{verify["changeClassification"]})" }
end
puts
puts "### Acceptance evidence"
puts
criteria.each do |criterion|
  item = evidence.find { |entry| entry.is_a?(Hash) && entry["id"] == criterion["id"] }
  reject("acceptance evidence is missing #{criterion["id"]}") unless item && item["evidence"].is_a?(Array) && !item["evidence"].empty?
  puts "- #{criterion["id"]}: `#{item["status"]}` — #{item["evidence"].join(", ")}"
end
puts
puts "## Opposite-model review"
puts
puts "- Reviewer: `#{reviewer}`"
puts "- Reviewer model: `#{reviewer}`"
puts "- Reviewed Head SHA: `#{review["headSha"]}`"
puts "- Verified SHA: `#{review["verifySha"]}`"
puts "- Verdict: `#{review["verdict"]}`"
puts "- Blocking findings: `0`"
puts
puts "## Remaining work"
puts
puts "- None for this Issue."
handles.reverse_each { |handle| handle.close unless handle.closed? }
RUBY
