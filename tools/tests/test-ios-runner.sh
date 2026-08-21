#!/usr/bin/env bash
set -euo pipefail

source_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d "$HOME/Library/Caches/ios-runner.XXXXXX")"
scratch="$(cd "$scratch" && pwd -P)"
trap '[[ "${KEEP_IOS_RUNNER_SCRATCH-}" == 1 ]] || rm -rf "$scratch"' EXIT

adapter_bin="$scratch/adapter-bin"
poison_bin="$scratch/poison-bin"
fake_developer="$scratch/FakeXcode/Contents/Developer"
fake_log="$scratch/commands.log"
poison_log="$scratch/poison.log"
test_source="$scratch/test-source"
runner="$test_source/tools/verify-ios-issue.sh"
mkdir -p "$adapter_bin" "$poison_bin" "$fake_developer/usr/bin" \
  "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin" "$test_source/tools/lib"
/bin/cp "$source_repo/tools/verify-ios-issue.sh" "$runner"
/bin/cp "$source_repo/tools/lib/xcode.sh" "$test_source/tools/lib/xcode.sh"
/bin/cp "$source_repo/tools/validate-verify-json.swift" "$test_source/tools/validate-verify-json.swift"

# This is a test-only compiled copy: production constants are textually replaced with
# absolute adapters. If the constants disappear, the poison PATH below catches it.
/usr/bin/sed -i '' \
  -e "s|^TRUSTED_XCODE_SELECT=.*|TRUSTED_XCODE_SELECT=\"$adapter_bin/xcode-select\"|" \
  -e "s|^TRUSTED_XCRUN=.*|TRUSTED_XCRUN=\"$adapter_bin/xcrun\"|" \
  -e "s|^PREFERRED_DEVELOPER_DIR=.*|PREFERRED_DEVELOPER_DIR=\"$fake_developer\"|" \
  "$test_source/tools/lib/xcode.sh"

for poisoned in git xcode-select xcrun xcodebuild swift; do
  /usr/bin/sed "s|@NAME@|$poisoned|g; s|@LOG@|$poison_log|g" >"$poison_bin/$poisoned" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '@NAME@' >>'@LOG@'
exit 97
SH
  chmod +x "$poison_bin/$poisoned"
done

cat >"$adapter_bin/xcode-select" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for variable in "${!GIT_@}"; do echo "xcode-select environment retained $variable" >&2; exit 1; done
[[ -z "${DEVELOPER_DIR-}${TOOLCHAINS-}${SDKROOT-}" ]] || { echo 'xcode-select environment was not scrubbed' >&2; exit 1; }
printf 'xcode-select\tDEVELOPER_DIR=%s\t%s\n' "${DEVELOPER_DIR-}" "$*" >>"$FAKE_COMMAND_LOG"
[[ "$#" -eq 1 && "$1" == "-p" ]]
printf '%s\n' "$FAKE_FALLBACK_DEVELOPER_DIR"
SH
chmod +x "$adapter_bin/xcode-select"

cat >"$fake_developer/usr/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for variable in "${!GIT_@}"; do echo "xcodebuild environment retained $variable" >&2; exit 1; done
[[ -z "${TOOLCHAINS-}${SDKROOT-}" ]] || { echo 'xcodebuild environment was not scrubbed' >&2; exit 1; }
{
  printf 'xcodebuild\tDEVELOPER_DIR=%s' "${DEVELOPER_DIR-}"
  printf '\t%s' "$@"
  printf '\n'
} >>"$FAKE_COMMAND_LOG"
if [[ "$#" -eq 1 && "$1" == "-version" ]]; then
  if [[ "${FAKE_PREFERRED_XCODE_INVALID-}" == 1 && "${DEVELOPER_DIR-}" == *"/FakeXcode/Contents/Developer" ]]; then
    echo "configured preferred Xcode failure" >&2
    exit 1
  fi
  printf '%s\n' 'Xcode 26.5' 'Build version 17F42'
  exit 0
fi
mode=""
for argument in "$@"; do
  case "$argument" in
    build) mode="build" ;;
    test) mode="unit-test" ;;
    test-without-building) mode="ui-test" ;;
  esac
done
if [[ "$mode" == build ]]; then
  [[ "${FAKE_BUILD_MODE-}" != fail ]] || { echo "configured build failure TOKEN-super-secret" >&2; exit 1; }
  derived="" result="" previous=""
  for argument in "$@"; do
    [[ "$previous" != -derivedDataPath ]] || derived="$argument"
    [[ "$previous" != -resultBundlePath ]] || result="$argument"
    previous="$argument"
  done
  app="$derived/Build/Products/Debug-iphonesimulator/TemplateApp.app"
  mkdir -p "$app" "$result"
  plist='<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.TemplateApp</string></dict></plist>'
  if [[ "${FAKE_BUILD_MODE-}" == plist-symlink ]]; then
    printf '%s\n' "$plist" >"$derived/outside-info.plist"
    /bin/ln -s "$derived/outside-info.plist" "$app/Info.plist"
  else
    printf '%s\n' "$plist" >"$app/Info.plist"
  fi
  if [[ -n "${FAKE_HOLD_BUILD_FILE-}" ]]; then
    : >"$FAKE_HOLD_BUILD_FILE.started"
    while [[ ! -e "$FAKE_HOLD_BUILD_FILE.release" ]]; do /bin/sleep 0.05; done
  fi
  [[ "${FAKE_MUTATE_INPUT-}" != contract ]] || printf '\n' >>"$FAKE_CONTRACT_PATH"
  [[ "${FAKE_MUTATE_INPUT-}" != matrix ]] || printf '\n' >>"$FAKE_MATRIX_PATH"
  exit 0
