#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby swift swiftc

source_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
publisher="$source_repo/tools/publish-workflow-verify.sh"
validator="$source_repo/tools/validate-verify-json.swift"
scratch="$(mktemp -d -t ios-workflow-evidence.XXXXXX)"
trap '/bin/rm -rf "$scratch"' EXIT
# Compile the same production validator once for the full rejection matrix.
# Keep a real shell-entrypoint check below; repeated interpretation exceeded
# the 300-second targeted-test budget without adding different coverage.
compiled_validator="$scratch/validate-verify-json"
/usr/bin/swiftc "$validator" -o "$compiled_validator"

phase_record='Config/releases/anygps-mvp/phase-records/0001-phase-1.json'

# prepare_fixture LABEL [recorded]: "recorded" puts a template base record and a phase record in the base.
prepare_fixture() {
  local label="$1"
  repo="$scratch/$label/repository"
  /bin/mkdir -p "$repo/Config" "$repo/tools/lib"
  /usr/bin/git -C "$repo" init -q
  /usr/bin/git -C "$repo" config user.name 'Workflow Publisher Test'
  /usr/bin/git -C "$repo" config user.email 'workflow-publisher@example.invalid'
  printf '%s\n' '.artifacts/' >"$repo/.gitignore"
  printf '%s\n' '# base' >"$repo/README.md"
  /usr/bin/git -C "$repo" add -- .gitignore README.md
  if [[ "${2:-}" == recorded ]]; then
    /bin/mkdir -p "$repo/Config/releases/anygps-mvp/phase-records"
    printf '%s\n' '{"recordId":"0001-phase-1"}' >"$repo/$phase_record"
    printf '%s\n' '{"baseCommit":"0000000000000000000000000000000000000001"}' >"$repo/Config/template-base.json"
    /usr/bin/git -C "$repo" add -- "$phase_record" Config/template-base.json
  fi
  /usr/bin/git -C "$repo" commit -q -m base
  base_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
  printf '%s\n' '{}' >"$repo/Config/repository-tests.json"
  printf '%s\n' '# workflow helper' >"$repo/tools/lib/example.rb"
  /usr/bin/git -C "$repo" add -- Config/repository-tests.json tools/lib/example.rb
  /usr/bin/git -C "$repo" commit -q -m head
  head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
  issue_root="$repo/.artifacts/issues/42"
  /bin/mkdir -p "$issue_root/$head_sha"
  ISSUE_ROOT="$issue_root" BASE="$base_sha" HEAD="$head_sha" /usr/bin/ruby --disable-gems -rjson -rdigest -rtime <<'RUBY'
# encoding: UTF-8
root = ENV.fetch("ISSUE_ROOT")
contract = {
  "schemaVersion"=>1, "issue"=>42, "repository"=>"yuto1201/iOS-Template",
  "goal"=>"Verify workflow changes without Xcode",
  "specAnchors"=>["specs/acceptance.md#33-workflow-only検証"],
  "acceptanceCriteria"=>[
    {"id"=>"AC-1","text"=>"UI-direction route: not-applicable; Scope: workflow tools; Reason: no application UI changes."},
    {"id"=>"AC-2","text"=>"Application paths are rejected."}
  ],
  "dependencies"=>[], "externalOperations"=>[],
  "externalOperationDetailsDigest"=>"sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945",
  "fetchedAt"=>Time.now.utc.iso8601,
  "deliveryStage"=>{"name"=>"harden","timeBudgetMinutes"=>60,"reason"=>"Bounded workflow change."},
  "deliveryProfile"=>{"name"=>"strict","reason"=>"Verification gate change."}
}
contract_path = File.join(root, "issue-contract.json")
File.write(contract_path, JSON.pretty_generate(contract) + "\n")
digest = "sha256:#{Digest::SHA256.file(contract_path).hexdigest}"
record = {
  "schemaVersion"=>1,"status"=>"passed","issue"=>42,"baseSha"=>ENV.fetch("BASE"),"headSha"=>ENV.fetch("HEAD"),
  "issueContract"=>{"path"=>".artifacts/issues/42/issue-contract.json","digest"=>digest},
  "runnerFiles"=>[],"suite"=>{"path"=>"tools/tests","pattern"=>"test-*.sh","total"=>1,"passed"=>1,"failed"=>0},
  "tests"=>[{"path"=>"tools/tests/test-workflow.sh","arguments"=>[],"status"=>"passed","exitStatus"=>0,"outputDigest"=>"sha256:#{"0"*64}","startedAt"=>Time.now.utc.iso8601,"completedAt"=>Time.now.utc.iso8601}],
  "acceptanceEvidence"=>[
    {"id"=>"AC-1","status"=>"passed","tests"=>["tools/tests/test-workflow.sh"]},
    {"id"=>"AC-2","status"=>"passed","tests"=>["tools/tests/test-workflow.sh"]}
  ],"startedAt"=>Time.now.utc.iso8601,"completedAt"=>Time.now.utc.iso8601
}
File.write(File.join(root, ENV.fetch("HEAD"), "repository-tests.json"), JSON.generate(record))
File.write(File.join(root, "workflow-evidence-input.json"), JSON.generate({"schemaVersion"=>1,"reason"=>"Workflow harden passed; not release-ready."}))
RUBY
}

