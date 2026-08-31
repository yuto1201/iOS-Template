#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require_relative "descriptor-files"
require_relative "issue-contract"
require_relative "delivery-profile"
require_relative "ownership"
require_relative "review-contract"
require_relative "review-receipt"

def refuse(message)
  warn "pre-merge gate failed: #{message}"
  exit 1
end

def canonical(value)
  case value
  when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
  when Array then value.map { |entry| canonical(entry) }
  else value
  end
end

def exact_keys!(value, keys, at)
  refuse("#{at} must be an object") unless value.is_a?(Hash)
  refuse("#{at} has unexpected or missing fields") unless value.keys.sort == keys.sort
end

def parse_object(bytes, at)
  # JSON.parse may retag its input as UTF-8. Parse a duplicate so the held
  # descriptor snapshot remains byte-for-byte comparable for non-ASCII data.
  value = JSON.parse(bytes.dup)
  refuse("#{at} must be an object") unless value.is_a?(Hash)
  value
rescue JSON::ParserError => error
  refuse("#{at} is not valid JSON: #{error.message}")
end

def iso8601!(value, at)
  refuse("#{at} must be a nonempty timestamp") unless value.is_a?(String) && !value.empty?
  Time.iso8601(value).utc
rescue ArgumentError
  refuse("#{at} must be ISO 8601")
end

def safe_identifier!(value, at)
  refuse("#{at} is invalid") unless value.is_a?(String) && value.bytesize.between?(1, 256) && value == value.strip && value.match?(/\A[A-Za-z0-9][A-Za-z0-9 ._:@\/-]*\z/)
  value
end

class HeldSnapshots
  Directory = Struct.new(:io, :parent, :name, :stat, :at, keyword_init: true)
  Leaf = Struct.new(:io, :parent, :name, :stat, :bytes, :at, keyword_init: true)

  def initialize(root, at)
    @directories = []
    @leaves = []
    root_io = DescriptorFiles.open_directory(root)
    @root = Directory.new(io: root_io, parent: nil, name: nil, stat: root_io.stat, at: at)
    @directories << @root
  end

  attr_reader :root

  def self.metadata(stat)
    # APFS may finalize ctime asynchronously after an atomic replacement.
    # Compare stable identity, ownership, permissions, and content mtime; exact
    # bytes are checked separately while the descriptor remains held.
    [
      stat.dev, stat.ino, stat.size, stat.mode, stat.nlink,
      stat.uid, stat.gid, stat.mtime.to_i, stat.mtime.nsec
    ]
  end

  def directory(parent, name, at)
    io = DescriptorFiles.open_directory_at(parent.io, name)
    value = Directory.new(io: io, parent: parent, name: name, stat: io.stat, at: at)
    @directories << value
    value
  rescue SystemCallError, IOError => error
    refuse("#{at} is not a descriptor-bound physical directory: #{error.message}")
  end

  def leaf(parent, name, at)
    io, stat = DescriptorFiles.open_regular_at(parent.io, name)
    io.binmode
    bytes = io.read
    value = Leaf.new(io: io, parent: parent, name: name, stat: stat, bytes: bytes, at: at)
    @leaves << value
    value
  rescue SystemCallError, IOError => error
    refuse("#{at} is not a descriptor-bound regular single-link file: #{error.message}")
  end

  def relative_leaf(parent, relative, at)
    components = relative.split("/")
    refuse("#{at} path is unsafe") if components.empty? || components.any? { |part| part.empty? || part == "." || part == ".." }
    current = parent
    components[0...-1].each_with_index do |component, index|
      current = directory(current, component, "#{at} component #{index + 1}")
    end
    leaf(current, components.last, at)
  end

  def verify!
    @directories.drop(1).each do |directory|
      current = DescriptorFiles.open_directory_at(directory.parent.io, directory.name)
      stat = current.stat
      current.close
      refuse("#{directory.at} component identity changed") unless [stat.dev, stat.ino] == [directory.stat.dev, directory.stat.ino]
    rescue SystemCallError, IOError => error
      refuse("#{directory.at} component identity changed: #{error.message}")
    end
    @leaves.each do |leaf|
      stat = leaf.io.stat
      refuse("#{leaf.at} descriptor identity or metadata changed") unless
        stat.file? && stat.nlink == 1 && self.class.metadata(stat) == self.class.metadata(leaf.stat)
      leaf.io.rewind
      refuse("#{leaf.at} bytes changed while held") unless leaf.io.read == leaf.bytes
      current, current_stat = DescriptorFiles.open_regular_at(leaf.parent.io, leaf.name)
      current.binmode
      current_bytes = current.read
      current.close
      refuse("#{leaf.at} path identity or metadata changed") unless self.class.metadata(current_stat) == self.class.metadata(leaf.stat)
      refuse("#{leaf.at} path bytes changed") unless current_bytes == leaf.bytes
    rescue SystemCallError, IOError => error
      refuse("#{leaf.at} path identity changed: #{error.message}")
    end
  end

  def close
    (@leaves.map(&:io) + @directories.map(&:io)).reverse_each { |io| io.close unless io.closed? }
  end