fi
if [[ "$mode" == unit-test ]]; then
  result="" previous=""
  for argument in "$@"; do
    [[ "$previous" != -resultBundlePath ]] || result="$argument"
    previous="$argument"
  done
  mkdir -p "$result"
  [[ "${FAKE_TEST_MODE-}" != command-fail ]] || { echo 'configured unit test command failure' >&2; exit 1; }
  echo "Test Suite 'All tests' passed"
  exit 0
fi
[[ "$mode" == ui-test ]] || { echo 'unexpected xcodebuild arguments' >&2; exit 1; }
[[ "${FAKE_UI_MODE-}" != fail ]] || { echo 'configured UI test failure' >&2; exit 1; }
destination="" identifier="" language="" region="" result="" previous=""
for argument in "$@"; do
  [[ "$previous" != -destination ]] || destination="$argument"
  [[ "$previous" != -testLanguage ]] || language="$argument"
  [[ "$previous" != -testRegion ]] || region="$argument"
  [[ "$previous" != -resultBundlePath ]] || result="$argument"
  [[ "$argument" != -only-testing:* ]] || identifier="${argument#-only-testing:}"
  previous="$argument"
done
case "$destination" in
  *id=00000000-0000-0000-0000-000000000001) expected_case=iphone-en; expected_language=en; expected_region=US ;;
  *id=00000000-0000-0000-0000-000000000003) expected_case=ipad-en; expected_language=en; expected_region=US ;;
  *) echo 'wrong UI destination' >&2; exit 1 ;;
esac
[[ "$identifier" == TemplateAppUITests/SmokeTests/testLaunch ]] || { echo 'wrong UI identifier' >&2; exit 1; }
[[ "$language" == "$expected_language" && "$region" == "$expected_region" ]] || { echo 'wrong UI locale' >&2; exit 1; }
[[ "$result" == */Cases/"$expected_case".xcresult ]] || { echo 'wrong or missing UI result path' >&2; exit 1; }
mkdir -p "$result"
echo "Test Suite 'Selected tests' passed"
SH
chmod +x "$fake_developer/usr/bin/xcodebuild"

cat >"$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for variable in "${!GIT_@}"; do echo "Swift environment retained $variable" >&2; exit 1; done
[[ -z "${TOOLCHAINS-}${SDKROOT-}" ]] || { echo 'Swift environment was not scrubbed' >&2; exit 1; }
unset DEVELOPER_DIR TOOLCHAINS SDKROOT
if [[ " $* " == *" --runner-check-inputs "* && "${FAKE_COLLIDE_DRAFT-}" == 1 ]]; then
  /usr/bin/swift "$@"
  collision="$(pwd -P)/.artifacts/issues/42/$(/usr/bin/git rev-parse HEAD)/verify-draft.json"
  mkdir -p "$(dirname "$collision")"
  printf '%s\n' sentinel-draft >"$collision"
  exit 0
fi
if [[ " $* " == *" --candidate-file "* && "${FAKE_COLLIDE_FINAL-}" == 1 ]]; then
  target="" previous=""
  for argument in "$@"; do
    [[ "$previous" != --file ]] || target="$argument"
    previous="$argument"
  done
  [[ -n "$target" ]] || { echo 'missing canonical final path' >&2; exit 1; }
  printf '%s\n' sentinel-final >"$target"
fi
exec /usr/bin/swift "$@"
SH
chmod +x "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

