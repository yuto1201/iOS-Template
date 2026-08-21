#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tools/lib/xcode.sh
source "$script_dir/lib/xcode.sh"

TRUSTED_GIT="/usr/bin/git"

run_git() {
  run_scrubbed GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=0 GIT_NO_REPLACE_OBJECTS=1 "$TRUSTED_GIT" "$@"
}

json_tool() {
  PATH=/bin /usr/bin/ruby --disable-gems -rjson -rdigest -rtime - "$@" <<'RUBY'
def abort_with(message)
  warn message
  exit 1
end

def exact_keys!(object, expected, label)
  abort_with("#{label} must be an object") unless object.is_a?(Hash)
  actual = object.keys.sort
  wanted = expected.sort
  abort_with("#{label} has missing or unknown keys") unless actual == wanted
end

def nonempty_string!(value, label)
  abort_with("#{label} must be a non-empty string") unless value.is_a?(String) && !value.strip.empty?
  value
end

def integer!(value, label, minimum = nil)
  abort_with("#{label} must be an integer") unless value.is_a?(Integer)
  abort_with("#{label} is below its minimum") if minimum && value < minimum
  value
end

def read_bound_file(root, relative, label)
  abort_with("#{label} must be canonical and relative") if relative.empty? || relative.start_with?("/")
  parts = relative.split("/", -1)
  abort_with("#{label} must be lexically contained") if parts.any? { |part| part.empty? || part == "." || part == ".." }
  current = root
  parts.each_with_index do |part, index|
    current = File.join(current, part)
    stat = File.lstat(current)
    abort_with("#{label} contains a symbolic link") if stat.symlink?
    if index == parts.length - 1
      abort_with("#{label} must be a regular single-link file") unless stat.file? && stat.nlink == 1
    else
      abort_with("#{label} has a non-directory ancestor") unless stat.directory?
    end
  rescue Errno::ENOENT, Errno::ENOTDIR
    abort_with("#{label} is unavailable")
  end
  File.binread(current)
end

def parse_json(bytes, label)
  JSON.parse(bytes)
rescue JSON::ParserError
  abort_with("#{label} is not valid JSON")
end

def digest(bytes)
  "sha256:#{Digest::SHA256.hexdigest(bytes)}"
end

def mkdir_p(path)
  expanded = File.expand_path(path)
  current = File::SEPARATOR
  expanded.split(File::SEPARATOR).reject(&:empty?).each do |component|
    current = File.join(current, component)
    begin
      Dir.mkdir(current, 0o700)
    rescue Errno::EEXIST
      abort_with("output ancestor is not a directory") unless File.directory?(current) && !File.symlink?(current)
    end
  end
end

def atomic_write(path, bytes)
  mkdir_p(File.dirname(path))
  temporary = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{rand(1_000_000)}")
  File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(bytes)
    file.flush
    file.fsync
  end
  File.link(temporary, path)
  directory = File.open(File.dirname(path), File::RDONLY)
  directory.fsync
  directory.close
  File.unlink(temporary)
  temporary = nil
ensure
  File.unlink(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
end

EXPECTED_CASES = [
  ["iphone-en", "iPhone", "en_US", "en"],
  ["iphone-ja", "iPhone", "ja_JP", "ja"],
  ["ipad-en", "iPad", "en_US", "en"],
  ["ipad-ja", "iPad", "ja_JP", "ja"]
].freeze

def validate_contract!(document, issue)
  base_keys = %w[acceptanceCriteria dependencies externalOperations fetchedAt goal issue repository schemaVersion specAnchors]
  exact_keys!(document, base_keys + ["verification"], "issue contract")
  abort_with("issue contract schemaVersion must be 1") unless document["schemaVersion"] == 1
  abort_with("issue contract issue mismatch") unless document["issue"] == issue
  %w[repository goal fetchedAt].each { |key| nonempty_string!(document[key], "issue contract #{key}") }
  abort_with("issue contract specAnchors must be non-empty") unless document["specAnchors"].is_a?(Array) && !document["specAnchors"].empty? && document["specAnchors"].all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
  abort_with("issue contract dependencies must be an array") unless document["dependencies"].is_a?(Array)
  abort_with("issue contract externalOperations must be an array") unless document["externalOperations"].is_a?(Array)
  criteria = document["acceptanceCriteria"]
  abort_with("issue contract acceptanceCriteria must be non-empty") unless criteria.is_a?(Array) && !criteria.empty?
  acceptance_ids = criteria.each_with_index.map do |criterion, index|
    exact_keys!(criterion, %w[id text], "issue contract acceptanceCriteria[#{index}]")
    id = nonempty_string!(criterion["id"], "acceptance ID")
    abort_with("issue contract acceptance IDs must be exact and ordered") unless id == "AC-#{index + 1}"
    nonempty_string!(criterion["text"], "acceptance text")
    id
  end

  verification = document["verification"]
  exact_keys!(verification, %w[acceptanceMappings bundleIdentifier cases], "verification")
  bundle = nonempty_string!(verification["bundleIdentifier"], "verification bundleIdentifier")
  abort_with("verification bundleIdentifier is invalid") unless bundle.match?(/\A[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+\z/)
  cases = verification["cases"]
  abort_with("verification cases must contain the exact four ordered case IDs") unless cases.is_a?(Array) && cases.length == 4
  normalized = cases.each_with_index.map do |entry, index|
    abort_with("verification case must be an object") unless entry.is_a?(Hash)
    id = entry["id"]
    abort_with("verification cases must contain the exact four ordered case IDs") unless id == EXPECTED_CASES[index][0]
    if entry.keys.sort == %w[id testIdentifier]
      identifier = nonempty_string!(entry["testIdentifier"], "verification testIdentifier")
      abort_with("verification testIdentifier must be Target/Class/testMethod") unless identifier.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\/[A-Za-z_][A-Za-z0-9_.-]*\/[A-Za-z_][A-Za-z0-9_.-]*\z/)
      {"id" => id, "action" => "testIdentifier", "value" => identifier}
    elsif entry.keys.sort == %w[assertion id]
      assertion = entry["assertion"]
      exact_keys!(assertion, ["kind"], "verification assertion")
      abort_with("verification assertion kind is not supported") unless assertion["kind"] == "launch-succeeded"
      {"id" => id, "action" => "assertion", "value" => "launch-succeeded"}
    else
      abort_with("verification case must contain exactly one testIdentifier or assertion")
    end
  end
  allowed_checks = %w[stage:build stage:unit-tests case:iphone-en case:iphone-ja case:ipad-en case:ipad-ja visual:iphone-en visual:iphone-ja visual:ipad-en visual:ipad-ja]
  mappings = verification["acceptanceMappings"]
  abort_with("verification acceptanceMappings must map every AC exactly once") unless mappings.is_a?(Array) && mappings.length == acceptance_ids.length
  normalized_mappings = mappings.each_with_index.map do |mapping, index|
    exact_keys!(mapping, %w[checks id], "verification acceptanceMapping")
    abort_with("verification acceptanceMappings must follow exact AC order") unless mapping["id"] == acceptance_ids[index]
    checks = mapping["checks"]
    abort_with("verification acceptance mapping checks must be non-empty and unique") unless checks.is_a?(Array) && !checks.empty? && checks.all? { |entry| entry.is_a?(String) } && checks.uniq.length == checks.length
    abort_with("verification acceptance mapping contains an unknown check") unless checks.all? { |entry| allowed_checks.include?(entry) }
    abort_with("verification acceptance mapping checks are out of order") unless checks == checks.sort_by { |entry| allowed_checks.index(entry) }
    abort_with("verification acceptance mapping needs an execution check") unless checks.any? { |entry| entry.start_with?("stage:") || entry.start_with?("case:") }
    {"id" => mapping["id"], "checks" => checks}
  end
  [bundle, acceptance_ids, normalized, normalized_mappings]
end

action = ARGV.shift
case action
when "verify-xcode"
  config = JSON.parse(File.read(ARGV.fetch(0)))
  actual = {"path" => ARGV.fetch(1), "version" => ARGV.fetch(2), "build" => ARGV.fetch(3)}
  abort_with("resolved Xcode does not match the frozen matrix") unless config.fetch("xcode") == actual
when "config-value"
  config = JSON.parse(File.read(ARGV.fetch(0)))
  path = ARGV.fetch(1).split(".")
  value = path.reduce(config) { |memo, component| component.match?(/\A\d+\z/) ? memo.fetch(component.to_i) : memo.fetch(component) }
  puts value
when "receipt"
  receipt = JSON.parse(ARGV.fetch(0))
  exact_keys!(receipt, %w[configPath lockToken workspaceRoot], "runner receipt")
  %w[configPath lockToken workspaceRoot].each { |key| nonempty_string!(receipt[key], "runner receipt #{key}") }
  puts [receipt["configPath"], receipt["workspaceRoot"], receipt["lockToken"]].join("\t")
when "test-summary"
  summary_path, expected_kind, expected_udid = ARGV
  summary = JSON.parse(File.read(summary_path))
  passed = integer!(summary["passedTests"], "passedTests", 0)
  failed = integer!(summary["failedTests"], "failedTests", 0)
  skipped = integer!(summary["skippedTests"], "skippedTests", 0)
  total = integer!(summary["totalTestCount"], "totalTestCount", 0)
  expected_failures = integer!(summary["expectedFailures"], "expectedFailures", 0)
  abort_with("test result status is not Passed") unless summary["result"] == "Passed"
  abort_with("unit tests did not report exact totals") unless total == passed + failed + skipped
  expected_passed = expected_kind == "case" ? 1 : nil
  abort_with("tests failed, were skipped, or selected the wrong count") unless passed > 0 && failed == 0 && skipped == 0 && expected_failures == 0 && (expected_passed.nil? || passed == expected_passed)
  configuration = summary["devicesAndConfigurations"]
  abort_with("devicesAndConfigurations must be an object") unless configuration.is_a?(Hash)
  device = configuration["device"]
  abort_with("test result device is invalid") unless device.is_a?(Hash) && device["deviceId"] == expected_udid
  abort_with("device test totals mismatch") unless configuration["passedTests"] == passed && configuration["failedTests"] == failed && configuration["skippedTests"] == skipped && configuration["expectedFailures"] == expected_failures
  puts [passed, failed, skipped].join("\t")
when "diagnostics"
  diagnostics = JSON.parse(File.read(ARGV.fetch(0)))
  warning_count = integer!(diagnostics["warningCount"], "warningCount", 0)
  analyzer_count = integer!(diagnostics["analyzerWarningCount"], "analyzerWarningCount", 0)
  error_count = integer!(diagnostics["errorCount"], "errorCount", 0)
  abort_with("structured diagnostics status is not succeeded") unless diagnostics["status"] == "succeeded"
  %w[warnings analyzerWarnings errors].each do |key|
    abort_with("structured diagnostics #{key} must be empty") unless diagnostics[key].is_a?(Array) && diagnostics[key].empty?
  end
  abort_with("structured diagnostics contain warnings or errors") unless warning_count == 0 && analyzer_count == 0 && error_count == 0
when "simulator-booted"
  document = JSON.parse(File.read(ARGV.fetch(0)))
  udid = ARGV.fetch(1)
  devices = document["devices"]
  abort_with("simulator state output is invalid") unless devices.is_a?(Hash)
  matches = devices.values.flat_map { |entries| entries.is_a?(Array) ? entries : [] }.select { |entry| entry.is_a?(Hash) && entry["udid"] == udid }
  abort_with("simulator is not uniquely Booted") unless matches.length == 1 && matches[0]["state"] == "Booted"
when "draft"
  config_path, output, issue_text, base, head, scheme, derived, build_result, test_result, passed_text, failed_text, skipped_text = ARGV
  config = JSON.parse(File.read(config_path))
  cases = config.fetch("cases").map do |entry|
    mechanical = entry.fetch("action") == "testIdentifier" ? "test:#{entry.fetch("value")}" : "assertion:launch-succeeded"
    {"id" => entry.fetch("id"), "status" => "passed", "screenshot" => "#{entry.fetch("id")}/screenshot.png", "mechanicalCheck" => mechanical}
  end
  execution_mappings = config.fetch("acceptanceMappings").map do |mapping|
    {"id" => mapping.fetch("id"), "evidence" => mapping.fetch("checks").reject { |check| check.start_with?("visual:") }}
  end
  draft = {
    "schemaVersion" => 1, "status" => "awaiting-visual-review", "issue" => Integer(issue_text, 10),
    "baseSha" => base, "headSha" => head,
    "issueContract" => {"path" => config.fetch("contractPath"), "digest" => config.fetch("contractDigest")},
    "matrixFile" => config.fetch("matrixPath"), "matrixDigest" => config.fetch("matrixDigest"),
    "executionRoute" => "xcodebuild-simctl", "xcode" => config.fetch("xcode"),
    "build" => {"status" => "passed", "scheme" => scheme, "warningsAdded" => 0},
    "tests" => {"status" => "passed", "passed" => Integer(passed_text, 10), "failed" => Integer(failed_text, 10), "skipped" => Integer(skipped_text, 10)},
    "cases" => cases,
    "acceptanceEvidence" => execution_mappings,
    "workspaceArtifacts" => {"derivedDataPath" => derived, "buildResultBundlePath" => build_result, "testResultBundlePath" => test_result},
    "executionCompletedAt" => Time.now.iso8601
  }
  atomic_write(output, JSON.pretty_generate(draft) + "\n")
when "failure"
  directory, issue_text, base, head, stage, error = ARGV
  mkdir_p(directory)
  document = {"schemaVersion" => 1, "status" => "failed", "issue" => Integer(issue_text, 10), "baseSha" => base, "headSha" => head, "stage" => stage, "error" => error, "recordedAt" => Time.now.iso8601}
  100.times do
    path = File.join(directory, "failure-#{Time.now.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}-#{rand(1_000_000)}.json")
    begin
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(document) + "\n") }
      puts path
      exit 0
    rescue Errno::EEXIST
    end
  end
  abort_with("could not create unique failure record")
