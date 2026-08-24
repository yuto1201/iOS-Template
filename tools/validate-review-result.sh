#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: validate-review-result.sh --primary codex|claude --packet .artifacts/issues/ISSUE/HEAD/PACKET.json [--result RESULT.json]' >&2; exit 2; }

primary='' packet='' result=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary) [[ -z "$primary" && $# -ge 2 ]] || usage; primary=$2; shift 2 ;;
    --packet) [[ -z "$packet" && $# -ge 2 ]] || usage; packet=$2; shift 2 ;;
    --result) [[ -z "$result" && $# -ge 2 ]] || usage; result=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ ( "$primary" == codex || "$primary" == claude ) && -n "$packet" ]] || usage

topology=$(ruby "$repo_root/tools/lib/review-artifacts.rb" "$repo_root") || exit 1
ruby -rjson -rdigest -rtime -rfiddle/import - "$topology" "$primary" "$packet" "$result" <<'RUBY'
topology_json, primary, packet_input, result_input = ARGV

def reject(message)
  warn "review validation failed: #{message}"
  exit 1
end

def exact_keys!(object, keys, at)
  reject("#{at} must be an object") unless object.is_a?(Hash)
  actual = object.keys.sort
  expected = keys.sort
  reject("#{at}: unexpected or missing keys") unless actual == expected
end

def string!(value, at)
  reject("#{at} must be a nonempty string") unless value.is_a?(String) && !value.empty? && !value.include?("\0")
  value
end

def sha!(value, at)
  value = string!(value, at)
  reject("#{at} must be a 40-character lowercase Git SHA") unless value.match?(/\A[0-9a-f]{40}\z/)
  value
end

def digest!(value, at)
  value = string!(value, at)
  reject("#{at} must be a sha256 digest") unless value.match?(/\Asha256:[0-9a-f]{64}\z/)
  value
end

def json_file!(file, at)
  JSON.parse(file.fetch(:bytes))
rescue JSON::ParserError => error
  reject("#{at} is not readable JSON: #{error.message}")
end

module NativeOpen
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern "int openat(int, const char*, int)"
end

def secure_file!(path, root, at, expected_root_identity = nil)
  reject("#{at} path is not absolute") unless path.start_with?("/") && root.start_with?("/")
  reject("#{at} escapes its physical root") unless path.start_with?(root + "/")
  relative = path.delete_prefix(root + "/")
  reject("#{at} has an empty or unsafe path") if relative.empty? || relative.split("/").any? { |component| component.empty? || component == "." || component == ".." }
  components = relative.split("/")
  flags = File::RDONLY
  flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
  descriptors = []
  file = nil
  root_file = File.open(root, flags)
  descriptors << root_file
  root_stat = root_file.stat
  reject("#{at} root must be a physical directory") unless root_stat.directory? && File.realpath(root) == root
  if expected_root_identity
    reject("#{at} physical root identity changed") unless [root_stat.dev, root_stat.ino] == expected_root_identity
  end
  current = root_file
  components.each_with_index do |component, index|
    fd = NativeOpen.openat(current.fileno, component, flags)
    if fd.negative?
      error = SystemCallError.new("openat", Fiddle.last_error)
      reject("#{at} is not readable without following links: #{error.message}")
    end
    opened = IO.for_fd(fd, autoclose: true)
    descriptors << opened
    stat = opened.stat
    if index < components.length - 1
      reject("#{at} has a non-directory component") unless stat.directory?
      current = opened
    else
      file = opened
    end
  end
  reject("#{at} did not resolve to a file") unless file
  descriptor_stat = file.stat
  reject("#{at} must be a regular single-link file") unless descriptor_stat.file? && descriptor_stat.nlink == 1
  bytes = file.read
  current_path = root
  components.each_with_index do |component, index|
    current_path = File.join(current_path, component)
    stat = File.lstat(current_path)
    reject("#{at} contains a symlink") if stat.symlink?
    reject("#{at} has a non-directory component") if index < components.length - 1 && !stat.directory?
    if index == components.length - 1
      reject("#{at} changed while it was read") unless stat.file? && stat.nlink == 1 && stat.dev == descriptor_stat.dev && stat.ino == descriptor_stat.ino
    end
  end
  {path: path, bytes: bytes}
rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
  reject("#{at} is not readable: #{error.message}")
ensure
  descriptors&.reverse_each { |descriptor| descriptor.close unless descriptor.closed? }
end

def regular_inside!(repo, input, root, at, root_identity)
  reject("#{at} must be repository-relative") if input.start_with?("/")
  reject("#{at} contains an unsafe component") if input.split("/").any? { |component| component.empty? || component == "." || component == ".." }
  path = File.join(repo, input)
  secure_file!(path, root, at, root_identity)
end

def artifact_file!(artifacts, input, canonical_root, at, artifacts_identity)
  reject("#{at} must be a canonical artifact path") unless input.is_a?(String) && input.start_with?(".artifacts/")
  components = input.split("/")
  reject("#{at} contains an unsafe component") if components.any? { |component| component.empty? || component == "." || component == ".." }
  suffix = components.drop(1).join("/")
  path = File.join(artifacts, suffix)
  reject("#{at} escapes its canonical directory") unless path.start_with?(canonical_root + "/")
  secure_file!(path, artifacts, at, artifacts_identity)
end

def relative_artifact!(value, root, at)
  value = string!(value, at)
  reject("#{at} must be relative") if value.start_with?("/") || value.split("/").include?("..") || value.split("/").include?(".")
  File.join(root, value)
end

topology = JSON.parse(topology_json)
repo = topology.fetch("repositoryRoot")
artifacts = topology.fetch("artifactsRoot")
repo_identity = [topology.fetch("repositoryDevice"), topology.fetch("repositoryInode")]
artifacts_identity = [topology.fetch("artifactsDevice"), topology.fetch("artifactsInode")]
issues_root = File.join(artifacts, "issues")
packet_file = artifact_file!(artifacts, packet_input, issues_root, "packet", artifacts_identity)
packet = json_file!(packet_file, "packet")
packet_keys = %w[schemaVersion issue primaryModel reviewerModel baseSha headSha verifySha issueContract specAnchors acceptanceCriteria diffFile verifyFile imageFiles]
exact_keys!(packet, packet_keys, "packet")
reject("packet.schemaVersion must be 1") unless packet["schemaVersion"] == 1
issue = packet["issue"]
reject("packet.issue must be a positive integer") unless issue.is_a?(Integer) && issue.positive?
expected_reviewer = primary == "codex" ? "claude" : "codex"
reject("packet.primaryModel does not match --primary") unless packet["primaryModel"] == primary
reject("packet.reviewerModel must be the opposite model") unless packet["reviewerModel"] == expected_reviewer
base_sha = sha!(packet["baseSha"], "packet.baseSha")
head_sha = sha!(packet["headSha"], "packet.headSha")
verify_sha = sha!(packet["verifySha"], "packet.verifySha")
reject("packet.headSha must equal packet.verifySha") unless head_sha == verify_sha

issue_root = File.join(artifacts, "issues", issue.to_s)
head_root = File.join(issue_root, head_sha)
expected_packet_path = ".artifacts/issues/#{issue}/#{head_sha}/review-packet.json"
reject("packet path is not canonical") unless packet_input == expected_packet_path
packet_file = artifact_file!(artifacts, packet_input, head_root, "packet", artifacts_identity)
exact_keys!(packet["issueContract"], %w[path digest], "packet.issueContract")
expected_contract_path = ".artifacts/issues/#{issue}/issue-contract.json"
reject("packet.issueContract.path is not canonical") unless packet["issueContract"]["path"] == expected_contract_path
contract_file = artifact_file!(artifacts, expected_contract_path, issue_root, "packet.issueContract.path", artifacts_identity)
contract_digest = digest!(packet["issueContract"]["digest"], "packet.issueContract.digest")
actual_contract_digest = "sha256:#{Digest::SHA256.hexdigest(contract_file.fetch(:bytes))}"
reject("packet.issueContract.digest does not match exact file bytes") unless contract_digest == actual_contract_digest
contract = json_file!(contract_file, "issue contract")
reject("issue contract identity does not match packet") unless contract.is_a?(Hash) && contract["schemaVersion"] == 1 && contract["issue"] == issue
repository = string!(contract["repository"], "issue contract.repository")
reject("issue contract.repository is invalid") unless repository.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)

anchors = packet["specAnchors"]
reject("packet.specAnchors must be a nonempty array") unless anchors.is_a?(Array) && !anchors.empty? && anchors.all? { |entry| entry.is_a?(String) && !entry.empty? } && anchors.uniq == anchors
criteria = packet["acceptanceCriteria"]
reject("packet.acceptanceCriteria must be a nonempty array") unless criteria.is_a?(Array) && !criteria.empty?
criteria.each_with_index do |criterion, index|
  exact_keys!(criterion, %w[id text], "packet.acceptanceCriteria[#{index}]")
  expected_id = "AC-#{index + 1}"
  reject("packet.acceptanceCriteria must have ordered IDs") unless criterion["id"] == expected_id
  string!(criterion["text"], "packet.acceptanceCriteria[#{index}].text")
end
reject("packet acceptance criteria do not match issue contract") unless contract["acceptanceCriteria"] == criteria
reject("packet spec anchors do not match issue contract") unless contract["specAnchors"] == anchors

expected_prefix = ".artifacts/issues/#{issue}/#{head_sha}/"
%w[diffFile verifyFile].each do |field|
  value = string!(packet[field], "packet.#{field}")
  reject("packet.#{field} is not inside the Issue/Head artifact directory") unless value.start_with?(expected_prefix)
  artifact_file!(artifacts, value, head_root, "packet.#{field}", artifacts_identity)
end
images = packet["imageFiles"]
reject("packet.imageFiles must be an array") unless images.is_a?(Array) && images.all? { |entry| entry.is_a?(String) } && images.uniq == images
images.each_with_index do |image, index|
  artifact_path = relative_artifact!(image, head_root, "packet.imageFiles[#{index}]")
  relative_path = artifact_path.delete_prefix(artifacts + "/")
  artifact_file!(artifacts, ".artifacts/#{relative_path}", head_root, "packet.imageFiles[#{index}]", artifacts_identity)
end

verify_file = artifact_file!(artifacts, packet["verifyFile"], head_root, "packet.verifyFile", artifacts_identity)
verify = json_file!(verify_file, "verify file")
reject("verify file must be an object") unless verify.is_a?(Hash)
reject("verify file identity does not match packet") unless verify["schemaVersion"] == 1 && verify["issue"] == issue && verify["baseSha"] == base_sha && verify["headSha"] == verify_sha
exact_keys!(verify["issueContract"], %w[path digest], "verify.issueContract")
reject("verify issue-contract reference does not match packet") unless verify["issueContract"]["path"] == expected_contract_path && verify["issueContract"]["digest"] == contract_digest

if result_input.empty?
  puts JSON.generate(packet.merge("issueContractRepository" => repository))
  exit 0
end

result_input_path = File.expand_path(result_input, Dir.pwd)
result_parent = File.realpath(File.dirname(result_input_path))
result_path = File.join(result_parent, File.basename(result_input_path))
result_file = secure_file!(result_path, result_parent, "result")
result = json_file!(result_file, "result")
result_keys = %w[schemaVersion issue reviewerModel baseSha headSha verifySha issueContractDigest verdict findings acceptanceAssessment reviewedAt]
exact_keys!(result, result_keys, "result")
reject("result.schemaVersion must be 1") unless result["schemaVersion"] == 1
reject("result identity does not match packet") unless result["issue"] == issue && result["reviewerModel"] == expected_reviewer && result["baseSha"] == base_sha && result["headSha"] == head_sha && result["verifySha"] == verify_sha
reject("result issueContractDigest does not match packet") unless digest!(result["issueContractDigest"], "result.issueContractDigest") == contract_digest
verdict = result["verdict"]
reject("result.verdict is invalid") unless %w[approved changes-requested].include?(verdict)
findings = result["findings"]
reject("result.findings must be an array") unless findings.is_a?(Array)
findings.each_with_index do |finding, index|
  exact_keys!(finding, %w[severity category file line title evidence requiredChange], "result.findings[#{index}]")
  reject("result.findings[#{index}].severity is invalid") unless %w[critical high medium low].include?(finding["severity"])
  reject("result.findings[#{index}].category is invalid") unless string!(finding["category"], "result.findings[#{index}].category").match?(/\A[a-z][a-z-]*\z/)
  file = string!(finding["file"], "result.findings[#{index}].file")
  regular_inside!(repo, file, repo, "result.findings[#{index}].file", repo_identity)
  reject("result.findings[#{index}].line must be positive") unless finding["line"].is_a?(Integer) && finding["line"].positive?
  %w[title evidence requiredChange].each { |field| string!(finding[field], "result.findings[#{index}].#{field}") }
end
assessments = result["acceptanceAssessment"]
reject("result.acceptanceAssessment must match packet criteria") unless assessments.is_a?(Array) && assessments.length == criteria.length
assessments.each_with_index do |assessment, index|
  exact_keys!(assessment, %w[id status evidence], "result.acceptanceAssessment[#{index}]")
  reject("result.acceptanceAssessment IDs must match packet") unless assessment["id"] == criteria[index]["id"]
  reject("result.acceptanceAssessment status is invalid") unless %w[supported unsupported].include?(assessment["status"])
  evidence = assessment["evidence"]
  reject("result.acceptanceAssessment evidence must be nonempty strings") unless evidence.is_a?(Array) && !evidence.empty? && evidence.all? { |entry| entry.is_a?(String) && !entry.empty? && !entry.include?("\0") && !entry.start_with?("/") && !entry.split("/").include?("..") }
  evidence.each_with_index do |reference, evidence_index|
    local_path = reference.split("#", 2).first
    next if local_path.include?(":")
    artifact_path = relative_artifact!(local_path, head_root, "result.acceptanceAssessment[#{index}].evidence[#{evidence_index}]")
    relative_path = artifact_path.delete_prefix(artifacts + "/")
    artifact_file!(artifacts, ".artifacts/#{relative_path}", head_root, "result.acceptanceAssessment[#{index}].evidence[#{evidence_index}]", artifacts_identity)
  end
end
begin
  reviewed_at = Time.iso8601(string!(result["reviewedAt"], "result.reviewedAt"))
  reject("result.reviewedAt is implausibly in the future") if reviewed_at > Time.now + 300
rescue ArgumentError
  reject("result.reviewedAt must be ISO 8601")
end
if verdict == "approved"
  reject("approved result must have no findings") unless findings.empty?
  reject("approved result must support every acceptance criterion") unless assessments.all? { |entry| entry["status"] == "supported" }
else
  blocking = findings.any? { |finding| %w[critical high medium].include?(finding["severity"]) } || assessments.any? { |entry| entry["status"] == "unsupported" }
  reject("changes-requested result must contain a blocking finding or unsupported criterion") unless blocking
end
puts JSON.generate(result)
RUBY
