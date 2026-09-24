#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby

source_repo=$(cd "$(dirname "$0")/../.." && pwd -P)
ruby -I"$source_repo/tools/lib" -rrepository-test-plan -rfileutils -rtmpdir -rjson <<'RUBY'
module Fixture
  module_function

  def git(repo, *args)
    IOSTemplate::RepositoryTestPlan.git!(repo, *args).strip
  end

  def manifest(tests: %w[tools/tests/test-alpha.sh tools/tests/test-beta.sh])
    {
      "schemaVersion" => 1,
      "headAllPaths" => [],
      "headAllPrefixes" => [],
      "domainRules" => [
        {"domain" => "repository", "paths" => ["Config/repository-tests.json", "tools/lib/repository-test-plan.rb", "tools/lib/run-repository-tests.rb", "tools/run-repository-tests.sh"], "prefixes" => []},
        {"domain" => "review", "paths" => ["tools/lib/review-contract.rb"], "prefixes" => ["docs/review/"]},
        {"domain" => "workflow", "paths" => ["tools/lib/workflow.rb"], "prefixes" => ["docs/workflow/"]}
      ],
      "tests" => tests.map do |path|
        {"path" => path, "domains" => path.end_with?("alpha.sh") ? %w[repository review] : ["workflow"]}
      end
    }
  end

  def contract(issue:, scope: "targeted")
    criteria = [
      {"id" => "AC-1", "text" => "UI-direction route: not-applicable; Scope: tests; Reason: no UI."},
      {"id" => "AC-2", "text" => "Repository-test scope: #{scope}; Reason: fixture policy."}
    ]
    JSON.generate({"schemaVersion"=>1, "issue"=>issue, "repository"=>"example/repo", "goal"=>"Plan tests",
      "specAnchors"=>["specs/test.md#plan"], "acceptanceCriteria"=>criteria, "dependencies"=>[],
      "externalOperations"=>[], "externalOperationDetailsDigest"=>"sha256:#{'0' * 64}",
      "fetchedAt"=>"2026-09-13T13:03:38Z", "deliveryStage"=>{"name"=>"harden", "timeBudgetMinutes"=>60, "reason"=>"fixture"},
      "deliveryProfile"=>{"name"=>"strict", "reason"=>"fixture"}})
  end
end

runner = IOSTemplate::RepositoryTestPlan
lint_manifest = {
  "schemaVersion" => 1,
  "headAllPaths" => [],
  "headAllPrefixes" => [],
  "domainRules" => [
    {"domain" => "appstore", "paths" => ["tools/appstore.rb"], "prefixes" => []},
    {"domain" => "ios-verification", "paths" => ["tools/ios.rb"], "prefixes" => []},
    {"domain" => "release-disposition", "paths" => ["tools/release.rb"], "prefixes" => []},
    {"domain" => "repository-testing", "paths" => ["tools/lib/repository-test-plan.rb", "tools/sample.sh"], "prefixes" => []},
    {"domain" => "specification", "paths" => ["docs/verification.md"], "prefixes" => []},
    {"domain" => "workflow-state", "paths" => ["tools/workflow.rb"], "prefixes" => []}
  ],
  "tests" => [
    {"path" => "tools/tests/test-alpha.sh", "domains" => ["repository-testing"]},
    {"path" => "tools/tests/test-appstore.sh", "domains" => ["appstore"]},
    {"path" => "tools/tests/test-ios.sh", "domains" => ["ios-verification"]},
    {"path" => "tools/tests/test-prerequisites.sh", "domains" => %w[release-disposition repository-lint workflow-state]},
    {"path" => "tools/tests/test-spec-state.sh", "domains" => %w[repository-lint specification]},
    {"path" => "tools/tests/test-workflow.sh", "domains" => ["workflow-state"]}
  ]
}
lint_tests = %w[tools/tests/test-prerequisites.sh tools/tests/test-spec-state.sh]
inventory = lint_manifest.fetch("tests").map { |entry| entry.fetch("path") }
runner.validate_manifest!(lint_manifest, inventory)
%w[tools/tests/test-alpha.sh tools/sample.sh].each do |shell_path|
  scope, reason, tests = runner.resolve(lint_manifest, "targeted", [shell_path])
  abort "shell change did not select only the repository test and both lints: #{shell_path}" unless
    scope == "targeted" && reason.include?("repository-lint") && tests == ["tools/tests/test-alpha.sh", *lint_tests]