cat >"$adapter_bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for variable in "${!GIT_@}"; do echo "xcrun environment retained $variable" >&2; exit 1; done
[[ -z "${TOOLCHAINS-}${SDKROOT-}" ]] || { echo 'xcrun environment was not scrubbed' >&2; exit 1; }
{
  printf 'xcrun\tDEVELOPER_DIR=%s' "${DEVELOPER_DIR-}"
  printf '\t%s' "$@"
  printf '\n'
} >>"$FAKE_COMMAND_LOG"
if [[ "${1-}" == xcresulttool ]]; then
  result_path="" previous=""
  for argument in "$@"; do
    [[ "$previous" != --path ]] || result_path="$argument"
    previous="$argument"
  done
  [[ -n "$result_path" ]] || { echo 'missing xcresult path' >&2; exit 1; }
  if [[ "${3-}" == build-results ]]; then
    warnings=0 errors=0
    case "$result_path" in
      */Build.xcresult) [[ "${FAKE_BUILD_MODE-}" != warning ]] || warnings=1 ;;
      */Tests.xcresult) [[ "${FAKE_TEST_MODE-}" != warning ]] || warnings=1 ;;
      */Cases/*.xcresult) [[ "${FAKE_UI_MODE-}" != warning ]] || warnings=1 ;;
      *) echo 'unexpected diagnostics result path' >&2; exit 1 ;;
    esac
    printf '{"status":"succeeded","analyzerWarningCount":0,"errorCount":%s,"warningCount":%s,"analyzerWarnings":[],"warnings":[],"errors":[]}\n' "$errors" "$warnings"
    exit 0
  fi
  [[ "${2-}" == get && "${3-}" == test-results && "${4-}" == summary ]] || { echo 'unexpected xcresulttool query' >&2; exit 1; }
  if [[ "$result_path" == */Tests.xcresult ]]; then
    passed=24 failed=0 skipped=0 total=24 udid=00000000-0000-0000-0000-000000000001
    case "${FAKE_TEST_MODE-}" in
      failed) passed=23; failed=1 ;;
      skipped) passed=23; skipped=1 ;;
      zero) passed=0; total=0 ;;
    esac
  else
    passed=1 failed=0 skipped=0 total=1
    case "$result_path" in
      */Cases/iphone-en.xcresult) udid=00000000-0000-0000-0000-000000000001 ;;
      */Cases/ipad-en.xcresult) udid=00000000-0000-0000-0000-000000000003 ;;
      *) echo 'unexpected UI summary result path' >&2; exit 1 ;;
    esac
    case "${FAKE_UI_MODE-}" in
      zero) passed=0; total=0 ;;
      skipped) passed=0; skipped=1 ;;
    esac
  fi
  printf '{"result":"Passed","totalTestCount":%s,"passedTests":%s,"failedTests":%s,"skippedTests":%s,"expectedFailures":0,"devicesAndConfigurations":{"device":{"deviceId":"%s"},"passedTests":%s,"failedTests":%s,"skippedTests":%s,"expectedFailures":0}}\n' \
    "$total" "$passed" "$failed" "$skipped" "$udid" "$passed" "$failed" "$skipped"
  exit 0
fi
[[ "${1-}" == simctl ]] || { echo 'expected simctl' >&2; exit 1; }
command="${2-}"
case "$command" in
  boot)
    [[ "${FAKE_PREBOOTED-}" != 1 ]] || exit 1
    ;;
  list)
    [[ "${3-}" == devices && "${4-}" == --json ]] || { echo 'wrong simulator state query' >&2; exit 1; }
    printf '%s\n' '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[' \
      '{"udid":"00000000-0000-0000-0000-000000000001","state":"Booted"},' \
      '{"udid":"00000000-0000-0000-0000-000000000002","state":"Booted"},' \
      '{"udid":"00000000-0000-0000-0000-000000000003","state":"Booted"},' \
      '{"udid":"00000000-0000-0000-0000-000000000004","state":"Booted"}]}}'
    ;;
  bootstatus|install|terminate) exit 0 ;;
  launch)
    /usr/bin/awk -F '\t' -v udid="${3-}" '$3 == "simctl" && $4 == "terminate" && $5 == udid {seen=1} END {exit seen ? 0 : 1}' "$FAKE_COMMAND_LOG" || { echo 'launch lacked pre-termination' >&2; exit 1; }
    [[ "${FAKE_CASE_MODE-}" != launch-fail || "${3-}" != "00000000-0000-0000-0000-000000000002" ]] || { echo 'configured launch failure' >&2; exit 1; }
    printf '%s: 4321\n' "${4-}"
    ;;
  spawn)
    [[ "${4-}" == /bin/kill && "${5-}" == -0 && "${6-}" == 4321 ]] || { echo 'wrong process liveness probe' >&2; exit 1; }
    [[ "${FAKE_CASE_MODE-}" != crash || "${3-}" != "00000000-0000-0000-0000-000000000002" ]] || exit 1
    ;;
  io)
    [[ "${4-}" == screenshot ]] || { echo 'expected screenshot' >&2; exit 1; }
    /usr/bin/awk -F '\t' -v udid="${3-}" '$3 == "simctl" && $4 == "spawn" && $5 == udid && $6 == "/bin/kill" && $7 == "-0" {seen=1} END {exit seen ? 0 : 1}' "$FAKE_COMMAND_LOG" || { echo 'screenshot lacked liveness probe' >&2; exit 1; }
    mkdir -p "$(dirname "${5-}")"
    printf 'fixture-png' >"${5-}"
    ;;
  *) echo "unexpected simctl command: $command" >&2; exit 1 ;;
esac
SH
chmod +x "$adapter_bin/xcrun"

repo="" base_sha="" head_sha="" contract="" matrix="" draft="" visual="" final=""

