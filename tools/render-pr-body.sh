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

ruby -rjson -rdigest -rtime -ropen3 -I"$repo_root/tools/lib" -rdescriptor-files - "$repo_root" "$issue" "$head_sha" <<'RUBY'
repo, issue_text, head = ARGV
issue = Integer(issue_text)

def reject(message)
  warn "PR body rendering refused: #{message}"
  exit 1
end

def exact_keys!(value, keys, at)
  reject("#{at} schema is incomplete") unless value.is_a?(Hash) && value.keys.sort == keys.sort
end

class HeldEvidence
  Directory = Struct.new(:io, :parent, :name, :stat, :at, :watch_contents, keyword_init: true)
  Leaf = Struct.new(:io, :parent, :name, :stat, :bytes, :at, keyword_init: true)

  def initialize(root)
    io = DescriptorFiles.open_directory(root)
    @root_path = root
    @root = Directory.new(io: io, parent: nil, name: nil, stat: io.stat, at: "primary checkout", watch_contents: false)
    @directories = {[] => @root}
    @leaves = {}
  end

  def leaf(components, at)
    components = safe_components(components, at)
    return @leaves.fetch(components) if @leaves.key?(components)
    parent = directory(components[0...-1], at)
    io, stat = DescriptorFiles.open_regular_at(parent.io, components.last)
    io.binmode
    io.flock(File::LOCK_SH)
    bytes = DescriptorFiles.read_opened(io, stat)
    value = Leaf.new(io: io, parent: parent, name: components.last, stat: stat, bytes: bytes, at: at)
    @leaves[components] = value
  rescue SystemCallError, IOError, ArgumentError => error
    reject("#{at} descriptor is unavailable or invalid: #{error.message}")
  end

  def watch_directory(components, at)
    value = directory(safe_components(components, at), at)
    value.watch_contents = true
  end

  def verify!
    current = nil
    current_root = nil
    current_root = DescriptorFiles.open_directory(@root_path)
    reject("primary checkout identity changed") unless DescriptorFiles.stable_identity_equal?(@root.stat, current_root.stat)
    current_root.close
    @directories.each_value do |entry|
      next unless entry.parent
      current = DescriptorFiles.open_directory_at(entry.parent.io, entry.name)
      current_stat = current.stat
      current.close
      same = DescriptorFiles.stable_identity_equal?(entry.stat, current_stat)
      same &&= DescriptorFiles.metadata_equal?(entry.stat, current_stat) if entry.watch_contents
      reject("#{entry.at} component identity or contents changed") unless same
    end
    @leaves.each_value do |entry|
      held_bytes = DescriptorFiles.read_opened(entry.io, entry.stat)
      current, current_stat = DescriptorFiles.open_regular_at(entry.parent.io, entry.name)
      current.binmode
      current_bytes = DescriptorFiles.read_opened(current, current_stat)
      current.close
      held_same = held_bytes == entry.bytes
      current_same = current_bytes == entry.bytes
      metadata_same = DescriptorFiles.metadata_equal?(entry.stat, current_stat)
      reject("#{entry.at} identity or bytes changed (held=#{held_same}, current=#{current_same}, identity=#{metadata_same})") unless
        held_same && current_same && metadata_same
    end
  rescue SystemCallError, IOError, ArgumentError => error
    reject("descriptor-held evidence changed: #{error.message}")
  ensure
    current&.close unless current&.closed?
    current_root&.close unless current_root&.closed?
  end

  def close
    (@leaves.values.map(&:io) + @directories.values.map(&:io)).reverse_each { |io| io.close unless io.closed? }
  end

  private

  def safe_components(components, at)
    reject("#{at} path is unsafe") unless components.is_a?(Array) && !components.empty? &&
      components.all? { |value| value.is_a?(String) && !value.empty? && value != "." && value != ".." && !value.include?("/") && !value.include?("\0") }
    components.freeze
  end

  def directory(components, at)
    current = @root
    path = []
    components.each do |component|
      path = (path + [component]).freeze
      current = @directories[path] ||= begin
        io = DescriptorFiles.open_directory_at(current.io, component)
        Directory.new(io: io, parent: current, name: component, stat: io.stat, at: at, watch_contents: false)
      end
    end
    current
  end