end
scope, reason, tests = runner.resolve(lint_manifest, "targeted", ["tools/lib/repository-test-plan.rb"])
abort "non-shell plan changed" unless scope == "targeted" &&
  reason == "Changed paths resolve to repository-test domains: repository-testing." && tests == ["tools/tests/test-alpha.sh"]
begin
  runner.resolve(lint_manifest, "targeted", ["tools/sample.sh", "tools/uncovered.sh"])
  abort "uncovered shell path was accepted"
rescue IOSTemplate::RepositoryTestPlan::PlanError => error
  abort "uncovered shell path failed for the wrong reason" unless error.message.include?("no manifest coverage: tools/uncovered.sh")
end
missing_lints = Marshal.load(Marshal.dump(lint_manifest))
missing_lints.fetch("tests").reject! { |entry| lint_tests.include?(entry.fetch("path")) }
begin
  runner.resolve(missing_lints, "targeted", ["tools/sample.sh"])
  abort "shell change without lint entries was accepted"
rescue IOSTemplate::RepositoryTestPlan::PlanError => error
  abort "missing lints failed for the wrong reason" unless error.message.include?("repository-lint")
end
abort "targeted merge did not use its bounded scenario" unless
  runner.test_arguments("tools/tests/test-merge-issue.sh", "targeted") == ["scoped"]
abort "targeted premerge did not use its bounded scenario" unless
  runner.test_arguments("tools/tests/test-premerge-gate.sh", "targeted") == ["scoped"]
abort "targeted renderer did not use its bounded scenario" unless
  runner.test_arguments("tools/tests/test-render-pr-body.sh", "targeted") == ["scoped"]
abort "targeted workflow state did not use its bounded scenario" unless
  runner.test_arguments("tools/tests/test-workflow-state.sh", "targeted") == ["scoped"]
abort "targeted workflow E2E did not use its bounded scenario" unless
  runner.test_arguments("tools/tests/test-workflow-e2e.sh", "targeted") == ["scoped"]
abort "head-all unexpectedly narrowed a test" unless
  runner.test_arguments("tools/tests/test-premerge-gate.sh", "head-all") == [] &&
    runner.test_arguments("tools/tests/test-workflow-state.sh", "head-all") == [] &&
    runner.test_arguments("tools/tests/test-workflow-e2e.sh", "head-all") == []
abort "bootstrap full entrypoint changed" unless
  runner.test_arguments("tools/tests/test-app-bootstrap.sh", "targeted") == ["all"]
