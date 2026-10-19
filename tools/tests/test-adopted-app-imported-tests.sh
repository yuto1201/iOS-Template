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

[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$before_head" ]] || fail 'the running repository HEAD changed'
[[ "$(git -C "$repo_root" status --porcelain)" == "$before_status" ]] || fail 'the running repository working tree changed'
[[ "$(git -C "$repo_root" ls-files -s | shasum -a 256)" == "$before_index" ]] || fail 'the running repository index changed'

echo 'adopted-app imported test regressions passed'
