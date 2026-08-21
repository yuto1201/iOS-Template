#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tools/lib/xcode.sh
source "$script_dir/lib/xcode.sh"

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
  File.rename(temporary, path)
  directory = File.open(File.dirname(path), File::RDONLY)
  directory.fsync
  directory.close
ensure
  File.unlink(temporary) if defined?(temporary) && File.exist?(temporary)
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
  exact_keys!(verification, %w[bundleIdentifier cases], "verification")
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
  [bundle, acceptance_ids, normalized]
end

def validate_matrix!(document)
  exact_keys!(document, %w[batchId cases resolvedAt runtime schemaVersion xcode], "matrix")
  abort_with("matrix schemaVersion must be 1") unless document["schemaVersion"] == 1
  %w[batchId resolvedAt].each { |key| nonempty_string!(document[key], "matrix #{key}") }
  exact_keys!(document["xcode"], %w[build path version], "matrix xcode")
  document["xcode"].each { |key, value| nonempty_string!(value, "matrix xcode #{key}") }
  exact_keys!(document["runtime"], %w[identifier version], "matrix runtime")
  document["runtime"].each { |key, value| nonempty_string!(value, "matrix runtime #{key}") }
  cases = document["cases"]
  abort_with("matrix must contain exactly four cases") unless cases.is_a?(Array) && cases.length == 4
  udids = []
  family_types = {}
  normalized = cases.each_with_index.map do |entry, index|
    exact_keys!(entry, %w[deviceType family id language locale udid], "matrix case")
    expected = EXPECTED_CASES[index]
    abort_with("matrix cases must use the exact four ordered locale rows") unless [entry["id"], entry["family"], entry["locale"], entry["language"]] == expected
    exact_keys!(entry["deviceType"], %w[identifier name], "matrix deviceType")
    entry["deviceType"].each { |key, value| nonempty_string!(value, "matrix deviceType #{key}") }
    family_types[entry["family"]] ||= entry["deviceType"]
    abort_with("matrix must use one Device Type per family") unless family_types[entry["family"]] == entry["deviceType"]
    udid = nonempty_string!(entry["udid"], "matrix udid")
    abort_with("matrix udid is invalid") unless udid.match?(/\A[0-9A-Fa-f-]+\z/)
    abort_with("matrix Simulator UDIDs must be unique") if udids.include?(udid)
    udids << udid
    {"id" => entry["id"], "locale" => entry["locale"], "language" => entry["language"], "udid" => udid}
  end
  [document["xcode"], normalized]
end

action = ARGV.shift
case action
when "snapshot"
  root, contract_path, matrix_path, config_path, issue_text = ARGV
  issue = Integer(issue_text, 10)
  contract_bytes = read_bound_file(root, contract_path, "issue contract")
  matrix_bytes = read_bound_file(root, matrix_path, "matrix")
  contract = parse_json(contract_bytes, "issue contract")
  matrix = parse_json(matrix_bytes, "matrix")
  bundle, acceptance_ids, verification_cases = validate_contract!(contract, issue)
  matrix_xcode, matrix_cases = validate_matrix!(matrix)
  abort_with("verification cases do not match matrix") unless verification_cases.map { |entry| entry["id"] } == matrix_cases.map { |entry| entry["id"] }
  cases = matrix_cases.each_with_index.map { |entry, index| entry.merge(verification_cases[index].reject { |key, _| key == "id" }) }
  config = {
    "contractPath" => contract_path, "contractDigest" => digest(contract_bytes),
    "matrixPath" => matrix_path, "matrixDigest" => digest(matrix_bytes),
    "bundleIdentifier" => bundle, "acceptanceIDs" => acceptance_ids,
    "xcode" => matrix_xcode, "cases" => cases
  }
  File.write(config_path, JSON.generate(config), mode: "wb", perm: 0o600)
when "verify-xcode"
  config = JSON.parse(File.read(ARGV.fetch(0)))
  actual = {"path" => ARGV.fetch(1), "version" => ARGV.fetch(2), "build" => ARGV.fetch(3)}
  abort_with("resolved Xcode does not match the frozen matrix") unless config.fetch("xcode") == actual