end

def parse_leaf(leaf, at)
  JSON.parse(leaf.bytes)
rescue JSON::ParserError => error
  reject("#{at} is unavailable or invalid: #{error.message}")
end

def relative_components(path, at)
  reject("#{at} path is invalid") unless path.is_a?(String) && !path.empty? && !path.start_with?("/")
  components = path.split("/", -1)
  reject("#{at} path is unsafe") unless components.all? { |value| !value.empty? && value != "." && value != ".." && !value.include?("\0") }
  components
end

def validate_canonical_verify!(repo, issue, head, base, verify_digest)
  output, status = Open3.capture2e(
    "/usr/bin/swift", File.join(repo, "tools", "validate-verify-json.swift"),
    "--file", ".artifacts/issues/#{issue}/#{head}/verify.json",
    "--expected-file-digest", verify_digest,
    "--expected-issue", issue.to_s, "--expected-base", base, "--expected-head", head,
    chdir: repo
  )
  reject("canonical Verify validation failed: #{output.strip}") unless status.success?
end

repo = File.realpath(repo)
link = File.join(repo, ".artifacts")
reject(".artifacts is not the canonical raw link") unless File.symlink?(link) && File.readlink(link) == "../../.artifacts"
primary = File.realpath(File.join(repo, "..", ".."))
reject("Issue worktree is outside .worktrees") unless repo.start_with?(File.join(primary, ".worktrees") + File::SEPARATOR)
reject("canonical artifact link escapes the primary store") unless File.realpath(link) == File.join(primary, ".artifacts") && !File.symlink?(File.join(primary, ".artifacts"))
issue_root = File.join(primary, ".artifacts", "issues", issue.to_s)
head_root = File.join(issue_root, head)
snapshots = HeldEvidence.new(primary)
contract_leaf = snapshots.leaf([".artifacts", "issues", issue.to_s, "issue-contract.json"], "Issue contract")
verify_leaf = snapshots.leaf([".artifacts", "issues", issue.to_s, head, "verify.json"], "verify.json")
review_leaf = snapshots.leaf([".artifacts", "issues", issue.to_s, head, "review.json"], "review.json")
contract_bytes = contract_leaf.bytes
verify_bytes = verify_leaf.bytes
contract = parse_leaf(contract_leaf, "Issue contract")
verify = parse_leaf(verify_leaf, "verify.json")
review = parse_leaf(review_leaf, "review.json")
contract_digest = "sha256:#{Digest::SHA256.hexdigest(contract_bytes)}"
verify_digest = "sha256:#{Digest::SHA256.hexdigest(verify_bytes)}"
contract_required = %w[schemaVersion issue repository goal specAnchors acceptanceCriteria dependencies externalOperations fetchedAt]
reject("Issue contract schema is incomplete") unless contract.is_a?(Hash) && (contract.keys - contract_required - ["verification"]).empty? && contract_required.all? { |key| contract.key?(key) }
exact_keys!(verify, %w[schemaVersion status changeClassification reason issue baseSha headSha issueContract matrixFile matrixDigest executionRoute xcode build tests cases visualEvaluation acceptanceEvidence completedAt], "verify.json")
exact_keys!(review, %w[schemaVersion issue reviewerModel baseSha headSha verifySha issueContractDigest verdict findings acceptanceAssessment reviewedAt], "review.json")
reject("contract identity mismatch") unless contract.is_a?(Hash) && contract["schemaVersion"] == 1 && contract["issue"] == issue
reject("contract repository is invalid") unless contract["repository"].is_a?(String) && contract["repository"].match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
reject("verification identity mismatch") unless verify.is_a?(Hash) && verify["schemaVersion"] == 1 && verify["issue"] == issue && verify["headSha"] == head && verify.dig("issueContract", "path") == ".artifacts/issues/#{issue}/issue-contract.json" && verify.dig("issueContract", "digest") == contract_digest
reject("verification Base SHA is invalid") unless verify["baseSha"].is_a?(String) && verify["baseSha"].match?(/\A[0-9a-f]{40}\z/)
exact_keys!(verify["issueContract"], %w[path digest], "verify.issueContract")
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
reject("acceptance criteria are malformed") unless criteria.is_a?(Array) && !criteria.empty? && criteria.each_with_index.all? { |item, index| item.is_a?(Hash) && item.keys.sort == %w[id text].sort && item["id"] == "AC-#{index + 1}" && item["text"].is_a?(String) && !item["text"].empty? }
reject("acceptance evidence is malformed") unless evidence.is_a?(Array)
reject("acceptance evidence count differs from the Issue contract") unless evidence.length == criteria.length
criteria.each_with_index do |criterion, index|
  item = evidence[index]
  reject("acceptance evidence order or readiness differs") unless item.is_a?(Hash) && item.keys.sort == %w[id status evidence].sort && item["id"] == criterion["id"] && item["status"] == "passed" && item["evidence"].is_a?(Array) && !item["evidence"].empty? && item["evidence"].all? { |entry| entry.is_a?(String) && !entry.empty? }
