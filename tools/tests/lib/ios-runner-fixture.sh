#!/usr/bin/env bash
set -euo pipefail

source_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
scratch="$(mktemp -d "$HOME/Library/Caches/ios-runner.XXXXXX")"
scratch="$(cd "$scratch" && pwd -P)"
unrelated_timeout_pid=''
cleanup_lock_pid=''
cleanup_immutable_file=''
cleanup_test() {
  if [[ -n "$cleanup_immutable_file" ]]; then
    chflags nouchg "$cleanup_immutable_file" 2>/dev/null || true
  fi
  if [[ -n "$cleanup_lock_pid" ]]; then
    /bin/kill "$cleanup_lock_pid" >/dev/null 2>&1 || true
    wait "$cleanup_lock_pid" 2>/dev/null || true
  fi
  if [[ -n "$unrelated_timeout_pid" ]]; then
    /bin/kill "$unrelated_timeout_pid" >/dev/null 2>&1 || true
    wait "$unrelated_timeout_pid" 2>/dev/null || true
  fi
  [[ "${KEEP_IOS_RUNNER_SCRATCH-}" == 1 ]] || rm -rf "$scratch"
}
trap cleanup_test EXIT

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
/bin/cp "$source_repo/tools/lib/bounded-command.sh" "$test_source/tools/lib/bounded-command.sh"
/bin/cp "$source_repo/tools/lib/bounded-command.rb" "$test_source/tools/lib/bounded-command.rb"
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
    if (try? String(contentsOfFile: "#{state_dir}/publication_kill_owner", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == "1",
       let owner = try? String(contentsOfFile: "#{state_dir}/runner-owner", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       let pid = Int32(owner) {
        _ = kill(pid, SIGKILL)
    }
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
/usr/bin/ruby - "$runner" "$adapter_state/runner-owner" <<'RUBY'
path, owner = ARGV
text = File.read(path)
text.sub!('stage="input-validation"', 'printf "%s\\n" "$$" >"' + owner + '"' + "\n" + 'stage="input-validation"')
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
  printf '%s\n' Booted >"$state_dir/device-state-$(state first_udid)"
  mutate_path="$(state mutate_worktree_path)"
  [[ "$(state mutate_worktree)" != 1 || -z "$mutate_path" ]] || printf '%s\n' MUTATED-WORKTREE >"$mutate_path"
  [[ "$parallel" == NO && "$destination_count" == 1 && "$destination" == *id="$(state first_udid)" ]] || { echo 'build destination or parallel setting is invalid' >&2; exit 1; }
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
  [[ "$destination" == *id="$(state first_udid)" ]] || { echo 'wrong unit destination' >&2; exit 1; }
  [[ -z "$language$region" && "$result" == */Tests.xcresult ]] || { echo 'unit stage included UI locale or wrong result' >&2; exit 1; }
  mkdir -p "$result"
  printf '%s\n' Booted >"$state_dir/device-state-$(state first_udid)"
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
  *id=00000000-0000-0000-0000-000000000002) expected_case=iphone-ja; expected_language=ja; expected_region=JP ;;
  *id=00000000-0000-0000-0000-000000000003) expected_case=ipad-en; expected_language=en; expected_region=US ;;
  *) echo 'wrong UI destination' >&2; exit 1 ;;
esac
[[ "$identifier" == TemplateAppUITests/SmokeTests/testLaunch ]] || { echo 'wrong UI identifier' >&2; exit 1; }
[[ "$language" == "$expected_language" && "$region" == "$expected_region" ]] || { echo 'wrong UI locale' >&2; exit 1; }
[[ "$result" == */Cases/"$expected_case".xcresult ]] || { echo 'wrong or missing UI result path' >&2; exit 1; }
mkdir -p "$result"
: >"$state_dir/ui-ran-$expected_case"
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
    if [[ "${1-}" == --runner-clean-attempt && "$(state observe_cleanup)" == 1 ]]; then
      /usr/bin/ruby -rjson -rdigest -rfileutils - "$3" "$state_dir/cleanup-observation" <<'RUBY'
