#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require_relative "evidence-applicability"
require_relative "review-sealing"

module IOSTemplate
  module EvidenceApplicabilityCLI
    class PublicationError < StandardError; end

    module_function

    def run(repo:, issue:, base_sha:, head_sha:, input_path:)
      repo = File.realpath(repo)
      input_bytes = physical_file_bytes(input_path, "applicability input")
      input = EvidenceApplicability.parse_input!(input_bytes)
      topology = topology!(repo)
      snapshots = ReviewSealing::SnapshotSet.new(
        topology.fetch("artifactsRoot"), at: "artifact root",
        expected_identity: topology.values_at("artifactsDevice", "artifactsInode")
      )
      published = nil
      begin
        issue_directory = snapshots.relative_leaf("issues/#{issue}/issue-contract.json", at: "target issue contract").parent
        contract_file = snapshots.leaf(issue_directory, "issue-contract.json", at: "target issue contract")
        head_directory = snapshots.directory(issue_directory, head_sha, at: "target Head evidence directory")
        source_file = snapshots.relative_leaf(input.fetch("sourceVerify").delete_prefix(".artifacts/"), at: "Phase 5 source verification")
        source_verify = JSON.parse(source_file.bytes.dup)
        source_contract_path = source_verify.dig("issueContract", "path")
        reject("source verification lacks a canonical contract reference") unless source_contract_path.is_a?(String) && source_contract_path.start_with?(".artifacts/")
        source_contract_file = snapshots.relative_leaf(source_contract_path.delete_prefix(".artifacts/"), at: "Phase 5 source contract")

        record = EvidenceApplicability.build(
          repo: repo, target_issue: issue, target_base_sha: base_sha, target_head_sha: head_sha,
          target_contract_bytes: contract_file.bytes,
          source_verify_path: input.fetch("sourceVerify"), source_verify_bytes: source_file.bytes,
          source_contract_bytes: source_contract_file.bytes,
          source_context: input.fetch("sourceContext"), target_context: input.fetch("targetContext"),
          impact_entries: input.fetch("impact"), reason: input.fetch("reason"), evaluated_at: input.fetch("evaluatedAt")
        )
        bytes = EvidenceApplicability.canonical_bytes(record)
        snapshots.verify!
        published = snapshots.publish_exclusive(
          head_directory, "evidence-applicability.json", bytes, at: "evidence applicability"
        )
        snapshots.verify!
        reference = EvidenceApplicability.references!(record_bytes: bytes, target_issue: issue, target_head_sha: head_sha).fetch("record")
        {"status" => "published", "decision" => record.dig("decision", "action"), "reference" => reference}
      rescue StandardError
        snapshots.unlink_if_same(head_directory, published) if published
        raise
      ensure
        snapshots.close
      end
    rescue EvidenceApplicability::ValidationError, ReviewSealing::SealError, JSON::ParserError,
           KeyError, SystemCallError, IOError, ArgumentError => error
      raise PublicationError, error.message
    end

    def topology!(repo)
      helper = File.join(__dir__, "review-artifacts.rb")
      output, status = Open3.capture2e(EvidenceApplicability::GIT_ENV, "/usr/bin/ruby", helper, repo)
      reject("artifact topology is invalid: #{output.strip}") unless status.success?
      JSON.parse(output)
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

    def reject(message)
      raise PublicationError, message
    end
  end
end

if $PROGRAM_NAME == __FILE__
  repo, issue_text, base_sha, head_sha, input_path = ARGV
  unless repo && issue_text&.match?(/\A[1-9][0-9]*\z/) && base_sha&.match?(/\A[0-9a-f]{40}\z/) &&
         head_sha&.match?(/\A[0-9a-f]{40}\z/) && input_path && ARGV.length == 5
    warn "usage: evidence-applicability-cli.rb REPOSITORY_ROOT ISSUE BASE_SHA HEAD_SHA INPUT"
    exit 2
  end
  begin
    puts JSON.generate(IOSTemplate::EvidenceApplicabilityCLI.run(
      repo: repo, issue: Integer(issue_text), base_sha: base_sha, head_sha: head_sha,
      input_path: File.expand_path(input_path)
    ))
  rescue IOSTemplate::EvidenceApplicabilityCLI::PublicationError => error
    warn "evidence applicability publication failed: #{error.message}"
    exit 1
  end
end