when "config-value"
  config = JSON.parse(File.read(ARGV.fetch(0)))
  path = ARGV.fetch(1).split(".")
  value = path.reduce(config) { |memo, component| component.match?(/\A\d+\z/) ? memo.fetch(component.to_i) : memo.fetch(component) }
  puts value
when "verify-inputs"
  config_path, root = ARGV
  config = JSON.parse(File.read(config_path))
  contract = read_bound_file(root, config.fetch("contractPath"), "issue contract")
  matrix = read_bound_file(root, config.fetch("matrixPath"), "matrix")
  abort_with("contract changed during verification") unless digest(contract) == config.fetch("contractDigest")
  abort_with("matrix changed during verification") unless digest(matrix) == config.fetch("matrixDigest")
when "test-summary"
  summary = JSON.parse(File.read(ARGV.fetch(0)))
  passed = integer!(summary["passedTests"], "passedTests", 0)
  failed = integer!(summary["failedTests"], "failedTests", 0)
  skipped = integer!(summary["skippedTests"], "skippedTests", 0)
  total = integer!(summary["totalTestCount"], "totalTestCount", 0)
  abort_with("unit tests did not report exact totals") unless total == passed + failed + skipped
  abort_with("unit tests failed or were skipped") unless passed > 0 && failed == 0 && skipped == 0
  puts [passed, failed, skipped].join("\t")
when "draft"
  config_path, output, issue_text, base, head, scheme, derived, build_result, test_result, passed_text, failed_text, skipped_text = ARGV
  config = JSON.parse(File.read(config_path))
  cases = config.fetch("cases").map do |entry|
    mechanical = entry.fetch("action") == "testIdentifier" ? "test:#{entry.fetch("value")}" : "assertion:launch-succeeded"
    {"id" => entry.fetch("id"), "status" => "passed", "screenshot" => "#{entry.fetch("id")}/screenshot.png", "mechanicalCheck" => mechanical}
  end
  case_reference = "cases:#{cases.map { |entry| entry.fetch("id") }.join(",")}"
  draft = {
    "schemaVersion" => 1, "status" => "awaiting-visual-review", "issue" => Integer(issue_text, 10),
    "baseSha" => base, "headSha" => head,
    "issueContract" => {"path" => config.fetch("contractPath"), "digest" => config.fetch("contractDigest")},
    "matrixFile" => config.fetch("matrixPath"), "matrixDigest" => config.fetch("matrixDigest"),
    "executionRoute" => "xcodebuild-simctl", "xcode" => config.fetch("xcode"),
    "build" => {"status" => "passed", "scheme" => scheme, "warningsAdded" => 0},
    "tests" => {"status" => "passed", "passed" => Integer(passed_text, 10), "failed" => Integer(failed_text, 10), "skipped" => Integer(skipped_text, 10)},
    "cases" => cases,
    "acceptanceEvidence" => config.fetch("acceptanceIDs").map { |id| {"id" => id, "evidence" => ["stage:build", "stage:unit-tests", case_reference]} },
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
  draft["workspaceArtifacts"].each do |key, value|
    path = nonempty_string!(value, "draft workspaceArtifacts #{key}")
    abort_with("draft workspaceArtifacts escaped /tmp") unless path.start_with?("/tmp/ios-template-verify/")
  end
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
    abort_with("draft mechanicalCheck is invalid") unless check == "assertion:launch-succeeded" || check.match?(/\Atest:[^\s]+\z/)
  end
  acceptance = draft["acceptanceEvidence"]
  abort_with("draft acceptanceEvidence must be non-empty") unless acceptance.is_a?(Array) && !acceptance.empty?
  acceptance.each_with_index do |entry, index|
    exact_keys!(entry, %w[evidence id], "draft acceptanceEvidence")
    abort_with("draft acceptance IDs are not exact and ordered") unless entry["id"] == "AC-#{index + 1}"
    evidence = entry["evidence"]
    abort_with("draft acceptance evidence must be non-empty stage/case references") unless evidence.is_a?(Array) && !evidence.empty? && evidence.all? { |item| item.is_a?(String) && (item.start_with?("stage:") || item.start_with?("cases:")) && !item.split(":", 2).last.to_s.strip.empty? }
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
    "acceptanceEvidence" => draft["acceptanceEvidence"].map { |entry| {"id" => entry["id"], "status" => "passed", "evidence" => entry["evidence"]} },
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

repository_root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "iOS verification failed: Git repository unavailable" >&2; exit 1; }
repository_root="$(cd "$repository_root" && pwd -P)"
[[ "$(pwd -P)" == "$repository_root" ]] || { echo "iOS verification failed: run from the Git top-level" >&2; exit 1; }
head_sha="$(git rev-parse HEAD 2>/dev/null)" || { echo "iOS verification failed: current Git Head unavailable" >&2; exit 1; }
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "iOS verification failed: current Git Head is invalid" >&2; exit 1; }
git rev-parse --verify "${expected_base}^{commit}" >/dev/null 2>&1 || { echo "iOS verification failed: expected Base is not a commit" >&2; exit 1; }
[[ "$expected_base" != "$head_sha" ]] || { echo "iOS verification failed: Base and Head must differ" >&2; exit 1; }
git merge-base --is-ancestor "$expected_base" "$head_sha" || { echo "iOS verification failed: expected Base is not an ancestor of current Git Head" >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || { echo "iOS verification failed: working tree must be clean" >&2; exit 1; }

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
  trap 'rm -f "$candidate"' EXIT
  stage="visual-finalization"
  json_tool final "$repository_root" "$draft" "$visual_result" "$candidate" "$issue" "$expected_base" "$head_sha" 2>"$evidence_dir/.finalize-error-$$" || {
    diagnostic="$(<"$evidence_dir/.finalize-error-$$")"
    rm -f "$evidence_dir/.finalize-error-$$"
    case "$diagnostic" in
      *"draft digest"*) fail "visual draft digest mismatch" ;;
      *"current Git range"*) fail "draft does not match current Git Head" ;;
      *) fail "visual result is invalid" ;;
    esac
  }
  rm -f "$evidence_dir/.finalize-error-$$"
  mv "$candidate" "$final_path" || fail "atomic verify.json publication failed"
  stage="final-schema-validation"
  if ! swift "$script_dir/validate-verify-json.swift" --file "$final_path" --expected-issue "$issue" --expected-base "$expected_base" --expected-head "$head_sha"; then
    rm -f "$final_path"
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

