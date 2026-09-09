#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "open3"
require_relative "descriptor-files"
require_relative "issue-contract"
require_relative "delivery-profile"

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

def validate_state(root, repository, issue, mode, recover_missing_pr: false)
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
  refuse("state executor must match the primary implementer") unless state["executor"] == expected_model
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
  IOSTemplate::IssueContract.validate_snapshot!(contract, issue: issue, repository: repository)

  state_name = state["state"]
  case state_name
  when "approved-for-merge"
    expected_previous = IOSTemplate::DeliveryProfile.review_required?(contract) ? "review-requested" : "verify-passed"
    refuse("approved state history is invalid") unless state["previousState"] == expected_previous && state["resumeState"].nil? && state["from"] == expected_previous && state["to"] == "approved-for-merge"
  when "merged"
    refuse("merged state history is invalid") unless state["previousState"] == "approved-for-merge" && state["resumeState"].nil? && state["from"] == "approved-for-merge" && state["to"] == "merged"
    positive_integer!(state["pullRequest"], "merged state pullRequest") unless recover_missing_pr && state["pullRequest"].nil?
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
    "stateMetadata" => {
      "dev" => state_stat.dev, "ino" => state_stat.ino, "size" => state_stat.size,
      "mode" => state_stat.mode, "nlink" => state_stat.nlink,
      "uid" => state_stat.uid, "gid" => state_stat.gid,
      "mtimeSec" => state_stat.mtime.to_i, "mtimeNsec" => state_stat.mtime.nsec
    },
    "primaryRoot" => primary,
    "worktreePath" => expected_worktree,
    "worktreePresent" => File.directory?(expected_worktree) && !File.symlink?(expected_worktree),
    "state" => state_name,
    "repository" => repository,
    "issue" => issue,
    "branch" => branch,
    "worktree" => worktree,
    "primaryImplementer" => state.fetch("primaryImplementer"),
    "baseSha" => base,
    "headSha" => head,
    "pullRequest" => state["pullRequest"],
    "contractDigest" => contract_digest,
    "externalOperations" => contract.fetch("externalOperations"),
    "title" => "Issue ##{issue}: #{title_goal}"
  }
  if recover_missing_pr
    refuse("PR recovery requires durable merged state") unless state_name == "merged"
    result["transitionedAt"] = state.fetch("transitionedAt")
    result["contract"] = contract
  end
  handles.reverse_each { |handle| handle.close unless handle.closed? }
  result
rescue IOSTemplate::IssueContract::ValidationError => error
  refuse("Issue contract is invalid: #{error.failures.join('; ')}")
rescue JSON::ParserError => error
  refuse("Issue contract is not valid JSON: #{error.message}")
rescue IOError, SystemCallError, ArgumentError => error
  refuse("descriptor-bound Issue identity is unavailable: #{error.message}")
ensure
  contract_io&.close unless contract_io&.closed?
  state_io&.close unless state_io&.closed?
  handles&.reverse_each { |handle| handle.close unless handle.closed? }
end

def atomic_update_state(identity, guard: nil)
  handles = DescriptorFiles.open_components(identity.fetch("primaryRoot"), [".artifacts", "issues", identity.fetch("issue").to_s])
  directory = handles.last
  directory.flock(File::LOCK_EX)
  state_io, original_stat = DescriptorFiles.open_regular_at(directory, "state.json")
  state_io.flock(File::LOCK_EX)
  bytes = DescriptorFiles.read_opened(state_io, original_stat)
  digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
  metadata = identity.fetch("stateMetadata")
  exact_metadata = metadata == {
    "dev" => original_stat.dev, "ino" => original_stat.ino, "size" => original_stat.size,
    "mode" => original_stat.mode, "nlink" => original_stat.nlink,
    "uid" => original_stat.uid, "gid" => original_stat.gid,
    "mtimeSec" => original_stat.mtime.to_i, "mtimeNsec" => original_stat.mtime.nsec
  }
  refuse("durable state bytes or metadata changed after validation") unless digest == identity.fetch("stateDigest") && exact_metadata
  guard&.call
  value = JSON.parse(bytes)
  yield value
  published_bytes = JSON.generate(value)
  guard&.call
  published_stat = DescriptorFiles.atomic_replace_at(directory, "state.json", published_bytes, bytes, original_stat)
  if guard
    begin
      guard.call
    rescue StandardError
      # Undo only our exact publication. Never overwrite a concurrent writer.
      current_bytes, current_stat = DescriptorFiles.read_regular_at(directory, "state.json")
      raise IOError, "state changed after guarded publication" unless current_bytes == published_bytes && DescriptorFiles.metadata_equal?(published_stat, current_stat)
      DescriptorFiles.atomic_replace_at(directory, "state.json", bytes, current_bytes, current_stat)
      raise IOError, "recovery inputs changed during publication; PR binding rolled back"
    end
  end
  value
