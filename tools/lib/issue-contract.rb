#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "time"

module IOSTemplate
  module IssueContract
    REQUIRED_HEADINGS = [
      "Goal",
      "In scope",
      "Out of scope",
      "Acceptance criteria",
      "Spec anchors",
      "Dependencies",
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
      elevenlabs.generate_audio
      appstore.inspect_app
      appstore.upload_build
      appstore.update_metadata
      appstore.submit_review
    ].freeze

    ENVIRONMENTS = %w[local preview staging production].freeze

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
      unless %w[feature regression].include?(issue_type)
        failures << "Issue type must be feature or regression"
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

      external_details = parse_external_operations(
        sections.fetch("External operations", ""),
        sections.fetch("User approvals", ""),
        failures
      )

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
          "fetchedAt" => fetched_at
        }
      end

      raise ValidationError, failures unless failures.empty?

      Result.new(contract: contract, external_operation_details: external_details)
    end

    def parse_external_operations(external_section, approvals_section, failures)
      no_additional_approval = no_additional_approval?(approvals_section)
      approval_reference = approval_reference?(approvals_section)

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
        failures << "External operations Executor must be Codex" unless executor == "Codex"
        failures << "External operations Approval required must be yes or no" unless %w[yes no].include?(approval_value)

        details << {
          "operation" => operation,
          "service" => service,
          "environment" => environment,
          "executor" => executor,
          "approvalRequired" => approval_value == "yes"
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

    def none_value?(value)
      value.match?(/\A\s*(?:[-*]\s*)?None\.?\s*\z/i)
    end

    def no_additional_approval?(value)
      value.match?(/\A\s*(?:[-*]\s*)?(?:None|No additional approval)\.?\s*\z/i)
    end

    def approval_reference?(value)
      value.match?(/(?:https?:\/\/\S+|\B#\d+\b|\bD-\d+\b|\bapproval(?:\s+reference)?\s*:\s*\S+)/i)
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
    cli.banner = "usage: issue-contract.rb --body PATH [--type feature|regression] [--format validate|contract|envelope] [snapshot options]"
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
