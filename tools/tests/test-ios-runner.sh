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
poison_sentinel="$scratch/poison-sentinel"
git_policy_sentinel="$scratch/git-policy-sentinel"
adapter_state="$scratch/adapter-state"
test_source="$scratch/test-source"
runner="$test_source/tools/verify-ios-issue.sh"
mkdir -p "$adapter_bin" "$poison_bin" "$adapter_state" "$fake_developer/usr/bin" \
  "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin" "$test_source/tools/lib"
/bin/cp "$source_repo/tools/verify-ios-issue.sh" "$runner"
/bin/cp "$source_repo/tools/lib/xcode.sh" "$test_source/tools/lib/xcode.sh"
/bin/cp "$source_repo/tools/validate-verify-json.swift" "$test_source/tools/validate-verify-json.swift"
/usr/bin/ruby - "$test_source/tools/validate-verify-json.swift" "$adapter_state" <<'RUBY'
path, state_dir = ARGV
text = File.read(path)
helper = <<~SWIFT
func round3TestPublicationRace() {
    let modePath = "#{state_dir}/publication_race"
    let markerPath = "#{state_dir}/publication-race-fired"
    guard !FileManager.default.fileExists(atPath: markerPath),
          let mode = try? String(contentsOfFile: modePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          ["contract", "matrix", "candidate", "image-bytes", "image-set", "packet", "visual-result"].contains(mode),
          let target = try? String(contentsOfFile: "#{state_dir}/" + mode + "_path", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          !target.isEmpty,
          FileManager.default.createFile(atPath: markerPath, contents: Data(), attributes: nil) else { return }
    if mode == "candidate" {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: target),
              let name = names.first(where: { $0.hasPrefix(".verify-candidate-") }) else { return }
        let path = target + "/" + name
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try? FileManager.default.removeItem(atPath: path)
        _ = FileManager.default.createFile(atPath: path, contents: Data("substituted-candidate\\n".utf8), attributes: [.posixPermissions: 0o400])
        return
    }
    if mode == "image-set" {
        _ = FileManager.default.createFile(
            atPath: target + "/late-state.png", contents: Data("late-state\\n".utf8), attributes: nil
        )
        return
    }
    if mode == "packet" {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
        guard let file = FileHandle(forWritingAtPath: target) else { return }
        file.seekToEndOfFile()
        file.write(Data("\\n".utf8))
        try? file.synchronize()
        try? file.close()
        try? FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target)
        return
    }
    if mode == "visual-result" {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target)),
              var document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        document["status"] = "rejected"
        document["findings"] = ["approval withdrawn"]
        guard let changed = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? (changed + Data("\\n".utf8)).write(to: URL(fileURLWithPath: target), options: [.atomic])
        return
    }
    guard let file = FileHandle(forWritingAtPath: target) else { return }
    file.seekToEndOfFile()
    file.write(Data("\\n".utf8))
    try? file.synchronize()
    try? file.close()
}

func round4TestKillDuringDraftPublication() {
    let modePath = "#{state_dir}/publication_kill"
    let markerPath = "#{state_dir}/publication-kill-fired"
    guard !FileManager.default.fileExists(atPath: markerPath),
          let mode = try? String(contentsOfFile: modePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          mode == "1",
          FileManager.default.createFile(atPath: markerPath, contents: Data(), attributes: nil) else { return }
    _ = kill(getpid(), SIGKILL)
}

func round5TestKillBeforePublication(_ canonicalName: String) {
    let modePath = "#{state_dir}/publication_kill_target"
    guard let target = try? String(contentsOfFile: modePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          !target.isEmpty, target == canonicalName else { return }
    let markerPath = "#{state_dir}/publication-kill-" + target.replacingOccurrences(of: "/", with: "-")
    guard !FileManager.default.fileExists(atPath: markerPath),
          FileManager.default.createFile(atPath: markerPath, contents: Data(), attributes: nil) else { return }
    _ = kill(getpid(), SIGKILL)
}

func completionTestKillAfterPublication(_ canonicalName: String) {
    let modePath = "#{state_dir}/publication_kill_after_target"
    guard let target = try? String(contentsOfFile: modePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          !target.isEmpty, target == canonicalName else { return }
    let markerPath = "#{state_dir}/publication-kill-after-" + target.replacingOccurrences(of: "/", with: "-")
    guard !FileManager.default.fileExists(atPath: markerPath),
          FileManager.default.createFile(atPath: markerPath, contents: Data(), attributes: nil) else { return }
    _ = kill(getpid(), SIGKILL)
}

SWIFT
text.sub!("typealias JSONObject", helper + "typealias JSONObject")
text.gsub!("publishedScreenshotCount += 1", "publishedScreenshotCount += 1\n            round4TestKillDuringDraftPublication()")
text.gsub!("guard renameatx_np(\n        directoryFileDescriptor", "round5TestKillBeforePublication(canonicalName)\n    guard renameatx_np(\n        directoryFileDescriptor")
if text.include?("if renameatx_np(directory, candidateName")
  text.gsub!("if renameatx_np(directory, candidateName", "round5TestKillBeforePublication(\"verify.json\")\n    if renameatx_np(directory, candidateName")
else
  text.gsub!("guard renameatx_np(directory, candidateName", "round5TestKillBeforePublication(\"verify.json\")\n    guard renameatx_np(directory, candidateName")
end
text.gsub!("    let published = openat(directoryFileDescriptor, canonicalName", "    completionTestKillAfterPublication(canonicalName)\n    let published = openat(directoryFileDescriptor, canonicalName")
text.gsub!("    let published = openat(directory, \"verify.json\"", "    completionTestKillAfterPublication(\"verify.json\")\n    let published = openat(directory, \"verify.json\"")
if text.include?("try beforeLink()")
  text.gsub!("try beforeLink()", "round3TestPublicationRace()\n    try beforeLink()")
else
  text.gsub!("guard linkat(", "round3TestPublicationRace()\n    guard linkat(")
end
File.write(path, text)
RUBY
validator_binary="$scratch/validate-verify-json"
/usr/bin/swiftc "$test_source/tools/validate-verify-json.swift" -o "$validator_binary"

# This is a test-only compiled copy: production constants are textually replaced with
# absolute adapters. If the constants disappear, the poison PATH below catches it.
/usr/bin/sed -i '' \
  -e "s|^TRUSTED_XCODE_SELECT=.*|TRUSTED_XCODE_SELECT=\"$adapter_bin/xcode-select\"|" \
  -e "s|^TRUSTED_XCRUN=.*|TRUSTED_XCRUN=\"$adapter_bin/xcrun\"|" \
  -e "s|^PREFERRED_DEVELOPER_DIR=.*|PREFERRED_DEVELOPER_DIR=\"$fake_developer\"|" \
  "$test_source/tools/lib/xcode.sh"

for poisoned in bash dirname git xcode-select xcrun xcodebuild swift; do
  /usr/bin/sed "s|@NAME@|$poisoned|g; s|@LOG@|$poison_log|g" >"$poison_bin/$poisoned" <<'SH'
#!/bin/sh
printf '%s\n' '@NAME@' >>'@LOG@'
exit 97
SH
  chmod +x "$poison_bin/$poisoned"
done

poison_ruby="$scratch/poison-ruby.rb"
poison_tool="$scratch/poison-tool"
poison_bash_env="$scratch/poison-bash-env.sh"
/usr/bin/sed "s|@SENTINEL@|$poison_sentinel|g" >"$poison_ruby" <<'RUBY'
File.open("@SENTINEL@", "a") { |file| file.puts("ruby-environment-executed") }
RUBY
/usr/bin/sed "s|@SENTINEL@|$poison_sentinel|g" >"$poison_tool" <<'SH'
#!/bin/bash -p
printf '%s\n' poison-tool-executed >>'@SENTINEL@'
exit 98
SH
chmod +x "$poison_tool"
/usr/bin/sed "s|@SENTINEL@|$poison_sentinel|g" >"$poison_bash_env" <<'SH'
printf '%s\n' bash-env-executed >>'@SENTINEL@'
SH

set_state() {
  local key="$1" value="$2"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value" >"$adapter_state/$key"
  else
    /bin/rm -f "$adapter_state/$key"
  fi
}

cat >"$adapter_bin/xcode-select" <<'SH'
#!/bin/bash -p
set -euo pipefail
state_dir="@STATE_DIR@" fake_log="@FAKE_LOG@"
state() { [[ -f "$state_dir/$1" ]] && /bin/cat "$state_dir/$1" || true; }
for variable in "${!GIT_@}"; do echo "xcode-select environment retained $variable" >&2; exit 1; done
[[ -z "${DEVELOPER_DIR-}${TOOLCHAINS-}${SDKROOT-}" ]] || { echo 'xcode-select environment was not scrubbed' >&2; exit 1; }
printf 'xcode-select\tDEVELOPER_DIR=%s\t%s\n' "${DEVELOPER_DIR-}" "$*" >>"$fake_log"
[[ "$#" -eq 1 && "$1" == "-p" ]]
state fallback_developer
SH
chmod +x "$adapter_bin/xcode-select"

cat >"$fake_developer/usr/bin/xcodebuild" <<'SH'
#!/bin/bash -p
set -euo pipefail
state_dir="@STATE_DIR@" fake_log="@FAKE_LOG@"
state() { [[ -f "$state_dir/$1" ]] && /bin/cat "$state_dir/$1" || true; }
for variable in "${!GIT_@}"; do echo "xcodebuild environment retained $variable" >&2; exit 1; done
[[ -z "${TOOLCHAINS-}${SDKROOT-}" ]] || { echo 'xcodebuild environment was not scrubbed' >&2; exit 1; }
{
  printf 'xcodebuild\tDEVELOPER_DIR=%s' "${DEVELOPER_DIR-}"
  printf '\t%s' "$@"
  printf '\n'
} >>"$fake_log"
if [[ "$#" -eq 1 && "$1" == "-version" ]]; then
  if [[ "$(state preferred_invalid)" == 1 && "${DEVELOPER_DIR-}" == *"/FakeXcode/Contents/Developer" ]]; then
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
    build-for-testing) mode="build-for-testing" ;;
    test-without-building) mode="ui-test" ;;
  esac
done
[[ "$mode" != build ]] || { echo 'plain build is forbidden' >&2; exit 1; }
if [[ "$mode" == build-for-testing ]]; then
  [[ "$(state build_mode)" != fail ]] || { echo "configured build failure TOKEN-super-secret" >&2; exit 1; }
  derived="" result="" destination="" parallel="" project="" previous="" destination_count=0
  for argument in "$@"; do
    [[ "$previous" != -project ]] || project="$argument"
    [[ "$previous" != -derivedDataPath ]] || derived="$argument"
    [[ "$previous" != -resultBundlePath ]] || result="$argument"
    if [[ "$previous" == -destination ]]; then destination="$argument"; destination_count=$((destination_count + 1)); fi
    [[ "$previous" != -parallel-testing-enabled ]] || parallel="$argument"
    previous="$argument"
  done
  [[ "$project" == */Source/TemplateApp.xcodeproj ]] || { echo 'build did not use the private raw-Head source snapshot' >&2; exit 1; }
  source_root="${project%/TemplateApp.xcodeproj}"
  [[ "$(/bin/pwd -P)" == "$(builtin cd "$source_root" && /bin/pwd -P)" ]] || { echo 'xcodebuild cwd escaped the private raw-Head source snapshot' >&2; exit 1; }
  [[ "$(/bin/cat "$source_root/Sources/App.swift")" == HEAD-SOURCE ]] || { echo 'raw-Head source snapshot is incomplete' >&2; exit 1; }
  [[ "$(/bin/cat "$source_root/Config/App.xcconfig")" == HEAD-CONFIG ]] || { echo 'raw-Head config snapshot is incomplete' >&2; exit 1; }
  [[ ! -e "$source_root/Sources/Ignored.swift" ]] || { echo 'ignored source entered raw-Head snapshot' >&2; exit 1; }
  mutate_path="$(state mutate_worktree_path)"
  [[ "$(state mutate_worktree)" != 1 || -z "$mutate_path" ]] || printf '%s\n' MUTATED-WORKTREE >"$mutate_path"
  [[ "$parallel" == NO && "$destination_count" == 1 && "$destination" == *id=00000000-0000-0000-0000-000000000001 ]] || { echo 'build destination or parallel setting is invalid' >&2; exit 1; }
  app="$derived/Build/Products/Debug-iphonesimulator/TemplateApp.app"
  mkdir -p "$app" "$result"
  plist='<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.TemplateApp</string><key>CFBundleExecutable</key><string>TemplateApp</string></dict></plist>'
  if [[ "$(state build_mode)" == plist-symlink ]]; then
    printf '%s\n' "$plist" >"$derived/outside-info.plist"
    /bin/ln -s "$derived/outside-info.plist" "$app/Info.plist"
  else
    printf '%s\n' "$plist" >"$app/Info.plist"
  fi
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$app/TemplateApp"
  chmod 0700 "$app/TemplateApp"
  case "$(state app_mode)" in
    nested-symlink)
      mkdir -p "$app/Resources"
      printf '%s\n' outside >"$derived/outside-resource"
      /bin/ln -s "$derived/outside-resource" "$app/Resources/linked-resource"
      ;;
    special-file)
      mkdir -p "$app/Resources"
      /usr/bin/mkfifo "$app/Resources/unsupported.fifo"
      ;;
    structural-collision)
      /usr/bin/ruby --disable-gems -e 'File.binwrite(ARGV.fetch(0), "F\0b\0X")' "$app/a"
      ;;
  esac
  hold_file="$(state hold_file)"
  if [[ -n "$hold_file" ]]; then
    printf '%s\n' "$PPID" >"$hold_file.owner"
    : >"$hold_file.started"
    while [[ ! -e "$hold_file.release" ]]; do /bin/sleep 0.05; done
  fi
  [[ "$(state mutate_input)" != contract ]] || printf '\n' >>"$(state contract_path)"
  [[ "$(state mutate_input)" != matrix ]] || printf '\n' >>"$(state matrix_path)"
  exit 0
