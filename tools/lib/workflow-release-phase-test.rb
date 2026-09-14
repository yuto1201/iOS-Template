# frozen_string_literal: true

require "digest"
require "json"
require "tmpdir"
require_relative "workflow-release-phase"

module ReleasePhaseSelfTest
  module_function

  def assert(message)
    raise message unless yield
  end

  def rejects(message)
    begin
      yield
    rescue IOSTemplate::ReleasePhase::ValidationError
      return
    end
    raise "expected rejection: #{message}"
  end

  def completion(phase, authority:, actor:, reference:)
    {
      "event" => "phase-completed",
      "revision" => 1,
      "phase" => phase,
      "scope" => ["workflow"],
      "authority" => authority,
      "actor" => actor,
      "approvalReference" => reference,
      "reason" => "Phase #{phase} exit accepted.",
      "evidence" => ["issue:#{phase}"],
      "knownDefects" => [],
      "omittedTests" => [],
      "unverified" => [],
      "carryovers" => [],
      "recordedAt" => "2026-09-14T00:0#{phase}:00Z"
    }
  end

  def binding(record_bytes, release: "template-v1", revision: 1, phase: 4,
              scope: ["workflow"], work_kind: "implementation", route: "standard", reason: "Implement the next phase.")
    value = {
      "releaseIdentifier" => release,
      "revision" => revision,
      "phase" => phase,
      "scope" => scope,
      "workKind" => work_kind,
      "route" => route,
      "recordPath" => "Config/releases/template-v1/phase-records/record-0004.json",
      "recordDigest" => "sha256:#{Digest::SHA256.hexdigest(record_bytes)}",
      "reason" => reason
    }
    json = JSON.generate(IOSTemplate::ReleasePhase.canonical(value))
    {"acceptanceCriteria" => [{"id" => "AC-1", "text" => "Release-phase binding: #{json}"}]}
  end

  def change(classification:, from_revision: 1, to_revision: 1, reopen_from_phase: nil,
             authority: "delegated", actor: "codex", reference: "D-038")
    {
      "event" => "change-classified",
      "classification" => classification,
      "fromRevision" => from_revision,
      "toRevision" => to_revision,
      "fromScope" => ["workflow"],
      "toScope" => ["workflow"],
      "reopenFromPhase" => reopen_from_phase,
      "authority" => authority,
      "actor" => actor,
      "approvalReference" => reference,
      "reason" => "Classify the release change.",
      "changedBefore" => "Previous behavior.",
      "changedAfter" => "Changed behavior.",
      "affectedSpecifications" => ["specs/development-stages.md#153"],
      "affectedIssues" => [85],
      "invalidatedEvidence" => classification == "major" ? ["issue:2", "issue:3"] : [],
      "retainedEvidence" => ["issue:1"],
      "carryovers" => [],
      "recordedAt" => "2026-09-14T00:10:00Z"
    }
  end

  def run
    phase_one = IOSTemplate::ReleasePhase.create(
      release_identifier: "template-v1",
      revision: 1,
      scope: ["workflow"],
      goal: "Ship the phase workflow.",
      actor: "codex",
      reason: "Create the release unit.",
      recorded_at: "2026-09-14T00:00:00Z"
    )
    IOSTemplate::ReleasePhase.validate_record_bytes!(phase_one)

    phase_two = IOSTemplate::ReleasePhase.append(phase_one, completion(1, authority: "user", actor: "yuto1201", reference: "issue-1"))
    phase_three = IOSTemplate::ReleasePhase.append(phase_two, completion(2, authority: "delegated", actor: "codex", reference: "D-038"))
    phase_four = IOSTemplate::ReleasePhase.append(phase_three, completion(3, authority: "user", actor: "yuto1201", reference: "issue-3"))
    IOSTemplate::ReleasePhase.validate_record_bytes!(phase_four, previous_bytes: phase_three)

    gate = IOSTemplate::ReleasePhase.gate!(binding(phase_four), phase_four)
    assert("Phase 4 gate did not bind all prerequisite exits") { gate["status"] == "passed" && gate["requiredPriorPhases"] == [1, 2, 3] }

    rejects("another release approval") { IOSTemplate::ReleasePhase.gate!(binding(phase_four, release: "other"), phase_four) }
    rejects("stale revision approval") { IOSTemplate::ReleasePhase.gate!(binding(phase_four, revision: 2), phase_four) }
    rejects("another scope approval") { IOSTemplate::ReleasePhase.gate!(binding(phase_four, scope: ["other"]), phase_four) }
    tampered = binding(phase_four)
    text = tampered.fetch("acceptanceCriteria").first.fetch("text")
    tampered.fetch("acceptanceCriteria").first["text"] = text.sub(/sha256:[0-9a-f]{64}/, "sha256:#{"0" * 64}")
    rejects("record digest mismatch") { IOSTemplate::ReleasePhase.gate!(tampered, phase_four) }

    rejects("Phase 4 before the user-approved Phase 3 exit") do
      IOSTemplate::ReleasePhase.gate!(binding(phase_three), phase_three)
    end
    research = IOSTemplate::ReleasePhase.gate!(
      binding(phase_three, work_kind: "research", reason: "Read-only research may precede the implementation gate."), phase_three
    )
    assert("research was not distinguished from implementation") { research["status"] == "passed" && research["workKind"] == "research" }

    minor = IOSTemplate::ReleasePhase.append(phase_four, change(classification: "minor"))
    IOSTemplate::ReleasePhase.gate!(binding(minor, reason: "Delegated correction remains inside the accepted flow."), minor)

    major = IOSTemplate::ReleasePhase.append(
      phase_four,
      change(classification: "major", to_revision: 2, reopen_from_phase: 2,
             authority: "user", actor: "yuto1201", reference: "issue-85")
    )
    rejects("major change must invalidate dependent exits") do
      IOSTemplate::ReleasePhase.gate!(binding(major, revision: 2), major)
    end
    resume_gate = IOSTemplate::ReleasePhase.gate!(binding(major, revision: 2, phase: 2), major)
    assert("major change did not preserve the unaffected Phase 1 exit") { resume_gate["requiredPriorPhases"] == [1] }

    unclassified = IOSTemplate::ReleasePhase.append(phase_four, change(classification: "unclassified"))
    rejects("unclassified dependent implementation") { IOSTemplate::ReleasePhase.gate!(binding(unclassified), unclassified) }
    independent = IOSTemplate::ReleasePhase.gate!(
      binding(unclassified, phase: 5, work_kind: "independent", reason: "This documentation lane does not consume the changed output."),
      unclassified
    )
    assert("independent work did not remain available") { independent["workKind"] == "independent" }

    reuse_event = {
      "event" => "phase-reused",
      "revision" => 1,
      "route" => "emergency",
      "throughPhase" => 3,
      "scope" => ["workflow"],
      "foundations" => %w[purpose identity ui-direction data],
      "authority" => "user",
      "actor" => "yuto1201",
      "approvalReference" => "incident-1",
      "reason" => "Existing foundations remain applicable to this narrow urgent fix.",
      "recordedAt" => "2026-09-14T00:13:00Z"
    }
    reused = IOSTemplate::ReleasePhase.append(phase_one, reuse_event)
    IOSTemplate::ReleasePhase.gate!(binding(reused, route: "emergency", reason: "Use the recorded emergency reuse."), reused)
    rejects("implicit standard route over reused foundations") do
      IOSTemplate::ReleasePhase.gate!(binding(reused, route: "standard"), reused)
    end
    rejects("reuse route mismatch") do
      IOSTemplate::ReleasePhase.gate!(binding(reused, route: "existing-app"), reused)
    end

    legacy = IOSTemplate::ReleasePhase.gate!({"schemaVersion" => 1}, nil)
    assert("legacy Issue was implicitly migrated") { legacy == {"status" => "legacy-unbound"} }

    malformed = JSON.parse(phase_four)
    malformed.fetch("history").first["reason"] = "rewritten"
    rejects("noncanonical or rewritten record") do
      IOSTemplate::ReleasePhase.validate_record_bytes!(IOSTemplate::ReleasePhase.canonical_record(malformed), previous_bytes: phase_three)
    end

    Dir.mktmpdir("release-phase-selftest") do |directory|
      path = File.join(directory, "record.json")
      IOSTemplate::ReleasePhase.write_unique!(path, phase_one)
      rejects("producer overwrite") { IOSTemplate::ReleasePhase.write_unique!(path, phase_two) }
    end

    puts "PASS: versioned release phase records and partial reapproval gate"
  end
end

ReleasePhaseSelfTest.run if $PROGRAM_NAME == __FILE__