worktree_name="$(basename "$repository_root")"
root_digest="$(printf '%s' "$repository_root" | shasum -a 256 | awk '{print substr($1,1,12)}')"
worktree_id="${worktree_name//[^A-Za-z0-9_.-]/-}-$root_digest"
workspace_root="/tmp/ios-template-verify/$worktree_id/issue-$issue/$head_sha"
run_state="$workspace_root/.run-$PPID-$$"
mkdir -p "$run_state" "$evidence_dir" || fail "verification workspace could not be created"
trap 'rm -rf "$run_state"' EXIT
config="$run_state/config.json"

stage="input-validation"
if ! json_tool snapshot "$repository_root" "$issue_contract" "$matrix" "$config" "$issue" 2>"$run_state/input-error"; then
  diagnostic="$(<"$run_state/input-error")"
  case "$diagnostic" in
    *"verification"*) fail "verification contract is absent or incomplete" ;;
    *) fail "contract or matrix validation failed" ;;
  esac
fi

stage="xcode-resolution"
resolve_xcode_environment || fail "Xcode could not be resolved"
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
warning_count="$(grep -Eic '(^|[[:space:]])warning:' "$build_log" || true)"
[[ "$warning_count" == 0 ]] || fail "build warnings are not allowed"

stage="unit-tests"
test_log="$run_state/tests.log"
if ! run_xcodebuild -project "$project" -scheme "$scheme" -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$first_udid" -derivedDataPath "$derived_data" \
  -resultBundlePath "$test_result" test >"$test_log" 2>&1; then
  fail "unit tests command failed"
fi
test_warning_count="$(grep -Eic '(^|[[:space:]])warning:' "$test_log" || true)"
[[ "$test_warning_count" == 0 ]] || fail "unit test warnings are not allowed"
summary="$run_state/test-summary.json"
if ! run_xcrun xcresulttool get test-results summary --path "$test_result" >"$summary" 2>"$run_state/xcresult-error"; then
  fail "unit tests summary failed"