when "final"
  root, draft_path, visual_path, output, issue_text, base, head = ARGV
  draft_bytes = read_bound_file(root, draft_path, "draft")
  visual_bytes = read_bound_file(root, visual_path, "visual result")
  draft = parse_json(draft_bytes, "draft")
  visual = parse_json(visual_bytes, "visual result")
  exact_keys!(draft, %w[acceptanceEvidence baseSha build cases executionCompletedAt executionRoute headSha issue issueContract matrixDigest matrixFile schemaVersion status tests workspaceArtifacts xcode], "draft")
  abort_with("draft status is not awaiting visual review") unless draft["schemaVersion"] == 1 && draft["status"] == "awaiting-visual-review"
  abort_with("draft identity does not match current Git range") unless draft["issue"] == Integer(issue_text, 10) && draft["baseSha"] == base && draft["headSha"] == head
  exact_keys!(draft["issueContract"], %w[digest path], "draft issueContract")
  nonempty_string!(draft["issueContract"]["path"], "draft issueContract path")
  abort_with("draft issueContract digest is invalid") unless draft["issueContract"]["digest"].is_a?(String) && draft["issueContract"]["digest"].match?(/\Asha256:[0-9a-f]{64}\z/)
  contract_bytes = read_bound_file(root, draft["issueContract"]["path"], "issue contract")
  abort_with("draft issueContract digest no longer matches canonical bytes") unless draft["issueContract"]["digest"] == digest(contract_bytes)
  contract = parse_json(contract_bytes, "issue contract")
  _bundle, contract_ids, contract_cases, contract_mappings = validate_contract!(contract, Integer(issue_text, 10))
  nonempty_string!(draft["matrixFile"], "draft matrixFile")
  abort_with("draft matrixDigest is invalid") unless draft["matrixDigest"].is_a?(String) && draft["matrixDigest"].match?(/\Asha256:[0-9a-f]{64}\z/)
  abort_with("draft executionRoute is invalid") unless draft["executionRoute"] == "xcodebuild-simctl"
  exact_keys!(draft["xcode"], %w[build path version], "draft xcode")
  draft["xcode"].each { |key, value| nonempty_string!(value, "draft xcode #{key}") }
  exact_keys!(draft["build"], %w[scheme status warningsAdded], "draft build")
  abort_with("draft build is not passed") unless draft["build"]["status"] == "passed" && draft["build"]["warningsAdded"] == 0
  nonempty_string!(draft["build"]["scheme"], "draft build scheme")
  exact_keys!(draft["tests"], %w[failed passed skipped status], "draft tests")
  passed = integer!(draft["tests"]["passed"], "draft tests passed", 1)
  failed = integer!(draft["tests"]["failed"], "draft tests failed", 0)
  skipped = integer!(draft["tests"]["skipped"], "draft tests skipped", 0)
  abort_with("draft tests are not passed") unless draft["tests"]["status"] == "passed" && passed > 0 && failed == 0 && skipped == 0
  exact_keys!(draft["workspaceArtifacts"], %w[buildResultBundlePath derivedDataPath testResultBundlePath], "draft workspaceArtifacts")
  worktree_name = File.basename(root).gsub(/[^A-Za-z0-9_.-]/, "-")
  workspace = "/tmp/ios-template-verify/#{worktree_name}-#{Digest::SHA256.hexdigest(root)}/issue-#{issue_text}/#{head}"
  expected_artifacts = {
    "derivedDataPath" => "#{workspace}/DerivedData",
    "buildResultBundlePath" => "#{workspace}/Build.xcresult",
    "testResultBundlePath" => "#{workspace}/Tests.xcresult"
  }
  abort_with("draft workspaceArtifacts do not match the current physical worktree") unless draft["workspaceArtifacts"] == expected_artifacts
  abort_with("draft must contain exact four cases") unless draft["cases"].is_a?(Array) && draft["cases"].length == 4
  screenshots = []
  draft["cases"].each_with_index do |entry, index|
    exact_keys!(entry, %w[id mechanicalCheck screenshot status], "draft case")
    expected_id = EXPECTED_CASES[index][0]
    abort_with("draft cases are not exact and ordered") unless entry["id"] == expected_id && entry["status"] == "passed"
    screenshot = nonempty_string!(entry["screenshot"], "draft screenshot")
    abort_with("draft screenshot is not case-owned") unless screenshot.start_with?("#{expected_id}/") && !screenshot.split("/").include?("..")
    abort_with("draft screenshots must be unique") if screenshots.include?(screenshot)
    screenshots << screenshot
    check = nonempty_string!(entry["mechanicalCheck"], "draft mechanicalCheck")
    contract_case = contract_cases.fetch(index)
    expected_check = contract_case.fetch("action") == "testIdentifier" ? "test:#{contract_case.fetch("value")}" : "assertion:launch-succeeded"
    abort_with("draft mechanicalCheck does not match the canonical contract") unless check == expected_check
  end
  acceptance = draft["acceptanceEvidence"]
  abort_with("draft acceptanceEvidence must be non-empty") unless acceptance.is_a?(Array) && !acceptance.empty?
  acceptance.each_with_index do |entry, index|
    exact_keys!(entry, %w[evidence id], "draft acceptanceEvidence")
    abort_with("draft acceptance IDs are not exact and ordered") unless entry["id"] == contract_ids[index]
    evidence = entry["evidence"]
    expected_execution = contract_mappings.fetch(index).fetch("checks").reject { |check| check.start_with?("visual:") }
    abort_with("draft acceptance evidence does not match the canonical contract") unless evidence == expected_execution
  end
  exact_keys!(visual, %w[cases draft findings headSha issue reviewedAt schemaVersion status], "visual result")
  abort_with("visual result identity mismatch") unless visual["schemaVersion"] == 1 && visual["issue"] == Integer(issue_text, 10) && visual["headSha"] == head
  exact_keys!(visual["draft"], %w[digest path], "visual result draft")
  abort_with("visual draft path mismatch") unless visual["draft"]["path"] == draft_path
  abort_with("visual draft digest mismatch") unless visual["draft"]["digest"] == digest(draft_bytes)
  abort_with("visual result is not approved") unless visual["status"] == "approved" && visual["findings"] == []
  draft_cases = draft["cases"]
  visual_cases = visual["cases"]
  abort_with("visual result must contain exact four cases") unless draft_cases.is_a?(Array) && visual_cases.is_a?(Array) && visual_cases.length == 4
  visual_cases.each_with_index do |entry, index|
    exact_keys!(entry, %w[findings id screenshot status], "visual result case")
    expected = draft_cases.fetch(index)
    abort_with("visual result cases mismatch") unless entry["id"] == expected["id"] && entry["screenshot"] == expected["screenshot"]
    abort_with("visual result case is not approved") unless entry["status"] == "approved" && entry["findings"] == []
  end
  execution_time = Time.iso8601(nonempty_string!(draft["executionCompletedAt"], "draft executionCompletedAt")) rescue abort_with("draft executionCompletedAt is invalid")
  reviewed_time = Time.iso8601(nonempty_string!(visual["reviewedAt"], "visual reviewedAt")) rescue abort_with("visual reviewedAt is invalid")
  abort_with("visual review predates execution") if reviewed_time < execution_time
  abort_with("visual reviewedAt is implausibly in the future") if reviewed_time > Time.now + 300
  final = {
    "schemaVersion" => 1, "status" => "passed", "changeClassification" => "application-code", "reason" => nil,
    "issue" => draft["issue"], "baseSha" => base, "headSha" => head,
    "issueContract" => draft["issueContract"], "matrixFile" => draft["matrixFile"], "matrixDigest" => draft["matrixDigest"],
    "executionRoute" => draft["executionRoute"], "xcode" => draft["xcode"], "build" => draft["build"], "tests" => draft["tests"],
    "cases" => draft_cases.map { |entry| {"id" => entry["id"], "status" => "passed", "screenshot" => entry["screenshot"]} },
    "visualEvaluation" => {"status" => "passed", "findings" => []},
    "acceptanceEvidence" => contract_mappings.map { |mapping| {"id" => mapping.fetch("id"), "status" => "passed", "evidence" => mapping.fetch("checks")} },
    "completedAt" => visual["reviewedAt"]
  }
  File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.pretty_generate(final) + "\n")
    file.flush
    file.fsync
  end