Dir.mktmpdir("repository-test-plan-") do |scratch|
  repo = File.join(scratch, "repo")
  FileUtils.mkdir_p(File.join(repo, "Config"))
  FileUtils.mkdir_p(File.join(repo, "tools/tests"))
  FileUtils.mkdir_p(File.join(repo, "tools/lib"))
  Fixture.git(repo, "init", "-q", "-b", "main")
  Fixture.git(repo, "config", "user.name", "Fixture")
  Fixture.git(repo, "config", "user.email", "fixture@example.invalid")
  File.write(File.join(repo, "tools/tests/test-alpha.sh"), "exit 0\n")
  File.write(File.join(repo, "tools/tests/test-beta.sh"), "exit 0\n")
  File.write(File.join(repo, "tools/lib/review-contract.rb"), "BASE = true\n")
  File.write(File.join(repo, "tools/lib/workflow.rb"), "BASE = true\n")
  File.write(File.join(repo, "tools/lib/repository-test-plan.rb"), "PLAN = true\n")
  File.write(File.join(repo, "tools/lib/run-repository-tests.rb"), "RUNNER = true\n")
  File.write(File.join(repo, "tools/run-repository-tests.sh"), "exit 0\n")
  File.write(File.join(repo, "Config/repository-tests.json"), JSON.generate(Fixture.manifest))
  Fixture.git(repo, "add", ".")
  Fixture.git(repo, "commit", "-qm", "base")
  base = Fixture.git(repo, "rev-parse", "HEAD")

  File.write(File.join(repo, "tools/lib/review-contract.rb"), "HEAD = true\n")
  Fixture.git(repo, "add", ".")
  Fixture.git(repo, "commit", "-qm", "review change")
  head = Fixture.git(repo, "rev-parse", "HEAD")
  contract = Fixture.contract(issue: 42)
  mappings = {"AC-1"=>["tools/tests/test-alpha.sh"], "AC-2"=>["tools/tests/test-alpha.sh"]}
  plan = runner.build(repo: repo, issue: 42, base_sha: base, head_sha: head, contract_bytes: contract, mappings: mappings)
  abort "single domain did not resolve targeted" unless plan.values_at("requestedScope", "resolvedScope", "testPaths") == ["targeted", "targeted", ["tools/tests/test-alpha.sh"]]
  runner.validate!(plan, repo: repo, issue: 42, base_sha: base, head_sha: head, contract_bytes: contract)

  File.write(File.join(repo, "tools/lib/workflow.rb"), "HEAD = true\n")
  Fixture.git(repo, "add", ".")
  Fixture.git(repo, "commit", "-qm", "multi-domain change")
  multi_domain_head = Fixture.git(repo, "rev-parse", "HEAD")
  all_mapping = {"AC-1"=>%w[tools/tests/test-alpha.sh tools/tests/test-beta.sh], "AC-2"=>["tools/tests/test-beta.sh"]}
  multi_domain = runner.build(repo: repo, issue: 42, base_sha: base, head_sha: multi_domain_head,
    contract_bytes: contract, mappings: all_mapping)
  abort "multiple domains did not remain targeted" unless multi_domain["requestedScope"] == "targeted" &&
    multi_domain["resolvedScope"] == "targeted" &&
    multi_domain["testPaths"] == %w[tools/tests/test-alpha.sh tools/tests/test-beta.sh] &&
    multi_domain["resolutionReason"].include?("review,workflow")

  altered = Marshal.load(Marshal.dump(plan))
  altered["headSha"] = base
  begin
    runner.validate!(altered, repo: repo, issue: 42, base_sha: base, head_sha: head, contract_bytes: contract)
    abort "tampered plan was accepted"
  rescue IOSTemplate::RepositoryTestPlan::PlanError
  end

  File.write(File.join(repo, "unmatched.txt"), "broad\n")
  Fixture.git(repo, "add", ".")
  Fixture.git(repo, "commit", "-qm", "unmatched")
  unmatched_head = Fixture.git(repo, "rev-parse", "HEAD")
  begin
    runner.build(repo: repo, issue: 42, base_sha: multi_domain_head, head_sha: unmatched_head,
      contract_bytes: contract, mappings: all_mapping)
    abort "unmatched path triggered repository tests"
  rescue IOSTemplate::RepositoryTestPlan::PlanError => error
    abort "unmatched path failed for an unexpected reason" unless error.message.include?("no manifest coverage")
  end

  File.write(File.join(repo, "tools/tests/test-alpha.sh"), "echo changed\n")
  Fixture.git(repo, "add", ".")
  Fixture.git(repo, "commit", "-qm", "inventory infrastructure")
  broad_head = Fixture.git(repo, "rev-parse", "HEAD")
  begin
    runner.build(repo: repo, issue: 42, base_sha: unmatched_head, head_sha: broad_head,
      contract_bytes: contract, mappings: mappings)
    abort "test change without repository-lint entries was accepted"
  rescue IOSTemplate::RepositoryTestPlan::PlanError => error
    abort "missing lint entries failed for the wrong reason" unless error.message.include?("repository-lint")
  end

  valid_manifest_change = Fixture.manifest
  valid_manifest_change.fetch("domainRules").first.fetch("prefixes") << "docs/review-notes/"
  valid_manifest_change.fetch("domainRules").first.fetch("prefixes").sort!
  File.write(File.join(repo, "Config/repository-tests.json"), JSON.generate(valid_manifest_change))
  Fixture.git(repo, "add", ".")
  Fixture.git(repo, "commit", "-qm", "valid manifest change")
  manifest_head = Fixture.git(repo, "rev-parse", "HEAD")
  manifest_broad = runner.build(repo: repo, issue: 42, base_sha: broad_head, head_sha: manifest_head,
    contract_bytes: contract, mappings: mappings)
  abort "manifest change did not remain targeted" unless manifest_broad["resolvedScope"] == "targeted" &&
    manifest_broad["testPaths"] == ["tools/tests/test-alpha.sh"] &&
    manifest_broad["resolutionReason"].include?("repository")

  File.write(File.join(repo, "tools/lib/run-repository-tests.rb"), "RUNNER = :changed\n")
  Fixture.git(repo, "add", ".")
  Fixture.git(repo, "commit", "-qm", "runner change")
  runner_head = Fixture.git(repo, "rev-parse", "HEAD")
  runner_broad = runner.build(repo: repo, issue: 42, base_sha: manifest_head, head_sha: runner_head,
    contract_bytes: contract, mappings: mappings)
  abort "runner change did not remain targeted" unless runner_broad["resolvedScope"] == "targeted" &&
    runner_broad["testPaths"] == ["tools/tests/test-alpha.sh"] &&
    runner_broad["resolutionReason"].include?("repository")

  head_all_contract = Fixture.contract(issue: 42, scope: "head-all")
  explicit_full = runner.build(repo: repo, issue: 42, base_sha: manifest_head, head_sha: runner_head,
    contract_bytes: head_all_contract, mappings: all_mapping)
  abort "explicit head-all did not select the inventory" unless explicit_full["resolvedScope"] == "head-all" &&
    explicit_full["testPaths"] == %w[tools/tests/test-alpha.sh tools/tests/test-beta.sh]

  base_head_contract = Fixture.contract(issue: 42, scope: "base-and-head")
  comparison = runner.build(repo: repo, issue: 42, base_sha: unmatched_head, head_sha: broad_head, contract_bytes: base_head_contract, mappings: all_mapping)
  abort "explicit comparison did not remain base-and-head" unless comparison["resolvedScope"] == "base-and-head"

  begin
    runner.build(repo: repo, issue: 42, base_sha: multi_domain_head, head_sha: unmatched_head, contract_bytes: contract,
      mappings: {"AC-1"=>["tools/tests/test-alpha.sh"], "AC-2"=>["tools/tests/test-alpha.sh"]})
    abort "incomplete mapping union was accepted"
  rescue IOSTemplate::RepositoryTestPlan::PlanError
  end

  empty_domain_manifest = Fixture.manifest
  empty_domain_manifest.fetch("domainRules").first["paths"] = []
  empty_domain_manifest.fetch("domainRules").first["prefixes"] = []
  begin
    runner.validate_manifest!(empty_domain_manifest, %w[tools/tests/test-alpha.sh tools/tests/test-beta.sh],
      tracked_paths: runner.tracked_paths(repo, broad_head))
    abort "manifest domain with empty coverage was accepted"
  rescue IOSTemplate::RepositoryTestPlan::PlanError => error
    abort "empty domain failed for an unexpected reason" unless error.message.include?("domain coverage is empty")
  end

  File.write(File.join(repo, "Config/repository-tests.json"), JSON.generate(Fixture.manifest(tests: ["tools/tests/test-alpha.sh"])))
  Fixture.git(repo, "add", ".")
  Fixture.git(repo, "commit", "-qm", "missing manifest test")
  invalid_head = Fixture.git(repo, "rev-parse", "HEAD")
  begin
    runner.build(repo: repo, issue: 42, base_sha: broad_head, head_sha: invalid_head, contract_bytes: contract, mappings: mappings)
    abort "manifest missing a tracked test was accepted"
  rescue IOSTemplate::RepositoryTestPlan::PlanError
  end

  invalid_manifest = Fixture.manifest
  invalid_manifest["headAllPaths"] = ["tools/lib/repository-test-plan.rb"]
  begin
    runner.validate_manifest!(invalid_manifest, %w[tools/tests/test-alpha.sh tools/tests/test-beta.sh],
      tracked_paths: runner.tracked_paths(repo, invalid_head))
    abort "automatic head-all path was accepted"
  rescue IOSTemplate::RepositoryTestPlan::PlanError => error
    abort "automatic head-all failed for an unexpected reason" unless error.message.include?("automatic head-all")
  end