write_contract() {
  /usr/bin/ruby -rjson -rtime - "$1" "${2:-valid}" <<'RUBY'
path, mode = ARGV
cases = [
  {"id" => "iphone-en", "testIdentifier" => "TemplateAppUITests/SmokeTests/testLaunch"},
  {"id" => "iphone-ja", "assertion" => {"kind" => "launch-succeeded"}},
  {"id" => "ipad-en", "testIdentifier" => "TemplateAppUITests/SmokeTests/testLaunch"},
  {"id" => "ipad-ja", "assertion" => {"kind" => "launch-succeeded"}}
]
cases.pop if mode == "missing-case"
cases[1] = {"id" => "iphone-ja"} if mode == "missing-action"
cases[1]["testIdentifier"] = "TemplateAppUITests/SmokeTests/testLaunch" if mode == "both-actions"
mappings = [
  {"id" => "AC-1", "checks" => ["stage:build", "stage:unit-tests"]},
  {"id" => "AC-2", "checks" => ["case:iphone-en", "case:iphone-ja", "case:ipad-en", "case:ipad-ja", "visual:iphone-en", "visual:iphone-ja", "visual:ipad-en", "visual:ipad-ja"]}
]
mappings.pop if mode == "missing-mapping"
mappings[1]["checks"] << "case:unknown" if mode == "unknown-mapping"
document = {
  "schemaVersion" => 1, "issue" => 42, "repository" => "yuto1201/iOS-Template",
  "goal" => "Run reproducible iOS verification",
  "specAnchors" => ["docs/verification.md#4-execution-draft"],
  "acceptanceCriteria" => [
    {"id" => "AC-1", "text" => "Build and tests pass once"},
    {"id" => "AC-2", "text" => "Four localized cases pass mechanically"}
  ],
  "dependencies" => [], "externalOperations" => [], "fetchedAt" => Time.now.iso8601,
  "verification" => {"bundleIdentifier" => "com.example.TemplateApp", "cases" => cases, "acceptanceMappings" => mappings}
}
document.delete("verification") if mode == "absent"
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
}

write_matrix() {
  /usr/bin/ruby -rjson -rtime - "$1" "$fake_developer" <<'RUBY'
path, developer = ARGV
rows = [
  ["iphone-en", "iPhone", "en_US", "en", "00000000-0000-0000-0000-000000000001"],
  ["iphone-ja", "iPhone", "ja_JP", "ja", "00000000-0000-0000-0000-000000000002"],
  ["ipad-en", "iPad", "en_US", "en", "00000000-0000-0000-0000-000000000003"],
  ["ipad-ja", "iPad", "ja_JP", "ja", "00000000-0000-0000-0000-000000000004"]
]
document = {
  "schemaVersion" => 1, "batchId" => "runner-fixture", "resolvedAt" => Time.now.iso8601,
  "xcode" => {"path" => developer, "version" => "26.5", "build" => "17F42"},
  "runtime" => {"identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version" => "26.5"},
  "cases" => rows.map do |id, family, locale, language, udid|
    type = family == "iPhone" ? ["com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro"] : ["com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)"]
    {"id" => id, "family" => family, "deviceType" => {"identifier" => type[0], "name" => type[1]}, "locale" => locale, "language" => language, "udid" => udid}
  end
}
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
}

prepare_repo() {
  local label="$1" contract_mode="${2:-valid}"
  repo="$scratch/$label/repository"
  mkdir -p "$repo/TemplateApp.xcodeproj" "$repo/docs"
  repo="$(cd "$repo" && pwd -P)"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Runner Test'
  git -C "$repo" config user.email 'runner@example.invalid'
  printf '%s\n' '.artifacts/' >"$repo/.gitignore"
  printf '%s\n' '{}' >"$repo/TemplateApp.xcodeproj/project.pbxproj"
  printf '%s\n' '# Base' >"$repo/docs/base.md"
  git -C "$repo" add -- .gitignore TemplateApp.xcodeproj docs/base.md
  git -C "$repo" commit -q -m base
  base_sha="$(git -C "$repo" rev-parse HEAD)"
  printf '%s\n' '# Head' >"$repo/docs/head.md"
  git -C "$repo" add -- docs/head.md
  git -C "$repo" commit -q -m head
  head_sha="$(git -C "$repo" rev-parse HEAD)"
  contract="$repo/.artifacts/issues/42/issue-contract.json"
  matrix="$repo/.artifacts/batches/runner-fixture/simulator-matrix.json"
  draft="$repo/.artifacts/issues/42/$head_sha/verify-draft.json"
  visual="$repo/.artifacts/issues/42/$head_sha/visual-result.json"
  final="$repo/.artifacts/issues/42/$head_sha/verify.json"
  mkdir -p "$(dirname "$contract")" "$(dirname "$matrix")" "$(dirname "$draft")"
  write_contract "$contract" "$contract_mode"
  write_matrix "$matrix"
  : >"$fake_log"
}

run_execute() {
  (cd "$repo" && PATH="$poison_bin:/usr/bin:/bin" FAKE_COMMAND_LOG="$fake_log" \
    FAKE_FALLBACK_DEVELOPER_DIR="${FAKE_FALLBACK_DEVELOPER_DIR:-$fake_developer}" \
    FAKE_CONTRACT_PATH="$contract" FAKE_MATRIX_PATH="$matrix" \
    GIT_DIR=/malicious/git-dir GIT_WORK_TREE=/malicious/work-tree GIT_INDEX_FILE=/malicious/index \
    GIT_OBJECT_DIRECTORY=/malicious/objects GIT_ALTERNATE_OBJECT_DIRECTORIES=/malicious/alternates \
    GIT_CONFIG_GLOBAL=/malicious/global GIT_CONFIG_SYSTEM=/malicious/system GIT_CONFIG_NOSYSTEM=0 \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.rev-parse GIT_CONFIG_VALUE_0='!exit 91' \
    DEVELOPER_DIR=/malicious/developer TOOLCHAINS=malicious SDKROOT=/malicious/sdk \
    "$runner" --issue 42 --expected-base "$base_sha" \
      --issue-contract .artifacts/issues/42/issue-contract.json \
      --matrix .artifacts/batches/runner-fixture/simulator-matrix.json \
      --project TemplateApp.xcodeproj --scheme TemplateApp)
}

