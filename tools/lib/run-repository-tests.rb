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

module IOSTemplate
  module RepositoryTests
    class RunnerError < StandardError; end

    module_function

    SHA = /\A[0-9a-f]{40}\z/
    TEST_PATH = %r{\Atools/tests/test-[a-z0-9-]+\.sh\z}
    RUNNER_PATHS = %w[tools/run-repository-tests.sh tools/lib/run-repository-tests.rb].freeze
    DEFAULT_CHILD_TIMEOUT_SECONDS = 900

    def run(repo:, issue:, expected_base:, mappings:)
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

        tests = tracked_tests(repo, head_sha)
        reject("no tracked repository tests were found") if tests.empty?
        acceptance = validate_mappings!(mappings, criteria, tests)
        runner_files = RUNNER_PATHS.map do |path|
          bytes = git!(repo, "show", "#{head_sha}:#{path}").b
          {"path" => path, "digest" => ReviewContract.digest(bytes)}
        end

        suite_started = Time.now.utc
        results = execute_in_detached_worktree(repo, head_sha, tests)
        suite_completed = Time.now.utc
        failure = results.find { |entry| entry["status"] != "passed" }
        reject("repository test failed: #{failure.fetch('path')}") if failure

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
        bytes = JSON.generate(evidence).b
        snapshots.verify!
        reject("current Head changed before evidence publication") unless git!(repo, "rev-parse", "HEAD").strip == head_sha
        leaf = snapshots.publish_exclusive(head_directory, "repository-tests.json", bytes, at: "repository-tests.json")
        snapshots.verify!

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
    rescue ReviewContract::ValidationError, ReviewSealing::SealError, JSON::ParserError, KeyError,
           SystemCallError, IOError => error
      raise RunnerError, error.message
    end

    def execute_in_detached_worktree(repo, head_sha, tests)
      results = []
      Dir.mktmpdir("ios-template-repository-tests-") do |temporary|
        worktree = File.join(temporary, "worktree")
        git!(repo, "worktree", "add", "--detach", worktree, head_sha)
        begin
          reject("detached test worktree resolved an unexpected Head") unless git!(worktree, "rev-parse", "HEAD").strip == head_sha
          tests.each do |path|
            arguments = test_arguments(path)
            started = Time.now.utc
            timeout_seconds = repository_test_timeout_seconds
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
            reject("repository test timed out: #{path}; elapsedSeconds=#{format('%.3f', elapsed)}") if timed_out
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

    def repository_test_timeout_seconds
      raw = ENV.fetch("IOS_TEMPLATE_REPOSITORY_TEST_TIMEOUT_SECONDS", DEFAULT_CHILD_TIMEOUT_SECONDS.to_s)
      value = Integer(raw, 10)
      reject("repository test timeout must be a positive integer") unless value.positive?
      value
    rescue ArgumentError
      reject("repository test timeout must be a positive integer")
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
  until ARGV.empty?
    case ARGV.shift
    when "--issue" then issue = ARGV.shift
    when "--expected-base" then expected_base = ARGV.shift
    when "--map" then mapping_arguments << ARGV.shift
    else
      warn "usage: run-repository-tests.sh --issue NUMBER --expected-base SHA --map AC-N=TEST[,TEST...] ..."
      exit 2
    end
  end
  unless repo && issue&.match?(/\A[1-9][0-9]*\z/) && expected_base && !mapping_arguments.empty? && mapping_arguments.none?(&:nil?)
    warn "usage: run-repository-tests.sh --issue NUMBER --expected-base SHA --map AC-N=TEST[,TEST...] ..."
    exit 2
  end
  begin
    mappings = {}
    mapping_arguments.each do |argument|
      id, paths = argument.split("=", 2)
      IOSTemplate::RepositoryTests.reject("acceptance mapping is invalid") unless id&.match?(/\AAC-[1-9][0-9]*\z/) && paths && !paths.empty? && !mappings.key?(id)
      mappings[id] = paths.split(",", -1)
    end
    result = IOSTemplate::RepositoryTests.run(
      repo: repo, issue: Integer(issue), expected_base: expected_base, mappings: mappings
    )
    puts JSON.generate(result)
  rescue IOSTemplate::RepositoryTests::RunnerError => error
    warn "repository test evidence failed: #{error.message}"
    exit 1
  end
end
