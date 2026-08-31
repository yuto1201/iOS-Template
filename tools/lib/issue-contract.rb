#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "time"
require "digest"
require_relative "delivery-profile"

module IOSTemplate
  module IssueContract
    REQUIRED_HEADINGS = [
      "Goal",
      "In scope",
      "Out of scope",
      "Acceptance criteria",
      "Spec anchors",
      "Dependencies",
      "UI verification",
      "External operations",
      "User approvals"
    ].freeze

    OPERATION_FIELDS = [
      "Operation",
      "Service",
      "Environment",
      "Executor",
      "Approval required"
    ].freeze

    SERVICE_BY_PREFIX = {
      "github" => "GitHub",
      "supabase" => "Supabase",
      "cloudflare" => "Cloudflare",
      "linear" => "Linear",
      "vercel" => "Vercel",
      "elevenlabs" => "ElevenLabs",
      "appstore" => "App Store Connect"
    }.freeze

    ALLOWED_OPERATIONS = %w[
      github.read_issue
      github.create_issue
      github.update_issue
      github.push_branch
      github.create_pr
      github.merge_pr
      github.delete_branch
      github.sync_labels
      supabase.inspect_project
      supabase.apply_migrations
      cloudflare.inspect_account
      cloudflare.deploy
      linear.inspect_workspace
      vercel.inspect_team
      elevenlabs.generate_audio
      elevenlabs.process_media
      appstore.inspect_app
      appstore.upload_build
      appstore.update_metadata
      appstore.submit_review
    ].freeze

    ENVIRONMENTS = %w[local preview staging production].freeze
    SNAPSHOT_REQUIRED_KEYS = %w[
      schemaVersion issue repository goal specAnchors acceptanceCriteria dependencies
      externalOperations externalOperationDetailsDigest fetchedAt
    ].freeze
    SNAPSHOT_OPTIONAL_KEYS = %w[verification deliveryProfile].freeze
    VERIFICATION_CASE_IDS = %w[iphone-en iphone-ja ipad-en ipad-ja].freeze
    VERIFICATION_CHECKS = (
      %w[stage:build stage:unit-tests] +
      VERIFICATION_CASE_IDS.map { |id| "case:#{id}" } +
      VERIFICATION_CASE_IDS.map { |id| "visual:#{id}" }
    ).freeze
    BUNDLE_IDENTIFIER = /\A[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+\z/
    TEST_IDENTIFIER = %r{\A[A-Za-z_][A-Za-z0-9_.-]*/[A-Za-z_][A-Za-z0-9_.-]*/[A-Za-z_][A-Za-z0-9_.-]*(\(\))?\z}

    # JSON's default last-key-wins behavior would hide ambiguous operator input.
    class UniqueVerificationKeys < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate Verification key" if key?(key)

        super
      end
    end

    Result = Struct.new(:contract, :external_operation_details, keyword_init: true)

    class ValidationError < StandardError
      attr_reader :failures

      def initialize(failures)
        @failures = failures.freeze
        super(failures.join("\n"))
      end
    end

    module_function

    # Shared producer/reconstruction interface. Callers that only validate may
    # omit snapshot metadata. Claim and live pre-merge reconstruction pass all
    # three metadata fields and consume Result#contract plus the structured
    # operation details from the same parse.
    def parse_file(path, issue_type: "feature", issue: nil, repository: nil, fetched_at: nil)
      body = File.read(path, encoding: "UTF-8")
      parse(
        body,
        issue_type: issue_type,
        issue: issue,
        repository: repository,
        fetched_at: fetched_at
      )
    end

    def parse(body, issue_type: "feature", issue: nil, repository: nil, fetched_at: nil)
      failures = []
      unless %w[feature regression docs release].include?(issue_type)
        failures << "Issue type must be feature, regression, docs, or release"
      end

      lines = body.lines
      headings = []
      lines.each_with_index do |line, index|
        match = line.match(/\A(#+)\s+(.+?)\s*\z/)
        headings << [match[2], index] if match
      end

      required_headings = REQUIRED_HEADINGS.dup
      required_headings.concat(["Original PR", "Reproduction steps"]) if issue_type == "regression"
      sections = {}
      required_headings.each do |heading|
        indexes = headings.each_index.select { |index| headings[index][0] == heading }
        if indexes.empty?
          label = issue_type == "regression" && ["Original PR", "Reproduction steps"].include?(heading) ? "Regression Issue missing required heading" : "missing required heading"
          failures << "#{label}: #{heading}"
          next
        end

        duplicate_label = issue_type == "regression" && ["Original PR", "Reproduction steps"].include?(heading) ? "duplicate Regression heading" : "duplicate required heading"
        failures << "#{duplicate_label}: #{heading}" if indexes.length > 1
        heading_index = headings[indexes.first][1]
        next_heading = headings.find { |_, line_index| line_index > heading_index }
        end_index = next_heading ? next_heading[1] : lines.length
        sections[heading] = lines[(heading_index + 1)...end_index].join
        empty_label = issue_type == "regression" && ["Original PR", "Reproduction steps"].include?(heading) ? "Regression Issue section is empty" : "required section is empty"
        failures << "#{empty_label}: #{heading}" if sections[heading].strip.empty?
      end

      acceptance = sections.fetch("Acceptance criteria", "")
      acceptance_items = acceptance.each_line.map do |line|
        match = line.match(/^\s*[-*]\s+(AC-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)\s*:\s*(\S.*?)\s*$/)
        match && {"id" => match[1], "text" => match[2]}
      end.compact
      failures << "Acceptance criteria must contain at least one '- AC-*:' item" if acceptance_items.empty?
      duplicate_acceptance = acceptance_items.map { |item| item.fetch("id") }.group_by(&:itself).select { |_, items| items.length > 1 }.keys
      failures << "duplicate acceptance criteria ID: #{duplicate_acceptance.join(', ')}" unless duplicate_acceptance.empty?

      spec_anchor_section = sections.fetch("Spec anchors", "")
      unless spec_anchor_section.match?(/\[[^\]]+\]\((?:<)?(?:\.\/)?specs\/[^)\s]+\.md#[^)\s]+(?:>)?\)/)
        failures << "Spec anchors must contain a local Markdown link to specs/ with a section anchor"
      end

      ui_verification = sections.fetch("UI verification", "")
      unless ui_verification.match?(/\A\s*(?:[-*]\s*)?Not applicable\.?\s*\z/i)
        ui_fields = ui_verification.each_line.map do |line|
          match = line.match(/^\s*[-*]\s+(Target screens\/states|English expectations|Japanese expectations):\s*(\S.*?)\s*$/)
          match&.captures
        end.compact
        expected_ui_fields = ["Target screens/states", "English expectations", "Japanese expectations"]
        if ui_fields.map(&:first) != expected_ui_fields || ui_fields.any? { |_, value| value.strip.empty? }
          failures << "UI verification must be Not applicable or contain Target screens/states, English expectations, and Japanese expectations in order"
        end
      end

      external_details = parse_external_operations(
        sections.fetch("External operations", ""),
        sections.fetch("User approvals", ""),
        failures
      )

      verification = parse_verification(lines, headings, acceptance_items.map { |item| item.fetch("id") }, failures)
      delivery_profile = parse_delivery_profile(lines, headings, failures)
      if delivery_profile
        name = delivery_profile.fetch("name")
        if name == "fast" && verification
          failures << "fast delivery profile cannot contain application Verification"
        end
        if name == "fast" && !ui_verification.match?(/\A\s*(?:[-*]\s*)?Not applicable\.?\s*\z/i)
          failures << "fast delivery profile requires UI verification to be Not applicable"
        end
        if name != "strict" && external_details.any? { |detail| DeliveryProfile.strict_operation?(detail.fetch("operation")) }
          failures << "high-risk external operations require strict delivery profile"
        end
        if name != "strict" && external_details.any? { |detail| detail.fetch("approvalRequired") }
          failures << "approval-required operations require strict delivery profile"
        end
      end

      snapshot_requested = !issue.nil? || !repository.nil? || !fetched_at.nil?
      contract = nil
      if snapshot_requested
        issue_number = begin
          Integer(issue)
        rescue ArgumentError, TypeError
          nil
        end
        failures << "Issue number must be a positive integer" unless issue_number&.positive?
        failures << "Repository must be OWNER/REPO" unless repository&.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
        begin
          Time.iso8601(fetched_at.to_s)
        rescue ArgumentError
          failures << "fetchedAt must be an ISO 8601 timestamp"
        end

        numeric_acceptance = acceptance.each_line.map do |line|
          match = line.match(/^\s*[-*]\s+(AC-(\d+))\s*:\s*(\S.*?)\s*$/)
          match && {"id" => match[1], "text" => match[3]}
        end.compact
        numeric_acceptance.each_with_index do |item, index|
          failures << "Acceptance criteria must be AC-1 through AC-n" unless item.fetch("id") == "AC-#{index + 1}"
        end
        if numeric_acceptance.length != acceptance_items.length
          failures << "Canonical acceptance criteria must use numeric AC-1 through AC-n identifiers"
        end

        goal = sections.fetch("Goal", "").strip
        anchors = spec_anchor_section.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten.map do |raw|
          raw.strip.sub(/\A</, "").sub(/>\z/, "")
        end.uniq
        failures << "Issue body has no specification anchors" if anchors.empty?

        dependencies_section = sections.fetch("Dependencies", "")
        dependencies = if none_value?(dependencies_section)
          []
        else
          dependencies_section.scan(/#([1-9][0-9]*)/).flatten.map(&:to_i).uniq
        end

        contract = {
          "schemaVersion" => 1,
          "issue" => issue_number,
          "repository" => repository,
          "goal" => goal,
          "specAnchors" => anchors,
          "acceptanceCriteria" => numeric_acceptance,
          "dependencies" => dependencies,
          "externalOperations" => external_details.map { |detail| detail.fetch("operation") },
          "externalOperationDetailsDigest" => "sha256:#{Digest::SHA256.hexdigest(canonical_json(external_details))}",
          "fetchedAt" => fetched_at
        }
        contract["deliveryProfile"] = delivery_profile if delivery_profile
        contract["verification"] = verification if verification
      end

      raise ValidationError, failures unless failures.empty?

      Result.new(contract: contract, external_operation_details: external_details)
    end

    def parse_verification(lines, headings, acceptance_ids, failures)
      matches = headings.select { |heading, _| heading == "Verification" }
      return nil if matches.empty?
      if matches.length != 1
        failures << "duplicate optional heading: Verification"
        return nil
      end
      start = matches.first[1]
      following = headings.find { |_, index| index > start }
      section = lines[(start + 1)...(following ? following[1] : lines.length)].join.strip
      return nil if ["_No response_", "Not applicable"].include?(section)

      fence = section.match(/\A```json[ \t]*\r?\n(.*)\r?\n```[ \t]*\z/m)
      json = fence ? fence[1] : section
      value = JSON.parse(json, object_class: UniqueVerificationKeys)
      validate_verification(value, acceptance_ids, failures)
      value
    rescue JSON::ParserError
      failures << "Verification must contain one unambiguous JSON object, optionally fenced as json"
      nil
    end

    def validate_verification(value, acceptance_ids, failures)
      unless value.is_a?(Hash) && value.keys.sort == %w[acceptanceMappings bundleIdentifier cases unitTestIdentifier]
        failures << "Verification must contain exactly bundleIdentifier, unitTestIdentifier, cases, and acceptanceMappings"
        return
      end
      unless value["bundleIdentifier"].is_a?(String) && value["bundleIdentifier"].match?(BUNDLE_IDENTIFIER)
        failures << "Verification bundleIdentifier is invalid"
      end
      unless value["unitTestIdentifier"].is_a?(String) && value["unitTestIdentifier"].match?(TEST_IDENTIFIER)
        failures << "Verification unitTestIdentifier must be Target/Class/testMethod with optional trailing ()"
      end
      cases = value["cases"]
      if cases.is_a?(Array) && cases.length == VERIFICATION_CASE_IDS.length
        cases.each_with_index do |entry, index|
          unless entry.is_a?(Hash) && entry["id"] == VERIFICATION_CASE_IDS[index] &&
                 [%w[id testIdentifier], %w[assertion id]].include?(entry.keys.sort)
            failures << "Verification cases must have four ordered IDs and exactly one testIdentifier or assertion"
            next
          end
          if entry.key?("testIdentifier")
            unless entry["testIdentifier"].is_a?(String) && entry["testIdentifier"].match?(TEST_IDENTIFIER)
              failures << "Verification case testIdentifier is invalid"
            end
          elsif entry["assertion"] != {"kind" => "launch-succeeded"}
            failures << "Verification assertion must be exactly launch-succeeded"
          end
        end
      else
        failures << "Verification cases must contain the exact four ordered case IDs"
      end

      mappings = value["acceptanceMappings"]
      unless acceptance_ids == acceptance_ids.each_index.map { |index| "AC-#{index + 1}" } &&
             mappings.is_a?(Array) && mappings.length == acceptance_ids.length
        failures << "Verification acceptanceMappings must map every numeric AC exactly once in order"
        return
      end
      mappings.each_with_index do |mapping, index|
        unless mapping.is_a?(Hash) && mapping.keys.sort == %w[checks id] && mapping["id"] == acceptance_ids[index]
          failures << "Verification acceptanceMappings must follow the exact AC order"
          next
        end
        checks = mapping["checks"]
        unless checks.is_a?(Array) && !checks.empty? && checks.uniq == checks &&
               checks.all? { |check| VERIFICATION_CHECKS.include?(check) } &&
               checks == VERIFICATION_CHECKS.select { |check| checks.include?(check) } &&
               checks.any? { |check| check.start_with?("stage:", "case:") }
          failures << "Verification checks must be nonempty, unique, in canonical order, and include an execution check"
        end
      end
    end

    def parse_delivery_profile(lines, headings, failures)
      matches = headings.select { |heading, _| heading == "Delivery profile" }
      return nil if matches.empty?
      if matches.length > 1
        failures << "duplicate optional heading: Delivery profile"
        return nil
      end
      heading_index = matches.first[1]
      next_heading = headings.find { |_, line_index| line_index > heading_index }
      section = lines[(heading_index + 1)...(next_heading ? next_heading[1] : lines.length)].join
      parsed = section.each_line.reject { |line| line.strip.empty? }.map do |line|
        match = line.match(/\A\s*[-*]\s*(Profile|Reason):\s*(\S.*?)\s*\z/)
        match&.captures
      end
      unless parsed.length == 2 && parsed.none?(&:nil?) && parsed.map(&:first) == ["Profile", "Reason"]
        failures << "Delivery profile must contain Profile and Reason in order"
        return nil
      end
      name = parsed[0][1].downcase
      reason = parsed[1][1].strip
      failures << "Delivery profile must be fast, standard, or strict" unless DeliveryProfile::NAMES.include?(name)
      return nil unless DeliveryProfile::NAMES.include?(name)
      {"name" => name, "reason" => reason}
    end

    def parse_external_operations(external_section, approvals_section, failures)
      no_additional_approval = no_additional_approval?(approvals_section)
      approval_reference = approval_reference?(approvals_section)
      normalized_approval_reference = normalize_approval_reference(approvals_section)

      if none_value?(external_section)
        failures << "External operations None requires User approvals to be None or No additional approval" unless no_additional_approval
        return []
      end

      raw_lines = external_section.each_line.reject { |line| line.strip.empty? }
      if raw_lines.empty?
        failures << "External operations must contain None or at least one exact operation block"
        return []
      end

      failures << "External operations must contain exact five-field blocks" unless (raw_lines.length % OPERATION_FIELDS.length).zero?
      details = []
      raw_lines.each_slice(OPERATION_FIELDS.length).with_index(1) do |block, block_index|
        parsed = block.map do |line|
          match = line.match(/\A\s*[-*]\s*(Operation|Service|Environment|Executor|Approval required):\s*(.*?)\s*\z/)
          failures << "External operations block #{block_index} contains a malformed field" unless match
          match&.captures
        end
        next if parsed.any?(&:nil?)

        fields = parsed.map(&:first)
        duplicate_fields = fields.group_by(&:itself).select { |_, items| items.length > 1 }.keys
        failures << "duplicate External operations field in block #{block_index}: #{duplicate_fields.join(', ')}" unless duplicate_fields.empty?
        unless fields == OPERATION_FIELDS
          failures << "External operations block #{block_index} fields must be exactly #{OPERATION_FIELDS.join(', ')} in order"
          next
        end

        values = parsed.to_h
        OPERATION_FIELDS.each do |field|
          failures << "External operations block #{block_index} has an empty #{field}" if values.fetch(field).empty?
        end

        operation = values.fetch("Operation")
        service = values.fetch("Service")
        environment = values.fetch("Environment")
        executor = values.fetch("Executor")
        approval_value = values.fetch("Approval required")

        failures << "External operations Operation is not allowed by docs/AUTHORITY.md: #{operation}" unless ALLOWED_OPERATIONS.include?(operation)
        expected_service = SERVICE_BY_PREFIX[operation.split(".", 2).first]
        if expected_service && service != expected_service
          failures << "External operations Service #{service} does not match #{operation}; expected #{expected_service}"
        end
        failures << "External operations Environment must be local, preview, staging, or production" unless ENVIRONMENTS.include?(environment)
        failures << "External operations Executor must be Codex or Claude" unless %w[Codex Claude].include?(executor)
        failures << "External operations Approval required must be yes or no" unless %w[yes no].include?(approval_value)

        details << {
          "operation" => operation,
          "service" => service,
          "environment" => environment,
          "executor" => executor,
          "approvalRequired" => approval_value == "yes",
          "approvalReference" => approval_value == "yes" ? normalized_approval_reference : nil
        }
      end

      duplicate_operations = details.map { |detail| detail.fetch("operation") }.group_by(&:itself).select { |_, items| items.length > 1 }.keys
      failures << "duplicate External operations Operation: #{duplicate_operations.join(', ')}" unless duplicate_operations.empty?

      if details.any? { |detail| detail.fetch("approvalRequired") }
        failures << "Approval required: yes needs a nonempty User approvals reference" unless approval_reference
      elsif !no_additional_approval
        failures << "Approval required: no requires User approvals to be None or No additional approval"
      end

      details
    end

    def validate_snapshot!(value, issue:, repository:)
      failures = []
      unless value.is_a?(Hash)
        raise ValidationError, ["Issue contract must be an object"]
      end
      unknown = value.keys - SNAPSHOT_REQUIRED_KEYS - SNAPSHOT_OPTIONAL_KEYS
      missing = SNAPSHOT_REQUIRED_KEYS - value.keys
      failures << "Issue contract has unknown fields: #{unknown.join(', ')}" unless unknown.empty?
      failures << "Issue contract is missing fields: #{missing.join(', ')}" unless missing.empty?
      failures << "Issue contract schemaVersion must be 1" unless value["schemaVersion"] == 1
      failures << "Issue contract identity differs from requested Issue" unless value["issue"] == issue && value["repository"] == repository
      failures << "Issue contract goal is missing" unless value["goal"].is_a?(String) && !value["goal"].strip.empty?
      anchors = value["specAnchors"]
      failures << "Issue contract spec anchors are invalid" unless anchors.is_a?(Array) && !anchors.empty? && anchors.all? { |entry| entry.is_a?(String) && !entry.empty? } && anchors.uniq == anchors
      criteria = value["acceptanceCriteria"]
      valid_criteria = criteria.is_a?(Array) && !criteria.empty? && criteria.each_with_index.all? do |entry, index|
        entry.is_a?(Hash) && entry.keys.sort == %w[id text] && entry["id"] == "AC-#{index + 1}" && entry["text"].is_a?(String) && !entry["text"].strip.empty?
      end
      failures << "Issue contract acceptance criteria are invalid" unless valid_criteria
      if value.key?("verification")
        validate_verification(value["verification"], valid_criteria ? criteria.map { |entry| entry.fetch("id") } : [], failures)
      end
      dependencies = value["dependencies"]
      failures << "Issue contract dependencies are invalid" unless dependencies.is_a?(Array) && dependencies.all? { |entry| entry.is_a?(Integer) && entry.positive? } && dependencies.uniq == dependencies
      operations = value["externalOperations"]
      failures << "Issue contract external operations are invalid" unless operations.is_a?(Array) && operations.all? { |entry| entry.is_a?(String) && ALLOWED_OPERATIONS.include?(entry) } && operations.uniq == operations
      begin
        profile = DeliveryProfile.effective_name(value)
        if profile == "fast" && value.key?("verification")
          failures << "Issue contract fast delivery profile cannot require UI verification"
        end
        if profile != "strict" && operations.is_a?(Array) && operations.any? { |operation| DeliveryProfile.strict_operation?(operation) }
          failures << "Issue contract high-risk external operations require strict delivery profile"
        end
      rescue ArgumentError => error
        failures << error.message
      end
      failures << "Issue contract operation-details digest is invalid" unless value["externalOperationDetailsDigest"].is_a?(String) && value["externalOperationDetailsDigest"].match?(/\Asha256:[0-9a-f]{64}\z/)
      begin
        Time.iso8601(value["fetchedAt"].to_s)
      rescue ArgumentError
        failures << "Issue contract fetchedAt is invalid"
      end
      raise ValidationError, failures unless failures.empty?

      value
    end

    def operation_declared?(contract, operation)
      contract.fetch("externalOperations").include?(operation)
    end

    def none_value?(value)
      value.match?(/\A\s*(?:[-*]\s*)?None\.?\s*\z/i)
    end

    def no_additional_approval?(value)
      value.match?(/\A\s*(?:[-*]\s*)?(?:None|No additional approval)\.?\s*\z/i)
    end

    def approval_reference?(value)
      value.match?(/(?:https?:\/\/\S+|\B#\d+\b|\bD-\d+\b|\bapproval(?:\s+reference)?\s*:\s*\S+)/i)
    end

    def normalize_approval_reference(value)
      value.each_line.map do |line|
        line.strip.sub(/\A[-*]\s+/, "").gsub(/[ \t]+/, " ")
      end.reject(&:empty?).join("\n")
    end

    def canonical(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, output| output[key] = canonical(value[key]) }
      when Array
        value.map { |entry| canonical(entry) }
      else
        value
      end
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {"type" => "feature", "format" => "validate"}
  parser = OptionParser.new do |cli|
    cli.banner = "usage: issue-contract.rb --body PATH [--type feature|regression|docs|release] [--format validate|contract|envelope] [snapshot options]"
    cli.on("--body PATH") { |value| options["body"] = value }
    cli.on("--type TYPE") { |value| options["type"] = value }
    cli.on("--format FORMAT") { |value| options["format"] = value }
    cli.on("--issue NUMBER") { |value| options["issue"] = value }
    cli.on("--repo OWNER/REPO") { |value| options["repo"] = value }
    cli.on("--fetched-at TIMESTAMP") { |value| options["fetched_at"] = value }
  end

  begin
    parser.parse!
    raise OptionParser::InvalidArgument, "unexpected positional arguments" unless ARGV.empty?
    raise OptionParser::MissingArgument, "--body" unless options["body"]
    raise OptionParser::InvalidArgument, "--format" unless %w[validate contract envelope].include?(options["format"])
    snapshot = options["format"] != "validate"
    if snapshot && [options["issue"], options["repo"], options["fetched_at"]].any?(&:nil?)
      raise OptionParser::MissingArgument, "--issue, --repo, and --fetched-at are required for snapshot output"
    end

    result = IOSTemplate::IssueContract.parse_file(
      options.fetch("body"),
      issue_type: options.fetch("type"),
      issue: snapshot ? options["issue"] : nil,
      repository: snapshot ? options["repo"] : nil,
      fetched_at: snapshot ? options["fetched_at"] : nil
    )

    case options["format"]
    when "contract"
      STDOUT.write(IOSTemplate::IssueContract.canonical_json(result.contract))
    when "envelope"
      puts IOSTemplate::IssueContract.canonical_json(
        "contract" => result.contract,
        "externalOperationDetails" => result.external_operation_details
      )
    end
  rescue OptionParser::ParseError => error
    warn error.message
    warn parser
    exit 2
  rescue Errno::ENOENT => error
    warn "Issue body file not found: #{error.filename}"
    exit 2
  rescue IOSTemplate::IssueContract::ValidationError => error
    warn error.failures.join("\n")
    exit 1
  end
end