end

root, repository, issue_text, head_sha, merge_pr_text = ARGV
refuse("invalid gate helper arguments") unless root&.start_with?("/") && repository&.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}) && issue_text&.match?(/\A[1-9][0-9]*\z/) && head_sha&.match?(/\A[0-9a-f]{40}\z/) && (merge_pr_text.nil? || merge_pr_text.empty? || merge_pr_text.match?(/\A[1-9][0-9]*\z/))
issue = Integer(issue_text)
merge_pr = merge_pr_text.nil? || merge_pr_text.empty? ? nil : Integer(merge_pr_text)
identity = parse_object(ENV.fetch("PREMERGE_IDENTITY_JSON", ""), "merge identity")
refuse("merge identity differs from caller") unless identity["repository"] == repository && identity["issue"] == issue && identity["headSha"] == head_sha && identity["state"] == "approved-for-merge"
refuse("merge PR differs from durable identity") if merge_pr && identity["pullRequest"] != merge_pr
primary = identity.fetch("primaryRoot")

artifact_snapshots = HeldSnapshots.new(primary, "primary checkout")
source_snapshots = HeldSnapshots.new(root, "Issue worktree")
begin
  artifacts = artifact_snapshots.directory(artifact_snapshots.root, ".artifacts", ".artifacts")
  issues = artifact_snapshots.directory(artifacts, "issues", ".artifacts/issues")
  issue_directory = artifact_snapshots.directory(issues, issue.to_s, "Issue artifact directory")
  lock_mode = merge_pr ? File::LOCK_EX : File::LOCK_SH
  refuse("Issue artifact directory is locked by another workflow") unless issue_directory.io.flock(lock_mode | File::LOCK_NB)
  head_directory = artifact_snapshots.directory(issue_directory, head_sha, "Head artifact directory")
  state_file = artifact_snapshots.leaf(issue_directory, "state.json", "state.json")
  contract_file = artifact_snapshots.leaf(issue_directory, "issue-contract.json", "issue-contract.json")
  verify_file = artifact_snapshots.leaf(head_directory, "verify.json", "verify.json")
  contract = parse_object(contract_file.bytes, "issue-contract.json")
  review_required = IOSTemplate::DeliveryProfile.review_required?(contract)
  packet_file = review_required ? artifact_snapshots.leaf(head_directory, "review-packet.json", "review-packet.json") : nil
  review_file = review_required ? artifact_snapshots.leaf(head_directory, "review.json", "review.json") : nil
  receipt_file = review_required ? artifact_snapshots.leaf(head_directory, "review-receipt.json", "review-receipt.json") : nil
  preflight_file = artifact_snapshots.leaf(issue_directory, "github-preflight.json", "github-preflight.json")
  config = source_snapshots.directory(source_snapshots.root, "Config", "Config")
  ownership_file = source_snapshots.leaf(config, "ownership.yml", "Config/ownership.yml")
  ownership = IOSTemplate::Ownership.parse(ownership_file.bytes)

  diff_file = nil
  image_files = {}
  if review_required
    review_references = IOSTemplate::ReviewContract.strict_references!(
      packet_bytes: packet_file.bytes, issue: issue, head_sha: head_sha
    )
    evidence_prefix = ".artifacts/issues/#{issue}/#{head_sha}/"
    diff_relative = review_references.fetch("diff").fetch("path").delete_prefix(evidence_prefix)
    diff_file = artifact_snapshots.relative_leaf(head_directory, diff_relative, "review.diff")
    image_files = review_references.fetch("imageFiles").to_h do |reference|
      path = reference.fetch("path")
      relative = path.delete_prefix(evidence_prefix)
      held = artifact_snapshots.relative_leaf(head_directory, relative, "review image #{path}")
      [path, held]
    end
  end

  state = parse_object(state_file.bytes, "state.json")
  state_digest = "sha256:#{Digest::SHA256.hexdigest(state_file.bytes)}"
  state_metadata = {
    "dev" => state_file.stat.dev, "ino" => state_file.stat.ino, "size" => state_file.stat.size,
    "mode" => state_file.stat.mode, "nlink" => state_file.stat.nlink,
    "uid" => state_file.stat.uid, "gid" => state_file.stat.gid,
    "mtimeSec" => state_file.stat.mtime.to_i, "mtimeNsec" => state_file.stat.mtime.nsec
  }
  refuse("held state bytes or metadata differ from validated identity") unless
    identity["stateDigest"] == state_digest && identity["stateMetadata"] == state_metadata
  refuse("held state differs from validated identity") unless
    state["state"] == "approved-for-merge" && state["issue"] == issue && state["repository"] == repository &&
    state["branch"] == identity["branch"] && state["worktree"] == identity["worktree"] &&
    state["primaryImplementer"] == identity["primaryImplementer"] &&
    state["baseSha"] == identity["baseSha"] && state["headSha"] == head_sha &&
    state.dig("issueContract", "digest") == identity["contractDigest"]
  transitioned_at = iso8601!(state["transitionedAt"], "state.transitionedAt")
  contract_digest = "sha256:#{Digest::SHA256.hexdigest(contract_file.bytes)}"
  refuse("contract bytes differ from validated identity") unless contract_digest == identity["contractDigest"]

  operation_details = contract.fetch("externalOperations", []).map { |operation| [operation, nil] }.to_h
  refuse("Issue contract does not declare github.merge_pr") unless operation_details.key?("github.merge_pr")
  provider_files = {}
  non_github_operations = operation_details.keys.reject { |operation| operation.start_with?("github.") }
  unless non_github_operations.empty?
    provider_root = artifact_snapshots.directory(issue_directory, "provider-preflights", "provider-preflights")
    provider_by_prefix = {"supabase" => "supabase", "cloudflare" => "cloudflare", "linear" => "linear", "vercel" => "vercel", "elevenlabs" => "elevenlabs", "appstore" => "app-store"}
    non_github_operations.each do |operation|
      prefix = operation.split(".", 2).first
      provider = provider_by_prefix.fetch(prefix) { refuse("unsupported provider operation: #{operation}") }
      refuse("multiple operations for provider #{provider}") if provider_files.key?(provider)
      provider_files[provider] = artifact_snapshots.leaf(provider_root, "#{provider}.json", "#{provider} provider preflight")
    end
  end

  issue_output, issue_status = Open3.capture2e("gh", "issue", "view", issue.to_s, "--repo", repository, "--json", "number,url,body,labels")
  refuse("live Issue could not be fetched") unless issue_status.success?
  live_issue = parse_object(issue_output, "live Issue")
  exact_keys!(live_issue, %w[number url body labels], "live Issue")
  refuse("live Issue number or URL differs from caller") unless live_issue["number"] == issue && live_issue["url"] == "https://github.com/#{repository}/issues/#{issue}"
  labels = live_issue["labels"]
  refuse("live Issue labels must be an array") unless labels.is_a?(Array) && labels.all? { |label| label.is_a?(Hash) && label["name"].is_a?(String) }
  type_labels = labels.map { |label| label["name"] }.select { |name| %w[type:feature type:regression type:docs type:release].include?(name) }
  refuse("live Issue must have exactly one supported type label") unless type_labels.length == 1
  issue_type = type_labels.first.delete_prefix("type:")
  parsed_contract = IOSTemplate::IssueContract.parse(
    live_issue["body"], issue_type: issue_type, issue: issue,
    repository: repository, fetched_at: contract["fetchedAt"]
  )
  reconstructed_contract = parsed_contract.contract
  reconstructed_bytes = JSON.generate(canonical(reconstructed_contract))
  refuse("live Issue contract bytes differ from the canonical snapshot") unless reconstructed_bytes.b == contract_file.bytes.b
  parsed_contract.external_operation_details.each { |detail| operation_details[detail.fetch("operation")] = detail }
  refuse("live Issue operation details differ from the contract") if operation_details.any? { |_, detail| detail.nil? }

  provider_files.each do |provider, held|
    value = parse_object(held.bytes, "#{provider} provider preflight")
    exact_keys!(value, %w[schemaVersion issue executor provider account target environment operation health checkedAt digest], "#{provider} provider preflight")
    operation = value["operation"]
    detail = operation_details[operation]
    refuse("#{provider} provider operation does not match the Issue contract") unless detail && operation.split(".", 2).first == (provider == "app-store" ? "appstore" : provider)
    refuse("#{provider} provider identity is invalid") unless value["schemaVersion"] == 2 && value["issue"] == issue && value["provider"] == provider && value["health"] == "healthy"
    refuse("#{provider} provider executor differs from the Issue contract") unless value["executor"] == detail.fetch("executor").downcase
    safe_identifier!(value["account"], "#{provider} provider account")
    safe_identifier!(value["target"], "#{provider} provider target")
    expected_provider_identity = IOSTemplate::Ownership.provider_identity!(ownership, provider)
    refuse("#{provider} provider account differs from Config ownership") unless value["account"] == expected_provider_identity.fetch("account")
    refuse("#{provider} provider target differs from Config ownership") unless value["target"] == expected_provider_identity.fetch("target")
    refuse("#{provider} provider environment differs from the Issue contract") unless value["environment"] == detail.fetch("environment")
    checked_at = iso8601!(value["checkedAt"], "#{provider} provider checkedAt")
    refuse("#{provider} provider preflight predates the Issue contract") if checked_at < iso8601!(contract["fetchedAt"], "issue contract fetchedAt")
    refuse("#{provider} provider preflight is implausibly in the future") if checked_at > Time.now.utc + 300
    unsigned = value.reject { |key, _| key == "digest" }
    expected_digest = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(unsigned)))}"
    refuse("#{provider} provider digest is invalid") unless value["digest"] == expected_digest
  end

  verify = parse_object(verify_file.bytes, "verify.json")
  base_sha = identity.fetch("baseSha")
  actual_diff_bytes = IOSTemplate::ReviewContract.actual_diff(repo: root, base_sha: base_sha, head_sha: head_sha)
  verify_digest = "sha256:#{Digest::SHA256.hexdigest(verify_file.bytes)}"
  validator_output, validator_status = Open3.capture2e(
    "swift", "tools/validate-verify-json.swift", "--file", ".artifacts/issues/#{issue}/#{head_sha}/verify.json",
    "--expected-file-digest", verify_digest, "--expected-issue", issue.to_s,
    "--expected-base", base_sha, "--expected-head", head_sha, chdir: root
  )
  refuse("verify.json does not satisfy the canonical verification contract: #{validator_output.strip}") unless validator_status.success?

  completed_at = iso8601!(verify.fetch("completedAt"), "verify.completedAt")
  reviewed_at = completed_at
  if review_required
    review_values = IOSTemplate::ReviewContract.validate!(
      packet_bytes: packet_file.bytes, result_bytes: review_file.bytes,
      verify_bytes: verify_file.bytes, contract_bytes: contract_file.bytes,
      primary: state.fetch("primaryImplementer"), issue: issue, base_sha: base_sha, head_sha: head_sha,
      require_temporal_order: true, strict: true,
      diff_bytes: diff_file.bytes,
      image_bytes: image_files.transform_values(&:bytes),
      actual_diff_bytes: actual_diff_bytes
    )
    refuse("opposite-model review is not approved") unless review_values.fetch("result").fetch("verdict") == "approved"
    IOSTemplate::ReviewReceipt.validate!(
      receipt_bytes: receipt_file.bytes, packet_bytes: packet_file.bytes, review_bytes: review_file.bytes,
      repo: root, primary: state.fetch("primaryImplementer"), issue: issue, head_sha: head_sha
    )
    reviewed_at = iso8601!(review_values.fetch("result").fetch("reviewedAt"), "review.reviewedAt")
  end

  expected_account = IOSTemplate::Ownership.github_login!(ownership)
  refuse("configured GitHub account differs from this repository owner") unless expected_account == repository.split("/", 2).first
  preflight = parse_object(preflight_file.bytes, "github-preflight.json")
  exact_keys!(preflight, %w[account repository defaultBranch url intendedOperation issue headSha checkedAt digest], "github-preflight.json")
  refuse("GitHub preflight identity differs from the merge request") unless
    preflight["account"] == expected_account && preflight["repository"] == repository &&
    preflight["defaultBranch"] == "main" && preflight["url"] == "https://github.com/#{repository}" &&
    preflight["intendedOperation"] == "github.merge_pr" && preflight["issue"] == issue && preflight["headSha"] == head_sha
  unsigned_preflight = preflight.reject { |key, _| key == "digest" }
  expected_preflight_digest = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(unsigned_preflight)))}"
  refuse("GitHub preflight digest is invalid") unless preflight["digest"] == expected_preflight_digest
  preflight_at = iso8601!(preflight["checkedAt"], "github-preflight.checkedAt")
  refuse("GitHub preflight is not fresher than merge evidence and approval") unless preflight_at > completed_at && preflight_at > reviewed_at && preflight_at > transitioned_at
  refuse("GitHub preflight is implausibly in the future") if preflight_at > Time.now.utc + 300

  verify_lease = lambda do
    refuse("actual Base..Head diff changed while Gate was running") unless
      IOSTemplate::ReviewContract.actual_diff(repo: root, base_sha: base_sha, head_sha: head_sha) == actual_diff_bytes
    artifact_snapshots.verify!
    source_snapshots.verify!
  end
  verify_lease.call

  if merge_pr
    auth_output, auth_status = Open3.capture2e("gh", "auth", "status", "--active")
    refuse("active GitHub authentication could not be refreshed inside the merge lease") unless auth_status.success?
    active_account = auth_output[/account\s+([^\s(]+)/, 1]
    refuse("active GitHub account changed inside the merge lease") unless active_account == expected_account
    repo_output, repo_status = Open3.capture2e("gh", "repo", "view", repository, "--json", "nameWithOwner,defaultBranchRef,url")
    refuse("repository identity could not be refreshed inside the merge lease") unless repo_status.success?
    live_repository = parse_object(repo_output, "merge-lease repository")
    exact_keys!(live_repository, %w[nameWithOwner defaultBranchRef url], "merge-lease repository")
    exact_keys!(live_repository["defaultBranchRef"], %w[name], "merge-lease repository.defaultBranchRef")
    refuse("repository identity changed inside the merge lease") unless live_repository["nameWithOwner"] == repository && live_repository.dig("defaultBranchRef", "name") == "main" && live_repository["url"] == "https://github.com/#{repository}"
    pr_fields = "number,state,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,closingIssuesReferences,mergeCommit,url"
    pr_output, pr_status = Open3.capture2e("gh", "pr", "view", merge_pr.to_s, "--repo", repository, "--json", pr_fields)
    refuse("final PR identity could not be refreshed") unless pr_status.success?
    pr = parse_object(pr_output, "final PR")
    exact_keys!(pr, pr_fields.split(","), "final PR")
    closing = pr["closingIssuesReferences"]
    refuse("final PR head repository shape differs") unless pr["headRepository"].is_a?(Hash) && pr["headRepositoryOwner"].is_a?(Hash)
    refuse("final PR closing Issue shape differs") unless closing.is_a?(Array) && closing.length == 1
    refuse("final PR closing Issue shape differs") unless closing[0].is_a?(Hash) && closing[0]["repository"].is_a?(Hash)
    repository_owner, repository_name = repository.split("/", 2)
    refuse("final PR identity differs from the merge lease") unless
      pr["number"] == merge_pr && pr["state"] == "OPEN" && pr["baseRefName"] == "main" &&
      pr["headRefName"] == identity.fetch("branch") && pr["headRefOid"] == head_sha &&
      pr["isCrossRepository"] == false && pr.dig("headRepository", "nameWithOwner") == repository &&
      pr.dig("headRepositoryOwner", "login") == repository_owner && pr["mergeCommit"].nil? &&
      pr["url"] == "https://github.com/#{repository}/pull/#{merge_pr}" &&
      closing[0]["number"] == issue && closing[0]["url"] == "https://github.com/#{repository}/issues/#{issue}" &&
      closing[0].dig("repository", "name") == repository_name &&
      closing[0].dig("repository", "owner", "login") == repository_owner
    verify_lease.call
    merged = system("gh", "pr", "merge", merge_pr.to_s, "--repo", repository, "--squash", "--match-head-commit", head_sha)
    refuse("exact squash merge failed") unless merged
    puts JSON.generate({"status" => "merge-submitted", "issue" => issue, "pullRequest" => merge_pr, "headSha" => head_sha, "issueContractDigest" => contract_digest})
  else
    puts JSON.generate({"status" => "passed", "issue" => issue, "headSha" => head_sha, "issueContractDigest" => contract_digest})
  end
rescue IOSTemplate::IssueContract::ValidationError => error
  refuse("live Issue is invalid: #{error.failures.join('; ')}")
rescue IOSTemplate::Ownership::ValidationError => error
  refuse("Config ownership is invalid: #{error.message}")
rescue IOSTemplate::ReviewContract::ValidationError => error
  refuse("review contract is invalid: #{error.message}")
rescue IOSTemplate::ReviewReceipt::ValidationError => error
  refuse("review receipt is invalid: #{error.message}")
rescue KeyError, JSON::ParserError, SystemCallError, IOError, ArgumentError => error
  refuse("descriptor-bound validation failed: #{error.message}")
ensure
  artifact_snapshots.close
  source_snapshots.close
end