fi
[[ "$mode" == ui-test ]] || { echo 'unexpected xcodebuild arguments' >&2; exit 1; }
destination="" identifier="" language="" region="" result="" project="" previous=""
parallel="" destination_count=0
for argument in "$@"; do
  [[ "$previous" != -project ]] || project="$argument"
  if [[ "$previous" == -destination ]]; then destination="$argument"; destination_count=$((destination_count + 1)); fi
  [[ "$previous" != -testLanguage ]] || language="$argument"
  [[ "$previous" != -testRegion ]] || region="$argument"
  [[ "$previous" != -resultBundlePath ]] || result="$argument"
  [[ "$previous" != -parallel-testing-enabled ]] || parallel="$argument"
  [[ "$argument" != -only-testing:* ]] || identifier="${argument#-only-testing:}"
  previous="$argument"
done
[[ "$parallel" == NO && "$destination_count" == 1 ]] || { echo 'parallel testing or destination count is invalid' >&2; exit 1; }
[[ "$project" == */Source/TemplateApp.xcodeproj ]] || { echo 'test did not use the private raw-Head source snapshot' >&2; exit 1; }
source_root="${project%/TemplateApp.xcodeproj}"
[[ "$(/bin/pwd -P)" == "$(builtin cd "$source_root" && /bin/pwd -P)" ]] || { echo 'test cwd escaped the private raw-Head source snapshot' >&2; exit 1; }
  if [[ "$identifier" == TemplateAppTests/UnitSmokeTests/testUnit\(\) ]]; then
  [[ "$(state test_mode)" != command-fail ]] || { echo 'configured unit test command failure' >&2; exit 1; }
  [[ "$destination" == *id=00000000-0000-0000-0000-000000000001 ]] || { echo 'wrong unit destination' >&2; exit 1; }
  [[ -z "$language$region" && "$result" == */Tests.xcresult ]] || { echo 'unit stage included UI locale or wrong result' >&2; exit 1; }
  mkdir -p "$result"
  if [[ "$(state config_mode)" == mutate ]]; then
    workspace="$(dirname "$result")"
    config="$workspace/config.json"
    [[ -n "$config" ]] || { echo 'runner config not found for mutation' >&2; exit 1; }
    /bin/chmod 0600 "$config"
    printf '\n' >>"$config"
  fi
  echo "Test Suite 'Selected unit test' passed"
  exit 0
fi
[[ "$(state ui_mode)" != fail ]] || { echo 'configured UI test failure' >&2; exit 1; }
case "$destination" in
  *id=00000000-0000-0000-0000-000000000001) expected_case=iphone-en; expected_language=en; expected_region=US ;;
  *id=00000000-0000-0000-0000-000000000003) expected_case=ipad-en; expected_language=en; expected_region=US ;;
  *) echo 'wrong UI destination' >&2; exit 1 ;;
esac
[[ "$identifier" == TemplateAppUITests/SmokeTests/testLaunch ]] || { echo 'wrong UI identifier' >&2; exit 1; }
[[ "$language" == "$expected_language" && "$region" == "$expected_region" ]] || { echo 'wrong UI locale' >&2; exit 1; }
[[ "$result" == */Cases/"$expected_case".xcresult ]] || { echo 'wrong or missing UI result path' >&2; exit 1; }
mkdir -p "$result"
[[ "$(state case_mode)" != pid-replacement ]] || : >"$state_dir/ui-ran-$expected_case"
echo "Test Suite 'Selected tests' passed"
SH
chmod +x "$fake_developer/usr/bin/xcodebuild"

cat >"$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" <<'SH'
#!/bin/bash -p
set -euo pipefail
state_dir="@STATE_DIR@"
validator_binary="@VALIDATOR_BINARY@"
state() { [[ -f "$state_dir/$1" ]] && /bin/cat "$state_dir/$1" || true; }
[[ "${0##*/}" == swift ]] || {
  echo 'Swift frontend was invoked directly instead of the Swift driver symlink' >&2
  exit 1
}
run_swift() {
  if [[ "${1-}" == */validate-verify-json.swift ]]; then
    shift
    "$validator_binary" "$@"
  else
    /usr/bin/swift "$@"
  fi
}
for variable in "${!GIT_@}"; do echo "Swift environment retained $variable" >&2; exit 1; done
[[ -z "${TOOLCHAINS-}${SDKROOT-}" ]] || { echo 'Swift environment was not scrubbed' >&2; exit 1; }
unset DEVELOPER_DIR TOOLCHAINS SDKROOT
if [[ " $* " == *" --runner-check-inputs "* && "$(state collide_draft)" == 1 ]]; then
  run_swift "$@"
  collision="$(pwd -P)/.artifacts/issues/42/$(/usr/bin/git rev-parse HEAD)/verify-draft.json"
  mkdir -p "$(dirname "$collision")"
  printf '%s\n' sentinel-draft >"$collision"
  exit 0
fi
if [[ " $* " == *" --runner-finalize "* && "$(state collide_final)" == 1 ]]; then
  head="" issue="" previous=""
  for argument in "$@"; do
    [[ "$previous" != --expected-head ]] || head="$argument"
    [[ "$previous" != --issue ]] || issue="$argument"
    previous="$argument"
  done
  target="$(pwd -P)/.artifacts/issues/$issue/$head/verify.json"
  printf '%s\n' sentinel-final >"$target"
fi
if [[ "$(state candidate_mode)" == substitute && " $* " == *" --runner-finalize "* ]]; then
  head="" issue="" previous=""
  for argument in "$@"; do
    [[ "$previous" != --expected-head ]] || head="$argument"
    [[ "$previous" != --issue ]] || issue="$argument"
    previous="$argument"
  done
  directory="$(pwd -P)/.artifacts/issues/$issue/$head"
  run_swift "$@" & validator_pid=$!
  candidate=""
  for _ in $(/usr/bin/jot 400); do
    candidate="$(/usr/bin/find "$directory" -maxdepth 1 -name '.verify-candidate-*' -type f -print -quit 2>/dev/null || true)"
    [[ -z "$candidate" ]] || break
    /bin/sleep 0.005
  done
  if [[ -f "$candidate" ]]; then
    /bin/chmod 0600 "$candidate"
    printf '%s\n' substituted-candidate >"$candidate"
    /bin/chmod 0400 "$candidate"
  fi
  wait "$validator_pid"
  exit $?
fi
run_swift "$@"
SH
chmod +x "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
/bin/mv "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" \
  "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"
/bin/ln -s swift-frontend "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