rescue JSON::ParserError, IOError, SystemCallError, ArgumentError => error
  refuse("descriptor-bound state publication failed: #{error.message}")
ensure
  state_io&.close unless state_io&.closed?
  handles&.reverse_each { |handle| handle.close unless handle.closed? }
end

def recovery_command(root, stage, *arguments, input: "", timeout: 120)
  output, _error, status = Open3.capture3(
    "/usr/bin/ruby", File.join(root, "tools/lib/bounded-command.rb"),
    "--stage", stage, "--timeout-seconds", timeout.to_s, "--", *arguments,
    stdin_data: input, chdir: root
  )
  refuse("#{stage} failed; no PR binding was published") unless status.success?
  output
rescue SystemCallError, IOError
  refuse("#{stage} unavailable; no PR binding was published")
end

def recovery_git_identity!(root, identity)
  git = ->(*arguments) { recovery_command(root, "recovery-git", "git", "-C", root, *arguments, timeout: 30).strip }
  refuse("recovery Git top-level differs") unless git.call("rev-parse", "--show-toplevel") == root
  refuse("recovery Git common directory differs") unless git.call("rev-parse", "--path-format=absolute", "--git-common-dir") == File.join(identity.fetch("primaryRoot"), ".git")
  refuse("recovery Branch differs") unless git.call("branch", "--show-current") == identity.fetch("branch")
  refuse("recovery Head or raw Branch ref differs") unless git.call("rev-parse", "HEAD") == identity.fetch("headSha") && git.call("rev-parse", "refs/heads/#{identity.fetch('branch')}") == identity.fetch("headSha")
  %w[baseSha headSha].each { |key| refuse("recovery #{key} is not a commit") unless git.call("cat-file", "-t", identity.fetch(key)) == "commit" }
  git.call("merge-base", "--is-ancestor", identity.fetch("baseSha"), identity.fetch("headSha"))
  refuse("recovery worktree is dirty") unless git.call("status", "--porcelain").empty?
  repository = identity.fetch("repository")
  origins = ["https://github.com/#{repository}", "https://github.com/#{repository}.git", "git@github.com:#{repository}", "git@github.com:#{repository}.git", "ssh://git@github.com/#{repository}", "ssh://git@github.com/#{repository}.git"]
  refuse("recovery origin differs") unless origins.include?(git.call("remote", "get-url", "origin"))
end

def recovery_preflight!(root, identity)
  refuse("sealed contract does not authorize PR inspection") unless identity.fetch("externalOperations").include?("github.read_issue")
  JSON.parse(recovery_command(root, "recovery-account", File.join(root, "tools/github-account-preflight.sh"),
    "--repo", identity.fetch("repository"), "--issue", identity.fetch("issue").to_s,
    "--intended-operation", "github.read_issue", "--expected-head", identity.fetch("headSha")))
end