else
  abort_with("unknown JSON helper action")
end
RUBY
}

usage() {
  echo "usage: tools/verify-ios-issue.sh --issue N --expected-base SHA --issue-contract canonical --matrix canonical --project PATH --scheme NAME" >&2
  echo "   or: tools/verify-ios-issue.sh --finalize --issue N --expected-base SHA --draft canonical --visual-result canonical" >&2
  exit 2
}

mode="execute"
if [[ "${1-}" == "--finalize" ]]; then
  mode="finalize"
  shift
fi

issue="" expected_base="" issue_contract="" matrix="" project="" scheme="" draft="" visual_result=""
declare -a seen_options=()
while [[ "$#" -gt 0 ]]; do
  option="$1"
  shift
  [[ "$#" -gt 0 ]] || usage
  value="$1"
  shift
  for seen in "${seen_options[@]-}"; do [[ "$seen" != "$option" ]] || usage; done
  seen_options+=("$option")
  case "$option" in
    --issue) issue="$value" ;;
    --expected-base) expected_base="$value" ;;
    --issue-contract) issue_contract="$value" ;;
    --matrix) matrix="$value" ;;
    --project) project="$value" ;;
    --scheme) scheme="$value" ;;
    --draft) draft="$value" ;;
    --visual-result) visual_result="$value" ;;
    *) usage ;;
  esac