cat >"$adapter_bin/xcrun" <<'SH'
#!/bin/bash -p
set -euo pipefail
state_dir="@STATE_DIR@" fake_log="@FAKE_LOG@"
state() { [[ -f "$state_dir/$1" ]] && /bin/cat "$state_dir/$1" || true; }
for variable in "${!GIT_@}"; do echo "xcrun environment retained $variable" >&2; exit 1; done
[[ -z "${TOOLCHAINS-}${SDKROOT-}" ]] || { echo 'xcrun environment was not scrubbed' >&2; exit 1; }
{
  printf 'xcrun\tDEVELOPER_DIR=%s' "${DEVELOPER_DIR-}"
  printf '\t%s' "$@"
  printf '\n'
} >>"$fake_log"
if [[ "${1-}" == xcresulttool ]]; then
  result_path="" previous=""
  for argument in "$@"; do
    [[ "$previous" != --path ]] || result_path="$argument"
    previous="$argument"
  done
  [[ -n "$result_path" ]] || { echo 'missing xcresult path' >&2; exit 1; }
  if [[ "${3-}" == build-results ]]; then
    warnings=0 errors=0 status=succeeded
    case "$result_path" in
      */Build.xcresult) [[ "$(state build_mode)" != warning ]] || warnings=1 ;;
      */Tests.xcresult) status=notRequested; [[ "$(state test_mode)" != warning ]] || warnings=1 ;;
      */Cases/*.xcresult) status=notRequested; [[ "$(state ui_mode)" != warning ]] || warnings=1 ;;
      *) echo 'unexpected diagnostics result path' >&2; exit 1 ;;
    esac
    printf '{"status":"%s","analyzerWarningCount":0,"errorCount":%s,"warningCount":%s,"analyzerWarnings":[],"warnings":[],"errors":[]}\n' "$status" "$errors" "$warnings"
    exit 0
  fi
  [[ "${2-}" == get && "${3-}" == test-results ]] || { echo 'unexpected xcresulttool query' >&2; exit 1; }
  if [[ "$result_path" == */Tests.xcresult ]]; then
    passed=1 failed=0 skipped=0 total=1 udid=00000000-0000-0000-0000-000000000001
    selected_target=TemplateAppTests selected_class=UnitSmokeTests selected_method=testUnit selected_url_method='testUnit()'
    case "$(state test_mode)" in
      failed) passed=0; failed=1 ;;
      skipped) passed=0; skipped=1 ;;
      zero) passed=0; total=0 ;;
      two-summary) passed=2; total=2 ;;
      wrong-selector) selected_method=anotherTest; selected_url_method='anotherTest()' ;;
    esac
  else
    passed=1 failed=0 skipped=0 total=1
    selected_target=TemplateAppUITests selected_class=SmokeTests selected_method=testLaunch selected_url_method=testLaunch
    case "$result_path" in
      */Cases/iphone-en.xcresult) udid=00000000-0000-0000-0000-000000000001 ;;
      */Cases/ipad-en.xcresult) udid=00000000-0000-0000-0000-000000000003 ;;
      *) echo 'unexpected UI summary result path' >&2; exit 1 ;;
    esac
    case "$(state ui_mode)" in
      zero) passed=0; total=0 ;;
      skipped) passed=0; skipped=1 ;;
      wrong-selector) selected_method=anotherTest; selected_url_method=anotherTest ;;
    esac
  fi
  if [[ "${4-}" == summary ]]; then
    printf '{"devicesAndConfigurations":[{"device":{"architecture":"arm64","deviceId":"%s","deviceName":"fixture","modelName":"fixture","osBuildNumber":"23F77","osVersion":"26.5","platform":"iOS Simulator"},"expectedFailures":0,"failedTests":%s,"passedTests":%s,"skippedTests":%s,"testPlanConfiguration":{"configurationId":"1","configurationName":"Test Scheme Action"}}],"environmentDescription":"fixture","expectedFailures":0,"failedTests":%s,"finishTime":1,"passedTests":%s,"result":"Passed","skippedTests":%s,"startTime":0,"statistics":[],"testFailures":[],"title":"Test - TemplateApp","topInsights":[],"totalTestCount":%s}\n' \
      "$udid" "$failed" "$passed" "$skipped" "$failed" "$passed" "$skipped" "$total"
    exit 0
  fi
  if [[ "${4-}" == tests ]]; then
    printf '{"devices":[{"deviceId":"%s"}],"testNodes":[{"children":[{"children":[{"children":[{"duration":"0.1s","durationInSeconds":0.1,"name":"selected","nodeIdentifier":"%s/%s()","nodeIdentifierURL":"test://com.apple.xcode/TemplateApp/%s/%s/%s","nodeType":"Test Case","result":"%s"}],"name":"suite","nodeIdentifierURL":"test://com.apple.xcode/TemplateApp/%s/%s","nodeType":"Test Suite","result":"%s"}],"name":"target","nodeIdentifierURL":"test://com.apple.xcode/TemplateApp/%s","nodeType":"Unit test bundle","result":"%s"}],"name":"Test Plan","nodeType":"Test Plan","result":"%s"}]}\n' \
      "$udid" "$selected_class" "$selected_method" "$selected_target" "$selected_class" "$selected_url_method" \
      "$([[ "$failed" == 0 && "$skipped" == 0 ]] && printf Passed || printf Failed)" "$selected_target" "$selected_class" \
      "$([[ "$failed" == 0 && "$skipped" == 0 ]] && printf Passed || printf Failed)" "$selected_target" \
      "$([[ "$failed" == 0 && "$skipped" == 0 ]] && printf Passed || printf Failed)" \
      "$([[ "$failed" == 0 && "$skipped" == 0 ]] && printf Passed || printf Failed)"
    exit 0
  fi
  echo 'unexpected xcresulttool test-results operation' >&2
  exit 1
fi
[[ "${1-}" == simctl ]] || { echo 'expected simctl' >&2; exit 1; }
command="${2-}"
case "$command" in
  boot)
    [[ "$(state prebooted)" != 1 ]] || exit 1
    ;;
  list)
    [[ "${3-}" == devices && "${4-}" == --json ]] || { echo 'wrong simulator state query' >&2; exit 1; }
    printf '%s\n' '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[' \
      '{"udid":"00000000-0000-0000-0000-000000000001","state":"Booted"},' \
      '{"udid":"00000000-0000-0000-0000-000000000002","state":"Booted"},' \
      '{"udid":"00000000-0000-0000-0000-000000000003","state":"Booted"},' \
      '{"udid":"00000000-0000-0000-0000-000000000004","state":"Booted"}]}}'
    ;;
  bootstatus) exit 0 ;;
  get_app_container)
    [[ "${4-}" == com.example.TemplateApp && "${5-}" == app ]] || { echo 'wrong app container lookup' >&2; exit 1; }
    printf '%s\n' "/Users/fixture/Containers/${3-}/TemplateApp.app"
    ;;
  terminate)
    if [[ "$(state mutate_after_case)" =~ ^(contract|matrix)$ && "${3-}" == "00000000-0000-0000-0000-000000000001" && ! -e "$state_dir/mutate-after-case-fired" ]] && \
       /usr/bin/awk -F '\t' '$3 == "simctl" && $4 == "io" && $5 == "00000000-0000-0000-0000-000000000001" {seen=1} END {exit seen ? 0 : 1}' "$fake_log"; then
      : >"$state_dir/mutate-after-case-fired"
      printf '\n' >>"$(state "$(state mutate_after_case)_path")"
    fi
    exit 0
    ;;
  install)
    app_path="${4-}"
    [[ -d "$app_path" ]] || { echo 'install path is not an app directory' >&2; exit 1; }
    if [[ "$(state app_mode)" == mutate-after-install && ! -e "$state_dir/app-mutated" ]]; then
      : >"$state_dir/app-mutated"
      chmod 0600 "$app_path/Info.plist"
      printf '%s\n' mutated-after-install >>"$app_path/Info.plist"
      chmod 0400 "$app_path/Info.plist"
    elif [[ "$(state app_mode)" == replace-after-install && ! -e "$state_dir/app-mutated" ]]; then
      : >"$state_dir/app-mutated"
      /bin/mv "$app_path" "$app_path.replaced"
      mkdir -p "$app_path"
      /bin/cp "$app_path.replaced/Info.plist" "$app_path/Info.plist"
    elif [[ "$(state app_mode)" == structural-collision && ! -e "$state_dir/app-mutated" ]]; then
      : >"$state_dir/app-mutated"
      /bin/chmod 0600 "$app_path/a"
      /usr/bin/ruby --disable-gems -e 'File.binwrite(ARGV.fetch(0), "")' "$app_path/a"
      /bin/chmod 0400 "$app_path/a"
      /usr/bin/ruby --disable-gems -e 'File.binwrite(ARGV.fetch(0), "X")' "$app_path/b"
      /bin/chmod 0400 "$app_path/b"
    fi
    exit 0
    ;;
  launch)
    /usr/bin/awk -F '\t' -v udid="${3-}" '$3 == "simctl" && $4 == "terminate" && $5 == udid {seen=1} END {exit seen ? 0 : 1}' "$fake_log" || { echo 'launch lacked pre-termination' >&2; exit 1; }
    [[ "$(state case_mode)" != launch-fail || "${3-}" != "00000000-0000-0000-0000-000000000002" ]] || { echo 'configured launch failure' >&2; exit 1; }
    [[ "$(state case_mode)" != late-fail || "${3-}" != "00000000-0000-0000-0000-000000000004" ]] || { echo 'configured late launch failure' >&2; exit 1; }
    launch_pid=4321
    [[ "$(state case_mode)" != pid-replacement || ! -e "$state_dir/ui-ran-iphone-en" || "${3-}" != "00000000-0000-0000-0000-000000000001" ]] || launch_pid=9876
    printf '%s: %s\n' "${4-}" "$launch_pid"
    ;;
  spawn)
    if [[ "$(state case_mode)" == stubborn-probe && "${3-}" == "00000000-0000-0000-0000-000000000001" && "${4-}" == /bin/kill ]]; then
      printf '%s\n' "$$" >"$state_dir/stubborn-probe-pid"
      trap '' TERM
      while true; do /bin/sleep 0.05; done
    fi
    if [[ "${4-}" == /usr/bin/pgrep && "${5-}" == -x && "${6-}" == TemplateApp ]]; then
      echo 'sysmon request failed with error: sysmond service not found' >&2
      echo 'pgrep: Cannot get process list' >&2
      exit 3
    fi
    if [[ "${4-}" == /bin/ps && "${5-}" == -ww && "${6-}" == -p && "${8-}" == -o && "${9-}" == comm= ]]; then
      expected_pid=4321
      [[ "$(state case_mode)" != pid-replacement || ! -e "$state_dir/ui-ran-iphone-en" || "${3-}" != "00000000-0000-0000-0000-000000000001" ]] || expected_pid=9876
      [[ "${7-}" == "$expected_pid" ]] || { echo 'ps inspected stale application PID' >&2; exit 1; }
      printf '%s\n' "/Users/fixture/Containers/${3-}/TemplateApp.app/TemplateApp"
      exit 0
    fi
    expected_pid=4321
    [[ "$(state case_mode)" != pid-replacement || ! -e "$state_dir/ui-ran-iphone-en" || "${3-}" != "00000000-0000-0000-0000-000000000001" ]] || expected_pid=9876
    [[ "${4-}" == /bin/kill && "${5-}" == -0 && "${6-}" == "$expected_pid" ]] || { echo 'wrong process liveness probe' >&2; exit 1; }
    spawn_count_file="$state_dir/spawn-${3-}"
    spawn_count=0
    [[ ! -f "$spawn_count_file" ]] || spawn_count="$(/bin/cat "$spawn_count_file")"
    spawn_count=$((spawn_count + 1))
    printf '%s\n' "$spawn_count" >"$spawn_count_file"
    [[ "$(state case_mode)" != crash || "${3-}" != "00000000-0000-0000-0000-000000000002" ]] || exit 1
    [[ "$(state case_mode)" != post-ui-crash || "${3-}" != "00000000-0000-0000-0000-000000000001" || "$spawn_count" -lt 2 ]] || exit 1
    ;;
  io)
    [[ "${4-}" == screenshot ]] || { echo 'expected screenshot' >&2; exit 1; }
    /usr/bin/awk -F '\t' -v udid="${3-}" '$3 == "simctl" && $4 == "spawn" && $5 == udid && $6 == "/bin/kill" && $7 == "-0" {seen=1} END {exit seen ? 0 : 1}' "$fake_log" || { echo 'screenshot lacked liveness probe' >&2; exit 1; }
    mkdir -p "$(dirname "${5-}")"
    if [[ "$(state png_mode)" == corrupt ]]; then
      printf 'not-a-png' >"${5-}"
    else
      /usr/bin/base64 -D >"${5-}" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=
