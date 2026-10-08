#!/bin/bash
set -euo pipefail

# D-074 template sync regressions in a derived app (#259). A disposable copy of the template records
# its template base (D-073, before Identity bootstrap), then runs Identity bootstrap; in both states the
# report and apply regressions must pass, without changing the repository that runs this test.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby swiftc tar shasum cc python3

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
source "$repo_root/tools/tests/fixtures/template-sync/template-sample.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-template-sync-derived.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name='Template Sync Test' -c user.email=template-sync@example.invalid -c commit.gpgsign=false \
    -c gc.auto=0 -c maintenance.auto=false commit -q -m "$2"
}

# The running repository's Head, index, working-tree status and base record.
repository_state() {
  git -C "$repo_root" rev-parse HEAD
  git -C "$repo_root" ls-files -s -z | shasum -a 256
  git -C "$repo_root" status --porcelain=v1 --untracked-files=all | shasum -a 256
  if [[ -e "$repo_root/Config/template-base.json" ]]; then shasum -a 256 <"$repo_root/Config/template-base.json"; else echo 'no base record'; fi
}
before=$(repository_state)

run_sync_regressions() {
  local state=$1 test
  for test in test-template-sync test-template-sync-apply; do
    if ! bash "$app/tools/tests/$test.sh" >"$work/$state-$test.log" 2>&1; then
      echo "$test failed in a derived app $state" >&2
      tail -n 20 "$work/$state-$test.log" >&2
      exit 1
    fi
  done
}

# A derived app as D-073 creates it: the template's files with its template base recorded.
app="$work/app"
build_template_sample "$repo_root" "$app"
git -C "$app" init -q -b main
commit_all "$app" template
(cd "$app" && BASE=$(git rev-parse HEAD) ruby -rjson -e '
  File.write("Config/template-base.json", JSON.pretty_generate({
    "baseCommit" => ENV.fetch("BASE"), "method" => "created", "recordedAt" => "2026-10-08T00:00:00Z",
    "schemaVersion" => 1, "templateRepository" => "yuto1201/iOS-Template"
  }) + "\n")
')
commit_all "$app" base-record
run_sync_regressions 'before Identity bootstrap'

# Identity bootstrap runs on a working branch, away from the recorded default branch.
git -C "$app" update-ref refs/remotes/origin/main "$(git -C "$app" rev-parse HEAD)"
git -C "$app" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$app" switch -q -c identity-bootstrap
(cd "$app" && tools/bootstrap-app.sh --display-name 'Garden Notes' --module-name GardenNotes \
  --app-slug garden-notes --bundle-id com.yuto.GardenNotes >"$work/bootstrap.log" 2>&1) ||
  { echo 'Identity bootstrap of the derived copy failed' >&2; tail -n 20 "$work/bootstrap.log" >&2; exit 1; }
commit_all "$app" identity
[[ -d "$app/GardenNotes" && ! -e "$app/TemplateApp" && -f "$app/Config/app-identity.json" ]] ||
  { echo 'the derived copy was not converted to its Identity' >&2; exit 1; }
run_sync_regressions 'after Identity bootstrap'

[[ "$(repository_state)" == "$before" ]] || { echo 'the derived-app regression changed the running repository' >&2; exit 1; }
echo "template sync derived-app tests passed"