config_path, destination = ARGV
config = JSON.parse(File.read(config_path))
FileUtils.mkdir_p(destination)
File.open(config.fetch('lockPath'), File::RDWR) do |lock|
  abort 'attempt cleanup ran without the Head lock' if lock.flock(File::LOCK_EX | File::LOCK_NB)
end
root = config.fetch('attemptRoot')
abort 'attempt permissions changed before cleanup' unless File.stat(root).mode & 0777 == 0700
Dir.glob(root + '/Screenshots/*.png').each do |image|
  receipt = root + '/' + File.basename(image, '.png') + '-screenshot.sha256'
  abort 'screenshot was not sealed before cleanup' unless [image, receipt].all? { |path| File.stat(path).mode & 0777 == 0400 }
  abort 'screenshot receipt mismatch before cleanup' unless File.read(receipt).strip == 'sha256:' + Digest::SHA256.file(image).hexdigest
end
FileUtils.cp(config_path, destination + '/config.json')
File.write(destination + '/checked', 'lock, config, directory mode, screenshot seal and digest')
RUBY
    fi
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
    passed=1 failed=0 skipped=0 total=1 udid="$(state first_udid)"
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
      */Cases/iphone-ja.xcresult) udid=00000000-0000-0000-0000-000000000002 ;;
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
    if [[ "$(state system_locale_mode)" == restart-lost ]]; then
      /bin/rm -f "$state_dir/system-language-${3-}"
    fi
    for preference in language locale; do
      /bin/rm -f "$state_dir/active-system-$preference-${3-}"
      if [[ -f "$state_dir/system-$preference-${3-}" ]]; then
        /bin/cp "$state_dir/system-$preference-${3-}" "$state_dir/active-system-$preference-${3-}"
      fi
    done
    prebooted_marker="$state_dir/prebooted-fired-${3-}"
    if [[ "$(state prebooted)" == 1 && ! -e "$prebooted_marker" ]]; then
      : >"$prebooted_marker"
      printf '%s\n' Booted >"$state_dir/device-state-${3-}"
      exit 1
    fi
    printf '%s\n' Booted >"$state_dir/device-state-${3-}"
    ;;
  list)
    [[ "${3-}" == devices && "${4-}" == --json ]] || { echo 'wrong simulator state query' >&2; exit 1; }
    /usr/bin/ruby --disable-gems -rjson - "$state_dir" "$(state simulator_identity_mode)" <<'RUBY'