PNG
    fi
    ;;
  *) echo "unexpected simctl command: $command" >&2; exit 1 ;;
esac
SH
chmod +x "$adapter_bin/xcrun"

for adapter in "$adapter_bin/xcode-select" "$adapter_bin/xcrun" \
  "$fake_developer/usr/bin/xcodebuild" \
  "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"; do
  /usr/bin/sed -i '' -e "s|@STATE_DIR@|$adapter_state|g" -e "s|@FAKE_LOG@|$fake_log|g" \
    -e "s|@VALIDATOR_BINARY@|$validator_binary|g" "$adapter"
done

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
  "verification" => {
    "bundleIdentifier" => "com.example.TemplateApp",
    "unitTestIdentifier" => "TemplateAppTests/UnitSmokeTests/testUnit()",
    "cases" => cases,
    "acceptanceMappings" => mappings
  }
}
document.delete("verification") if mode == "absent"
document.fetch("verification").delete("unitTestIdentifier") if mode == "missing-unit-test" && document["verification"]
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
  local label="$1" contract_mode="${2:-valid}" head_directory="${3:-present}"
  repo="$scratch/$label/repository"
  mkdir -p "$repo/TemplateApp.xcodeproj" "$repo/docs" "$repo/Sources" "$repo/Config"
  repo="$(cd "$repo" && pwd -P)"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Runner Test'
  git -C "$repo" config user.email 'runner@example.invalid'
  printf '%s\n' '.artifacts/' >"$repo/.gitignore"
  printf '%s\n' '{}' >"$repo/TemplateApp.xcodeproj/project.pbxproj"
  printf '%s\n' HEAD-SOURCE >"$repo/Sources/App.swift"
  printf '%s\n' HEAD-CONFIG >"$repo/Config/App.xcconfig"
  printf '%s\n' '# Base' >"$repo/docs/base.md"
  git -C "$repo" add -- .gitignore TemplateApp.xcodeproj Sources Config docs/base.md
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
  mkdir -p "$(dirname "$contract")" "$(dirname "$matrix")"
  [[ "$head_directory" != present ]] || mkdir -p "$(dirname "$draft")"
  write_contract "$contract" "$contract_mode"
  write_matrix "$matrix"
  : >"$fake_log"
  : >"$poison_log"
  /bin/rm -f "$poison_sentinel"
  for key in build_mode test_mode ui_mode case_mode mutate_input mutate_after_case prebooted preferred_invalid \
    hold_file collide_draft collide_final png_mode config_mode candidate_mode app_mode publication_race publication_kill publication_kill_target publication_kill_after_target mutate_worktree mutate_worktree_path; do
    set_state "$key" ""
  done
  for spawn_state in "$adapter_state"/spawn-*; do
    [[ ! -e "$spawn_state" ]] || /bin/rm -f "$spawn_state"
  done
  /bin/rm -f "$adapter_state/app-mutated"
  /bin/rm -f "$adapter_state/publication-race-fired"
  /bin/rm -f "$adapter_state/publication-kill-fired" "$adapter_state/mutate-after-case-fired" "$adapter_state"/ui-ran-*
  /bin/rm -f "$adapter_state"/publication-kill-*
  /bin/rm -f "$adapter_state"/publication-kill-after-*
  /bin/rm -f "$adapter_state/stubborn-probe-pid"
}

refresh_head_paths() {
  head_sha="$(git -C "$repo" rev-parse HEAD)"
  draft="$repo/.artifacts/issues/42/$head_sha/verify-draft.json"
  visual="$repo/.artifacts/issues/42/$head_sha/visual-result.json"
  final="$repo/.artifacts/issues/42/$head_sha/verify.json"
  mkdir -p "$(dirname "$draft")"
}

runner_workspace() {
  /usr/bin/ruby --disable-gems -rdigest -e '
    root = File.realpath(ARGV.fetch(0))
    name = File.basename(root).gsub(/[^A-Za-z0-9_.-]/, "-")
    puts "/tmp/ios-template-verify/#{name}-#{Digest::SHA256.hexdigest(root)}/issue-42/#{ARGV.fetch(1)}"
  ' "$repo" "$head_sha"
}

assert_no_failed_attempts() {
  local workspace attempts
  workspace="$(runner_workspace)"
  attempts="$workspace/Attempts"
  if [[ -d "$attempts" ]] && /usr/bin/find "$attempts" -mindepth 1 -maxdepth 1 -type d -name 'attempt-*' -print -quit | /usr/bin/grep -q .; then
    echo "failed verification retained a private attempt" >&2
    /usr/bin/find "$attempts" -mindepth 1 -maxdepth 2 -print >&2
    exit 1
  fi
}

run_execute() {
  set_state build_mode "${FAKE_BUILD_MODE-}"
  set_state test_mode "${FAKE_TEST_MODE-}"
  set_state ui_mode "${FAKE_UI_MODE-}"
  set_state case_mode "${FAKE_CASE_MODE-}"
  set_state mutate_input "${FAKE_MUTATE_INPUT-}"
  set_state mutate_after_case "${FAKE_MUTATE_AFTER_CASE-}"
  set_state prebooted "${FAKE_PREBOOTED-}"
  set_state preferred_invalid "${FAKE_PREFERRED_XCODE_INVALID-}"
  set_state hold_file "${FAKE_HOLD_BUILD_FILE-}"
  set_state collide_draft "${FAKE_COLLIDE_DRAFT-}"
  set_state png_mode "${FAKE_PNG_MODE-}"
  set_state config_mode "${FAKE_CONFIG_MODE-}"
  set_state app_mode "${FAKE_APP_MODE-}"
  set_state publication_race "${FAKE_PUBLICATION_RACE-}"
  set_state publication_kill "${FAKE_PUBLICATION_KILL-}"
  set_state publication_kill_target "${FAKE_PUBLICATION_KILL_TARGET-}"
  set_state publication_kill_after_target "${FAKE_PUBLICATION_KILL_AFTER_TARGET-}"
  set_state mutate_worktree "${FAKE_MUTATE_WORKTREE-}"
  set_state mutate_worktree_path "$repo/Sources/App.swift"
  set_state contract_path "$contract"
  set_state matrix_path "$matrix"
  set_state fallback_developer "${FAKE_FALLBACK_DEVELOPER_DIR:-$fake_developer}"
  (cd "$repo" && /usr/bin/env \
    "BASH_FUNC_cd%%=() { printf '%s\\n' bash-function-executed >>'$poison_sentinel'; builtin cd \"\$@\"; }" \
    BASH_ENV="$poison_bash_env" PATH="$poison_bin:/usr/bin:/bin" \
    GIT_DIR=/malicious/git-dir GIT_WORK_TREE=/malicious/work-tree GIT_INDEX_FILE=/malicious/index \
    GIT_OBJECT_DIRECTORY=/malicious/objects GIT_ALTERNATE_OBJECT_DIRECTORIES=/malicious/alternates \
    GIT_CONFIG_GLOBAL=/malicious/global GIT_CONFIG_SYSTEM=/malicious/system GIT_CONFIG_NOSYSTEM=0 \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.rev-parse GIT_CONFIG_VALUE_0='!exit 91' \
    DEVELOPER_DIR=/malicious/developer TOOLCHAINS=malicious SDKROOT=/malicious/sdk \
    RUBYOPT="-r$poison_ruby" RUBYLIB=/malicious/ruby GEM_HOME=/malicious/gem GEM_PATH=/malicious/gems \
    BUNDLE_GEMFILE=/malicious/Gemfile DYLD_INSERT_LIBRARIES=/malicious/libpoison.dylib \
    SWIFT_EXEC="$poison_tool" SWIFT_DRIVER_SWIFT_FRONTEND_EXEC="$poison_tool" \
    CC="$poison_tool" CXX="$poison_tool" LD="$poison_tool" OTHER_SWIFT_FLAGS=-malicious \
    XCODE_XCCONFIG_FILE=/malicious/settings.xcconfig \
    "$runner" --issue 42 --expected-base "${FAKE_EXPECTED_BASE:-$base_sha}" \
      --issue-contract .artifacts/issues/42/issue-contract.json \
      --matrix .artifacts/batches/runner-fixture/simulator-matrix.json \
      --project "${FAKE_PROJECT_PATH:-TemplateApp.xcodeproj}" --scheme TemplateApp)
}

