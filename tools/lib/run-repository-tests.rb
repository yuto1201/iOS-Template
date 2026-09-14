#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "time"
require_relative "review-contract"
require_relative "review-sealing"
require_relative "repository-test-plan"

module IOSTemplate
  module RepositoryTests
    class RunnerError < StandardError; end

    module_function

    SHA = /\A[0-9a-f]{40}\z/
    TEST_PATH = %r{\Atools/tests/test-[a-z0-9-]+\.sh\z}
    RUNNER_PATHS = %w[tools/run-repository-tests.sh tools/lib/run-repository-tests.rb tools/lib/repository-test-plan.rb].freeze
    DEFAULT_TARGETED_CHILD_TIMEOUT_SECONDS = 300
    DEFAULT_TARGETED_SUITE_TIMEOUT_SECONDS = 900
    DEFAULT_FULL_CHILD_TIMEOUT_SECONDS = 900
    DEFAULT_FULL_SUITE_TIMEOUT_SECONDS = 14_400
    FAILURE_FILE_PREFIX = "repository-test-failure-attempt-"

    def run(repo:, issue:, expected_base:, mappings:, base_mappings: {}, retry_after_targeted: nil, before_publish: nil)
      reject("repository root must be a physical absolute directory") unless repo.start_with?("/") && File.realpath(repo) == repo
      reject("issue must be a positive integer") unless issue.is_a?(Integer) && issue.positive?
      reject("expected Base SHA is invalid") unless expected_base.match?(SHA)

      head_sha = git!(repo, "rev-parse", "HEAD").strip
      reject("current Head SHA is invalid") unless head_sha.match?(SHA)
      git_status!(repo, "merge-base", "--is-ancestor", expected_base, head_sha)
      reject("Issue worktree must be clean before repository tests") unless git!(repo, "status", "--porcelain").empty?

      topology = artifact_topology!(repo)
      artifacts = topology.fetch("artifactsRoot")
      snapshots = ReviewSealing::SnapshotSet.new(
        artifacts, at: "artifact root",
        expected_identity: [topology.fetch("artifactsDevice"), topology.fetch("artifactsInode")]
      )
      begin
        issues = snapshots.directory(snapshots.root, "issues", at: "issues")
        issue_directory = snapshots.directory(issues, issue.to_s, at: "Issue artifact directory")
        head_directory = snapshots.directory(issue_directory, head_sha, at: "Head artifact directory")
        contract_file = snapshots.leaf(issue_directory, "issue-contract.json", at: "issue contract")
        reject("canonical repository-tests.json already exists") if existing_leaf(snapshots, head_directory, "repository-tests.json")

        contract = JSON.parse(contract_file.bytes.dup)
        ReviewContract.validate_contract_keys!(contract)
        reject("Issue contract identity differs") unless contract["schemaVersion"] == 1 && contract["issue"] == issue
        criteria = contract.fetch("acceptanceCriteria")
        validate_criteria!(criteria)
        plan_policy = RepositoryTestPlan.policy(contract)
        plan = plan_policy&.fetch("planRequired") ? RepositoryTestPlan.build(
          repo: repo, issue: issue, base_sha: expected_base, head_sha: head_sha,
          contract_bytes: contract_file.bytes, mappings: mappings
        ) : nil
        plan_bytes = plan && JSON.generate(plan).b
        plan_file = nil
        if plan
          plan_file = existing_leaf(snapshots, head_directory, "repository-test-plan.json")
          if plan_file
            reject("existing repository-test-plan.json differs from immutable inputs") unless plan_file.bytes == plan_bytes
          else
            plan_file = snapshots.publish_exclusive(head_directory, "repository-test-plan.json", plan_bytes, at: "repository-test-plan.json")
          end
        end
        dual_revision = plan ? plan.fetch("resolvedScope") == "base-and-head" : ReviewContract.repository_test_scope(criteria) == "base-and-head"
        reject("Base mappings require a Base and Head contract") if !dual_revision && !base_mappings.empty?
        context = dual_revision ? ReviewContract.repository_revision_context(repo: repo, base_sha: expected_base, head_sha: head_sha) : nil
        plan_context = plan ? (context || ReviewContract.repository_revision_context(repo: repo, base_sha: expected_base, head_sha: head_sha)) : nil

        inventory = dual_revision ? context.fetch("inventories")[1].map { |entry| entry.fetch("path") } : tracked_tests(repo, head_sha)
        reject("no tracked repository tests were found") if inventory.empty?
        acceptance = if plan
          plan.fetch("acceptanceMappings").map { |entry| {"id"=>entry.fetch("id"), "status"=>"passed", "tests"=>entry.fetch("tests")} }
        else
          validate_mappings!(mappings, criteria, inventory)
        end
        # Before the versioned impact manifest lands, only the sealed
        # workflow-only contract may use its AC map as the execution set.
        # Every other legacy Head-only contract keeps the full inventory.
        tests = if plan
                  plan.fetch("testPaths")
                elsif dual_revision || !workflow_only_contract?(contract)
                  inventory
                else
                  mappings.values.flatten.uniq.sort
                end
        if dual_revision
          base_tests = context.fetch("inventories")[0].map { |entry| entry.fetch("path") }
          reject("no tracked Base repository tests were found") if base_tests.empty?
          reject("Base mapping contains an unknown AC") unless (base_mappings.keys - mappings.keys).empty?
          base_mappings.each do |id, paths|
            reject("Base mapping #{id} must reference unique tracked Base tests") unless paths.is_a?(Array) && !paths.empty? && paths.uniq == paths && paths.all? { |path| base_tests.include?(path) }
          end
          declaration_id = criteria.find { |entry| entry["text"].start_with?("Repository-test scope:") }.fetch("id")
          reject("repository scope AC must map both complete suites") unless base_mappings[declaration_id]&.sort == base_tests && mappings[declaration_id].sort == tests
          acceptance = acceptance.map { |entry| {"id"=>entry["id"], "status"=>"passed", "baseTests"=>base_mappings.fetch(entry["id"], []), "headTests"=>entry["tests"]} }
        end
        execution_scope = plan ? plan.fetch("resolvedScope") : dual_revision ? "base-and-head" : "legacy-head"
        child_timeout_seconds = repository_test_timeout_seconds(execution_scope)
        suite_timeout_seconds = repository_test_suite_timeout_seconds(execution_scope, contract)
        previous_failures = repository_test_failures(snapshots, head_directory, issue: issue, head_sha: head_sha,
          scope: execution_scope)
        reject("repository tests already failed twice for this Issue, Head, and scope") if previous_failures.length >= 2
        reject("repository test retry is allowed only after one failed attempt") if retry_after_targeted && previous_failures.length != 1
        if previous_failures.length == 1 && retry_after_targeted.nil?
          reject("repository tests already failed for this Issue, Head, and scope; run one selected targeted diagnostic and pass --retry-after-targeted PATH")
        end
        if retry_after_targeted
          expected_diagnostic = previous_failures.first.fetch("failedTest")
          reject("previous repository failure has no selected diagnostic test") unless expected_diagnostic
          reject("retry diagnostic must match the failed selected repository test") unless retry_after_targeted == expected_diagnostic
        end
        runner_paths = plan ? RUNNER_PATHS : RUNNER_PATHS.first(2)
        runner_files = runner_paths.map do |path|
          bytes = git!(repo, "show", "#{head_sha}:#{path}").b
          {"path" => path, "digest" => ReviewContract.digest(bytes)}
        end

        suite_started = Time.now.utc
        suite_started_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        suite_deadline = suite_started_monotonic + suite_timeout_seconds
        execution_stage = "suite"
        warn "repository test execution plan: #{JSON.generate({scope: execution_scope, testCount: tests.length,
          tests: tests, childTimeoutSeconds: child_timeout_seconds, suiteTimeoutSeconds: suite_timeout_seconds})}"
        begin
          if retry_after_targeted
            execution_stage = "diagnostic"
            diagnostic_inventory = plan ? plan_context.fetch("inventories")[1].select { |entry| entry.fetch("path") == retry_after_targeted } : nil
            diagnostic_results = execute_in_detached_worktree(repo, head_sha, [retry_after_targeted], inventory: diagnostic_inventory,
              deadline: suite_deadline, child_timeout_seconds: child_timeout_seconds)
            diagnostic_failure = diagnostic_results.find { |entry| entry["status"] != "passed" }
            reject("retry diagnostic failed: #{diagnostic_failure.fetch('path')}") if diagnostic_failure
          end
          if dual_revision
            revisions = [["base", expected_base], ["head", head_sha]].each_with_index.map do |(role, sha), index|
              execution_stage = role
              started = Time.now.utc
              inventory = context.fetch("inventories")[index]
              revision_results = execute_in_detached_worktree(repo, sha, inventory.map { |entry| entry["path"] }, inventory: inventory,
                deadline: suite_deadline, child_timeout_seconds: child_timeout_seconds)
              failure = revision_results.find { |entry| entry["status"] != "passed" }
              reject("#{role} repository test failed: #{failure.fetch('path')}") if failure
              {"role"=>role, "testedSha"=>sha, "suite"=>suite_summary(revision_results), "tests"=>revision_results,
               "startedAt"=>started.iso8601(6), "completedAt"=>Time.now.utc.iso8601(6)}
            end
            results = revisions.flat_map { |revision| revision.fetch("tests") }
          else
            execution_stage = "suite"
            selected_inventory = plan ? plan_context.fetch("inventories")[1].select { |entry| tests.include?(entry.fetch("path")) } : nil
            results = execute_in_detached_worktree(repo, head_sha, tests, inventory: selected_inventory,
              deadline: suite_deadline, child_timeout_seconds: child_timeout_seconds)
          end
          failure = results.find { |entry| entry["status"] != "passed" }
          reject("repository test failed: #{failure.fetch('path')}") if failure
        rescue RunnerError => error
          elapsed_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - suite_started_monotonic
          failure_details = repository_test_failure_details(error.message, tests, execution_stage)
          warn "repository test execution stopped: #{JSON.generate({scope: execution_scope, status: "failed",
            stage: execution_stage, testCount: tests.length, tests: tests, childTimeoutSeconds: child_timeout_seconds,
            suiteTimeoutSeconds: suite_timeout_seconds, elapsedSeconds: elapsed_seconds.round(6),
            timedOut: failure_details.fetch("timedOut"), unexecutedTests: failure_details.fetch("unexecutedTestPaths")})}"
          publish_repository_test_failure!(snapshots, head_directory, issue: issue, head_sha: head_sha,
            scope: execution_scope, attempt: previous_failures.length + 1, tests: tests, started_at: suite_started,
            stage: execution_stage, child_timeout_seconds: child_timeout_seconds,
            suite_timeout_seconds: suite_timeout_seconds, elapsed_seconds: elapsed_seconds,
            failure_details: failure_details, error: error.message)
          raise
        end
        suite_completed = Time.now.utc
        suite_elapsed_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - suite_started_monotonic
        warn "repository test execution completed: #{JSON.generate({scope: execution_scope, status: "passed",
          testCount: tests.length, tests: tests, childTimeoutSeconds: child_timeout_seconds,
          suiteTimeoutSeconds: suite_timeout_seconds, elapsedSeconds: suite_elapsed_seconds.round(6), unexecutedTests: []})}"

        reject("current Head changed during repository tests") unless git!(repo, "rev-parse", "HEAD").strip == head_sha
        reject("Issue worktree changed during repository tests") unless git!(repo, "status", "--porcelain").empty?
        snapshots.verify!

        evidence = {
          "schemaVersion" => 1,
          "status" => "passed",
          "issue" => issue,
          "baseSha" => expected_base,
          "headSha" => head_sha,
          "issueContract" => {
            "path" => ".artifacts/issues/#{issue}/issue-contract.json",
            "digest" => ReviewContract.digest(contract_file.bytes)
          },
          "runnerFiles" => runner_files,
          "suite" => {
            "path" => "tools/tests",
            "pattern" => "test-*.sh",
            "total" => results.length,
            "passed" => results.count { |entry| entry["status"] == "passed" },
            "failed" => results.count { |entry| entry["status"] != "passed" }
          },
          "tests" => results,
          "acceptanceEvidence" => acceptance,
          "startedAt" => suite_started.iso8601(6),
          "completedAt" => suite_completed.iso8601(6)
        }
        if dual_revision
          %w[runnerFiles suite tests].each { |key| evidence.delete(key) }
          evidence.merge!("schemaVersion"=>2, "scope"=>"base-and-head", "producer"=>{"headSha"=>head_sha, "files"=>runner_files}, "revisions"=>revisions)
          unless plan
            ReviewContract.validate_repository_tests!(evidence, issue: issue, base_sha: expected_base, head_sha: head_sha,
              contract_digest: ReviewContract.digest(contract_file.bytes), criteria: criteria, revision_context: context)
          end
          reject("repository execution predates Issue contract") if suite_started < Time.iso8601(contract.fetch("fetchedAt"))
        end
        if plan
          evidence.delete("runnerFiles")
          evidence["schemaVersion"] = 3
          evidence["scope"] = plan.fetch("resolvedScope")
          evidence["repositoryTestPlan"] = {
            "path" => ".artifacts/issues/#{issue}/#{head_sha}/repository-test-plan.json",
            "digest" => ReviewContract.digest(plan_file.bytes)
          }
          evidence["producer"] ||= {"headSha"=>head_sha, "files"=>runner_files}
          ReviewContract.validate_repository_tests!(evidence, issue: issue, base_sha: expected_base, head_sha: head_sha,
            contract_digest: ReviewContract.digest(contract_file.bytes), criteria: criteria,
            revision_context: plan_context, repository_test_plan: plan)
        end
        bytes = JSON.generate(evidence).b
        before_publish&.call
        snapshots.verify!
        reject("current Head changed before evidence publication") unless git!(repo, "rev-parse", "HEAD").strip == head_sha
        reject("Issue worktree changed before evidence publication") if (dual_revision || plan) && !git!(repo, "status", "--porcelain").empty?
        leaf = snapshots.publish_exclusive(head_directory, "repository-tests.json", bytes, at: "repository-tests.json")
        begin
          snapshots.verify!
          reject("current Head changed during evidence publication") if (dual_revision || plan) && git!(repo, "rev-parse", "HEAD").strip != head_sha
        rescue StandardError
          snapshots.unlink_if_same(head_directory, leaf) if dual_revision || plan
          raise
        end

        {
          "path" => ".artifacts/issues/#{issue}/#{head_sha}/repository-tests.json",
          "digest" => ReviewContract.digest(leaf.bytes),
          "total" => results.length,
          "passed" => results.length,
          "failed" => 0
        }
      ensure
        snapshots.close
      end
    rescue ReviewContract::ValidationError, RepositoryTestPlan::PlanError, ReviewSealing::SealError, JSON::ParserError, KeyError,
           SystemCallError, IOError => error
      raise RunnerError, error.message
    end

    def suite_summary(results)
      {"path"=>"tools/tests", "pattern"=>"test-*.sh", "total"=>results.length,
       "passed"=>results.count { |entry| entry["status"] == "passed" },
       "failed"=>results.count { |entry| entry["status"] != "passed" }}
    end

    def execute_in_detached_worktree(repo, head_sha, tests, inventory: nil, deadline:, child_timeout_seconds:)
      results = []
      Dir.mktmpdir("ios-template-repository-tests-") do |temporary|
        worktree = File.join(temporary, "worktree")
        git!(repo, "worktree", "add", "--detach", worktree, head_sha)
        begin
          reject("detached test worktree resolved an unexpected Head") unless git!(worktree, "rev-parse", "HEAD").strip == head_sha
          tests.each_with_index do |path, index|
            remaining_seconds = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            unfinished = tests.drop(index)
            remaining_whole_seconds = remaining_seconds.floor
            reject("repository test suite reached its aggregate timeout; unexecuted tests: #{JSON.generate(unfinished)}") unless remaining_whole_seconds.positive?
            if inventory
              reject("detached revision worktree is dirty") unless git!(worktree, "status", "--porcelain").empty?
              expected = inventory.find { |entry| entry["path"] == path }.fetch("sourceDigest")
              source = File.join(worktree, path)
              reject("detached test source differs from revision") unless File.lstat(source).file? && ReviewContract.digest(File.binread(source)) == expected
            end
            arguments = test_arguments(path)
            started = Time.now.utc
            timeout_seconds = [child_timeout_seconds, remaining_whole_seconds].min
            aggregate_limited = timeout_seconds < child_timeout_seconds
            stdout, stderr, status, timed_out, elapsed = capture3_bounded(
              {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil},
              "/bin/bash", "-p", path, *arguments,
              chdir: worktree, timeout_seconds: timeout_seconds
            )
            completed = Time.now.utc
            exit_status = timed_out ? 124 : status.exitstatus || 128 + status.termsig.to_i
            results << {
              "path" => path,
              "arguments" => arguments,
              "status" => timed_out ? "timed-out" : status.success? ? "passed" : "failed",
              "exitStatus" => exit_status,
              "outputDigest" => ReviewContract.digest(stdout.b + "\0".b + stderr.b),
              "startedAt" => started.iso8601(6),
              "completedAt" => completed.iso8601(6)
            }
            if inventory
              results.last.merge!("sourceDigest"=>expected, "command"=>["/bin/bash", "-p", path, *arguments],
                "timeoutSeconds"=>timeout_seconds, "elapsedSeconds"=>elapsed.round(6))
              reject("detached revision worktree changed during tests") unless git!(worktree, "rev-parse", "HEAD").strip == head_sha && git!(worktree, "status", "--porcelain").empty?
            end
            if timed_out
              if aggregate_limited
                reject("repository test suite reached its aggregate timeout; active test: #{path}; unexecuted tests: #{JSON.generate(tests.drop(index + 1))}")
              end
              reject("repository test timed out: #{path}; elapsedSeconds=#{format('%.3f', elapsed)}; unexecuted tests: #{JSON.generate(tests.drop(index + 1))}")
            end
            break unless status.success?
          end
        ensure
          _, cleanup_status = Open3.capture2e(
            {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil},
            "/usr/bin/git", "-C", repo, "worktree", "remove", "--force", worktree
          )
          reject("detached test worktree cleanup failed") unless cleanup_status.success?
        end
      end
      results
    end

    def repository_test_timeout_seconds(scope)
      maximum = scope == "targeted" ? DEFAULT_TARGETED_CHILD_TIMEOUT_SECONDS : DEFAULT_FULL_CHILD_TIMEOUT_SECONDS
      raw = ENV.fetch("IOS_TEMPLATE_REPOSITORY_TEST_TIMEOUT_SECONDS", maximum.to_s)
      value = Integer(raw, 10)
      reject("repository test timeout must be a positive integer") unless value.positive?
      reject("repository test timeout exceeds the #{maximum}-second #{scope} limit") if value > maximum
      value
    rescue ArgumentError
      reject("repository test timeout must be a positive integer")
    end

    def repository_test_suite_timeout_seconds(scope, contract)
      maximum = scope == "targeted" ? DEFAULT_TARGETED_SUITE_TIMEOUT_SECONDS : DEFAULT_FULL_SUITE_TIMEOUT_SECONDS
      if scope != "targeted"
        issue_limit = contract.dig("deliveryStage", "timeBudgetMinutes")
        maximum = [maximum, issue_limit * 60].min if issue_limit.is_a?(Integer) && issue_limit.positive?
      end
      raw = ENV.fetch("IOS_TEMPLATE_REPOSITORY_TEST_SUITE_TIMEOUT_SECONDS", maximum.to_s)
      value = Integer(raw, 10)
      reject("repository test suite timeout must be a positive integer") unless value.positive?
      reject("repository test suite timeout exceeds the #{maximum}-second #{scope} limit") if value > maximum
      value
    rescue ArgumentError
      reject("repository test suite timeout must be a positive integer")
    end

    def repository_test_failures(snapshots, head_directory, issue:, head_sha:, scope:)
      failures = []
      (1..2).each do |attempt|
        leaf = existing_leaf(snapshots, head_directory, "#{FAILURE_FILE_PREFIX}#{attempt}.json")
        next unless leaf
        value = JSON.parse(leaf.bytes.dup)
        reject("repository test failure record is invalid") unless value.is_a?(Hash) &&
          value.values_at("schemaVersion", "issue", "headSha", "scope", "attempt") == [1, issue, head_sha, scope, attempt]
        tests = value.fetch("testPaths")
        failed_test = value.fetch("failedTest")
        unexecuted = value.fetch("unexecutedTestPaths")
        reject("repository test failure record is invalid") unless tests.is_a?(Array) && !tests.empty? && tests.uniq == tests &&
          tests.all? { |path| path.is_a?(String) } &&
          (failed_test.nil? || tests.include?(failed_test)) &&
          unexecuted.is_a?(Array) && unexecuted.uniq == unexecuted && unexecuted.all? { |path| tests.include?(path) } &&
          %w[suite diagnostic base head].include?(value.fetch("stage")) &&
          value.fetch("childTimeoutSeconds").is_a?(Integer) && value.fetch("childTimeoutSeconds").positive? &&
          value.fetch("suiteTimeoutSeconds").is_a?(Integer) && value.fetch("suiteTimeoutSeconds").positive? &&
          value.fetch("elapsedSeconds").is_a?(Numeric) && value.fetch("elapsedSeconds") >= 0 &&
          [true, false].include?(value.fetch("timedOut"))
        failures << value
      end
      reject("repository test failure attempt sequence is incomplete") if failures.map { |entry| entry.fetch("attempt") } != (1..failures.length).to_a
      failures
    rescue JSON::ParserError, KeyError
      reject("repository test failure record is invalid")
    end

    def repository_test_failure_details(error, tests, stage)
      failed_test = tests.find do |path|
        error.include?("failed: #{path}") || error.include?("timed out: #{path}") ||
          error.include?("active test: #{path}")
      end
      unexecuted = if stage == "diagnostic"
                     tests
                   elsif (marker = error.split("unexecuted tests: ", 2)[1])
                     parsed = JSON.parse(marker)
                     reject("repository test failure unexecuted list is invalid") unless parsed.is_a?(Array) &&
                       parsed.uniq == parsed && parsed.all? { |path| tests.include?(path) }
                     parsed
                   elsif failed_test
                     tests.drop(tests.index(failed_test) + 1)
                   else
                     []
                   end
      {
        "failedTest" => failed_test,
        "timedOut" => error.include?("timed out") || error.include?("timeout"),
        "unexecutedTestPaths" => unexecuted
      }
    rescue JSON::ParserError
      reject("repository test failure unexecuted list is invalid")
    end

    def publish_repository_test_failure!(snapshots, head_directory, issue:, head_sha:, scope:, attempt:, tests:, started_at:,
                                         stage:, child_timeout_seconds:, suite_timeout_seconds:, elapsed_seconds:,
                                         failure_details:, error:)
      reject("repository test failure attempt is invalid") unless (1..2).cover?(attempt)
      document = {
        "schemaVersion" => 1,
        "issue" => issue,
        "headSha" => head_sha,
        "scope" => scope,
        "attempt" => attempt,
        "stage" => stage,
        "testPaths" => tests,
        "failedTest" => failure_details.fetch("failedTest"),
        "childTimeoutSeconds" => child_timeout_seconds,
        "suiteTimeoutSeconds" => suite_timeout_seconds,
        "elapsedSeconds" => elapsed_seconds.round(6),
        "timedOut" => failure_details.fetch("timedOut"),
        "unexecutedTestPaths" => failure_details.fetch("unexecutedTestPaths"),
        "error" => error,
        "startedAt" => started_at.iso8601(6),
        "completedAt" => Time.now.utc.iso8601(6)
      }
      snapshots.publish_exclusive(head_directory, "#{FAILURE_FILE_PREFIX}#{attempt}.json", JSON.generate(document).b,
        at: "repository test failure attempt #{attempt}")
    end

    def capture3_bounded(environment, *command, chdir:, timeout_seconds:)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      input = output = error = wait_thread = nil
      input, output, error, wait_thread = Open3.popen3(environment, *command, chdir: chdir, pgroup: true)
      input.close
      stdout_reader = Thread.new { output.read }
      stderr_reader = Thread.new { error.read }
      timed_out = wait_thread.join(timeout_seconds).nil?
      if timed_out
        terminate_process_group(wait_thread.pid)
        wait_thread.join(5)
        if wait_thread.alive?
          begin
            Process.kill("KILL", -wait_thread.pid)
          rescue Errno::ESRCH
            nil
          end
          wait_thread.join
        end
      end
      status = wait_thread.value
      stdout = stdout_reader.value
      stderr = stderr_reader.value
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      [stdout, stderr, status, timed_out, elapsed]
    ensure
      input&.close unless input&.closed?
      output&.close unless output&.closed?
      error&.close unless error&.closed?
    end

    def terminate_process_group(pid)
      Process.kill("TERM", -pid)
    rescue Errno::ESRCH
      nil
    end

    def test_arguments(path)
      path == "tools/tests/test-app-bootstrap.sh" ? ["all"] : []
    end

    def tracked_tests(repo, head_sha)
      output = git!(repo, "ls-tree", "-r", "--name-only", head_sha, "--", "tools/tests")
      tests = output.lines.map(&:strip).select { |path| path.match?(TEST_PATH) }.sort
      reject("tracked repository test paths are not unique") unless tests.uniq == tests
      tests
    end

    def validate_criteria!(criteria)
      reject("Issue contract acceptance criteria are invalid") unless criteria.is_a?(Array) && !criteria.empty?
      criteria.each_with_index do |criterion, index|
        reject("Issue contract acceptance criteria are invalid") unless
          criterion.is_a?(Hash) && criterion.keys.sort == %w[id text] &&
          criterion["id"] == "AC-#{index + 1}" && criterion["text"].is_a?(String) && !criterion["text"].empty?
      end
    end

    def workflow_only_contract?(contract)
      contract.dig("deliveryStage", "name") == "harden" &&
        contract.dig("deliveryProfile", "name") == "strict" &&
        !contract.key?("verification") && !contract.key?("verificationScope")
    end

    def validate_mappings!(mappings, criteria, tests)
      expected_ids = criteria.map { |entry| entry.fetch("id") }
      reject("acceptance mappings must match every Issue contract AC exactly once") unless mappings.keys == expected_ids
      mappings.map do |id, paths|
        reject("acceptance mapping #{id} must reference at least one test") unless paths.is_a?(Array) && !paths.empty? && paths.uniq == paths
        paths.each { |path| reject("acceptance mapping #{id} references an untracked repository test") unless tests.include?(path) }
        {"id" => id, "status" => "passed", "tests" => paths}
      end
    end

    def artifact_topology!(repo)
      output, status = Open3.capture2e(
        {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil},
        "/usr/bin/ruby", File.join(repo, "tools", "lib", "review-artifacts.rb"), repo
      )
      reject("repository artifact topology is invalid: #{output.strip}") unless status.success?
      JSON.parse(output)
    end

    def existing_leaf(snapshots, directory, name)
      snapshots.leaf(directory, name, at: name)
    rescue SystemCallError => error
      return nil if error.errno == Errno::ENOENT::Errno
      raise
    end

    def git!(repo, *arguments)
      output, status = Open3.capture2e(
        {
          "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil,
          "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null",
          "LANG" => "C", "LC_ALL" => "C"
        },
        "/usr/bin/git", "-C", repo, *arguments
      )
      reject("Git command failed: #{arguments.first}") unless status.success?
      output
    end

    def git_status!(repo, *arguments)
      _, status = Open3.capture2e(
        {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil, "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null"},
        "/usr/bin/git", "-C", repo, *arguments
      )
      reject("Git command failed: #{arguments.first}") unless status.success?
    end

    def reject(message)
      raise RunnerError, message
    end
  end