run_finalize() {
  (cd "$repo" && PATH="$poison_bin:/usr/bin:/bin" FAKE_COMMAND_LOG="$fake_log" \
    GIT_DIR=/malicious/git-dir GIT_WORK_TREE=/malicious/work-tree GIT_INDEX_FILE=/malicious/index \
    GIT_OBJECT_DIRECTORY=/malicious/objects GIT_ALTERNATE_OBJECT_DIRECTORIES=/malicious/alternates \
    GIT_CONFIG_GLOBAL=/malicious/global GIT_CONFIG_SYSTEM=/malicious/system GIT_CONFIG_NOSYSTEM=0 \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.rev-parse GIT_CONFIG_VALUE_0='!exit 91' \
    DEVELOPER_DIR=/malicious/developer TOOLCHAINS=malicious SDKROOT=/malicious/sdk \
    "$runner" --finalize --issue 42 --expected-base "$base_sha" \
      --draft ".artifacts/issues/42/$head_sha/verify-draft.json" \
      --visual-result ".artifacts/issues/42/$head_sha/visual-result.json")
}

expect_execute_failure() {
  local label="$1" diagnostic="$2"
  if run_execute >"$scratch/$label.stdout" 2>"$scratch/$label.stderr"; then
    echo "runner unexpectedly accepted $label" >&2; exit 1
  fi
  grep -Fq -- "$diagnostic" "$scratch/$label.stderr" || {
    echo "runner rejected $label for the wrong reason; expected $diagnostic" >&2
    cat "$scratch/$label.stderr" >&2; exit 1
  }
}

expect_finalize_failure() {
  local label="$1" diagnostic="$2"
  if run_finalize >"$scratch/$label.finalize.stdout" 2>"$scratch/$label.finalize.stderr"; then
    echo "finalizer unexpectedly accepted $label" >&2; exit 1
  fi
  grep -Fq -- "$diagnostic" "$scratch/$label.finalize.stderr" || {
    echo "finalizer rejected $label for the wrong reason; expected $diagnostic" >&2
    cat "$scratch/$label.finalize.stderr" >&2; exit 1
  }
  [[ ! -e "$final" ]] || { echo "failed finalization left verify.json" >&2; exit 1; }
}

write_visual() {
  /usr/bin/ruby -rjson -rtime -rdigest - "$draft" "$visual" "${1:-approved}" <<'RUBY'
draft_path, visual_path, mode = ARGV
draft = JSON.parse(File.read(draft_path))
document = {
  "schemaVersion" => 1, "status" => "approved", "issue" => draft.fetch("issue"),
  "headSha" => draft.fetch("headSha"),
  "draft" => {"path" => ".artifacts/issues/42/#{draft.fetch("headSha")}/verify-draft.json", "digest" => "sha256:#{Digest::SHA256.file(draft_path).hexdigest}"},
  "cases" => draft.fetch("cases").map { |entry| {"id" => entry.fetch("id"), "status" => "approved", "screenshot" => entry.fetch("screenshot"), "findings" => []} },
  "findings" => [], "reviewedAt" => Time.now.iso8601
}
case mode
when "rejected" then document["status"] = "rejected"; document["findings"] = ["layout overlap"]
when "wrong-digest" then document.fetch("draft")["digest"] = "sha256:" + "0" * 64
when "wrong-head" then document["headSha"] = "0" * 40
when "missing-case" then document.fetch("cases").pop
when "case-finding" then document.fetch("cases").fetch(0)["findings"] = ["clipped"]
end
File.write(visual_path, JSON.pretty_generate(document) + "\n")
RUBY
}

# Initial RED: the complete behavioral suite is enabled after this missing-runner assertion passes.
if [[ ! -e "$runner" ]]; then
  prepare_repo red-runner
  expect_execute_failure absent-runner "No such file or directory"
  echo "iOS runner RED tests are ready"
  exit 1
fi