run_finalize() {
  set_state collide_final "${FAKE_COLLIDE_FINAL-}"
  set_state candidate_mode "${FAKE_CANDIDATE_MODE-}"
  set_state publication_race "${FAKE_PUBLICATION_RACE-}"
  set_state publication_kill_target "${FAKE_PUBLICATION_KILL_TARGET-}"
  set_state publication_kill_after_target "${FAKE_PUBLICATION_KILL_AFTER_TARGET-}"
  set_state candidate_path "$(dirname "$final")"
  set_state packet_path "$(dirname "$final")/visual-packet.json"
  set_state visual-result_path "$visual"
  set_state image-bytes_path "$(dirname "$final")/iphone-en/settings-open.png"
  set_state image-set_path "$(dirname "$final")/iphone-en"
  (cd "$repo" && /usr/bin/env \
    "BASH_FUNC_cd%%=() { printf '%s\\n' bash-function-executed >>'$poison_sentinel'; builtin cd \"\$@\"; }" \
    BASH_ENV="$poison_bash_env" PATH="$poison_bin:/usr/bin:/bin" \
    GIT_DIR=/malicious/git-dir GIT_WORK_TREE=/malicious/work-tree GIT_INDEX_FILE=/malicious/index \
    GIT_OBJECT_DIRECTORY=/malicious/objects GIT_ALTERNATE_OBJECT_DIRECTORIES=/malicious/alternates \
    GIT_CONFIG_GLOBAL=/malicious/global GIT_CONFIG_SYSTEM=/malicious/system GIT_CONFIG_NOSYSTEM=0 \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.rev-parse GIT_CONFIG_VALUE_0='!exit 91' \
    DEVELOPER_DIR=/malicious/developer TOOLCHAINS=malicious SDKROOT=/malicious/sdk \
    RUBYOPT="-r$poison_ruby" RUBYLIB=/malicious/ruby GEM_HOME=/malicious/gem GEM_PATH=/malicious/gems \
    BUNDLE_GEMFILE=/malicious/Gemfile DYLD_INSERT_LIBRARIES=/malicious/libpoison.dylib \
    SWIFT_EXEC="$poison_tool" SWIFT_DRIVER_SWIFT_FRONTEND_EXEC="$poison_tool" \
    CC="$poison_tool" CXX="$poison_tool" LD="$poison_tool" OTHER_LDFLAGS=-malicious \
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

write_packet() {
  local packet="$(dirname "$draft")/visual-packet.json"
  [[ -e "$packet" ]] && return
  (cd "$repo" && "$validator_binary" --visual-packet --issue 42 --expected-base "$base_sha" \
    --draft ".artifacts/issues/42/$head_sha/verify-draft.json" \
    --output ".artifacts/issues/42/$head_sha/visual-packet.json" >/dev/null)
}

write_additional_png() {
  /usr/bin/ruby -rzlib - "$1" "$2" <<'RUBY'
source, destination = ARGV
png = File.binread(source)
payload = "State\0settings-open".b
type = "tEXt".b
chunk = [payload.bytesize].pack("N") + type + payload + [Zlib.crc32(type + payload)].pack("N")
File.binwrite(destination, png.byteslice(0, png.bytesize - 12) + chunk + png.byteslice(-12, 12))
RUBY
}

write_visual() {
  write_packet
  /usr/bin/ruby -rjson -rtime -rdigest - "$draft" "$(dirname "$draft")/visual-packet.json" "$visual" "${1:-approved}" <<'RUBY'
draft_path, packet_path, visual_path, mode = ARGV
draft = JSON.parse(File.read(draft_path))
packet = JSON.parse(File.read(packet_path))
document = {
  "schemaVersion" => 1, "status" => "approved", "issue" => draft.fetch("issue"),
  "headSha" => draft.fetch("headSha"),
  "draft" => {"path" => ".artifacts/issues/42/#{draft.fetch("headSha")}/verify-draft.json", "digest" => "sha256:#{Digest::SHA256.file(draft_path).hexdigest}"},
  "visualPacket" => {"path" => ".artifacts/issues/42/#{draft.fetch("headSha")}/visual-packet.json", "digest" => "sha256:#{Digest::SHA256.file(packet_path).hexdigest}"},
  "cases" => packet.fetch("cases").map { |entry| {"id" => entry.fetch("id"), "status" => "approved", "images" => entry.fetch("images").map { |image| {"state" => image.fetch("state"), "path" => image.fetch("path"), "digest" => image.fetch("digest"), "findings" => []} }, "findings" => []} },
  "findings" => [], "reviewedAt" => Time.now.iso8601
}
case mode
when "rejected" then document["status"] = "rejected"; document["findings"] = ["layout overlap"]
when "wrong-digest" then document.fetch("draft")["digest"] = "sha256:" + "0" * 64
when "wrong-head" then document["headSha"] = "0" * 40
when "missing-case" then document.fetch("cases").pop
when "case-finding" then document.fetch("cases").fetch(0)["findings"] = ["clipped"]
when "wrong-screenshot-digest" then document.fetch("cases").fetch(0).fetch("images").fetch(0)["digest"] = "sha256:" + "0" * 64
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

startup_stdout="$scratch/startup.stdout"
startup_stderr="$scratch/startup.stderr"
if (cd "$scratch" && CDPATH="$scratch" test-source/tools/verify-ios-issue.sh >"$startup_stdout" 2>"$startup_stderr"); then
  echo "startup unexpectedly accepted missing arguments" >&2; exit 1
fi
[[ ! -s "$startup_stdout" ]] || { echo "hostile CDPATH contaminated startup resolution" >&2; exit 1; }
grep -Fq 'usage:' "$startup_stderr" || { echo "relative startup did not reach the trusted runner" >&2; exit 1; }
if (cd "$test_source/tools" && /bin/bash -p verify-ios-issue.sh >"$startup_stdout" 2>"$startup_stderr"); then
  echo "pathless startup unexpectedly succeeded" >&2; exit 1
fi
grep -Fq 'unsafe runner invocation path' "$startup_stderr" || { echo "pathless startup was not rejected" >&2; exit 1; }
control_runner="$test_source/tools/verify-ios-issue"$'\n'".sh"
/bin/cp "$runner" "$control_runner"
chmod +x "$control_runner"
if "$control_runner" >"$startup_stdout" 2>"$startup_stderr"; then
  echo "control-character startup unexpectedly succeeded" >&2; exit 1
fi
grep -Fq 'unsafe runner invocation path' "$startup_stderr" || { echo "control-character startup was not rejected" >&2; exit 1; }

swift_driver_probe="$scratch/swift-driver-probe.swift"
printf '%s\n' 'print("swift-driver-ok")' >"$swift_driver_probe"
if ! swift_driver_output="$(
  source "$test_source/tools/lib/xcode.sh"
  select_initial_xcode_environment
  run_xcode_swift "$swift_driver_probe"
)"; then
  echo "Xcode Swift dispatch did not preserve the validated driver invocation name" >&2
  exit 1
fi
[[ "$swift_driver_output" == swift-driver-ok ]] || {
  echo "Xcode Swift driver probe returned unexpected output" >&2
  exit 1
}

prepare_repo valid
run_execute
[[ ! -s "$poison_log" ]] || { echo "production dispatch used caller PATH" >&2; cat "$poison_log" >&2; exit 1; }
[[ ! -e "$poison_sentinel" ]] || { echo "security-critical child inherited poisoned environment" >&2; cat "$poison_sentinel" >&2; exit 1; }
[[ -f "$draft" && ! -e "$final" ]] || { echo "execution did not publish only the draft" >&2; exit 1; }
/usr/bin/ruby -rjson -rdigest - "$draft" "$head_sha" <<'RUBY'
draft, head = ARGV
document = JSON.parse(File.read(draft))
abort "wrong draft status" unless document["status"] == "awaiting-visual-review"
abort "draft claimed visual approval" if document.key?("visualEvaluation")
abort "wrong Head" unless document["headSha"] == head
project = document.fetch("build").fetch("project")
abort "wrong project path" unless project.fetch("path") == "TemplateApp.xcodeproj"
abort "missing project digest" unless project.fetch("digest").match?(/\Asha256:[0-9a-f]{64}\z/)
source_tree = document.fetch("build").fetch("sourceTree")
abort "wrong source Head" unless source_tree.fetch("headSha") == head
abort "wrong source project" unless source_tree.fetch("projectPath") == "TemplateApp.xcodeproj"
abort "missing source tree digest" unless source_tree.fetch("digest").match?(/\Asha256:[0-9a-f]{64}\z/)
abort "wrong cases" unless document["cases"].map { |entry| entry["id"] } == %w[iphone-en iphone-ja ipad-en ipad-ja]
evidence_root = File.dirname(draft)
document.fetch("cases").each do |entry|
  screenshot = File.join(evidence_root, entry.fetch("screenshot"))
  expected = "sha256:#{Digest::SHA256.file(screenshot).hexdigest}"
  abort "missing or wrong screenshot digest" unless entry.fetch("screenshotDigest") == expected
end
abort "missing AC mappings" unless document["acceptanceEvidence"].map { |entry| entry["id"] } == %w[AC-1 AC-2]
abort "wrong execution AC evidence" unless document["acceptanceEvidence"].map { |entry| entry["evidence"] } == [
  %w[stage:build stage:unit-tests],
  %w[case:iphone-en case:iphone-ja case:ipad-en case:ipad-ja]
]
paths = document.fetch("workspaceArtifacts")
prefix = "/tmp/ios-template-verify/"
abort "DerivedData escaped /tmp" unless paths.fetch("derivedDataPath").start_with?(prefix) && paths.fetch("derivedDataPath").match?(%r{/#{head}/Attempts/attempt-[0-9a-f-]+/DerivedData\z})
abort "result bundles escaped /tmp" unless %w[buildResultBundlePath testResultBundlePath].all? { |key| paths.fetch(key).start_with?(prefix) && paths.fetch(key).include?("/#{head}/") }
worktree_id = paths.fetch("derivedDataPath").split("/").fetch(3)
abort "worktree ID lacks full physical-root digest" unless worktree_id.match?(/-[0-9a-f]{64}\z/)
RUBY
workspace_root="$(/usr/bin/ruby -rjson -e 'puts File.dirname(JSON.parse(File.read(ARGV[0])).fetch("workspaceArtifacts").fetch("derivedDataPath"))' "$draft")"
[[ "$(/usr/bin/stat -f '%Lp' "$workspace_root")" == 700 ]] || { echo "workspace is not mode 0700" >&2; exit 1; }

build_count="$(awk -F '\t' '$1 == "xcodebuild" && $0 ~ /\tbuild-for-testing$/ {count++} END {print count+0}' "$fake_log")"
test_count="$(awk -F '\t' '$1 == "xcodebuild" && $0 ~ /\ttest-without-building$/ {count++} END {print count+0}' "$fake_log")"
[[ "$build_count" == 1 && "$test_count" == 3 ]] || { echo "wrong Build/Test invocation counts" >&2; cat "$fake_log" >&2; exit 1; }
/usr/bin/awk -F '\t' '$1 == "xcrun" && $3 == "simctl" && $4 == "install" { count++; if ($6 !~ /\/Attempts\/attempt-[0-9a-f-]+\/StagedApp\/TemplateApp\.app$/) bad=1 } END { exit count == 4 && !bad ? 0 : 1 }' "$fake_log" || {
  echo "Simulator install did not use the exact private staged application" >&2
  exit 1
}
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
    elsif fields.last == "build-for-testing"
      sequence << "build"
      next
    end
    if fields.last == "test-without-building"
      identifier = fields.find { |field| field.start_with?("-only-testing:") }.sub("-only-testing:", "")
      if identifier == "TemplateAppTests/UnitSmokeTests/testUnit()"
        sequence << "unit-test"
      else
        udid = fields.fetch(fields.index("-destination") + 1).split("id=", 2).last
        sequence << "#{case_for.fetch(udid)}-ui-test"
      end
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
    operation = fields[4] == "build-results" ? "diagnostics" : fields[5]
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
  xcode-version build build-diagnostics unit-test unit-diagnostics unit-summary unit-tests
  iphone-en-boot iphone-en-bootstatus iphone-en-install iphone-en-get_app_container iphone-en-terminate iphone-en-launch iphone-en-spawn iphone-en-ui-test iphone-en-diagnostics iphone-en-summary iphone-en-tests iphone-en-terminate iphone-en-launch iphone-en-spawn iphone-en-spawn iphone-en-screenshot iphone-en-terminate
  iphone-ja-boot iphone-ja-bootstatus iphone-ja-install iphone-ja-get_app_container iphone-ja-terminate iphone-ja-launch iphone-ja-spawn iphone-ja-spawn iphone-ja-screenshot iphone-ja-terminate
  ipad-en-boot ipad-en-bootstatus ipad-en-install ipad-en-get_app_container ipad-en-terminate ipad-en-launch ipad-en-spawn ipad-en-ui-test ipad-en-diagnostics ipad-en-summary ipad-en-tests ipad-en-terminate ipad-en-launch ipad-en-spawn ipad-en-spawn ipad-en-screenshot ipad-en-terminate
  ipad-ja-boot ipad-ja-bootstatus ipad-ja-install ipad-ja-get_app_container ipad-ja-terminate ipad-ja-launch ipad-ja-spawn ipad-ja-spawn ipad-ja-screenshot ipad-ja-terminate
]
abort "unexpected Xcode/Simulator command order:\n#{actual.join("\n")}" unless actual == expected
RUBY
[[ "$(grep -c $'^xcrun\t.*\tsimctl\tlaunch\t' "$fake_log")" == 6 ]] || { echo "wrong locale launch count" >&2; exit 1; }
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
/usr/bin/ruby -rjson -rdigest - "$final" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.read(path))
document.fetch("cases").each do |entry|
  screenshot = File.join(File.dirname(path), entry.fetch("screenshot"))
  abort "final screenshot digest mismatch" unless entry.fetch("screenshotDigest") == "sha256:#{Digest::SHA256.file(screenshot).hexdigest}"
end
project = document.fetch("build").fetch("project")
abort "final project identity mismatch" unless project.fetch("path") == "TemplateApp.xcodeproj" && project.fetch("digest").match?(/\Asha256:[0-9a-f]{64}\z/)
RUBY
run_finalize
[[ -f "$final" ]] || { echo "idempotent finalization did not preserve exact canonical evidence" >&2; exit 1; }

prepare_repo first-run valid absent-head
run_execute
[[ -f "$draft" ]] || { echo "first run did not create and publish into the canonical Head directory" >&2; exit 1; }

prepare_repo contained-source-symlink
git -C "$repo" mv Sources/App.swift Sources/RealApp.swift
/bin/ln -s RealApp.swift "$repo/Sources/App.swift"
git -C "$repo" add -- Sources/App.swift
git -C "$repo" commit -q -m 'use contained source symlink'
refresh_head_paths
run_execute
[[ -f "$draft" ]] || { echo "contained source symlink was not materialized" >&2; exit 1; }

prepare_repo contained-config-symlink
git -C "$repo" mv Config/App.xcconfig Config/RealApp.xcconfig
/bin/ln -s RealApp.xcconfig "$repo/Config/App.xcconfig"
git -C "$repo" add -- Config/App.xcconfig
git -C "$repo" commit -q -m 'use contained config symlink'
refresh_head_paths
run_execute
[[ -f "$draft" ]] || { echo "contained config symlink was not materialized" >&2; exit 1; }

prepare_repo escaping-source-symlink
git -C "$repo" rm -q Sources/App.swift
/bin/mkdir -p "$repo/Sources"
/bin/ln -s ../../outside.swift "$repo/Sources/App.swift"
git -C "$repo" add -- Sources/App.swift
git -C "$repo" commit -q -m 'add escaping source symlink'
refresh_head_paths
expect_execute_failure escaping-source-symlink "contract or matrix validation failed"
assert_no_failed_attempts
if /usr/bin/awk -F '\t' '$1 == "xcodebuild" && $0 ~ /build-for-testing$/ {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
  echo "escaping source symlink reached Build" >&2; exit 1
fi

prepare_repo cyclic-source-symlink
git -C "$repo" rm -q Sources/App.swift
/bin/mkdir -p "$repo/Sources"
/bin/ln -s Loop.swift "$repo/Sources/App.swift"
/bin/ln -s App.swift "$repo/Sources/Loop.swift"
git -C "$repo" add -- Sources/App.swift Sources/Loop.swift
git -C "$repo" commit -q -m 'add cyclic source symlinks'
refresh_head_paths
expect_execute_failure cyclic-source-symlink "contract or matrix validation failed"
assert_no_failed_attempts
if /usr/bin/awk -F '\t' '$1 == "xcodebuild" && $0 ~ /build-for-testing$/ {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
  echo "cyclic source symlink reached Build" >&2; exit 1
fi

prepare_repo atomic-failure-evidence
FAKE_BUILD_MODE=fail expect_execute_failure atomic-failure-evidence "build command failed"
assert_no_failed_attempts
failure_file="$(/usr/bin/find "$(dirname "$draft")/failures" -type f -name 'failure-*.json' -print -quit)"
[[ -n "$failure_file" ]] || { echo "failure evidence was not published" >&2; exit 1; }
[[ "$(/usr/bin/stat -f '%Lp' "$failure_file")" == 400 ]] || { echo "failure evidence was not sealed read-only" >&2; exit 1; }
/usr/bin/ruby -rjson -e 'document = JSON.parse(File.read(ARGV.fetch(0))); abort unless document["status"] == "failed" && document["stage"] == "build"' "$failure_file"
if /usr/bin/find "$(dirname "$draft")/failures" -type f ! -name 'failure-*.json' -print -quit | /usr/bin/grep -q .; then
  echo "failure publication left a temporary file" >&2
  exit 1
fi

prepare_repo stubborn-probe-timeout
FAKE_CASE_MODE=stubborn-probe run_execute >"$scratch/stubborn-probe.stdout" 2>"$scratch/stubborn-probe.stderr" &
stubborn_runner_pid=$!
stubborn_finished=0
for _ in $(/usr/bin/jot 400); do
  if ! /bin/kill -0 "$stubborn_runner_pid" >/dev/null 2>&1; then stubborn_finished=1; break; fi
  /bin/sleep 0.05
done
if [[ "$stubborn_finished" != 1 ]]; then
  stubborn_child_pid="$(/bin/cat "$adapter_state/stubborn-probe-pid" 2>/dev/null || true)"
  [[ ! "$stubborn_child_pid" =~ ^[1-9][0-9]*$ ]] || /bin/kill -KILL "$stubborn_child_pid" >/dev/null 2>&1 || true
  /bin/kill -KILL "$stubborn_runner_pid" >/dev/null 2>&1 || true
  wait "$stubborn_runner_pid" 2>/dev/null || true
  echo "bounded Simulator probe hung after TERM" >&2
  exit 1
fi
if wait "$stubborn_runner_pid"; then
  echo "stubborn Simulator probe unexpectedly succeeded" >&2; exit 1
fi
grep -Fq 'process liveness' "$scratch/stubborn-probe.stderr" || { echo "stubborn probe reported the wrong failure" >&2; exit 1; }
stubborn_child_pid="$(/bin/cat "$adapter_state/stubborn-probe-pid" 2>/dev/null || true)"
if [[ "$stubborn_child_pid" =~ ^[1-9][0-9]*$ ]] && /bin/kill -0 "$stubborn_child_pid" >/dev/null 2>&1; then
  /bin/kill -KILL "$stubborn_child_pid" >/dev/null 2>&1 || true
  echo "bounded Simulator probe left a TERM-ignoring descendant" >&2
  exit 1
fi
assert_no_failed_attempts

prepare_repo malicious-git-policy
malicious_hooks="$scratch/malicious-hooks"
mkdir -p "$malicious_hooks"
/usr/bin/sed "s|@SENTINEL@|$git_policy_sentinel|g" >"$scratch/malicious-fsmonitor" <<'SH'
#!/bin/sh
printf '%s\n' fsmonitor-executed >>'@SENTINEL@'
exit 1
SH
/usr/bin/sed "s|@SENTINEL@|$git_policy_sentinel|g" >"$malicious_hooks/post-index-change" <<'SH'
#!/bin/sh
printf '%s\n' hook-executed >>'@SENTINEL@'
exit 0
SH
chmod +x "$scratch/malicious-fsmonitor" "$malicious_hooks/post-index-change"
git -C "$repo" config core.fsmonitor "$scratch/malicious-fsmonitor"
git -C "$repo" config core.hooksPath "$malicious_hooks"
touch "$repo/docs/head.md"
/bin/rm -f "$git_policy_sentinel"
run_execute
[[ ! -e "$git_policy_sentinel" ]] || {
  echo "trusted Git executed repository-local fsmonitor or hooks" >&2
  /bin/cat "$git_policy_sentinel" >&2
  exit 1
}

prepare_repo ignored-project
printf '%s\n' 'Evil.xcodeproj/' >>"$repo/.git/info/exclude"
mkdir -p "$repo/Evil.xcodeproj"
printf '%s\n' '{}' >"$repo/Evil.xcodeproj/project.pbxproj"
FAKE_PROJECT_PATH=Evil.xcodeproj expect_execute_failure ignored-project "project"
if /usr/bin/awk -F '\t' '$1 == "xcodebuild" && ($0 ~ /build-for-testing$/ || $0 ~ /test-without-building$/) {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
  echo "ignored project reached Build" >&2; exit 1
fi

prepare_repo ignored-synchronized-source
printf '%s\n' 'Sources/Ignored.swift' >>"$repo/.git/info/exclude"
printf '%s\n' 'IGNORED-SOURCE' >"$repo/Sources/Ignored.swift"
run_execute
[[ -f "$draft" ]] || { echo "ignored source prevented isolated raw-Head execution" >&2; exit 1; }

prepare_repo assume-unchanged-source
git -C "$repo" update-index --assume-unchanged Sources/App.swift
printf '%s\n' MUTATED >"$repo/Sources/App.swift"
expect_execute_failure assume-unchanged-source "working tree must be clean"

prepare_repo assume-unchanged-xcconfig
git -C "$repo" update-index --assume-unchanged Config/App.xcconfig
printf '%s\n' MUTATED >"$repo/Config/App.xcconfig"
expect_execute_failure assume-unchanged-xcconfig "working tree must be clean"

prepare_repo hostile-filter
filter_sentinel="$scratch/filter-sentinel"
git -C "$repo" config filter.hostile.smudge "/bin/sh -c 'printf filter-executed >>$filter_sentinel; /bin/cat'"
git -C "$repo" config filter.hostile.clean /bin/cat
printf '%s\n' '*.swift filter=hostile' >"$repo/.git/info/attributes"
/bin/rm -f "$filter_sentinel"
run_execute
[[ ! -e "$filter_sentinel" ]] || { echo "runner executed a hostile conversion filter" >&2; exit 1; }

prepare_repo missing-project-member
git -C "$repo" rm -q Sources/App.swift
git -C "$repo" commit -q -m 'remove project member fixture'
refresh_head_paths
FAKE_BUILD_MODE= expect_execute_failure missing-project-member "build command failed"

prepare_repo mutate-worktree-during-build
FAKE_MUTATE_WORKTREE=1 expect_execute_failure mutate-worktree-during-build "verification inputs changed"
if /usr/bin/awk -F '\t' '$1 == "xcrun" && $3 == "simctl" {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
  echo "worktree mutation reached Simulator commands" >&2; exit 1
fi

prepare_repo intermediate-project-symlink
mkdir -p "$repo/RealProjects/TemplateApp.xcodeproj"
printf '%s\n' '{}' >"$repo/RealProjects/TemplateApp.xcodeproj/project.pbxproj"
/bin/ln -s RealProjects "$repo/LinkedProjects"
git -C "$repo" add -- RealProjects LinkedProjects
git -C "$repo" commit -q -m 'add linked project fixture'
refresh_head_paths
FAKE_PROJECT_PATH=LinkedProjects/TemplateApp.xcodeproj expect_execute_failure intermediate-project-symlink "project"
if /usr/bin/awk -F '\t' '$1 == "xcodebuild" && ($0 ~ /build-for-testing$/ || $0 ~ /test-without-building$/) {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
  echo "symlinked project reached Build" >&2; exit 1
fi

for mode in absent missing-unit-test missing-case missing-action both-actions missing-mapping unknown-mapping; do
  prepare_repo "contract-$mode" "$mode"
  expect_execute_failure "contract-$mode" "verification"
  [[ ! -s "$fake_log" ]] || { echo "invalid contract reached Xcode for $mode" >&2; cat "$fake_log" >&2; exit 1; }
done

prepare_repo dirty-range
printf '%s\n' dirty >>"$repo/docs/head.md"
expect_execute_failure dirty-range "working tree must be clean"
dirty_failure="$(/usr/bin/find "$(dirname "$draft")/failures" -type f -name 'failure-*.json' -print -quit)"
[[ -n "$dirty_failure" ]] || { echo "dirty preflight did not publish failure evidence" >&2; exit 1; }
/usr/bin/ruby -rjson -e 'd = JSON.parse(File.read(ARGV.fetch(0))); abort unless d["stage"] == "preflight" && d["error"] == "working tree must be clean"' "$dirty_failure"
if /usr/bin/awk -F '\t' '$1 == "xcodebuild" && ($0 ~ /build-for-testing$/ || $0 ~ /test-without-building$/) || ($1 == "xcrun" && $3 == "simctl") {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
  echo "dirty range reached Build or Simulator" >&2; exit 1
fi

prepare_repo invalid-base
invalid_base="ffffffffffffffffffffffffffffffffffffffff"
FAKE_EXPECTED_BASE="$invalid_base" expect_execute_failure invalid-base "expected Base is not a commit"
invalid_base_failure="$(/usr/bin/find "$(dirname "$draft")/failures" -type f -name 'failure-*.json' -print -quit)"
[[ -n "$invalid_base_failure" ]] || { echo "invalid Base preflight did not publish failure evidence" >&2; exit 1; }
/usr/bin/ruby -rjson -e 'd = JSON.parse(File.read(ARGV.fetch(0))); abort unless d["stage"] == "preflight" && d["baseSha"] == ARGV.fetch(1)' "$invalid_base_failure" "$invalid_base"

prepare_repo warning
FAKE_BUILD_MODE=warning expect_execute_failure warning "build warnings are not allowed"
[[ ! -e "$draft" ]] || { echo "warning failure published draft" >&2; exit 1; }

for mode in failed skipped zero command-fail; do
  prepare_repo "tests-$mode"
  FAKE_TEST_MODE="$mode" expect_execute_failure "tests-$mode" "unit tests"
  [[ ! -e "$draft" ]] || { echo "test failure published draft" >&2; exit 1; }
done

prepare_repo tests-wrong-selector
FAKE_TEST_MODE=wrong-selector expect_execute_failure tests-wrong-selector "unit tests"

prepare_repo tests-two-summary
FAKE_TEST_MODE=two-summary expect_execute_failure tests-two-summary "unit tests"

prepare_repo tests-warning
FAKE_TEST_MODE=warning expect_execute_failure tests-warning "unit test warnings are not allowed"
[[ ! -e "$draft" ]] || { echo "unit-test warning published draft" >&2; exit 1; }

for mode in zero skipped warning; do
  prepare_repo "ui-$mode"
  FAKE_UI_MODE="$mode" expect_execute_failure "ui-$mode" "case iphone-en failed"
  [[ ! -e "$draft" ]] || { echo "invalid UI result published draft" >&2; exit 1; }
done

prepare_repo ui-wrong-selector
FAKE_UI_MODE=wrong-selector expect_execute_failure ui-wrong-selector "case iphone-en failed"

prepare_repo corrupt-png
FAKE_PNG_MODE=corrupt expect_execute_failure corrupt-png "case iphone-en failed"
[[ ! -d "$(dirname "$draft")/iphone-en" ]] || { echo "corrupt PNG was published" >&2; exit 1; }

prepare_repo mutable-config
FAKE_CONFIG_MODE=mutate expect_execute_failure mutable-config "config"
[[ ! -e "$draft" ]] || { echo "mutable config published draft" >&2; exit 1; }

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

prepare_repo final-publication-race-image-bytes
run_execute
write_additional_png "$(dirname "$draft")/iphone-en/screenshot.png" "$(dirname "$draft")/iphone-en/settings-open.png"
write_visual approved
FAKE_PUBLICATION_RACE=image-bytes expect_finalize_failure final-publication-race-image-bytes "visual result is invalid"

prepare_repo final-publication-race-image-set
run_execute
write_visual approved
FAKE_PUBLICATION_RACE=image-set expect_finalize_failure final-publication-race-image-set "visual result is invalid"

prepare_repo final-publication-race-packet
run_execute
write_visual approved
FAKE_PUBLICATION_RACE=packet expect_finalize_failure final-publication-race-packet "visual result is invalid"

prepare_repo final-publication-race-visual-result
run_execute
write_visual approved
FAKE_PUBLICATION_RACE=visual-result expect_finalize_failure final-publication-race-visual-result "visual result is invalid"

for source in contract matrix; do
  prepare_repo "mutated-after-case-$source"
  FAKE_MUTATE_AFTER_CASE="$source" expect_execute_failure "mutated-after-case-$source" "$source changed during verification"
  if /usr/bin/awk -F '\t' '$3 == "simctl" && $5 == "00000000-0000-0000-0000-000000000002" {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
    echo "runner issued later-case Simulator commands after $source mutation" >&2; exit 1
  fi
done

for source in contract matrix; do
  prepare_repo "publication-race-$source"
  FAKE_PUBLICATION_RACE="$source" expect_execute_failure "publication-race-$source" "atomic draft publication failed"
  [[ ! -e "$draft" ]] || { echo "publication race emitted a stale draft" >&2; exit 1; }
  for case_id in iphone-en iphone-ja ipad-en ipad-ja; do
    [[ ! -e "$(dirname "$draft")/$case_id/screenshot.png" ]] || { echo "publication race left a screenshot" >&2; exit 1; }
  done
done

prepare_repo case-failure
FAKE_CASE_MODE=launch-fail expect_execute_failure case-failure "case iphone-ja failed"
[[ ! -e "$draft" ]] || { echo "case failure published draft" >&2; exit 1; }
/usr/bin/awk -F '\t' '$3 == "simctl" && $4 == "terminate" && $5 == "00000000-0000-0000-0000-000000000002" {count++} END {exit count >= 2 ? 0 : 1}' "$fake_log" || { echo "case failure did not terminate active app" >&2; exit 1; }

prepare_repo case-crash
FAKE_CASE_MODE=crash expect_execute_failure case-crash "case iphone-ja failed"

prepare_repo post-ui-crash
FAKE_CASE_MODE=post-ui-crash expect_execute_failure post-ui-crash "case iphone-en failed"

prepare_repo ui-pid-replacement
FAKE_CASE_MODE=pid-replacement run_execute
[[ -f "$draft" ]] || { echo "UI PID replacement did not complete verification" >&2; exit 1; }
/usr/bin/awk -F '\t' '$3 == "simctl" && $4 == "spawn" && $5 == "00000000-0000-0000-0000-000000000001" && $6 == "/bin/kill" && $8 == "9876" {found=1} END {exit found ? 0 : 1}' "$fake_log" || {
  echo "runner did not probe the reacquired UI application PID" >&2; exit 1
}

prepare_repo app-plist-symlink
FAKE_BUILD_MODE=plist-symlink expect_execute_failure app-plist-symlink "built application"

prepare_repo app-nested-symlink
FAKE_APP_MODE=nested-symlink expect_execute_failure app-nested-symlink "built application"

prepare_repo app-special-file
FAKE_APP_MODE=special-file expect_execute_failure app-special-file "built application"

prepare_repo app-content-mutation
FAKE_APP_MODE=mutate-after-install expect_execute_failure app-content-mutation "built application"

prepare_repo app-path-replacement
FAKE_APP_MODE=replace-after-install expect_execute_failure app-path-replacement "built application"

prepare_repo app-structural-collision
FAKE_APP_MODE=structural-collision expect_execute_failure app-structural-collision "built application"

prepare_repo late-failure-retry
FAKE_CASE_MODE=late-fail expect_execute_failure late-failure-retry "case ipad-ja failed"
for case_id in iphone-en iphone-ja ipad-en ipad-ja; do
  [[ ! -e "$(dirname "$draft")/$case_id/screenshot.png" ]] || { echo "late failure exposed canonical screenshot" >&2; exit 1; }
done
run_execute
[[ -f "$draft" ]] || { echo "same-Head retry did not publish draft" >&2; exit 1; }

prepare_repo draft-collision
FAKE_COLLIDE_DRAFT=1 expect_execute_failure draft-collision "atomic draft publication failed"
grep -Fq sentinel-draft "$draft" || { echo "draft collision replaced the winner" >&2; exit 1; }
for case_id in iphone-en iphone-ja ipad-en ipad-ja; do
  [[ ! -e "$(dirname "$draft")/$case_id/screenshot.png" ]] || { echo "draft collision left a partial screenshot bundle" >&2; exit 1; }
done


prepare_repo killed-draft-publication
FAKE_PUBLICATION_KILL=1 expect_execute_failure killed-draft-publication "atomic draft publication failed"
run_execute
[[ -f "$draft" ]] || { echo "same-Head retry did not recover killed draft publication" >&2; exit 1; }
[[ ! -e "$(dirname "$draft")/.verify-publication-journal.json" ]] || { echo "successful retry left publication journal" >&2; exit 1; }

for canonical_name in .verify-publication-journal.json screenshot.png verify-draft.json; do
  label="kill-before-${canonical_name//[^A-Za-z0-9]/-}"
  prepare_repo "$label"
  FAKE_PUBLICATION_KILL_TARGET="$canonical_name" expect_execute_failure "$label" "atomic draft publication failed"
  run_execute
  [[ -f "$draft" ]] || { echo "same-Head retry failed after kill before $canonical_name" >&2; exit 1; }
done

for canonical_name in .verify-publication-journal.json screenshot.png verify-draft.json; do
  label="kill-after-${canonical_name//[^A-Za-z0-9]/-}"
  prepare_repo "$label"
  FAKE_PUBLICATION_KILL_AFTER_TARGET="$canonical_name" expect_execute_failure "$label" "atomic draft publication failed"
  : >"$fake_log"
  run_execute
  [[ -f "$draft" ]] || { echo "same-Head retry failed after kill after $canonical_name" >&2; exit 1; }
  if [[ "$canonical_name" == verify-draft.json ]] && /usr/bin/awk -F '\t' '$1 == "xcodebuild" {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
    echo "complete canonical draft transaction was re-executed" >&2; exit 1
  fi
done

prepare_repo kill-before-final
run_execute
write_visual approved
FAKE_PUBLICATION_KILL_TARGET=verify.json expect_finalize_failure kill-before-final "visual result is invalid"
run_finalize
[[ -f "$final" ]] || { echo "final retry failed after kill before canonical rename" >&2; exit 1; }

prepare_repo kill-after-final
run_execute
write_visual approved
if FAKE_PUBLICATION_KILL_AFTER_TARGET=verify.json run_finalize >"$scratch/kill-after-final.stdout" 2>"$scratch/kill-after-final.stderr"; then
  echo "kill-after-final fixture unexpectedly returned success" >&2; exit 1
fi
[[ -f "$final" ]] || { echo "kill after final rename did not leave canonical evidence" >&2; exit 1; }
run_finalize
[[ -f "$final" ]] || { echo "final retry did not accept exact canonical evidence" >&2; exit 1; }

prepare_repo corrupt-after-final
run_execute
write_visual approved
if FAKE_PUBLICATION_KILL_AFTER_TARGET=verify.json run_finalize >"$scratch/corrupt-after-final.stdout" 2>"$scratch/corrupt-after-final.stderr"; then
  echo "corrupt-after-final fixture unexpectedly returned success" >&2; exit 1
fi
/bin/chmod 0600 "$final"
printf '%s\n' corrupt-final >"$final"
/bin/chmod 0400 "$final"
if run_finalize >"$scratch/corrupt-final-retry.stdout" 2>"$scratch/corrupt-final-retry.stderr"; then
  echo "finalizer accepted corrupt existing canonical evidence" >&2; exit 1
fi
grep -Fq 'canonical verify.json already exists' "$scratch/corrupt-final-retry.stderr" || { echo "corrupt final retry reported the wrong error" >&2; exit 1; }

prepare_repo concurrent-lock
hold_file="$scratch/concurrent-hold"
FAKE_HOLD_BUILD_FILE="$hold_file" run_execute >"$scratch/concurrent-first.stdout" 2>"$scratch/concurrent-first.stderr" &
first_runner_pid=$!
for _ in $(/usr/bin/jot 600); do
  [[ ! -e "$hold_file.started" ]] || break
  /bin/sleep 0.05
done
[[ -e "$hold_file.started" ]] || { echo "first concurrent runner did not reach Build" >&2; exit 1; }
expect_execute_failure concurrent-lock "lock"
workspace="$(runner_workspace)"
attempt_count="$(/usr/bin/find "$workspace/Attempts" -mindepth 1 -maxdepth 1 -type d -name 'attempt-*' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$attempt_count" == 1 ]] || { echo "lock loser retained a private attempt" >&2; exit 1; }
: >"$hold_file.release"
wait "$first_runner_pid"
[[ -f "$draft" ]] || { echo "concurrent lock winner did not publish draft" >&2; exit 1; }

