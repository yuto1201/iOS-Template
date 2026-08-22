#!/usr/bin/env bash
set -euo pipefail

source_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fixtures="$source_repo/tools/tests/fixtures/verify"
scratch="$(mktemp -d -t ios-evidence.XXXXXX)"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT

validator_source="$source_repo/tools/validate-verify-json.swift"
validator="$scratch/validate-verify-json"
swift_bin="$(command -v swift)"
swiftc "$validator_source" -o "$validator"

poison_bin="$scratch/poison-bin"
poison_log="$scratch/poison.log"
mkdir -p "$poison_bin"
for command_name in xcrun xcodebuild simctl; do
  command_path="$poison_bin/$command_name"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$0 $*" >>"$POISON_LOG"' 'exit 97' >"$command_path"
  chmod +x "$command_path"
done

matrix_fixture="$scratch/simulator-matrix.json"
write_matrix() {
  local path="$1"
  ruby -rjson - "$path" <<'RUBY'
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
    ["iphone-en", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro", "en_US", "en", "00000000-0000-0000-0000-000000000001"],
    ["iphone-ja", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro", "ja_JP", "ja", "00000000-0000-0000-0000-000000000002"],
    ["ipad-en", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "en_US", "en", "00000000-0000-0000-0000-000000000003"],
    ["ipad-ja", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "ja_JP", "ja", "00000000-0000-0000-0000-000000000004"]
  ].map do |id, family, identifier, name, locale, language, udid|
    {
      "id" => id,
      "family" => family,
      "deviceType" => {"identifier" => identifier, "name" => name},
      "locale" => locale,
      "language" => language,
      "udid" => udid
    }
  end
}
File.write(path, JSON.pretty_generate(matrix) + "\n")
RUBY
}
write_matrix "$matrix_fixture"

fixture_root=""
evidence_file=""
base_sha=""
head_sha=""
older_base_sha=""
nonancestor_sha=""

prepare_fixture() {
  local label="$1"
  local template="${2:-passed.json}"
  local change_kind="${3:-normal}"
  local change_path="${4:-docs/change.md}"

  fixture_root="$scratch/$label/repository"
  mkdir -p "$fixture_root"
  fixture_root="$(cd "$fixture_root" && pwd -P)"
  git -C "$fixture_root" init -q
  git -C "$fixture_root" config user.name 'Evidence Test'
  git -C "$fixture_root" config user.email 'evidence@example.invalid'

  mkdir -p "$fixture_root/docs"
  printf '%s\n' '# Initial' >"$fixture_root/docs/initial.md"
  git -C "$fixture_root" add -- docs/initial.md
  git -C "$fixture_root" commit -q -m initial
  older_base_sha="$(git -C "$fixture_root" rev-parse HEAD)"

  printf '%s\n' '# Base' >"$fixture_root/docs/base.md"
  case "$change_kind" in
    chmod)
      printf '%s\n' '# Mode' >"$fixture_root/docs/mode.md"
      ;;
    rename)
      printf '%s\n' '# Rename' >"$fixture_root/docs/rename.md"
      ;;
  esac
  git -C "$fixture_root" add -- docs
  git -C "$fixture_root" commit -q -m base
  base_sha="$(git -C "$fixture_root" rev-parse HEAD)"

  case "$change_kind" in
    normal)
      mkdir -p "$fixture_root/$(dirname "$change_path")"
      printf '%s\n' '# Head' >"$fixture_root/$change_path"
      git -C "$fixture_root" add -- "$change_path"
      ;;
    chmod)
      chmod +x "$fixture_root/docs/mode.md"
      git -C "$fixture_root" add -- docs/mode.md
      ;;
    rename)
      mkdir -p "$fixture_root/scripts"
      git -C "$fixture_root" mv docs/rename.md scripts/rename.md
      ;;
    gitlink)
      git -C "$fixture_root" update-index --add --cacheinfo 160000,"$base_sha",docs/submodule.md
      ;;
    *)
      echo "unknown fixture change kind: $change_kind" >&2
      exit 1
      ;;
  esac
  git -C "$fixture_root" commit -q -m head
  head_sha="$(git -C "$fixture_root" rev-parse HEAD)"
  empty_tree="$(printf '' | git -C "$fixture_root" mktree)"
  nonancestor_sha="$(printf '%s\n' unrelated | git -C "$fixture_root" commit-tree "$empty_tree")"

  local issue_dir="$fixture_root/.artifacts/issues/42"
  local evidence_dir="$issue_dir/$head_sha"
  local matrix_dir="$fixture_root/.artifacts/batches/evidence-fixture"
  evidence_file="$evidence_dir/verify.json"
  mkdir -p "$evidence_dir" "$matrix_dir"
  cp "$fixtures/issue-contract.json" "$issue_dir/issue-contract.json"
  cp "$matrix_fixture" "$matrix_dir/simulator-matrix.json"
  cp -R "$fixtures/screenshots/." "$evidence_dir/"

  local contract_digest matrix_digest
  contract_digest="$(shasum -a 256 "$issue_dir/issue-contract.json" | awk '{print $1}')"
  matrix_digest="$(shasum -a 256 "$matrix_dir/simulator-matrix.json" | awk '{print $1}')"
  ruby - "$fixtures/$template" "$evidence_file" \
    "$base_sha" "$head_sha" "$older_base_sha" "$contract_digest" "$matrix_digest" <<'RUBY'