run_publisher() {
  (cd "$repo" && "$compiled_validator" --publish-workflow --issue 42 --expected-base "$base_sha" --expected-head "$head_sha" --input .artifacts/issues/42/workflow-evidence-input.json)
}

refresh_record_contract_digest() {
  CONTRACT="$issue_root/issue-contract.json" RECORD="$issue_root/$head_sha/repository-tests.json" /usr/bin/ruby --disable-gems -rjson -rdigest <<'RUBY'
contract = ENV.fetch("CONTRACT")
record_path = ENV.fetch("RECORD")
record = JSON.parse(File.binread(record_path))
record.fetch("issueContract")["digest"] = "sha256:#{Digest::SHA256.file(contract).hexdigest}"
File.binwrite(record_path, JSON.generate(record))
RUBY
}

rebind_head_artifacts() {
  local previous_head="$1"
  /bin/mv "$issue_root/$previous_head" "$issue_root/$head_sha"
  RECORD="$issue_root/$head_sha/repository-tests.json" HEAD="$head_sha" /usr/bin/ruby --disable-gems -rjson <<'RUBY'
path = ENV.fetch("RECORD")
value = JSON.parse(File.binread(path))
value["headSha"] = ENV.fetch("HEAD")
File.binwrite(path, JSON.generate(value))
RUBY
}

expect_rejection() {
  local label="$1" message="$2"
  if run_publisher >"$scratch/$label.stdout" 2>"$scratch/$label.stderr"; then
    echo "workflow publisher accepted $label" >&2
    exit 1
  fi
  /usr/bin/grep -Fq "$message" "$scratch/$label.stderr" || {
    echo "workflow rejection differed for $label" >&2
    /bin/cat "$scratch/$label.stderr" >&2
    exit 1
  }
  [[ ! -e "$issue_root/$head_sha/verify.json" ]] || { echo "workflow rejection published verify.json: $label" >&2; exit 1; }
}

prepare_fixture shell-entrypoint
published="$(cd "$repo" && "$publisher" --issue 42 --expected-base "$base_sha" --expected-head "$head_sha" --input .artifacts/issues/42/workflow-evidence-input.json)"
[[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]]
(cd "$repo" && "$compiled_validator" --file "$published" --expected-issue 42 --expected-base "$base_sha" --expected-head "$head_sha") >/dev/null

prepare_fixture valid
published="$(run_publisher)"
[[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]]
(cd "$repo" && /usr/bin/swift "$validator" --file "$published" --expected-issue 42 --expected-base "$base_sha" --expected-head "$head_sha") >/dev/null
/usr/bin/ruby --disable-gems -rjson - "$repo/.artifacts/issues/42/$head_sha/verify.json" <<'RUBY'
value = JSON.parse(File.read(ARGV.fetch(0)))
abort unless value.values_at("status", "changeClassification", "executionRoute") == ["passed", "workflow-only", "repository-tests"]
abort unless value["xcode"].nil? && value["cases"] == [] && value.dig("build", "status") == "not-applicable"
abort unless value.fetch("acceptanceEvidence").map { |item| item.fetch("evidence") } == [
  ["repository-tests.json#acceptanceEvidence/0"], ["repository-tests.json#acceptanceEvidence/1"]
]
RUBY