end

if $PROGRAM_NAME == __FILE__
  repo = ARGV.shift
  issue = nil
  expected_base = nil
  mapping_arguments = []
  base_mapping_arguments = []
  retry_after_targeted = nil
  until ARGV.empty?
    case ARGV.shift
    when "--issue" then issue = ARGV.shift
    when "--expected-base" then expected_base = ARGV.shift
    when "--map" then mapping_arguments << ARGV.shift
    when "--base-map" then base_mapping_arguments << ARGV.shift
    when "--retry-after-targeted" then retry_after_targeted = ARGV.shift
    else
      warn "usage: run-repository-tests.sh --issue NUMBER --expected-base SHA --map AC-N=TEST[,TEST...] ... [--base-map AC-N=TEST[,TEST...] ...] [--retry-after-targeted TEST]"
      exit 2
    end
  end
  unless repo && issue&.match?(/\A[1-9][0-9]*\z/) && expected_base && !mapping_arguments.empty? && mapping_arguments.none?(&:nil?)
    warn "usage: run-repository-tests.sh --issue NUMBER --expected-base SHA --map AC-N=TEST[,TEST...] ..."
    exit 2
  end
  begin
    parse_mappings = lambda do |arguments|
      parsed = {}
      arguments.each do |argument|
        IOSTemplate::RepositoryTests.reject("acceptance mapping is invalid") unless argument.is_a?(String)
        id, paths = argument.split("=", 2)
        IOSTemplate::RepositoryTests.reject("acceptance mapping is invalid") unless id&.match?(/\AAC-[1-9][0-9]*\z/) && paths && !paths.empty? && !parsed.key?(id)
        parsed[id] = paths.split(",", -1)
      end
      parsed
    end
    mappings = parse_mappings.call(mapping_arguments)
    base_mappings = parse_mappings.call(base_mapping_arguments)
    result = IOSTemplate::RepositoryTests.run(
      repo: repo, issue: Integer(issue), expected_base: expected_base, mappings: mappings, base_mappings: base_mappings,
      retry_after_targeted: retry_after_targeted
    )
    puts JSON.generate(result)
  rescue IOSTemplate::RepositoryTests::RunnerError => error
    warn "repository test evidence failed: #{error.message}"
    exit 1
  end
end
