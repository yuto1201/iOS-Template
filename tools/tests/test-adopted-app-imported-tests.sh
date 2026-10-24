#!/usr/bin/env bash
set -euo pipefail

# #315: repository tests that the template sync imports into an app must pass on the app's correct
# state. A disposable clone of this template's HEAD is turned into an app that adopted the template:
# its template-only files are gone, it records Config/template-base.json, specs/product.md holds the
# app's own text, and the dedicated Simulators carry the app's display name. The imported credential
# scan and dedicated-Simulator setup tests run inside it, and the template keeps the exact checks.

# #356: the same kind of app, Identity-bootstrapped with another module name and without the app's App Store
# files, also runs the imported foundation, App Store, 3D asset and app-bootstrap tests. The two bootstrap groups
# take longer, so each runs on its own through tools/tests/test-adopted-app-bootstrap-*.sh and stays well inside
# the targeted per-test limit; with no argument this test runs the `imported` group.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby python3 shasum swift

group="${1:-imported}"
case "$group" in
  imported|bootstrap-transform|bootstrap-fixture) ;;
  *)
    echo "usage: $0 [imported|bootstrap-transform|bootstrap-fixture]" >&2
    exit 64
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ios-template-adopted-app-tests.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

fail() { echo "adopted-app imported tests: $*" >&2; exit 1; }

before_head="$(git -C "$repo_root" rev-parse HEAD)"
before_status="$(git -C "$repo_root" status --porcelain)"
before_index="$(git -C "$repo_root" ls-files -s | shasum -a 256)"

check_running_repository() {
  [[ "$(git -C "$repo_root" rev-parse HEAD)" == "$before_head" ]] || fail 'the running repository HEAD changed'
  [[ "$(git -C "$repo_root" status --porcelain)" == "$before_status" ]] || fail 'the running repository working tree changed'
  [[ "$(git -C "$repo_root" ls-files -s | shasum -a 256)" == "$before_index" ]] || fail 'the running repository index changed'
}
commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    -c gc.auto=0 -c maintenance.auto=false commit -q -m "$2"
}

# #356: a disposable clone of this HEAD becomes an app that adopted the template after its Identity bootstrap.
# Its project is SampleNotes.xcodeproj, the template-only files (docs/superpowers/ among them) and the app's
# own App Store files are gone, it records Config/template-base.json, and specs/product.md holds the app's text.
make_bootstrapped_adopted_app() {
  local dest="$1" path
  git clone -q --no-hardlinks "$repo_root" "$dest"
  git -C "$dest" checkout -q --detach "$before_head"
  swift "$dest/tools/bootstrap-app.swift" apply --root "$dest" --manifest "$dest/Config/template-identity.json" \
    --display-name 'Sample Notes' --module-name SampleNotes --app-slug sample-notes --bundle-id com.example.SampleNotes \
    >"$work/bootstrap-$group.log" 2>&1 || fail "Identity bootstrap of the adopted app failed: $(tail -3 "$work/bootstrap-$group.log")"
  [[ -f "$dest/SampleNotes.xcodeproj/project.pbxproj" && -f "$dest/Config/app-identity.json" && ! -e "$dest/TemplateApp.xcodeproj" ]] ||
    fail 'the adopted app was not renamed to SampleNotes'
  commit_all "$dest" 'Bootstrap Sample Notes'
  ruby -r"$dest/tools/lib/template-sync.rb" -e '
    root = ARGV.fetch(0)
    ownership = TemplateSync.load_ownership(File.read(File.join(root, TemplateSync::OWNERSHIP_PATH)))
    TemplateSync.tracked_paths(root, "HEAD").each do |path|
      category = TemplateSync.classify(ownership, path)&.dig(:category)
      puts path if category == "template-only" || (category == "app" && path.start_with?("App Store/"))
    end
  ' "$dest" >"$work/adopted-removed.txt"
  for path in 'App Store/screenshots/states.json' 'App Store/metadata/app.yml' 'App Store/submission/requirements.json' \
    docs/superpowers/plans/2026-08-22-app-bootstrap.md; do
    grep -Fxq -- "$path" "$work/adopted-removed.txt" || fail "the adopted app would keep $path"
  done
  while IFS= read -r path; do
    [[ -n "$path" ]] && git -C "$dest" rm -q -- "$path"
  done <"$work/adopted-removed.txt"
  printf '{\n  "baseCommit": "%s",\n  "method": "adopted",\n  "recordedAt": "2026-10-19T00:00:00Z",\n  "schemaVersion": 1,\n  "templateRepository": "yuto1201/iOS-Template"\n}\n' "$before_head" >"$dest/Config/template-base.json"
  printf '# Sample Notes product\n\nSample Notes keeps notes on the device. It has no server and no database.\n' >"$dest/specs/product.md"
  commit_all "$dest" 'Adopt the template as Sample Notes'
  [[ -z "$(git -C "$dest" ls-files -- 'App Store/metadata/app.yml' 'App Store/screenshots/states.json' 'App Store/submission' docs/superpowers)" ]] ||
    fail 'the adopted app still tracks app-owned App Store files or template-only documents'
}
run_in() { (cd "$1" && bash "tools/tests/$2" "${@:3}" >"$work/$2${3:+-$3}.log" 2>&1); }

