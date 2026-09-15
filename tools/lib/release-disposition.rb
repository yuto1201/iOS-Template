# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require_relative "delivery-profile"
require_relative "workflow-release-phase"

module IOSTemplate
  module ReleaseDisposition
    class ValidationError < StandardError; end

    RECORD_KEYS = %w[schemaVersion release candidate entries executionDecisions recordedAt].freeze
    RELEASE_KEYS = %w[identifier revision phase scope phaseRecord].freeze
    CANDIDATE_KEYS = %w[issue baseSha headSha issueContract].freeze
    REFERENCE_KEYS = %w[path digest].freeze
    APPROVAL_KEYS = %w[authority actor reference issue baseSha headSha approvedAt].freeze
    ACCEPTED_DEFECT_KEYS = %w[
      id type classification severity title impact workaround fixCost approval expiresAt
      followUpIssue reevaluationCondition
    ].freeze
    DEFERRED_DEFECT_KEYS = %w[
      id type classification severity title impact reason followUpIssue resumeCondition
    ].freeze
    OMITTED_TEST_KEYS = %w[id type testPath reason risk followUpIssue].freeze
    UNVERIFIED_KEYS = %w[id type scope reason risk followUpIssue].freeze
    EXECUTION_DECISION_KEYS = %w[
      id action failure reason actor authority followUpIssue resumeCondition decidedAt
    ].freeze
    FAILURE_KEYS = %w[
      schemaVersion issue headSha scope attempt stage testPaths failedTest childTimeoutSeconds
      suiteTimeoutSeconds elapsedSeconds timedOut unexecutedTestPaths error startedAt completedAt
    ].freeze

    ENTRY_TYPES = %w[accepted-defect deferred-defect omitted-test unverified].freeze
    SAFE_DEFECT_CLASSIFICATIONS = %w[
      cosmetic minor-functional minor-performance minor-accessibility minor-localization
    ].freeze
    BLOCKING_DEFECT_CLASSIFICATIONS = %w[
      data-loss secret-leak billing money-calculation date-time-calculation primary-flow-crash
      authentication privacy legal
    ].freeze
    DEFECT_CLASSIFICATIONS = (SAFE_DEFECT_CLASSIFICATIONS + BLOCKING_DEFECT_CLASSIFICATIONS + ["unknown"]).freeze
    DEFECT_SEVERITIES = %w[critical high medium low unknown].freeze
    EXECUTION_ACTIONS = %w[shrink split defer wait].freeze
    FAILURE_SCOPES = %w[targeted head-all base-and-head].freeze
    FAILURE_STAGES = %w[suite diagnostic base head].freeze
    SHA = /\A[0-9a-f]{40}\z/
    DIGEST = /\Asha256:[0-9a-f]{64}\z/
    ENTRY_ID = /\A[a-z][a-z0-9-]{0,79}\z/
    FAILURE_PATH = %r{\A\.artifacts/issues/([1-9][0-9]*)/([0-9a-f]{40})/repository-test-failure-attempt-([12])\.json\z}
    CUTOVER = DeliveryProfile::RELEASE_DISPOSITION_CUTOVER
    GIT_ENV = {
      "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil,
      "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null",
      "GIT_NO_REPLACE_OBJECTS" => "1", "LANG" => "C", "LC_ALL" => "C"
    }.freeze

    module_function

    def required?(contract)
      return false unless DeliveryProfile.release_disposition_required?(contract)
      binding = ReleasePhase.binding_from_contract!(contract)
      reject("release disposition policy lacks its required binding") unless binding
      true
    rescue ReleasePhase::ValidationError, ArgumentError => error
      reject(error.message)
    end

    def parse_input!(bytes)
      value = parse_object(bytes, "release disposition input")
      exact_keys!(value, %w[schemaVersion entries executionDecisions recordedAt], "release disposition input")
      reject("release disposition input schemaVersion must be 1") unless value["schemaVersion"] == 1
      reject("release disposition input entries must be an array") unless value["entries"].is_a?(Array)
      reject("release disposition input executionDecisions must be an array") unless value["executionDecisions"].is_a?(Array)
      time!(value["recordedAt"], "release disposition input recordedAt")
      input_failure_references!(value)
      value
    end

    def input_failure_references!(input)
      decisions = input.fetch("executionDecisions")
      decisions.each_with_index do |decision, index|
        exact_keys!(decision, EXECUTION_DECISION_KEYS, "executionDecisions[#{index}]")
        reference!(decision["failure"], "executionDecisions[#{index}].failure")
      end
      decisions.map { |decision| decision.fetch("failure") }
    end

    def build(contract_bytes:, phase_record_bytes:, issue:, base_sha:, head_sha:, entries:,
              execution_decisions:, failure_record_bytes:, recorded_at:, now: Time.now.utc)
      contract = parse_object(contract_bytes, "issue contract")
      issue!(issue, "candidate issue")
      sha!(base_sha, "candidate Base SHA")
      sha!(head_sha, "candidate Head SHA")
      reject("candidate Base and Head must differ") if base_sha == head_sha
      reject("issue contract identity differs from candidate") unless contract["schemaVersion"] == 1 && contract["issue"] == issue
      repository = string!(contract["repository"], "issue contract repository")
      reject("issue contract repository is invalid") unless repository.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
      binding = required_binding!(contract)
      gate = ReleasePhase.gate!(contract, phase_record_bytes)
      reject("release Phase gate did not pass") unless gate["status"] == "passed"

      record = {
        "schemaVersion" => 1,
        "release" => {
          "identifier" => binding.fetch("releaseIdentifier"),
          "revision" => binding.fetch("revision"),
          "phase" => binding.fetch("phase"),
          "scope" => deep_copy(binding.fetch("scope")),
          "phaseRecord" => {"path" => binding.fetch("recordPath"), "digest" => binding.fetch("recordDigest")}
        },
        "candidate" => {
          "issue" => issue, "baseSha" => base_sha, "headSha" => head_sha,
          "issueContract" => {
            "path" => ".artifacts/issues/#{issue}/issue-contract.json",
            "digest" => digest(contract_bytes)
          }
        },
        "entries" => deep_copy(entries),
        "executionDecisions" => deep_copy(execution_decisions),
        "recordedAt" => recorded_at
      }
      validate_record_shape!(record, repository: repository, failure_record_bytes: failure_record_bytes, now: now)
      canonical(record)
    rescue ReleasePhase::ValidationError => error
      reject(error.message)
    end

    def validate!(record_bytes:, contract_bytes:, phase_record_bytes:, issue:, base_sha:, head_sha:,
                  failure_record_bytes:, now: Time.now.utc)
      record = parse_object(record_bytes, "release disposition")
      reject("release disposition must use canonical bytes") unless record_bytes.b == canonical_bytes(record)
      expected = build(
        contract_bytes: contract_bytes, phase_record_bytes: phase_record_bytes,
        issue: issue, base_sha: base_sha, head_sha: head_sha,
        entries: record["entries"], execution_decisions: record["executionDecisions"],
        failure_record_bytes: failure_record_bytes, recorded_at: record["recordedAt"], now: now
      )
      reject("release disposition differs from immutable inputs") unless record == expected
      record
    end

    def references!(record_bytes:, issue:, head_sha:)
      record = parse_object(record_bytes, "release disposition")
      reject("release disposition must use canonical bytes") unless record_bytes.b == canonical_bytes(record)
      exact_keys!(record, RECORD_KEYS, "release disposition")
      exact_keys!(record["candidate"], CANDIDATE_KEYS, "candidate")
      reject("release disposition candidate differs from caller") unless
        record.dig("candidate", "issue") == issue && record.dig("candidate", "headSha") == head_sha
      decisions = record["executionDecisions"]
      reject("release disposition executionDecisions must be an array") unless decisions.is_a?(Array)
      failures = decisions.each_with_index.map do |decision, index|
        exact_keys!(decision, EXECUTION_DECISION_KEYS, "executionDecisions[#{index}]")
        reference = reference!(decision["failure"], "executionDecisions[#{index}].failure")
        match = reference.fetch("path").match(FAILURE_PATH)
        reject("failure reference is outside the current Issue/Head") unless
          match && Integer(match[1]) == issue && match[2] == head_sha
        reference
      end
      reject("failure references must be unique") unless failures.map { |entry| entry.fetch("path") }.uniq.length == failures.length
      {
        "record" => {
          "path" => ".artifacts/issues/#{issue}/#{head_sha}/release-disposition.json",
          "digest" => digest(record_bytes)
        },
        "failures" => failures
      }
    end

    def release_ready!(record)
      reject("release disposition must be an object") unless record.is_a?(Hash)
      deferred_blocker = Array(record["entries"]).find do |entry|
        next false unless entry.is_a?(Hash) && entry["type"] == "deferred-defect"
        %w[critical high unknown].include?(entry["severity"]) ||
          BLOCKING_DEFECT_CLASSIFICATIONS.include?(entry["classification"]) || entry["classification"] == "unknown"
      end
      reject("release disposition contains a deferred critical, high, unknown, or blocking defect") if deferred_blocker
      reject("release disposition is waiting for a user decision") if
        Array(record["executionDecisions"]).any? { |decision| decision.is_a?(Hash) && decision["action"] == "wait" }
      record
    end

    def after_evidence!(record, evidence_times)
      reject("release disposition must be an object") unless record.is_a?(Hash)
      reject("release disposition evidence times must be an object") unless evidence_times.is_a?(Hash)
      recorded = time!(record["recordedAt"], "release disposition recordedAt")
      evidence_times.each do |label, value|
        next if value.nil?
        evidence_at = time!(value, label.to_s)
        reject("release disposition predates #{label}") if recorded < evidence_at
      end
      recorded
    end

    def phase_record_bytes!(repo:, base_sha:, contract:)
      reject("repository root must be physical") unless
        repo.is_a?(String) && repo.start_with?("/") && File.realpath(repo) == repo
      sha!(base_sha, "release disposition Base SHA")
      binding = required_binding!(contract)
      path = binding.fetch("recordPath")
      tree, error, status = Open3.capture3(
        GIT_ENV, "/usr/bin/git", "-C", repo, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
        "ls-tree", "-z", base_sha, "--", path
      )
      reject("bound release phase record lookup failed: #{error.strip}") unless status.success?
      entries = tree.split("\0").reject(&:empty?)
      reject("bound release phase record is not one exact Base blob") unless entries.length == 1
      metadata, actual_path = entries.first.split("\t", 2)
      mode, type, object = metadata.to_s.split(" ")
      reject("bound release phase record is not a regular Base blob") unless
        actual_path == path && type == "blob" && mode == "100644" && object&.match?(/\A[0-9a-f]{40,64}\z/)
      bytes, blob_error, blob_status = Open3.capture3(GIT_ENV, "/usr/bin/git", "-C", repo, "cat-file", "blob", object)
      reject("bound release phase record bytes are unavailable: #{blob_error.strip}") unless blob_status.success?
      bytes.b
    rescue SystemCallError => error
      reject("bound release phase record bytes are unavailable: #{error.message}")
    end

    def validate_record_shape!(record, repository:, failure_record_bytes:, now:)
      exact_keys!(record, RECORD_KEYS, "release disposition")
      reject("release disposition schemaVersion must be 1") unless record["schemaVersion"] == 1
      exact_keys!(record["release"], RELEASE_KEYS, "release")
      release = record.fetch("release")
      identifier!(release["identifier"], "release identifier")
      issue!(release["revision"], "release revision")
      reject("release phase must be Phase 5 or 6") unless [5, 6].include?(release["phase"])
      scope!(release["scope"], "release scope")
      reference!(release["phaseRecord"], "release phaseRecord")

      exact_keys!(record["candidate"], CANDIDATE_KEYS, "candidate")
      candidate = record.fetch("candidate")
      issue!(candidate["issue"], "candidate issue")
      sha!(candidate["baseSha"], "candidate Base SHA")
      sha!(candidate["headSha"], "candidate Head SHA")
      reference!(candidate["issueContract"], "candidate issueContract")

      recorded = time!(record["recordedAt"], "recordedAt")
      reject("release disposition recordedAt is implausibly in the future") if recorded > now.utc + 300
      validate_entries!(record["entries"], candidate: candidate, repository: repository, recorded_at: recorded, now: now.utc)
      validate_execution_decisions!(
        record["executionDecisions"], candidate: candidate, failure_record_bytes: failure_record_bytes,
        recorded_at: recorded, now: now.utc
      )
      record
    end

    def validate_entries!(entries, candidate:, repository:, recorded_at:, now:)
      reject("release disposition entries must be an array") unless entries.is_a?(Array)
      ids = []
      entries.each_with_index do |entry, index|
        reject("entries[#{index}] must be an object") unless entry.is_a?(Hash)
        type = entry["type"]
        reject("entries[#{index}].type is unsupported") unless ENTRY_TYPES.include?(type)
        expected = case type
                   when "accepted-defect" then ACCEPTED_DEFECT_KEYS
                   when "deferred-defect" then DEFERRED_DEFECT_KEYS
                   when "omitted-test" then OMITTED_TEST_KEYS
                   when "unverified" then UNVERIFIED_KEYS
                   end
        exact_keys!(entry, expected, "entries[#{index}]")
        ids << identifier!(entry["id"], "entries[#{index}].id")
        case type
        when "accepted-defect"
          defect!(entry, "entries[#{index}]")
          reject("accepted defect severity must be low") unless entry["severity"] == "low"
          reject("accepted defect classification is blocking or unknown") unless SAFE_DEFECT_CLASSIFICATIONS.include?(entry["classification"])
          %w[workaround fixCost reevaluationCondition].each { |field| string!(entry[field], "entries[#{index}].#{field}") }
          issue!(entry["followUpIssue"], "entries[#{index}].followUpIssue")
          approval!(entry["approval"], candidate: candidate, repository: repository, at: "entries[#{index}].approval")
          approved = time!(entry.dig("approval", "approvedAt"), "entries[#{index}].approval.approvedAt")
          expires = time!(entry["expiresAt"], "entries[#{index}].expiresAt")
          reject("accepted defect approval expires before it was granted") unless expires > approved
          reject("accepted defect approval predates or equals its expiry") unless now <= expires
          reject("accepted defect approval is later than the disposition") if approved > recorded_at
        when "deferred-defect"
          defect!(entry, "entries[#{index}]")
          %w[reason resumeCondition].each { |field| string!(entry[field], "entries[#{index}].#{field}") }
          issue!(entry["followUpIssue"], "entries[#{index}].followUpIssue")
        when "omitted-test"
          %w[testPath reason risk].each { |field| string!(entry[field], "entries[#{index}].#{field}") }
          issue!(entry["followUpIssue"], "entries[#{index}].followUpIssue")
        when "unverified"
          %w[scope reason risk].each { |field| string!(entry[field], "entries[#{index}].#{field}") }
          issue!(entry["followUpIssue"], "entries[#{index}].followUpIssue")
        end
      end
      reject("release disposition entry IDs must be unique and sorted") unless ids == ids.uniq.sort
    end

    def defect!(entry, at)
      reject("#{at}.classification is unsupported") unless DEFECT_CLASSIFICATIONS.include?(entry["classification"])
      reject("#{at}.severity is unsupported") unless DEFECT_SEVERITIES.include?(entry["severity"])
      %w[title impact].each { |field| string!(entry[field], "#{at}.#{field}") }
    end

    def approval!(approval, candidate:, repository:, at:)
      exact_keys!(approval, APPROVAL_KEYS, at)
      reject("#{at}.authority must be user") unless approval["authority"] == "user"
      string!(approval["actor"], "#{at}.actor")
      reference = string!(approval["reference"], "#{at}.reference")
      escaped_repository = Regexp.escape(repository)
      reject("#{at}.reference must name a GitHub Issue comment in the contract repository") unless
        reference.match?(%r{\Ahttps://github\.com/#{escaped_repository}/issues/[1-9][0-9]*#issuecomment-[1-9][0-9]*\z})
      reject("#{at} candidate identity differs") unless
        approval.values_at("issue", "baseSha", "headSha") == candidate.values_at("issue", "baseSha", "headSha")
      time!(approval["approvedAt"], "#{at}.approvedAt")
    end

    def validate_execution_decisions!(decisions, candidate:, failure_record_bytes:, recorded_at:, now:)
      reject("release disposition executionDecisions must be an array") unless decisions.is_a?(Array)
      reject("failure record bytes must be keyed by canonical path") unless failure_record_bytes.is_a?(Hash)
      ids = []
      paths = []
      decisions.each_with_index do |decision, index|
        at = "executionDecisions[#{index}]"
        exact_keys!(decision, EXECUTION_DECISION_KEYS, at)
        ids << identifier!(decision["id"], "#{at}.id")
        action = decision["action"]
        reject("#{at}.action is unsupported") unless EXECUTION_ACTIONS.include?(action)
        failure = reference!(decision["failure"], "#{at}.failure")
        path = failure.fetch("path")
        paths << path
        match = path.match(FAILURE_PATH)
        reject("#{at}.failure path differs from candidate") unless
          match && Integer(match[1]) == candidate["issue"] && match[2] == candidate["headSha"]
        bytes = failure_record_bytes[path]
        reject("#{at} has no exact failure record bytes") unless bytes.is_a?(String)
        reject("#{at}.failure digest differs from exact bytes") unless digest(bytes) == failure["digest"]
        failure_value = validate_failure_record!(
          bytes, issue: candidate["issue"], head_sha: candidate["headSha"], attempt: Integer(match[3]), at: "#{at}.failure"
        )
        string!(decision["reason"], "#{at}.reason")
        string!(decision["actor"], "#{at}.actor")
        string!(decision["resumeCondition"], "#{at}.resumeCondition")
        reject("#{at}.authority is unsupported") unless %w[user workflow].include?(decision["authority"])
        reject("workflow decisions must be recorded by codex or claude") if
          decision["authority"] == "workflow" && !%w[codex claude].include?(decision["actor"])
        if %w[split defer].include?(action)
          reject("#{at}.#{action} requires user authority") unless decision["authority"] == "user"
          issue!(decision["followUpIssue"], "#{at}.followUpIssue")
        else
          reject("#{at}.followUpIssue must be null for #{action}") unless decision["followUpIssue"].nil?
        end
        decided = time!(decision["decidedAt"], "#{at}.decidedAt")
        failed_at = time!(failure_value["completedAt"], "#{at}.failure.completedAt")
        reject("#{at} predates its failure record") if decided < failed_at
        reject("#{at} is later than the disposition") if decided > recorded_at
        reject("#{at} is implausibly in the future") if decided > now + 300
      end
      reject("execution decision IDs must be unique and sorted") unless ids == ids.uniq.sort
      reject("each failure record must have exactly one decision") unless paths.uniq.length == paths.length
      reject("failure records and execution decisions must have exact coverage") unless failure_record_bytes.keys.sort == paths.sort
    end

    def validate_failure_record!(bytes, issue:, head_sha:, attempt:, at:)
      value = parse_object(bytes, at)
      exact_keys!(value, FAILURE_KEYS, at)
      reject("#{at} identity differs") unless
        value.values_at("schemaVersion", "issue", "headSha", "attempt") == [1, issue, head_sha, attempt]
      reject("#{at}.scope is unsupported") unless FAILURE_SCOPES.include?(value["scope"])
      reject("#{at}.stage is unsupported") unless FAILURE_STAGES.include?(value["stage"])
      tests = string_array!(value["testPaths"], "#{at}.testPaths", require_nonempty: true)
      reject("#{at}.testPaths must be unique") unless tests.uniq == tests
      failed = value["failedTest"]
      reject("#{at}.failedTest differs from testPaths") unless failed.nil? || tests.include?(failed)
      unexecuted = string_array!(value["unexecutedTestPaths"], "#{at}.unexecutedTestPaths")
      reject("#{at}.unexecutedTestPaths is invalid") unless unexecuted.uniq == unexecuted && (unexecuted - tests).empty?
      %w[childTimeoutSeconds suiteTimeoutSeconds].each do |field|
        reject("#{at}.#{field} must be positive") unless value[field].is_a?(Integer) && value[field].positive?
      end
      reject("#{at}.elapsedSeconds is invalid") unless value["elapsedSeconds"].is_a?(Numeric) && value["elapsedSeconds"].finite? && value["elapsedSeconds"] >= 0
      reject("#{at}.timedOut must be boolean") unless [true, false].include?(value["timedOut"])
      string!(value["error"], "#{at}.error")
      started = time!(value["startedAt"], "#{at}.startedAt")
      completed = time!(value["completedAt"], "#{at}.completedAt")
      reject("#{at} interval is invalid") if completed < started
      value
    end

    def required_binding!(contract)
      binding = ReleasePhase.binding_from_contract!(contract)
      reject("release disposition requires a Release-phase binding") unless binding
      reject("release disposition requires Phase 5 or 6 implementation") unless
        binding["workKind"] == "implementation" && [5, 6].include?(binding["phase"])
      binding
    end

    def canonical_bytes(value)
      JSON.generate(canonical(value)).b
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.each_with_object({}) { |key, result| result[key] = canonical(value[key]) }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def digest(bytes)
      "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    end

    def exact_keys!(value, keys, at)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      reject("#{at}: unexpected or missing keys") unless value.keys.sort == keys.sort
    end

    def reference!(value, at)
      exact_keys!(value, REFERENCE_KEYS, at)
      string!(value["path"], "#{at}.path")
      digest!(value["digest"], "#{at}.digest")
      value
    end

    def scope!(value, at)
      strings = string_array!(value, at, require_nonempty: true)
      reject("#{at} must be unique and sorted") unless strings == strings.uniq.sort
      strings
    end

    def string_array!(value, at, require_nonempty: false)
      reject("#{at} must be an array") unless value.is_a?(Array)
      reject("#{at} must not be empty") if require_nonempty && value.empty?
      value.each_with_index { |entry, index| string!(entry, "#{at}[#{index}]") }
      value
    end

    def string!(value, at)
      reject("#{at} must be a nonempty string") unless
        value.is_a?(String) && !value.empty? && value == value.strip && !value.include?("\0") && value.bytesize <= 4_096
      value
    end

    def identifier!(value, at)
      reject("#{at} is invalid") unless value.is_a?(String) && value.match?(ENTRY_ID)
      value
    end

    def issue!(value, at)
      reject("#{at} must be a positive integer") unless value.is_a?(Integer) && value.positive?
      value
    end

    def sha!(value, at)
      reject("#{at} must be a lowercase Git SHA") unless value.is_a?(String) && value.match?(SHA)
      value
    end

    def digest!(value, at)
      reject("#{at} must be a sha256 digest") unless value.is_a?(String) && value.match?(DIGEST)
      value
    end

    def time!(value, at)
      string!(value, at)
      Time.iso8601(value).utc
    rescue ArgumentError
      reject("#{at} must be ISO 8601")
    end

    def parse_object(bytes, at)
      reject("#{at} bytes are missing") unless bytes.is_a?(String)
      value = JSON.parse(bytes.dup)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      value
    rescue JSON::ParserError => error
      reject("#{at} is invalid JSON: #{error.message}")
    end

    def reject(message)
      raise ValidationError, message
    end
  end
end