prepare_repo killed-lock-owner
killed_hold="$scratch/killed-lock-hold"
FAKE_HOLD_BUILD_FILE="$killed_hold" run_execute >"$scratch/killed-lock.stdout" 2>"$scratch/killed-lock.stderr" &
killed_runner_pid=$!
for _ in $(/usr/bin/jot 600); do
  [[ ! -e "$killed_hold.started" ]] || break
  /bin/sleep 0.05
done
[[ -e "$killed_hold.started" ]] || { echo "kill fixture did not acquire lock" >&2; exit 1; }
killed_owner_pid="$(/bin/cat "$killed_hold.owner")"
[[ "$killed_owner_pid" =~ ^[1-9][0-9]*$ ]] || { echo "kill fixture recorded an invalid runner owner" >&2; exit 1; }
/bin/kill -KILL "$killed_owner_pid"
wait "$killed_runner_pid" 2>/dev/null || true
run_execute
: >"$killed_hold.release"
[[ -f "$draft" ]] || { echo "retry after killed owner did not publish draft" >&2; exit 1; }

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

for mode in rejected wrong-digest wrong-head missing-case case-finding wrong-screenshot-digest; do
  prepare_repo "final-$mode"
  run_execute
  write_visual "$mode"
  expect_finalize_failure "final-$mode" "visual"