prepare_fixture shared-skill-link
/bin/mkdir -p "$repo/.agents/skills/example" "$repo/.claude/skills"
printf '%s\n' '---' 'name: example' 'description: Use when testing a shared skill.' '---' >"$repo/.agents/skills/example/SKILL.md"
/bin/ln -s ../../.agents/skills/example "$repo/.claude/skills/example"
previous_head="$head_sha"
/usr/bin/git -C "$repo" add -- .agents/skills/example/SKILL.md .claude/skills/example
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
rebind_head_artifacts "$previous_head"
published="$(run_publisher)"
[[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]]

prepare_fixture appstore-delivery-tools
/bin/mkdir -p "$repo/.agents/skills/prepare-appstore-assets/templates" "$repo/.agents/skills/submit-appstore-release" \
  "$repo/App Store/legal" "$repo/App Store/screenshots" "$repo/docs/agent-contracts" "$repo/tools/lib" "$repo/tools/tests"
printf '%s\n' '# local preparation guidance' >"$repo/.agents/skills/prepare-appstore-assets/SKILL.md"
printf '%s\n' '# legal handoff guidance' >"$repo/.agents/skills/prepare-appstore-assets/templates/legal-page-handoff.md"
printf '%s\n' '# local submission guidance' >"$repo/.agents/skills/submit-appstore-release/SKILL.md"
printf '%s\n' '# legal handoff readme' >"$repo/App Store/legal/README.md"
printf '%s\n' '# screenshot workflow guidance' >"$repo/App Store/screenshots/README.md"
printf '%s\n' '# app store submission contract' >"$repo/docs/agent-contracts/appstore-submission.md"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$repo/tools/capture-appstore-screenshots.sh"
printf '%s\n' '# local legal handoff library' >"$repo/tools/lib/appstore-legal-handoff.rb"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$repo/tools/prepare-appstore-legal-handoff.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$repo/tools/tests/test-appstore-legal-handoff.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$repo/tools/tests/test-appstore-screenshots.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$repo/tools/tests/test-appstore-skills.sh"
/bin/chmod +x "$repo/tools/capture-appstore-screenshots.sh" "$repo/tools/prepare-appstore-legal-handoff.sh" \
  "$repo/tools/tests/test-appstore-legal-handoff.sh" \
  "$repo/tools/tests/test-appstore-screenshots.sh" "$repo/tools/tests/test-appstore-skills.sh"
previous_head="$head_sha"
/usr/bin/git -C "$repo" add -- .agents/skills/prepare-appstore-assets/SKILL.md \
  .agents/skills/prepare-appstore-assets/templates/legal-page-handoff.md \
  .agents/skills/submit-appstore-release/SKILL.md 'App Store/screenshots/README.md' \
  'App Store/legal/README.md' docs/agent-contracts/appstore-submission.md \
  tools/capture-appstore-screenshots.sh \
  tools/lib/appstore-legal-handoff.rb tools/prepare-appstore-legal-handoff.sh \
  tools/tests/test-appstore-legal-handoff.sh tools/tests/test-appstore-screenshots.sh \
  tools/tests/test-appstore-skills.sh
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
rebind_head_artifacts "$previous_head"
published="$(run_publisher)"
[[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]]

# Only the enumerated asc adapter files qualify for fake-only workflow evidence.
prepare_fixture asc-adapter-exact-paths
for asc_path in Config/asc-cli.json tools/asc-run.sh tools/install-asc-cli.sh tools/lib/asc-cli.rb tools/tests/fixtures/asc/checksums.txt tools/tests/fixtures/asc/fake-asc tools/tests/fixtures/asc/fake-security tools/tests/fixtures/asc/pin.json tools/tests/test-asc-cli.sh; do
  /bin/mkdir -p "$(/usr/bin/dirname "$repo/$asc_path")"
  /bin/cp "$source_repo/$asc_path" "$repo/$asc_path"
done
previous_head="$head_sha"
/usr/bin/git -C "$repo" add -- Config/asc-cli.json tools
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
rebind_head_artifacts "$previous_head"
published="$(run_publisher)"
[[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]]

prepare_fixture appstore-readonly-preparation
/bin/mkdir -p "$repo/App Store/metadata" "$repo/tools/lib" "$repo/tools/tests"
printf '%s\n' '# source preparation guidance' >"$repo/App Store/README.md"
printf '%s\n' '# versioned source preparation format' >"$repo/App Store/metadata/preparation-format.md"
for helper in \
  account-evidence asset-evidence code-inventory confirmation preparation public-evidence \
  readback-evidence registration-preparation source-schema xcode-facts; do
  printf '%s\n' '# local read-only preparation helper' >"$repo/tools/lib/appstore-$helper.rb"
