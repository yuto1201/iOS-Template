# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"

module IOSTemplate
  module EvidenceApplicability
    class ValidationError < StandardError; end

    RECORD_KEYS = %w[
      schemaVersion release target source sourceContext targetContext diff impact decision evaluatedAt
    ].freeze
    RELEASE_KEYS = %w[identifier revision sourcePhase targetPhase scope sourceLegacy sourceRecord targetRecord].freeze
    TARGET_KEYS = %w[issue baseSha headSha issueContract].freeze
    SOURCE_KEYS = %w[issue baseSha headSha path digest issueContract completedAt].freeze
    CONTEXT_KEYS = %w[artifactDigest configurationDigest sdkDigest signingDigest scope].freeze
    DIFF_KEYS = %w[baseSha headSha digest changedPaths].freeze
    IMPACT_KEYS = %w[entries].freeze
    IMPACT_ENTRY_KEYS = %w[path classification scopes dependencies reason].freeze
    DEPENDENCY_KEYS = %w[path status digest].freeze
    DECISION_KEYS = %w[action impactScope reason].freeze
    REFERENCE_KEYS = %w[path digest].freeze
    INPUT_KEYS = %w[schemaVersion sourceVerify sourceContext targetContext impact reason evaluatedAt].freeze
    ACTIONS = %w[reuse targeted-reverify expanded-verification].freeze
    CLASSIFICATIONS = %w[unaffected affected unknown].freeze
    DIGEST = /\Asha256:[0-9a-f]{64}\z/
    SHA = /\A[0-9a-f]{40}\z/
    SOURCE_VERIFY_PATH = %r{\A\.artifacts/issues/([1-9][0-9]*)/([0-9a-f]{40})/verify\.json\z}
    RELEASE_PHASE_CUTOVER = Time.iso8601("2026-09-14T00:00:00Z").freeze

    GIT_ENV = {
      "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil,
      "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null",
      "GIT_NO_REPLACE_OBJECTS" => "1", "LANG" => "C", "LC_ALL" => "C"
    }.freeze

    module_function

    def required?(contract)
      binding = phase_binding_from_contract!(contract)
      binding && binding["phase"] == 6 && binding["workKind"] == "implementation"
    end

    def parse_input!(bytes)
      value = parse_object(bytes, "applicability input")
      exact_keys!(value, INPUT_KEYS, "applicability input")
      reject("applicability input schemaVersion must be 1") unless value["schemaVersion"] == 1
      source_path!(value["sourceVerify"])
      context!(value["sourceContext"], "sourceContext")
      context!(value["targetContext"], "targetContext")
      impact_entries!(value["impact"])
      string!(value["reason"], "applicability input reason")
      time!(value["evaluatedAt"], "applicability input evaluatedAt")
      value
    end

    def build(repo:, target_issue:, target_base_sha:, target_head_sha:, target_contract_bytes:,
              source_verify_path:, source_verify_bytes:, source_contract_bytes:,
              source_context:, target_context:, impact_entries:, reason:, evaluated_at:)
      repository!(repo)
      issue!(target_issue, "target issue")
      sha!(target_base_sha, "target Base SHA")
      sha!(target_head_sha, "target Head SHA")
      source_issue, source_head = source_path!(source_verify_path)
      source_context = context!(deep_copy(source_context), "sourceContext")
      target_context = context!(deep_copy(target_context), "targetContext")
      impact_entries = impact_entries!(deep_copy(impact_entries))
      reason = string!(reason, "decision reason")
      evaluated = time!(evaluated_at, "evaluatedAt")

      target_contract = parse_object(target_contract_bytes, "target issue contract")
      source_contract = parse_object(source_contract_bytes, "source issue contract")
      source_verify = parse_object(source_verify_bytes, "source verification")
      target_contract_digest = digest(target_contract_bytes)
      source_contract_digest = digest(source_contract_bytes)

      reject("target issue contract identity differs") unless
        target_contract["schemaVersion"] == 1 && target_contract["issue"] == target_issue
      reject("source verification identity differs from its canonical path") unless
        source_verify["schemaVersion"] == 1 && source_verify["issue"] == source_issue &&
        source_verify["headSha"] == source_head && source_verify["status"] == "passed"
      source_base = sha!(source_verify["baseSha"], "source verification Base SHA")
      source_contract_reference = reference!(source_verify["issueContract"], "source verification issueContract")
      expected_source_contract_path = ".artifacts/issues/#{source_issue}/issue-contract.json"
      reject("source verification contract reference is not canonical") unless
        source_contract_reference == {"path" => expected_source_contract_path, "digest" => source_contract_digest}
      reject("source issue contract identity differs") unless
        source_contract["schemaVersion"] == 1 && source_contract["issue"] == source_issue

      source_completed_at = time!(source_verify["completedAt"], "source verification completedAt")
      reject("applicability evaluation predates source verification") if evaluated < source_completed_at
      reject("applicability evaluation is implausibly in the future") if evaluated > Time.now.utc + 300

      target_binding = phase_binding!(target_contract, phase: 6, at: "target")
      source_binding, source_legacy = source_phase_binding!(source_contract, target_binding)
      reject("source and target release identifiers differ") unless
        source_binding["releaseIdentifier"] == target_binding["releaseIdentifier"]
      reject("source and target release revisions differ") unless
        source_binding["revision"] == target_binding["revision"]
      reject("target release scope is outside the Phase 5 source scope") unless
        (target_binding["scope"] - source_binding["scope"]).empty?
      reject("source evidence context scope is outside the Phase 5 binding") unless
        (source_context["scope"] - source_binding["scope"]).empty?
      reject("target evidence context scope differs from the Phase 6 binding") unless
        target_context["scope"] == target_binding["scope"]

      current_head!(repo, target_head_sha)
      commit!(repo, target_base_sha, "target Base")
      commit!(repo, target_head_sha, "target Head")
      commit!(repo, source_base, "source Base")
      commit!(repo, source_head, "source Head")
      ancestor!(repo, target_base_sha, target_head_sha, "target Base")
      ancestor!(repo, source_base, source_head, "source Base")
      ancestor!(repo, source_head, target_head_sha, "source Head") unless source_head == target_head_sha

      diff_bytes = actual_diff(repo: repo, base_sha: source_head, head_sha: target_head_sha)
      changed_paths = changed_paths(repo: repo, base_sha: source_head, head_sha: target_head_sha)
      reject("impact entries do not exactly cover the immutable source..target diff") unless
        impact_entries.map { |entry| entry.fetch("path") } == changed_paths
      validate_dependencies!(repo, target_head_sha, impact_entries)

      action, impact_scope = decision_for(
        source_head: source_head, target_head: target_head_sha,
        source_context: source_context, target_context: target_context,
        entries: impact_entries, target_scope: target_binding.fetch("scope")
      )

      record = {
        "schemaVersion" => 1,
        "release" => {
          "identifier" => target_binding.fetch("releaseIdentifier"),
          "revision" => target_binding.fetch("revision"),
          "sourcePhase" => 5,
          "targetPhase" => 6,
          "scope" => target_binding.fetch("scope"),
          "sourceLegacy" => source_legacy,
          "sourceRecord" => source_legacy ? nil : {"path" => source_binding.fetch("recordPath"), "digest" => source_binding.fetch("recordDigest")},
          "targetRecord" => {"path" => target_binding.fetch("recordPath"), "digest" => target_binding.fetch("recordDigest")}
        },
        "target" => {
          "issue" => target_issue, "baseSha" => target_base_sha, "headSha" => target_head_sha,
          "issueContract" => {"path" => ".artifacts/issues/#{target_issue}/issue-contract.json", "digest" => target_contract_digest}
        },
        "source" => {
          "issue" => source_issue, "baseSha" => source_base, "headSha" => source_head,
          "path" => source_verify_path, "digest" => digest(source_verify_bytes),
          "issueContract" => source_contract_reference, "completedAt" => source_verify.fetch("completedAt")
        },
        "sourceContext" => source_context,
        "targetContext" => target_context,
        "diff" => {
          "baseSha" => source_head, "headSha" => target_head_sha,
          "digest" => digest(diff_bytes), "changedPaths" => changed_paths
        },
        "impact" => {"entries" => impact_entries},
        "decision" => {"action" => action, "impactScope" => impact_scope, "reason" => reason},
        "evaluatedAt" => evaluated_at
      }
      validate_record_shape!(record)
      canonical(record)
    end

    def validate!(record_bytes:, repo:, target_contract_bytes:, source_verify_bytes:, source_contract_bytes:)
      record = parse_object(record_bytes, "evidence applicability")
      validate_record_shape!(record)
      reject("evidence applicability must use canonical bytes") unless record_bytes.b == JSON.generate(canonical(record)).b
      source = record.fetch("source")
      expected = build(
        repo: repo,
        target_issue: record.dig("target", "issue"),
        target_base_sha: record.dig("target", "baseSha"),
        target_head_sha: record.dig("target", "headSha"),
        target_contract_bytes: target_contract_bytes,
        source_verify_path: source.fetch("path"),
        source_verify_bytes: source_verify_bytes,
        source_contract_bytes: source_contract_bytes,
        source_context: record.fetch("sourceContext"),
        target_context: record.fetch("targetContext"),
        impact_entries: record.dig("impact", "entries"),
        reason: record.dig("decision", "reason"),
        evaluated_at: record.fetch("evaluatedAt")
      )
      reject("evidence applicability differs from immutable inputs") unless record == expected
      record
    end

    def references!(record_bytes:, target_issue:, target_head_sha:)
      record = parse_object(record_bytes, "evidence applicability")
      validate_record_shape!(record)
      reject("evidence applicability target differs from caller") unless
        record.dig("target", "issue") == target_issue && record.dig("target", "headSha") == target_head_sha
      source = record.fetch("source")
      {
        "record" => {
          "path" => ".artifacts/issues/#{target_issue}/#{target_head_sha}/evidence-applicability.json",
          "digest" => digest(record_bytes)
        },
        "sourceVerify" => {"path" => source.fetch("path"), "digest" => source.fetch("digest")},
        "sourceContract" => source.fetch("issueContract")
      }
    end

    def canonical_bytes(record)
      JSON.generate(canonical(record)).b
    end

    def validate_record_shape!(record)
      exact_keys!(record, RECORD_KEYS, "evidence applicability")
      reject("evidence applicability schemaVersion must be 1") unless record["schemaVersion"] == 1
      exact_keys!(record["release"], RELEASE_KEYS, "release")
      release = record.fetch("release")
      reject("release identifier is invalid") unless release["identifier"].is_a?(String) && release["identifier"].match?(release_phase.const_get(:IDENTIFIER))
      issue!(release["revision"], "release revision")
      reject("release phases must be Phase 5 to Phase 6") unless release.values_at("sourcePhase", "targetPhase") == [5, 6]
      scope!(release["scope"], "release scope")
      reject("release sourceLegacy must be a boolean") unless [true, false].include?(release["sourceLegacy"])
      if release["sourceLegacy"]
        reject("legacy source must not synthesize a Phase 5 record") unless release["sourceRecord"].nil?
      else
        reference!(release["sourceRecord"], "release sourceRecord")
      end
      reference!(release["targetRecord"], "release targetRecord")

      exact_keys!(record["target"], TARGET_KEYS, "target")
      issue!(record.dig("target", "issue"), "target issue")
      sha!(record.dig("target", "baseSha"), "target Base SHA")
      sha!(record.dig("target", "headSha"), "target Head SHA")
      reference!(record.dig("target", "issueContract"), "target issueContract")

      exact_keys!(record["source"], SOURCE_KEYS, "source")
      source = record.fetch("source")
      issue!(source["issue"], "source issue")
      sha!(source["baseSha"], "source Base SHA")
      sha!(source["headSha"], "source Head SHA")
      parsed_issue, parsed_head = source_path!(source["path"])
      reject("source path identity differs") unless [parsed_issue, parsed_head] == source.values_at("issue", "headSha")
      digest!(source["digest"], "source digest")
      reference!(source["issueContract"], "source issueContract")
      time!(source["completedAt"], "source completedAt")

      context!(record["sourceContext"], "sourceContext")
      context!(record["targetContext"], "targetContext")
      exact_keys!(record["diff"], DIFF_KEYS, "diff")
      reject("diff identity differs from source and target") unless
        record["diff"].values_at("baseSha", "headSha") == [source["headSha"], record.dig("target", "headSha")]
      digest!(record.dig("diff", "digest"), "diff digest")
      paths = paths!(record.dig("diff", "changedPaths"), "diff changedPaths")
      entries = impact_entries!(record.dig("impact", "entries"))
      exact_keys!(record["impact"], IMPACT_KEYS, "impact")
      reject("impact entries differ from diff paths") unless entries.map { |entry| entry["path"] } == paths

      exact_keys!(record["decision"], DECISION_KEYS, "decision")
      reject("decision action is invalid") unless ACTIONS.include?(record.dig("decision", "action"))
      scope!(record.dig("decision", "impactScope"), "decision impactScope", allow_empty: true)
      string!(record.dig("decision", "reason"), "decision reason")
      time!(record["evaluatedAt"], "evaluatedAt")
      record
    end

    def decision_for(source_head:, target_head:, source_context:, target_context:, entries:, target_scope:)
      unknown = entries.any? { |entry| entry["classification"] == "unknown" }
      missing = entries.any? { |entry| entry["dependencies"].any? { |dependency| dependency["status"] == "missing" } }
      scope_expanded = !(target_context.fetch("scope") - source_context.fetch("scope")).empty?
      impact_scope = entries.flat_map { |entry| entry.fetch("scopes") }.uniq.sort

      if unknown || missing || scope_expanded
        ["expanded-verification", (impact_scope + target_scope).uniq.sort]
      elsif source_head != target_head || source_context != target_context || entries.any? { |entry| entry["classification"] == "affected" }
        ["targeted-reverify", (impact_scope + target_scope).uniq.sort]
      else
        ["reuse", impact_scope]
      end
    end

    def context!(value, at)
      exact_keys!(value, CONTEXT_KEYS, at)
      %w[artifactDigest configurationDigest sdkDigest signingDigest].each { |key| digest!(value[key], "#{at}.#{key}") }
      scope!(value["scope"], "#{at}.scope")
      value
    end

    def impact_entries!(value)
      reject("impact must be an array") unless value.is_a?(Array)
      value.each_with_index do |entry, index|
        exact_keys!(entry, IMPACT_ENTRY_KEYS, "impact[#{index}]")
        path!(entry["path"], "impact[#{index}].path")
        reject("impact classification is invalid") unless CLASSIFICATIONS.include?(entry["classification"])
        scope!(entry["scopes"], "impact[#{index}].scopes", allow_empty: true)
        string!(entry["reason"], "impact[#{index}].reason")
        dependencies = entry["dependencies"]
        reject("impact dependencies must be an array") unless dependencies.is_a?(Array)
        dependencies.each_with_index do |dependency, dependency_index|
          exact_keys!(dependency, DEPENDENCY_KEYS, "impact[#{index}].dependencies[#{dependency_index}]")
          path!(dependency["path"], "impact dependency path")
          reject("impact dependency status is invalid") unless %w[present missing].include?(dependency["status"])
          if dependency["status"] == "present"
            digest!(dependency["digest"], "impact dependency digest")
          else
            reject("missing dependency digest must be null") unless dependency["digest"].nil?
          end
        end
        reject("impact dependencies must be unique and sorted") unless
          dependencies.map { |dependency| dependency["path"] } == dependencies.map { |dependency| dependency["path"] }.uniq.sort
      end
      reject("impact entries must be unique and sorted") unless
        value.map { |entry| entry["path"] } == value.map { |entry| entry["path"] }.uniq.sort
      value
    end

    def validate_dependencies!(repo, head, entries)
      entries.each do |entry|
        entry.fetch("dependencies").each do |dependency|
          bytes = blob_at(repo, head, dependency.fetch("path"))
          if dependency["status"] == "present"
            reject("declared dependency is missing: #{dependency['path']}") unless bytes
            reject("dependency digest differs: #{dependency['path']}") unless dependency["digest"] == digest(bytes)
          else
            reject("declared missing dependency exists: #{dependency['path']}") if bytes
          end
        end
      end
    end

    def phase_binding!(contract, phase:, at:)
      binding = phase_binding_from_contract!(contract)
      reject("#{at} issue contract lacks a Release-phase binding") unless binding
      reject("#{at} issue contract must bind Phase #{phase} implementation") unless
        binding["phase"] == phase && binding["workKind"] == "implementation"
      binding
    end

    # A Phase 5 proof sealed before the release-phase contract cutover remains
    # usable as an immutable source. The Phase 6 target binding supplies the
    # release/revision/scope identity; no binding is synthesized back into the
    # legacy Issue contract. Post-cutover source proofs must bind Phase 5.
    def source_phase_binding!(contract, target_binding)
      binding = phase_binding_from_contract!(contract)
      if binding
        reject("source issue contract must bind Phase 5 implementation") unless
          binding["phase"] == 5 && binding["workKind"] == "implementation"
        return [binding, false]
      end
      fetched_at = time!(contract["fetchedAt"], "source issue contract fetchedAt")
      reject("post-cutover Phase 5 source contract lacks a Release-phase binding") unless fetched_at < RELEASE_PHASE_CUTOVER
      [target_binding.merge("phase" => 5), true]
    end

    def phase_binding_from_contract!(contract)
      release_phase.binding_from_contract!(contract)
    rescue StandardError => error
      if defined?(IOSTemplate::ReleasePhase::ValidationError) && error.is_a?(IOSTemplate::ReleasePhase::ValidationError)
        reject(error.message)
      end
      raise
    end

    def release_phase
      require_relative "workflow-release-phase" unless defined?(IOSTemplate::ReleasePhase)
      IOSTemplate::ReleasePhase
    rescue LoadError => error
      reject("release phase validator is unavailable: #{error.message}")
    end

    def actual_diff(repo:, base_sha:, head_sha:)
      git!(repo, "diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--no-renames",
           "--src-prefix=a/", "--dst-prefix=b/", base_sha, head_sha, "--")
    end

    def changed_paths(repo:, base_sha:, head_sha:)
      git!(repo, "diff", "--name-only", "-z", "--no-renames", base_sha, head_sha, "--")
        .split("\0").reject(&:empty?).sort
    end

    def blob_at(repo, head, path)
      tree = git!(repo, "ls-tree", "-z", head, "--", path)
      entries = tree.split("\0").reject(&:empty?)
      return nil if entries.empty?
      reject("dependency path is ambiguous: #{path}") unless entries.length == 1
      metadata, actual_path = entries.first.split("\t", 2)
      mode, type, object = metadata.to_s.split(" ")
      reject("dependency path does not name an exact regular blob: #{path}") unless
        actual_path == path && type == "blob" && %w[100644 100755].include?(mode)
      git!(repo, "cat-file", "blob", object)
    end

    def git!(repo, *arguments)
      output, error, status = Open3.capture3(GIT_ENV, "/usr/bin/git", "-C", repo,
                                             "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", *arguments)
      reject("Git lookup failed: #{arguments.first}: #{error.strip}") unless status.success?
      output.b
    end

    def commit!(repo, sha, at)
      _, _, status = Open3.capture3(GIT_ENV, "/usr/bin/git", "-C", repo, "cat-file", "-e", "#{sha}^{commit}")
      reject("#{at} is not an available commit") unless status.success?
    end

    def ancestor!(repo, ancestor, descendant, at)
      _, _, status = Open3.capture3(GIT_ENV, "/usr/bin/git", "-C", repo, "merge-base", "--is-ancestor", ancestor, descendant)
      reject("#{at} is not an ancestor of the corresponding Head") unless status.success?
    end

    def current_head!(repo, expected)
      reject("current Head differs from applicability target") unless git!(repo, "rev-parse", "HEAD").strip == expected
    end

    def repository!(repo)
      reject("repository root must be a physical absolute directory") unless
        repo.is_a?(String) && repo.start_with?("/") && File.directory?(repo) && File.realpath(repo) == repo
      repo
    rescue Errno::ENOENT, Errno::EACCES
      reject("repository root is unavailable")
    end

    def source_path!(value)
      match = value.is_a?(String) && value.match(SOURCE_VERIFY_PATH)
      reject("source verification path is not canonical") unless match
      [Integer(match[1]), match[2]]
    end

    def reference!(value, at)
      exact_keys!(value, REFERENCE_KEYS, at)
      path!(value["path"], "#{at}.path")
      digest!(value["digest"], "#{at}.digest")
      value
    end

    def paths!(value, at)
      reject("#{at} must be an array") unless value.is_a?(Array)
      value.each { |path| path!(path, at) }
      reject("#{at} must be unique and sorted") unless value == value.uniq.sort
      value
    end

    def scope!(value, at, allow_empty: false)
      reject("#{at} must be an array") unless value.is_a?(Array)
      reject("#{at} must not be empty") if !allow_empty && value.empty?
      reject("#{at} must contain sorted unique identifiers") unless
        value == value.uniq.sort && value.all? { |entry| entry.is_a?(String) && entry.match?(/\A[a-z0-9][a-z0-9._-]{0,79}\z/) }
      value
    end

    def path!(value, at)
      reject("#{at} must be a safe relative path") unless value.is_a?(String) && !value.empty? &&
        !value.start_with?("/") && !value.include?("\0") &&
        value.split("/", -1).none? { |component| component.empty? || component == "." || component == ".." }
      value
    end

    def issue!(value, at)
      reject("#{at} must be a positive integer") unless value.is_a?(Integer) && value.positive?
      value
    end

    def sha!(value, at)
      reject("#{at} must be a lowercase 40-character SHA") unless value.is_a?(String) && value.match?(SHA)
      value
    end

    def digest!(value, at)
      reject("#{at} must be a sha256 digest") unless value.is_a?(String) && value.match?(DIGEST)
      value
    end

    def string!(value, at)
      reject("#{at} must be a nonempty string") unless value.is_a?(String) && value == value.strip && !value.empty? && !value.include?("\0")
      value
    end

    def time!(value, at)
      Time.iso8601(string!(value, at)).utc
    rescue ArgumentError
      reject("#{at} must be ISO 8601")
    end

    def parse_object(bytes, at)
      value = JSON.parse(bytes.dup)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      value
    rescue JSON::ParserError => error
      reject("#{at} is not readable JSON: #{error.message}")
    end

    def exact_keys!(value, keys, at)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      reject("#{at} has unexpected or missing fields") unless value.keys.sort == keys.sort
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def digest(bytes)
      "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def reject(message)
      raise ValidationError, message
    end
  end
end