if [[ "$group" != imported ]]; then
  adopted="$work/adopted-app"
  make_bootstrapped_adopted_app "$adopted"
  if [[ "$group" == bootstrap-transform ]]; then
    run_in "$adopted" test-app-bootstrap.sh transform ||
      fail "test-app-bootstrap.sh transform failed in the adopted app: $(tail -3 "$work/test-app-bootstrap.sh-transform.log")"
  else
    run_in "$adopted" test-bootstrap-fixture.sh ||
      fail "test-bootstrap-fixture.sh failed in the adopted app: $(tail -3 "$work/test-bootstrap-fixture.sh.log")"
  fi
  check_running_repository
  echo "adopted-app imported $group test regressions passed"
  exit 0
fi

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
for entrypoint in tools/tests/test-adopted-app-bootstrap-fixture.sh tools/tests/test-adopted-app-bootstrap-transform.sh; do
  grep -Fxq "$entrypoint" <<<"$removed" || fail "$entrypoint is not template-only"
done
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

# #366: the canonical runner itself starts the formal repository tests in the adopted app. A change to the
# imported authority document selects the imported provider-ownership test and the always-selected credential
# scan, which both finish in a few seconds. The Issue number is used only inside the disposable clone, and
# the runner's artifacts, detached worktree, and any kept failure output stay outside the running repository.
(
  cd "$app"
  printf '\nAdopted app note.\n' >> docs/AUTHORITY.md
  git add -A
  git -c user.name=test -c user.email=test@example.invalid commit -q -m 'Change an imported document'
)
runner_base="$(git -C "$app" rev-parse HEAD~1)"
runner_head="$(git -C "$app" rev-parse HEAD)"
runner_contract="$app/.artifacts/issues/42/issue-contract.json"
mkdir -p "$app/.artifacts/issues/42/$runner_head"
ruby -I"$app/tools/lib" -rjson -rissue-contract -e '
  criteria = [{"id" => "AC-1", "text" => "UI-direction route: not-applicable; Scope: tests; Reason: no UI."},
              {"id" => "AC-2", "text" => "Repository-test scope: targeted; Reason: adopted app fixture."}]
  contract = {"schemaVersion"=>1, "issue"=>42, "repository"=>"example/repo", "goal"=>"Adopted runner",
    "specAnchors"=>["specs/test.md#runner"], "acceptanceCriteria"=>criteria, "dependencies"=>[], "externalOperations"=>[],
    "externalOperationDetailsDigest"=>"sha256:#{"0" * 64}", "fetchedAt"=>"2026-10-21T00:00:00Z",
    "deliveryStage"=>{"name"=>"harden", "timeBudgetMinutes"=>60, "reason"=>"fixture"},
    "deliveryProfile"=>{"name"=>"strict", "reason"=>"fixture"}}
  File.binwrite(ARGV.fetch(0), IOSTemplate::IssueContract.canonical_json(contract))
