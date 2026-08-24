#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "descriptor-files"

def refuse(message)
  warn "merge identity refused: #{message}"
  exit 1
end

def exact_keys!(value, required, optional, at)
  refuse("#{at} must be an object") unless value.is_a?(Hash)
  keys = value.keys
  refuse("#{at} has unknown or missing fields") unless (keys - required - optional).empty? && required.all? { |key| value.key?(key) }
end

def ensure_plain_directory!(path, at)
  stat = File.lstat(path)
  refuse("#{at} must be a real directory") unless stat.directory? && !stat.symlink?
rescue Errno::ENOENT, Errno::EACCES => error
  refuse("#{at} is unavailable: #{error.message}")
end

def repository!(value, at)
  refuse("#{at} is invalid") unless value.is_a?(String) && value.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
  value
end

def sha!(value, at)
  refuse("#{at} is invalid") unless value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)
  value
end

def digest!(value, at)
  refuse("#{at} is invalid") unless value.is_a?(String) && value.match?(/\Asha256:[0-9a-f]{64}\z/)
  value
end

def positive_integer!(value, at)
  refuse("#{at} must be a positive integer") unless value.is_a?(Integer) && value.positive?
  value
end

def canonical_topology(root, issue, mode)
  root = File.realpath(root)
  if mode == "worktree"
    link = File.join(root, ".artifacts")
    refuse(".artifacts must be the canonical raw link") unless File.symlink?(link) && File.readlink(link) == "../../.artifacts"
    primary = File.realpath(File.join(root, "..", ".."))
    refuse("worktree is outside the canonical .worktrees directory") unless root.start_with?(File.join(primary, ".worktrees") + File::SEPARATOR)
    ensure_plain_directory!(File.join(primary, ".artifacts"), "primary .artifacts")
    ensure_plain_directory!(File.join(primary, ".worktrees"), "primary .worktrees")
    refuse(".artifacts link does not resolve to the primary store") unless File.realpath(link) == File.join(primary, ".artifacts")
    git_file = File.lstat(File.join(root, ".git"))
    refuse("worktree .git file is unsafe") unless git_file.file? && !git_file.symlink? && git_file.nlink == 1
  else
    primary = root
    ensure_plain_directory!(File.join(primary, ".artifacts"), "primary .artifacts")
    ensure_plain_directory!(File.join(primary, ".worktrees"), "primary .worktrees")
  end
  issue_dir = File.join(primary, ".artifacts", "issues", issue.to_s)
  handles = DescriptorFiles.open_components(primary, [".artifacts", "issues", issue.to_s])
  [root, primary, issue_dir, handles]
end