done
printf '%s\n' '#!/bin/bash' 'exit 0' >"$repo/tools/prepare-appstore-sources.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$repo/tools/tests/test-appstore-preparation-migration.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$repo/tools/tests/test-appstore-preparation.sh"
/bin/chmod +x "$repo/tools/prepare-appstore-sources.sh" \
  "$repo/tools/tests/test-appstore-preparation-migration.sh" \
  "$repo/tools/tests/test-appstore-preparation.sh"
previous_head="$head_sha"
/usr/bin/git -C "$repo" add -- 'App Store/README.md' 'App Store/metadata/preparation-format.md' \
  tools/lib/appstore-account-evidence.rb tools/lib/appstore-asset-evidence.rb \
  tools/lib/appstore-code-inventory.rb tools/lib/appstore-confirmation.rb \
  tools/lib/appstore-preparation.rb tools/lib/appstore-public-evidence.rb \
  tools/lib/appstore-readback-evidence.rb tools/lib/appstore-registration-preparation.rb \
  tools/lib/appstore-source-schema.rb tools/lib/appstore-xcode-facts.rb \
  tools/prepare-appstore-sources.sh tools/tests/test-appstore-preparation-migration.sh \
  tools/tests/test-appstore-preparation.sh
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
rebind_head_artifacts "$previous_head"
published="$(run_publisher)"
[[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]]

prepare_fixture escaping-skill-link
/bin/mkdir -p "$repo/.claude/skills"
/bin/ln -s ../../../outside "$repo/.claude/skills/example"
previous_head="$head_sha"
/usr/bin/git -C "$repo" add -- .claude/skills/example
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
rebind_head_artifacts "$previous_head"
expect_rejection escaping-skill-link 'workflow-only shared skill symlink is invalid'

prepare_fixture application-path
/bin/mkdir -p "$repo/TemplateApp"
printf '%s\n' 'import SwiftUI' >"$repo/TemplateApp/Changed.swift"
/usr/bin/git -C "$repo" add -- TemplateApp/Changed.swift
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
if run_publisher >"$scratch/application.stdout" 2>"$scratch/application.stderr"; then
  echo 'workflow publisher accepted an application path' >&2
  exit 1
fi
/usr/bin/grep -Fq 'workflow-only path is not allowlisted: TemplateApp/Changed.swift' "$scratch/application.stderr"

prepare_fixture appstore-operation
CONTRACT="$issue_root/issue-contract.json" /usr/bin/ruby --disable-gems -rjson <<'RUBY'
path = ENV.fetch("CONTRACT")
value = JSON.parse(File.binread(path))
value["externalOperations"] = ["appstore.upload"]
File.binwrite(path, JSON.generate(value))
RUBY
refresh_record_contract_digest
expect_rejection appstore-operation 'App Store operations require release Delivery stage'

prepare_fixture asc-inspect-operation
CONTRACT="$issue_root/issue-contract.json" /usr/bin/ruby --disable-gems -rjson <<'RUBY'
path = ENV.fetch("CONTRACT")
value = JSON.parse(File.binread(path))
value["externalOperations"] = ["appstore.inspect_app"]
File.binwrite(path, JSON.generate(value))
RUBY
refresh_record_contract_digest
expect_rejection asc-inspect-operation 'App Store operations require release Delivery stage'

prepare_fixture application-verification
CONTRACT="$issue_root/issue-contract.json" /usr/bin/ruby --disable-gems -rjson <<'RUBY'
path = ENV.fetch("CONTRACT")
value = JSON.parse(File.binread(path))
value["verificationScope"] = {"name"=>"targeted", "reason"=>"Invalid application scope."}
value["verification"] = {
  "bundleIdentifier"=>"com.example.TemplateApp", "unitTestIdentifier"=>"TemplateAppTests/UnitSmokeTests/testUnit",
  "cases"=>[{"id"=>"iphone-ja", "assertion"=>{"kind"=>"launch-succeeded"}}],
  "acceptanceMappings"=>[
    {"id"=>"AC-1", "checks"=>["stage:build"]},
    {"id"=>"AC-2", "checks"=>["case:iphone-ja"]}
  ]
}
File.binwrite(path, JSON.generate(value))
RUBY
refresh_record_contract_digest
expect_rejection application-verification 'workflow-only evidence requires harden + strict without application Verification'