prepare_repo valid
run_execute
[[ ! -s "$poison_log" ]] || { echo "production dispatch used caller PATH" >&2; cat "$poison_log" >&2; exit 1; }
[[ -f "$draft" && ! -e "$final" ]] || { echo "execution did not publish only the draft" >&2; exit 1; }
/usr/bin/ruby -rjson - "$draft" "$head_sha" <<'RUBY'
draft, head = ARGV
document = JSON.parse(File.read(draft))
abort "wrong draft status" unless document["status"] == "awaiting-visual-review"
abort "draft claimed visual approval" if document.key?("visualEvaluation")
abort "wrong Head" unless document["headSha"] == head
abort "wrong cases" unless document["cases"].map { |entry| entry["id"] } == %w[iphone-en iphone-ja ipad-en ipad-ja]
abort "missing AC mappings" unless document["acceptanceEvidence"].map { |entry| entry["id"] } == %w[AC-1 AC-2]
abort "wrong execution AC evidence" unless document["acceptanceEvidence"].map { |entry| entry["evidence"] } == [
  %w[stage:build stage:unit-tests],
  %w[case:iphone-en case:iphone-ja case:ipad-en case:ipad-ja]
]
paths = document.fetch("workspaceArtifacts")
prefix = "/tmp/ios-template-verify/"
abort "DerivedData escaped /tmp" unless paths.fetch("derivedDataPath").start_with?(prefix) && paths.fetch("derivedDataPath").end_with?("/#{head}/DerivedData")
abort "result bundles escaped /tmp" unless %w[buildResultBundlePath testResultBundlePath].all? { |key| paths.fetch(key).start_with?(prefix) && paths.fetch(key).include?("/#{head}/") }
worktree_id = paths.fetch("derivedDataPath").split("/").fetch(3)
abort "worktree ID lacks full physical-root digest" unless worktree_id.match?(/-[0-9a-f]{64}\z/)
RUBY
workspace_root="$(/usr/bin/ruby -rjson -e 'puts File.dirname(JSON.parse(File.read(ARGV[0])).fetch("workspaceArtifacts").fetch("derivedDataPath"))' "$draft")"
[[ "$(/usr/bin/stat -f '%Lp' "$workspace_root")" == 700 ]] || { echo "workspace is not mode 0700" >&2; exit 1; }

build_count="$(awk -F '\t' '$1 == "xcodebuild" && $0 ~ /\tbuild$/ {count++} END {print count+0}' "$fake_log")"
unit_count="$(awk -F '\t' '$1 == "xcodebuild" && $0 ~ /\ttest$/ {count++} END {print count+0}' "$fake_log")"
ui_count="$(awk -F '\t' '$1 == "xcodebuild" && $0 ~ /\ttest-without-building$/ {count++} END {print count+0}' "$fake_log")"
[[ "$build_count" == 1 && "$unit_count" == 1 && "$ui_count" == 2 ]] || { echo "wrong Build/Test invocation counts" >&2; cat "$fake_log" >&2; exit 1; }
/usr/bin/ruby - "$fake_log" "$fake_developer" <<'RUBY'
path = ARGV.fetch(0)
case_for = {
  "00000000-0000-0000-0000-000000000001" => "iphone-en",
  "00000000-0000-0000-0000-000000000002" => "iphone-ja",
  "00000000-0000-0000-0000-000000000003" => "ipad-en",
  "00000000-0000-0000-0000-000000000004" => "ipad-ja"
}
actual = File.readlines(path, chomp: true).each_with_object([]) do |line, sequence|
  fields = line.split("\t")
  next unless fields[1] == "DEVELOPER_DIR=#{ARGV.fetch(1)}"
  if fields[0] == "xcodebuild"
    if fields[2..] == ["-version"]
      sequence << "xcode-version"
      next
    elsif fields.last == "build"
      sequence << "build"
      next
    elsif fields.last == "test"
      sequence << "unit-test"
      next
    end
    if fields.last == "test-without-building"
      udid = fields.fetch(fields.index("-destination") + 1).split("id=", 2).last
      sequence << "#{case_for.fetch(udid)}-ui-test"
      next
    end
  elsif fields[0] == "xcrun" && fields[2] == "xcresulttool"
    result_path = fields.fetch(fields.index("--path") + 1)
    result_label = if result_path.end_with?("/Build.xcresult")
      "build"
    elsif result_path.end_with?("/Tests.xcresult")
      "unit"
    elsif result_path.include?("/Cases/iphone-en.xcresult")
      "iphone-en"
    elsif result_path.include?("/Cases/ipad-en.xcresult")
      "ipad-en"
    else
      raise "unknown xcresult path #{result_path}"
    end
    operation = fields[4] == "build-results" ? "diagnostics" : "summary"
    sequence << "#{result_label}-#{operation}"
    next
  elsif fields[0] == "xcrun" && fields[2] == "simctl"
    command = fields.fetch(3)
    udid = fields.fetch(4)
    label = command == "io" ? "screenshot" : command
    sequence << "#{case_for.fetch(udid)}-#{label}"
    next
  end
end
expected = %w[
  xcode-version build build-diagnostics unit-test unit-diagnostics unit-summary
  iphone-en-boot iphone-en-bootstatus iphone-en-install iphone-en-terminate iphone-en-launch iphone-en-spawn iphone-en-ui-test iphone-en-diagnostics iphone-en-summary iphone-en-screenshot iphone-en-terminate
  iphone-ja-boot iphone-ja-bootstatus iphone-ja-install iphone-ja-terminate iphone-ja-launch iphone-ja-spawn iphone-ja-screenshot iphone-ja-terminate
  ipad-en-boot ipad-en-bootstatus ipad-en-install ipad-en-terminate ipad-en-launch ipad-en-spawn ipad-en-ui-test ipad-en-diagnostics ipad-en-summary ipad-en-screenshot ipad-en-terminate
  ipad-ja-boot ipad-ja-bootstatus ipad-ja-install ipad-ja-terminate ipad-ja-launch ipad-ja-spawn ipad-ja-screenshot ipad-ja-terminate
]
abort "unexpected Xcode/Simulator command order:\n#{actual.join("\n")}" unless actual == expected
RUBY
[[ "$(grep -c $'^xcrun\t.*\tsimctl\tlaunch\t' "$fake_log")" == 4 ]] || { echo "wrong locale launch count" >&2; exit 1; }
grep -q -- $'-AppleLanguages\t(en)' "$fake_log"
grep -q -- $'-AppleLanguages\t(ja)' "$fake_log"
grep -q -- $'-AppleLocale\ten_US' "$fake_log"
grep -q -- $'-AppleLocale\tja_JP' "$fake_log"
if rg -n '/\.artifacts/.*DerivedData|-derivedDataPath[[:space:]]+\.artifacts' "$fake_log"; then
  echo "runner used repository-local DerivedData" >&2; exit 1
