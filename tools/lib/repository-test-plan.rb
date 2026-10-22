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
    TARGETED_SCOPED_TESTS = %w[
      tools/tests/test-merge-issue.sh
      tools/tests/test-premerge-gate.sh
      tools/tests/test-render-pr-body.sh
      tools/tests/test-workflow-e2e.sh
      tools/tests/test-workflow-state.sh
    ].freeze
    TEST_PATH = %r{\Atools/tests/test-[a-z0-9-]+\.sh\z}
    SAFE_PATH = %r{\A(?!/)(?!.*(?:\A|/)\.\.(?:/|\z))[A-Za-z0-9._+@ /-]+\z}
    SHELL_LINT_DOMAIN = "repository-lint"
    SHELL_LINT_TESTS = %w[tools/tests/test-prerequisites.sh tools/tests/test-spec-state.sh].freeze
    CREDENTIAL_SCAN_DOMAIN = "credential-scan"
    CREDENTIAL_SCAN_TESTS = %w[tools/tests/test-tracked-credential-scan.sh].freeze
    # An app that adopted the template records its base here (D-074). The template sync never brings the
    # template-only files below into such an app (tools/template-sync/ownership.json), so their manifest
    # entries are left out there when the files are absent at Head (#349). The template keeps them exactly.
    TEMPLATE_BASE_PATH = "Config/template-base.json"
    TEMPLATE_ONLY_TESTS = %w[
      tools/tests/test-adopted-app-imported-tests.sh
      tools/tests/test-link-user-skill.sh
      tools/tests/test-template-sync-apply.sh
      tools/tests/test-template-sync-derived.sh
      tools/tests/test-template-sync.sh
    ].freeze
    TEMPLATE_ONLY_PATHS = %w[
      tools/lib/template-sync-apply.rb
      tools/lib/template-sync.rb
      tools/link-user-skill.sh
      tools/template-sync-codex-review.sh
      tools/template-sync.sh
      tools/tests/test-adopted-app-imported-tests.sh
    ].freeze
    # #327: a revision with every companion group entrypoint is split and runs `core` in BOOTSTRAP_CORE_TEST;
    # a revision without them runs that test's `all`.
    BOOTSTRAP_CORE_TEST = "tools/tests/test-app-bootstrap.sh"
    BOOTSTRAP_GROUP_TESTS = %w[
      tools/tests/test-app-bootstrap-safety-rejection.sh
      tools/tests/test-app-bootstrap-safety-rerun.sh
      tools/tests/test-app-bootstrap-transform.sh
    ].freeze

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
      adopted, testless_domains = adopted_manifest(parse_object(manifest_bytes, "repository-test manifest"), head_paths)
      manifest = validate_manifest!(
        adopted, head_paths.select { |path| path.match?(TEST_PATH) }, tracked_paths: head_paths,
        testless_domains: testless_domains
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

    # #327: the arguments come from the tested revision's own tracked test entrypoints (revision_tests), so a
    # Base and a Head on either side of the app-bootstrap split each run the form they contain. Legacy Head-only
    # evidence keeps its recorded `all`.
    def test_arguments(path, scope, revision_tests:)
      if path == BOOTSTRAP_CORE_TEST
        return ["all"] if scope == "legacy-head"

        reject("revision test inventory is required for #{path}") unless revision_tests.is_a?(Array)
        return (BOOTSTRAP_GROUP_TESTS - revision_tests).empty? ? ["core"] : ["all"]
      end
      return ["scoped"] if scope == "targeted" && TARGETED_SCOPED_TESTS.include?(path)

      []
    end

    # In an app that adopted the template, leaves out the template-only tests and exact paths that are absent
    # at Head, and names the domains whose only tests were those. Anywhere else the manifest is unchanged.
    def adopted_manifest(manifest, head_paths)
      return [manifest, []] unless head_paths.include?(TEMPLATE_BASE_PATH) && manifest.is_a?(Hash) &&
        manifest["tests"].is_a?(Array) && manifest["domainRules"].is_a?(Array)

      absent = ->(path) { !head_paths.include?(path) }
      tests, dropped = manifest["tests"].partition do |entry|
        !(entry.is_a?(Hash) && TEMPLATE_ONLY_TESTS.include?(entry["path"]) && absent.call(entry["path"]))
      end
      rules = manifest["domainRules"].map do |rule|
        next rule unless rule.is_a?(Hash) && rule["paths"].is_a?(Array)
        rule.merge("paths" => rule["paths"].reject { |path| TEMPLATE_ONLY_PATHS.include?(path) && absent.call(path) })
      end
      remaining = tests.flat_map { |entry| entry.is_a?(Hash) && entry["domains"].is_a?(Array) ? entry["domains"] : [] }
      testless = dropped.flat_map { |entry| entry["domains"].is_a?(Array) ? entry["domains"] : [] }.uniq - remaining
      [manifest.merge("tests" => tests, "domainRules" => rules), testless.sort]
    end

    def validate_manifest!(manifest, inventory, tracked_paths: nil, testless_domains: [])
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
        reject("repository-lint must not have a path rule") if domain == SHELL_LINT_DOMAIN
        reject("credential-scan must not have a path rule") if domain == CREDENTIAL_SCAN_DOMAIN
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
          test_domains == test_domains.sort && test_domains.uniq == test_domains &&
          test_domains.all? { |domain| domains.include?(domain) ||
            (domain == SHELL_LINT_DOMAIN && SHELL_LINT_TESTS.include?(path)) ||
            (domain == CREDENTIAL_SCAN_DOMAIN && CREDENTIAL_SCAN_TESTS.include?(path)) }
        path
      end
      reject("repository-test manifest tests must be sorted and unique") unless test_paths == test_paths.sort && test_paths.uniq == test_paths
      reject("repository-test manifest inventory differs from tracked tests") unless test_paths == inventory
      referenced = tests.flat_map { |entry| entry.fetch("domains") }.uniq.sort
      reject("repository-test manifest contains a domain without tests") unless (referenced - [SHELL_LINT_DOMAIN, CREDENTIAL_SCAN_DOMAIN]) == domains - testless_domains
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
      if changed.any? { |path| path.end_with?(".sh") }
        lint_tests = manifest.fetch("tests").select do |entry|
          SHELL_LINT_TESTS.include?(entry.fetch("path")) && entry.fetch("domains").include?(SHELL_LINT_DOMAIN)
        end.map { |entry| entry.fetch("path") }
        reject("repository-lint tests are missing from the manifest") unless lint_tests == SHELL_LINT_TESTS
        domains << SHELL_LINT_DOMAIN
      end
      if changed.any?
        scan_tests = manifest.fetch("tests").select do |entry|
          CREDENTIAL_SCAN_TESTS.include?(entry.fetch("path")) && entry.fetch("domains").include?(CREDENTIAL_SCAN_DOMAIN)
        end.map { |entry| entry.fetch("path") }
        reject("credential-scan test is missing from the manifest") unless scan_tests == CREDENTIAL_SCAN_TESTS
        domains << CREDENTIAL_SCAN_DOMAIN
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