end

puts "PASS: repository-test plans are diff-derived, scope-bounded, AC-mapped, and tamper-evident"
RUBY

SOURCE_REPO="$source_repo" ruby -I"$source_repo/tools/lib" -rfileutils -rtmpdir -rjson -ropen3 -rtime -rdigest -rissue-contract <<'RUBY'
source = ENV.fetch("SOURCE_REPO")
Dir.mktmpdir("repository-test-plan-e2e-") do |scratch|
  scratch = File.realpath(scratch)
  repo = File.join(scratch, "repo")
  FileUtils.mkdir_p([File.join(repo, "tools/lib"), File.join(repo, "tools/tests"),
    File.join(repo, "Config"), File.join(repo, ".artifacts/issues/82")])
  repo = File.realpath(repo)
  git = lambda do |*arguments|
    output, status = Open3.capture2e("/usr/bin/git", "-C", repo, *arguments)
    abort "fixture Git failed: #{arguments.join(' ')}: #{output}" unless status.success?
    output.strip
  end
  git.call("init", "-q", "-b", "main")
  git.call("config", "user.name", "Fixture")
  git.call("config", "user.email", "fixture@example.invalid")
  File.write(File.join(repo, ".gitignore"), "/.artifacts\n")
  %w[run-repository-tests.sh prepare-review-packet.sh validate-review-result.sh cross-model-review.sh].each do |name|
    FileUtils.cp(File.join(source, "tools", name), File.join(repo, "tools", name))
  end
  Dir[File.join(source, "tools/lib/*.rb")].each { |path| FileUtils.cp(path, File.join(repo, "tools/lib")) }
  File.write(File.join(repo, "tools/tests/test-alpha.sh"), "#!/bin/bash\nexit 0\n")
  File.write(File.join(repo, "tools/tests/test-beta.sh"), "#!/bin/bash\nexit 0\n")
  FileUtils.chmod(0o755, Dir[File.join(repo, "tools/*.sh")] + Dir[File.join(repo, "tools/tests/*.sh")])
  File.write(File.join(repo, "tools/lib/workflow.rb"), "WORKFLOW = :base\n")
  File.write(File.join(repo, "tools/lib/review.rb"), "REVIEW = :base\n")
  manifest = {
    "schemaVersion"=>1,
    "headAllPaths"=>[],
    "headAllPrefixes"=>[],
    "domainRules"=>[
      {"domain"=>"review", "paths"=>["tools/lib/review.rb"], "prefixes"=>[]},
      {"domain"=>"workflow", "paths"=>["tools/lib/workflow.rb"], "prefixes"=>[]}
    ],
    "tests"=>[
      {"path"=>"tools/tests/test-alpha.sh", "domains"=>["workflow"]},
      {"path"=>"tools/tests/test-beta.sh", "domains"=>["review"]}
    ]
  }
  File.write(File.join(repo, "Config/repository-tests.json"), JSON.generate(manifest))
  git.call("add", ".")
  git.call("commit", "-qm", "base")
  base = git.call("rev-parse", "HEAD")
  File.write(File.join(repo, "tools/lib/workflow.rb"), "WORKFLOW = :head\n")
  git.call("add", "tools/lib/workflow.rb")
  git.call("commit", "-qm", "targeted workflow change")
  head = git.call("rev-parse", "HEAD")

  criteria = [
    {"id"=>"AC-1", "text"=>"UI-direction route: not-applicable; Scope: plan fixture; Reason: no UI."},
    {"id"=>"AC-2", "text"=>"Repository-test scope: targeted; Reason: one workflow domain."}
  ]
  contract = {"schemaVersion"=>1, "issue"=>82, "repository"=>"example/repo", "goal"=>"Plan execution",
    "specAnchors"=>["specs/test.md#plan"], "acceptanceCriteria"=>criteria, "dependencies"=>[],
    "externalOperations"=>[], "externalOperationDetailsDigest"=>"sha256:#{'0' * 64}",
    "fetchedAt"=>"2026-09-13T13:03:38Z",
    "deliveryStage"=>{"name"=>"harden", "timeBudgetMinutes"=>60, "reason"=>"fixture"},
    "deliveryProfile"=>{"name"=>"strict", "reason"=>"fixture"}}
  issue_root = File.join(repo, ".artifacts/issues/82")
  head_root = File.join(issue_root, head)
  FileUtils.mkdir_p(head_root)
  contract_bytes = IOSTemplate::IssueContract.canonical_json(contract)
  File.binwrite(File.join(issue_root, "issue-contract.json"), contract_bytes)
  command = [File.join(repo, "tools/run-repository-tests.sh"), "--issue", "82", "--expected-base", base,
    "--map", "AC-1=tools/tests/test-alpha.sh", "--map", "AC-2=tools/tests/test-alpha.sh"]
  output, error, status = Open3.capture3(*command, chdir: repo)
  abort "planned runner failed: #{error}" unless status.success?
  abort "targeted execution limits were not reported" unless error.include?('"childTimeoutSeconds":300') &&
    error.include?('"suiteTimeoutSeconds":900')
  abort "targeted completion summary was not reported" unless error.include?("repository test execution completed:") &&
    error.include?('"status":"passed"') && error.match?(/"elapsedSeconds":[0-9]/) &&
    error.include?('"unexecutedTests":[]')
  receipt = JSON.parse(output)
  plan_path = File.join(head_root, "repository-test-plan.json")
  record_path = File.join(head_root, "repository-tests.json")
  plan_bytes = File.binread(plan_path)
  plan = JSON.parse(plan_bytes)
  record = JSON.parse(File.binread(record_path))
  abort "runner did not select one targeted test" unless plan.values_at("resolvedScope", "testPaths") == ["targeted", ["tools/tests/test-alpha.sh"]]
  abort "schema v3 record differs from plan" unless record.values_at("schemaVersion", "scope") == [3, "targeted"] &&
    record.fetch("tests").map { |entry| entry.fetch("path") } == plan.fetch("testPaths") && receipt.fetch("total") == 1
  abort "targeted child timeout differs" unless record.fetch("tests").all? { |entry| entry.fetch("timeoutSeconds") == 300 }

  contract_digest = "sha256:#{Digest::SHA256.hexdigest(contract_bytes)}"
  state = {"schemaVersion"=>1, "issue"=>82, "repository"=>"example/repo",
    "branch"=>"codex/82-plan", "worktree"=>".worktrees/82-plan", "baseSha"=>base,
    "primaryImplementer"=>"codex", "issueContract"=>{"path"=>".artifacts/issues/82/issue-contract.json", "digest"=>contract_digest},
    "state"=>"verify-passed", "previousState"=>"in-progress", "resumeState"=>nil,
    "executor"=>"codex", "headSha"=>head, "from"=>"in-progress", "to"=>"verify-passed",
    "transitionedAt"=>Time.now.utc.iso8601(6)}
  File.binwrite(File.join(issue_root, "state.json"), JSON.generate(IOSTemplate::IssueContract.canonical(state)))
  verify = {"schemaVersion"=>1, "status"=>"passed", "changeClassification"=>"workflow-only",
    "reason"=>"Repository tests passed.", "issue"=>82, "baseSha"=>base, "headSha"=>head,
    "issueContract"=>{"path"=>".artifacts/issues/82/issue-contract.json", "digest"=>contract_digest},
    "matrixFile"=>nil, "matrixDigest"=>nil, "executionRoute"=>"repository-tests", "xcode"=>nil,
    "build"=>{"status"=>"not-applicable", "scheme"=>nil, "warningsAdded"=>nil, "project"=>nil, "sourceTree"=>nil},
    "tests"=>{"status"=>"not-applicable", "passed"=>nil, "failed"=>nil, "skipped"=>nil}, "cases"=>[],
    "visualEvaluation"=>{"status"=>"not-applicable", "findings"=>[]},
    "acceptanceEvidence"=>criteria.map { |criterion| {"id"=>criterion.fetch("id"), "status"=>"passed", "evidence"=>["repository-tests.json"]} },
    "completedAt"=>Time.now.utc.iso8601(6)}
  File.binwrite(File.join(head_root, "verify.json"), JSON.generate(verify))
  _, error, status = Open3.capture3(File.join(repo, "tools/prepare-review-packet.sh"), "--primary", "codex",
    "--issue", "82", "--base-sha", base, "--head-sha", head, chdir: repo)
  abort "planned packet failed: #{error}" unless status.success?
  packet = JSON.parse(File.binread(File.join(head_root, "review-packet.json")))
  abort "packet omitted planned closure" unless packet.fetch("repositoryTestPlan") == plan &&
    packet.fetch("repositoryTestPlanFile").fetch("digest") == "sha256:#{Digest::SHA256.hexdigest(plan_bytes)}"
  _, error, status = Open3.capture3(File.join(repo, "tools/validate-review-result.sh"), "--primary", "codex",
    "--packet", ".artifacts/issues/82/#{head}/review-packet.json", chdir: repo)
  abort "planned packet preflight failed: #{error}" unless status.success?
  packet_path = File.join(head_root, "review-packet.json")
  packet_bytes = File.binread(packet_path)
  reviewed_at = Time.now.utc.iso8601(6)
  review_result = {"schemaVersion"=>2, "issue"=>82, "reviewerModel"=>"claude", "baseSha"=>base,
    "headSha"=>head, "verifySha"=>head, "issueContractDigest"=>contract_digest,
    "reviewPacketDigest"=>"sha256:#{Digest::SHA256.hexdigest(packet_bytes)}", "verdict"=>"approved", "findings"=>[],
    "acceptanceAssessment"=>criteria.each_with_index.map { |criterion, index|
      {"id"=>criterion.fetch("id"), "status"=>"supported", "evidence"=>["repository-tests.json#acceptanceEvidence/#{index}"]}
    }, "reviewedAt"=>reviewed_at}
  result_path = File.join(scratch, "review-result.json")
  File.binwrite(result_path, JSON.generate(review_result))
  _, error, status = Open3.capture3("/usr/bin/ruby", File.join(repo, "tools/lib/publish-review-result.rb"),
    repo, "82", head, result_path, packet_path, "codex", reviewed_at, Time.now.utc.iso8601(6))
  abort "planned result publication failed: #{error}" unless status.success?
  abort "planned publication omitted review receipt" unless File.file?(File.join(head_root, "review.json")) &&
    File.file?(File.join(head_root, "review-receipt.json"))
  File.binwrite(plan_path, plan_bytes + "\n")
  _, _, status = Open3.capture3(File.join(repo, "tools/validate-review-result.sh"), "--primary", "codex",
    "--packet", ".artifacts/issues/82/#{head}/review-packet.json", chdir: repo)
  abort "planned packet accepted changed plan bytes" if status.success?
end
puts "PASS: targeted plans drive schema v3 execution and remain sealed through packet validation"
RUBY