state_dir, mode = ARGV
runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
rows = [
  ["iphone-en", "00000000-0000-0000-0000-000000000001", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"],
  ["iphone-ja", "00000000-0000-0000-0000-000000000002", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"],
  ["ipad-en", "00000000-0000-0000-0000-000000000003", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3"],
  ["ipad-ja", "00000000-0000-0000-0000-000000000004", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3"]
]
devices = rows.map do |id, udid, type|
  state_path = File.join(state_dir, "device-state-#{udid}")
  {
    "udid" => udid,
    "name" => "iOS-Template-runner-fixture-#{id}",
    "state" => File.exist?(state_path) ? File.read(state_path).strip : "Booted",
    "isAvailable" => true,
    "deviceTypeIdentifier" => type
  }
end
devices.pop if mode == "missing"
devices[3]["name"] = "tampered" if mode == "wrong"
devices[3]["isAvailable"] = false if mode == "unavailable"
devices[3]["deviceTypeIdentifier"] = "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M3" if mode == "wrong-type"
wrong_runtime_device = devices.pop if mode == "wrong-runtime"
devices << {
  "udid" => "00000000-0000-0000-0000-999999999999",
  "name" => mode == "duplicate" ? "iOS-Template-runner-fixture-iphone-en" : "Unrelated Personal Simulator",
  "state" => "Shutdown",
  "isAvailable" => true,
  "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
}
document = {"devices" => {runtime => devices}}
document.fetch("devices")["com.apple.CoreSimulator.SimRuntime.iOS-25-0"] = [wrong_runtime_device] if wrong_runtime_device
puts JSON.generate(document)
RUBY
    ;;
  shutdown)
    if [[ "$(state case_mode)" == term-blocked-probe && "${3-}" == "00000000-0000-0000-0000-000000000001" && -e "$state_dir/term-blocked-probe-pgid" ]]; then
      probe_pgid="$(state term-blocked-probe-pgid)"
      if [[ "$probe_pgid" =~ ^[1-9][0-9]*$ ]] && /bin/kill -0 -- "-$probe_pgid" >/dev/null 2>&1; then
        : >"$state_dir/term-cleanup-before-probe-stop"
        exit 1
      fi
    fi
    [[ "$(state resource_failure)" != shutdown-after-case || "${3-}" != "00000000-0000-0000-0000-000000000001" || ! -e "$state_dir/ui-ran-iphone-en" ]] || exit 1
    printf '%s\n' Shutdown >"$state_dir/device-state-${3-}"
    ;;
  erase)
    if [[ "$(state case_mode)" == term-blocked-probe && "${3-}" == "00000000-0000-0000-0000-000000000001" && -e "$state_dir/term-blocked-probe-pgid" ]]; then
      probe_pgid="$(state term-blocked-probe-pgid)"
      if [[ "$probe_pgid" =~ ^[1-9][0-9]*$ ]] && /bin/kill -0 -- "-$probe_pgid" >/dev/null 2>&1; then
        : >"$state_dir/term-cleanup-before-probe-stop"
        exit 1
      fi
    fi
    [[ "$(state resource_failure)" != erase-after-case || "${3-}" != "00000000-0000-0000-0000-000000000001" || ! -e "$state_dir/ui-ran-iphone-en" ]] || exit 1
    [[ "$(state "device-state-${3-}")" == Shutdown ]] || { echo 'erase requires Shutdown' >&2; exit 1; }
    erase_count_file="$state_dir/erase-count-${3-}"
    erase_count=0
    [[ ! -f "$erase_count_file" ]] || erase_count="$(/bin/cat "$erase_count_file")"
    printf '%s\n' "$((erase_count + 1))" >"$erase_count_file"
    /bin/rm -f "$state_dir/system-language-${3-}" "$state_dir/system-locale-${3-}" \
      "$state_dir/active-system-language-${3-}" "$state_dir/active-system-locale-${3-}"
    ;;
  bootstatus) exit 0 ;;
  get_app_container)
    [[ "${4-}" == com.example.TemplateApp && "${5-}" == app ]] || { echo 'wrong app container lookup' >&2; exit 1; }
    container_root=Containers
    if [[ "${3-}" == "00000000-0000-0000-0000-000000000001" && -e "$state_dir/ui-ran-iphone-en" ]] || \
       [[ "${3-}" == "00000000-0000-0000-0000-000000000003" && -e "$state_dir/ui-ran-ipad-en" ]]; then
      container_root=ContainersAfterUI
    fi
    printf '%s\n' "/Users/fixture/$container_root/${3-}/TemplateApp.app"
    ;;
  terminate)
    if [[ "$(state case_mode)" == term-blocked-probe && "${3-}" == "00000000-0000-0000-0000-000000000001" && -e "$state_dir/term-blocked-probe-pgid" ]]; then
      probe_pgid="$(state term-blocked-probe-pgid)"
      if [[ "$probe_pgid" =~ ^[1-9][0-9]*$ ]] && /bin/kill -0 -- "-$probe_pgid" >/dev/null 2>&1; then
        : >"$state_dir/term-cleanup-before-probe-stop"
        exit 1
      fi
    fi
    if [[ "$(state mutate_after_case)" =~ ^(contract|matrix)$ && "${3-}" == "00000000-0000-0000-0000-000000000001" && ! -e "$state_dir/mutate-after-case-fired" ]] && \
       /usr/bin/awk -F '\t' '$3 == "simctl" && $4 == "io" && $5 == "00000000-0000-0000-0000-000000000001" {seen=1} END {exit seen ? 0 : 1}' "$fake_log"; then
      : >"$state_dir/mutate-after-case-fired"
       printf '\n' >>"$(state "$(state mutate_after_case)_path")"
    fi
    [[ "$(state resource_failure)" != terminate-after-case || "${3-}" != "00000000-0000-0000-0000-000000000001" || ! -e "$state_dir/ui-ran-iphone-en" ]] || exit 1
    exit 0
    ;;
  install)
    [[ "$(state resource_failure)" != install || "${3-}" != "00000000-0000-0000-0000-000000000001" ]] || exit 1
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
    if [[ "${4-}" == defaults ]]; then
      [[ "$(state "device-state-${3-}")" == Booted ]] || { echo 'preferences require Booted device' >&2; exit 1; }
      if [[ "${5-}" == write && "${6-}" == -g && "${7-}" == AppleLanguages && "${8-}" == -array && $# == 9 ]]; then
        [[ "$(state system_locale_mode)" != write-language ]] || exit 1
        printf '%s\n' "${9-}" >"$state_dir/system-language-${3-}"
      elif [[ "${5-}" == write && "${6-}" == -g && "${7-}" == AppleLocale && "${8-}" == -string && $# == 9 ]]; then
        [[ "$(state system_locale_mode)" != write-locale ]] || exit 1
        printf '%s\n' "${9-}" >"$state_dir/system-locale-${3-}"
      elif [[ "${5-}" == export && "${6-}" == -g && "${7-}" == - && $# == 7 ]]; then
        [[ "$(state system_locale_mode)" != read-failure ]] || exit 1
        /usr/bin/ruby --disable-gems - "$state_dir" "${3-}" "$(state system_locale_mode)" <<'RUBY'
directory, udid, mode = ARGV
read = ->(name) { path = File.join(directory, "#{name}-#{udid}"); File.file?(path) ? File.read(path).strip : nil }
language, locale = read.call("system-language"), read.call("system-locale")
abort "SpringBoard did not reload the declared preferences" unless language == read.call("active-system-language") && locale == read.call("active-system-locale")
if mode == "malformed"
  puts "not a property list"
  exit
end
language = "fr-FR" if mode == "wrong-language" || (mode == "post-ui-drift" && File.exist?(File.join(directory, "ui-ran-iphone-en")))
locale = "fr_FR" if mode == "wrong-locale"
language = nil if mode == "missing-language"
languages = if mode == "wrong-type"
  "<key>AppleLanguages</key><string>#{language}</string>"
elsif language
  extra = mode == "extra-language" ? "<string>fr-FR</string>" : ""
  "<key>AppleLanguages</key><array><string>#{language}</string>#{extra}</array>"
else
  ""
end
puts %(<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>#{languages}<key>AppleLocale</key><string>#{locale}</string></dict></plist>)
RUBY
      else
        echo 'unexpected system preferences command' >&2; exit 1
      fi
      exit 0
    fi
    if [[ "$(state case_mode)" == term-blocked-probe && "${3-}" == "00000000-0000-0000-0000-000000000001" && "${4-}" == /bin/kill ]]; then
      printf '%s\n' "$$" >"$state_dir/term-blocked-probe-pid"
      /bin/ps -o pgid= -p "$$" | /usr/bin/tr -d ' ' >"$state_dir/term-blocked-probe-pgid"
      printf '%s\n' "$PPID" >"$state_dir/term-blocked-runner-pid"
      trap 'exit 143' TERM
      while true; do /bin/sleep 0.05; done
    fi
    if [[ "$(state case_mode)" == stubborn-probe && "${3-}" == "00000000-0000-0000-0000-000000000001" && "${4-}" == /bin/kill ]]; then
      /bin/ps -o pgid= -p "$$" | /usr/bin/tr -d ' ' >"$state_dir/stubborn-probe-pgid"
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
      container_root=Containers
      if [[ "${3-}" == "00000000-0000-0000-0000-000000000001" && -e "$state_dir/ui-ran-iphone-en" ]] || \
         [[ "${3-}" == "00000000-0000-0000-0000-000000000003" && -e "$state_dir/ui-ran-ipad-en" ]]; then
        container_root=ContainersAfterUI
      fi
      printf '%s\n' "/Users/fixture/$container_root/${3-}/TemplateApp.app/TemplateApp"
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
    [[ "$(state resource_failure)" != screenshot || "${3-}" != "00000000-0000-0000-0000-000000000001" ]] || exit 1
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
  delete) echo 'runner must never delete a Simulator' >&2; exit 1 ;;
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
  /usr/bin/ruby -I"$source_repo/tools/lib" -rissue-contract -rjson -rtime - "$1" "${2:-valid}" "${3:-full}" <<'RUBY'
path, mode, scope = ARGV
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
if %w[iphone-ja shape].include?(scope)
  cases.select! { |entry| entry["id"] == "iphone-ja" }
  mappings.each { |entry| entry["checks"].select! { |check| check.start_with?("stage:") || check.end_with?(":iphone-ja") } }
end
if scope == "shape"
  cases[0] = {"id" => "iphone-ja", "testIdentifier" => "TemplateAppUITests/SmokeTests/testLaunch"}
  mappings.each { |entry| entry["checks"].reject! { |check| check.start_with?("visual:") } }
end
document = {
  "schemaVersion" => 1, "issue" => 42, "repository" => "yuto1201/iOS-Template",
  "goal" => "Run reproducible iOS verification",
  "specAnchors" => ["docs/verification.md#4-execution-draft"],
  "acceptanceCriteria" => [
    {"id" => "AC-1", "text" => "UI-direction route: not-applicable; Scope: iOS verification runner fixture; Reason: This synthetic fixture validates verification tooling and does not change product UI; build and tests pass once"},
    {"id" => "AC-2", "text" => "Four localized cases pass mechanically"}
  ],
  "dependencies" => [], "externalOperations" => [],
  "externalOperationDetailsDigest" => "sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945",
  "fetchedAt" => Time.now.iso8601,
  "verification" => {
    "bundleIdentifier" => "com.example.TemplateApp",
    "unitTestIdentifier" => "TemplateAppTests/UnitSmokeTests/testUnit()",
    "cases" => cases,
    "acceptanceMappings" => mappings
  }
}
document.delete("verification") if mode == "absent"
document.fetch("verification").delete("unitTestIdentifier") if mode == "missing-unit-test" && document["verification"]
if mode == "valid"
  # Exercise the real producer-to-runner boundary. Malformed modes below remain
  # deliberate synthetic fixtures for the independent Swift validator.
  body = <<~BODY
    ## Goal
    #{document.fetch("goal")}
    ## In scope
    - Exercise application verification.
    ## Out of scope
    - External operations.
    ## Acceptance criteria
    #{document.fetch("acceptanceCriteria").map { |ac| "- #{ac.fetch('id')}: #{ac.fetch('text')}" }.join("\n")}
    ## Spec anchors
    - [Done](specs/acceptance.md#3-issue-definition-of-done)
    ## Dependencies
    None
    ## UI verification
    #{scope == "shape" ? "- Target screens/states: Main launch path.\n- English expectations: Deferred to release.\n- Japanese expectations: Main path is operable." : "Not applicable"}
    ## External operations
    None
    ## User approvals
    None
    ## Verification
    #{JSON.generate(document.fetch("verification"))}
  BODY
  if scope == "iphone-ja"
    body += "\n## Verification scope\n- Scope: iphone-ja\n- Stage: feature\n- Reason: Japanese iPhone feature fixture; finishing deferred.\n"
  elsif scope == "shape"
    body += <<~BODY

      ## Delivery profile
      - Profile: standard
      - Reason: Operable UI shape with bounded smoke verification.
      ## Delivery stage
      - Stage: shape
      - Time budget: 120 minutes
      - Reason: Confirm the primary flow before hardening.
      ## Verification scope
      - Scope: iphone-ja
      - Reason: One representative Japanese iPhone smoke path.
    BODY
  end
  produced = IOSTemplate::IssueContract.parse(
    body, issue: 42, repository: "yuto1201/iOS-Template", fetched_at: document.fetch("fetchedAt"),
    allow_legacy_delivery_stage: scope != "shape"
  ).contract
  File.write(path, IOSTemplate::IssueContract.canonical_json(produced))
else
  File.write(path, JSON.pretty_generate(document) + "\n")
end
RUBY
}

write_matrix() {
  /usr/bin/ruby -rjson -rtime - "$1" "$fake_developer" "${2:-full}" <<'RUBY'
path, developer, scope = ARGV
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
if %w[iphone-ja shape].include?(scope)
  document["scope"] = "iphone-ja"
  document["cases"].select! { |entry| entry["id"] == "iphone-ja" }
end
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
}

prepare_repo() {
  local label="$1" contract_mode="${2:-valid}" head_directory="${3:-present}" scope="${4:-full}"
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
  write_contract "$contract" "$contract_mode" "$scope"
  write_matrix "$matrix" "$scope"
  if [[ "$scope" == iphone-ja || "$scope" == shape ]]; then
    set_state first_udid 00000000-0000-0000-0000-000000000002
  else
    set_state first_udid 00000000-0000-0000-0000-000000000001
  fi
  : >"$fake_log"
  : >"$poison_log"
  /bin/rm -f "$poison_sentinel"
  for key in build_mode test_mode ui_mode case_mode mutate_input mutate_after_case prebooted preferred_invalid \
    hold_file collide_draft collide_final png_mode config_mode candidate_mode app_mode publication_race publication_kill publication_kill_target publication_kill_after_target mutate_worktree mutate_worktree_path simulator_identity_mode resource_failure system_locale_mode; do
    set_state "$key" ""
  done
  for spawn_state in "$adapter_state"/spawn-*; do
    [[ ! -e "$spawn_state" ]] || /bin/rm -f "$spawn_state"
  done
  /bin/rm -f "$adapter_state/app-mutated" "$adapter_state"/prebooted-fired-*
  /bin/rm -f "$adapter_state/publication-race-fired"
  /bin/rm -f "$adapter_state/publication-kill-fired" "$adapter_state/mutate-after-case-fired" "$adapter_state"/ui-ran-*
  /bin/rm -f "$adapter_state"/publication-kill-*
  /bin/rm -f "$adapter_state"/publication-kill-after-*
  /bin/rm -f "$adapter_state"/stubborn-probe-*
  /bin/rm -f "$adapter_state"/term-blocked-probe-* "$adapter_state/term-blocked-runner-pid" "$adapter_state/term-cleanup-before-probe-stop"
  /bin/rm -f "$adapter_state"/device-state-* "$adapter_state"/erase-count-*
  /bin/rm -f "$adapter_state"/system-language-* "$adapter_state"/system-locale-* "$adapter_state"/active-system-*
  for udid in \
    00000000-0000-0000-0000-000000000001 \
    00000000-0000-0000-0000-000000000002 \
    00000000-0000-0000-0000-000000000003 \
    00000000-0000-0000-0000-000000000004; do
    printf '%s\n' Booted >"$adapter_state/device-state-$udid"
  done
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
    echo "verification retained a private attempt" >&2
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
  set_state observe_cleanup "${FAKE_OBSERVE_CLEANUP-}"
  set_state app_mode "${FAKE_APP_MODE-}"
  set_state simulator_identity_mode "${FAKE_SIMULATOR_IDENTITY_MODE-}"
  set_state resource_failure "${FAKE_RESOURCE_FAILURE-}"
  set_state system_locale_mode "${FAKE_SYSTEM_LOCALE_MODE-}"
  set_state publication_race "${FAKE_PUBLICATION_RACE-}"
  set_state publication_kill "${FAKE_PUBLICATION_KILL-}"
  set_state publication_kill_owner "${FAKE_PUBLICATION_KILL_OWNER-}"
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

test_stubborn_probe() {
  prepare_repo stubborn-probe-timeout
  FAKE_CASE_MODE=stubborn-probe run_execute >"$scratch/stubborn-probe.stdout" 2>"$scratch/stubborn-probe.stderr" &
  stubborn_runner_pid=$!
  stubborn_child_pid=""
  for _ in $(/usr/bin/jot 800); do
    stubborn_child_pid="$(/bin/cat "$adapter_state/stubborn-probe-pid" 2>/dev/null || true)"
    [[ "$stubborn_child_pid" =~ ^[1-9][0-9]*$ ]] && break
    /bin/kill -0 "$stubborn_runner_pid" >/dev/null 2>&1 || break
    /bin/sleep 0.05
  done
  if [[ ! "$stubborn_child_pid" =~ ^[1-9][0-9]*$ ]]; then
    /bin/kill -KILL "$stubborn_runner_pid" >/dev/null 2>&1 || true
    wait "$stubborn_runner_pid" 2>/dev/null || true
    echo "bounded Simulator probe fixture did not reach its TERM-ignoring child" >&2
    exit 1
  fi
  stubborn_probe_pgid="$(/bin/cat "$adapter_state/stubborn-probe-pgid" 2>/dev/null || true)"
  if [[ ! "$stubborn_probe_pgid" =~ ^[1-9][0-9]*$ || "$stubborn_probe_pgid" != "$stubborn_child_pid" ]]; then
    /bin/kill -KILL "$stubborn_child_pid" >/dev/null 2>&1 || true
    /bin/kill -KILL "$stubborn_runner_pid" >/dev/null 2>&1 || true
    wait "$stubborn_runner_pid" 2>/dev/null || true
    echo "bounded Simulator probe fixture did not establish an isolated process group" >&2
    exit 1
  fi
  stubborn_finished=0
  for _ in $(/usr/bin/jot 400); do
    if ! /bin/kill -0 "$stubborn_runner_pid" >/dev/null 2>&1; then stubborn_finished=1; break; fi
    /bin/sleep 0.05
  done
  if [[ "$stubborn_finished" != 1 ]]; then
    /bin/kill -KILL -- "-$stubborn_probe_pgid" >/dev/null 2>&1 || true
    /bin/kill -KILL "$stubborn_runner_pid" >/dev/null 2>&1 || true
    wait "$stubborn_runner_pid" 2>/dev/null || true
    echo "bounded Simulator probe cleanup did not finish after KILL" >&2
    exit 1
  fi
  if wait "$stubborn_runner_pid"; then
    echo "stubborn Simulator probe unexpectedly succeeded" >&2; exit 1
  fi
  grep -Fq 'process liveness' "$scratch/stubborn-probe.stderr" || { echo "stubborn probe reported the wrong failure" >&2; exit 1; }
  if /bin/kill -0 -- "-$stubborn_probe_pgid" >/dev/null 2>&1; then
    /bin/kill -KILL -- "-$stubborn_probe_pgid" >/dev/null 2>&1 || true
    echo "bounded Simulator probe left its TERM-ignoring process group alive" >&2
    exit 1
  fi
  assert_no_failed_attempts
}

# Initial RED: the complete behavioral suite is enabled after this missing-runner assertion passes.
if [[ ! -e "$runner" ]]; then
  prepare_repo red-runner
  expect_execute_failure absent-runner "No such file or directory"
  echo "iOS runner RED tests are ready"
  exit 1
fi

assert_runner_publication_cleanup() {
  if find "$scratch" -name '*.tmp' -o -name '.verify-*' | rg -q .; then
    echo "runner left publication temporary files" >&2; exit 1
  fi
}