' "$runner_contract"
run_runner_in_app() {
  (cd "$app" && IOS_TEMPLATE_REPOSITORY_TEST_OUTPUT_ROOT="$(cd "$work" && pwd -P)/kept-output" \
    tools/run-repository-tests.sh --issue 42 --expected-base "$runner_base" "$@") >"$work/runner.out" 2>"$work/runner.err"
}
run_runner_in_app \
  --map AC-1=tools/tests/test-provider-ownership.sh \
  --map AC-2=tools/tests/test-provider-ownership.sh,tools/tests/test-tracked-credential-scan.sh ||
  fail "the canonical repository-test runner failed in the adopted app: $(tail -3 "$work/runner.err")"
EVIDENCE="$app/.artifacts/issues/42/$runner_head/repository-tests.json" BASE="$runner_base" HEAD_SHA="$runner_head" \
  ruby -rjson -I"$repo_root/tools/lib" -rrepository-test-plan -e '
  value = JSON.parse(File.binread(ENV.fetch("EVIDENCE")))
  expected = %w[tools/tests/test-provider-ownership.sh tools/tests/test-tracked-credential-scan.sh]
  abort "wrong evidence identity" unless value.values_at("status", "issue", "baseSha", "headSha") == ["passed", 42, ENV.fetch("BASE"), ENV.fetch("HEAD_SHA")]
  abort "the evidence scope is not targeted: #{value["scope"]}" unless value["scope"] == "targeted"
  executed = value.fetch("tests").map { |entry| entry.fetch("path") }
  abort "unexpected executed tests: #{executed}" unless executed == expected
  abort "a template-only test ran: #{executed}" unless (executed & IOSTemplate::RepositoryTestPlan::TEMPLATE_ONLY_TESTS).empty?
  abort "an executed test did not pass" unless value.fetch("tests").all? { |entry| entry.fetch("status") == "passed" && entry.fetch("exitStatus") == 0 }
  abort "wrong suite totals" unless value.fetch("suite").values_at("total", "passed", "failed") == [2, 2, 0]
' || fail 'the adopted app repository-test evidence differs'

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

# #356: in the bootstrapped adopted app, the imported foundation, App Store and 3D asset tests pass. The app has
# no App Store/screenshots/states.json, App Store/metadata/app.yml or App Store/submission/requirements.json, no
# TemplateApp.xcodeproj, no docs/superpowers/, and its own specs/product.md.
adopted="$work/adopted-app"
make_bootstrapped_adopted_app "$adopted"
for test_name in test-foundation.sh test-appstore-screenshots.sh test-appstore-preparation-migration.sh \
  test-appstore-build.sh test-ios-design-3d-asset-skill.sh; do
  run_in "$adopted" "$test_name" || fail "$test_name failed in the adopted app: $(tail -3 "$work/$test_name.log")"
done
# Without the adoption record the same repository is checked as the template, which needs the template's files.
git -C "$adopted" rm -q -- Config/template-base.json
commit_all "$adopted" 'Check the adopted app as the template'
expect_template_failure() {
  if run_in "$adopted" "$1"; then
    fail "$1 accepted a repository without the template's files and without the adoption record"
  fi
  grep -Fq -- "$2" "$work/$1.log" || fail "unexpected template failure of $1: $(tail -3 "$work/$1.log")"
}
expect_template_failure test-foundation.sh 'missing required foundation file: App Store/submission/requirements.json'
expect_template_failure test-appstore-preparation-migration.sh 'App Store/metadata/app.yml'
expect_template_failure test-ios-design-3d-asset-skill.sh "specs/product.md lacks '### 5.1 3Dモデル制作方針'"

check_running_repository

echo 'adopted-app imported test regressions passed'