done

[[ "$issue" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$expected_base" =~ ^[0-9a-f]{40}$ ]] || usage
if [[ "$mode" == "execute" ]]; then
  [[ -n "$issue_contract" && -n "$matrix" && -n "$project" && -n "$scheme" && -z "$draft" && -z "$visual_result" ]] || usage
else
  [[ -n "$draft" && -n "$visual_result" && -z "$issue_contract" && -z "$matrix" && -z "$project" && -z "$scheme" ]] || usage
fi

repository_root="$(run_git rev-parse --show-toplevel 2>/dev/null)" || { echo "iOS verification failed: Git repository unavailable" >&2; exit 1; }
repository_root="$(cd "$repository_root" && pwd -P)"
[[ "$(pwd -P)" == "$repository_root" ]] || { echo "iOS verification failed: run from the Git top-level" >&2; exit 1; }
head_sha="$(run_git rev-parse HEAD 2>/dev/null)" || { echo "iOS verification failed: current Git Head unavailable" >&2; exit 1; }
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "iOS verification failed: current Git Head is invalid" >&2; exit 1; }
run_git rev-parse --verify "${expected_base}^{commit}" >/dev/null 2>&1 || { echo "iOS verification failed: expected Base is not a commit" >&2; exit 1; }
[[ "$expected_base" != "$head_sha" ]] || { echo "iOS verification failed: Base and Head must differ" >&2; exit 1; }
run_git merge-base --is-ancestor "$expected_base" "$head_sha" || { echo "iOS verification failed: expected Base is not an ancestor of current Git Head" >&2; exit 1; }
[[ -z "$(run_git status --porcelain --untracked-files=all)" ]] || { echo "iOS verification failed: working tree must be clean" >&2; exit 1; }

evidence_dir="$repository_root/.artifacts/issues/$issue/$head_sha"
failure_dir="$evidence_dir/failures"
stage="preflight"
fail() {
  local message="$1"
  json_tool failure "$failure_dir" "$issue" "$expected_base" "$head_sha" "$stage" "$message" >/dev/null 2>&1 || true
  echo "iOS verification failed: $message" >&2
  exit 1
}

if [[ "$mode" == "finalize" ]]; then
  expected_draft=".artifacts/issues/$issue/$head_sha/verify-draft.json"
  expected_visual=".artifacts/issues/$issue/$head_sha/visual-result.json"
  if [[ "$draft" != "$expected_draft" || "$visual_result" != "$expected_visual" ]]; then
    if [[ "$draft" =~ ^\.artifacts/issues/$issue/[0-9a-f]{40}/verify-draft\.json$ && "$visual_result" =~ ^\.artifacts/issues/$issue/[0-9a-f]{40}/visual-result\.json$ ]]; then
      fail "draft does not match current Git Head"
    fi
    fail "draft and visual result must use canonical paths"
  fi
  [[ -f "$repository_root/$draft" && ! -L "$repository_root/$draft" ]] || fail "canonical draft is unavailable"
  [[ -f "$repository_root/$visual_result" && ! -L "$repository_root/$visual_result" ]] || fail "canonical visual result is unavailable"
  final_path="$evidence_dir/verify.json"
  [[ ! -e "$final_path" && ! -L "$final_path" ]] || fail "canonical verify.json already exists"
  candidate="$evidence_dir/.verify-candidate-$PPID-$$"
  trap '/bin/rm -f "$candidate"' EXIT
  stage="visual-finalization"
  json_tool final "$repository_root" "$draft" "$visual_result" "$candidate" "$issue" "$expected_base" "$head_sha" 2>"$evidence_dir/.finalize-error-$$" || {
    diagnostic="$(<"$evidence_dir/.finalize-error-$$")"
    /bin/rm -f "$evidence_dir/.finalize-error-$$"
    case "$diagnostic" in
      *"draft digest"*) fail "visual draft digest mismatch" ;;
      *"current Git range"*) fail "draft does not match current Git Head" ;;
      *) fail "visual result is invalid" ;;
    esac
  }
  /bin/rm -f "$evidence_dir/.finalize-error-$$"
  /bin/chmod 0400 "$candidate" || fail "verify.json candidate could not be sealed"
  stage="final-schema-validation"
  resolve_xcode_environment || fail "Xcode could not be resolved for final validation"
  if ! run_xcode_swift "$script_dir/validate-verify-json.swift" --file "$final_path" --candidate-file "$candidate" --expected-issue "$issue" --expected-base "$expected_base" --expected-head "$head_sha"; then
    fail "final verify.json failed strict schema validation"
  fi
  trap - EXIT
  printf '%s\n' "$final_path"
  exit 0
