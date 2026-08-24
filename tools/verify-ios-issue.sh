#!/bin/bash -p
set -euo pipefail

unset CDPATH
script_source="${BASH_SOURCE[0]}"
[[ "$script_source" == */* && "$script_source" != *[$'\001'-$'\037'$'\177']* ]] || {
  echo "iOS verification failed: unsafe runner invocation path" >&2
  exit 1
}
script_source_directory="${script_source%/*}"
[[ "$script_source_directory" == /* || "$script_source_directory" == ./* ]] || script_source_directory="./$script_source_directory"
script_dir="$({ builtin cd -P -- "$script_source_directory" >/dev/null && /bin/pwd -P; })" || {
  echo "iOS verification failed: runner directory unavailable" >&2
  exit 1
}
# shellcheck source=tools/lib/xcode.sh
source "$script_dir/lib/xcode.sh"

TRUSTED_GIT="/usr/bin/git"

run_git() {
  run_scrubbed GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=0 GIT_NO_REPLACE_OBJECTS=1 "$TRUSTED_GIT" \
    -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

json_tool() {
  run_scrubbed /usr/bin/ruby --disable-gems -rjson -rtime - "$@" <<'RUBY'
def abort_with(message)
  warn message
  exit 1
end

def integer!(value, label, minimum = nil)
  abort_with("#{label} must be an integer") unless value.is_a?(Integer)
  abort_with("#{label} is below its minimum") if minimum && value < minimum
  value
end

action = ARGV.shift
case action
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
  abort_with("test summary kind is invalid") unless %w[unit case].include?(expected_kind)
  abort_with("tests failed, were skipped, or selected the wrong count") unless passed == 1 && total == 1 && failed == 0 && skipped == 0 && expected_failures == 0
  configurations = summary["devicesAndConfigurations"]
  abort_with("devicesAndConfigurations must contain exactly one entry") unless configurations.is_a?(Array) && configurations.length == 1
  configuration = configurations.fetch(0)
  abort_with("device configuration must be an object") unless configuration.is_a?(Hash)
  device = configuration["device"]
  abort_with("test result device is invalid") unless device.is_a?(Hash) && device["deviceId"] == expected_udid
  plan = configuration["testPlanConfiguration"]
  abort_with("test plan configuration is invalid") unless plan.is_a?(Hash) && plan["configurationId"] == "1" && plan["configurationName"] == "Test Scheme Action"
  abort_with("device test totals mismatch") unless configuration["passedTests"] == passed && configuration["failedTests"] == failed && configuration["skippedTests"] == skipped && configuration["expectedFailures"] == expected_failures
  puts [passed, failed, skipped].join("\t")
when "test-tree"
  tree_path, expected_identifier, expected_udid = ARGV
  tree = JSON.parse(File.read(tree_path))
  devices = tree["devices"]
  abort_with("test tree device is invalid") unless devices.is_a?(Array) && devices.length == 1 && devices[0].is_a?(Hash) && devices[0]["deviceId"] == expected_udid
  target, klass, method = expected_identifier.split("/", -1)
  abort_with("expected test identifier is invalid") unless [target, klass, method].all? { |entry| entry && !entry.empty? }
  declared_method = method
  method = method.delete_suffix("()")
  test_cases = []
  visit = lambda do |node|
    if node.is_a?(Hash)
      test_cases << node if node["nodeType"] == "Test Case"
      node.each_value { |value| visit.call(value) }
    elsif node.is_a?(Array)
      node.each { |value| visit.call(value) }
    end
  end
  visit.call(tree["testNodes"])
  abort_with("selected test tree must contain exactly one passed test") unless test_cases.length == 1
  selected = test_cases.fetch(0)
  expected_node = "#{klass}/#{method}()"
  expected_url_suffix = "/#{target}/#{klass}/#{declared_method}"
  abort_with("selected test tree identifier mismatch") unless selected["nodeIdentifier"] == expected_node && selected["nodeIdentifierURL"].is_a?(String) && selected["nodeIdentifierURL"].end_with?(expected_url_suffix) && selected["result"] == "Passed"
when "diagnostics"
  diagnostics_path, expected_status = ARGV
  diagnostics = JSON.parse(File.read(diagnostics_path))
  warning_count = integer!(diagnostics["warningCount"], "warningCount", 0)
  analyzer_count = integer!(diagnostics["analyzerWarningCount"], "analyzerWarningCount", 0)
  error_count = integer!(diagnostics["errorCount"], "errorCount", 0)
  abort_with("expected diagnostics status is invalid") unless %w[succeeded notRequested].include?(expected_status)
  abort_with("structured diagnostics status mismatch") unless diagnostics["status"] == expected_status
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
evidence_dir="$repository_root/.artifacts/issues/$issue/$head_sha"
stage="preflight"
fail() {
  local message="$1"
  if [[ -z "${XCODE_SWIFT_PATH-}" ]]; then
    select_initial_xcode_environment >/dev/null 2>&1 || true
  fi
  if [[ -n "${XCODE_SWIFT_PATH-}" ]]; then
    run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-record-failure \
      --issue "$issue" --expected-base "$expected_base" --expected-head "$head_sha" \
      --stage "$stage" --message "$message" >/dev/null 2>&1 || true
  fi
  echo "iOS verification failed: $message" >&2
  exit 1
}

run_git rev-parse --verify "${expected_base}^{commit}" >/dev/null 2>&1 || fail "expected Base is not a commit"
[[ "$expected_base" != "$head_sha" ]] || fail "Base and Head must differ"
run_git merge-base --is-ancestor "$expected_base" "$head_sha" || fail "expected Base is not an ancestor of current Git Head"
if [[ "$mode" == "finalize" ]]; then
  expected_draft=".artifacts/issues/$issue/$head_sha/verify-draft.json"
  expected_visual=".artifacts/issues/$issue/$head_sha/visual-result.json"
  if [[ "$draft" != "$expected_draft" || "$visual_result" != "$expected_visual" ]]; then
    if [[ "$draft" =~ ^\.artifacts/issues/$issue/[0-9a-f]{40}/verify-draft\.json$ && "$visual_result" =~ ^\.artifacts/issues/$issue/[0-9a-f]{40}/visual-result\.json$ ]]; then
      fail "draft does not match current Git Head"
    fi
    fail "draft and visual result must use canonical paths"
  fi
  stage="visual-finalization"
  resolve_xcode_environment || fail "Xcode could not be resolved for final validation"
  if ! final_output="$(run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-finalize \
      --issue "$issue" --expected-base "$expected_base" --expected-head "$head_sha" \
      --draft "$draft" --visual-result "$visual_result" 2>&1)"; then
    diagnostic="$final_output"
    case "$diagnostic" in
      *"draft digest"*) fail "visual draft digest mismatch" ;;
      *"current Git range"*) fail "draft does not match current Git Head" ;;
      *"already exists"*) fail "canonical verify.json already exists" ;;
      *) fail "visual result is invalid" ;;
    esac
  fi
  printf '%s\n' "$final_output"
  exit 0
fi

expected_contract=".artifacts/issues/$issue/issue-contract.json"
[[ "$issue_contract" == "$expected_contract" ]] || fail "issue contract must use the canonical path"
[[ "$matrix" =~ ^\.artifacts/batches/[A-Za-z0-9][A-Za-z0-9-]{0,63}/simulator-matrix\.json$ ]] || fail "matrix must use the canonical path"
[[ "$scheme" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "scheme is invalid"

select_initial_xcode_environment || fail "Xcode tools could not be derived"
if ! snapshot_receipt="$(run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-snapshot \
  --issue "$issue" --expected-base "$expected_base" --expected-head "$head_sha" \
  --issue-contract "$issue_contract" --matrix "$matrix" --project "$project" 2>&1)"; then
  diagnostic="$snapshot_receipt"
  case "$diagnostic" in
    *"lock"*) fail "verification lock is already held" ;;
    *"verification"*) fail "verification contract is absent or incomplete" ;;
    *"tracked"*|*"source bytes"*|*"source mode"*) fail "working tree must be clean" ;;
    *"project"*) fail "project path or contents are invalid" ;;
    *) fail "contract or matrix validation failed" ;;
  esac
fi
stage="input-validation"
IFS=$'\t' read -r config config_digest workspace_root attempt_root lock_path lock_ready_fifo lock_control_fifo <<<"$snapshot_receipt"
[[ -n "$config" && -n "$config_digest" && -n "$workspace_root" && -n "$attempt_root" && -n "$lock_path" && -n "$lock_ready_fifo" && -n "$lock_control_fifo" ]] || fail "verification workspace receipt is invalid"
config_value() {
  run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-config \
    --config "$config" --digest "$config_digest" --get "$1"
}
config_check() {
  run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-config \
    --config "$config" --digest "$config_digest" --check >/dev/null
}
active_case_id=""
active_probe_pid=""
runner_succeeded=0
lock_holder_pid=""
simulator_snapshot_index=0
run_state="$attempt_root"
stop_probe_group() {
  local probe_pid="$1" iteration
  /bin/kill -TERM -- "-$probe_pid" >/dev/null 2>&1 || true
  for ((iteration = 0; iteration < 20; iteration++)); do
    /bin/kill -0 -- "-$probe_pid" >/dev/null 2>&1 || break
    /bin/sleep 0.05
  done
  if /bin/kill -0 -- "-$probe_pid" >/dev/null 2>&1; then
    /bin/kill -KILL -- "-$probe_pid" >/dev/null 2>&1 || true
    for ((iteration = 0; iteration < 20; iteration++)); do
      /bin/kill -0 -- "-$probe_pid" >/dev/null 2>&1 || break
      /bin/sleep 0.05
    done
  fi
  wait "$probe_pid" >/dev/null 2>&1 || true
  ! /bin/kill -0 -- "-$probe_pid" >/dev/null 2>&1
}
release_runner() {
  local status="$?" cleanup_case_id cleanup_udid cleanup_bundle probe_stopped=1
  if [[ -n "$active_probe_pid" ]]; then
    if ! stop_probe_group "$active_probe_pid"; then
      echo "iOS verification failed: bounded Simulator probe cleanup failed" >&2
      [[ "$status" -ne 0 ]] || status=1
      probe_stopped=0
    fi
    active_probe_pid=""
  fi
  if [[ -n "$active_case_id" && "$probe_stopped" -eq 1 ]]; then
    cleanup_case_id="$active_case_id"
    cleanup_udid="$(case_udid "$cleanup_case_id")" || cleanup_udid=""
    cleanup_bundle="$(config_value bundleIdentifier)" || cleanup_bundle=""
    if [[ -n "$cleanup_udid" && -n "$cleanup_bundle" ]]; then
      run_xcrun simctl terminate "$cleanup_udid" "$cleanup_bundle" >/dev/null 2>&1 || true
    fi
    if [[ -z "$cleanup_udid" || -z "$cleanup_bundle" ]] || ! reclaim_owned_simulator "$cleanup_case_id" "exit-cleanup"; then
      run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-record-failure \
        --issue "$issue" --expected-base "$expected_base" --expected-head "$head_sha" \
        --stage "$stage" --message "active Simulator resource reclamation failed" >/dev/null 2>&1 || true
      echo "iOS verification failed: active Simulator resource reclamation failed" >&2
      [[ "$status" -ne 0 ]] || status=1
    fi
  fi
  exec 9>&- || true
  if [[ -n "$lock_holder_pid" ]]; then
    if ! wait "$lock_holder_pid"; then
      echo "iOS verification failed: verification lock release failed" >&2
      [[ "$status" -ne 0 ]] || status=1
    fi
  fi
  if [[ "$runner_succeeded" -ne 1 ]]; then
    if ! run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-clean-attempt \
        --config "$config" --digest "$config_digest" >/dev/null 2>&1; then
      echo "iOS verification failed: verification attempt cleanup failed" >&2
      [[ "$status" -ne 0 ]] || status=1
    fi
  fi
  return "$status"
}
trap release_runner EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_xcrun_bounded() {
  local output_path="$1" error_path="$2" result=0 iteration
  shift 2
  initialize_trusted_environment || return 1
  /usr/bin/env -i "${TRUSTED_BASE_ENV[@]}" DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
    /usr/bin/ruby --disable-gems -e 'Process.setpgrp; exec(*ARGV)' "$TRUSTED_XCRUN" "$@" \
    9>&- >"$output_path" 2>"$error_path" &
  active_probe_pid="$!"
  for ((iteration = 0; iteration < 100; iteration++)); do
    if ! /bin/kill -0 "$active_probe_pid" >/dev/null 2>&1; then
      wait "$active_probe_pid" || result="$?"
      active_probe_pid=""
      return "$result"
    fi
    /bin/sleep 0.05
  done
  stop_probe_group "$active_probe_pid" || result=125
  active_probe_pid=""
  [[ "$result" -eq 0 ]] || return "$result"
  return 124
}

capture_simulator_identities() {
  local label="$1" target_case="${2-}" expected_state="${3-}" snapshot output
  [[ "$label" =~ ^[A-Za-z0-9-]+$ ]] || return 1
  simulator_snapshot_index=$((simulator_snapshot_index + 1))
  snapshot="$run_state/simulator-devices-${simulator_snapshot_index}-${label}.json"
  [[ ! -e "$snapshot" ]] || return 1
  run_xcrun simctl list devices --json >"$snapshot" 2>"$run_state/simulator-devices-${simulator_snapshot_index}-${label}-error" || return 1
  if [[ -n "$target_case" && -n "$expected_state" ]]; then
    output="$(run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-check-simulators \
      --config "$config" --digest "$config_digest" --devices "$snapshot" \
      --target "$target_case" --expected-state "$expected_state")" || return 1
  elif [[ -n "$target_case" ]]; then
    output="$(run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-check-simulators \
      --config "$config" --digest "$config_digest" --devices "$snapshot" \
      --target "$target_case")" || return 1
  else
    run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-check-simulators \
      --config "$config" --digest "$config_digest" --devices "$snapshot" >/dev/null || return 1
    output=""
  fi
  current_simulator_state="$output"
}

case_udid() {
  case "$1" in
    iphone-en) config_value cases.0.udid ;;
    iphone-ja) config_value cases.1.udid ;;
    ipad-en) config_value cases.2.udid ;;
    ipad-ja) config_value cases.3.udid ;;
    *) return 1 ;;
  esac
}

reclaim_owned_simulator() {
  local case_id="$1" label="$2" udid
  udid="$(case_udid "$case_id")" || return 1
  capture_simulator_identities "$label-pre" "$case_id" || return 1
  case "$current_simulator_state" in
    Booted) run_xcrun simctl shutdown "$udid" >/dev/null 2>&1 || return 1 ;;
    Shutdown) ;;
    *) return 1 ;;
  esac
  capture_simulator_identities "$label-shutdown" "$case_id" Shutdown || return 1
  run_xcrun simctl erase "$udid" >/dev/null 2>&1 || return 1
  capture_simulator_identities "$label-post" "$case_id" Shutdown || return 1
  if [[ "$active_case_id" == "$case_id" ]]; then
    active_case_id=""
  fi
}

config_check || fail "verification workspace receipt is invalid"
[[ "$(config_value workspaceRoot)" == "$workspace_root" && "$(config_value attemptRoot)" == "$attempt_root" && "$(config_value lockPath)" == "$lock_path" && "$(config_value lockReadyFIFO)" == "$lock_ready_fifo" && "$(config_value lockControlFIFO)" == "$lock_control_fifo" ]] || fail "verification workspace identity mismatch"
project_relative="$(config_value project.path)"
project="$(config_value buildProjectPath)"
source_root="$(config_value sourceRoot)"
project_digest="$(config_value project.digest)"
source_digest="$(config_value sourceTree.digest)"
run_snapshot_xcodebuild() (
  unset CDPATH
  builtin cd -P -- "$source_root" >/dev/null
  run_xcodebuild "$@"
)
contract_digest="$(config_value contractDigest)"
matrix_digest="$(config_value matrixDigest)"
verify_live_inputs() {
  local input_diagnostic
  config_check || fail "verification config changed during verification"
  if ! input_diagnostic="$(run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-check-inputs \
    --issue "$issue" --expected-base "$expected_base" --expected-head "$head_sha" \
    --issue-contract "$issue_contract" --matrix "$matrix" --project "$project_relative" \
    --contract-digest "$contract_digest" --matrix-digest "$matrix_digest" \
    --project-digest "$project_digest" --source-digest "$source_digest" 2>&1)"; then
    case "$input_diagnostic" in
      *"contract changed"*) fail "contract changed during verification" ;;
      *"matrix changed"*) fail "matrix changed during verification" ;;
      *"project"*) fail "project changed during verification" ;;
      *) fail "verification inputs changed during verification" ;;
    esac
  fi
}
run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-lock-holder \
  --config "$config" --digest "$config_digest" <"$lock_control_fifo" >"$lock_ready_fifo" &
lock_holder_pid="$!"
exec 9>"$lock_control_fifo"
if ! read -r -t 30 lock_status <"$lock_ready_fifo" || [[ "$lock_status" != "LOCKED" ]]; then
  exec 9>&-
  wait "$lock_holder_pid" >/dev/null 2>&1 || true
  run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-clean-attempt \
    --config "$config" --digest "$config_digest" >/dev/null 2>&1 || true
  fail "verification lock is already held"
fi

stage="publication-recovery"
verify_live_inputs
if ! recovered_draft="$(run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-recover-publication \
  --config "$config" --digest "$config_digest" --issue "$issue" \
  --expected-base "$expected_base" --expected-head "$head_sha" \
  2>"$run_state/publication-recovery-error")"; then
  fail "interrupted draft publication could not be recovered"
fi
if [[ -n "$recovered_draft" ]]; then
  [[ "$recovered_draft" == "$evidence_dir/verify-draft.json" ]] || fail "interrupted draft publication could not be recovered"
  printf '%s\n' "$recovered_draft"
  exit 0
fi

stage="simulator-ownership"
capture_simulator_identities "startup-full-set" || fail "dedicated Simulator ownership validation failed"
for owned_case_id in iphone-en iphone-ja ipad-en ipad-ja; do
  reclaim_owned_simulator "$owned_case_id" "startup-$owned_case_id" \
    || fail "dedicated Simulator startup reclamation failed"
done

stage="xcode-resolution"
if ! probe_xcode_environment; then
  select_fallback_xcode_environment || fail "Xcode could not be resolved"
  probe_xcode_environment || fail "Xcode could not be resolved"
fi
run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-verify-xcode \
  --config "$config" --digest "$config_digest" --path "$XCODE_DEVELOPER_DIR" \
  --version "$XCODE_VERSION" --build "$XCODE_BUILD" >/dev/null 2>&1 || fail "resolved Xcode does not match the frozen matrix"

derived_data="$attempt_root/DerivedData"
build_result="$attempt_root/Build.xcresult"
test_result="$attempt_root/Tests.xcresult"
[[ ! -e "$derived_data" && ! -e "$build_result" && ! -e "$test_result" ]] || fail "verification workspace already contains results for this Head"
first_udid="$(config_value cases.0.udid)"

stage="build"
build_log="$run_state/build.log"
if ! run_snapshot_xcodebuild -project "$project" -scheme "$scheme" -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$first_udid" -derivedDataPath "$derived_data" \
  -resultBundlePath "$build_result" -parallel-testing-enabled NO build-for-testing >"$build_log" 2>&1; then
  fail "build command failed"
fi
build_diagnostics="$run_state/build-diagnostics.json"
run_xcrun xcresulttool get build-results --schema-version 0.1.0 --path "$build_result" --compact >"$build_diagnostics" 2>"$run_state/build-diagnostics-error" || fail "build diagnostics failed"
json_tool diagnostics "$build_diagnostics" succeeded 2>"$run_state/build-diagnostics-parse-error" || fail "build warnings are not allowed"

stage="unit-tests"
test_log="$run_state/tests.log"
unit_test_identifier="$(config_value unitTestIdentifier)"
if ! run_snapshot_xcodebuild -project "$project" -scheme "$scheme" -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$first_udid" -derivedDataPath "$derived_data" \
  -resultBundlePath "$test_result" -parallel-testing-enabled NO \
  -only-testing:"$unit_test_identifier" test-without-building >"$test_log" 2>&1; then
  fail "unit tests command failed"
fi
test_diagnostics="$run_state/test-diagnostics.json"
run_xcrun xcresulttool get build-results --schema-version 0.1.0 --path "$test_result" --compact >"$test_diagnostics" 2>"$run_state/test-diagnostics-error" || fail "unit test diagnostics failed"
json_tool diagnostics "$test_diagnostics" notRequested 2>"$run_state/test-diagnostics-parse-error" || fail "unit test warnings are not allowed"
summary="$run_state/test-summary.json"
if ! run_xcrun xcresulttool get test-results summary --schema-version 0.1.0 --path "$test_result" --compact >"$summary" 2>"$run_state/xcresult-error"; then
  fail "unit tests summary failed"
fi
if ! counts="$(json_tool test-summary "$summary" unit "$first_udid" 2>"$run_state/test-summary-error")"; then
  fail "unit tests failed, were skipped, or reported invalid counts"
fi
IFS=$'\t' read -r passed failed skipped <<<"$counts"
unit_tree="$run_state/test-tree.json"
if ! run_xcrun xcresulttool get test-results tests --schema-version 0.1.0 --path "$test_result" --compact >"$unit_tree" 2>"$run_state/test-tree-error"; then
  fail "unit tests tree failed"
fi
json_tool test-tree "$unit_tree" "$unit_test_identifier" "$first_udid" 2>"$run_state/test-tree-parse-error" || fail "unit tests selected the wrong identifier"

stage="post-unit-simulator-reclamation"
verify_live_inputs
reclaim_owned_simulator "iphone-en" "post-unit-iphone-en" \
  || fail "unit-test Simulator resource reclamation failed"

bundle_identifier="$(config_value bundleIdentifier)"
if ! app_receipt="$(run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-find-app \
  --config "$config" --digest "$config_digest" --derived-data "$derived_data" \
  --bundle-identifier "$bundle_identifier" 2>"$run_state/app-lookup-error")"; then
  fail "built application matching the verification bundle identifier was not found safely"
fi
IFS=$'\t' read -r app_path app_digest app_executable <<<"$app_receipt"
[[ -n "$app_path" && "$app_digest" =~ ^sha256:[0-9a-f]{64}$ && "$app_executable" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,127}$ ]] || fail "built application staging receipt is invalid"

for index in 0 1 2 3; do
  stage="case-input-$index"
  verify_live_inputs
  case_id="$(config_value cases.$index.id)"
  udid="$(config_value cases.$index.udid)"
  locale="$(config_value cases.$index.locale)"
  language="$(config_value cases.$index.language)"
  action="$(config_value cases.$index.action)"
  action_value="$(config_value cases.$index.value)"
  stage="case-$case_id"
  case_failed=""
  active_case_id="$case_id"
  if ! run_xcrun simctl boot "$udid" >/dev/null 2>&1; then
    simulator_state="$run_state/$case_id-simulator-state.json"
    run_xcrun simctl list devices --json >"$simulator_state" 2>/dev/null || case_failed="boot state"
    [[ -n "$case_failed" ]] || json_tool simulator-booted "$simulator_state" "$udid" >/dev/null 2>&1 || case_failed="boot state"
  fi
  [[ -n "$case_failed" ]] || run_xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || case_failed="bootstatus"
  if [[ -z "$case_failed" ]]; then
    run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-check-app \
      --config "$config" --digest "$config_digest" --app "$app_path" \
      --bundle-digest "$app_digest" --executable "$app_executable" \
      >/dev/null 2>"$run_state/$case_id-app-validation-error" \
      || fail "built application changed during verification"
  fi
  [[ -n "$case_failed" ]] || run_xcrun simctl install "$udid" "$app_path" >/dev/null 2>&1 || case_failed="install"
  if [[ -z "$case_failed" ]]; then
    installed_container_file="$run_state/$case_id-installed-container"
    if run_xcrun_bounded "$installed_container_file" "$run_state/$case_id-installed-container-error" \
        simctl get_app_container "$udid" "$bundle_identifier" app; then
      installed_app_container="$(/bin/cat "$installed_container_file")"
      [[ "$installed_app_container" =~ ^/[^[:cntrl:]]+\.app$ ]] || case_failed="installed application identity"
    else
      case_failed="installed application identity"
    fi
  fi
  if [[ -z "$case_failed" ]]; then
    run_xcrun simctl terminate "$udid" "$bundle_identifier" >/dev/null 2>&1 || true
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
    run_xcrun_bounded /dev/null "$run_state/$case_id-liveness-error" \
      simctl spawn "$udid" /bin/kill -0 "$launch_pid" || case_failed="process liveness"
  fi
  if [[ -z "$case_failed" && "$action" == "testIdentifier" ]]; then
    region="${locale#*_}"
    case_result="$attempt_root/Cases/$case_id.xcresult"
    [[ ! -e "$case_result" ]] || case_failed="UI result collision"
  fi
  if [[ -z "$case_failed" && "$action" == "testIdentifier" ]]; then
    run_snapshot_xcodebuild -project "$project" -scheme "$scheme" -sdk iphonesimulator \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived_data" \
      -resultBundlePath "$case_result" -parallel-testing-enabled NO \
      -only-testing:"$action_value" -testLanguage "$language" -testRegion "$region" \
      test-without-building >"$run_state/$case_id-ui-test.log" 2>&1 || case_failed="UI test"
    if [[ -z "$case_failed" ]]; then
      case_diagnostics="$run_state/$case_id-diagnostics.json"
      run_xcrun xcresulttool get build-results --schema-version 0.1.0 --path "$case_result" --compact >"$case_diagnostics" 2>"$run_state/$case_id-diagnostics-error" || case_failed="UI diagnostics"
    fi
    if [[ -z "$case_failed" ]]; then
      json_tool diagnostics "$case_diagnostics" notRequested 2>"$run_state/$case_id-diagnostics-parse-error" || case_failed="UI warnings"
    fi
    if [[ -z "$case_failed" ]]; then
      case_summary="$run_state/$case_id-summary.json"
      run_xcrun xcresulttool get test-results summary --schema-version 0.1.0 --path "$case_result" --compact >"$case_summary" 2>"$run_state/$case_id-summary-error" || case_failed="UI summary"
    fi
    if [[ -z "$case_failed" ]]; then
      json_tool test-summary "$case_summary" case "$udid" >/dev/null 2>"$run_state/$case_id-summary-parse-error" || case_failed="UI selected test"
    fi
    if [[ -z "$case_failed" ]]; then
      case_tree="$run_state/$case_id-tree.json"
      run_xcrun xcresulttool get test-results tests --schema-version 0.1.0 --path "$case_result" --compact >"$case_tree" 2>"$run_state/$case_id-tree-error" || case_failed="UI test tree"
    fi
    if [[ -z "$case_failed" ]]; then
      json_tool test-tree "$case_tree" "$action_value" "$udid" >/dev/null 2>"$run_state/$case_id-tree-parse-error" || case_failed="UI selected test identifier"
    fi
    if [[ -z "$case_failed" ]]; then
      run_xcrun simctl terminate "$udid" "$bundle_identifier" >/dev/null 2>&1 || true
      launch_output="$(run_xcrun simctl launch "$udid" "$bundle_identifier" -AppleLanguages "($language)" -AppleLocale "$locale" 2>/dev/null)" || case_failed="UI relaunch"
    fi
    if [[ -z "$case_failed" ]]; then
      launch_prefix="$bundle_identifier: "
      launch_pid="${launch_output#"$launch_prefix"}"
      [[ "$launch_output" == "$launch_prefix"* && "$launch_pid" =~ ^[1-9][0-9]*$ ]] || case_failed="UI relaunch PID"
    fi
    if [[ -z "$case_failed" ]]; then
      current_container_file="$run_state/$case_id-current-container"
      if run_xcrun_bounded "$current_container_file" "$run_state/$case_id-current-container-error" \
          simctl get_app_container "$udid" "$bundle_identifier" app; then
        installed_app_container="$(/bin/cat "$current_container_file")"
        [[ "$installed_app_container" =~ ^/[^[:cntrl:]]+\.app$ ]] || case_failed="current application container"
      else
        case_failed="current application container"
      fi
    fi
    if [[ -z "$case_failed" ]]; then
      current_process_file="$run_state/$case_id-current-process"
      if run_xcrun_bounded "$current_process_file" "$run_state/$case_id-current-process-error" \
          simctl spawn "$udid" /bin/ps -ww -p "$launch_pid" -o comm=; then
        [[ "$(/bin/cat "$current_process_file")" == "$installed_app_container/$app_executable" ]] || case_failed="current application identity"
      else
        case_failed="current application identity"
      fi
    fi
  elif [[ -z "$case_failed" && "$action_value" != "launch-succeeded" ]]; then
    case_failed="mechanical assertion"
  fi
  if [[ -z "$case_failed" ]]; then
    run_xcrun_bounded /dev/null "$run_state/$case_id-post-check-liveness-error" \
      simctl spawn "$udid" /bin/kill -0 "$launch_pid" || case_failed="post-check process liveness"
  fi
  screenshot_source="$attempt_root/Screenshots/$case_id.png"
  [[ ! -e "$screenshot_source" ]] || case_failed="screenshot collision"
  [[ -n "$case_failed" ]] || run_xcrun simctl io "$udid" screenshot "$screenshot_source" >/dev/null 2>&1 || case_failed="screenshot"
  if [[ -z "$case_failed" ]]; then
    run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-seal-png \
      --config "$config" --digest "$config_digest" --case "$case_id" \
      --source "$screenshot_source" >/dev/null 2>"$run_state/$case_id-screenshot-validation-error" || case_failed="screenshot validation"
  fi
  if [[ -z "$case_failed" ]]; then
    stage="case-$case_id-input-stability"
    verify_live_inputs
    stage="case-$case_id-reclamation"
  fi
  if ! run_xcrun simctl terminate "$udid" "$bundle_identifier" >/dev/null 2>&1 && [[ -z "$case_failed" ]]; then
    case_failed="terminate"
  fi
  if ! reclaim_owned_simulator "$case_id" "case-$case_id" && [[ -z "$case_failed" ]]; then
    case_failed="resource reclamation"
  fi
  [[ -z "$case_failed" ]] || fail "case $case_id failed: $case_failed"
done

stage="input-stability"
verify_live_inputs
[[ "$(run_git rev-parse HEAD)" == "$head_sha" ]] || fail "current Git Head changed during verification"

stage="draft-publication"
draft_path="$evidence_dir/verify-draft.json"
if ! published_draft="$(run_xcode_swift "$script_dir/validate-verify-json.swift" --runner-publish-draft \
    --config "$config" --digest "$config_digest" --issue "$issue" \
    --expected-base "$expected_base" --expected-head "$head_sha" --scheme "$scheme" \
    --derived-data "$derived_data" --build-result "$build_result" --test-result "$test_result" \
    --passed "$passed" --failed "$failed" --skipped "$skipped" 2>&1)"; then
  fail "atomic draft publication failed"
fi
[[ "$published_draft" == "$draft_path" ]] || fail "atomic draft publication failed"
runner_succeeded=1
trap - EXIT
release_runner
printf '%s\n' "$draft_path"
