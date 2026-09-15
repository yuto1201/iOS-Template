#!/bin/bash -p
set -euo pipefail

unset CDPATH ENV BASH_ENV GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

repo_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && /bin/pwd -P)

/usr/bin/ruby -I"$repo_root/tools/lib" -rjson -rdigest -rfileutils -rshellwords -rtmpdir -rrelease-disposition -rrelease-disposition-cli -rreview-contract -rdelivery-profile -rworkflow-release-phase <<'RUBY'
module ReleaseDispositionTest
  module_function

  ISSUE = 501
  BASE = "a" * 40
  HEAD = "b" * 40
  NOW = Time.iso8601("2026-09-15T12:00:00Z")

  def assert(message)
    raise message unless yield
  end

  def rejects(message)
    yield
  rescue IOSTemplate::ReleaseDisposition::ValidationError
    return
  else
    raise "expected rejection: #{message}"
  end

  def completion(phase)
    user_phase = [1, 3, 4].include?(phase)
    {
      "event" => "phase-completed",
      "revision" => 1,
      "phase" => phase,
      "scope" => ["core"],
      "authority" => user_phase ? "user" : "delegated",
      "actor" => user_phase ? "yuto1201" : "codex",
      "approvalReference" => user_phase ? "issue-#{phase}-user-approval" : "D-038",
      "reason" => "Phase #{phase} exit accepted.",
      "evidence" => ["issue:#{phase}"],
      "knownDefects" => [],
      "omittedTests" => [],
      "unverified" => [],
      "carryovers" => [],
      "recordedAt" => format("2026-09-15T10:%02d:00Z", phase)
    }
  end

  def phase_record
    bytes = IOSTemplate::ReleasePhase.create(
      release_identifier: "sample-v1", revision: 1, scope: ["core"],
      goal: "Ship the sample release.", actor: "yuto1201", reason: "Start the release.",
      recorded_at: "2026-09-15T10:00:00Z"
    )
    (1..4).each { |phase| bytes = IOSTemplate::ReleasePhase.append(bytes, completion(phase)) }
    bytes
  end

  def contract(record_bytes = phase_record)
    binding = {
      "releaseIdentifier" => "sample-v1", "revision" => 1, "phase" => 5,
      "scope" => ["core"], "workKind" => "implementation", "route" => "standard",
      "recordPath" => "Config/releases/sample-v1/phase-records/record-0005.json",
      "recordDigest" => "sha256:#{Digest::SHA256.hexdigest(record_bytes)}",
      "reason" => "Complete Phase 5 quality decisions."
    }
    {
      "schemaVersion" => 1, "issue" => ISSUE, "repository" => "yuto1201/iOS-Template",
      "fetchedAt" => "2026-09-15T11:01:00Z",
      "acceptanceCriteria" => [
        {"id" => "AC-1", "text" => "Release-phase binding: #{JSON.generate(IOSTemplate::ReleasePhase.canonical(binding))}"}
      ]
    }
  end

  def approval
    {
      "authority" => "user", "actor" => "yuto1201",
      "reference" => "https://github.com/yuto1201/iOS-Template/issues/#{ISSUE}#issuecomment-1001",
      "issue" => ISSUE, "baseSha" => BASE, "headSha" => HEAD,
      "approvedAt" => "2026-09-15T11:00:00Z"
    }
  end

  def entries
    [
      {
        "id" => "defect-accepted-001", "type" => "accepted-defect",
        "classification" => "cosmetic", "severity" => "low", "title" => "Minor spacing drift",
        "impact" => "One secondary label is offset by one point.",
        "workaround" => "No workaround is needed; content remains readable.",
        "fixCost" => "Re-baseline and re-review the localized screenshots.",
        "approval" => approval, "expiresAt" => "2026-09-22T11:00:00Z",
        "followUpIssue" => 601, "reevaluationCondition" => "Reevaluate before the next candidate or after layout changes."
      },
      {
        "id" => "defect-deferred-001", "type" => "deferred-defect",
        "classification" => "minor-performance", "severity" => "low", "title" => "Cold animation delay",
        "impact" => "The optional animation can start late on first launch.",
        "reason" => "The primary flow is unaffected and the bounded fix belongs in a harden Issue.",
        "followUpIssue" => 602, "resumeCondition" => "Profile the animation startup in Issue #602."
      },
      {
        "id" => "test-omitted-001", "type" => "omitted-test",
        "testPath" => "manual:legacy-device", "reason" => "The legacy device is unavailable in this bounded run.",
        "risk" => "Rendering on the legacy device remains unknown.", "followUpIssue" => 603
      },
      {
        "id" => "verification-unverified-001", "type" => "unverified",
        "scope" => "external accessory playback", "reason" => "The accessory is not available.",
        "risk" => "Accessory-specific playback remains unknown.", "followUpIssue" => 604
      }
    ]
  end

  def failure
    {
      "schemaVersion" => 1, "issue" => ISSUE, "headSha" => HEAD, "scope" => "targeted", "attempt" => 1,
      "stage" => "suite", "testPaths" => ["tools/tests/test-a.sh", "tools/tests/test-b.sh"],
      "failedTest" => "tools/tests/test-a.sh", "childTimeoutSeconds" => 300,
      "suiteTimeoutSeconds" => 900, "elapsedSeconds" => 300.25, "timedOut" => true,
      "unexecutedTestPaths" => ["tools/tests/test-b.sh"], "error" => "repository test timed out",
      "startedAt" => "2026-09-15T10:30:00Z", "completedAt" => "2026-09-15T10:35:00Z"
    }
  end

  def failure_bytes
    JSON.generate(IOSTemplate::ReleaseDisposition.canonical(failure))
  end

  def failure_reference
    {
      "path" => ".artifacts/issues/#{ISSUE}/#{HEAD}/repository-test-failure-attempt-1.json",
      "digest" => "sha256:#{Digest::SHA256.hexdigest(failure_bytes)}"
    }
  end

  def decision(action = "shrink")
    authority = %w[split defer].include?(action) ? "user" : "workflow"
    {
      "id" => "execution-001", "action" => action, "failure" => failure_reference,
      "reason" => "Stop the bounded execution and record the next action.",
      "actor" => authority == "user" ? "yuto1201" : "codex", "authority" => authority,
      "followUpIssue" => %w[split defer].include?(action) ? 605 : nil,
      "resumeCondition" => "Resume only from a new bounded plan after diagnosis.",
      "decidedAt" => "2026-09-15T11:30:00Z"
    }
  end

  def build(entries_value: entries, decisions: [decision], recorded_at: "2026-09-15T12:00:00Z")
    record = phase_record
    contract_bytes = JSON.generate(IOSTemplate::ReleaseDisposition.canonical(contract(record)))
    IOSTemplate::ReleaseDisposition.build(
      contract_bytes: contract_bytes, phase_record_bytes: record,
      issue: ISSUE, base_sha: BASE, head_sha: HEAD,
      entries: entries_value, execution_decisions: decisions,
      failure_record_bytes: {failure_reference.fetch("path") => failure_bytes},
      recorded_at: recorded_at, now: NOW
    )
  end

  def run
    record = phase_record
    contract_bytes = JSON.generate(IOSTemplate::ReleaseDisposition.canonical(contract(record)))
    value = build
    bytes = IOSTemplate::ReleaseDisposition.canonical_bytes(value)
    validated = IOSTemplate::ReleaseDisposition.validate!(
      record_bytes: bytes, contract_bytes: contract_bytes, phase_record_bytes: record,
      issue: ISSUE, base_sha: BASE, head_sha: HEAD,
      failure_record_bytes: {failure_reference.fetch("path") => failure_bytes}, now: NOW
    )
    assert("candidate identity") { validated.dig("candidate", "headSha") == HEAD }
    assert("all disposition categories stay distinct") do
      validated.fetch("entries").map { |entry| entry.fetch("type") } ==
        %w[accepted-defect deferred-defect omitted-test unverified]
    end
    assert("failure decision stays separate") { validated.fetch("executionDecisions").first.fetch("action") == "shrink" }
    assert("bound Phase 5 implementation requires disposition") { IOSTemplate::ReleaseDisposition.required?(JSON.parse(contract_bytes)) }
    IOSTemplate::ReleaseDisposition.release_ready!(validated)
    IOSTemplate::ReleaseDisposition.after_evidence!(
      validated, "verify.completedAt" => "2026-09-15T11:59:00Z"
    )
    rejects("disposition predates current evidence") do
      IOSTemplate::ReleaseDisposition.after_evidence!(
        validated, "repositoryTests.completedAt" => "2026-09-15T12:00:01Z"
      )
    end

    legacy = JSON.parse(contract_bytes)
    legacy["fetchedAt"] = "2026-09-15T10:59:59Z"
    assert("pre-cutover binding remains compatible") { !IOSTemplate::ReleaseDisposition.required?(legacy) }

    standard_candidate = JSON.parse(contract_bytes)
    standard_candidate["deliveryStage"] = {
      "name" => "harden", "timeBudgetMinutes" => 120, "reason" => "One bounded release-candidate concern."
    }
    standard_candidate["deliveryProfile"] = {"name" => "standard", "reason" => "Ordinary implementation risk."}
    assert("post-cutover Phase 5 candidate requires formal review") do
      IOSTemplate::DeliveryProfile.review_required?(standard_candidate)
    end
    standard_candidate["fetchedAt"] = "2026-09-15T10:59:59Z"
    assert("pre-cutover standard harden candidate keeps the direct route") do
      !IOSTemplate::DeliveryProfile.review_required?(standard_candidate)
    end

    packet = {
      "schemaVersion" => 2, "issue" => ISSUE, "primaryModel" => "codex", "reviewerModel" => "claude",
      "baseSha" => BASE, "headSha" => HEAD, "verifySha" => HEAD,
      "issueContract" => {"path" => ".artifacts/issues/#{ISSUE}/issue-contract.json", "digest" => IOSTemplate::ReleaseDisposition.digest(contract_bytes)},
      "specAnchors" => ["specs/acceptance.md#30"], "acceptanceCriteria" => JSON.parse(contract_bytes).fetch("acceptanceCriteria"),
      "diff" => {"path" => ".artifacts/issues/#{ISSUE}/#{HEAD}/review.diff", "digest" => "sha256:#{"1" * 64}"},
      "verify" => {"path" => ".artifacts/issues/#{ISSUE}/#{HEAD}/verify.json", "digest" => "sha256:#{"2" * 64}"},
      "imageFiles" => [], "releaseDisposition" => value,
      "releaseDispositionFile" => {"path" => ".artifacts/issues/#{ISSUE}/#{HEAD}/release-disposition.json", "digest" => IOSTemplate::ReleaseDisposition.digest(bytes)}
    }
    references = IOSTemplate::ReviewContract.strict_references!(
      packet_bytes: JSON.generate(packet), issue: ISSUE, head_sha: HEAD
    )
    assert("review packet holds disposition") { references.fetch("releaseDispositionFile") == packet.fetch("releaseDispositionFile") }
    assert("review packet holds exact failure") { references.fetch("releaseDispositionFailures") == [failure_reference] }

    %w[shrink split defer wait].each do |action|
      candidate = build(entries_value: [], decisions: [decision(action)])
      assert("#{action} decision accepted") { candidate.dig("executionDecisions", 0, "action") == action }
    end

    changed_head = JSON.parse(bytes)
    changed_head.dig("candidate", "headSha").replace("c" * 40)
    rejects("another candidate Head") do
      IOSTemplate::ReleaseDisposition.validate!(
        record_bytes: JSON.generate(IOSTemplate::ReleaseDisposition.canonical(changed_head)),
        contract_bytes: contract_bytes, phase_record_bytes: record,
        issue: ISSUE, base_sha: BASE, head_sha: HEAD,
        failure_record_bytes: {failure_reference.fetch("path") => failure_bytes}, now: NOW
      )
    end

    stale = entries
    stale.first["expiresAt"] = "2026-09-15T11:59:59Z"
    rejects("expired acceptance") { build(entries_value: stale) }

    critical = entries
    critical.first["classification"] = "data-loss"
    rejects("critical defect accepted as minor") { build(entries_value: critical) }

    unknown = entries
    unknown.first["classification"] = "unknown"
    rejects("unknown defect classification") { build(entries_value: unknown) }

    low_finding = entries
    low_finding.first["approval"]["authority"] = "review-low-finding"
    rejects("review low finding used as approval") { build(entries_value: low_finding) }

    wrong_approval = entries
    wrong_approval.first["approval"]["headSha"] = "c" * 40
    rejects("approval for another candidate") { build(entries_value: wrong_approval) }

    tampered_failure = JSON.parse(failure_bytes)
    tampered_failure["error"] = "changed"
    rejects("tampered failure record") do
      IOSTemplate::ReleaseDisposition.build(
        contract_bytes: contract_bytes, phase_record_bytes: record,
        issue: ISSUE, base_sha: BASE, head_sha: HEAD,
        entries: [], execution_decisions: [decision],
        failure_record_bytes: {failure_reference.fetch("path") => JSON.generate(tampered_failure)},
        recorded_at: "2026-09-15T12:00:00Z", now: NOW
      )
    end

    no_failure = decision
    no_failure["failure"] = {
      "path" => ".artifacts/issues/#{ISSUE}/#{HEAD}/repository-test-failure-attempt-2.json",
      "digest" => "sha256:#{"0" * 64}"
    }
    rejects("decision without failure record") { build(entries_value: [], decisions: [no_failure]) }

    rejects("failure without a post-stop decision") do
      record = phase_record
      IOSTemplate::ReleaseDisposition.build(
        contract_bytes: contract_bytes, phase_record_bytes: record,
        issue: ISSUE, base_sha: BASE, head_sha: HEAD,
        entries: [], execution_decisions: [],
        failure_record_bytes: {failure_reference.fetch("path") => failure_bytes},
        recorded_at: "2026-09-15T12:00:00Z", now: NOW
      )
    end

    rerun = decision
    rerun["action"] = "rerun-full-suite"
    rejects("unbounded rerun action") { build(entries_value: [], decisions: [rerun]) }

    waiting = build(entries_value: [], decisions: [decision("wait")])
    rejects("decision wait passes readiness") { IOSTemplate::ReleaseDisposition.release_ready!(waiting) }

    wrong_phase_record = phase_record.sub("Phase 4 exit accepted.", "Phase 4 exit changed.")
    rejects("changed Phase record") do
      IOSTemplate::ReleaseDisposition.build(
        contract_bytes: contract_bytes, phase_record_bytes: wrong_phase_record,
        issue: ISSUE, base_sha: BASE, head_sha: HEAD,
        entries: [], execution_decisions: [], failure_record_bytes: {},
        recorded_at: "2026-09-15T12:00:00Z", now: NOW
      )
    end

    blocking = entries
    blocking[1]["classification"] = "primary-flow-crash"
    blocking[1]["severity"] = "critical"
    blocking_record = build(entries_value: blocking)
    rejects("critical deferred blocker passes readiness") do
      IOSTemplate::ReleaseDisposition.release_ready!(blocking_record)
    end

    medium = entries
    medium[1]["severity"] = "medium"
    IOSTemplate::ReleaseDisposition.release_ready!(build(entries_value: medium))

    classified_blocker = entries
    classified_blocker[1]["classification"] = "privacy"
    rejects("blocking deferred classification passes readiness") do
      IOSTemplate::ReleaseDisposition.release_ready!(build(entries_value: classified_blocker))
    end

    pretty = JSON.pretty_generate(value)
    rejects("noncanonical bytes") do
      IOSTemplate::ReleaseDisposition.validate!(
        record_bytes: pretty, contract_bytes: contract_bytes, phase_record_bytes: record,
        issue: ISSUE, base_sha: BASE, head_sha: HEAD,
        failure_record_bytes: {failure_reference.fetch("path") => failure_bytes}, now: NOW
      )
    end

    Dir.mktmpdir("release-disposition-producer-") do |repo|
      FileUtils.mkdir_p(File.join(repo, "Config/releases/sample-v1/phase-records"))
      File.binwrite(File.join(repo, "Config/releases/sample-v1/phase-records/record-0005.json"), record)
      File.binwrite(File.join(repo, "README.md"), "base\n")
      system("/usr/bin/git", "-C", repo, "init", "-q") or raise "git init failed"
      system("/usr/bin/git", "-C", repo, "config", "user.name", "Disposition Fixture") or raise "git config failed"
      system("/usr/bin/git", "-C", repo, "config", "user.email", "fixture@example.invalid") or raise "git config failed"
      system("/usr/bin/git", "-C", repo, "add", "Config", "README.md") or raise "git add failed"
      system("/usr/bin/git", "-C", repo, "commit", "-qm", "base") or raise "git commit failed"
      real_base = `git -C #{repo.shellescape} rev-parse HEAD`.strip
      File.binwrite(File.join(repo, "README.md"), "head\n")
      system("/usr/bin/git", "-C", repo, "add", "README.md") or raise "git add failed"
      system("/usr/bin/git", "-C", repo, "commit", "-qm", "head") or raise "git commit failed"
      real_head = `git -C #{repo.shellescape} rev-parse HEAD`.strip
      FileUtils.mkdir_p(File.join(repo, ".artifacts/issues/#{ISSUE}/#{real_head}"))
      real_contract = contract(record)
      real_contract["fetchedAt"] = (Time.now.utc - 5).iso8601
      real_contract_bytes = JSON.generate(IOSTemplate::ReleaseDisposition.canonical(real_contract))
      File.binwrite(File.join(repo, ".artifacts/issues/#{ISSUE}/issue-contract.json"), real_contract_bytes)
      input_path = File.join(repo, "disposition-input.json")
      File.binwrite(input_path, JSON.generate(
        "schemaVersion" => 1, "entries" => [], "executionDecisions" => [],
        "recordedAt" => Time.now.utc.iso8601
      ))
      result = IOSTemplate::ReleaseDispositionCLI.run(
        repo: File.realpath(repo), issue: ISSUE, base_sha: real_base, head_sha: real_head,
        input_path: input_path
      )
      assert("producer publishes canonical record") { result["status"] == "published" }
      published_path = File.join(repo, result.dig("reference", "path"))
      published_bytes = File.binread(published_path)
      published = JSON.parse(published_bytes)
      packet["baseSha"] = real_base
      packet["headSha"] = real_head
      packet["verifySha"] = real_head
      packet["issueContract"]["digest"] = IOSTemplate::ReleaseDisposition.digest(real_contract_bytes)
      packet["diff"] = {"path" => ".artifacts/issues/#{ISSUE}/#{real_head}/review.diff", "digest" => "sha256:#{"1" * 64}"}
      packet["verify"] = {"path" => ".artifacts/issues/#{ISSUE}/#{real_head}/verify.json", "digest" => "sha256:#{"2" * 64}"}
      packet["releaseDisposition"] = published
      packet["releaseDispositionFile"] = result.fetch("reference")
      validated_consumer = IOSTemplate::ReviewContract.validate_release_disposition!(
        packet: packet, contract: real_contract, issue: ISSUE, base_sha: real_base, head_sha: real_head,
        contract_bytes: real_contract_bytes, disposition_bytes: published_bytes,
        failure_record_bytes: {}, repo: File.realpath(repo)
      )
      assert("review consumer validates the exact producer record") { validated_consumer == published }
      begin
        IOSTemplate::ReleaseDispositionCLI.run(
          repo: File.realpath(repo), issue: ISSUE, base_sha: real_base, head_sha: real_head,
          input_path: input_path
        )
      rescue IOSTemplate::ReleaseDispositionCLI::PublicationError
        # no-replace is mandatory
      else
        raise "expected producer no-replace rejection"
      end
    end

    puts "PASS: release disposition identity, categories, approvals, blockers and bounded failure decisions"
  end
end

ReleaseDispositionTest.run
RUBY