def recover_merged_pr(root, repository, issue, pr, expected_head)
  require_relative "review-sealing"
  identity = validate_state(root, repository, issue, "worktree", recover_missing_pr: true)
  root = identity.fetch("worktreePath")
  snapshots = IOSTemplate::ReviewSealing::SnapshotSet.new(identity.fetch("primaryRoot"), at: "recovery primary")
  held_contract = snapshots.relative_leaf(".artifacts/issues/#{issue}/issue-contract.json", at: "recovery contract")
  snapshots.relative_leaf("#{identity.fetch('worktree')}/Config/ownership.yml", at: "recovery ownership")
  snapshots.relative_leaf("#{identity.fetch('worktree')}/.git", at: "recovery Git link")
  refuse("held recovery contract differs") unless "sha256:#{Digest::SHA256.hexdigest(held_contract.bytes)}" == identity.fetch("contractDigest")
  guard = lambda do
    root_stat = File.lstat(identity.fetch("primaryRoot"))
    held_root = snapshots.root.stat
    raise IOError, "recovery primary identity changed" unless root_stat.directory? && !root_stat.symlink? && [root_stat.dev, root_stat.ino] == [held_root.dev, held_root.ino]
    snapshots.verify!
  end
  guard.call
  refuse("requested recovery Head differs") unless identity.fetch("headSha") == expected_head
  refuse("existing PR binding conflicts") unless identity["pullRequest"].nil? || identity["pullRequest"] == pr
  recovery_git_identity!(root, identity)
  preflight = recovery_preflight!(root, identity)
  owner = preflight.fetch("account")
  refuse("recovery preflight target differs") unless preflight["repository"] == repository && preflight["issue"] == issue && preflight["headSha"] == expected_head && preflight["defaultBranch"] == "main" && preflight["intendedOperation"] == "github.read_issue"
  issue_bytes = recovery_command(root, "recovery-issue-read", "gh", "issue", "view", issue.to_s, "--repo", repository,
    "--json", "number,state,url,body,labels,comments")
  live = JSON.parse(issue_bytes)
  exact_keys!(live, %w[number state url body labels comments], [], "recovery live Issue")
  refuse("recovery Issue is not exactly closed") unless live["number"] == issue && live["state"] == "CLOSED" && live["url"] == "https://github.com/#{repository}/issues/#{issue}"
  helper = File.join(root, "tools/lib/workflow-json.rb")
  state = recovery_command(root, "recovery-workflow-label", "/usr/bin/ruby", helper, "state-from-issue", input: issue_bytes).strip
  refuse("remote workflow is not merged") unless state == "merged"
  marker = JSON.parse(recovery_command(root, "recovery-owned-history", "/usr/bin/ruby", helper, "latest-state-marker", "merged", owner, input: issue_bytes))
  expected_marker = {"executor"=>identity.fetch("primaryImplementer"), "from"=>"approved-for-merge", "to"=>"merged", "resumeState"=>nil, "timestamp"=>identity.fetch("transitionedAt")}
  refuse("remote owned transition differs from durable history") unless marker == expected_marker
  types = live.fetch("labels").map { |label| label["name"].delete_prefix("type:") if label.is_a?(Hash) && label["name"].is_a?(String) && label["name"].start_with?("type:") }.compact
  refuse("remote Issue type is ambiguous") if types.length > 1
  parsed = IOSTemplate::IssueContract.parse(live.fetch("body"), issue_type: types.fetch(0, "feature"), issue: issue,
    repository: repository, fetched_at: identity.fetch("contract").fetch("fetchedAt"), allow_legacy_delivery_stage: true)
  refuse("live operation authority differs from sealed contract") unless parsed.contract.fetch("externalOperationDetailsDigest") == identity.fetch("contract").fetch("externalOperationDetailsDigest")
  permission = parsed.external_operation_details.find { |entry| entry["operation"] == "github.read_issue" }
  refuse("live PR read executor differs") unless permission && permission["executor"].downcase == identity.fetch("primaryImplementer") && permission["environment"] == "production"

  recovery_preflight!(root, identity)
  fields = %w[number state baseRefName headRefName headRefOid headRepository headRepositoryOwner isCrossRepository closingIssuesReferences mergeCommit url]
  document = JSON.parse(recovery_command(root, "recovery-pr-read", "gh", "pr", "view", pr.to_s, "--repo", repository, "--json", fields.join(",")))
  exact_keys!(document, fields, [], "recovery PR")
  refuse("recovery PR number, URL or merged state differs") unless document["number"] == pr && document["url"] == "https://github.com/#{repository}/pull/#{pr}" && document["state"] == "MERGED"
  refuse("recovery PR Base, Branch or Head differs") unless document["baseRefName"] == "main" && document["headRefName"] == identity.fetch("branch") && document["headRefOid"] == expected_head
  target_owner, target_name = repository.split("/", 2)
  refuse("recovery PR source repository differs") unless document["isCrossRepository"] == false && document.dig("headRepository", "nameWithOwner") == repository && document.dig("headRepositoryOwner", "login") == target_owner
  closing = document["closingIssuesReferences"]
  refuse("recovery PR does not close exactly this Issue") unless closing.is_a?(Array) && closing.length == 1 && closing[0].is_a?(Hash) && closing[0]["number"] == issue && closing[0]["url"] == "https://github.com/#{repository}/issues/#{issue}" && closing[0].dig("repository", "name") == target_name && closing[0].dig("repository", "owner", "login") == target_owner
  sha!(document.dig("mergeCommit", "oid"), "recovery merge commit")

  recovery_git_identity!(root, identity)
  refreshed = validate_state(root, repository, issue, "worktree", recover_missing_pr: true)
  refuse("durable identity changed during remote inspection") unless refreshed == identity
  value = atomic_update_state(identity, guard: guard) do |current|
    refuse("PR binding changed before recovery publication") unless current["pullRequest"].nil? || current["pullRequest"] == pr
    current["pullRequest"] = pr
  end
  {"status"=>"recorded", "issue"=>issue, "pullRequest"=>value.fetch("pullRequest"), "headSha"=>expected_head}
rescue JSON::ParserError, KeyError, TypeError, NoMethodError, IOError, SystemCallError, IOSTemplate::IssueContract::ValidationError, IOSTemplate::ReviewSealing::SealError
  refuse("invalid remote recovery evidence or authority")
ensure
  snapshots&.close
end

command = ARGV.shift
case command
when "recover-merged-pr"
  root, repository, issue_text, pr_text, head = ARGV
  refuse("invalid recovery arguments") unless ARGV.length == 5 && issue_text&.match?(/\A[1-9][0-9]*\z/) && pr_text&.match?(/\A[1-9][0-9]*\z/)
  sha!(head, "requested recovery Head")
  puts JSON.generate(recover_merged_pr(root, repository, Integer(issue_text), Integer(pr_text), head))
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
