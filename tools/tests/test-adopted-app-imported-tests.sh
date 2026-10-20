#!/usr/bin/env bash
set -euo pipefail

# #315: repository tests that the template sync imports into an app must pass on the app's correct
# state. A disposable clone of this template's HEAD is turned into an app that adopted the template:
# its template-only files are gone, it records Config/template-base.json, specs/product.md holds the
# app's own text, and the dedicated Simulators carry the app's display name. The imported credential
# scan and dedicated-Simulator setup tests run inside it, and the template keeps the exact checks.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby python3 shasum

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ios-template-adopted-app-tests.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

fail() { echo "adopted-app imported tests: $*" >&2; exit 1; }

before_head="$(git -C "$repo_root" rev-parse HEAD)"
before_status="$(git -C "$repo_root" status --porcelain)"
before_index="$(git -C "$repo_root" ls-files -s | shasum -a 256)"

app="$work/app"
git clone -q --no-hardlinks "$repo_root" "$app"
git -C "$app" checkout -q --detach "$before_head"

# The derived-app test of the template sync tools and this regression are template-only, like the sync library they load.
removed="$(ruby -r"$app/tools/lib/template-sync.rb" -e '
  root = ARGV.fetch(0)
  ownership = TemplateSync.load_ownership(File.read(File.join(root, TemplateSync::OWNERSHIP_PATH)))
  TemplateSync.tracked_paths(root, "HEAD").each do |path|
    puts path if TemplateSync.classify(ownership, path)&.dig(:category) == "template-only"
  end
' "$app")"
grep -Fxq 'tools/tests/test-template-sync-derived.sh' <<<"$removed" || fail 'test-template-sync-derived.sh is not template-only'
# This regression loads the template-only sync library, so an adopted app must not receive it either.
grep -Fxq 'tools/tests/test-adopted-app-imported-tests.sh' <<<"$removed" || fail 'this regression is not template-only'
grep -Fxq 'tools/tests/fixtures/template-sync/template-sample.sh' <<<"$removed" || fail 'the template-sync fixture is not template-only'

(
  cd "$app"
  while IFS= read -r path; do
    [[ -n "$path" ]] && git rm -q -- "$path"
  done <<<"$removed"
  printf '{\n  "baseCommit": "%s",\n  "method": "adopted",\n  "recordedAt": "2026-10-19T00:00:00Z",\n  "schemaVersion": 1,\n  "templateRepository": "yuto1201/iOS-Template"\n}\n' "$before_head" > Config/template-base.json
  printf '# Sample app product\n\nThe sample app keeps timers on the device. It has no server and no database.\n' > specs/product.md
  ruby -rjson -e '
    path = ARGV.fetch(0)
    value = JSON.parse(File.read(path))
    value.fetch("devices").each { |device| device["name"] = device.fetch("name").sub("iOS-Template ", "Sample ") }
    File.write(path, JSON.pretty_generate(value) + "\n")
  ' Config/dedicated-simulators.json
  grep -Fq '"Sample iPhone 17 Pro"' Config/dedicated-simulators.json || fail 'the sample declaration was not renamed'
  git add -A
  git -c user.name=test -c user.email=test@example.invalid commit -q -m 'Adopt the template as a sample app'
)

run_in_app() { (cd "$app" && bash "tools/tests/$1" >"$work/$1.log" 2>&1); }

run_in_app test-tracked-credential-scan.sh || fail "credential scan failed in the adopted app: $(tail -3 "$work/test-tracked-credential-scan.sh.log")"
run_in_app test-setup-dedicated-simulators.sh || fail "dedicated Simulator setup test failed in the adopted app: $(tail -3 "$work/test-setup-dedicated-simulators.sh.log")"

# #349: the plan leaves out the manifest's template-only entries that an adopted app does not have, and the
# workflow evidence test no longer reads the app-owned App Store/submission/. First, the plan's list of
# template-only entries is exactly what the ownership manifest makes template-only, and the template's own
# manifest is used unchanged.
ruby -rjson -r"$repo_root/tools/lib/template-sync.rb" -I"$repo_root/tools/lib" -rrepository-test-plan -e '
  root = ARGV.fetch(0)
  ownership = TemplateSync.load_ownership(File.read(File.join(root, TemplateSync::OWNERSHIP_PATH)))
  manifest = JSON.parse(File.read(File.join(root, "Config/repository-tests.json")))
  template_only = ->(path) { TemplateSync.classify(ownership, path)&.dig(:category) == "template-only" }
  plan = IOSTemplate::RepositoryTestPlan
  tests = manifest.fetch("tests").map { |entry| entry.fetch("path") }.select(&template_only).sort
  paths = manifest.fetch("domainRules").flat_map { |rule| rule.fetch("paths") }.select(&template_only).uniq.sort
  abort "template-only manifest tests differ from the plan: #{tests}" unless tests == plan::TEMPLATE_ONLY_TESTS.sort
  abort "template-only manifest paths differ from the plan: #{paths}" unless paths == plan::TEMPLATE_ONLY_PATHS.sort
  tracked = IO.popen(["git", "-C", root, "ls-files"], &:read).split("\n")
  same, testless = plan.adopted_manifest(manifest, tracked)
  abort "the template manifest is not used unchanged" unless same == manifest && testless.empty?