prepare_fixture foreign-evidence
RECORD="$issue_root/$head_sha/repository-tests.json" /usr/bin/ruby --disable-gems -rjson <<'RUBY'
path = ENV.fetch("RECORD")
value = JSON.parse(File.binread(path))
value["issue"] = 99
File.binwrite(path, JSON.generate(value))
RUBY
expect_rejection foreign-evidence 'workflow-only repository-test evidence identity differs'

prepare_fixture failed-evidence
RECORD="$issue_root/$head_sha/repository-tests.json" /usr/bin/ruby --disable-gems -rjson <<'RUBY'
path = ENV.fetch("RECORD")
value = JSON.parse(File.binread(path))
value.fetch("suite")["failed"] = 1
value.fetch("tests").first["status"] = "failed"
value.fetch("tests").first["exitStatus"] = 1
File.binwrite(path, JSON.generate(value))
RUBY
expect_rejection failed-evidence 'workflow-only repository-test evidence contains a failed or empty suite'

prepare_fixture appstore-path
/bin/mkdir -p "$repo/App Store"
printf '%s\n' 'metadata' >"$repo/App Store/Metadata.md"
/usr/bin/git -C "$repo" add -- 'App Store/Metadata.md'
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
expect_rejection appstore-path 'workflow-only diff contains a release or App Store path: App Store/Metadata.md'

prepare_fixture legal-source-path
/bin/mkdir -p "$repo/App Store/legal"
printf '%s\n' '# Privacy Policy' 'Status: Confirmed' >"$repo/App Store/legal/privacy-policy.md"
/usr/bin/git -C "$repo" add -- 'App Store/legal/privacy-policy.md'
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
expect_rejection legal-source-path 'workflow-only diff contains a release or App Store path: App Store/legal/privacy-policy.md'

prepare_fixture adopted-appstore-asset
/bin/mkdir -p "$repo/App Store/screenshots"
printf '%s\n' 'adopted image bytes' >"$repo/App Store/screenshots/iphone-ja.png"
/usr/bin/git -C "$repo" add -- 'App Store/screenshots/iphone-ja.png'
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
expect_rejection adopted-appstore-asset 'workflow-only diff contains a release or App Store path: App Store/screenshots/iphone-ja.png'

prepare_fixture dedicated-simulator-declaration
/bin/mkdir -p "$repo/Config"
printf '%s\n' '{"schemaVersion":1,"devices":[]}' >"$repo/Config/dedicated-simulators.json"
previous_head="$head_sha"
/usr/bin/git -C "$repo" add -- Config/dedicated-simulators.json
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
rebind_head_artifacts "$previous_head"
published="$(run_publisher)"
[[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]] || { echo 'workflow publisher rejected the dedicated Simulator declaration' >&2; exit 1; }

prepare_fixture template-identity-manifest
/bin/mkdir -p "$repo/Config"
printf '%s\n' '{"schemaVersion":1,"liveContentPaths":["Config/dedicated-simulators.json"]}' >"$repo/Config/template-identity.json"
previous_head="$head_sha"
/usr/bin/git -C "$repo" add -- Config/template-identity.json
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
rebind_head_artifacts "$previous_head"
published="$(run_publisher)"
[[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]] || { echo 'workflow publisher rejected the template identity manifest' >&2; exit 1; }

prepare_fixture account-ownership
/bin/mkdir -p "$repo/Config"
printf '%s\n' 'appStore:' '  teamId: ABCDE12345' >"$repo/Config/ownership.yml"
previous_head="$head_sha"
/usr/bin/git -C "$repo" add -- Config/ownership.yml
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
rebind_head_artifacts "$previous_head"
published="$(run_publisher)"
[[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]] || { echo 'workflow publisher rejected the account ownership binding' >&2; exit 1; }

# The staged Config changes become the Head, and the evidence follows it.
commit_config_change() {
  local previous_head="$head_sha"
  /usr/bin/git -C "$repo" add -A -- Config
  /usr/bin/git -C "$repo" commit -q --amend --no-edit
  head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
  rebind_head_artifacts "$previous_head"
}