fi
if ! /usr/bin/awk -F '\t' -v expected="DEVELOPER_DIR=$fake_developer" '($1 == "xcodebuild" || $1 == "xcrun") && $2 != expected {bad=1} END {exit bad}' "$fake_log"; then
  echo "an Xcode command lacked command-scoped DEVELOPER_DIR" >&2
  cat "$fake_log" >&2
  exit 1
fi

write_visual approved
run_finalize
[[ -f "$final" ]] || { echo "finalizer did not publish verify.json" >&2; exit 1; }
[[ ! -s "$poison_log" ]] || { echo "finalizer dispatch used caller PATH" >&2; cat "$poison_log" >&2; exit 1; }
(cd "$repo" && swift "$source_repo/tools/validate-verify-json.swift" --file "$final" --expected-issue 42 --expected-base "$base_sha" --expected-head "$head_sha")

for mode in absent missing-case missing-action both-actions missing-mapping unknown-mapping; do
  prepare_repo "contract-$mode" "$mode"
  expect_execute_failure "contract-$mode" "verification"
  [[ ! -s "$fake_log" ]] || { echo "invalid contract reached Xcode for $mode" >&2; cat "$fake_log" >&2; exit 1; }
done

prepare_repo dirty-range
printf '%s\n' dirty >>"$repo/docs/head.md"
expect_execute_failure dirty-range "working tree must be clean"
[[ ! -s "$fake_log" ]] || { echo "dirty range reached Xcode" >&2; exit 1; }

prepare_repo warning
FAKE_BUILD_MODE=warning expect_execute_failure warning "build warnings are not allowed"
[[ ! -e "$draft" ]] || { echo "warning failure published draft" >&2; exit 1; }

for mode in failed skipped zero command-fail; do
  prepare_repo "tests-$mode"
  FAKE_TEST_MODE="$mode" expect_execute_failure "tests-$mode" "unit tests"
  [[ ! -e "$draft" ]] || { echo "test failure published draft" >&2; exit 1; }
done

prepare_repo tests-warning
FAKE_TEST_MODE=warning expect_execute_failure tests-warning "unit test warnings are not allowed"
[[ ! -e "$draft" ]] || { echo "unit-test warning published draft" >&2; exit 1; }

for mode in zero skipped warning; do
  prepare_repo "ui-$mode"
  FAKE_UI_MODE="$mode" expect_execute_failure "ui-$mode" "case iphone-en failed"
  [[ ! -e "$draft" ]] || { echo "invalid UI result published draft" >&2; exit 1; }
done

prepare_repo build-failure
printf '%s\n' sentinel >"$draft"
FAKE_BUILD_MODE=fail expect_execute_failure build-failure "build command failed"
grep -Fq sentinel "$draft" || { echo "failed execution replaced existing draft" >&2; exit 1; }
failure_count="$(find "$(dirname "$draft")/failures" -type f -name '*.json' | wc -l | tr -d ' ')"
FAKE_BUILD_MODE=fail expect_execute_failure build-failure-repeat "build command failed"
new_failure_count="$(find "$(dirname "$draft")/failures" -type f -name '*.json' | wc -l | tr -d ' ')"
[[ "$new_failure_count" -gt "$failure_count" ]] || { echo "failure records are not unique" >&2; exit 1; }
if rg -n 'TOKEN-super-secret|configured build failure' "$(dirname "$draft")/failures"; then
  echo "failure record leaked command output" >&2; exit 1
fi

for source in contract matrix; do
  prepare_repo "mutated-$source"
  FAKE_MUTATE_INPUT="$source" expect_execute_failure "mutated-$source" "$source changed during verification"
  [[ ! -e "$draft" ]] || { echo "mutated input published draft" >&2; exit 1; }
done

prepare_repo case-failure
FAKE_CASE_MODE=launch-fail expect_execute_failure case-failure "case iphone-ja failed"
[[ ! -e "$draft" ]] || { echo "case failure published draft" >&2; exit 1; }
/usr/bin/awk -F '\t' '$3 == "simctl" && $4 == "terminate" && $5 == "00000000-0000-0000-0000-000000000002" {count++} END {exit count >= 2 ? 0 : 1}' "$fake_log" || { echo "case failure did not terminate active app" >&2; exit 1; }