fi

expected_contract=".artifacts/issues/$issue/issue-contract.json"
[[ "$issue_contract" == "$expected_contract" ]] || fail "issue contract must use the canonical path"
[[ "$matrix" =~ ^\.artifacts/batches/[A-Za-z0-9][A-Za-z0-9-]{0,63}/simulator-matrix\.json$ ]] || fail "matrix must use the canonical path"
[[ "$project" != /* && "$project" != *".."* && -d "$repository_root/$project" && ! -L "$repository_root/$project" ]] || fail "project path is invalid"
[[ "$scheme" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "scheme is invalid"

stage="input-validation"
select_initial_xcode_environment || fail "Xcode tools could not be derived"
if ! snapshot_receipt="$(run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-snapshot \
  --issue "$issue" --expected-base "$expected_base" --expected-head "$head_sha" \
  --issue-contract "$issue_contract" --matrix "$matrix" 2>&1)"; then
  diagnostic="$snapshot_receipt"
  case "$diagnostic" in
    *"lock"*) fail "verification lock is already held" ;;
    *"verification"*) fail "verification contract is absent or incomplete" ;;
    *) fail "contract or matrix validation failed" ;;
  esac
fi
if ! receipt_values="$(json_tool receipt "$snapshot_receipt" 2>/dev/null)"; then
  fail "verification workspace receipt is invalid"
fi
IFS=$'\t' read -r config workspace_root lock_token <<<"$receipt_values"
run_state="$(json_tool config-value "$config" runState)"
[[ "$(json_tool config-value "$config" workspaceRoot)" == "$workspace_root" ]] || fail "verification workspace identity mismatch"
active_udid=""
active_bundle=""
release_runner() {
  local status="$?"
  if [[ -n "$active_udid" && -n "$active_bundle" ]]; then
    run_xcrun simctl terminate "$active_udid" "$active_bundle" >/dev/null 2>&1 || true
  fi
  run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-release --config "$config" --token "$lock_token" >/dev/null 2>&1 || true
  return "$status"
}
trap release_runner EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage="xcode-resolution"
if ! probe_xcode_environment; then
  select_fallback_xcode_environment || fail "Xcode could not be resolved"
  probe_xcode_environment || fail "Xcode could not be resolved"
fi
json_tool verify-xcode "$config" "$XCODE_DEVELOPER_DIR" "$XCODE_VERSION" "$XCODE_BUILD" >/dev/null 2>&1 || fail "resolved Xcode does not match the frozen matrix"

derived_data="$workspace_root/DerivedData"
build_result="$workspace_root/Build.xcresult"
test_result="$workspace_root/Tests.xcresult"
[[ ! -e "$derived_data" && ! -e "$build_result" && ! -e "$test_result" ]] || fail "verification workspace already contains results for this Head"
first_udid="$(json_tool config-value "$config" cases.0.udid)"

stage="build"
build_log="$run_state/build.log"
if ! run_xcodebuild -project "$project" -scheme "$scheme" -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$first_udid" -derivedDataPath "$derived_data" \
  -resultBundlePath "$build_result" build >"$build_log" 2>&1; then
  fail "build command failed"
fi
build_diagnostics="$run_state/build-diagnostics.json"
run_xcrun xcresulttool get build-results --schema-version 0.1.0 --path "$build_result" --compact >"$build_diagnostics" 2>"$run_state/build-diagnostics-error" || fail "build diagnostics failed"
json_tool diagnostics "$build_diagnostics" 2>"$run_state/build-diagnostics-parse-error" || fail "build warnings are not allowed"

stage="unit-tests"
test_log="$run_state/tests.log"
if ! run_xcodebuild -project "$project" -scheme "$scheme" -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$first_udid" -derivedDataPath "$derived_data" \
  -resultBundlePath "$test_result" test >"$test_log" 2>&1; then
  fail "unit tests command failed"
fi
test_diagnostics="$run_state/test-diagnostics.json"
run_xcrun xcresulttool get build-results --schema-version 0.1.0 --path "$test_result" --compact >"$test_diagnostics" 2>"$run_state/test-diagnostics-error" || fail "unit test diagnostics failed"
json_tool diagnostics "$test_diagnostics" 2>"$run_state/test-diagnostics-parse-error" || fail "unit test warnings are not allowed"
summary="$run_state/test-summary.json"
if ! run_xcrun xcresulttool get test-results summary --schema-version 0.1.0 --path "$test_result" --compact >"$summary" 2>"$run_state/xcresult-error"; then
  fail "unit tests summary failed"
fi
if ! counts="$(json_tool test-summary "$summary" unit "$first_udid" 2>"$run_state/test-summary-error")"; then
  fail "unit tests failed, were skipped, or reported invalid counts"
fi
IFS=$'\t' read -r passed failed skipped <<<"$counts"

bundle_identifier="$(json_tool config-value "$config" bundleIdentifier)"
if ! app_path="$(run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-find-app \
  --derived-data "$derived_data" --bundle-identifier "$bundle_identifier" 2>"$run_state/app-lookup-error")"; then
  fail "built application matching the verification bundle identifier was not found safely"
fi

for index in 0 1 2 3; do
  case_id="$(json_tool config-value "$config" cases.$index.id)"
  udid="$(json_tool config-value "$config" cases.$index.udid)"
  locale="$(json_tool config-value "$config" cases.$index.locale)"
  language="$(json_tool config-value "$config" cases.$index.language)"
  action="$(json_tool config-value "$config" cases.$index.action)"
  action_value="$(json_tool config-value "$config" cases.$index.value)"
  stage="case-$case_id"
  case_failed=""
  if ! run_xcrun simctl boot "$udid" >/dev/null 2>&1; then
    simulator_state="$run_state/$case_id-simulator-state.json"
    run_xcrun simctl list devices --json >"$simulator_state" 2>/dev/null || case_failed="boot state"
    [[ -n "$case_failed" ]] || json_tool simulator-booted "$simulator_state" "$udid" >/dev/null 2>&1 || case_failed="boot state"
  fi
  [[ -n "$case_failed" ]] || run_xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || case_failed="bootstatus"
  [[ -n "$case_failed" ]] || run_xcrun simctl install "$udid" "$app_path" >/dev/null 2>&1 || case_failed="install"
  if [[ -z "$case_failed" ]]; then
    run_xcrun simctl terminate "$udid" "$bundle_identifier" >/dev/null 2>&1 || true
    active_udid="$udid"
    active_bundle="$bundle_identifier"
  fi
  launch_output=""
  if [[ -z "$case_failed" ]]; then
    launch_output="$(run_xcrun simctl launch "$udid" "$bundle_identifier" -AppleLanguages "($language)" -AppleLocale "$locale" 2>/dev/null)" || case_failed="launch"
  fi
  if [[ -z "$case_failed" ]]; then
    launch_prefix="$bundle_identifier: "
    launch_pid="${launch_output#"$launch_prefix"}"
    [[ "$launch_output" == "$launch_prefix"* && "$launch_pid" =~ ^[1-9][0-9]*$ ]] || case_failed="launch PID"
  fi
  if [[ -z "$case_failed" ]]; then
    run_xcrun simctl spawn "$udid" /bin/kill -0 "$launch_pid" >/dev/null 2>&1 || case_failed="process liveness"
  fi
  if [[ -z "$case_failed" && "$action" == "testIdentifier" ]]; then
    region="${locale#*_}"
    case_result="$workspace_root/Cases/$case_id.xcresult"
    [[ ! -e "$case_result" ]] || case_failed="UI result collision"
  fi
  if [[ -z "$case_failed" && "$action" == "testIdentifier" ]]; then
    run_xcodebuild -project "$project" -scheme "$scheme" -sdk iphonesimulator \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived_data" \
      -resultBundlePath "$case_result" \
      -only-testing:"$action_value" -testLanguage "$language" -testRegion "$region" \
      test-without-building >"$run_state/$case_id-ui-test.log" 2>&1 || case_failed="UI test"
    if [[ -z "$case_failed" ]]; then
      case_diagnostics="$run_state/$case_id-diagnostics.json"
      run_xcrun xcresulttool get build-results --schema-version 0.1.0 --path "$case_result" --compact >"$case_diagnostics" 2>"$run_state/$case_id-diagnostics-error" || case_failed="UI diagnostics"
    fi
    if [[ -z "$case_failed" ]]; then
      json_tool diagnostics "$case_diagnostics" 2>"$run_state/$case_id-diagnostics-parse-error" || case_failed="UI warnings"
    fi
    if [[ -z "$case_failed" ]]; then
      case_summary="$run_state/$case_id-summary.json"
      run_xcrun xcresulttool get test-results summary --schema-version 0.1.0 --path "$case_result" --compact >"$case_summary" 2>"$run_state/$case_id-summary-error" || case_failed="UI summary"
    fi
    if [[ -z "$case_failed" ]]; then
      json_tool test-summary "$case_summary" case "$udid" >/dev/null 2>"$run_state/$case_id-summary-parse-error" || case_failed="UI selected test"
    fi
  elif [[ -z "$case_failed" && "$action_value" != "launch-succeeded" ]]; then
    case_failed="mechanical assertion"
  fi
  screenshot_source="$workspace_root/Screenshots/$case_id.png"
  [[ ! -e "$screenshot_source" ]] || case_failed="screenshot collision"
  [[ -n "$case_failed" ]] || run_xcrun simctl io "$udid" screenshot "$screenshot_source" >/dev/null 2>&1 || case_failed="screenshot"
  if [[ -z "$case_failed" ]]; then
    run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-publish-screenshot \
      --source "$screenshot_source" --issue "$issue" --head "$head_sha" --case "$case_id" \
      >/dev/null 2>"$run_state/$case_id-screenshot-publication-error" || case_failed="screenshot publication"
  fi
  if run_xcrun simctl terminate "$udid" "$bundle_identifier" >/dev/null 2>&1; then
    active_udid=""
    active_bundle=""
  elif [[ -z "$case_failed" ]]; then
    case_failed="terminate"
  fi
  [[ -z "$case_failed" ]] || fail "case $case_id failed"
done

stage="input-stability"
contract_digest="$(json_tool config-value "$config" contractDigest)"
matrix_digest="$(json_tool config-value "$config" matrixDigest)"
if ! input_diagnostic="$(run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-check-inputs \
  --issue "$issue" --expected-base "$expected_base" --expected-head "$head_sha" \
  --issue-contract "$issue_contract" --matrix "$matrix" \
  --contract-digest "$contract_digest" --matrix-digest "$matrix_digest" 2>&1)"; then
  case "$input_diagnostic" in
    *"contract changed"*) fail "contract changed during verification" ;;
    *"matrix changed"*) fail "matrix changed during verification" ;;
    *) fail "verification inputs changed during verification" ;;
  esac
fi
[[ "$(run_git rev-parse HEAD)" == "$head_sha" ]] || fail "current Git Head changed during verification"
[[ -z "$(run_git status --porcelain --untracked-files=all)" ]] || fail "working tree changed during verification"

stage="draft-publication"
draft_path="$evidence_dir/verify-draft.json"
json_tool draft "$config" "$draft_path" "$issue" "$expected_base" "$head_sha" "$scheme" \
  "$derived_data" "$build_result" "$test_result" "$passed" "$failed" "$skipped" || fail "atomic draft publication failed"
trap - EXIT
release_runner
printf '%s\n' "$draft_path"
