#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require_relative "review-contract"
require_relative "review-sealing"

module IOSTemplate
  module PrepareReviewPacket
    class PreparationError < StandardError; end

    module_function

    def prepare(repo:, primary:, issue:, base_sha:, head_sha:, before_publish: nil)
      reject("primary model is invalid") unless %w[codex claude].include?(primary)
      reject("issue must be a positive integer") unless issue.is_a?(Integer) && issue.positive?
      [base_sha, head_sha].each { |sha| reject("Git SHA is invalid") unless sha.match?(/\A[0-9a-f]{40}\z/) }
      reject("repository root must be a physical absolute directory") unless repo.start_with?("/") && File.realpath(repo) == repo

      topology = topology!(repo)
      artifacts = topology.fetch("artifactsRoot")
      snapshots = ReviewSealing::SnapshotSet.new(
        artifacts, at: "artifact root",
        expected_identity: [topology.fetch("artifactsDevice"), topology.fetch("artifactsInode")]
      )
      published_diff = false
      published_packet = false
      begin
        issues = snapshots.directory(snapshots.root, "issues", at: "issues")
        issue_directory = snapshots.directory(issues, issue.to_s, at: "Issue artifact directory")
        issue_directory.io.flock(File::LOCK_EX)
        head_directory = snapshots.directory(issue_directory, head_sha, at: "Head artifact directory")
        contract_file = snapshots.leaf(issue_directory, "issue-contract.json", at: "issue contract")
        verify_file = snapshots.leaf(head_directory, "verify.json", at: "verify.json")
        contract = parse_object(contract_file.bytes, "issue contract")
        verify = parse_object(verify_file.bytes, "verify.json")
        contract_digest = ReviewContract.digest(contract_file.bytes)
        validate_inputs!(contract, verify, issue, base_sha, head_sha, contract_digest)

        image_references = ReviewContract.verified_image_references!(verify, issue: issue, head_sha: head_sha)
        image_files = image_references.map do |reference|
          relative = reference.fetch("path").delete_prefix(".artifacts/")
          leaf = snapshots.relative_leaf(relative, at: "verified image #{reference.fetch('path')}")
          reject("verified image digest differs from exact bytes: #{reference.fetch('path')}") unless ReviewContract.digest(leaf.bytes) == reference.fetch("digest")
          [reference, leaf]
        end
        actual_diff = ReviewContract.actual_diff(repo: repo, base_sha: base_sha, head_sha: head_sha)
        prefix = ".artifacts/issues/#{issue}/#{head_sha}/"
        packet = {
          "schemaVersion" => 2,
          "issue" => issue,
          "primaryModel" => primary,
          "reviewerModel" => primary == "codex" ? "claude" : "codex",
          "baseSha" => base_sha,
          "headSha" => head_sha,
          "verifySha" => head_sha,
          "issueContract" => {"path" => ".artifacts/issues/#{issue}/issue-contract.json", "digest" => contract_digest},
          "specAnchors" => contract.fetch("specAnchors"),
          "acceptanceCriteria" => contract.fetch("acceptanceCriteria"),
          "diff" => {"path" => "#{prefix}review.diff", "digest" => ReviewContract.digest(actual_diff)},
          "verify" => {"path" => "#{prefix}verify.json", "digest" => ReviewContract.digest(verify_file.bytes)},
          "imageFiles" => image_references
        }
        packet_bytes = JSON.generate(packet).b

        validate_git_identity!(repo, base_sha, head_sha)
        snapshots.verify!
        reject("Base..Head diff changed before publication") unless ReviewContract.actual_diff(repo: repo, base_sha: base_sha, head_sha: head_sha) == actual_diff
        before_publish&.call
        snapshots.verify!
        validate_git_identity!(repo, base_sha, head_sha)
        reject("Base..Head diff changed during publication") unless ReviewContract.actual_diff(repo: repo, base_sha: base_sha, head_sha: head_sha) == actual_diff

        diff_leaf = existing_leaf(snapshots, head_directory, "review.diff", "review.diff")
        if diff_leaf
          reject("existing review.diff differs from the exact Base..Head diff") unless diff_leaf.bytes == actual_diff
        else
          diff_leaf = snapshots.publish_exclusive(head_directory, "review.diff", actual_diff, at: "review.diff")
          published_diff = true
        end
        packet_leaf = existing_leaf(snapshots, head_directory, "review-packet.json", "review-packet.json")
        if packet_leaf
          reject("existing review-packet.json differs from the exact review closure") unless packet_leaf.bytes == packet_bytes
        else
          packet_leaf = snapshots.publish_exclusive(head_directory, "review-packet.json", packet_bytes, at: "review-packet.json")
          published_packet = true
        end

        snapshots.verify!
        validate_git_identity!(repo, base_sha, head_sha)
        reject("Base..Head diff changed after publication") unless ReviewContract.actual_diff(repo: repo, base_sha: base_sha, head_sha: head_sha) == actual_diff
        # Touch every held image descriptor after publication before returning.
        image_files.each { |reference, leaf| reject("verified image changed after packet publication") unless ReviewContract.digest(leaf.bytes) == reference.fetch("digest") }

        {
          "path" => "#{prefix}review-packet.json",
          "digest" => ReviewContract.digest(packet_bytes),
          "diffDigest" => ReviewContract.digest(actual_diff),
          "verifyDigest" => ReviewContract.digest(verify_file.bytes),
          "imageFiles" => image_references
        }
      rescue StandardError
        if published_packet
          snapshots.unlink_if_same(head_directory, packet_leaf) rescue nil
        end
        if published_diff
          snapshots.unlink_if_same(head_directory, diff_leaf) rescue nil
        end
        raise
      ensure
        snapshots.close
      end
    rescue ReviewContract::ValidationError, ReviewSealing::SealError, KeyError, JSON::ParserError,
           SystemCallError, IOError, Errno::ENOENT, Errno::EACCES => error
      raise PreparationError, error.message
    end

    def topology!(repo)
      helper = File.join(repo, "tools", "lib", "review-artifacts.rb")
      output, status = Open3.capture2e(
        {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil},
        "/usr/bin/ruby", helper, repo
      )
      reject("review artifact topology is invalid: #{output.strip}") unless status.success?
      JSON.parse(output)
    end

    def validate_inputs!(contract, verify, issue, base_sha, head_sha, contract_digest)
      ReviewContract.validate_contract_keys!(contract)
      reject("issue contract identity differs from caller") unless contract["schemaVersion"] == 1 && contract["issue"] == issue
      ReviewContract.digest!(contract["externalOperationDetailsDigest"], "issue contract.externalOperationDetailsDigest")
      reject("verify identity differs from caller") unless verify["schemaVersion"] == 1 && verify["issue"] == issue && verify["baseSha"] == base_sha && verify["headSha"] == head_sha
      reject("verify is not complete") unless %w[passed not-applicable].include?(verify["status"])
      reject("verify issue contract differs from exact bytes") unless verify["issueContract"] == {"path" => ".artifacts/issues/#{issue}/issue-contract.json", "digest" => contract_digest}
    end

    def validate_git_identity!(repo, base_sha, head_sha)
      environment = {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil, "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null"}
      current, current_status = Open3.capture2e(environment, "/usr/bin/git", "-C", repo, "rev-parse", "HEAD")
      reject("current Head changed") unless current_status.success? && current.strip == head_sha
      _, ancestor_status = Open3.capture2e(environment, "/usr/bin/git", "-C", repo, "merge-base", "--is-ancestor", base_sha, head_sha)
      reject("Base is not an ancestor of Head") unless ancestor_status.success?
    end

    def existing_leaf(snapshots, directory, name, at)
      snapshots.leaf(directory, name, at: at)
    rescue SystemCallError => error
      return nil if error.errno == Errno::ENOENT::Errno
      raise
    end

    def parse_object(bytes, at)
      # JSON.parse changes a binary String's encoding in place. Parse a copy so
      # the descriptor-bound snapshot remains byte-for-byte comparable when a
      # contract or verification document contains non-ASCII text.
      value = JSON.parse(bytes.dup)
      reject("#{at} must be an object") unless value.is_a?(Hash)
      value
    end

    def reject(message)
      raise PreparationError, message
    end
  end
end

if $PROGRAM_NAME == __FILE__
  repo, primary, issue_text, base_sha, head_sha = ARGV
  unless repo && primary && issue_text&.match?(/\A[1-9][0-9]*\z/) && base_sha && head_sha
    warn "usage: prepare-review-packet.rb REPOSITORY_ROOT codex|claude ISSUE BASE_SHA HEAD_SHA"
    exit 2
  end
  begin
    puts JSON.generate(IOSTemplate::PrepareReviewPacket.prepare(
      repo: repo, primary: primary, issue: Integer(issue_text), base_sha: base_sha, head_sha: head_sha
    ))
  rescue IOSTemplate::PrepareReviewPacket::PreparationError => error
    warn "review packet preparation failed: #{error.message}"
    exit 1
  end
end
