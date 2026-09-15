# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require_relative "review-sealing"
require_relative "verification-scope"
require_relative "evidence-applicability"
require_relative "release-disposition"

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
    def with_full_proof(repo:, issue:, base:, head:, bundle:, publish:, expected_reference: nil, artifact_digest: nil)
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
        contract = JSON.parse(contract_file.bytes.dup)
        disposition_file = optional_leaf(
          snapshots, "issues/#{issue}/#{head}/release-disposition.json", "release disposition"
        )
        if ReleaseDisposition.required?(contract) && !disposition_file
          raise InvalidProof, "Phase 5 or 6 release requires a canonical release disposition"
        end
        if disposition_file
          failure_bytes = ReleaseDisposition.failure_paths(issue: issue, head_sha: head).each_with_object({}) do |path, values|
            failure_file = snapshots.optional_relative_leaf(
              path.delete_prefix(".artifacts/"), at: "release disposition failure #{path}"
            )
            values[path] = failure_file.bytes if failure_file
          end
          phase_record_bytes = ReleaseDisposition.phase_record_bytes!(
            repo: repo, base_sha: base, contract: contract
          )
          disposition = ReleaseDisposition.validate!(
            record_bytes: disposition_file.bytes, contract_bytes: contract_file.bytes,
            phase_record_bytes: phase_record_bytes, issue: issue, base_sha: base, head_sha: head,
            failure_record_bytes: failure_bytes
          )
          ReleaseDisposition.release_ready!(disposition)
        end
        applicability_file = optional_leaf(
          snapshots, "issues/#{issue}/#{head}/evidence-applicability.json", "release evidence applicability"
        )
        if EvidenceApplicability.required?(contract) && !applicability_file
          raise InvalidProof, "Phase 6 release requires a canonical evidence applicability decision"
        end

        applicability = nil
        if applicability_file
          applicability_references = EvidenceApplicability.references!(
            record_bytes: applicability_file.bytes, target_issue: issue, target_head_sha: head
          )
          source_verify_file = snapshots.relative_leaf(
            applicability_references.fetch("sourceVerify").fetch("path").delete_prefix(".artifacts/"),
            at: "Phase 5 source verification"
          )
          source_contract_file = snapshots.relative_leaf(
            applicability_references.fetch("sourceContract").fetch("path").delete_prefix(".artifacts/"),
            at: "Phase 5 source contract"
          )
          applicability = EvidenceApplicability.validate!(
            record_bytes: applicability_file.bytes, repo: repo, target_contract_bytes: contract_file.bytes,
            source_verify_bytes: source_verify_file.bytes, source_contract_bytes: source_contract_file.bytes
          )
          unless applicability.dig("target", "issue") == issue && applicability.dig("target", "baseSha") == base &&
                 applicability.dig("target", "headSha") == head
            raise InvalidProof, "release applicability target differs from caller"
          end
          effective_artifact_digest = artifact_digest || ENV["BUILD_DIGEST"]
          unless effective_artifact_digest.is_a?(String) && effective_artifact_digest.match?(/\Asha256:[0-9a-f]{64}\z/)
            raise InvalidProof, "release build artifact digest is required by the applicability decision"
          end
          unless applicability.dig("targetContext", "artifactDigest") == effective_artifact_digest
            raise InvalidProof, "release build artifact differs from the applicability decision"
          end
          reference = {
            "issue" => issue, "baseSha" => base,
            "path" => ".artifacts/issues/#{issue}/#{head}/evidence-applicability.json",
            "digest" => "sha256:#{Digest::SHA256.hexdigest(applicability_file.bytes)}"
          }
          if applicability.dig("decision", "action") == "reuse"
            proof_file = source_verify_file
            proof_contract_file = source_contract_file
            expected_proof_base = applicability.dig("source", "baseSha")
          else
            proof_file = snapshots.relative_leaf("issues/#{issue}/#{head}/verify.json", at: "release re-verification proof")
            proof_contract_file = contract_file
            expected_proof_base = applicability.dig("target", "baseSha")
            target_verify = JSON.parse(proof_file.bytes.dup)
            unless Time.iso8601(target_verify.fetch("completedAt")) > Time.iso8601(applicability.fetch("evaluatedAt"))
              raise InvalidProof, "release re-verification predates the applicability decision"
            end
          end
        else
          proof_file = snapshots.relative_leaf("issues/#{issue}/#{head}/verify.json", at: "release verification proof")
          proof_contract_file = contract_file
          expected_proof_base = base
          reference = {"issue"=>issue, "baseSha"=>base, "path"=>".artifacts/issues/#{issue}/#{head}/verify.json",
                       "digest"=>"sha256:#{Digest::SHA256.hexdigest(proof_file.bytes)}"}
        end
        if expected_reference && reference != expected_reference
          raise InvalidProof, "release verification reference changed after preparation"
        end
        proof_contract = JSON.parse(proof_contract_file.bytes.dup)
        verify = JSON.parse(proof_file.bytes.dup)
        if disposition
          ReleaseDisposition.after_evidence!(
            disposition,
            "verify.completedAt" => verify.fetch("completedAt"),
            "evidenceApplicability.evaluatedAt" => applicability&.fetch("evaluatedAt")
          )
        end
        proof_issue = verify.fetch("issue")
        proof_base = verify.fetch("baseSha")
        proof_head = verify.fetch("headSha")
        proof_path = ".artifacts/issues/#{proof_issue}/#{proof_head}/verify.json"
        proof_digest = "sha256:#{Digest::SHA256.hexdigest(proof_file.bytes)}"
        unless proof_file == source_verify_file || proof_path == ".artifacts/issues/#{issue}/#{head}/verify.json"
          raise InvalidProof, "release proof path is inconsistent"
        end
        unless proof_base == expected_proof_base
          raise InvalidProof, "release proof Base SHA differs from the caller or applicability decision"
        end
        scope = VerificationScope.validate_contract!(proof_contract)
        unless scope == "full" && verify["changeClassification"] == "application-code" && verify["status"] == "passed" &&
               verify["cases"].is_a?(Array) && verify["cases"].map { |entry| entry["id"] } == VerificationScope::FULL_IDS
          raise InvalidProof, "release requires passed full application verification"
        end
        unless proof_contract.dig("verification", "bundleIdentifier") == bundle
          raise InvalidProof, "release verification bundle identity differs"
        end
        if applicability_file && contract.dig("verification", "bundleIdentifier") != bundle
          raise InvalidProof, "Phase 6 release contract bundle identity differs"
        end
        output, status = Open3.capture2e(GIT_ENV, "/usr/bin/swift", File.expand_path("../validate-verify-json.swift", __dir__),
          "--file", proof_path, "--expected-file-digest", proof_digest,
          "--expected-issue", proof_issue.to_s, "--expected-base", expected_proof_base, "--expected-head", proof_head, chdir: repo)
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
    rescue ReviewSealing::SealError, EvidenceApplicability::ValidationError, ReleaseDisposition::ValidationError, JSON::ParserError,
           KeyError, ArgumentError, TypeError, SystemCallError => error
      raise InvalidProof, "release verification is unavailable or invalid: #{error.message}"
    end

    def optional_leaf(snapshots, relative, at)
      snapshots.relative_leaf(relative, at: at)
    rescue SystemCallError => error
      return nil if error.errno == Errno::ENOENT::Errno
      raise
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
      expected_reference: reference, artifact_digest: manifest["buildDigest"],
      publish: ->(value) { puts JSON.generate("status"=>"verified", "verification"=>value) }
    ) { |value| value }
  rescue IOSTemplate::ReleaseVerification::InvalidProof, KeyError, JSON::ParserError, SystemCallError => error
    warn error.message
    exit 1
  end
end