end
assessments = review["acceptanceAssessment"]
reject("review acceptance assessment is not fully supported") unless assessments.is_a?(Array) && assessments.length == criteria.length && assessments.each_with_index.all? { |item, index| item.is_a?(Hash) && item.keys.sort == %w[id status evidence].sort && item["id"] == criteria[index]["id"] && item["status"] == "supported" && item["evidence"].is_a?(Array) && !item["evidence"].empty? && item["evidence"].all? { |entry| entry.is_a?(String) && !entry.empty? } }
build = verify["build"]
tests = verify["tests"]
cases = verify["cases"]
case_ids = %w[iphone-en iphone-ja ipad-en ipad-ja]
if verify["changeClassification"] == "documentation-only"
  exact_keys!(build, %w[status scheme warningsAdded project sourceTree], "documentation build")
  exact_keys!(tests, %w[status passed failed skipped], "documentation tests")
  exact_keys!(verify["visualEvaluation"], %w[status findings], "documentation visual evaluation")
  reject("documentation verification readiness differs") unless verify["status"] == "not-applicable" && verify["reason"].is_a?(String) && !verify["reason"].empty? && verify["executionRoute"] == "none" && verify["xcode"].nil? && build == {"status"=>"not-applicable","scheme"=>nil,"warningsAdded"=>nil,"project"=>nil,"sourceTree"=>nil} && tests == {"status"=>"not-applicable","passed"=>nil,"failed"=>nil,"skipped"=>nil} && cases == [] && verify["matrixFile"].nil? && verify["matrixDigest"].nil? && verify["visualEvaluation"] == {"status"=>"not-applicable","findings"=>[]}
