# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "optparse"
require "time"
require_relative "descriptor-files"
require_relative "issue-contract"
require_relative "ownership"

module IOSTemplate
  module IssueContractRevision
    class ValidationError < StandardError; end

    DIGEST = /\Asha256:[0-9a-f]{64}\z/
    SHA = /\A[0-9a-f]{40}\z/
    REPOSITORY = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}
    USER_TRIGGERS = %w[user-explicit user-delegated].freeze
    TRIGGERS = (USER_TRIGGERS + %w[review-finding]).freeze
    SUBSTANTIVE_FIELDS = %w[acceptanceCriteria verification].freeze
    CHANGED_FIELDS = IssueContract::REVISION_MUTABLE_FIELDS.freeze
    INVALIDATED_EVIDENCE = %w[head-binding review verification].freeze
    REVISION_REFERENCE_KEYS = %w[digest path revision].freeze
    FILE_REFERENCE_KEYS = %w[digest path].freeze
    RECORD_KEYS = %w[
      schemaVersion issue repository issueType revision previousRevision previousRecord
      before after changedFields reason authority invalidatedEvidence retainedIdentity
      beforeState recordedAt
    ].freeze
    PENDING_KEYS = %w[
      schemaVersion issue repository revision record beforeContract afterContract
      beforeBody afterBody beforeState afterState request createdAt
    ].freeze
    AUTHORITY_KEYS = %w[actor delegate reference scope trigger].freeze
    RETAINED_IDENTITY_KEYS = %w[baseSha branch sourceHead worktree].freeze
    REQUEST_KEYS = %w[authorityReference delegate proposedBodyDigest reason trigger].freeze
    MARKER_KEYS = %w[
      afterBodyDigest beforeContractDigest delegate issue reason repository scope
      sourceHead trigger
    ].freeze
    MARKER_PATTERN = /<!-- ios-template-contract-revision (\{.*?\}) -->/m
    REVISION_ROOT = "issue-contract-revisions"
    PENDING_NAME = "issue-contract-revision.pending.json"

    module_function

    def reject(message)
      raise ValidationError, message
    end

    def canonical(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, output| output[key] = canonical(value.fetch(key)) }
      when Array
        value.map { |entry| canonical(entry) }
      else
        value
      end
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def digest(bytes)
      "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    end

    def parse_object(bytes, at)
      value = JSON.parse(bytes.dup)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      value
    rescue JSON::ParserError => error
      reject("#{at} is not valid JSON: #{error.message}")
    end

    def exact_keys!(value, keys, at)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      reject("#{at} has unknown or missing fields") unless value.keys.sort == keys.sort
      value
    end

    def nonempty_string!(value, at)
      reject("#{at} must be a nonempty string") unless value.is_a?(String) && !value.empty? && value == value.strip && !value.include?("\0")
      value
    end

    def digest!(value, at)
      reject("#{at} must be a sha256 digest") unless value.is_a?(String) && value.match?(DIGEST)
      value
    end

    def sha!(value, at)
      reject("#{at} must be a 40-character lowercase Git SHA") unless value.is_a?(String) && value.match?(SHA)
      value
    end

    def positive_integer!(value, at)
      reject("#{at} must be a positive integer") unless value.is_a?(Integer) && value.positive?
      value
    end

    def timestamp!(value, at)
      nonempty_string!(value, at)
      parsed = Time.iso8601(value).utc
      reject("#{at} must be canonical UTC ISO 8601 seconds") unless parsed.iso8601 == value
      parsed
    rescue ArgumentError
      reject("#{at} must be ISO 8601")
    end

    def repository!(value, at = "repository")
      reject("#{at} must be OWNER/REPO") unless value.is_a?(String) && value.match?(REPOSITORY)
      value
    end

    def topology!(repo_root, require_linked: false)
      root = File.realpath(repo_root)
      output, status = Open3.capture2e(
        {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil},
        "/usr/bin/ruby", File.join(root, "tools/lib/review-artifacts.rb"), root
      )
      reject("artifact topology is invalid: #{output.strip}") unless status.success?
      value = parse_object(output, "artifact topology")
      if require_linked
        reject("contract revision must run from the canonical Issue worktree") unless value.fetch("layout") == "linked"
      end
      value
    rescue Errno::ENOENT, Errno::EACCES, KeyError => error
      reject("artifact topology is unavailable: #{error.message}")
    end

    def artifact_relative!(path, issue, at)
      nonempty_string!(path, at)
      prefix = ".artifacts/issues/#{issue}/"
      reject("#{at} is outside the canonical Issue artifact directory") unless path.start_with?(prefix)
      components = path.split("/")
      reject("#{at} contains an unsafe component") if components.any? { |entry| entry.empty? || entry == "." || entry == ".." }
      path
    end

    def physical_file!(path, at)
      stat = File.lstat(path)
      reject("#{at} must be a regular single-link file") unless stat.file? && !stat.symlink? && stat.nlink == 1
      bytes = File.binread(path)
      final = File.lstat(path)
      reject("#{at} changed while read") unless
        [stat.dev, stat.ino, stat.size, stat.mode, stat.nlink, stat.mtime.to_r] ==
        [final.dev, final.ino, final.size, final.mode, final.nlink, final.mtime.to_r] && bytes.bytesize == final.size
      [bytes, final]
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
      reject("#{at} is unavailable: #{error.message}")
    end

    def artifact_loader(artifacts_root, issue)
      root = File.realpath(artifacts_root)
      lambda do |reference_path|
        artifact_relative!(reference_path, issue, "artifact reference")
        relative = reference_path.delete_prefix(".artifacts/")
        current = root
        parts = relative.split("/")
        parts.each_with_index do |part, index|
          current = File.join(current, part)
          stat = File.lstat(current)
          reject("artifact reference traverses a symlink") if stat.symlink?
          if index < parts.length - 1
            reject("artifact reference has a non-directory component") unless stat.directory?
          end
        end
        physical_file!(current, reference_path).first
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
        reject("artifact reference is unavailable: #{error.message}")
      end
    end

    def issue_paths(topology, issue)
      issue_root = File.join(topology.fetch("artifactsRoot"), "issues", issue.to_s)
      {
        "issueRoot" => issue_root,
        "contract" => File.join(issue_root, "issue-contract.json"),
        "state" => File.join(issue_root, "state.json"),
        "pending" => File.join(issue_root, PENDING_NAME)
      }
    end

    def reference!(value, at, revision: nil, expected_path: nil)
      keys = revision.nil? ? FILE_REFERENCE_KEYS : REVISION_REFERENCE_KEYS
      exact_keys!(value, keys, at)
      digest!(value["digest"], "#{at}.digest")
      nonempty_string!(value["path"], "#{at}.path")
      reject("#{at}.path differs") if expected_path && value["path"] != expected_path
      if revision
        positive_integer!(revision, "#{at}.revision")
        reject("#{at}.revision differs") unless value["revision"] == revision
      end
      value
    end

    def file_reference(path, bytes)
      {"path" => path, "digest" => digest(bytes)}
    end

    def revision_reference(path, bytes, revision)
      file_reference(path, bytes).merge("revision" => revision)
    end

    def load_reference!(loader, reference, at, expected_path: nil)
      revision = reference.is_a?(Hash) && reference.key?("revision") ? reference["revision"] : nil
      reference!(reference, at, revision: revision, expected_path: expected_path)
      bytes = loader.call(reference.fetch("path"))
      reject("#{at} digest differs from exact bytes") unless digest(bytes) == reference.fetch("digest")
      bytes
    end

    def canonical_contract!(bytes, issue, repository, at)
      contract = parse_object(bytes, at)
      IssueContract.validate_snapshot!(contract, issue: issue, repository: repository)
      reject("#{at} does not use canonical bytes") unless bytes.b == IssueContract.canonical_json(contract).b
      contract
    rescue IssueContract::ValidationError => error
      reject("#{at} is invalid: #{error.failures.join('; ')}")
    end

    def canonical_state!(bytes, issue, repository, at, require_canonical: true)
      value = parse_object(bytes, at)
      required = %w[
        baseSha branch executor issue issueContract previousState primaryImplementer
        repository resumeState schemaVersion state worktree
      ]
      optional = %w[from headSha issueContractRevision pullRequest to transitionedAt]
      reject("#{at} has unknown or missing fields") unless
        (value.keys - required - optional).empty? && required.all? { |key| value.key?(key) }
      reject("#{at} identity differs") unless value["schemaVersion"] == 1 && value["issue"] == issue && value["repository"] == repository
      sha!(value["baseSha"], "#{at}.baseSha")
      nonempty_string!(value["branch"], "#{at}.branch")
      nonempty_string!(value["worktree"], "#{at}.worktree")
      reject("#{at} branch or worktree is noncanonical") unless
        value["branch"].match?(%r{\A(codex|claude)/#{issue}-[a-z0-9][a-z0-9-]*\z}) &&
        value["worktree"] == ".worktrees/#{value.fetch('branch').split('/', 2).fetch(1)}"
      reject("#{at} implementer identity differs") unless
        %w[codex claude].include?(value["primaryImplementer"]) &&
        value["executor"] == value["primaryImplementer"] &&
        value["branch"].start_with?("#{value.fetch('primaryImplementer')}/")
      exact_keys!(value["issueContract"], %w[digest path], "#{at}.issueContract")
      reject("#{at} contract path is noncanonical") unless value.dig("issueContract", "path") == ".artifacts/issues/#{issue}/issue-contract.json"
      digest!(value.dig("issueContract", "digest"), "#{at}.issueContract.digest")
      sha!(value["headSha"], "#{at}.headSha") if value.key?("headSha")
      reject("#{at} state is invalid") unless value["state"].is_a?(String) && !value["state"].empty?
      canonical_bytes = canonical_json(value)
      if require_canonical
        reject("#{at} does not use canonical bytes") unless bytes == canonical_bytes || bytes == "#{canonical_bytes}\n"
      end
      value
    end

    def issue_type!(document)
      labels = document.fetch("labels")
      reject("live Issue labels are invalid") unless labels.is_a?(Array) && labels.all? { |entry| entry.is_a?(Hash) && entry["name"].is_a?(String) }
      values = labels.map { |entry| entry.fetch("name") }.select { |name| %w[type:feature type:regression type:docs type:release].include?(name) }
      reject("live Issue must have exactly one supported type label") unless values.length == 1
      values.first.delete_prefix("type:")
    rescue KeyError
      reject("live Issue labels are missing")
    end

    def live_issue!(document, issue, repository)
      reject("live Issue must be an object") unless document.is_a?(Hash)
      %w[number url body labels comments].each { |key| reject("live Issue is missing #{key}") unless document.key?(key) }
      reject("live Issue identity differs") unless
        document["number"] == issue && document["url"] == "https://github.com/#{repository}/issues/#{issue}"
      reject("live Issue body is invalid") unless document["body"].is_a?(String)
      labels = document.fetch("labels")
      states = labels.map do |label|
        name = label.is_a?(Hash) ? label["name"] : nil
        name&.start_with?("state:") ? name.delete_prefix("state:") : nil
      end.compact
      reject("contract revision requires the exact in-progress Issue state") unless states == ["in-progress"]
      reject("live Issue comments are invalid") unless document["comments"].is_a?(Array)
      issue_type!(document)
      document
    end

    def parse_body_contract!(body, issue_type:, issue:, repository:, fetched_at:, allow_legacy_delivery_stage:)
      body = body.dup.force_encoding(Encoding::UTF_8)
      reject("Issue body is not valid UTF-8") unless body.valid_encoding?
      result = IssueContract.parse(
        body, issue_type: issue_type, issue: issue, repository: repository,
        fetched_at: fetched_at, allow_legacy_delivery_stage: allow_legacy_delivery_stage
      )
      [result.contract, IssueContract.canonical_json(result.contract)]
    rescue IssueContract::ValidationError => error
      reject("revised Issue body is invalid: #{error.failures.join('; ')}")
    end

    def h2_parts(body)
      lines = body.lines
      offsets = []
      cursor = 0
      lines.each do |line|
        match = line.match(/\A##[ \t]+([^\r\n]+?)[ \t]*\r?\n?\z/)
        offsets << [match[1], cursor] if match
        cursor += line.bytesize
      end
      reject("Issue body must contain H2 sections") if offsets.empty?
      preamble = body.byteslice(0, offsets.first.fetch(1))
      sections = offsets.each_with_index.map do |(heading, start), index|
        finish = index + 1 < offsets.length ? offsets[index + 1].fetch(1) : body.bytesize
        [heading, body.byteslice(start, finish - start)]
      end
      [preamble, sections]
    end

    def allowed_body_delta!(before_body, after_body)
      before_preamble, before_sections = h2_parts(before_body)
      after_preamble, after_sections = h2_parts(after_body)
      reject("Issue preamble changed outside the revision scope") unless before_preamble == after_preamble
      allowed = ["Acceptance criteria", "Verification"]
      before_fixed = before_sections.reject { |heading, _| allowed.include?(heading) }
      after_fixed = after_sections.reject { |heading, _| allowed.include?(heading) }
      reject("Issue sections outside Acceptance criteria and Verification changed") unless before_fixed == after_fixed
      [before_sections, after_sections].each do |sections|
        allowed.each do |heading|
          matches = sections.select { |candidate, _| candidate == heading }
          reject("Issue body contains duplicate #{heading} sections") if matches.length > 1
          next if matches.empty?

          content = matches.first.fetch(1).lines.drop(1).join
          reject("#{heading} must not contain nested Markdown headings") if content.each_line.any? { |line| line.match?(/\A\#{1,6}[ \t]+/) }
        end
      end
      reject("Acceptance criteria cannot be removed") unless after_sections.any? { |heading, _| heading == "Acceptance criteria" }
      true
    end

    def contract_delta!(before, after)
      changed = (before.keys | after.keys).select { |key| before.key?(key) != after.key?(key) || before[key] != after[key] }.sort
      forbidden = changed - CHANGED_FIELDS
      reject("contract revision changes forbidden fields: #{forbidden.join(', ')}") unless forbidden.empty?
      reject("contract revision must refresh fetchedAt") unless changed.include?("fetchedAt")
      substantive = changed & SUBSTANTIVE_FIELDS
      reject("contract revision has no Verification or Acceptance criteria change") if substantive.empty?
      before_ids = before.fetch("acceptanceCriteria").map { |entry| entry.fetch("id") }
      after_ids = after.fetch("acceptanceCriteria").map { |entry| entry.fetch("id") }
      reject("Acceptance criteria IDs or order changed") unless before_ids == after_ids
      before_time = timestamp!(before.fetch("fetchedAt"), "before contract fetchedAt")
      after_time = timestamp!(after.fetch("fetchedAt"), "after contract fetchedAt")
      reject("revised fetchedAt must be later than the prior contract") unless after_time > before_time
      [changed, substantive]
    end

    def contract_snapshot_path(issue, revision)
      ".artifacts/issues/#{issue}/#{REVISION_ROOT}/contracts/revision-%04d.json" % revision
    end

    def body_snapshot_path(issue, revision)
      ".artifacts/issues/#{issue}/#{REVISION_ROOT}/bodies/revision-%04d.md" % revision
    end

    def record_path(issue, revision)
      ".artifacts/issues/#{issue}/#{REVISION_ROOT}/records/revision-%04d.json" % revision
    end

    def before_state_path(issue, revision)
      ".artifacts/issues/#{issue}/#{REVISION_ROOT}/states/revision-%04d-before.json" % revision
    end

    def after_state_path(issue, revision)
      ".artifacts/issues/#{issue}/#{REVISION_ROOT}/states/revision-%04d-after.json" % revision
    end

    def validate_revision_reference!(value, issue, at = "state.issueContractRevision")
      exact_keys!(value, REVISION_REFERENCE_KEYS, at)
      revision = positive_integer!(value["revision"], "#{at}.revision")
      reject("#{at}.revision must be at least 2") if revision < 2
      reference!(value, at, revision: revision, expected_path: record_path(issue, revision))
    end

    def validate_authority_shape!(authority, substantive, at = "revision authority")
      exact_keys!(authority, AUTHORITY_KEYS, at)
      reject("#{at}.trigger is invalid") unless TRIGGERS.include?(authority["trigger"])
      nonempty_string!(authority["actor"], "#{at}.actor")
      nonempty_string!(authority["reference"], "#{at}.reference")
      scope = authority["scope"]
      reject("#{at}.scope must exactly match changed contract fields") unless scope == substantive.sort
      if authority["trigger"] == "user-delegated"
        reject("#{at}.delegate is invalid") unless %w[codex claude].include?(authority["delegate"])
      else
        reject("#{at}.delegate must be null") unless authority["delegate"].nil?
      end
      authority
    end

    def validate_record!(bytes, expected_reference:, loader:, issue:, repository:)
      record = parse_object(bytes, "contract revision record")
      exact_keys!(record, RECORD_KEYS, "contract revision record")
      reject("contract revision record is not canonical") unless bytes == canonical_json(record)
      revision = positive_integer!(record["revision"], "contract revision record.revision")
      reject("contract revision record revision must be at least 2") if revision < 2
      reference!(expected_reference, "contract revision reference", revision: revision, expected_path: record_path(issue, revision))
      reject("contract revision record digest differs") unless digest(bytes) == expected_reference.fetch("digest")
      reject("contract revision record identity differs") unless
        record["schemaVersion"] == 1 && record["issue"] == issue && record["repository"] == repository
      reject("contract revision issueType is invalid") unless %w[feature regression docs release].include?(record["issueType"])
      reject("contract revision previousRevision differs") unless record["previousRevision"] == revision - 1
      if revision == 2
        reject("first contract revision must not name a previous record") unless record["previousRecord"].nil?
      else
        reference!(record["previousRecord"], "previous revision record", revision: revision - 1,
          expected_path: record_path(issue, revision - 1))
      end
      exact_keys!(record["before"], %w[body contract], "revision before")
      exact_keys!(record["after"], %w[body contract], "revision after")
      before_contract_bytes = load_reference!(loader, record.dig("before", "contract"), "before contract",
        expected_path: contract_snapshot_path(issue, revision - 1))
      after_contract_bytes = load_reference!(loader, record.dig("after", "contract"), "after contract",
        expected_path: contract_snapshot_path(issue, revision))
      before_body_bytes = load_reference!(loader, record.dig("before", "body"), "before body",
        expected_path: body_snapshot_path(issue, revision - 1))
      after_body_bytes = load_reference!(loader, record.dig("after", "body"), "after body",
        expected_path: body_snapshot_path(issue, revision))
      before = canonical_contract!(before_contract_bytes, issue, repository, "before contract snapshot")
      after = canonical_contract!(after_contract_bytes, issue, repository, "after contract snapshot")
      allow_legacy = !before.key?("deliveryStage")
      parsed_before, parsed_before_bytes = parse_body_contract!(
        before_body_bytes, issue_type: record.fetch("issueType"), issue: issue, repository: repository,
        fetched_at: before.fetch("fetchedAt"), allow_legacy_delivery_stage: allow_legacy
      )
      parsed_after, parsed_after_bytes = parse_body_contract!(
        after_body_bytes, issue_type: record.fetch("issueType"), issue: issue, repository: repository,
        fetched_at: after.fetch("fetchedAt"), allow_legacy_delivery_stage: allow_legacy
      )
      reject("before body does not reconstruct its contract snapshot") unless parsed_before_bytes.b == before_contract_bytes.b && parsed_before == before
      reject("after body does not reconstruct its contract snapshot") unless parsed_after_bytes.b == after_contract_bytes.b && parsed_after == after
      allowed_body_delta!(before_body_bytes, after_body_bytes)
      changed, substantive = contract_delta!(before, after)
      reject("contract revision changedFields differs from exact contract delta") unless record["changedFields"] == changed
      validate_authority_shape!(record["authority"], substantive)
      nonempty_string!(record["reason"], "contract revision reason")
      reject("contract revision invalidation set differs") unless record["invalidatedEvidence"] == INVALIDATED_EVIDENCE
      exact_keys!(record["retainedIdentity"], RETAINED_IDENTITY_KEYS, "retained identity")
      retained = record.fetch("retainedIdentity")
      sha!(retained["baseSha"], "retained identity baseSha")
      sha!(retained["sourceHead"], "retained identity sourceHead")
      reject("retained identity branch is invalid") unless retained["branch"].is_a?(String) && retained["branch"].match?(%r{\A(codex|claude)/#{issue}-[a-z0-9][a-z0-9-]*\z})
      reject("retained identity worktree differs") unless retained["worktree"] == ".worktrees/#{retained.fetch('branch').split('/', 2).fetch(1)}"
      timestamp!(record["recordedAt"], "contract revision recordedAt")
      before_state_bytes = load_reference!(loader, record["beforeState"], "before revision state",
        expected_path: before_state_path(issue, revision))
      before_state = canonical_state!(before_state_bytes, issue, repository, "before revision state")
      reject("before revision state contract differs") unless before_state["issueContract"] == {"path" => ".artifacts/issues/#{issue}/issue-contract.json", "digest" => digest(before_contract_bytes)}
      reject("before revision state was not in-progress") unless before_state["state"] == "in-progress"
      reject("before revision state identity differs") unless
        before_state.values_at("baseSha", "branch", "worktree") == retained.values_at("baseSha", "branch", "worktree")
      {
        "record" => record,
        "beforeContractBytes" => before_contract_bytes,
        "afterContractBytes" => after_contract_bytes,
        "beforeBodyBytes" => before_body_bytes,
        "afterBodyBytes" => after_body_bytes,
        "beforeStateBytes" => before_state_bytes
      }
    end

    def validate_chain!(state:, contract_bytes:, issue:, repository:, loader:)
      reference = validate_revision_reference!(state.fetch("issueContractRevision"), issue)
      expected_revision = reference.fetch("revision")
      latest = nil
      while expected_revision >= 2
        bytes = load_reference!(loader, reference, "revision record",
          expected_path: record_path(issue, expected_revision))
        validated = validate_record!(bytes, expected_reference: reference, loader: loader,
          issue: issue, repository: repository)
        record = validated.fetch("record")
        latest ||= validated
        if expected_revision == 2
          reject("first revision unexpectedly links another record") unless record["previousRecord"].nil?
        else
          previous = record.fetch("previousRecord")
          previous_bytes = load_reference!(loader, previous, "previous revision record",
            expected_path: record_path(issue, expected_revision - 1))
          previous_validated = validate_record!(previous_bytes, expected_reference: previous,
            loader: loader, issue: issue, repository: repository)
          reject("revision chain contract snapshots do not join") unless
            previous_validated.dig("record", "after") == record.dig("before")
          reject("revision chain body snapshots do not join") unless
            previous_validated.fetch("afterContractBytes") == validated.fetch("beforeContractBytes") &&
            previous_validated.fetch("afterBodyBytes") == validated.fetch("beforeBodyBytes")
          reject("revision chain changed retained Issue identity") unless
            previous_validated.dig("record", "retainedIdentity").values_at("baseSha", "branch", "worktree") ==
            record.fetch("retainedIdentity").values_at("baseSha", "branch", "worktree")
          reference = previous
        end
        expected_revision -= 1
      end
      reject("current contract differs from the latest revision snapshot") unless latest.fetch("afterContractBytes") == contract_bytes
      latest
    end

    def revision_history_exists?(issue_root)
      root = File.join(issue_root, REVISION_ROOT)
      File.exist?(root) || File.symlink?(root)
    end

    def pending_exists?(issue_root)
      path = File.join(issue_root, PENDING_NAME)
      File.exist?(path) || File.symlink?(path)
    end

    def validate_active_bytes!(state_bytes:, contract_bytes:, issue:, repository:, loader:,
                               history_exists:, pending_exists:, allow_pending: false)
      repository!(repository)
      positive_integer!(issue, "issue")
      reject("a contract revision is pending") if pending_exists && !allow_pending
      untrusted_state = parse_object(state_bytes, "durable Issue state")
      revision_bound = untrusted_state.key?("issueContractRevision") || history_exists || pending_exists
      state = canonical_state!(state_bytes, issue, repository, "durable Issue state",
        require_canonical: revision_bound)
      contract = canonical_contract!(contract_bytes, issue, repository, "canonical Issue contract")
      expected_contract = {"path" => ".artifacts/issues/#{issue}/issue-contract.json", "digest" => digest(contract_bytes)}
      reject("durable state does not bind the exact canonical contract") unless state["issueContract"] == expected_contract
      if state.key?("issueContractRevision")
        validated = validate_chain!(state: state, contract_bytes: contract_bytes, issue: issue,
          repository: repository, loader: loader)
        latest = validated.fetch("record")
        reject("durable state identity differs from the latest revision") unless
          state.values_at("baseSha", "branch", "worktree") == latest.fetch("retainedIdentity").values_at("baseSha", "branch", "worktree")
        {"status" => "revisioned", "revision" => latest.fetch("revision"), "contractDigest" => digest(contract_bytes)}
      else
        reject("revision history exists without a durable state reference") if history_exists
        {"status" => "original", "revision" => 1, "contractDigest" => digest(contract_bytes)}
      end
    end

    def with_issue_lock(repo_root, issue, exclusive: false)
      topology = topology!(repo_root)
      paths = issue_paths(topology, issue)
      issue_root = paths.fetch("issueRoot")
      stat = File.lstat(issue_root)
      reject("Issue artifact directory must be physical") unless stat.directory? && !stat.symlink?
      lock = File.open(issue_root, File::RDONLY | File::NOFOLLOW)
      mode = exclusive ? File::LOCK_EX : File::LOCK_SH
      reject("Issue artifact directory is locked by another workflow") unless lock.flock(mode | File::LOCK_NB)
      yield topology, paths, lock
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
      reject("Issue artifact directory is unavailable: #{error.message}")
    ensure
      lock&.close unless lock&.closed?
    end

    def validate_active!(repo_root:, issue:, repository:, allow_pending: false, operation: nil,
                         allow_missing_state: false)
      with_issue_lock(repo_root, issue) do |topology, paths, _lock|
        contract_bytes = physical_file!(paths.fetch("contract"), "canonical Issue contract").first
        history_exists = revision_history_exists?(paths.fetch("issueRoot"))
        pending_exists = pending_exists?(paths.fetch("issueRoot"))
        state_exists = File.exist?(paths.fetch("state")) || File.symlink?(paths.fetch("state"))
        result = if state_exists
          state_bytes = physical_file!(paths.fetch("state"), "durable Issue state").first
          loader = artifact_loader(topology.fetch("artifactsRoot"), issue)
          validate_active_bytes!(
            state_bytes: state_bytes, contract_bytes: contract_bytes, issue: issue,
            repository: repository, loader: loader,
            history_exists: history_exists, pending_exists: pending_exists,
            allow_pending: allow_pending
          )
        else
          reject("durable Issue state is missing") unless allow_missing_state
          reject("missing-state recovery cannot cross a contract revision") if history_exists || pending_exists
          canonical_contract!(contract_bytes, issue, repository, "canonical Issue contract")
          {"status" => "original-missing-state", "revision" => 1,
            "contractDigest" => digest(contract_bytes)}
        end
        if operation
          nonempty_string!(operation, "operation")
          contract = canonical_contract!(contract_bytes, issue, repository, "canonical Issue contract")
          reject("required external operation is not declared: #{operation}") unless IssueContract.operation_declared?(contract, operation)
          result = result.merge("operation" => operation)
        end
        result
      end
    end

    def validate_live_body!(repo_root:, issue:, repository:, live_document:,
                            allow_missing_state: false)
      with_issue_lock(repo_root, issue) do |topology, paths, _lock|
        contract_bytes = physical_file!(paths.fetch("contract"), "canonical Issue contract").first
        history_exists = revision_history_exists?(paths.fetch("issueRoot"))
        pending_exists = pending_exists?(paths.fetch("issueRoot"))
        state_exists = File.exist?(paths.fetch("state")) || File.symlink?(paths.fetch("state"))
        if state_exists
          state_bytes = physical_file!(paths.fetch("state"), "durable Issue state").first
          loader = artifact_loader(topology.fetch("artifactsRoot"), issue)
          validate_active_bytes!(state_bytes: state_bytes, contract_bytes: contract_bytes,
            issue: issue, repository: repository, loader: loader,
            history_exists: history_exists, pending_exists: pending_exists,
            allow_pending: false)
        else
          reject("durable Issue state is missing") unless allow_missing_state
          reject("missing-state recovery cannot cross a contract revision") if history_exists || pending_exists
        end
        reject("live Issue must be an object") unless live_document.is_a?(Hash)
        reject("live Issue identity differs") unless
          live_document["number"] == issue && live_document["url"] == "https://github.com/#{repository}/issues/#{issue}"
        body = live_document["body"]
        reject("live Issue body is invalid") unless body.is_a?(String)
        issue_type = issue_type!(live_document)
        contract = canonical_contract!(contract_bytes, issue, repository, "canonical Issue contract")
        reconstructed, reconstructed_bytes = parse_body_contract!(body, issue_type: issue_type,
          issue: issue, repository: repository, fetched_at: contract.fetch("fetchedAt"),
          allow_legacy_delivery_stage: !contract.key?("deliveryStage"))
        reject("live Issue body differs from the canonical contract") unless
          reconstructed == contract && reconstructed_bytes.b == contract_bytes.b
        {"status" => "matched", "contractDigest" => digest(contract_bytes)}
      end
    end

    def current_git_identity!(repo_root, topology, state)
      root = File.realpath(repo_root)
      reject("contract revision must run from its durable worktree") unless
        root == File.join(topology.fetch("primaryRoot"), state.fetch("worktree"))
      environment = {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil,
        "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null"}
      branch, branch_status = Open3.capture2e(environment, "/usr/bin/git", "-C", root, "branch", "--show-current")
      head, head_status = Open3.capture2e(environment, "/usr/bin/git", "-C", root, "rev-parse", "HEAD")
      reject("current Git identity is unavailable") unless branch_status.success? && head_status.success?
      branch = branch.strip
      head = head.strip
      reject("current Branch differs from durable state") unless branch == state.fetch("branch")
      sha!(head, "current Head")
      [branch, head]
    end

    def configured_owner!(repo_root)
      bytes = physical_file!(File.join(File.realpath(repo_root), "Config", "ownership.yml"), "Config/ownership.yml").first
      Ownership.github_login!(Ownership.parse(bytes))
    rescue Ownership::ValidationError => error
      reject("configured owner is invalid: #{error.message}")
    end

    def user_marker(before_contract_digest:, after_body_digest:, issue:, repository:, scope:,
                    source_head:, trigger:, reason:, delegate:)
      reject("user authorization trigger is invalid") unless USER_TRIGGERS.include?(trigger)
      marker = {
        "afterBodyDigest" => digest!(after_body_digest, "after body digest"),
        "beforeContractDigest" => digest!(before_contract_digest, "before contract digest"),
        "delegate" => delegate,
        "issue" => positive_integer!(issue, "issue"),
        "reason" => nonempty_string!(reason, "reason"),
        "repository" => repository!(repository),
        "scope" => scope,
        "sourceHead" => sha!(source_head, "source Head"),
        "trigger" => trigger
      }
      validate_marker!(marker, scope: scope, delegate: delegate, trigger: trigger)
      "<!-- ios-template-contract-revision #{canonical_json(marker)} -->"
    end

    def validate_marker!(marker, scope:, delegate:, trigger:)
      exact_keys!(marker, MARKER_KEYS, "user revision marker")
      digest!(marker["afterBodyDigest"], "user revision marker.afterBodyDigest")
      digest!(marker["beforeContractDigest"], "user revision marker.beforeContractDigest")
      positive_integer!(marker["issue"], "user revision marker.issue")
      repository!(marker["repository"], "user revision marker.repository")
      sha!(marker["sourceHead"], "user revision marker.sourceHead")
      nonempty_string!(marker["reason"], "user revision marker.reason")
      reject("user revision marker.trigger differs") unless marker["trigger"] == trigger
      reject("user revision marker.scope differs") unless marker["scope"] == scope.sort
      if trigger == "user-delegated"
        reject("user-delegated marker requires codex or claude delegate") unless %w[codex claude].include?(delegate) && marker["delegate"] == delegate
      else
        reject("user-explicit marker cannot name a delegate") unless delegate.nil? && marker["delegate"].nil?
      end
      marker
    end

    def default_review_validator(repo_root:, primary:, issue:, head_sha:, packet_path:, review_path:)
      validation, validation_status = Open3.capture2e(
        File.join(repo_root, "tools/validate-review-result.sh"), "--primary", primary,
        "--packet", packet_path, "--result", review_path, chdir: repo_root
      )
      reject("review-finding source is not a canonical current-contract review: #{validation.strip}") unless validation_status.success?
      receipt, receipt_status = Open3.capture2e(
        "/usr/bin/ruby", File.join(repo_root, "tools/lib/validate-review-receipt.rb"),
        repo_root, primary, issue.to_s, head_sha, chdir: repo_root
      )
      reject("review-finding source has no valid launcher receipt: #{receipt.strip}") unless receipt_status.success?
      true
    end

    def validate_authority!(repo_root:, live_document:, state:, before_contract:, before_contract_digest:,
                            proposed_body_digest:, substantive:, source_head:, trigger:,
                            authority_reference:, reason:, delegate:, recorded_at:, loader:,
                            review_validator: nil)
      reject("revision trigger is invalid") unless TRIGGERS.include?(trigger)
      nonempty_string!(authority_reference, "authority reference")
      nonempty_string!(reason, "revision reason")
      if USER_TRIGGERS.include?(trigger)
        reject("user-explicit cannot name a delegate") if trigger == "user-explicit" && !delegate.nil?
        reject("user-delegated requires the current Issue executor as delegate") unless
          trigger != "user-delegated" || (%w[codex claude].include?(delegate) && delegate == state.fetch("executor"))
        owner = configured_owner!(repo_root)
        comments = live_document.fetch("comments")
        candidates = comments.select { |comment| comment.is_a?(Hash) && comment["url"] == authority_reference }
        reject("authority reference must identify exactly one live Issue comment") unless candidates.length == 1
        comment = candidates.first
        reject("authority comment is not owned by the configured GitHub owner") unless comment.dig("author", "login") == owner
        body = comment["body"]
        reject("authority comment body is invalid") unless body.is_a?(String)
        matches = body.scan(MARKER_PATTERN).flatten
        reject("authority comment must contain exactly one revision marker") unless matches.length == 1
        marker_bytes = matches.first
        marker = parse_object(marker_bytes, "user revision marker")
        reject("user revision marker is not canonical") unless marker_bytes == canonical_json(marker)
        validate_marker!(marker, scope: substantive, delegate: delegate, trigger: trigger)
        expected = {
          "afterBodyDigest" => proposed_body_digest,
          "beforeContractDigest" => before_contract_digest,
          "delegate" => delegate,
          "issue" => state.fetch("issue"),
          "reason" => reason,
          "repository" => state.fetch("repository"),
          "scope" => substantive.sort,
          "sourceHead" => source_head,
          "trigger" => trigger
        }
        reject("authority comment does not authorize this exact revision") unless marker == expected
        created_at = timestamp!(comment["createdAt"], "authority comment.createdAt")
        reject("authority comment predates the current sealed contract") if created_at < timestamp!(before_contract.fetch("fetchedAt"), "before contract fetchedAt")
        reject("authority comment is implausibly in the future") if created_at > timestamp!(recorded_at, "revision recordedAt") + 300
        return {"trigger" => trigger, "actor" => owner, "delegate" => delegate,
          "scope" => substantive.sort, "reference" => authority_reference}
      end

      reject("review-finding cannot name a user delegate") unless delegate.nil?
      match = authority_reference.match(%r{\A\.artifacts/issues/#{state.fetch('issue')}/([0-9a-f]{40})/review\.json#findings/([0-9]+)\z})
      reject("review-finding authority reference is noncanonical") unless match
      review_head = match[1]
      finding_index = Integer(match[2])
      reject("review-finding must be applied before the reviewed source Head changes") unless review_head == source_head
      reject("review-finding requires a changes-requested to in-progress history") unless
        state["state"] == "in-progress" && state["previousState"] == "changes-requested" &&
        state["from"] == "changes-requested" && state["to"] == "in-progress"
      review_path = ".artifacts/issues/#{state.fetch('issue')}/#{review_head}/review.json"
      packet_path = ".artifacts/issues/#{state.fetch('issue')}/#{review_head}/review-packet.json"
      review_bytes = loader.call(review_path)
      review = parse_object(review_bytes, "review-finding source")
      validator = review_validator || method(:default_review_validator)
      validator.call(repo_root: repo_root, primary: state.fetch("primaryImplementer"),
        issue: state.fetch("issue"), head_sha: review_head, packet_path: packet_path, review_path: review_path)
      reject("review-finding source identity differs") unless
        review["issue"] == state.fetch("issue") && review["headSha"] == review_head &&
        review["issueContractDigest"] == before_contract_digest && review["verdict"] == "changes-requested"
      findings = review["findings"]
      reject("review-finding source has no findings") unless findings.is_a?(Array)
      finding = findings[finding_index]
      reject("review-finding index is absent") unless finding.is_a?(Hash)
      reject("review-finding is not blocking") unless %w[critical high medium].include?(finding["severity"])
      required_change = finding["requiredChange"]
      nonempty_string!(required_change, "review finding.requiredChange")
      reject("revision reason must exactly match the selected review requiredChange") unless reason == required_change
      actor = nonempty_string!(review["reviewerModel"], "review reviewerModel")
      {"trigger" => trigger, "actor" => actor, "delegate" => nil,
        "scope" => substantive.sort, "reference" => authority_reference}
    rescue KeyError => error
      reject("revision authority is incomplete: #{error.message}")
    end

    def next_recorded_at(before_contract, requested_time)
      prior = timestamp!(before_contract.fetch("fetchedAt"), "before contract fetchedAt")
      # Contract timestamps are sealed at whole-second precision. Compare at
      # that same precision so two revisions in one second cannot collapse to
      # an unchanged fetchedAt after iso8601 formatting.
      now = Time.at(requested_time.to_i).utc
      now = prior + 1 if now <= prior
      now.iso8601
    end

    def local_path(artifacts_root, reference_path)
      File.join(artifacts_root, reference_path.delete_prefix(".artifacts/"))
    end

    def ensure_directory!(path)
      parent = File.dirname(path)
      ensure_directory!(parent) unless File.exist?(parent)
      unless File.exist?(path)
        Dir.mkdir(path, 0o700)
      end
      stat = File.lstat(path)
      reject("revision artifact directory is unsafe: #{path}") unless stat.directory? && !stat.symlink?
      path
    rescue Errno::EEXIST
      retry
    end

    def publish_exact!(path, bytes, at)
      ensure_directory!(File.dirname(path))
      if File.exist?(path) || File.symlink?(path)
        existing, = physical_file!(path, at)
        reject("existing #{at} differs from this exact revision") unless existing == bytes
        return path
      end
      flags = File::WRONLY | File::CREAT | File::EXCL
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(path, flags, 0o600) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        file.fsync
      end
      physical_file!(path, at)
      File.open(File.dirname(path), File::RDONLY | File::NOFOLLOW, &:fsync)
      path
    rescue Errno::EEXIST
      retry
    end

    def build_revision!(repo_root:, issue:, repository:, proposed_body:, live_document:, trigger:,
                        authority_reference:, reason:, delegate:, requested_time: Time.now.utc,
                        review_validator: nil, marker_only: false)
      repository!(repository)
      positive_integer!(issue, "issue")
      live_issue!(live_document, issue, repository)
      with_issue_lock(repo_root, issue, exclusive: true) do |topology, paths, _lock|
        reject("contract revision must run from the canonical Issue worktree") unless topology.fetch("layout") == "linked"
        reject("another contract revision is pending") if pending_exists?(paths.fetch("issueRoot"))
        state_bytes = physical_file!(paths.fetch("state"), "durable Issue state").first
        contract_bytes = physical_file!(paths.fetch("contract"), "canonical Issue contract").first
        loader = artifact_loader(topology.fetch("artifactsRoot"), issue)
        active = validate_active_bytes!(state_bytes: state_bytes, contract_bytes: contract_bytes,
          issue: issue, repository: repository, loader: loader,
          history_exists: revision_history_exists?(paths.fetch("issueRoot")), pending_exists: false)
        state = canonical_state!(state_bytes, issue, repository, "durable Issue state")
        reject("contract revision is allowed only in in-progress state") unless state["state"] == "in-progress"
        _branch, source_head = current_git_identity!(repo_root, topology, state)
        before_contract = canonical_contract!(contract_bytes, issue, repository, "canonical Issue contract")
        %w[github.read_issue github.update_issue].each do |operation|
          reject("sealed Issue contract does not authorize #{operation}") unless IssueContract.operation_declared?(before_contract, operation)
        end
        issue_type = issue_type!(live_document)
        allow_legacy = !before_contract.key?("deliveryStage")
        reconstructed, reconstructed_bytes = parse_body_contract!(live_document.fetch("body"), issue_type: issue_type,
          issue: issue, repository: repository, fetched_at: before_contract.fetch("fetchedAt"),
          allow_legacy_delivery_stage: allow_legacy)
        reject("live Issue body differs from the sealed current contract") unless reconstructed == before_contract && reconstructed_bytes.b == contract_bytes.b
        allowed_body_delta!(live_document.fetch("body"), proposed_body)

        recorded_at = next_recorded_at(before_contract, requested_time)
        after_contract, after_contract_bytes = parse_body_contract!(proposed_body, issue_type: issue_type,
          issue: issue, repository: repository, fetched_at: recorded_at,
          allow_legacy_delivery_stage: allow_legacy)
        changed, substantive = contract_delta!(before_contract, after_contract)
        before_digest = digest(contract_bytes)
        proposed_body_digest = digest(proposed_body)
        if marker_only
          reject("marker generation supports only user authority routes") unless USER_TRIGGERS.include?(trigger)
          return {"marker" => user_marker(before_contract_digest: before_digest,
            after_body_digest: proposed_body_digest, issue: issue, repository: repository,
            scope: substantive, source_head: source_head, trigger: trigger,
            reason: reason, delegate: delegate), "scope" => substantive}
        end

        authority = validate_authority!(repo_root: File.realpath(repo_root), live_document: live_document,
          state: state, before_contract: before_contract, before_contract_digest: before_digest,
          proposed_body_digest: proposed_body_digest, substantive: substantive, source_head: source_head,
          trigger: trigger, authority_reference: authority_reference, reason: reason, delegate: delegate,
          recorded_at: recorded_at, loader: loader, review_validator: review_validator)
        revision = active.fetch("revision") + 1
        previous_record = state["issueContractRevision"]
        previous_contract_path = contract_snapshot_path(issue, revision - 1)
        previous_body_path = body_snapshot_path(issue, revision - 1)
        new_contract_path = contract_snapshot_path(issue, revision)
        new_body_path = body_snapshot_path(issue, revision)
        state_before_path = before_state_path(issue, revision)
        record_reference_path = record_path(issue, revision)
        state_after_reference_path = after_state_path(issue, revision)

        before_contract_ref = file_reference(previous_contract_path, contract_bytes)
        before_body_ref = file_reference(previous_body_path, live_document.fetch("body"))
        after_contract_ref = file_reference(new_contract_path, after_contract_bytes)
        after_body_ref = file_reference(new_body_path, proposed_body)
        before_state_ref = file_reference(state_before_path, state_bytes)
        record = {
          "schemaVersion" => 1, "issue" => issue, "repository" => repository,
          "issueType" => issue_type, "revision" => revision, "previousRevision" => revision - 1,
          "previousRecord" => previous_record,
          "before" => {"contract" => before_contract_ref, "body" => before_body_ref},
          "after" => {"contract" => after_contract_ref, "body" => after_body_ref},
          "changedFields" => changed, "reason" => reason, "authority" => authority,
          "invalidatedEvidence" => INVALIDATED_EVIDENCE,
          "retainedIdentity" => {"baseSha" => state.fetch("baseSha"), "branch" => state.fetch("branch"),
            "worktree" => state.fetch("worktree"), "sourceHead" => source_head},
          "beforeState" => before_state_ref, "recordedAt" => recorded_at
        }
        record_bytes = canonical_json(record)
        record_ref = revision_reference(record_reference_path, record_bytes, revision)
        after_state = canonical(state.merge(
          "issueContract" => {"path" => ".artifacts/issues/#{issue}/issue-contract.json", "digest" => digest(after_contract_bytes)},
          "issueContractRevision" => record_ref
        ).reject { |key, _| key == "headSha" })
        after_state_bytes = "#{canonical_json(after_state)}\n"
        after_state_ref = file_reference(state_after_reference_path, after_state_bytes)
        request = {"trigger" => trigger, "authorityReference" => authority_reference,
          "reason" => reason, "delegate" => delegate, "proposedBodyDigest" => proposed_body_digest}
        pending = {"schemaVersion" => 1, "issue" => issue, "repository" => repository,
          "revision" => revision, "record" => record_ref,
          "beforeContract" => before_contract_ref, "afterContract" => after_contract_ref,
          "beforeBody" => before_body_ref, "afterBody" => after_body_ref,
          "beforeState" => before_state_ref, "afterState" => after_state_ref,
          "request" => request, "createdAt" => recorded_at}
        pending_bytes = canonical_json(pending)

        artifacts = topology.fetch("artifactsRoot")
        publications = [
          [previous_contract_path, contract_bytes, "prior contract snapshot"],
          [previous_body_path, live_document.fetch("body"), "prior body snapshot"],
          [new_contract_path, after_contract_bytes, "revised contract snapshot"],
          [new_body_path, proposed_body, "revised body snapshot"],
          [state_before_path, state_bytes, "before revision state snapshot"],
          [record_reference_path, record_bytes, "contract revision record"],
          [state_after_reference_path, after_state_bytes, "after revision state snapshot"]
        ]
        publications.each { |relative, bytes, at| publish_exact!(local_path(artifacts, relative), bytes, at) }
        publish_exact!(paths.fetch("pending"), pending_bytes, "contract revision pending record")
        validate_pending!(pending_bytes: pending_bytes, proposed_body: proposed_body,
          live_document: live_document, repo_root: File.realpath(repo_root), topology: topology,
          paths: paths, trigger: trigger, authority_reference: authority_reference, reason: reason,
          delegate: delegate, review_validator: review_validator)
        {"status" => "prepared", "revision" => revision, "liveBody" => "before",
          "pendingPath" => ".artifacts/issues/#{issue}/#{PENDING_NAME}",
          "afterBodyDigest" => proposed_body_digest, "record" => record_ref}
      end
    end

    def validate_pending!(pending_bytes:, proposed_body:, live_document:, repo_root:, topology:, paths:,
                          trigger:, authority_reference:, reason:, delegate:, review_validator: nil)
      pending = parse_object(pending_bytes, "contract revision pending record")
      exact_keys!(pending, PENDING_KEYS, "contract revision pending record")
      reject("contract revision pending record is not canonical") unless pending_bytes == canonical_json(pending)
      issue = positive_integer!(pending["issue"], "pending issue")
      repository = repository!(pending["repository"], "pending repository")
      revision = positive_integer!(pending["revision"], "pending revision")
      reject("pending revision must be at least 2") if revision < 2
      exact_keys!(pending["request"], REQUEST_KEYS, "pending request")
      expected_request = {"trigger" => trigger, "authorityReference" => authority_reference,
        "reason" => reason, "delegate" => delegate, "proposedBodyDigest" => digest(proposed_body)}
      reject("pending revision belongs to another request") unless pending["request"] == expected_request
      loader = artifact_loader(topology.fetch("artifactsRoot"), issue)
      record_bytes = load_reference!(loader, pending["record"], "pending record", expected_path: record_path(issue, revision))
      validated = validate_record!(record_bytes, expected_reference: pending["record"], loader: loader,
        issue: issue, repository: repository)
      %w[beforeContract afterContract beforeBody afterBody beforeState].each do |key|
        record_reference = case key
        when "beforeContract" then validated.dig("record", "before", "contract")
        when "afterContract" then validated.dig("record", "after", "contract")
        when "beforeBody" then validated.dig("record", "before", "body")
        when "afterBody" then validated.dig("record", "after", "body")
        else validated.dig("record", "beforeState")
        end
        reject("pending #{key} differs from the revision record") unless pending[key] == record_reference
      end
      after_state_bytes = load_reference!(loader, pending["afterState"], "pending after state",
        expected_path: after_state_path(issue, revision))
      after_state = canonical_state!(after_state_bytes, issue, repository, "pending after state")
      reject("pending after state revision reference differs") unless after_state["issueContractRevision"] == pending["record"]
      reject("pending after state contract differs") unless after_state["issueContract"] == {"path" => ".artifacts/issues/#{issue}/issue-contract.json", "digest" => pending.dig("afterContract", "digest")}
      reject("pending after state retained a stale Head binding") if after_state.key?("headSha")
      validate_active_bytes!(state_bytes: after_state_bytes,
        contract_bytes: validated.fetch("afterContractBytes"), issue: issue, repository: repository,
        loader: loader, history_exists: true, pending_exists: true, allow_pending: true)
      live_issue!(live_document, issue, repository)
      live_body = live_document.fetch("body")
      status = if digest(live_body) == pending.dig("beforeBody", "digest") && live_body == validated.fetch("beforeBodyBytes")
        "before"
      elsif digest(live_body) == pending.dig("afterBody", "digest") && live_body == validated.fetch("afterBodyBytes")
        "after"
      else
        reject("live Issue body matches neither side of the pending revision")
      end
      state_bytes = physical_file!(paths.fetch("state"), "durable Issue state").first
      contract_bytes = physical_file!(paths.fetch("contract"), "canonical Issue contract").first
      reject("canonical contract is outside the pending revision") unless [validated.fetch("beforeContractBytes"), validated.fetch("afterContractBytes")].include?(contract_bytes)
      reject("durable state is outside the pending revision") unless [validated.fetch("beforeStateBytes"), after_state_bytes].include?(state_bytes)
      state_for_authority = canonical_state!(validated.fetch("beforeStateBytes"), issue, repository, "before revision state")
      source_head = validated.dig("record", "retainedIdentity", "sourceHead")
      _branch, current_head = current_git_identity!(repo_root, topology, state_for_authority)
      reject("source Head changed while contract revision was pending") unless current_head == source_head
      before_contract = canonical_contract!(validated.fetch("beforeContractBytes"), issue, repository, "before contract snapshot")
      %w[github.read_issue github.update_issue].each do |operation|
        reject("pending contract does not authorize #{operation}") unless IssueContract.operation_declared?(before_contract, operation)
      end
      substantive = validated.dig("record", "authority", "scope")
      authority = validate_authority!(repo_root: repo_root, live_document: live_document,
        state: state_for_authority, before_contract: before_contract,
        before_contract_digest: pending.dig("beforeContract", "digest"),
        proposed_body_digest: pending.dig("afterBody", "digest"), substantive: substantive,
        source_head: source_head, trigger: trigger, authority_reference: authority_reference,
        reason: reason, delegate: delegate, recorded_at: pending.fetch("createdAt"), loader: loader,
        review_validator: review_validator)
      reject("pending authority differs from the validated authority") unless authority == validated.dig("record", "authority")
      {"pending" => pending, "validated" => validated, "afterStateBytes" => after_state_bytes, "liveBody" => status}
    end

    def resume_pending!(repo_root:, issue:, repository:, proposed_body:, live_document:, trigger:,
                        authority_reference:, reason:, delegate:, review_validator: nil)
      with_issue_lock(repo_root, issue, exclusive: true) do |topology, paths, _lock|
        reject("contract revision must run from the canonical Issue worktree") unless topology.fetch("layout") == "linked"
        reject("no contract revision is pending") unless pending_exists?(paths.fetch("issueRoot"))
        pending_bytes = physical_file!(paths.fetch("pending"), "contract revision pending record").first
        result = validate_pending!(pending_bytes: pending_bytes, proposed_body: proposed_body,
          live_document: live_document, repo_root: File.realpath(repo_root), topology: topology,
          paths: paths, trigger: trigger, authority_reference: authority_reference, reason: reason,
          delegate: delegate, review_validator: review_validator)
        pending = result.fetch("pending")
        {"status" => "pending", "revision" => pending.fetch("revision"),
          "liveBody" => result.fetch("liveBody"),
          "pendingPath" => ".artifacts/issues/#{issue}/#{PENDING_NAME}",
          "afterBodyDigest" => pending.dig("afterBody", "digest"), "record" => pending.fetch("record")}
      end
    end

    def replace_exact!(directory, name, before_bytes, after_bytes, at)
      current_io, current_stat = DescriptorFiles.open_regular_at(directory, name)
      current_bytes = DescriptorFiles.read_opened(current_io, current_stat)
      current_io.close
      return "after" if current_bytes == after_bytes
      reject("#{at} matches neither side of the pending revision") unless current_bytes == before_bytes
      DescriptorFiles.atomic_replace_at(directory, name, after_bytes, before_bytes, current_stat)
      "replaced"
    rescue SystemCallError, IOError => error
      reject("#{at} could not be atomically replaced: #{error.message}")
    ensure
      current_io&.close unless current_io&.closed?
    end

    def unlink_pending_exact!(issue_directory, path, expected_bytes)
      io, stat = DescriptorFiles.open_regular_at(issue_directory, File.basename(path))
      bytes = DescriptorFiles.read_opened(io, stat)
      io.close
      reject("pending revision changed before cleanup") unless bytes == expected_bytes
      current, current_stat = DescriptorFiles.open_regular_at(issue_directory, File.basename(path))
      current.close
      reject("pending revision identity changed before cleanup") unless
        [stat.dev, stat.ino, stat.size, stat.mode, stat.nlink, stat.mtime.to_r] ==
        [current_stat.dev, current_stat.ino, current_stat.size, current_stat.mode, current_stat.nlink, current_stat.mtime.to_r]
      File.unlink(path)
      issue_directory.fsync
    rescue SystemCallError, IOError, Errno::ENOENT => error
      reject("pending revision could not be safely removed: #{error.message}")
    ensure
      io&.close unless io&.closed?
      current&.close unless current&.closed?
    end

    def activate_pending!(repo_root:, issue:, repository:, proposed_body:, live_document:, trigger:,
                          authority_reference:, reason:, delegate:, review_validator: nil,
                          fail_after_contract: false, fail_after_state: false)
      with_issue_lock(repo_root, issue, exclusive: true) do |topology, paths, lock|
        reject("contract revision must run from the canonical Issue worktree") unless topology.fetch("layout") == "linked"
        pending_bytes = physical_file!(paths.fetch("pending"), "contract revision pending record").first
        result = validate_pending!(pending_bytes: pending_bytes, proposed_body: proposed_body,
          live_document: live_document, repo_root: File.realpath(repo_root), topology: topology,
          paths: paths, trigger: trigger, authority_reference: authority_reference, reason: reason,
          delegate: delegate, review_validator: review_validator)
        reject("live Issue body has not reached the revised side") unless result.fetch("liveBody") == "after"
        validated = result.fetch("validated")
        issue_directory = lock
        contract_result = replace_exact!(issue_directory, "issue-contract.json",
          validated.fetch("beforeContractBytes"), validated.fetch("afterContractBytes"), "canonical Issue contract")
        reject("injected failure after contract publication") if fail_after_contract && contract_result == "replaced"
        state_result = replace_exact!(issue_directory, "state.json", validated.fetch("beforeStateBytes"),
          result.fetch("afterStateBytes"), "durable Issue state")
        reject("injected failure after state publication") if fail_after_state && state_result == "replaced"
        loader = artifact_loader(topology.fetch("artifactsRoot"), issue)
        validate_active_bytes!(state_bytes: result.fetch("afterStateBytes"),
          contract_bytes: validated.fetch("afterContractBytes"), issue: issue, repository: repository,
          loader: loader, history_exists: true, pending_exists: true, allow_pending: true)
        unlink_pending_exact!(issue_directory, paths.fetch("pending"), pending_bytes)
        {"status" => "revised", "revision" => result.dig("pending", "revision"),
          "contractDigest" => digest(validated.fetch("afterContractBytes")),
          "record" => result.dig("pending", "record")}
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  options = {}
  parser = OptionParser.new do |cli|
    cli.banner = "usage: issue-contract-revision.rb validate|validate-live|marker|prepare|resume|activate [options]"
    cli.on("--repo-root PATH") { |value| options["repoRoot"] = value }
    cli.on("--repo OWNER/REPO") { |value| options["repo"] = value }
    cli.on("--issue NUMBER", Integer) { |value| options["issue"] = value }
    cli.on("--body PATH") { |value| options["body"] = value }
    cli.on("--live-json PATH") { |value| options["liveJson"] = value }
    cli.on("--trigger VALUE") { |value| options["trigger"] = value }
    cli.on("--authority-reference VALUE") { |value| options["authorityReference"] = value }
    cli.on("--reason VALUE") { |value| options["reason"] = value }
    cli.on("--delegate VALUE") { |value| options["delegate"] = value }
    cli.on("--operation VALUE") { |value| options["operation"] = value }
    cli.on("--allow-missing-state") { options["allowMissingState"] = true }
  end

  begin
    parser.parse!(ARGV)
    raise OptionParser::InvalidArgument, "unexpected positional arguments" unless ARGV.empty?
    if options["allowMissingState"] && !%w[validate validate-live].include?(command)
      raise OptionParser::InvalidArgument, "--allow-missing-state is only valid for Claim recovery validation"
    end
    required = %w[repoRoot repo issue]
    required << "liveJson" if command == "validate-live"
    required.concat(%w[body liveJson trigger reason]) unless %w[validate validate-live].include?(command)
    required << "authorityReference" if %w[prepare resume activate].include?(command)
    missing = required.reject { |key| options.key?(key) }
    raise OptionParser::MissingArgument, missing.join(", ") unless missing.empty?
    repo_root = File.realpath(options.fetch("repoRoot"))
    issue = options.fetch("issue")
    repository = options.fetch("repo")
    if command == "validate"
      puts JSON.generate(IOSTemplate::IssueContractRevision.validate_active!(repo_root: repo_root,
        issue: issue, repository: repository, operation: options["operation"],
        allow_missing_state: options.fetch("allowMissingState", false)))
      exit 0
    end
    if command == "validate-live"
      live_path = options.fetch("liveJson")
      raise OptionParser::InvalidArgument, "--live-json must be a regular nonsymlink file" unless File.file?(live_path) && !File.symlink?(live_path)
      puts JSON.generate(IOSTemplate::IssueContractRevision.validate_live_body!(repo_root: repo_root,
        issue: issue, repository: repository, live_document: JSON.parse(File.binread(live_path)),
        allow_missing_state: options.fetch("allowMissingState", false)))
      exit 0
    end
    body_path = options.fetch("body")
    live_path = options.fetch("liveJson")
    raise OptionParser::InvalidArgument, "--body must be a regular nonsymlink file" unless File.file?(body_path) && !File.symlink?(body_path)
    raise OptionParser::InvalidArgument, "--live-json must be a regular nonsymlink file" unless File.file?(live_path) && !File.symlink?(live_path)
    proposed_body = File.binread(body_path).force_encoding(Encoding::UTF_8)
    live_document = JSON.parse(File.binread(live_path))
    common = {repo_root: repo_root, issue: issue, repository: repository,
      proposed_body: proposed_body, live_document: live_document,
      trigger: options.fetch("trigger"), reason: options.fetch("reason"),
      delegate: options["delegate"]}
    output = case command
    when "marker"
      IOSTemplate::IssueContractRevision.build_revision!(**common,
        authority_reference: "marker-only", marker_only: true)
    when "prepare"
      IOSTemplate::IssueContractRevision.build_revision!(**common,
        authority_reference: options.fetch("authorityReference"))
    when "resume"
      IOSTemplate::IssueContractRevision.resume_pending!(**common,
        authority_reference: options.fetch("authorityReference"))
    when "activate"
      IOSTemplate::IssueContractRevision.activate_pending!(**common,
        authority_reference: options.fetch("authorityReference"),
        fail_after_contract: ENV["IOS_TEMPLATE_REVISION_FAIL_AFTER"] == "contract",
        fail_after_state: ENV["IOS_TEMPLATE_REVISION_FAIL_AFTER"] == "state")
    else
      raise OptionParser::InvalidArgument, "command must be validate, validate-live, marker, prepare, resume, or activate"
    end
    puts JSON.generate(output)
  rescue OptionParser::ParseError, JSON::ParserError, Errno::ENOENT, Errno::EACCES,
         IOSTemplate::IssueContractRevision::ValidationError => error
    warn "Issue contract revision failed: #{error.message}"
    exit 1
  end
end