source, destination, base_sha, head_sha, stale_sha, contract_digest, matrix_digest = ARGV
text = File.read(source)
{
  "BASE_SHA" => base_sha,
  "HEAD_SHA" => head_sha,
  "STALE_SHA" => stale_sha,
  "CONTRACT_DIGEST" => contract_digest,
  "MATRIX_DIGEST" => matrix_digest
}.each { |key, value| text = text.gsub(key, value) }
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

refresh_contract_digest() {
  local contract="$fixture_root/.artifacts/issues/42/issue-contract.json"
  local digest
  digest="$(shasum -a 256 "$contract" | awk '{print $1}')"
  DIGEST="$digest" mutate_json "$evidence_file" 'document.fetch("issueContract")["digest"] = "sha256:" + ENV.fetch("DIGEST")'
}

refresh_matrix_digest() {
  local matrix="$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json"
  local digest
  digest="$(shasum -a 256 "$matrix" | awk '{print $1}')"
  DIGEST="$digest" mutate_json "$evidence_file" 'document["matrixDigest"] = "sha256:" + ENV.fetch("DIGEST")'
}

run_validator() {
  local expected_base="${1:-$base_sha}"
  local expected_head="${2:-$head_sha}"
  local selected_file="${3:-$evidence_file}"
  (
    cd "$fixture_root"
    PATH="$poison_bin:$PATH" POISON_LOG="$poison_log" \
      "$validator" --file "$selected_file" --expected-issue 42 \
        --expected-base "$expected_base" --expected-head "$expected_head"
  )
}

expect_failure() {
  local label="$1"
  local diagnostic="$2"
  local expected_base="${3:-$base_sha}"
  local expected_head="${4:-$head_sha}"
  local selected_file="${5:-$evidence_file}"
  local stdout="$scratch/$label.stdout"
  local stderr="$scratch/$label.stderr"
  if run_validator "$expected_base" "$expected_head" "$selected_file" >"$stdout" 2>"$stderr"; then
    echo "validator unexpectedly accepted $label" >&2
    exit 1
  fi
  if ! grep -Fq -- "$diagnostic" "$stderr"; then
    echo "validator rejected $label for the wrong reason" >&2
    echo "expected diagnostic: $diagnostic" >&2
    cat "$stderr" >&2
    exit 1
  fi
}

