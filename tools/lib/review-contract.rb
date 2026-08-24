# frozen_string_literal: true

require "digest"
require "json"
require "time"

module IOSTemplate
  module ReviewContract
    class ValidationError < StandardError; end

    module_function

    PACKET_KEYS = %w[
      schemaVersion issue primaryModel reviewerModel baseSha headSha verifySha
      issueContract specAnchors acceptanceCriteria diffFile verifyFile imageFiles
    ].freeze
    RESULT_KEYS = %w[
      schemaVersion issue reviewerModel baseSha headSha verifySha
      issueContractDigest verdict findings acceptanceAssessment reviewedAt
    ].freeze

    def validate!(packet_bytes:, result_bytes:, verify_bytes:, contract_bytes:, primary:, issue:, base_sha:, head_sha:, now: Time.now.utc, require_temporal_order: false)
      reject("primary model is invalid") unless %w[codex claude].include?(primary)
      reviewer = primary == "codex" ? "claude" : "codex"
      packet = parse_object(packet_bytes, "packet")
      result = parse_object(result_bytes, "result")
      verify = parse_object(verify_bytes, "verify")
      contract = parse_object(contract_bytes, "issue contract")
      digest = "sha256:#{Digest::SHA256.hexdigest(contract_bytes)}"

      exact_keys!(packet, PACKET_KEYS, "packet")
      reject("packet.schemaVersion must be 1") unless packet["schemaVersion"] == 1
      reject("packet identity does not match the merge identity") unless
        packet["issue"] == issue && packet["primaryModel"] == primary &&
        packet["reviewerModel"] == reviewer && packet["baseSha"] == base_sha &&
        packet["headSha"] == head_sha && packet["verifySha"] == head_sha
      exact_keys!(packet["issueContract"], %w[path digest], "packet.issueContract")
      expected_contract_path = ".artifacts/issues/#{issue}/issue-contract.json"
      reject("packet issue contract does not match exact bytes") unless
        packet["issueContract"] == {"path" => expected_contract_path, "digest" => digest}

      exact_keys!(contract, %w[schemaVersion issue repository goal specAnchors acceptanceCriteria dependencies externalOperations fetchedAt], "issue contract")
      reject("issue contract identity is invalid") unless contract["schemaVersion"] == 1 && contract["issue"] == issue
      anchors = unique_nonempty_strings!(packet["specAnchors"], "packet.specAnchors", require_nonempty: true)
      reject("packet spec anchors do not match issue contract") unless anchors == contract["specAnchors"]
      criteria = packet["acceptanceCriteria"]
      reject("packet.acceptanceCriteria must be a nonempty array") unless criteria.is_a?(Array) && !criteria.empty?
      criteria.each_with_index do |criterion, index|
        exact_keys!(criterion, %w[id text], "packet.acceptanceCriteria[#{index}]")
        reject("packet acceptance criteria must have ordered IDs") unless criterion["id"] == "AC-#{index + 1}"
        string!(criterion["text"], "packet.acceptanceCriteria[#{index}].text")
      end
      reject("packet acceptance criteria do not match issue contract") unless criteria == contract["acceptanceCriteria"]
      expected_prefix = ".artifacts/issues/#{issue}/#{head_sha}/"
      reject("packet.diffFile is not canonical") unless packet["diffFile"] == "#{expected_prefix}review.diff"
      reject("packet.verifyFile is not canonical") unless packet["verifyFile"] == "#{expected_prefix}verify.json"
      images = unique_nonempty_strings!(packet["imageFiles"], "packet.imageFiles")
      images.each { |path| safe_relative!(path, "packet.imageFiles") }

      reject("verify identity does not match packet") unless
        verify.is_a?(Hash) && verify["schemaVersion"] == 1 && verify["issue"] == issue &&
        verify["baseSha"] == base_sha && verify["headSha"] == head_sha
      exact_keys!(verify["issueContract"], %w[path digest], "verify.issueContract")
      reject("verify issue contract does not match packet") unless verify["issueContract"] == packet["issueContract"]
      completed_at = iso8601!(verify["completedAt"], "verify.completedAt") if require_temporal_order

      exact_keys!(result, RESULT_KEYS, "result")
      reject("result.schemaVersion must be 1") unless result["schemaVersion"] == 1
      reject("result identity does not match packet") unless
        result["issue"] == issue && result["reviewerModel"] == reviewer &&
        result["baseSha"] == base_sha && result["headSha"] == head_sha &&
        result["verifySha"] == head_sha && result["issueContractDigest"] == digest
      verdict = result["verdict"]
      reject("result.verdict is invalid") unless %w[approved changes-requested].include?(verdict)
      findings = result["findings"]
      reject("result.findings must be an array") unless findings.is_a?(Array)
      findings.each_with_index do |finding, index|
        exact_keys!(finding, %w[severity category file line title evidence requiredChange], "result.findings[#{index}]")
        reject("result.findings[#{index}].severity is invalid") unless %w[critical high medium low].include?(finding["severity"])
        reject("result.findings[#{index}].category is invalid") unless string!(finding["category"], "result.findings[#{index}].category").match?(/\A[a-z][a-z-]*\z/)
        safe_relative!(string!(finding["file"], "result.findings[#{index}].file"), "result.findings[#{index}].file")
        reject("result.findings[#{index}].line must be positive") unless finding["line"].is_a?(Integer) && finding["line"].positive?
        %w[title evidence requiredChange].each { |key| string!(finding[key], "result.findings[#{index}].#{key}") }
      end
      assessments = result["acceptanceAssessment"]
      reject("result.acceptanceAssessment must match packet criteria") unless assessments.is_a?(Array) && assessments.length == criteria.length
      assessments.each_with_index do |assessment, index|
        exact_keys!(assessment, %w[id status evidence], "result.acceptanceAssessment[#{index}]")
        reject("result.acceptanceAssessment IDs must match packet") unless assessment["id"] == criteria[index]["id"]
        reject("result.acceptanceAssessment status is invalid") unless %w[supported unsupported].include?(assessment["status"])
        evidence = unique_nonempty_strings!(assessment["evidence"], "result.acceptanceAssessment[#{index}].evidence", require_nonempty: true)
        evidence.each { |reference| safe_reference!(reference, "result.acceptanceAssessment[#{index}].evidence") }
      end
      reviewed_at = iso8601!(result["reviewedAt"], "result.reviewedAt")
      reject("result.reviewedAt must be after verify.completedAt") if require_temporal_order && reviewed_at <= completed_at
      reject("result.reviewedAt is implausibly in the future") if reviewed_at > now + 300
      if verdict == "approved"
        reject("approved result must have no findings") unless findings.empty?
        reject("approved result must support every acceptance criterion") unless assessments.all? { |entry| entry["status"] == "supported" }
      else
        blocking = findings.any? { |finding| %w[critical high medium].include?(finding["severity"]) } || assessments.any? { |entry| entry["status"] == "unsupported" }
        reject("changes-requested result must contain a blocking finding or unsupported criterion") unless blocking
      end
      {"packet" => packet, "result" => result, "verify" => verify, "contract" => contract}
    end

    def parse_object(bytes, at)
      value = JSON.parse(bytes)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      value
    rescue JSON::ParserError => error
      reject("#{at} is not readable JSON: #{error.message}")
    end

    def exact_keys!(value, keys, at)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      reject("#{at}: unexpected or missing keys") unless value.keys.sort == keys.sort
    end

    def string!(value, at)
      reject("#{at} must be a nonempty string") unless value.is_a?(String) && !value.empty? && !value.include?("\0")
      value
    end

    def unique_nonempty_strings!(value, at, require_nonempty: false)
      reject("#{at} must be an array") unless value.is_a?(Array)
      reject("#{at} must not be empty") if require_nonempty && value.empty?
      reject("#{at} must contain unique nonempty strings") unless value.uniq == value && value.all? { |entry| entry.is_a?(String) && !entry.empty? && !entry.include?("\0") }
      value
    end

    def safe_relative!(value, at)
      reject("#{at} must be a safe relative path") if value.start_with?("/") || value.split("/").any? { |part| part.empty? || part == "." || part == ".." }
      value
    end

    def safe_reference!(value, at)
      reject("#{at} must be a safe relative reference") if value.start_with?("/") || value.split("#", 2).first.split("/").include?("..")
    end

    def iso8601!(value, at)
      Time.iso8601(string!(value, at)).utc
    rescue ArgumentError
      reject("#{at} must be ISO 8601")
    end

    def reject(message)
      raise ValidationError, message
    end
  end
end
