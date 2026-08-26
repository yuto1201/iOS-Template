#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "time"

module IOSTemplate
  module ReviewReceipt
    class ValidationError < StandardError; end

    KEYS = %w[
      schemaVersion issue headSha primaryModel reviewerModel launcher
      launcherDigest reviewerLauncher reviewerLauncherDigest reviewPacketDigest
      validatedResultDigest publishedReviewDigest startedAt completedAt exitStatus
    ].freeze
    DIGEST = /\Asha256:[0-9a-f]{64}\z/

    module_function

    def digest(bytes)
      "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    end

    def launcher_for(primary)
      primary == "codex" ? "tools/cross-model-review.sh" : "tools/request-codex-review.sh"
    end

    def build(repo:, primary:, issue:, head_sha:, packet_bytes:, validated_result_bytes:, published_review_bytes:, started_at:, completed_at:)
      reviewer = primary == "codex" ? "claude" : "codex"
      reviewer_launcher = launcher_for(primary)
      {
        "schemaVersion" => 1,
        "issue" => issue,
        "headSha" => head_sha,
        "primaryModel" => primary,
        "reviewerModel" => reviewer,
        "launcher" => "tools/cross-model-review.sh",
        "launcherDigest" => digest(File.binread(File.join(repo, "tools/cross-model-review.sh"))),
        "reviewerLauncher" => reviewer_launcher,
        "reviewerLauncherDigest" => digest(File.binread(File.join(repo, reviewer_launcher))),
        "reviewPacketDigest" => digest(packet_bytes),
        "validatedResultDigest" => digest(validated_result_bytes),
        "publishedReviewDigest" => digest(published_review_bytes),
        "startedAt" => started_at,
        "completedAt" => completed_at,
        "exitStatus" => 0
      }
    end

    def validate!(receipt_bytes:, packet_bytes:, review_bytes:, repo:, primary:, issue:, head_sha:, now: Time.now.utc)
      receipt = JSON.parse(receipt_bytes)
      reject!("receipt must be an object") unless receipt.is_a?(Hash)
      reject!("receipt has unexpected or missing fields") unless receipt.keys.sort == KEYS.sort
      reject!("receipt schemaVersion is unsupported") unless receipt["schemaVersion"] == 1
      reject!("receipt Issue or Head differs") unless receipt["issue"] == issue && receipt["headSha"] == head_sha
      reviewer = primary == "codex" ? "claude" : "codex"
      reject!("receipt is not an opposite-model review") unless receipt["primaryModel"] == primary && receipt["reviewerModel"] == reviewer
      reject!("receipt exit status is not successful") unless receipt["exitStatus"] == 0

      expected_launcher = "tools/cross-model-review.sh"
      expected_reviewer_launcher = launcher_for(primary)
      reject!("receipt launcher identity differs") unless receipt["launcher"] == expected_launcher && receipt["reviewerLauncher"] == expected_reviewer_launcher
      expected_launcher_digest = digest(File.binread(File.join(repo, expected_launcher)))
      expected_reviewer_launcher_digest = digest(File.binread(File.join(repo, expected_reviewer_launcher)))
      reject!("receipt launcher bytes differ") unless receipt["launcherDigest"] == expected_launcher_digest && receipt["reviewerLauncherDigest"] == expected_reviewer_launcher_digest

      %w[launcherDigest reviewerLauncherDigest reviewPacketDigest validatedResultDigest publishedReviewDigest].each do |field|
        reject!("receipt #{field} is invalid") unless receipt[field].is_a?(String) && receipt[field].match?(DIGEST)
      end
      reject!("receipt packet digest differs") unless receipt["reviewPacketDigest"] == digest(packet_bytes)
      expected_review_digest = digest(review_bytes)
      reject!("receipt validated result digest differs") unless receipt["validatedResultDigest"] == expected_review_digest
      reject!("receipt published review digest differs") unless receipt["publishedReviewDigest"] == expected_review_digest

      started = timestamp!(receipt["startedAt"], "startedAt")
      completed = timestamp!(receipt["completedAt"], "completedAt")
      reject!("receipt completion predates launch") if completed < started
      reject!("receipt completion is implausibly in the future") if completed > now + 300
      receipt
    rescue JSON::ParserError => error
      raise ValidationError, "receipt is not valid JSON: #{error.message}"
    rescue Errno::ENOENT, Errno::EACCES => error
      raise ValidationError, "receipt launcher is unavailable: #{error.message}"
    end

    def timestamp!(value, field)
      reject!("receipt #{field} must be a nonempty timestamp") unless value.is_a?(String) && !value.empty?
      Time.iso8601(value).utc
    rescue ArgumentError
      raise ValidationError, "receipt #{field} must be ISO 8601"
    end

    def reject!(message)
      raise ValidationError, message
    end
  end
end