expect_published() {
  published="$(run_publisher)"
  [[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]] || { echo "workflow publisher rejected $1" >&2; exit 1; }
}

# D-073, D-074: the template base record may be added or changed.
prepare_fixture template-base-record-add
printf '%s\n' '{"baseCommit":"0000000000000000000000000000000000000002"}' >"$repo/Config/template-base.json"
commit_config_change
expect_published 'adding the template base record'

prepare_fixture template-base-record-change recorded
printf '%s\n' '{"baseCommit":"0000000000000000000000000000000000000003"}' >"$repo/Config/template-base.json"
commit_config_change
expect_published 'changing the template base record'

# D-038: phase records are append-only, so only a new regular record file is accepted.
prepare_fixture phase-record-add recorded
printf '%s\n' '{"recordId":"0002-phase-2"}' >"$repo/Config/releases/anygps-mvp/phase-records/0002-phase-2.json"
commit_config_change
expect_published 'adding a new phase record'

prepare_fixture phase-record-change recorded
printf '%s\n' '{"recordId":"0001-phase-1","changed":true}' >"$repo/$phase_record"
commit_config_change
expect_rejection phase-record-change "workflow-only diff may only add a new phase record: $phase_record"

prepare_fixture phase-record-delete recorded
/usr/bin/git -C "$repo" rm -q -- "$phase_record"
commit_config_change
expect_rejection phase-record-delete "workflow-only diff may only add a new phase record: $phase_record"

prepare_fixture phase-record-rename recorded
/usr/bin/git -C "$repo" mv "$phase_record" Config/releases/anygps-mvp/phase-records/0003-phase-1.json
commit_config_change
expect_rejection phase-record-rename "workflow-only diff may only add a new phase record: $phase_record"

prepare_fixture phase-record-executable recorded
printf '%s\n' '{"recordId":"0002-phase-2"}' >"$repo/Config/releases/anygps-mvp/phase-records/0002-phase-2.json"
/bin/chmod +x "$repo/Config/releases/anygps-mvp/phase-records/0002-phase-2.json"
commit_config_change
expect_rejection phase-record-executable 'workflow-only diff may only add a new phase record: Config/releases/anygps-mvp/phase-records/0002-phase-2.json'

prepare_fixture phase-record-symlink recorded
/bin/ln -s 0001-phase-1.json "$repo/Config/releases/anygps-mvp/phase-records/0002-phase-2.json"
commit_config_change
expect_rejection phase-record-symlink 'workflow-only diff may only add a new phase record: Config/releases/anygps-mvp/phase-records/0002-phase-2.json'

prepare_fixture release-other-path recorded
printf '%s\n' '{"scope":"other"}' >"$repo/Config/releases/anygps-mvp/plan.json"
commit_config_change
expect_rejection release-other-path 'workflow-only path is not allowlisted: Config/releases/anygps-mvp/plan.json'

prepare_fixture phase-record-invalid-id recorded
/bin/mkdir -p "$repo/Config/releases/AnyGPS/phase-records"
printf '%s\n' '{"recordId":"0001"}' >"$repo/Config/releases/AnyGPS/phase-records/0001.json"
commit_config_change
expect_rejection phase-record-invalid-id 'workflow-only path is not allowlisted: Config/releases/AnyGPS/phase-records/0001.json'

# D-075: a workflow-only change may move the legacy root README.md into docs/, but never edit a root README.md.
prepare_fixture legacy-root-readme-move
/bin/mkdir -p "$repo/docs"
/usr/bin/git -C "$repo" mv README.md docs/README.md
previous_head="$head_sha"
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
rebind_head_artifacts "$previous_head"
published="$(run_publisher)"
[[ "$published" == ".artifacts/issues/42/$head_sha/verify.json" ]] || { echo 'workflow publisher rejected moving the legacy root README.md' >&2; exit 1; }

prepare_fixture root-readme-edit
printf '%s\n' '# edited' >>"$repo/README.md"
previous_head="$head_sha"
/usr/bin/git -C "$repo" add -- README.md
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
rebind_head_artifacts "$previous_head"
expect_rejection root-readme-edit 'workflow-only diff may only delete the legacy root README.md'

prepare_fixture signing-configuration
/bin/mkdir -p "$repo/Config"
printf '%s\n' 'DEVELOPMENT_TEAM = EXAMPLE' >"$repo/Config/Signing.xcconfig"
/usr/bin/git -C "$repo" add -- Config/Signing.xcconfig
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
expect_rejection signing-configuration 'workflow-only path is not allowlisted: Config/Signing.xcconfig'

