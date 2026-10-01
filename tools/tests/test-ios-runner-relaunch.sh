#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

# Declared relaunchArguments reach only the relaunch before the screenshot and are bound to the visual evidence.
validate_final() {
  (cd "$repo" && "$validator_binary" --file "$final" --expected-issue 42 \
    --expected-base "$base_sha" --expected-head "$head_sha")
}

assert_launches() {
  /usr/bin/ruby - "$fake_log" "$1" <<'RUBY'
lines = File.readlines(ARGV.fetch(0), chomp: true).map { |line| line.split("\t") }
english = lines.select { |fields| fields[2, 2] == %w[simctl launch] && fields[7] == "(en)" && fields[4].end_with?("000001") }
abort "expected initial launch and UI relaunch" unless english.length == 2
locale = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
abort "initial launch changed" unless english[0][6..] == locale
expected = ARGV.fetch(1) == "declared" ? locale + ["-verify-mode", "ready state", "-phase=2"] : locale
abort "UI relaunch arguments changed" unless english[1][6..] == expected
RUBY
}

prepare_repo relaunch-absent
FAKE_OBSERVE_CLEANUP=1 run_execute
assert_launches absent
write_visual approved
run_finalize
validate_final
for path in "$adapter_state/cleanup-observation/config.json" "$draft" "$(dirname "$draft")/visual-packet.json" "$final"; do
  ! rg -q 'relaunchArguments' "$path" || { echo "undeclared output changed: $path" >&2; exit 1; }
done

prepare_repo relaunch-declared
/usr/bin/ruby -I"$source_repo/tools/lib" -rjson -rissue-contract - "$contract" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.binread(path))
document.fetch("verification").fetch("cases").fetch(0)["relaunchArguments"] = ["-verify-mode", "ready state", "-phase=2"]
File.binwrite(path, IOSTemplate::IssueContract.canonical_json(document))
RUBY

cp "$contract" "$scratch/relaunch-contract.good"
for mode in assertion secret opaque; do
  /usr/bin/ruby -I"$source_repo/tools/lib" -rjson -rissue-contract - "$contract" "$mode" <<'RUBY'
path, mode = ARGV
document = JSON.parse(File.binread(path))
cases = document.fetch("verification").fetch("cases")
if mode == "assertion"
  cases.fetch(1)["relaunchArguments"] = ["-verify-mode"]
else
  cases.fetch(0)["relaunchArguments"] = mode == "secret" ? ["token=abc"] : ["a" * 32]
end
File.binwrite(path, IOSTemplate::IssueContract.canonical_json(document))
RUBY
  if (cd "$repo" && "$validator_binary" --runner-snapshot --issue 42 \
      --expected-base "$base_sha" --expected-head "$head_sha" \
      --issue-contract .artifacts/issues/42/issue-contract.json \
      --matrix .artifacts/batches/runner-fixture/simulator-matrix.json \
      --project TemplateApp.xcodeproj) >"$scratch/relaunch-$mode.out" 2>"$scratch/relaunch-$mode.err"; then
    echo "Swift validator accepted invalid $mode relaunchArguments" >&2; exit 1
  fi
  rg -q 'issueContract.verification.cases' "$scratch/relaunch-$mode.err" || {
    echo "Swift validator rejected $mode for an unrelated reason" >&2; exit 1
  }
  cp "$scratch/relaunch-contract.good" "$contract"
done

receipt="$(cd "$repo" && "$validator_binary" --runner-snapshot --issue 42 \
  --expected-base "$base_sha" --expected-head "$head_sha" \
  --issue-contract .artifacts/issues/42/issue-contract.json \
  --matrix .artifacts/batches/runner-fixture/simulator-matrix.json \
  --project TemplateApp.xcodeproj)"
IFS=$'\t' read -r config digest _ <<<"$receipt"
"$validator_binary" --runner-config --config "$config" --digest "$digest" \
  --get-lines cases.0.relaunchArguments >"$scratch/actual-lines"
printf '%s\n' '-verify-mode' 'ready state' '-phase=2' >"$scratch/expected-lines"
cmp "$scratch/actual-lines" "$scratch/expected-lines"
"$validator_binary" --runner-config --config "$config" --digest "$digest" \
  --get-lines cases.1.relaunchArguments >"$scratch/absent-lines"
[[ ! -s "$scratch/absent-lines" ]]
cp "$config" "$scratch/relaunch-config.good"
for mode in scalar nonstring newline carriage-return; do
  chmod 0600 "$config"
  /usr/bin/ruby -rjson - "$config" "$mode" <<'RUBY'
path, mode = ARGV
document = JSON.parse(File.binread(path))
document.fetch("cases").fetch(0)["relaunchArguments"] =
  {"scalar" => "state", "nonstring" => [3], "newline" => ["bad\nstate"],
   "carriage-return" => ["bad\rstate"]}.fetch(mode)
File.binwrite(path, JSON.generate(document))
RUBY
  chmod 0400 "$config"
  changed_digest="sha256:$(/usr/bin/shasum -a 256 "$config" | /usr/bin/awk '{print $1}')"
  if "$validator_binary" --runner-config --config "$config" --digest "$changed_digest" \
      --get-lines cases.0.relaunchArguments >"$scratch/get-lines-$mode.out" 2>"$scratch/get-lines-$mode.err"; then
    echo "get-lines accepted invalid $mode value" >&2; exit 1
  fi
  chmod 0600 "$config"
  cp "$scratch/relaunch-config.good" "$config"
  chmod 0400 "$config"
done
"$validator_binary" --runner-clean-attempt --config "$config" --digest "$digest"

run_execute
assert_launches declared
write_visual approved
run_finalize
validate_final
/usr/bin/ruby -rjson - "$draft" "$(dirname "$draft")/visual-packet.json" "$final" <<'RUBY'
expected = ["-verify-mode", "ready state", "-phase=2"]
ARGV.each do |path|
  cases = JSON.parse(File.binread(path)).fetch("cases")
  abort "declared arguments missing: #{path}" unless cases.fetch(0).fetch("relaunchArguments") == expected
  abort "undeclared case gained arguments: #{path}" if cases.drop(1).any? { |entry| entry.key?("relaunchArguments") }
end
RUBY

packet="$(dirname "$draft")/visual-packet.json"
cp "$packet" "$scratch/packet.good"
chmod 0600 "$packet"
/usr/bin/ruby -rjson - "$packet" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.binread(path))
document.fetch("cases").fetch(0)["relaunchArguments"] = ["-wrong-state"]
File.binwrite(path, JSON.pretty_generate(document) + "\n")
RUBY
chmod 0400 "$packet"
if validate_final >"$scratch/packet-mutation.out" 2>"$scratch/packet-mutation.err"; then
  echo "validator accepted changed visual packet relaunchArguments" >&2; exit 1
fi
chmod 0600 "$packet"
cp "$scratch/packet.good" "$packet"
chmod 0400 "$packet"

chmod 0600 "$final"
/usr/bin/ruby -rjson - "$final" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.binread(path))
document.fetch("cases").fetch(0)["relaunchArguments"] = ["-wrong-state"]
File.binwrite(path, JSON.pretty_generate(document) + "\n")
RUBY
chmod 0400 "$final"
if validate_final >"$scratch/final-mutation.out" 2>"$scratch/final-mutation.err"; then
  echo "validator accepted changed final relaunchArguments" >&2; exit 1
fi

assert_runner_publication_cleanup
echo "relaunch iOS runner tests passed"
