#!/usr/bin/env bash
set -euo pipefail

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

prepare_repo valid
run_execute
resource_config="$(/usr/bin/find "$(runner_workspace)/Attempts" -mindepth 2 -maxdepth 2 -type f -name config.json -print -quit)"
[[ -n "$resource_config" ]] || { echo "runner did not retain its sealed resource ownership config" >&2; exit 1; }
/usr/bin/ruby -rjson - "$resource_config" <<'RUBY'
config = JSON.parse(File.read(ARGV.fetch(0)))
abort "runner config did not seal the batch identity" unless config.fetch("batchId") == "runner-fixture"
abort "runner config did not seal the runtime identity" unless config.fetch("runtime") == {
  "identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version" => "26.5"
}
expected = %w[iphone-en iphone-ja ipad-en ipad-ja].map { |id| "iOS-Template-runner-fixture-#{id}" }
abort "runner config did not seal dedicated Simulator names" unless config.fetch("cases").map { |entry| entry.fetch("name") } == expected
abort "runner config did not seal Device Type identities" unless config.fetch("cases").all? do |entry|
  entry.fetch("deviceType").keys.sort == %w[identifier name]
end
RUBY
/usr/bin/ruby - "$fake_log" <<'RUBY'
lines = File.readlines(ARGV.fetch(0), chomp: true).map { |line| line.split("\t") }
owned = (1..4).map { |slot| format("00000000-0000-0000-0000-%012d", slot) }
simctl = lines.each_index.select { |index| lines[index][0] == "xcrun" && lines[index][2] == "simctl" }
erase = simctl.select { |index| lines[index][3] == "erase" }
abort "runner did not perform exact startup, post-unit, and per-case erase" unless erase.length == 9
abort "startup erase did not cover the exact four-device set" unless erase.first(4).map { |index| lines[index][4] } == owned
build = lines.index { |fields| fields[0] == "xcodebuild" && fields.last == "build-for-testing" }
unit = lines.index { |fields| fields[0] == "xcodebuild" && fields.last == "test-without-building" && fields.any? { |field| field.include?("TemplateAppTests/UnitSmokeTests") } }
abort "startup reclamation did not precede Build" unless erase.first(4).all? { |index| index < build }
abort "post-unit reclamation did not precede first UI case" unless erase[4] > unit && lines[erase[4]][4] == owned[0]
owned.each_with_index do |udid, offset|
  screenshot = lines.index { |fields| fields[0] == "xcrun" && fields[2] == "simctl" && fields[3] == "io" && fields[4] == udid }
  final_terminate = lines.each_index.select { |index| lines[index][0] == "xcrun" && lines[index][2] == "simctl" && lines[index][3] == "terminate" && lines[index][4] == udid }.last
  shutdown = lines.each_index.select { |index| lines[index][0] == "xcrun" && lines[index][2] == "simctl" && lines[index][3] == "shutdown" && lines[index][4] == udid }.last
  final_erase = erase[5 + offset]
  abort "case resource reclamation order is invalid for #{udid}" unless screenshot < final_terminate && final_terminate < shutdown && shutdown < final_erase
end
unrelated = "00000000-0000-0000-0000-999999999999"
abort "runner mutated an unrelated Simulator" if lines.any? do |fields|
  fields[0] == "xcrun" && fields[2] == "simctl" && %w[shutdown erase delete].include?(fields[3]) && fields[4] == unrelated
end
RUBY
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
for case_id in iphone-en iphone-ja ipad-en ipad-ja; do
  screenshot="$workspace_root/Screenshots/$case_id.png"
  receipt="$workspace_root/$case_id-screenshot.sha256"
  [[ "$(/usr/bin/stat -f '%Lp' "$screenshot")" == 400 && "$(/usr/bin/stat -f '%Lp' "$receipt")" == 400 ]] || {
    echo "case screenshot and digest receipt were not durably sealed" >&2; exit 1
  }
  [[ "$(/bin/cat "$receipt")" == "sha256:$(/usr/bin/shasum -a 256 "$screenshot" | /usr/bin/awk '{print $1}')" ]] || {
    echo "case screenshot receipt does not bind the host PNG" >&2; exit 1
  }
done

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
    next if %w[list shutdown erase].include?(command)
    udid = fields.fetch(4)
    label = command == "io" ? "screenshot" : command
    sequence << "#{case_for.fetch(udid)}-#{label}"
    next
  end
end
expected = %w[
  xcode-version build build-diagnostics unit-test unit-diagnostics unit-summary unit-tests
  iphone-en-boot iphone-en-bootstatus iphone-en-install iphone-en-get_app_container iphone-en-terminate iphone-en-launch iphone-en-spawn iphone-en-ui-test iphone-en-diagnostics iphone-en-summary iphone-en-tests iphone-en-terminate iphone-en-launch iphone-en-get_app_container iphone-en-spawn iphone-en-spawn iphone-en-screenshot iphone-en-terminate
  iphone-ja-boot iphone-ja-bootstatus iphone-ja-install iphone-ja-get_app_container iphone-ja-terminate iphone-ja-launch iphone-ja-spawn iphone-ja-spawn iphone-ja-screenshot iphone-ja-terminate
  ipad-en-boot ipad-en-bootstatus ipad-en-install ipad-en-get_app_container ipad-en-terminate ipad-en-launch ipad-en-spawn ipad-en-ui-test ipad-en-diagnostics ipad-en-summary ipad-en-tests ipad-en-terminate ipad-en-launch ipad-en-get_app_container ipad-en-spawn ipad-en-spawn ipad-en-screenshot ipad-en-terminate
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


assert_runner_publication_cleanup
echo "baseline iOS runner tests passed"
