#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
ruby -I"$repo_root/tools/lib" -rissue-contract -rminitest/autorun -rjson -ropen3 -rtmpdir -ryaml - "$repo_root" <<'RUBY'
REPO_ROOT = ARGV.shift

class VerificationContractTest < Minitest::Test
  def verification
    {
      "bundleIdentifier" => "com.example.TemplateApp",
      "unitTestIdentifier" => "TemplateAppTests/UnitSmokeTests/testUnit()",
      "cases" => [
        {"id" => "iphone-en", "testIdentifier" => "TemplateAppUITests/SmokeTests/testLaunch"},
        {"id" => "iphone-ja", "assertion" => {"kind" => "launch-succeeded"}},
        {"id" => "ipad-en", "testIdentifier" => "TemplateAppUITests/SmokeTests/testLaunch"},
        {"id" => "ipad-ja", "assertion" => {"kind" => "launch-succeeded"}}
      ],
      "acceptanceMappings" => [
        {"id" => "AC-1", "checks" => ["stage:build", "stage:unit-tests"]},
        {"id" => "AC-2", "checks" => ["case:iphone-ja", "visual:iphone-ja"]}
      ]
    }
  end

  def body(section = nil)
    <<~BODY + (section.nil? ? "" : "\n## Verification\n\n#{section}\n")
      ## Goal
      Generate exact application verification inputs.
      ## In scope
      - Verification contract generation.
      ## Out of scope
      - Application changes.
      ## Acceptance criteria
      - AC-1: Inputs are preserved.
      - AC-2: Each criterion has explicit evidence.
      ## Spec anchors
      - [Done](specs/acceptance.md#3-issue-definition-of-done)
      ## Dependencies
      None
      ## UI verification
      Not applicable
      ## External operations
      None
      ## User approvals
      None
    BODY
  end

  def parse(text)
    IOSTemplate::IssueContract.parse(text, issue: 42, repository: "yuto1201/iOS-Template", fetched_at: "2026-08-31T00:00:00Z").contract
  end

  def test_inline_and_fenced_json_generate_exact_ac_specific_configuration
    [JSON.generate(verification), "```json\n#{JSON.pretty_generate(verification)}\n```"].each do |section|
      contract = parse(body(section))
      assert_equal verification, contract["verification"]
      IOSTemplate::IssueContract.validate_snapshot!(contract, issue: 42, repository: "yuto1201/iOS-Template")
      assert_equal ["case:iphone-ja", "visual:iphone-ja"], contract.dig("verification", "acceptanceMappings", 1, "checks")
    end
  end

  def test_absent_and_github_empty_optional_answers_preserve_legacy_bytes
    expected = '{"acceptanceCriteria":[{"id":"AC-1","text":"Inputs are preserved."},{"id":"AC-2","text":"Each criterion has explicit evidence."}],"dependencies":[],"externalOperationDetailsDigest":"sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945","externalOperations":[],"fetchedAt":"2026-08-31T00:00:00Z","goal":"Generate exact application verification inputs.","issue":42,"repository":"yuto1201/iOS-Template","schemaVersion":1,"specAnchors":["specs/acceptance.md#3-issue-definition-of-done"]}'
    [nil, "_No response_", "Not applicable"].each do |section|
      assert_equal expected, IOSTemplate::IssueContract.canonical_json(parse(body(section)))
    end
  end

  def test_rejects_incomplete_or_ambiguous_configuration_before_claim
    mutations = {
      "missing bundle" => ->(v) { v.delete("bundleIdentifier") },
      "invalid bundle" => ->(v) { v["bundleIdentifier"] = "com.*" },
      "missing unit test" => ->(v) { v.delete("unitTestIdentifier") },
      "wildcard test" => ->(v) { v["unitTestIdentifier"] = "Tests/*" },
      "missing cases" => ->(v) { v.delete("cases") },
      "missing case" => ->(v) { v["cases"].pop },
      "case order" => ->(v) { v["cases"].reverse! },
      "duplicate case" => ->(v) { v["cases"][1] = v["cases"][0] },
      "two actions" => ->(v) { v["cases"][0]["assertion"] = {"kind" => "launch-succeeded"} },
      "missing action" => ->(v) { v["cases"][0].delete("testIdentifier") },
      "case unknown key" => ->(v) { v["cases"][0]["other"] = true },
      "case invalid test" => ->(v) { v["cases"][0]["testIdentifier"] = "Target/Class" },
      "assertion unknown key" => ->(v) { v["cases"][1]["assertion"]["other"] = true },
      "unsupported assertion" => ->(v) { v["cases"][1]["assertion"]["kind"] = "assume-passed" },
      "missing mappings" => ->(v) { v.delete("acceptanceMappings") },
      "missing AC" => ->(v) { v["acceptanceMappings"].pop },
      "wrong AC order" => ->(v) { v["acceptanceMappings"].reverse! },
      "unknown mapping key" => ->(v) { v["acceptanceMappings"][0]["other"] = true },
      "empty checks" => ->(v) { v["acceptanceMappings"][0]["checks"] = [] },
      "duplicate check" => ->(v) { v["acceptanceMappings"][0]["checks"] = ["stage:build", "stage:build"] },
      "check order" => ->(v) { v["acceptanceMappings"][0]["checks"].reverse! },
      "unknown check" => ->(v) { v["acceptanceMappings"][0]["checks"] = ["stage:all"] },
      "visual only" => ->(v) { v["acceptanceMappings"][0]["checks"] = ["visual:iphone-ja"] },
      "unknown root key" => ->(v) { v["defaults"] = {} }
    }
    mutations.each do |name, mutate|
      value = verification
      mutate.call(value)
      assert_raises(IOSTemplate::IssueContract::ValidationError, name) { parse(body(JSON.generate(value))) }
      # Snapshot consumers must reject the same malformed object independently.
      snapshot = parse(body)
      snapshot["verification"] = value
      assert_raises(IOSTemplate::IssueContract::ValidationError, "snapshot #{name}") do
        IOSTemplate::IssueContract.validate_snapshot!(snapshot, issue: 42, repository: "yuto1201/iOS-Template")
      end
    end
  end

  def test_rejects_null_nonobjects_broken_fences_duplicate_keys_and_duplicate_sections
    ["", "null", "[]", "{", "```json\n{}", "```yaml\n{}\n```", '{"cases":[],"cases":[]}'].each do |section|
      assert_raises(IOSTemplate::IssueContract::ValidationError, section.inspect) { parse(body(section)) }
    end
    duplicate = body(JSON.generate(verification)) + "\n## Verification\nNot applicable\n"
    assert_raises(IOSTemplate::IssueContract::ValidationError) { parse(duplicate) }
  end

  def test_fast_cannot_hide_four_ui_cases_behind_not_applicable_ui_text
    text = body(JSON.generate(verification)) + "\n## Delivery profile\n- Profile: fast\n- Reason: Incorrect classification.\n"
    assert_raises(IOSTemplate::IssueContract::ValidationError) { parse(text) }
  end

  def test_real_cli_validates_and_generates_the_same_verification
    Dir.mktmpdir("verification-contract-") do |directory|
      path = File.join(directory, "issue.md")
      File.write(path, body(JSON.generate(verification)))
      stdout, stderr, status = Open3.capture3("ruby", File.join(REPO_ROOT, "tools/lib/issue-contract.rb"), "--body", path, "--format", "contract", "--issue", "42", "--repo", "yuto1201/iOS-Template", "--fetched-at", "2026-08-31T00:00:00Z")
      assert status.success?, stderr
      assert_equal verification, JSON.parse(stdout)["verification"]
      _, stderr, status = Open3.capture3("bash", File.join(REPO_ROOT, "tools/validate-issue-body.sh"), path)
      assert status.success?, stderr
      File.write(path, body('{"cases":[]}'))
      _, _, status = Open3.capture3("bash", File.join(REPO_ROOT, "tools/validate-issue-body.sh"), path)
      refute status.success?, "validator accepted an incomplete verification object"
    end
  end

  def test_issue_form_examples_are_consumable_without_rewriting_the_schema
    %w[feature regression].each do |type|
      form = YAML.load_file(File.join(REPO_ROOT, ".github/ISSUE_TEMPLATE/#{type}.yml"))
      field = form.fetch("body").find { |entry| entry["id"] == "verification" }
      refute_nil field, "#{type} form has no Verification input"
      example = field.fetch("attributes").fetch("placeholder")
      assert_equal JSON.parse(example), parse(body(example)).fetch("verification")
    end
  end
end
RUBY