prepare_fixture provider-implementation
/bin/mkdir -p "$repo/tools/lib"
printf '%s\n' '# remote provider mutation' >"$repo/tools/lib/appstore-provider.rb"
/usr/bin/git -C "$repo" add -- tools/lib/appstore-provider.rb
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
expect_rejection provider-implementation 'workflow-only diff contains a release or App Store path: tools/lib/appstore-provider.rb'

prepare_fixture separated-provider-implementation
/bin/mkdir -p "$repo/tools/lib"
printf '%s\n' '# remote provider mutation with alternate service spelling' >"$repo/tools/lib/app-store-provider.rb"
/usr/bin/git -C "$repo" add -- tools/lib/app-store-provider.rb
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
expect_rejection separated-provider-implementation 'workflow-only diff contains a release or App Store path: tools/lib/app-store-provider.rb'

prepare_fixture dotted-provider-implementation
/bin/mkdir -p "$repo/tools/lib"
printf '%s\n' '# remote provider mutation with dotted service spelling' >"$repo/tools/lib/app.store-provider.rb"
/usr/bin/git -C "$repo" add -- tools/lib/app.store-provider.rb
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
expect_rejection dotted-provider-implementation 'workflow-only diff contains a release or App Store path: tools/lib/app.store-provider.rb'

prepare_fixture testflight-helper
/bin/mkdir -p "$repo/tools"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$repo/tools/testflight-upload.sh"
/bin/chmod +x "$repo/tools/testflight-upload.sh"
/usr/bin/git -C "$repo" add -- tools/testflight-upload.sh
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
expect_rejection testflight-helper 'workflow-only diff contains a release or App Store path: tools/testflight-upload.sh'

semantic_index=0
for semantic_path in Config/asc.json tools/tests/fixtures/asc/unlisted tools/lib/asc.rb tools/asc-provider.rb tools/connect-upload.sh tools/sign-release.sh tools/tf-client.sh tools/ascProvider.rb tools/iTunesConnectClient.rb tools/tfUpload.sh tools/ascprovider.rb tools/itunesconnectclient.rb tools/tfupload.sh tools/itunesconnect/client.rb tools/appleconnect/provider.rb tools/asc-save.rb tools/itunesconnectupdate.rb tools/tf-distribute.sh tools/asc.rb tools/itunes.rb tools/itunesconnect.rb tools/apple-connect.rb tools/asc-put.rb tools/asc-post.rb; do
  semantic_index=$((semantic_index + 1))
  fixture_name="semantic-$semantic_index-$(printf '%s' "$semantic_path" | /usr/bin/sed 's#[/.]#-#g')"
  prepare_fixture "$fixture_name"
  /bin/mkdir -p "$(/usr/bin/dirname "$repo/$semantic_path")"
  printf '%s\n' '# semantic remote release implementation alias' >"$repo/$semantic_path"
  /usr/bin/git -C "$repo" add -- "$semantic_path"
  /usr/bin/git -C "$repo" commit -q --amend --no-edit
  head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
  expect_rejection "$fixture_name" "workflow-only diff contains a release or App Store path: $semantic_path"
done

prepare_fixture unknown-appstore-helper
/bin/mkdir -p "$repo/tools/lib"
printf '%s\n' '# unknown local helper' >"$repo/tools/lib/appstore-unknown.rb"
/usr/bin/git -C "$repo" add -- tools/lib/appstore-unknown.rb
/usr/bin/git -C "$repo" commit -q --amend --no-edit
head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
expect_rejection unknown-appstore-helper 'workflow-only diff contains a release or App Store path: tools/lib/appstore-unknown.rb'

prepare_fixture missing-repository-evidence
/usr/bin/ruby -e 'File.unlink(ARGV.fetch(0))' "$repo/.artifacts/issues/42/$head_sha/repository-tests.json"
if run_publisher >"$scratch/missing.stdout" 2>"$scratch/missing.stderr"; then
  echo 'workflow publisher accepted missing repository evidence' >&2
  exit 1
fi
/usr/bin/grep -Fq 'workflow-only repository-test evidence is unavailable' "$scratch/missing.stderr"

echo 'workflow evidence publisher tests passed'