done

prepare_repo screenshot-byte-mutation
run_execute
write_visual approved
screenshot_path="$(dirname "$draft")/iphone-en/screenshot.png"
/bin/chmod 0600 "$screenshot_path"
printf 'changed-after-draft' >>"$screenshot_path"
/bin/chmod 0400 "$screenshot_path"
expect_finalize_failure screenshot-byte-mutation "visual"

prepare_repo draft-mutation
run_execute
write_visual approved
/bin/chmod 0600 "$draft"
printf '\n' >>"$draft"
expect_finalize_failure draft-mutation "visual"

prepare_repo draft-nested-schema-mutation
run_execute
write_packet
/bin/chmod 0600 "$draft"
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
write_packet
/bin/chmod 0600 "$draft"
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
write_packet
/bin/chmod 0600 "$draft"
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

for source in contract matrix; do
  prepare_repo "final-publication-race-$source"
  run_execute
  write_visual approved
  FAKE_PUBLICATION_RACE="$source" expect_finalize_failure "final-publication-race-$source" "visual result is invalid"
done

prepare_repo final-publication-race-candidate
run_execute
write_visual approved
FAKE_PUBLICATION_RACE=candidate expect_finalize_failure final-publication-race-candidate "visual result is invalid"
[[ ! -e "$final" ]] || { echo "publication-boundary candidate substitution became canonical" >&2; exit 1; }

prepare_repo final-collision
run_execute
write_visual approved
if FAKE_COLLIDE_FINAL=1 run_finalize >"$scratch/final-collision.stdout" 2>"$scratch/final-collision.stderr"; then
  echo "finalizer replaced an existing canonical winner" >&2; exit 1
fi
grep -Fq "canonical verify.json already exists" "$scratch/final-collision.stderr"
grep -Fq sentinel-final "$final" || { echo "final collision changed the winner" >&2; exit 1; }

prepare_repo candidate-substitution
run_execute
write_visual approved
FAKE_CANDIDATE_MODE=substitute expect_finalize_failure candidate-substitution "visual result is invalid"
[[ ! -e "$final" ]] || { echo "substituted candidate became canonical" >&2; exit 1; }

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
