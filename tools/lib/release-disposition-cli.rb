#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require_relative "release-disposition"
require_relative "review-sealing"

module IOSTemplate
  module ReleaseDispositionCLI
    class PublicationError < StandardError; end

    GIT_ENV = {
      "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil,
      "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null",
      "GIT_NO_REPLACE_OBJECTS" => "1", "LANG" => "C", "LC_ALL" => "C"
    }.freeze

    module_function

    def run(repo:, issue:, base_sha:, head_sha:, input_path:)
      repo = File.realpath(repo)
      input = ReleaseDisposition.parse_input!(physical_file_bytes(input_path, "release disposition input"))
      current_head!(repo, head_sha)
      ancestor!(repo, base_sha, head_sha)
      topology = topology!(repo)
      snapshots = ReviewSealing::SnapshotSet.new(
        topology.fetch("artifactsRoot"), at: "artifact root",
        expected_identity: topology.values_at("artifactsDevice", "artifactsInode")
      )
      published = nil
      begin
        issue_directory = snapshots.relative_leaf("issues/#{issue}/issue-contract.json", at: "issue contract").parent
        contract_file = snapshots.leaf(issue_directory, "issue-contract.json", at: "issue contract")
        contract = JSON.parse(contract_file.bytes.dup)
        binding = ReleasePhase.binding_from_contract!(contract)
        reject("release disposition requires a Release-phase binding") unless binding
        head_directory = snapshots.directory(issue_directory, head_sha, at: "Head artifact directory")
        failure_files = {}
        ReleaseDisposition.failure_paths(issue: issue, head_sha: head_sha).each do |path|
          leaf = optional_leaf(
            snapshots, head_directory, File.basename(path), "repository test failure #{path}"
          )
          failure_files[path] = leaf.bytes if leaf
        end
        phase_record_bytes = ReleaseDisposition.phase_record_bytes!(
          repo: repo, base_sha: base_sha, contract: contract
        )
        record = ReleaseDisposition.build(
          contract_bytes: contract_file.bytes, phase_record_bytes: phase_record_bytes,
          issue: issue, base_sha: base_sha, head_sha: head_sha,
          entries: input.fetch("entries"), execution_decisions: input.fetch("executionDecisions"),
          failure_record_bytes: failure_files, recorded_at: input.fetch("recordedAt")
        )
        bytes = ReleaseDisposition.canonical_bytes(record)
        snapshots.verify!
        current_head!(repo, head_sha)
        published = snapshots.publish_exclusive(
          head_directory, "release-disposition.json", bytes, at: "release disposition"
        )
        snapshots.verify!
        current_head!(repo, head_sha)
        reference = ReleaseDisposition.references!(record_bytes: published.bytes, issue: issue, head_sha: head_sha).fetch("record")
        counts = record.fetch("entries").group_by { |entry| entry.fetch("type") }.transform_values(&:length)
        {"status" => "published", "reference" => reference, "entryCounts" => counts,
         "executionDecisionCount" => record.fetch("executionDecisions").length}
      rescue StandardError
        snapshots.unlink_if_same(head_directory, published) if published
        raise
      ensure
        snapshots.close
      end
    rescue ReleaseDisposition::ValidationError, ReleasePhase::ValidationError, ReviewSealing::SealError,
           JSON::ParserError, KeyError, SystemCallError, IOError, ArgumentError => error
      raise PublicationError, error.message
    end

    def topology!(repo)
      output, status = Open3.capture2e(GIT_ENV, "/usr/bin/ruby", File.join(__dir__, "review-artifacts.rb"), repo)
      reject("artifact topology is invalid: #{output.strip}") unless status.success?
      JSON.parse(output)
    end

    def current_head!(repo, head_sha)
      output, status = Open3.capture2e(GIT_ENV, "/usr/bin/git", "-C", repo, "rev-parse", "HEAD")
      reject("current Head differs from the release disposition candidate") unless status.success? && output.strip == head_sha
    end

    def ancestor!(repo, base_sha, head_sha)
      _, status = Open3.capture2e(GIT_ENV, "/usr/bin/git", "-C", repo, "merge-base", "--is-ancestor", base_sha, head_sha)
      reject("candidate Base is not an ancestor of Head") unless status.success?
    end

    def physical_file_bytes(path, at)
      reject("#{at} path must be absolute") unless path.is_a?(String) && path.start_with?("/")
      stat = File.lstat(path)
      reject("#{at} must be a regular single-link file") unless stat.file? && !stat.symlink? && stat.nlink == 1
      bytes = File.binread(path)
      final = File.lstat(path)
      reject("#{at} changed while read") unless
        [stat.dev, stat.ino, stat.size, stat.mode, stat.mtime.to_r] ==
          [final.dev, final.ino, final.size, final.mode, final.mtime.to_r] && bytes.bytesize == final.size
      bytes
    end

    def optional_leaf(snapshots, directory, name, at)
      snapshots.leaf(directory, name, at: at)
    rescue SystemCallError => error
      return nil if error.errno == Errno::ENOENT::Errno
      raise
    end

    def reject(message)
      raise PublicationError, message
    end
  end
end

if $PROGRAM_NAME == __FILE__
  repo, issue_text, base_sha, head_sha, input_path = ARGV
  unless repo && issue_text&.match?(/\A[1-9][0-9]*\z/) && base_sha&.match?(/\A[0-9a-f]{40}\z/) &&
         head_sha&.match?(/\A[0-9a-f]{40}\z/) && input_path && ARGV.length == 5
    warn "usage: release-disposition-cli.rb REPOSITORY_ROOT ISSUE BASE_SHA HEAD_SHA INPUT"
    exit 2
  end
  begin
    puts JSON.generate(IOSTemplate::ReleaseDispositionCLI.run(
      repo: repo, issue: Integer(issue_text), base_sha: base_sha, head_sha: head_sha,
      input_path: File.expand_path(input_path)
    ))
  rescue IOSTemplate::ReleaseDispositionCLI::PublicationError => error
    warn "release disposition publication failed: #{error.message}"
    exit 1
  end
end