make_documentation_only() {
  mutate_json "$evidence_file" '
    document["status"] = "not-applicable"
    document["changeClassification"] = "documentation-only"
    document["reason"] = "Only allowlisted Markdown documentation changed"
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

prepare_fixture valid-passed
run_validator
(
  cd "$fixture_root"
  PATH="$poison_bin:$PATH" POISON_LOG="$poison_log" \
    "$swift_bin" "$validator_source" --file "$evidence_file" --expected-issue 42 \
      --expected-base "$base_sha" --expected-head "$head_sha"
)

expect_failure base-equals-head "expected Base and Head must differ" "$head_sha" "$head_sha"
expect_failure expected-base-mismatch "baseSha does not match --expected-base" "$older_base_sha" "$head_sha"
expect_failure nonancestor-base "expected Base is not an ancestor of expected Head" "$nonancestor_sha" "$head_sha"
expect_failure expected-head-not-current "--expected-head must equal current Git HEAD" "$older_base_sha" "$base_sha"

prepare_fixture standalone-candidate
standalone_candidate="$(dirname "$evidence_file")/.verify-candidate-external"
cp "$evidence_file" "$standalone_candidate"
chmod 0400 "$standalone_candidate"
if (
  cd "$fixture_root"
  "$validator" --file "$evidence_file" --candidate-file "$standalone_candidate" \
    --expected-issue 42 --expected-base "$base_sha" --expected-head "$head_sha"
) >"$scratch/standalone-candidate.stdout" 2>"$scratch/standalone-candidate.stderr"; then
  echo "validator accepted a standalone candidate without a retained validated descriptor" >&2
  exit 1
fi
grep -Fq "standalone candidate publication is not supported" "$scratch/standalone-candidate.stderr" || {
  echo "standalone candidate was rejected for the wrong reason" >&2
  cat "$scratch/standalone-candidate.stderr" >&2
  exit 1
}

prepare_fixture stale-sha stale-sha.json
expect_failure stale-sha "headSha does not match --expected-head"

prepare_fixture wrong-json-base
OLDER_BASE="$older_base_sha" mutate_json "$evidence_file" 'document["baseSha"] = ENV.fetch("OLDER_BASE")'
expect_failure wrong-json-base "baseSha does not match --expected-base"

prepare_fixture failed-case failed-case.json
expect_failure failed-case "cases[1].status must be passed"

prepare_fixture missing-screenshot
rm "$fixture_root/.artifacts/issues/42/$head_sha/iphone-ja/settings.png"
expect_failure missing-screenshot "cases[1].screenshot is unavailable"

prepare_fixture symlink-screenshot
rm "$fixture_root/.artifacts/issues/42/$head_sha/iphone-en/settings.png"
ln -s ../iphone-ja/settings.png "$fixture_root/.artifacts/issues/42/$head_sha/iphone-en/settings.png"
expect_failure symlink-screenshot "cases[0].screenshot is unavailable or contains a symbolic link"

prepare_fixture hardlink-screenshot
ln "$fixture_root/.artifacts/issues/42/$head_sha/iphone-en/settings.png" \
  "$fixture_root/.artifacts/issues/42/$head_sha/iphone-en/duplicate.png"
expect_failure hardlink-screenshot "cases[0].screenshot must have exactly one hard link"

prepare_fixture missing-screenshot-digest
mutate_json "$evidence_file" 'document.fetch("cases").fetch(0).delete("screenshotDigest")'
expect_failure missing-screenshot-digest "cases[0]: missing keys screenshotDigest"

prepare_fixture wrong-screenshot-digest
mutate_json "$evidence_file" 'document.fetch("cases").fetch(0)["screenshotDigest"] = "sha256:" + "0" * 64'
expect_failure wrong-screenshot-digest "cases[0].screenshotDigest does not match exact screenshot bytes"

prepare_fixture changed-screenshot-bytes
printf 'changed-after-evidence' >>"$fixture_root/.artifacts/issues/42/$head_sha/iphone-en/settings.png"
expect_failure changed-screenshot-bytes "cases[0].screenshotDigest does not match exact screenshot bytes"

prepare_fixture escaping-screenshot
mutate_json "$evidence_file" 'document.fetch("cases").fetch(0)["screenshot"] = "../../../../outside.png"'
expect_failure escaping-screenshot "cases[0].screenshot must be lexically contained"

prepare_fixture duplicate-screenshot
mutate_json "$evidence_file" 'document.fetch("cases").fetch(1)["screenshot"] = document.fetch("cases").fetch(0).fetch("screenshot")'
expect_failure duplicate-screenshot "case screenshot paths must be unique"

prepare_fixture wrong-case-directory
mkdir -p "$fixture_root/.artifacts/issues/42/$head_sha/wrong"
cp "$fixtures/screenshots/iphone-en/settings.png" "$fixture_root/.artifacts/issues/42/$head_sha/wrong/settings.png"
mutate_json "$evidence_file" 'document.fetch("cases").fetch(0)["screenshot"] = "wrong/settings.png"'
expect_failure wrong-case-directory "cases[0].screenshot must begin with its case ID"

prepare_fixture duplicate-case
mutate_json "$evidence_file" 'document.fetch("cases").fetch(1)["id"] = "iphone-en"'
expect_failure duplicate-case "cases contain duplicate ID iphone-en"

prepare_fixture skipped-test
mutate_json "$evidence_file" 'document.fetch("tests")["skipped"] = 1'
expect_failure skipped-test "tests.skipped must be zero"

prepare_fixture zero-tests
mutate_json "$evidence_file" 'document.fetch("tests")["passed"] = 0'
expect_failure zero-tests "tests.passed must be at least 1"

prepare_fixture added-warning
mutate_json "$evidence_file" 'document.fetch("build")["warningsAdded"] = 1'
expect_failure added-warning "build.warningsAdded must be zero"

prepare_fixture missing-contract
rm "$fixture_root/.artifacts/issues/42/issue-contract.json"
expect_failure missing-contract "issueContract.path is unavailable"

prepare_fixture symlink-contract
mv "$fixture_root/.artifacts/issues/42/issue-contract.json" "$fixture_root/.artifacts/issues/42/real-contract.json"
ln -s real-contract.json "$fixture_root/.artifacts/issues/42/issue-contract.json"
expect_failure symlink-contract "issueContract.path is unavailable or contains a symbolic link"

prepare_fixture changed-contract
printf '\n' >>"$fixture_root/.artifacts/issues/42/issue-contract.json"
expect_failure changed-contract "issueContract.digest does not match exact file bytes"

prepare_fixture missing-contract-digest
mutate_json "$evidence_file" 'document.fetch("issueContract").delete("digest")'
expect_failure missing-contract-digest "issueContract: missing keys digest"

prepare_fixture wrong-contract-issue
mutate_json "$fixture_root/.artifacts/issues/42/issue-contract.json" 'document["issue"] = 43'
refresh_contract_digest
expect_failure wrong-contract-issue "issueContract.issue does not match requested Issue"

prepare_fixture duplicate-contract-ac
mutate_json "$fixture_root/.artifacts/issues/42/issue-contract.json" 'document.fetch("acceptanceCriteria") << document.fetch("acceptanceCriteria").first'
refresh_contract_digest
expect_failure duplicate-contract-ac "acceptance IDs must be stable, ordered, and start at AC-1"

prepare_fixture optional-verification-contract
mutate_json "$fixture_root/.artifacts/issues/42/issue-contract.json" '
  document["verification"] = {
    "bundleIdentifier" => "com.example.TemplateApp",
    "unitTestIdentifier" => "TemplateAppTests/UnitSmokeTests/testUnit",
    "cases" => [
      {"id" => "iphone-en", "testIdentifier" => "TemplateAppUITests/SmokeTests/testLaunch"},
      {"id" => "iphone-ja", "assertion" => {"kind" => "launch-succeeded"}},
      {"id" => "ipad-en", "testIdentifier" => "TemplateAppUITests/SmokeTests/testLaunch"},
      {"id" => "ipad-ja", "assertion" => {"kind" => "launch-succeeded"}}
    ],
    "acceptanceMappings" => [
      {"id" => "AC-1", "checks" => ["stage:build", "stage:unit-tests"]},
      {"id" => "AC-2", "checks" => ["case:iphone-en", "case:iphone-ja", "case:ipad-en", "case:ipad-ja", "visual:iphone-en", "visual:iphone-ja", "visual:ipad-en", "visual:ipad-ja"]}
    ]
  }
'
mutate_json "$evidence_file" '
  document["acceptanceEvidence"] = [
    {"id" => "AC-1", "status" => "passed", "evidence" => ["stage:build", "stage:unit-tests"]},
    {"id" => "AC-2", "status" => "passed", "evidence" => ["case:iphone-en", "case:iphone-ja", "case:ipad-en", "case:ipad-ja", "visual:iphone-en", "visual:iphone-ja", "visual:ipad-en", "visual:ipad-ja"]}
  ]
'
refresh_contract_digest
run_validator
mutate_json "$evidence_file" 'document.fetch("acceptanceEvidence").reverse!'
expect_failure optional-verification-evidence-order "acceptanceEvidence must follow the exact Issue contract AC order"

prepare_fixture incomplete-verification-contract
mutate_json "$fixture_root/.artifacts/issues/42/issue-contract.json" '
  document["verification"] = {
    "bundleIdentifier" => "com.example.TemplateApp",
    "unitTestIdentifier" => "TemplateAppTests/UnitSmokeTests/testUnit",
    "cases" => [{"id" => "iphone-en", "assertion" => {"kind" => "launch-succeeded"}}],
    "acceptanceMappings" => []
  }
'
refresh_contract_digest
expect_failure incomplete-verification-contract "verification.cases must contain the exact four ordered case IDs"

prepare_fixture ambiguous-verification-action
mutate_json "$fixture_root/.artifacts/issues/42/issue-contract.json" '
  document["verification"] = {
    "bundleIdentifier" => "com.example.TemplateApp",
    "unitTestIdentifier" => "TemplateAppTests/UnitSmokeTests/testUnit",
    "cases" => [
      {"id" => "iphone-en", "testIdentifier" => "TemplateAppUITests/SmokeTests/testLaunch", "assertion" => {"kind" => "launch-succeeded"}},
      {"id" => "iphone-ja", "assertion" => {"kind" => "launch-succeeded"}},
      {"id" => "ipad-en", "testIdentifier" => "TemplateAppUITests/SmokeTests/testLaunch"},
      {"id" => "ipad-ja", "assertion" => {"kind" => "launch-succeeded"}}
    ],
    "acceptanceMappings" => [
      {"id" => "AC-1", "checks" => ["stage:build"]},
      {"id" => "AC-2", "checks" => ["case:iphone-en"]}
    ]
  }
'
refresh_contract_digest
expect_failure ambiguous-verification-action "must contain exactly one of testIdentifier or assertion"

prepare_fixture missing-execution-route
mutate_json "$evidence_file" 'document.delete("executionRoute")'
expect_failure missing-execution-route "missing keys executionRoute"

prepare_fixture unsupported-execution-route
mutate_json "$evidence_file" 'document["executionRoute"] = "manual"'
expect_failure unsupported-execution-route "executionRoute is not supported"

prepare_fixture missing-xcode
mutate_json "$evidence_file" 'document.delete("xcode")'
expect_failure missing-xcode "missing keys xcode"

prepare_fixture mismatched-xcode
mutate_json "$evidence_file" 'document.fetch("xcode")["build"] = "DIFFERENT"'
expect_failure mismatched-xcode "xcode identity must exactly match matrixFile.xcode"

prepare_fixture missing-matrix-digest
mutate_json "$evidence_file" 'document.delete("matrixDigest")'
expect_failure missing-matrix-digest "missing keys matrixDigest"

prepare_fixture changed-matrix
printf '\n' >>"$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json"
expect_failure changed-matrix "matrixDigest does not match exact file bytes"

prepare_fixture malformed-redigested-matrix
mutate_json "$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json" 'document.fetch("cases").fetch(0).delete("udid")'
refresh_matrix_digest
expect_failure malformed-redigested-matrix "matrixFile.cases[0]: missing keys udid"

prepare_fixture mismatched-matrix-row
mutate_json "$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json" 'document.fetch("cases").fetch(0)["id"] = "other"'
refresh_matrix_digest
expect_failure mismatched-matrix-row "matrixFile.cases must use the exact standard order and locale rows"

prepare_fixture unknown-matrix-key
mutate_json "$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json" 'document["unexpected"] = true'
refresh_matrix_digest
expect_failure unknown-matrix-key "matrixFile: unknown keys unexpected"

prepare_fixture duplicate-matrix-udid
mutate_json "$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json" 'document.fetch("cases").fetch(1)["udid"] = document.fetch("cases").fetch(0).fetch("udid")'
refresh_matrix_digest
expect_failure duplicate-matrix-udid "matrixFile Simulator UDIDs must be unique"

prepare_fixture split-family-matrix
mutate_json "$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json" 'document.fetch("cases").fetch(1).fetch("deviceType")["name"] = "Other Pro"'
refresh_matrix_digest
expect_failure split-family-matrix "matrixFile must use one Device Type per family"

prepare_fixture symlink-matrix
mv "$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json" "$fixture_root/.artifacts/batches/evidence-fixture/real-matrix.json"
ln -s real-matrix.json "$fixture_root/.artifacts/batches/evidence-fixture/simulator-matrix.json"
expect_failure symlink-matrix "matrixFile is unavailable or contains a symbolic link"

prepare_fixture invalid-batch-path
mutate_json "$evidence_file" 'document["matrixFile"] = ".artifacts/batches/unsafe.id/simulator-matrix.json"'
expect_failure invalid-batch-path "matrixFile must use the canonical safe batch path"

prepare_fixture missing-acceptance
mutate_json "$evidence_file" 'document.fetch("acceptanceEvidence").pop'
expect_failure missing-acceptance "must contain every Issue contract AC exactly once"

prepare_fixture duplicate-acceptance
mutate_json "$evidence_file" 'document.fetch("acceptanceEvidence") << document.fetch("acceptanceEvidence").first'
expect_failure duplicate-acceptance "acceptanceEvidence contains duplicate ID AC-1"

prepare_fixture extra-acceptance
mutate_json "$evidence_file" 'document.fetch("acceptanceEvidence") << {"id" => "AC-3", "status" => "passed", "evidence" => ["tests:extra"]}'
expect_failure extra-acceptance "must contain every Issue contract AC exactly once"

prepare_fixture visual-finding
mutate_json "$evidence_file" 'document.fetch("visualEvaluation").fetch("findings") << "layout overlap"'
expect_failure visual-finding "visualEvaluation.findings must be empty"

prepare_fixture unknown-key
mutate_json "$evidence_file" 'document["unexpected"] = true'
expect_failure unknown-key "verify.json: unknown keys unexpected"

prepare_fixture malformed-completed-at
mutate_json "$evidence_file" 'document["completedAt"] = "not-a-date"'
expect_failure malformed-completed-at "completedAt must be a complete ISO 8601 timestamp"

prepare_fixture invalid-calendar-timestamp
mutate_json "$evidence_file" 'document["completedAt"] = "2026-02-30T12:00:00Z"'
expect_failure invalid-calendar-timestamp "completedAt must be a valid ISO 8601 timestamp"

prepare_fixture timestamp-order
mutate_json "$evidence_file" 'document["completedAt"] = "2026-08-21T11:59:59+09:00"'
expect_failure timestamp-order "completedAt must not precede issueContract.fetchedAt"

prepare_fixture future-timestamp
future_timestamp="$(ruby -rtime -e 'puts (Time.now + 3600).iso8601')"
FUTURE="$future_timestamp" mutate_json "$evidence_file" 'document["completedAt"] = ENV.fetch("FUTURE")'
expect_failure future-timestamp "completedAt is implausibly in the future"

prepare_fixture future-fetched-at
future_timestamp="$(ruby -rtime -e 'puts (Time.now + 3600).iso8601')"
FUTURE="$future_timestamp" mutate_json "$fixture_root/.artifacts/issues/42/issue-contract.json" 'document["fetchedAt"] = ENV.fetch("FUTURE")'
refresh_contract_digest
expect_failure future-fetched-at "issueContract.fetchedAt is implausibly in the future"

prepare_fixture arbitrary-verify-root
cp "$evidence_file" "$fixture_root/verify.json"
expect_failure arbitrary-verify-root "--file must be the canonical evidence path" "$base_sha" "$head_sha" "$fixture_root/verify.json"

prepare_fixture hardlink-verify-file
ln "$evidence_file" "$fixture_root/verify-hardlink.json"
expect_failure hardlink-verify-file "verify.json must have exactly one hard link"

prepare_fixture symlink-verify-root
mv "$fixture_root/.artifacts" "$fixture_root/real-artifacts"
ln -s real-artifacts "$fixture_root/.artifacts"
expect_failure symlink-verify-root "verify.json is unavailable or contains a symbolic link"

for allowed_path in README.md AGENTS.md docs/allowed.md specs/allowed.md; do
  label="allowed-$(printf '%s' "$allowed_path" | tr '/.' '--')"
  prepare_fixture "$label" passed.json normal "$allowed_path"
  make_documentation_only
  run_validator
done

prepare_fixture disallowed-root-markdown passed.json normal OTHER.md
make_documentation_only
expect_failure disallowed-root-markdown "documentation-only path is not allowlisted: OTHER.md"

prepare_fixture disallowed-script passed.json normal scripts/check.sh
make_documentation_only
expect_failure disallowed-script "documentation-only path is not allowlisted: scripts/check.sh"

prepare_fixture disallowed-json passed.json normal docs/metadata.json
make_documentation_only
expect_failure disallowed-json "documentation-only path is not allowlisted: docs/metadata.json"

prepare_fixture executable-mode passed.json chmod
make_documentation_only
expect_failure executable-mode "documentation-only diff contains a type or mode change"

prepare_fixture gitlink-change passed.json gitlink
make_documentation_only
expect_failure gitlink-change "documentation-only diff contains a gitlink or unsupported file type"

prepare_fixture renamed-outside-allowlist passed.json rename
make_documentation_only
expect_failure renamed-outside-allowlist "documentation-only path is not allowlisted: scripts/rename.md"

prepare_fixture invalid-document-evidence
make_documentation_only
mutate_json "$evidence_file" 'document.fetch("acceptanceEvidence").fetch(0)["evidence"] = ["tests:not a document check"]'
expect_failure invalid-document-evidence "documentation-only acceptance evidence must cite document or link checks"

if [[ -e "$poison_log" ]]; then
  echo "validator invoked an Xcode or Simulator command" >&2
  cat "$poison_log" >&2
  exit 1
fi

echo "all iOS evidence validator tests passed"