' "$repo_root" || fail 'the plan does not track the template-only manifest entries'
(
  cd "$app"
  git rm -q -r -- "App Store/submission"
  printf '\nAdopted app note.\n' >> docs/template-sync.md
  git add -A
  git -c user.name=test -c user.email=test@example.invalid commit -q -m 'An adopted app without submission requirements'
)
plan_in_app() {
  (cd "$app" && ruby -Itools/lib -rjson -rrepository-test-plan -e '
    plan = IOSTemplate::RepositoryTestPlan
    base, head = ARGV
    criteria = [{"id" => "AC-1", "text" => "UI-direction route: not-applicable; Scope: tests; Reason: no UI."},
                {"id" => "AC-2", "text" => "Repository-test scope: targeted; Reason: adopted app fixture."}]
    contract = JSON.generate({"schemaVersion"=>1, "issue"=>42, "repository"=>"example/repo", "goal"=>"Adopted plan",
      "specAnchors"=>["specs/test.md#plan"], "acceptanceCriteria"=>criteria, "dependencies"=>[], "externalOperations"=>[],
      "externalOperationDetailsDigest"=>"sha256:#{"0" * 64}", "fetchedAt"=>"2026-09-13T13:03:38Z",
      "deliveryStage"=>{"name"=>"harden", "timeBudgetMinutes"=>60, "reason"=>"fixture"},
      "deliveryProfile"=>{"name"=>"strict", "reason"=>"fixture"}})
    manifest = JSON.parse(IO.popen(["git", "show", "#{head}:Config/repository-tests.json"], &:read))
    tracked = plan.tracked_paths(".", head)
    adopted, testless = plan.adopted_manifest(manifest, tracked)
    # The manifest check runs first, as in build, so the template check stops on the manifest.
    plan.validate_manifest!(adopted, tracked.grep(plan::TEST_PATH), tracked_paths: tracked, testless_domains: testless)
    _, _, selected = plan.resolve(adopted, "targeted", plan.changed_paths(".", base, head))
    built = plan.build(repo: ".", issue: 42, base_sha: base, head_sha: head, contract_bytes: contract,
      mappings: {"AC-1" => selected, "AC-2" => selected})
    abort "unexpected plan: #{built["testPaths"]}" unless built["testPaths"] == selected && (selected & plan::TEMPLATE_ONLY_TESTS).empty?
    abort "the template-sync domain should be left without tests: #{testless}" unless testless.include?("template-sync")
    puts selected.length
  ' "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)") >"$work/plan-in-app.log" 2>&1
}
plan_in_app || fail "the repository-test plan did not start in the adopted app: $(tail -3 "$work/plan-in-app.log")"
run_in_app test-workflow-evidence-publisher.sh || fail "workflow evidence test failed in the adopted app: $(tail -3 "$work/test-workflow-evidence-publisher.sh.log")"

# An app may not add a new occurrence of the restricted word outside the allowed files.
(
  cd "$app"
  mkdir -p Services
  printf 'const key = "service_role";\n' > Services/leak.ts
  git add -A
  git -c user.name=test -c user.email=test@example.invalid commit -q -m 'Leak the restricted word'
)
if run_in_app test-tracked-credential-scan.sh; then
  fail 'a new service_role occurrence in the adopted app was not reported'
fi
grep -Fq 'service_role policy occurrence set changed' "$work/test-tracked-credential-scan.sh.log" || fail "unexpected credential scan failure: $(tail -3 "$work/test-tracked-credential-scan.sh.log")"

# Without the adoption record the repository is checked as the template, with the exact set.
(
  cd "$app"
  git rm -q -- Services/leak.ts Config/template-base.json
  git -c user.name=test -c user.email=test@example.invalid commit -q -m 'Check as the template'
)
if run_in_app test-tracked-credential-scan.sh; then
  fail 'the template check accepted a missing allowed occurrence'
fi
grep -Fq 'service_role policy occurrence set changed' "$work/test-tracked-credential-scan.sh.log" || fail "unexpected template credential scan failure: $(tail -3 "$work/test-tracked-credential-scan.sh.log")"
# The template check of the manifest stays exact: without the adoption record, missing template-only tests
# stop the plan.
if plan_in_app; then
  fail 'the template manifest check accepted missing template-only tests'
fi
grep -Fq 'repository-test manifest inventory differs from tracked tests' "$work/plan-in-app.log" || fail "unexpected template plan failure: $(tail -3 "$work/plan-in-app.log")"

[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$before_head" ]] || fail 'the running repository HEAD changed'
[[ "$(git -C "$repo_root" status --porcelain)" == "$before_status" ]] || fail 'the running repository working tree changed'
[[ "$(git -C "$repo_root" ls-files -s | shasum -a 256)" == "$before_index" ]] || fail 'the running repository index changed'

echo 'adopted-app imported test regressions passed'