def validate_state(root, repository, issue, mode)
  repository!(repository, "requested repository")
  positive_integer!(issue, "requested Issue")
  root, primary, issue_dir, handles = canonical_topology(root, issue, mode)
  issue_handle = handles.last
  issue_handle.flock(File::LOCK_SH)
  state_path = File.join(issue_dir, "state.json")
  state_io, state_stat = DescriptorFiles.open_regular_at(issue_handle, "state.json")
  state_io.flock(File::LOCK_SH)
  state_bytes = DescriptorFiles.read_opened(state_io, state_stat)
  state = JSON.parse(state_bytes)
  required = %w[schemaVersion issue repository branch worktree baseSha primaryImplementer issueContract state previousState resumeState executor]
  optional = %w[headSha pullRequest from to transitionedAt]
  exact_keys!(state, required, optional, "durable Issue state")
  refuse("state.schemaVersion must be 1") unless state["schemaVersion"] == 1
  refuse("state Issue or repository differs from the request") unless state["issue"] == issue && state["repository"] == repository
  branch = state["branch"]
  worktree = state["worktree"]
  branch_match = branch.match(%r{\A(codex|claude)/#{issue}-([a-z0-9][a-z0-9-]*)\z}) if branch.is_a?(String)
  worktree_match = worktree.match(%r{\A\.worktrees/#{issue}-([a-z0-9][a-z0-9-]*)\z}) if worktree.is_a?(String)
  refuse("state Branch is noncanonical") unless branch_match
  refuse("state worktree is noncanonical") unless worktree_match
  refuse("state Branch and worktree slugs differ") unless branch_match[2] == worktree_match[1]
  expected_model = branch.start_with?("codex/") ? "codex" : "claude"
  refuse("state primary implementer differs from Branch ownership") unless state["primaryImplementer"] == expected_model
  refuse("state executor must be Codex") unless state["executor"] == "codex"
  base = sha!(state["baseSha"], "state.baseSha")
  head = sha!(state["headSha"], "state.headSha")
  contract_ref = state["issueContract"]
  exact_keys!(contract_ref, %w[path digest], [], "state.issueContract")
  expected_contract_path = ".artifacts/issues/#{issue}/issue-contract.json"
  refuse("state issue-contract path is noncanonical") unless contract_ref["path"] == expected_contract_path
  contract_digest = digest!(contract_ref["digest"], "state issue-contract digest")
  contract_path = File.join(issue_dir, "issue-contract.json")
  contract_io, contract_stat = DescriptorFiles.open_regular_at(issue_handle, "issue-contract.json")
  contract_bytes = DescriptorFiles.read_opened(contract_io, contract_stat)
  refuse("state issue-contract digest differs from exact bytes") unless contract_digest == "sha256:#{Digest::SHA256.hexdigest(contract_bytes)}"
  contract = JSON.parse(contract_bytes)
  refuse("Issue contract identity differs from durable state") unless contract.is_a?(Hash) && contract["schemaVersion"] == 1 && contract["issue"] == issue && contract["repository"] == repository
  refuse("Issue contract goal is missing") unless contract["goal"].is_a?(String) && !contract["goal"].strip.empty?
  anchors = contract["specAnchors"]
  refuse("Issue contract spec anchors are missing") unless anchors.is_a?(Array) && !anchors.empty? && anchors.all? { |entry| entry.is_a?(String) && !entry.empty? } && anchors.uniq == anchors

  state_name = state["state"]
  case state_name
  when "approved-for-merge"
    refuse("approved state history is invalid") unless state["previousState"] == "review-requested" && state["resumeState"].nil? && state["from"] == "review-requested" && state["to"] == "approved-for-merge"
  when "merged"
    refuse("merged state history is invalid") unless state["previousState"] == "approved-for-merge" && state["resumeState"].nil? && state["from"] == "approved-for-merge" && state["to"] == "merged"
    positive_integer!(state["pullRequest"], "merged state pullRequest")
  else
    refuse("state must be approved-for-merge or merged")
  end
  refuse("state transition timestamp is missing") unless state.key?("transitionedAt")
  if state.key?("pullRequest") && !state["pullRequest"].nil?
    positive_integer!(state["pullRequest"], "state.pullRequest")
  end
  if state.key?("transitionedAt")
    begin
      transitioned_at = Time.iso8601(state["transitionedAt"])
      refuse("state transition time is implausibly in the future") if transitioned_at > Time.now + 300
    rescue ArgumentError, TypeError
      refuse("state.transitionedAt is invalid")
    end
  end
  expected_worktree = File.join(primary, worktree)
  if mode == "worktree"
    refuse("current path differs from the durable worktree") unless root == expected_worktree
  elsif File.exist?(expected_worktree) || File.symlink?(expected_worktree)
    stat = File.lstat(expected_worktree)
    refuse("recorded worktree is unsafe") unless stat.directory? && !stat.symlink?
  end
  title_goal = contract["goal"].gsub(/\s+/, " ").strip
  title_goal = title_goal.byteslice(0, 180).to_s.scrub
  result = {
    "statePath" => state_path,
    "stateDigest" => "sha256:#{Digest::SHA256.hexdigest(state_bytes)}",
    "stateMetadata" => {"dev" => state_stat.dev, "ino" => state_stat.ino, "size" => state_stat.size, "mode" => state_stat.mode, "nlink" => state_stat.nlink, "mtimeSec" => state_stat.mtime.to_i, "mtimeNsec" => state_stat.mtime.nsec, "ctimeSec" => state_stat.ctime.to_i, "ctimeNsec" => state_stat.ctime.nsec},
    "primaryRoot" => primary,
    "worktreePath" => expected_worktree,
    "worktreePresent" => File.directory?(expected_worktree) && !File.symlink?(expected_worktree),
    "state" => state_name,
    "repository" => repository,
    "issue" => issue,
    "branch" => branch,
    "worktree" => worktree,
    "baseSha" => base,
    "headSha" => head,
    "pullRequest" => state["pullRequest"],
    "contractDigest" => contract_digest,
    "title" => "Issue ##{issue}: #{title_goal}"
  }
  handles.reverse_each { |handle| handle.close unless handle.closed? }
  result
rescue JSON::ParserError => error
  refuse("Issue contract is not valid JSON: #{error.message}")
rescue IOError, SystemCallError, ArgumentError => error
  refuse("descriptor-bound Issue identity is unavailable: #{error.message}")
ensure
  contract_io&.close unless contract_io&.closed?
  state_io&.close unless state_io&.closed?
  handles&.reverse_each { |handle| handle.close unless handle.closed? }
end

def atomic_update_state(identity)
  handles = DescriptorFiles.open_components(identity.fetch("primaryRoot"), [".artifacts", "issues", identity.fetch("issue").to_s])
  directory = handles.last
  directory.flock(File::LOCK_EX)
  state_io, original_stat = DescriptorFiles.open_regular_at(directory, "state.json")
  state_io.flock(File::LOCK_EX)
  bytes = DescriptorFiles.read_opened(state_io, original_stat)
  digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
  metadata = identity.fetch("stateMetadata")
  exact_metadata = metadata["dev"] == original_stat.dev && metadata["ino"] == original_stat.ino && metadata["size"] == original_stat.size && metadata["mode"] == original_stat.mode && metadata["nlink"] == original_stat.nlink && metadata["mtimeSec"] == original_stat.mtime.to_i && metadata["mtimeNsec"] == original_stat.mtime.nsec && metadata["ctimeSec"] == original_stat.ctime.to_i && metadata["ctimeNsec"] == original_stat.ctime.nsec
  refuse("durable state bytes or metadata changed after validation") unless digest == identity.fetch("stateDigest") && exact_metadata
  value = JSON.parse(bytes)
  yield value
  DescriptorFiles.atomic_replace_at(directory, "state.json", JSON.generate(value), bytes, original_stat)
  value
rescue JSON::ParserError, IOError, SystemCallError, ArgumentError => error
  refuse("descriptor-bound state publication failed: #{error.message}")
ensure
  state_io&.close unless state_io&.closed?
  handles&.reverse_each { |handle| handle.close unless handle.closed? }
end

command = ARGV.shift
case command
when "validate-worktree", "validate-primary"
  root, repository, issue_text = ARGV
  refuse("invalid arguments") unless root && repository && issue_text&.match?(/\A[1-9][0-9]*\z/)
  puts JSON.generate(validate_state(root, repository, Integer(issue_text), command == "validate-worktree" ? "worktree" : "primary"))
when "persist-pr"
  root, repository, issue_text, pr_text = ARGV
  refuse("invalid arguments") unless issue_text&.match?(/\A[1-9][0-9]*\z/) && pr_text&.match?(/\A[1-9][0-9]*\z/)
  identity = validate_state(root, repository, Integer(issue_text), "worktree")
  refuse("pullRequest cannot first be persisted after durable merged state") if identity["state"] == "merged" && identity["pullRequest"] != Integer(pr_text)
  value = atomic_update_state(identity) do |state|
    refuse("durable identity changed before pullRequest persistence") unless state["schemaVersion"] == 1 && state["issue"] == identity["issue"] && state["repository"] == identity["repository"] && state["branch"] == identity["branch"] && state["worktree"] == identity["worktree"] && state["baseSha"] == identity["baseSha"] && state["headSha"] == identity["headSha"] && state.dig("issueContract", "digest") == identity["contractDigest"] && state["state"] == identity["state"]
    existing = state["pullRequest"]
    refuse("persisted pullRequest differs from exact PR") if existing && existing != Integer(pr_text)
    state["pullRequest"] = Integer(pr_text)
  end
  puts JSON.generate(value)
when "mark-merged"
  root, repository, issue_text, pr_text, head, timestamp = ARGV
  refuse("invalid arguments") unless issue_text&.match?(/\A[1-9][0-9]*\z/) && pr_text&.match?(/\A[1-9][0-9]*\z/)
  identity = validate_state(root, repository, Integer(issue_text), "worktree")
  refuse("merged Head differs from durable Head") unless identity["headSha"] == head
  value = atomic_update_state(identity) do |state|
    refuse("durable identity changed before merged persistence") unless state["schemaVersion"] == 1 && state["issue"] == identity["issue"] && state["repository"] == identity["repository"] && state["branch"] == identity["branch"] && state["worktree"] == identity["worktree"] && state["baseSha"] == identity["baseSha"] && state["headSha"] == identity["headSha"] && state.dig("issueContract", "digest") == identity["contractDigest"] && state["state"] == identity["state"]
    refuse("persisted pullRequest differs from merged PR") if state["pullRequest"] && state["pullRequest"] != Integer(pr_text)
    if state["state"] == "approved-for-merge"
      begin
        transition_time = Time.iso8601(timestamp)
        refuse("transition time is implausibly in the future") if transition_time > Time.now + 300
      rescue ArgumentError, TypeError
        refuse("transition time is invalid")
      end
      state["state"] = "merged"
      state["previousState"] = "approved-for-merge"
      state["resumeState"] = nil
      state["from"] = "approved-for-merge"
      state["to"] = "merged"
      state["transitionedAt"] = timestamp
    end
    state["headSha"] = head
    state["pullRequest"] = Integer(pr_text)
  end
  puts JSON.generate(value)
else
  refuse("unknown command")
end