prepare_repo case-crash
FAKE_CASE_MODE=crash expect_execute_failure case-crash "case iphone-ja failed"

prepare_repo app-plist-symlink
FAKE_BUILD_MODE=plist-symlink expect_execute_failure app-plist-symlink "built application"

prepare_repo draft-collision
FAKE_COLLIDE_DRAFT=1 expect_execute_failure draft-collision "atomic draft publication failed"
grep -Fq sentinel-draft "$draft" || { echo "draft collision replaced the winner" >&2; exit 1; }

prepare_repo concurrent-lock
hold_file="$scratch/concurrent-hold"
FAKE_HOLD_BUILD_FILE="$hold_file" run_execute >"$scratch/concurrent-first.stdout" 2>"$scratch/concurrent-first.stderr" &
first_runner_pid=$!
for _ in $(/usr/bin/jot 100); do
  [[ ! -e "$hold_file.started" ]] || break
  /bin/sleep 0.05
done
[[ -e "$hold_file.started" ]] || { echo "first concurrent runner did not reach Build" >&2; exit 1; }
expect_execute_failure concurrent-lock "lock"
: >"$hold_file.release"
wait "$first_runner_pid"
[[ -f "$draft" ]] || { echo "concurrent lock winner did not publish draft" >&2; exit 1; }

prepare_repo prebooted
FAKE_PREBOOTED=1 run_execute

prepare_repo fallback
fallback_developer="$scratch/FallbackXcode/Contents/Developer"
mkdir -p "$fallback_developer/usr/bin" "$fallback_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
/bin/cp "$fake_developer/usr/bin/xcodebuild" "$fallback_developer/usr/bin/xcodebuild"
/bin/cp "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" "$fallback_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
/usr/bin/ruby -rjson - "$matrix" "$fallback_developer" <<'RUBY'
path, developer = ARGV
document = JSON.parse(File.read(path))
document.fetch("xcode")["path"] = developer
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
FAKE_PREFERRED_XCODE_INVALID=1 FAKE_FALLBACK_DEVELOPER_DIR="$fallback_developer" run_execute
grep -Fq $'xcode-select\tDEVELOPER_DIR=\t-p' "$fake_log"
/usr/bin/awk -F '\t' -v expected="DEVELOPER_DIR=$fallback_developer" '$1 == "xcodebuild" || $1 == "xcrun" {last=$2} END {exit last == expected ? 0 : 1}' "$fake_log"

for mode in rejected wrong-digest wrong-head missing-case case-finding; do
  prepare_repo "final-$mode"
  run_execute
  write_visual "$mode"
  expect_finalize_failure "final-$mode" "visual"
done

prepare_repo draft-mutation
run_execute
write_visual approved
printf '\n' >>"$draft"
expect_finalize_failure draft-mutation "draft digest"

prepare_repo draft-nested-schema-mutation
run_execute
/usr/bin/ruby -rjson - "$draft" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.read(path))
document.fetch("build")["unexpected"] = true
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
write_visual approved
expect_finalize_failure draft-nested-schema-mutation "visual"

prepare_repo draft-mechanical-mutation
run_execute
/usr/bin/ruby -rjson - "$draft" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.read(path))
document.fetch("cases").fetch(0)["mechanicalCheck"] = "assertion:launch-succeeded"
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
write_visual approved
expect_finalize_failure draft-mechanical-mutation "visual"

prepare_repo draft-mapping-mutation
run_execute
/usr/bin/ruby -rjson - "$draft" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.read(path))
document.fetch("acceptanceEvidence").fetch(0)["evidence"] = ["case:iphone-en"]
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
write_visual approved
expect_finalize_failure draft-mapping-mutation "visual"

prepare_repo canonical-contract-mutation
run_execute
write_visual approved
printf '\n' >>"$contract"
expect_finalize_failure canonical-contract-mutation "visual"

prepare_repo final-collision
run_execute
write_visual approved
if FAKE_COLLIDE_FINAL=1 run_finalize >"$scratch/final-collision.stdout" 2>"$scratch/final-collision.stderr"; then
  echo "finalizer replaced an existing canonical winner" >&2; exit 1
fi
grep -Fq "strict schema validation" "$scratch/final-collision.stderr"
grep -Fq sentinel-final "$final" || { echo "final collision changed the winner" >&2; exit 1; }

prepare_repo stale-head
run_execute
write_visual approved
printf '%s\n' '# New head' >"$repo/docs/new-head.md"
git -C "$repo" add -- docs/new-head.md
git -C "$repo" commit -q -m new-head
expect_finalize_failure stale-head "current Git Head"

prepare_repo canonical-paths
run_execute
write_visual approved
if (cd "$repo" && "$runner" --finalize --issue 42 --expected-base "$base_sha" --draft "$draft" --visual-result "$visual") >"$scratch/path.stdout" 2>"$scratch/path.stderr"; then
  echo "finalizer accepted absolute non-interface paths" >&2; exit 1
fi
grep -Fq "canonical" "$scratch/path.stderr"

if find "$scratch" -name '*.tmp' -o -name '.verify-*' | rg -q .; then
  echo "runner left publication temporary files" >&2; exit 1
fi

echo "all iOS runner tests passed"