fi
if ! counts="$(json_tool test-summary "$summary" 2>"$run_state/test-summary-error")"; then
  fail "unit tests failed, were skipped, or reported invalid counts"
fi
IFS=$'\t' read -r passed failed skipped <<<"$counts"

bundle_identifier="$(json_tool config-value "$config" bundleIdentifier)"
app_path=""
while IFS= read -r -d '' candidate_app; do
  candidate_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate_app/Info.plist" 2>/dev/null || true)"
  if [[ "$candidate_bundle" == "$bundle_identifier" ]]; then
    [[ -z "$app_path" ]] || fail "multiple built applications match the verification bundle identifier"
    app_path="$candidate_app"
  fi
done < <(find "$derived_data/Build/Products" -type d -name '*.app' -print0 2>/dev/null)
[[ -n "$app_path" ]] || fail "built application matching the verification bundle identifier was not found"

for index in 0 1 2 3; do
  case_id="$(json_tool config-value "$config" cases.$index.id)"
  udid="$(json_tool config-value "$config" cases.$index.udid)"
  locale="$(json_tool config-value "$config" cases.$index.locale)"
  language="$(json_tool config-value "$config" cases.$index.language)"
  action="$(json_tool config-value "$config" cases.$index.action)"
  action_value="$(json_tool config-value "$config" cases.$index.value)"
  stage="case-$case_id"
  case_failed=""
  run_xcrun simctl boot "$udid" >/dev/null 2>&1 || case_failed="boot"
  [[ -n "$case_failed" ]] || run_xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || case_failed="bootstatus"
  [[ -n "$case_failed" ]] || run_xcrun simctl install "$udid" "$app_path" >/dev/null 2>&1 || case_failed="install"
  [[ -n "$case_failed" ]] || run_xcrun simctl launch "$udid" "$bundle_identifier" -AppleLanguages "($language)" -AppleLocale "$locale" >/dev/null 2>&1 || case_failed="launch"
  if [[ -z "$case_failed" && "$action" == "testIdentifier" ]]; then
    region="${locale#*_}"
    run_xcodebuild -project "$project" -scheme "$scheme" -sdk iphonesimulator \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived_data" \
      -only-testing:"$action_value" -testLanguage "$language" -testRegion "$region" \
      test-without-building >"$run_state/$case_id-ui-test.log" 2>&1 || case_failed="UI test"
  elif [[ -z "$case_failed" && "$action_value" != "launch-succeeded" ]]; then
    case_failed="mechanical assertion"
  fi
  screenshot_dir="$evidence_dir/$case_id"
  mkdir -p "$screenshot_dir" || case_failed="screenshot directory"
  [[ -n "$case_failed" ]] || run_xcrun simctl io "$udid" screenshot "$screenshot_dir/screenshot.png" >/dev/null 2>&1 || case_failed="screenshot"
  run_xcrun simctl terminate "$udid" "$bundle_identifier" >/dev/null 2>&1 || [[ -n "$case_failed" ]] || case_failed="terminate"
  [[ -z "$case_failed" ]] || fail "case $case_id failed"
done

stage="input-stability"
if ! input_diagnostic="$(json_tool verify-inputs "$config" "$repository_root" 2>&1)"; then
  case "$input_diagnostic" in
    *"contract changed"*) fail "contract changed during verification" ;;
    *"matrix changed"*) fail "matrix changed during verification" ;;
    *) fail "verification inputs changed during verification" ;;
  esac
fi
[[ "$(git rev-parse HEAD)" == "$head_sha" ]] || fail "current Git Head changed during verification"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail "working tree changed during verification"

stage="draft-publication"
draft_path="$evidence_dir/verify-draft.json"
json_tool draft "$config" "$draft_path" "$issue" "$expected_base" "$head_sha" "$scheme" \
  "$derived_data" "$build_result" "$test_result" "$passed" "$failed" "$skipped" || fail "atomic draft publication failed"
trap - EXIT
rm -rf "$run_state"
printf '%s\n' "$draft_path"
