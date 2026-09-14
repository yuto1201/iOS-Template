# frozen_string_literal: true

require "digest"
require "json"
require "time"

module IOSTemplate
  module ReleasePhase
    class ValidationError < StandardError; end

    RECORD_KEYS = %w[schemaVersion releaseIdentifier currentRevision currentScope history].freeze
    BINDING_KEYS = %w[releaseIdentifier revision phase scope workKind route recordPath recordDigest reason].freeze
    IDENTIFIER = /\A[a-z0-9][a-z0-9._-]{0,79}\z/
    DIGEST = /\Asha256:[0-9a-f]{64}\z/
    RECORD_PATH = %r{\AConfig/releases/[a-z0-9][a-z0-9._-]*/phase-records/[a-z0-9][a-z0-9._-]*\.json\z}
    USER_APPROVAL_PHASES = [1, 3, 4, 5].freeze
    WORK_KINDS = %w[implementation research draft independent].freeze
    ROUTES = %w[standard existing-app emergency].freeze
    REUSE_ROUTES = %w[existing-app emergency].freeze
    FOUNDATIONS = %w[data identity purpose ui-direction].freeze
    BINDING_PREFIX = "Release-phase binding:"

    EVENT_KEYS = {
      "release-created" => %w[sequence event revision scope goal actor reason recordedAt],
      "phase-completed" => %w[
        sequence event revision phase scope authority actor approvalReference reason evidence
        knownDefects omittedTests unverified carryovers recordedAt
      ],
      "change-classified" => %w[
        sequence event classification fromRevision toRevision fromScope toScope reopenFromPhase
        authority actor approvalReference reason changedBefore changedAfter affectedSpecifications
        affectedIssues invalidatedEvidence retainedEvidence carryovers recordedAt
      ],
      "phase-reused" => %w[
        sequence event revision route throughPhase scope foundations authority actor approvalReference
        reason recordedAt
      ]
    }.freeze

    module_function

    def create(release_identifier:, revision:, scope:, goal:, actor:, reason:, recorded_at:)
      release_identifier!(release_identifier)
      positive_integer!(revision, "revision")
      scope = scope!(scope, "scope")
      nonempty_string!(goal, "goal")
      nonempty_string!(actor, "actor")
      time!(recorded_at, "recordedAt")
      event = {
        "sequence" => 1,
        "event" => "release-created",
        "revision" => revision,
        "scope" => scope,
        "goal" => goal,
        "actor" => actor,
        "reason" => nonempty_string!(reason, "reason"),
        "recordedAt" => recorded_at
      }
      canonical_record(
        "schemaVersion" => 1,
        "releaseIdentifier" => release_identifier,
        "currentRevision" => revision,
        "currentScope" => scope,
        "history" => [event]
      )
    end

    def append(previous_bytes, event)
      previous, previous_state = validate_record_bytes!(previous_bytes, return_state: true)
      reject("event input must be an object without sequence") unless event.is_a?(Hash) && !event.key?("sequence")
      candidate_event = event.merge("sequence" => previous.fetch("history").length + 1)
      candidate = previous.merge("history" => previous.fetch("history") + [candidate_event])
      state = replay!(candidate.fetch("releaseIdentifier"), candidate.fetch("history"))
      candidate["currentRevision"] = state.fetch("currentRevision")
      candidate["currentScope"] = state.fetch("currentScope")
      bytes = canonical_record(candidate)
      validate_record_bytes!(bytes, previous_bytes: canonical_record(previous))
      bytes
    end

    def validate_record_bytes!(bytes, previous_bytes: nil, return_state: false)
      reject("release phase record bytes are missing") unless bytes.is_a?(String)
      record = parse_object(bytes, "release phase record")
      exact_keys!(record, RECORD_KEYS, "release phase record")
      reject("release phase record schemaVersion must be 1") unless record["schemaVersion"] == 1
      release_identifier!(record["releaseIdentifier"])
      positive_integer!(record["currentRevision"], "currentRevision")
      current_scope = scope!(record["currentScope"], "currentScope")
      history = record["history"]
      reject("release phase history must be nonempty") unless history.is_a?(Array) && !history.empty?
      state = replay!(record.fetch("releaseIdentifier"), history)
      reject("release phase currentRevision differs from replayed history") unless record["currentRevision"] == state["currentRevision"]
      reject("release phase currentScope differs from replayed history") unless current_scope == state["currentScope"]
      reject("release phase record must use canonical bytes") unless bytes == canonical_record(record)

      if previous_bytes
        previous = validate_record_bytes!(previous_bytes)
        reject("release phase record does not append exactly one event") unless
          record["releaseIdentifier"] == previous["releaseIdentifier"] &&
          record["history"].length == previous["history"].length + 1 &&
          record["history"].first(previous["history"].length) == previous["history"]
      end
      return [record, state] if return_state

      record
    end

    def gate!(contract, record_bytes)
      reject("Issue contract must be an object") unless contract.is_a?(Hash)
      binding = binding_from_contract!(contract)
      return {"status" => "legacy-unbound"} if binding.nil?

      binding!(binding)
      reject("bound release phase record is missing") unless record_bytes.is_a?(String)
      record, state = validate_record_bytes!(record_bytes, return_state: true)
      expected_digest = "sha256:#{Digest::SHA256.hexdigest(record_bytes)}"
      reject("release phase record digest differs from the sealed binding") unless binding["recordDigest"] == expected_digest
      reject("release identifier differs from the sealed binding") unless binding["releaseIdentifier"] == record["releaseIdentifier"]
      reject("release revision differs from the sealed binding") unless binding["revision"] == state["currentRevision"]
      reject("release scope is outside the approved record scope") unless (binding["scope"] - state["currentScope"]).empty?

      work_kind = binding.fetch("workKind")
      phase = binding.fetch("phase")
      route = binding.fetch("route")
      if REUSE_ROUTES.include?(route)
        matching_reuse = state.fetch("reuseEvents").reverse.find do |event|
          event["revision"] == state["currentRevision"] && event["route"] == route &&
            (binding["scope"] - event["scope"]).empty?
        end
        reject("existing-app or emergency reuse is not authorized by the bound record") unless matching_reuse
      elsif route != "standard"
        reject("release phase route is unsupported")
      end

      if %w[research draft independent].include?(work_kind)
        return {
          "status" => "passed",
          "workKind" => work_kind,
          "releaseIdentifier" => binding["releaseIdentifier"],
          "revision" => binding["revision"],
          "phase" => phase,
          "requiredPriorPhases" => []
        }
      end

      reject("unclassified release change blocks dependent implementation") if state["unclassifiedChange"]
      reject("requested Phase is already completed for this release revision") if state.fetch("completedPhases").key?(phase)
      required = phase > 1 ? (1...phase).to_a : []
      missing = required.reject { |number| state.fetch("completedPhases").key?(number) }
      reject("required prior Phase exits are incomplete: #{missing.join(',')}") unless missing.empty?
      reused_prerequisites = required.map { |number| state.fetch("completedPhases").fetch(number) }
        .select { |event| event["event"] == "phase-reused" }
      if reused_prerequisites.any?
        reuse_routes = reused_prerequisites.map { |event| event.fetch("route") }.uniq
        reject("Issue route must name the recorded existing-app or emergency reuse") unless reuse_routes == [route]
      end
      {
        "status" => "passed",
        "workKind" => work_kind,
        "releaseIdentifier" => binding["releaseIdentifier"],
        "revision" => binding["revision"],
        "phase" => phase,
        "requiredPriorPhases" => required
      }
    end

    def binding_from_contract!(contract)
      criteria = contract["acceptanceCriteria"]
      return nil unless criteria.is_a?(Array)
      declarations = criteria.select do |criterion|
        criterion.is_a?(Hash) && criterion["text"].is_a?(String) && criterion["text"].start_with?(BINDING_PREFIX)
      end
      return nil if declarations.empty?
      reject("exactly one Release-phase binding declaration is allowed") unless declarations.length == 1
      text = declarations.first.fetch("text")
      json = text.delete_prefix(BINDING_PREFIX).strip
      reject("Release-phase binding must contain one canonical JSON object") if json.empty?
      binding = parse_object(json, "Release-phase binding")
      binding!(binding)
      reject("Release-phase binding JSON must be canonical") unless JSON.generate(canonical(binding)) == json
      binding
    end

    def binding!(binding)
      exact_keys!(binding, BINDING_KEYS, "releasePhase")
      release_identifier!(binding["releaseIdentifier"])
      positive_integer!(binding["revision"], "releasePhase.revision")
      phase!(binding["phase"], "releasePhase.phase")
      binding["scope"] = scope!(binding["scope"], "releasePhase.scope")
      reject("releasePhase.workKind is unsupported") unless WORK_KINDS.include?(binding["workKind"])
      reject("releasePhase.route is unsupported") unless ROUTES.include?(binding["route"])
      reject("releasePhase.recordPath is invalid") unless binding["recordPath"].is_a?(String) && binding["recordPath"].match?(RECORD_PATH)
      reject("releasePhase.recordPath does not match releaseIdentifier") unless
        binding["recordPath"].start_with?("Config/releases/#{binding.fetch('releaseIdentifier')}/phase-records/")
      reject("releasePhase.recordDigest is invalid") unless binding["recordDigest"].is_a?(String) && binding["recordDigest"].match?(DIGEST)
      nonempty_string!(binding["reason"], "releasePhase.reason")
      binding
    end

    def write_unique!(path, bytes)
      reject("output path must be nonempty") unless path.is_a?(String) && !path.empty?
      validate_record_bytes!(bytes)
      flags = File::WRONLY | File::CREAT | File::EXCL
      File.open(path, flags, 0o600) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        file.fsync
      end
      path
    rescue Errno::EEXIST
      reject("release phase record output already exists")
    end

    def replay!(release_identifier, history)
      current_revision = nil
      current_scope = nil
      completed = {}
      reuse_events = []
      unclassified = false
      previous_time = nil

      history.each_with_index do |event, index|
        reject("release phase event must be an object") unless event.is_a?(Hash)
        type = event["event"]
        expected_keys = EVENT_KEYS[type]
        reject("release phase event type is unsupported") unless expected_keys
        exact_keys!(event, expected_keys, "release phase event #{index + 1}")
        reject("release phase event sequence is invalid") unless event["sequence"] == index + 1
        recorded_at = time!(event["recordedAt"], "release phase event recordedAt")
        reject("release phase event timestamps must be monotonic") if previous_time && recorded_at < previous_time
        previous_time = recorded_at

        case type
        when "release-created"
          reject("release-created must be the first and only initialization event") unless index.zero? && current_revision.nil?
          positive_integer!(event["revision"], "release-created.revision")
          current_revision = event["revision"]
          current_scope = scope!(event["scope"], "release-created.scope")
          nonempty_string!(event["goal"], "release-created.goal")
          nonempty_string!(event["actor"], "release-created.actor")
          nonempty_string!(event["reason"], "release-created.reason")
        when "phase-completed"
          initialized!(current_revision)
          reject("phase completion cannot resolve an unclassified change") if unclassified
          reject("phase completion revision is stale") unless event["revision"] == current_revision
          reject("phase completion scope differs from the current release scope") unless scope!(event["scope"], "phase completion scope") == current_scope
          number = phase!(event["phase"], "phase completion phase")
          reject("Phase is already completed") if completed.key?(number)
          prerequisites = number > 1 ? (1...number).to_a : []
          missing = prerequisites.reject { |phase_number| completed.key?(phase_number) }
          reject("Phase completion skips incomplete prerequisites") unless missing.empty?
          authority!(event["authority"], event["actor"], event["approvalReference"])
          if USER_APPROVAL_PHASES.include?(number) && event["authority"] != "user"
            reject("Phase #{number} completion requires user authority")
          end
          nonempty_string!(event["reason"], "phase completion reason")
          %w[evidence knownDefects omittedTests unverified carryovers].each do |field|
            string_array!(event[field], "phase completion #{field}")
          end
          completed[number] = event
          unclassified = false
        when "change-classified"
          initialized!(current_revision)
          classification = event["classification"]
          reject("change classification is unsupported") unless %w[minor major unclassified].include?(classification)
          reject("change event fromRevision is stale") unless event["fromRevision"] == current_revision
          reject("change event fromScope differs") unless scope!(event["fromScope"], "change fromScope") == current_scope
          to_scope = scope!(event["toScope"], "change toScope")
          authority!(event["authority"], event["actor"], event["approvalReference"])
          %w[reason changedBefore changedAfter].each { |field| nonempty_string!(event[field], "change #{field}") }
          string_array!(event["affectedSpecifications"], "change affectedSpecifications", require_nonempty: true)
          integer_array!(event["affectedIssues"], "change affectedIssues", require_nonempty: true)
          %w[invalidatedEvidence retainedEvidence carryovers].each { |field| string_array!(event[field], "change #{field}") }

          case classification
          when "minor", "unclassified"
            reject("minor/unclassified change cannot change release revision or scope") unless
              event["toRevision"] == current_revision && to_scope == current_scope && event["reopenFromPhase"].nil?
            reject("minor change cannot invalidate accepted evidence") if classification == "minor" && !event["invalidatedEvidence"].empty?
            unclassified = classification == "unclassified"
          when "major"
            reject("major change requires user authority") unless event["authority"] == "user"
            reject("major change must increment revision exactly once") unless event["toRevision"] == current_revision + 1
            reopen = phase!(event["reopenFromPhase"], "change reopenFromPhase")
            invalidated = completed.select { |number, _| number >= reopen }.values.flat_map { |entry| Array(entry["evidence"]) }.uniq
            retained = completed.select { |number, _| number < reopen }.values.flat_map { |entry| Array(entry["evidence"]) }.uniq
            reject("major change invalidatedEvidence differs from affected Phase evidence") unless event["invalidatedEvidence"] == invalidated
            reject("major change retainedEvidence differs from unaffected Phase evidence") unless event["retainedEvidence"] == retained
            completed.delete_if { |number, _| number >= reopen }
            current_revision = event["toRevision"]
            current_scope = to_scope
            unclassified = false
          end
        when "phase-reused"
          initialized!(current_revision)
          reject("phase reuse cannot resolve an unclassified change") if unclassified
          reject("phase reuse revision is stale") unless event["revision"] == current_revision
          reject("phase reuse scope differs") unless scope!(event["scope"], "phase reuse scope") == current_scope
          reject("phase reuse route is unsupported") unless REUSE_ROUTES.include?(event["route"])
          through = phase!(event["throughPhase"], "phase reuse throughPhase")
          reject("Phase 6 cannot be reused as an existing foundation") if through == 6
          authority!(event["authority"], event["actor"], event["approvalReference"])
          reject("phase reuse requires user authority") unless event["authority"] == "user"
          foundations = string_array!(event["foundations"], "phase reuse foundations", require_nonempty: true)
          reject("phase reuse foundation is unsupported") unless (foundations - FOUNDATIONS).empty?
          nonempty_string!(event["reason"], "phase reuse reason")
          (1..through).each { |number| completed[number] ||= event }
          reuse_events << event
          unclassified = false
        end
      end

      initialized!(current_revision)
      {
        "currentRevision" => current_revision,
        "currentScope" => current_scope,
        "completedPhases" => completed,
        "reuseEvents" => reuse_events,
        "unclassifiedChange" => unclassified,
        "releaseIdentifier" => release_identifier
      }
    end

    def canonical_record(record)
      "#{JSON.generate(canonical(record))}\n"
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.each_with_object({}) { |key, result| result[key] = canonical(value[key]) }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def parse_object(bytes, at)
      value = JSON.parse(bytes)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      value
    rescue JSON::ParserError
      reject("#{at} is not valid JSON")
    end

    def exact_keys!(value, keys, at)
      reject("#{at} has unexpected or missing fields") unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def release_identifier!(value)
      reject("release identifier is invalid") unless value.is_a?(String) && value.match?(IDENTIFIER)
      value
    end

    def positive_integer!(value, at)
      reject("#{at} must be a positive integer") unless value.is_a?(Integer) && value.positive?
      value
    end

    def phase!(value, at)
      reject("#{at} must be an integer from 1 through 6") unless value.is_a?(Integer) && (1..6).cover?(value)
      value
    end

    def scope!(value, at)
      strings = string_array!(value, at, require_nonempty: true)
      reject("#{at} must be sorted") unless strings == strings.sort
      strings
    end

    def string_array!(value, at, require_nonempty: false)
      reject("#{at} must be an array") unless value.is_a?(Array)
      reject("#{at} must be nonempty") if require_nonempty && value.empty?
      reject("#{at} must contain unique nonempty strings") unless
        value.all? { |entry| entry.is_a?(String) && !entry.strip.empty? } && value.uniq == value
      value
    end

    def integer_array!(value, at, require_nonempty: false)
      reject("#{at} must be an array") unless value.is_a?(Array)
      reject("#{at} must be nonempty") if require_nonempty && value.empty?
      reject("#{at} must contain unique positive integers") unless
        value.all? { |entry| entry.is_a?(Integer) && entry.positive? } && value.uniq == value
      value
    end

    def authority!(authority, actor, reference)
      reject("approval authority must be user or delegated") unless %w[user delegated].include?(authority)
      nonempty_string!(actor, "approval actor")
      nonempty_string!(reference, "approval reference")
    end

    def nonempty_string!(value, at)
      reject("#{at} must be a nonempty string") unless value.is_a?(String) && !value.strip.empty?
      value
    end

    def time!(value, at)
      parsed = Time.iso8601(value.to_s)
      reject("#{at} must use UTC") unless parsed.utc_offset.zero? && value.end_with?("Z")
      parsed
    rescue ArgumentError
      reject("#{at} must be an ISO 8601 UTC timestamp")
    end

    def initialized!(current_revision)
      reject("release-created must be the first event") if current_revision.nil?
    end

    def reject(message)
      raise ValidationError, message
    end
  end
end
