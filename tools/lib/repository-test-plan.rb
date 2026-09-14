#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require_relative "delivery-profile"

module IOSTemplate
  module RepositoryTestPlan
    class PlanError < StandardError; end

    module_function

    CUTOFF = Time.iso8601("2026-09-13T13:03:38Z").freeze
    MANIFEST_PATH = "Config/repository-tests.json"
    SCOPES = %w[targeted head-all base-and-head].freeze
    TEST_PATH = %r{\Atools/tests/test-[a-z0-9-]+\.sh\z}
    SAFE_PATH = %r{\A(?!/)(?!.*(?:\A|/)\.\.(?:/|\z))[A-Za-z0-9._+@ /-]+\z}

    def policy(contract)
      criteria = contract.fetch("acceptanceCriteria")
      declarations = criteria.select { |entry| entry.fetch("text").start_with?("Repository-test scope:") }
      fetched_at = Time.iso8601(contract.fetch("fetchedAt"))
      workflow_only = contract.dig("deliveryStage", "name") == "harden" &&
        DeliveryProfile.effective_name(contract) == "strict" &&
        !contract.key?("verification") && !contract.key?("verificationScope")
      return nil if fetched_at < CUTOFF && declarations.empty?
      return nil if !workflow_only && declarations.empty?

      reject("exactly one repository-test scope declaration is required") unless declarations.length == 1
      text = declarations.first.fetch("text")
      if fetched_at < CUTOFF && text.match?(/\ARepository-test scope: base-and-head; \S/)
        return {"requestedScope" => "base-and-head", "reason" => text.split("; ", 2).last, "planRequired" => false}
      end

      match = text.match(/\ARepository-test scope: (targeted|head-all|base-and-head); Reason: (\S(?:.*\S)?)\z/)
      reject("repository-test scope declaration is malformed") unless match
      {"requestedScope" => match[1], "reason" => match[2], "planRequired" => true}
    rescue KeyError, ArgumentError
      reject("repository-test contract identity is invalid")
    end

    def build(repo:, issue:, base_sha:, head_sha:, contract_bytes:, mappings:)
      contract = parse_object(contract_bytes, "Issue contract")
      selected_policy = policy(contract)
      reject("repository-test plan is not enabled for this contract") unless selected_policy&.fetch("planRequired")
      reject("Issue identity differs") unless contract["issue"] == issue
      [base_sha, head_sha].each { |sha| reject("Git SHA is invalid") unless sha.match?(/\A[0-9a-f]{40}\z/) }

      manifest_bytes = git!(repo, "show", "#{head_sha}:#{MANIFEST_PATH}").b
      head_paths = tracked_paths(repo, head_sha)
      manifest = validate_manifest!(
        parse_object(manifest_bytes, "repository-test manifest"),
        head_paths.select { |path| path.match?(TEST_PATH) }, tracked_paths: head_paths
      )
      paths = changed_paths(repo, base_sha, head_sha)
      resolved_scope, resolution_reason, selected_tests = resolve(manifest, selected_policy.fetch("requestedScope"), paths)
      acceptance = validate_mappings!(mappings, contract.fetch("acceptanceCriteria"), selected_tests)
      diff_identity = {"baseSha" => base_sha, "headSha" => head_sha, "paths" => paths}

      {
        "schemaVersion" => 1,
        "issue" => issue,
        "baseSha" => base_sha,
        "headSha" => head_sha,
        "issueContract" => {
          "path" => ".artifacts/issues/#{issue}/issue-contract.json",
          "digest" => digest(contract_bytes)
        },
        "requestedScope" => selected_policy.fetch("requestedScope"),
        "resolvedScope" => resolved_scope,
        "requestReason" => selected_policy.fetch("reason"),
        "resolutionReason" => resolution_reason,
        "manifest" => {"path" => MANIFEST_PATH, "digest" => digest(manifest_bytes)},
        "diff" => {"paths" => paths, "digest" => digest(canonical_json(diff_identity))},
        "testPaths" => selected_tests,
        "acceptanceMappings" => acceptance
      }
    rescue JSON::ParserError, KeyError => error
      reject(error.message)
    end

    def validate!(plan, repo:, issue:, base_sha:, head_sha:, contract_bytes:)
      reject("repository-test plan must be an object") unless plan.is_a?(Hash)
      mappings = plan.fetch("acceptanceMappings").to_h do |entry|
        reject("repository-test plan acceptance mapping is invalid") unless entry.is_a?(Hash)
        [entry.fetch("id"), entry.fetch("tests")]
      end
      expected = build(repo: repo, issue: issue, base_sha: base_sha, head_sha: head_sha,
        contract_bytes: contract_bytes, mappings: mappings)
      reject("repository-test plan differs from immutable Git inputs") unless plan == expected
      plan
    rescue KeyError
      reject("repository-test plan is incomplete")
    end

    def validate_manifest!(manifest, inventory, tracked_paths: nil)
      exact_keys!(manifest, %w[schemaVersion headAllPaths headAllPrefixes domainRules tests], "manifest")
      reject("repository-test manifest schemaVersion is invalid") unless manifest["schemaVersion"] == 1
      head_all_paths = unique_paths!(manifest["headAllPaths"], "manifest.headAllPaths")
      head_all_prefixes = unique_prefixes!(manifest["headAllPrefixes"], "manifest.headAllPrefixes")
      reject("repository-test manifest automatic head-all paths are no longer allowed") unless head_all_paths.empty?
      reject("repository-test manifest automatic head-all prefixes are no longer allowed") unless head_all_prefixes.empty?
      rules = manifest["domainRules"]
      reject("repository-test manifest domainRules must be a nonempty array") unless rules.is_a?(Array) && !rules.empty?
      domains = []
      rules.each_with_index do |rule, index|
        exact_keys!(rule, %w[domain paths prefixes], "manifest.domainRules[#{index}]")
        domain = rule["domain"]
        reject("repository-test manifest domain is invalid") unless domain.is_a?(String) && domain.match?(/\A[a-z][a-z0-9-]*\z/)
        reject("repository-test manifest domain is duplicated") if domains.include?(domain)
        domains << domain
        paths = unique_paths!(rule["paths"], "manifest domain paths")
        prefixes = unique_prefixes!(rule["prefixes"], "manifest domain prefixes")
        reject("repository-test manifest domain coverage is empty") if paths.empty? && prefixes.empty?
      end
      reject("repository-test manifest domains must be sorted") unless domains == domains.sort

      tests = manifest["tests"]
      reject("repository-test manifest tests must be a nonempty array") unless tests.is_a?(Array) && !tests.empty?
      test_paths = tests.map.with_index do |entry, index|
        exact_keys!(entry, %w[path domains], "manifest.tests[#{index}]")
        path = entry["path"]
        reject("repository-test manifest test path is invalid") unless path.is_a?(String) && path.match?(TEST_PATH)
        test_domains = entry["domains"]
        reject("repository-test manifest test domains are invalid") unless test_domains.is_a?(Array) && !test_domains.empty? &&
          test_domains == test_domains.sort && test_domains.uniq == test_domains && test_domains.all? { |domain| domains.include?(domain) }
        path
      end
      reject("repository-test manifest tests must be sorted and unique") unless test_paths == test_paths.sort && test_paths.uniq == test_paths
      reject("repository-test manifest inventory differs from tracked tests") unless test_paths == inventory
      referenced = tests.flat_map { |entry| entry.fetch("domains") }.uniq.sort
      reject("repository-test manifest contains a domain without tests") unless referenced == domains
      if tracked_paths
        exact_coverage = rules.flat_map { |rule| rule.fetch("paths") }
        reject("repository-test manifest exact path is not tracked at Head") unless exact_coverage.all? { |path| tracked_paths.include?(path) }
      end
      manifest
    end

    def resolve(manifest, requested_scope, changed)
      reject("repository-test scope is invalid") unless SCOPES.include?(requested_scope)
      all_tests = manifest.fetch("tests").map { |entry| entry.fetch("path") }
      return ["base-and-head", "Acceptance criterion explicitly requires Base and Head comparison.", all_tests] if requested_scope == "base-and-head"
      return ["head-all", "Issue contract explicitly requires all current-Head repository tests.", all_tests] if requested_scope == "head-all"

      domains = []
      changed.each do |path|
        matches = manifest.fetch("domainRules").select do |rule|
          rule.fetch("paths").include?(path) || rule.fetch("prefixes").any? { |prefix| path.start_with?(prefix) }
        end.map { |rule| rule.fetch("domain") }
        if path.match?(TEST_PATH)
          test = manifest.fetch("tests").find { |entry| entry.fetch("path") == path }
          matches.concat(test.fetch("domains")) if test
        end
        reject("changed path has no manifest coverage: #{path}") if matches.empty?
        domains.concat(matches)
      end
      domains.uniq!
      domains.sort!
      selected = manifest.fetch("tests").select do |entry|
        !(entry.fetch("domains") & domains).empty?
      end.map { |entry| entry.fetch("path") }
      reject("targeted repository-test selection is empty") if selected.empty?
      ["targeted", "Changed paths resolve to repository-test domains: #{domains.join(',')}.", selected]
    end

    def validate_mappings!(mappings, criteria, selected_tests)
      expected_ids = criteria.map { |entry| entry.fetch("id") }
      reject("acceptance mappings must match every Issue contract AC exactly once") unless mappings.is_a?(Hash) && mappings.keys == expected_ids
      acceptance = expected_ids.map do |id|
        tests = mappings.fetch(id)
        reject("acceptance mapping #{id} must reference unique selected tests") unless tests.is_a?(Array) && !tests.empty? && tests.uniq == tests && tests.all? { |path| selected_tests.include?(path) }
        {"id" => id, "tests" => tests}
      end
      union = acceptance.flat_map { |entry| entry.fetch("tests") }.uniq.sort
      reject("acceptance mapping union differs from the selected repository tests") unless union == selected_tests
      acceptance
    end

    def changed_paths(repo, base_sha, head_sha)
      output = git!(repo, "diff", "--name-only", "--no-renames", "-z", base_sha, head_sha, "--").b
      paths = output.split("\0").reject(&:empty?).map do |path|
        path.force_encoding(Encoding::UTF_8)
        reject("Base..Head contains an unsafe path") unless path.valid_encoding? && path.match?(SAFE_PATH)
        path
      end.sort
      reject("Base..Head contains duplicate paths") unless paths.uniq == paths
      reject("Base..Head diff is empty") if paths.empty?
      paths
    end

    def tracked_tests(repo, head_sha)
      tracked_paths(repo, head_sha).select { |path| path.match?(TEST_PATH) }
    end

    def tracked_paths(repo, head_sha)
      paths = git!(repo, "ls-tree", "-r", "--name-only", "-z", head_sha, "--").split("\0").reject(&:empty?).sort
      reject("Head contains duplicate tracked paths") unless paths.uniq == paths
      paths
    end

    def unique_paths!(value, at)
      reject("#{at} must be a sorted unique array") unless value.is_a?(Array) && value == value.sort && value.uniq == value && value.all? { |path| path.is_a?(String) && path.match?(SAFE_PATH) }
      value
    end

    def unique_prefixes!(value, at)
      reject("#{at} must be a sorted unique prefix array") unless value.is_a?(Array) && value == value.sort && value.uniq == value &&
        value.all? { |prefix| prefix.is_a?(String) && prefix.match?(SAFE_PATH) }
      value
    end

    def exact_keys!(value, keys, at)
      reject("#{at} must be an object with exact keys") unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def parse_object(bytes, at)
      value = JSON.parse(bytes.dup)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      value
    end

    def git!(repo, *arguments)
      output, error, status = Open3.capture3(
        {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil,
         "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null", "LANG" => "C", "LC_ALL" => "C"},
        "/usr/bin/git", "-C", repo, *arguments
      )
      reject("Git command failed: #{arguments.first}: #{error.strip}") unless status.success?
      output
    end

    def digest(bytes)
      "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.each_with_object({}) { |key, result| result[key] = canonical(value[key]) }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def reject(message)
      raise PlanError, message
    end
  end
end
