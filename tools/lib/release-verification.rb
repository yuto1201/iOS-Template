# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require_relative "review-sealing"
require_relative "verification-scope"

module IOSTemplate
  module ReleaseVerification
    class InvalidProof < StandardError; end
    GIT_ENV = {"GIT_DIR"=>nil, "GIT_WORK_TREE"=>nil, "GIT_COMMON_DIR"=>nil,
               "GIT_CONFIG_GLOBAL"=>"/dev/null", "GIT_CONFIG_SYSTEM"=>"/dev/null"}.freeze
    module_function

    def topology(repo)
      output, status = Open3.capture2e(GIT_ENV, "/usr/bin/ruby", File.join(__dir__, "review-artifacts.rb"), repo)
      raise InvalidProof, "release verification artifact topology is invalid" unless status.success?
      JSON.parse(output)
    end

    def current_head!(repo, head)
      output, status = Open3.capture2e(GIT_ENV, "/usr/bin/git", "-C", repo, "rev-parse", "HEAD")
      raise InvalidProof, "release verification source Head is stale" unless status.success? && output.strip == head
    end

    # Build the result in memory, then recheck the held proof and topology just
    # before publishing. Never upgrade a partial/old package by inference.
    def with_full_proof(repo:, issue:, base:, head:, bundle:, publish:, expected_reference: nil)
      raise InvalidProof, "release verification Issue is invalid" unless issue.is_a?(Integer) && issue.positive?
      unless [base, head].all? { |sha| sha.is_a?(String) && sha.match?(/\A[0-9a-f]{40}\z/) }
        raise InvalidProof, "release verification Git identity is invalid"
      end
      current_head!(repo, head)
      layout = topology(repo)
      snapshots = ReviewSealing::SnapshotSet.new(layout.fetch("artifactsRoot"), at: "release verification",
        expected_identity: layout.values_at("artifactsDevice", "artifactsInode"))
      begin
        contract_file = snapshots.relative_leaf("issues/#{issue}/issue-contract.json", at: "release verification contract")
        verify_file = snapshots.relative_leaf("issues/#{issue}/#{head}/verify.json", at: "release verification proof")
        contract = JSON.parse(contract_file.bytes.dup)
        verify = JSON.parse(verify_file.bytes.dup)
        reference = {"issue"=>issue, "baseSha"=>base, "path"=>".artifacts/issues/#{issue}/#{head}/verify.json",
                     "digest"=>"sha256:#{Digest::SHA256.hexdigest(verify_file.bytes)}"}
        if expected_reference && reference != expected_reference
          raise InvalidProof, "release verification reference changed after preparation"
        end
        scope = VerificationScope.validate_contract!(contract)
        unless scope == "full" && verify["changeClassification"] == "application-code" && verify["status"] == "passed" &&
               verify["cases"].is_a?(Array) && verify["cases"].map { |entry| entry["id"] } == VerificationScope::FULL_IDS
          raise InvalidProof, "release requires passed full application verification"
        end
        unless contract.dig("verification", "bundleIdentifier") == bundle
          raise InvalidProof, "release verification bundle identity differs"
        end
        output, status = Open3.capture2e(GIT_ENV, "/usr/bin/swift", File.expand_path("../validate-verify-json.swift", __dir__),
          "--file", reference.fetch("path"), "--expected-file-digest", reference.fetch("digest"),
          "--expected-issue", issue.to_s, "--expected-base", base, "--expected-head", head, chdir: repo)
        raise InvalidProof, "canonical release verification failed: #{output.strip}" unless status.success?
        value = yield reference
        snapshots.verify!
        raise InvalidProof, "release verification topology changed" unless topology(repo) == layout
        current_head!(repo, head)
        publish.call(value)
        value
      ensure
        snapshots.close
      end
    rescue ReviewSealing::SealError, JSON::ParserError, KeyError, ArgumentError, TypeError, SystemCallError => error
      raise InvalidProof, "release verification is unavailable or invalid: #{error.message}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise IOSTemplate::ReleaseVerification::InvalidProof, "usage: release-verification.rb REPO PACKAGE_MANIFEST HEAD BUNDLE_ID" unless ARGV.length == 4
    repo, manifest_path, head, bundle = ARGV
    repo = File.realpath(repo)
    manifest_path = File.expand_path(manifest_path)
    stat = File.lstat(manifest_path)
    unless stat.file? && !stat.symlink? && stat.nlink == 1
      raise IOSTemplate::ReleaseVerification::InvalidProof, "prepared verification manifest path is unsafe"
    end
    manifest_path = File.realpath(manifest_path)
    manifest = JSON.parse(File.binread(manifest_path))
    version = manifest["version"]
    unless version.is_a?(String) && version.match?(/\A[0-9]+(?:\.[0-9]+){1,2}\z/) &&
           manifest_path == File.join(repo, "App Store", "submission", "#{version}-package.json") &&
           manifest["schemaVersion"] == 2 && manifest["status"] == "prepared" &&
           manifest["sourceSha"] == head && manifest["bundleId"] == bundle
      raise IOSTemplate::ReleaseVerification::InvalidProof, "prepared verification manifest identity is invalid"
    end
    reference = manifest.fetch("verification")
    unless reference.is_a?(Hash) && reference.keys.sort == %w[baseSha digest issue path]
      raise IOSTemplate::ReleaseVerification::InvalidProof, "prepared verification reference is invalid"
    end
    IOSTemplate::ReleaseVerification.with_full_proof(
      repo: repo, issue: reference["issue"], base: reference["baseSha"], head: head, bundle: bundle,
      expected_reference: reference, publish: ->(value) { puts JSON.generate("status"=>"verified", "verification"=>value) }
    ) { |value| value }
  rescue IOSTemplate::ReleaseVerification::InvalidProof, KeyError, JSON::ParserError, SystemCallError => error
    warn error.message
    exit 1
  end
end