else
  exact_keys!(build, %w[status scheme warningsAdded project sourceTree], "application build")
  exact_keys!(tests, %w[status passed failed skipped], "application tests")
  reject("application Verify status is not passed") unless verify["status"] == "passed"
  reject("application classification is invalid") unless verify["changeClassification"] == "application-code" && verify["reason"].nil? && %w[xcodebuild-mcp xcodebuild-simctl].include?(verify["executionRoute"]) && verify["xcode"].is_a?(Hash)
  exact_keys!(verify["xcode"], %w[path version build], "application xcode")
  reject("application Xcode identity is incomplete") unless verify["xcode"].values.all? { |entry| entry.is_a?(String) && !entry.empty? }
  exact_keys!(build["project"], %w[path digest], "application build project") if build["project"].is_a?(Hash)
  exact_keys!(build["sourceTree"], %w[headSha digest projectPath], "application source tree") if build["sourceTree"].is_a?(Hash)
  reject("application Build is not passed") unless build["status"] == "passed" && build["scheme"].is_a?(String) && !build["scheme"].empty? && build["warningsAdded"] == 0 && build["project"].is_a?(Hash) && build["sourceTree"].is_a?(Hash)
  reject("application Build identity is incomplete") unless build["project"]["path"].is_a?(String) && !build["project"]["path"].empty? && build["project"]["digest"].is_a?(String) && build["project"]["digest"].match?(/\Asha256:[0-9a-f]{64}\z/) && build["sourceTree"]["headSha"] == head && build["sourceTree"]["digest"].is_a?(String) && build["sourceTree"]["digest"].match?(/\Asha256:[0-9a-f]{64}\z/) && build["sourceTree"]["projectPath"] == build["project"]["path"]
  reject("application Tests are not passed") unless tests["status"] == "passed" && tests["passed"].is_a?(Integer) && tests["passed"].positive? && tests["failed"] == 0 && tests["skipped"] == 0
  reject("application matrix is not exactly four passed cases") unless cases.is_a?(Array) && cases.map { |item| item["id"] } == case_ids && cases.all? { |item| item.is_a?(Hash) && item.keys.sort == %w[id status screenshot screenshotDigest].sort && item["status"] == "passed" && item["screenshot"].is_a?(String) && item["screenshot"].start_with?("#{item["id"]}/") && item["screenshotDigest"].is_a?(String) && item["screenshotDigest"].match?(/\Asha256:[0-9a-f]{64}\z/) } && verify["matrixFile"].is_a?(String) && !verify["matrixFile"].empty? && verify["matrixDigest"].is_a?(String) && verify["matrixDigest"].match?(/\Asha256:[0-9a-f]{64}\z/)
  visual = verify["visualEvaluation"]
  reject("application visual evaluation is not passed") unless visual.is_a?(Hash) && visual.keys.sort == %w[status packet cases findings].sort && visual["status"] == "passed" && visual["findings"] == [] && visual["packet"].is_a?(Hash) && visual["packet"].keys.sort == %w[path digest].sort && visual["packet"]["path"].is_a?(String) && visual["packet"]["digest"].is_a?(String) && visual["packet"]["digest"].match?(/\Asha256:[0-9a-f]{64}\z/) && visual["cases"].is_a?(Array) && visual["cases"].map { |item| item["id"] } == case_ids && visual["cases"].all? { |item| item.is_a?(Hash) && item.keys.sort == %w[id images].sort && item["images"].is_a?(Array) && !item["images"].empty? && item["images"].all? { |image| image.is_a?(Hash) && image.keys.sort == %w[state path digest status findings].sort && image["state"].is_a?(String) && !image["state"].empty? && image["status"] == "passed" && image["findings"] == [] && image["path"].is_a?(String) && image["digest"].is_a?(String) && image["digest"].match?(/\Asha256:[0-9a-f]{64}\z/) } }

  # Retain the complete visual input set while the canonical Swift validator
  # proves all schema, relationship, and digest rules. Ruby only discovers and
  # binds safe paths here; it deliberately does not duplicate those rules.
  matrix_components = relative_components(verify["matrixFile"], "matrixFile")
  reject("matrixFile is outside the canonical artifact store") unless matrix_components.first == ".artifacts"
  snapshots.leaf(matrix_components, "matrixFile")
  evidence_prefix = [".artifacts", "issues", issue.to_s, head]
  cases.each do |item|
    screenshot = relative_components(item["screenshot"], "case screenshot")
    snapshots.leaf(evidence_prefix + screenshot, "case screenshot #{item["id"]}")
  end
  snapshots.leaf(evidence_prefix + ["verify-draft.json"], "verify-draft.json")
  packet_components = relative_components(visual.dig("packet", "path"), "visual packet")
  reject("visual packet is outside this Issue and Head") unless packet_components[0, 4] == evidence_prefix
  packet_leaf = snapshots.leaf(packet_components, "visual packet")
  packet = parse_leaf(packet_leaf, "visual packet")
  packet_cases = packet["cases"]
  reject("visual packet image references are incomplete") unless packet_cases.is_a?(Array)
  packet_cases.each do |packet_case|
    images = packet_case.is_a?(Hash) ? packet_case["images"] : nil
    reject("visual packet image references are incomplete") unless images.is_a?(Array) && !images.empty?
    images.each do |image|
      path = image.is_a?(Hash) ? image["path"] : nil
      components = relative_components(path, "visual packet image")
      snapshots.leaf(evidence_prefix + components, "visual packet image #{path}")
    end
  end
  case_ids.each { |id| snapshots.watch_directory(evidence_prefix + [id], "visual packet case directory") }
  validate_canonical_verify!(repo, issue, head, verify["baseSha"], verify_digest)
end

if verify["changeClassification"] == "documentation-only"
  validate_canonical_verify!(repo, issue, head, verify["baseSha"], verify_digest)
end

snapshots.verify!

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
snapshots.close
RUBY
