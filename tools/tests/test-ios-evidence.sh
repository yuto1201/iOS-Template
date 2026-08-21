#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

fixtures="$repo_root/tools/tests/fixtures/verify"
scratch="$(mktemp -d -t ios-evidence.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT

validator_source="$repo_root/tools/validate-verify-json.swift"
validator="$scratch/validate-verify-json"
swift_bin="$(command -v swift)"
swiftc "$validator_source" -o "$validator"

head_sha="$(git rev-parse HEAD)"
base_sha="$(git rev-parse HEAD^)"
stale_sha="1111111111111111111111111111111111111111"
contract_digest="$(shasum -a 256 "$fixtures/issue-contract.json" | awk '{print $1}')"
matrix_fixture="$scratch/simulator-matrix.json"
ruby -rjson - "$matrix_fixture" <<'RUBY'
path = ARGV.fetch(0)
matrix = {
  "schemaVersion" => 1,
  "batchId" => "evidence-fixture",
  "resolvedAt" => "2026-08-21T12:00:00+09:00",
  "xcode" => {
    "path" => "/Applications/Xcode.app/Contents/Developer",
    "version" => "26.5",
    "build" => "17F42"
  },
  "runtime" => {
    "identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    "version" => "26.5"
  },
  "cases" => [
    ["iphone-en", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro", "en_US", "en"],
    ["iphone-ja", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro", "ja_JP", "ja"],
    ["ipad-en", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "en_US", "en"],
    ["ipad-ja", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "ja_JP", "ja"]
  ].map do |id, family, identifier, name, locale, language|
    {
      "id" => id,
      "family" => family,
      "deviceType" => {"identifier" => identifier, "name" => name},
      "locale" => locale,
      "language" => language
    }
  end
}
File.write(path, JSON.pretty_generate(matrix) + "\n")
RUBY
matrix_digest="$(shasum -a 256 "$matrix_fixture" | awk '{print $1}')"

poison_bin="$scratch/poison-bin"
poison_log="$scratch/poison.log"
mkdir -p "$poison_bin"
for command_name in xcrun xcodebuild simctl; do
  command_path="$poison_bin/$command_name"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$0 $*" >>"$POISON_LOG"' 'exit 97' >"$command_path"
  chmod +x "$command_path"
done

evidence_file=""
fixture_root=""
prepare_fixture() {
  local label="$1"
  local template="${2:-passed.json}"
  local fixture_head="${3:-$head_sha}"
  fixture_root="$scratch/$label/repository"
  local evidence_dir="$fixture_root/.artifacts/issues/42/$fixture_head"
  evidence_file="$evidence_dir/verify.json"
  mkdir -p "$evidence_dir" \
    "$fixture_root/.artifacts/issues/42" \
    "$fixture_root/.artifacts/batches/evidence-fixture"
  cp "$fixtures/issue-contract.json" "$fixture_root/.artifacts/issues/42/issue-contract.json"
  cp "$matrix_fixture" "$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json"
  cp -R "$fixtures/screenshots/." "$evidence_dir/"
  ruby - "$fixtures/$template" "$evidence_file" \
    "$base_sha" "$fixture_head" "$stale_sha" "$contract_digest" "$matrix_digest" <<'RUBY'
source, destination, base_sha, head_sha, stale_sha, contract_digest, matrix_digest = ARGV
text = File.read(source)
replacements = {
  "BASE_SHA" => base_sha,
  "HEAD_SHA" => head_sha,
  "STALE_SHA" => stale_sha,
  "CONTRACT_DIGEST" => contract_digest,
  "MATRIX_DIGEST" => matrix_digest
}
replacements.each { |key, value| text = text.gsub(key, value) }
File.write(destination, text)
RUBY
}

mutate_json() {
  local path="$1"
  local mutation="$2"
  MUTATION="$mutation" ruby -rjson - "$path" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.read(path))
eval(ENV.fetch("MUTATION"), binding, "test mutation")
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
}

run_validator() {
  local expected_head="${1:-$head_sha}"
  PATH="$poison_bin:$PATH" POISON_LOG="$poison_log" \
    "$validator" --file "$evidence_file" --expected-issue 42 --expected-head "$expected_head"
}

expect_failure() {
  local label="$1"
  local expected_head="${2:-$head_sha}"
  if run_validator "$expected_head" >"$scratch/$label.stdout" 2>"$scratch/$label.stderr"; then
    echo "validator unexpectedly accepted $label" >&2
    exit 1
  fi
}

prepare_fixture valid-passed
run_validator
PATH="$poison_bin:$PATH" POISON_LOG="$poison_log" \
  "$swift_bin" "$validator_source" --file "$evidence_file" --expected-issue 42 --expected-head "$head_sha"

if PATH="$poison_bin:$PATH" POISON_LOG="$poison_log" \
  "$validator" --file "$evidence_file" --expected-issue 41 --expected-head "$head_sha" \
  >"$scratch/wrong-expected-issue.stdout" 2>"$scratch/wrong-expected-issue.stderr"; then
  echo "validator accepted the wrong expected Issue" >&2
  exit 1
fi

prepare_fixture failed-case failed-case.json
expect_failure failed-case

prepare_fixture missing-screenshot
rm "$fixture_root/.artifacts/issues/42/$head_sha/iphone-ja/settings.png"
expect_failure missing-screenshot

prepare_fixture symlink-screenshot
rm "$fixture_root/.artifacts/issues/42/$head_sha/iphone-en/settings.png"
ln -s ../iphone-ja/settings.png "$fixture_root/.artifacts/issues/42/$head_sha/iphone-en/settings.png"
expect_failure symlink-screenshot

prepare_fixture escaping-screenshot
printf '%s\n' outside >"$fixture_root/outside.png"
mutate_json "$evidence_file" 'document.fetch("cases").fetch(0)["screenshot"] = "../../../../outside.png"'
expect_failure escaping-screenshot

prepare_fixture stale-sha stale-sha.json
expect_failure stale-sha

prepare_fixture skipped-test
mutate_json "$evidence_file" 'document.fetch("tests")["skipped"] = 1'
expect_failure skipped-test

prepare_fixture zero-tests
mutate_json "$evidence_file" 'document.fetch("tests")["passed"] = 0'
expect_failure zero-tests

prepare_fixture added-warning
mutate_json "$evidence_file" 'document.fetch("build")["warningsAdded"] = 1'
expect_failure added-warning

prepare_fixture duplicate-case
mutate_json "$evidence_file" 'document.fetch("cases").fetch(1)["id"] = "iphone-en"'
expect_failure duplicate-case

prepare_fixture missing-contract
rm "$fixture_root/.artifacts/issues/42/issue-contract.json"
expect_failure missing-contract

prepare_fixture symlink-contract
mv "$fixture_root/.artifacts/issues/42/issue-contract.json" "$fixture_root/.artifacts/issues/42/real-contract.json"
ln -s real-contract.json "$fixture_root/.artifacts/issues/42/issue-contract.json"
expect_failure symlink-contract

prepare_fixture missing-contract-digest
mutate_json "$evidence_file" 'document.fetch("issueContract").delete("digest")'
expect_failure missing-contract-digest

prepare_fixture changed-contract
printf '\n' >>"$fixture_root/.artifacts/issues/42/issue-contract.json"
expect_failure changed-contract

prepare_fixture wrong-contract-issue
mutate_json "$fixture_root/.artifacts/issues/42/issue-contract.json" 'document["issue"] = 43'
digest="$(shasum -a 256 "$fixture_root/.artifacts/issues/42/issue-contract.json" | awk '{print $1}')"
DIGEST="$digest" mutate_json "$evidence_file" 'document.fetch("issueContract")["digest"] = "sha256:" + ENV.fetch("DIGEST")'
expect_failure wrong-contract-issue

prepare_fixture duplicate-contract-ac
mutate_json "$fixture_root/.artifacts/issues/42/issue-contract.json" 'document.fetch("acceptanceCriteria") << document.fetch("acceptanceCriteria").first'
digest="$(shasum -a 256 "$fixture_root/.artifacts/issues/42/issue-contract.json" | awk '{print $1}')"
DIGEST="$digest" mutate_json "$evidence_file" 'document.fetch("issueContract")["digest"] = "sha256:" + ENV.fetch("DIGEST")'
expect_failure duplicate-contract-ac

prepare_fixture missing-execution-route
mutate_json "$evidence_file" 'document.delete("executionRoute")'
expect_failure missing-execution-route

prepare_fixture unsupported-execution-route
mutate_json "$evidence_file" 'document["executionRoute"] = "manual"'
expect_failure unsupported-execution-route

prepare_fixture missing-xcode
mutate_json "$evidence_file" 'document.delete("xcode")'
expect_failure missing-xcode

prepare_fixture mismatched-xcode
mutate_json "$evidence_file" 'document.fetch("xcode")["build"] = "DIFFERENT"'
expect_failure mismatched-xcode

prepare_fixture missing-matrix-digest
mutate_json "$evidence_file" 'document.delete("matrixDigest")'
expect_failure missing-matrix-digest

prepare_fixture changed-matrix
printf '\n' >>"$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json"
expect_failure changed-matrix

prepare_fixture symlink-matrix
mv "$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json" "$fixture_root/.artifacts/batches/evidence-fixture/real-matrix.json"
ln -s real-matrix.json "$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json"
expect_failure symlink-matrix

prepare_fixture escaping-matrix
mutate_json "$evidence_file" 'document["matrixFile"] = ".artifacts/batches/../issues/42/issue-contract.json"'
expect_failure escaping-matrix

prepare_fixture missing-acceptance
mutate_json "$evidence_file" 'document.fetch("acceptanceEvidence").pop'
expect_failure missing-acceptance

prepare_fixture duplicate-acceptance
mutate_json "$evidence_file" 'document.fetch("acceptanceEvidence") << document.fetch("acceptanceEvidence").first'
expect_failure duplicate-acceptance

prepare_fixture extra-acceptance
mutate_json "$evidence_file" 'document.fetch("acceptanceEvidence") << {"id" => "AC-3", "status" => "passed", "evidence" => ["tests:extra"]}'
expect_failure extra-acceptance

prepare_fixture visual-finding
mutate_json "$evidence_file" 'document.fetch("visualEvaluation").fetch("findings") << "layout overlap"'
expect_failure visual-finding

prepare_fixture unknown-key
mutate_json "$evidence_file" 'document["unexpected"] = true'
expect_failure unknown-key

docs_head=""
docs_base=""
while IFS= read -r candidate; do
  candidate_base="$(git rev-parse "$candidate^" 2>/dev/null || true)"
  [[ -n "$candidate_base" ]] || continue
  changed_paths=()
  while IFS= read -r changed_path; do
    [[ -n "$changed_path" ]] && changed_paths+=("$changed_path")
  done < <(git diff --name-only "$candidate_base" "$candidate")
  [[ ${#changed_paths[@]} -gt 0 ]] || continue
  docs_only=1
  for changed_path in "${changed_paths[@]}"; do
    case "$changed_path" in
      *.md) ;;
      *) docs_only=0; break ;;
    esac
  done
  if [[ $docs_only -eq 1 ]]; then
    docs_head="$candidate"
    docs_base="$candidate_base"
    break
  fi
done < <(git rev-list --all)
[[ -n "$docs_head" && -n "$docs_base" ]] || {
  echo "repository has no adjacent documentation-only commits for classification test" >&2
  exit 1
}

make_documentation_only() {
  local selected_base="$1"
  local selected_head="$2"
  BASE="$selected_base" HEAD_SHA_VALUE="$selected_head" mutate_json "$evidence_file" '
    document["status"] = "not-applicable"
    document["changeClassification"] = "documentation-only"
    document["reason"] = "Only documentation and local links changed"
    document["baseSha"] = ENV.fetch("BASE")
    document["headSha"] = ENV.fetch("HEAD_SHA_VALUE")
    document["matrixFile"] = nil
    document["matrixDigest"] = nil
    document["executionRoute"] = "none"
    document["xcode"] = nil
    document["build"] = {"status" => "not-applicable", "scheme" => nil, "warningsAdded" => nil}
    document["tests"] = {"status" => "not-applicable", "passed" => nil, "failed" => nil, "skipped" => nil}
    document["cases"] = []
    document["visualEvaluation"] = {"status" => "not-applicable", "findings" => []}
    document["acceptanceEvidence"] = [
      {"id" => "AC-1", "status" => "passed", "evidence" => ["documents:spec consistency"]},
      {"id" => "AC-2", "status" => "passed", "evidence" => ["links:swift tools/check-markdown-links.swift"]}
    ]
  '
}

prepare_fixture valid-documentation-only passed.json "$docs_head"
make_documentation_only "$docs_base" "$docs_head"
run_validator "$docs_head"

invalid_docs_head="$head_sha"
invalid_docs_base="$base_sha"
prepare_fixture invalid-documentation-only passed.json "$invalid_docs_head"
make_documentation_only "$invalid_docs_base" "$invalid_docs_head"
expect_failure invalid-documentation-only "$invalid_docs_head"

prepare_fixture invalid-document-evidence passed.json "$docs_head"
make_documentation_only "$docs_base" "$docs_head"
mutate_json "$evidence_file" 'document.fetch("acceptanceEvidence").fetch(0)["evidence"] = ["tests:not a document check"]'
expect_failure invalid-document-evidence "$docs_head"

if [[ -e "$poison_log" ]]; then
  echo "validator invoked an Xcode or Simulator command" >&2
  cat "$poison_log" >&2
  exit 1
fi

echo "all iOS evidence validator tests passed"
