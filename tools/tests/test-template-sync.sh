#!/bin/bash
set -euo pipefail

# D-074 template sync, report half: ownership classification and the read-only diff report/plan.
# A synthetic template repository holds this template's tracked files (in a derived app, the same
# files rebuilt from the frozen template Identity) as its base commit, then an intermediate commit
# and a commit with template-side changes; synthetic target repositories cover a recorded base,
# an unknown base judged by each file's provenance (D-078), a non-template repository, app-side
# changes, Identity transform, and a decision-number collision. The preflight (D-078) runs on a
# synthetic target with a fake gh that answers only read-only list queries.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby swiftc tar shasum

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
source "$repo_root/tools/tests/fixtures/template-sync/template-sample.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-template-sync.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

commit_all() {
  git -C "$1" add -A
  # No automatic gc or maintenance, so no background process changes .git during the snapshot.
  git -C "$1" -c user.name='Template Sync Test' -c user.email=template-sync@example.invalid -c commit.gpgsign=false \
    -c gc.auto=0 -c maintenance.auto=false commit -q -m "$2"
}

# Every entry (directories and symlinks included) plus every file's bytes.
snapshot() {
  (cd "$1" && { find . -print | LC_ALL=C sort; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256; }) |
    shasum -a 256 | awk '{print $1}'
}

expect_failure() {
  local label=$1 message=$2
  shift 2
  if "$@" >"$work/$label.out" 2>&1; then
    echo "template sync accepted $label" >&2
    exit 1
  fi
  grep -Fq -- "$message" "$work/$label.out" || { echo "unexpected failure for $label" >&2; cat "$work/$label.out" >&2; exit 1; }
}

template="$work/template"
build_template_sample "$repo_root" "$template"
git -C "$template" init -q
commit_all "$template" base
base=$(git -C "$template" rev-parse HEAD)

# --- ownership classification (AC-3) ----------------------------------------------------------
# The template is checked as it is. A derived app's own paths are not the template's files, so there
# the rebuilt sample is checked instead.
check_root=$repo_root
template_sample_derived "$repo_root" && check_root=$template
check_output=$("$check_root/tools/template-sync.sh" check)
CHECK="$check_output" ruby -rjson -e '
  value = JSON.parse(ENV.fetch("CHECK"))
  abort "check did not classify the template" unless value["status"] == "classified"
  counts = value.fetch("categories")
  abort "a category is empty: #{counts}" unless counts.keys.sort == %w[app identity mixed template template-only] && counts.values.all?(&:positive?)
  abort "category counts do not cover every file" unless counts.values.sum == value["files"]
'


printf '%s\n' 'unclassified' >"$template/UNCLASSIFIED.txt"
commit_all "$template" unclassified
expect_failure unclassified-file 'unclassified template files: UNCLASSIFIED.txt' "$template/tools/template-sync.sh" check
git -C "$template" reset -q --hard "$base"

# Bootstrap rewrites docs/README.md, so ownership must keep transforming it.
ruby -rjson -e '
  path = ARGV.fetch(0)
  manifest = JSON.parse(File.read(path))
  manifest["rules"].each { |rule| rule["paths"].delete("docs/README.md") if rule["category"] == "identity" }
  manifest["rules"].find { |rule| rule["category"] == "template" }["paths"] << "docs/README.md"
  File.write(path, JSON.pretty_generate(manifest) + "\n")
' "$template/tools/template-sync/ownership.json"
commit_all "$template" untransformed-readme
expect_failure untransformed-identity 'bootstrap rewrites docs/README.md' "$template/tools/template-sync.sh" check
git -C "$template" reset -q --hard "$base"

# A base recorded before the ownership manifest existed: deleted files must not be deleted blindly.
git -C "$template" checkout -q -b legacy-base
git -C "$template" rm -q tools/template-sync/ownership.json
commit_all "$template" legacy-base
legacy=$(git -C "$template" rev-parse HEAD)
git -C "$template" checkout -q -

# --- an intermediate version (D-078) ---------------------------------------------------------
# With the next commit, docs/workflow.md and the Identity-transformed docs/verification.md have three
# versions; docs/agent-contracts/ios-reviewer.md has two, the newest being this one.
printf '%s\n' '中間の版で追記した手順。' >>"$template/docs/workflow.md"
printf '%s\n' '中間の版で追記した検証。' >>"$template/docs/verification.md"
printf '%s\n' '中間の版で追記した確認。' >>"$template/docs/agent-contracts/ios-reviewer.md"
commit_all "$template" middle
middle=$(git -C "$template" rev-parse HEAD)

# --- template-side changes since the base ----------------------------------------------------
printf '%s\n' 'テンプレートの手順を追記した。' >>"$template/docs/workflow.md"          # safe update
printf '%s\n' 'テンプレートの検証を追記した。' >>"$template/docs/verification.md"      # transformed, third version
printf '%s\n' 'テンプレート側の追記。' >>"$template/docs/AUTHORITY.md"                # conflict
printf '%s\n' '# New guide' '' 'テンプレートが追加した文書。' >"$template/docs/new-guide.md" # missing
git -C "$template" rm -q docs/appstore-creative.md                                              # deleted in template
printf '%s\n' '同期testの追記。' >>"$template/docs/README.md"                        # transformed safe update
printf '%s\n' '旧名TemplateAppを含む追記。' >>"$template/docs/security.md"           # identity regression
# The next free decision number, so the case keeps working as the template appends real decisions.
next_decision=$(ruby -e 'ids = File.read(ARGV[0]).scan(/^## D-(\d{3,}):/).flatten.map(&:to_i); printf("D-%03d", ids.max + 1)' "$template/specs/decisions.md")
printf '%s\n' '' "## $next_decision: テンプレートの新しい決定" '' '- Status: 確定' >>"$template/specs/decisions.md"
printf '%s\n' 'テンプレートのproduct変更。' >>"$template/specs/product.md"          # app-owned
printf '%s\n' 'テンプレートの計画変更。' >>"$template/docs/superpowers/plans/README.md" # template-only
printf '%s\n' 'テンプレート側の追記。' >>"$template/docs/agent-contracts/appstore-submission.md" # app deleted it: conflict
# Deletions whose manifest entries go away too: an exact-only file, the last files under a prefix,
# and an app-owned override that would otherwise fall back to a template prefix.
git -C "$template" rm -q .gitignore specs/acceptance.md
# Executable-mode changes count as changes.
chmod +x "$template/tools/lib/bounded-command.rb"                                    # template-only mode change
printf '%s\n' '# template change' >>"$template/tools/lib/delivery-profile.rb"        # app changes its mode: conflict
git -C "$template" rm -q tools/lib/release-verification.rb                          # app changes its mode: review
# New template files that the app's tree cannot take: a same-named folder, a parent file, a submodule.
mkdir -p "$template/docs/blocked"
printf '%s\n' 'new' >"$template/docs/folder-in-app.md"
printf '%s\n' 'new' >"$template/docs/blocked/guide.md"
printf '%s\n' 'new' >"$template/docs/submodule-in-app.md"
git -C "$template" rm -q -r .codex
ruby -rjson -e '
  path = ARGV.fetch(0)
  manifest = JSON.parse(File.read(path))
  manifest["rules"].each do |rule|
    rule["paths"] -= [".gitignore", "specs/acceptance.md"]
    rule["prefixes"] -= [".codex/"]
  end
  File.write(path, JSON.pretty_generate(manifest) + "\n")
' "$template/tools/template-sync/ownership.json"
commit_all "$template" new

# --- target repositories ---------------------------------------------------------------------
bootstrap_binary="$work/bootstrap-app"
swiftc -o "$bootstrap_binary" "$repo_root/tools/bootstrap-app.swift"

make_app() {
  local app=$1 commit=${2:-$base}
  mkdir -p "$app"
  # macOS tar stops at the end-of-archive marker without reading the padding after it, so a pipe from
  # git archive can die of SIGPIPE under pipefail depending on the archive bytes; extract from a file.
  git -C "$template" archive -o "$work/make-app.tar" "$commit"
  tar -xf "$work/make-app.tar" -C "$app"
  rm -f "$work/make-app.tar"
  "$bootstrap_binary" apply --root "$app" --manifest "$app/Config/template-identity.json" \
    --display-name 'Garden Notes' --module-name GardenNotes --app-slug garden-notes --bundle-id com.yuto.GardenNotes >/dev/null
  git -C "$app" init -q
}
# make_app never pipes git archive into tar (see the comment in make_app).
! declare -f make_app | grep -Eq 'archive[^|]*\|[[:space:]]*tar' || { echo 'make_app pipes git archive into tar' >&2; exit 1; }

# App 1: created from the base with a recorded base commit, then app-side changes.
app1="$work/app1"
make_app "$app1"
(cd "$app1" && BASE="$base" ruby -rjson -e '
  File.write("Config/template-base.json", JSON.pretty_generate({
    "schemaVersion" => 1, "templateRepository" => "yuto1201/iOS-Template", "baseCommit" => ENV.fetch("BASE"),
    "recordedAt" => "2026-10-05T00:00:00Z", "method" => "created"
  }) + "\n")
')
commit_all "$app1" created
printf '%s\n' 'アプリ側の追記。' >>"$app1/docs/AUTHORITY.md"
printf '%s\n' 'アプリ側だけの追記。' >>"$app1/docs/references.md"
printf '%s\n' '' "## $next_decision: アプリ固有の決定" '' '- Status: 確定' >>"$app1/specs/decisions.md"
git -C "$app1" rm -q docs/asc-derived-app-adoption.md docs/agent-contracts/appstore-submission.md
chmod -x "$app1/tools/lib/workflow-json.rb"
mkdir -p "$app1/docs/folder-in-app.md"
printf '%s\n' 'app' >"$app1/docs/folder-in-app.md/note.md"
printf '%s\n' 'app' >"$app1/docs/blocked"
chmod +x "$app1/tools/lib/delivery-profile.rb" "$app1/tools/lib/release-verification.rb"
commit_all "$app1" app-changes
# A submodule entry is committed directly; `git add -A` would drop it without a checkout.
git -C "$app1" update-index --add --cacheinfo "160000,$base,docs/submodule-in-app.md"
git -C "$app1" -c user.name='Template Sync Test' -c user.email=template-sync@example.invalid -c commit.gpgsign=false \
  -c gc.auto=0 -c maintenance.auto=false commit -q -m submodule
before=$(snapshot "$app1")

expect_failure output-inside-app 'must not be inside the app repository' \
  "$template/tools/template-sync.sh" report --app-root "$app1" --output-dir "$app1/sync-report"
expect_failure work-dir-inside-app '--work-dir must not be inside the app repository' \
  "$template/tools/template-sync.sh" report --app-root "$app1" --output-dir "$work/rejected-report" --work-dir "$app1/sync-cache/nested"
ln -s "$app1/docs" "$work/app-docs-link"
expect_failure work-dir-through-symlink '--work-dir must not be inside the app repository' \
  "$template/tools/template-sync.sh" report --app-root "$app1" --output-dir "$work/rejected-report" --work-dir "$work/app-docs-link/cache"
[[ ! -e "$app1/sync-cache" && ! -e "$app1/docs/cache" && ! -e "$work/rejected-report" ]] || { echo 'a rejected report created a directory' >&2; exit 1; }
report1=$("$template/tools/template-sync.sh" report --app-root "$app1" --output-dir "$work/report1" \
  --work-dir "$work/cache" --now 2026-10-05T01:00:00Z)
[[ "$(snapshot "$app1")" == "$before" ]] || { echo 'the report wrote to the target repository' >&2; exit 1; }

expected_readme_digest="sha256:$( { cat "$app1/docs/README.md"; printf '%s\n' '同期testの追記。'; } | shasum -a 256 | awk '{print $1}')"
PLAN="$work/report1/plan.json" BASE="$base" NEXT_DECISION="$next_decision" README_DIGEST="$expected_readme_digest" REPORT="$report1" ruby -rjson -rdigest -e '
  plan = JSON.parse(File.read(ENV.fetch("PLAN")))
  abort "report digest differs" unless JSON.parse(ENV.fetch("REPORT"))["planDigest"] == "sha256:#{Digest::SHA256.file(ENV.fetch("PLAN")).hexdigest}"
  abort "base not recorded: #{plan["base"]}" unless plan["base"] == {"status" => "known", "commit" => ENV.fetch("BASE"), "method" => "created", "recordedAt" => "2026-10-05T00:00:00Z"}
  abort "transform not applied" unless plan.dig("app", "transform") == "applied" && plan.dig("app", "identityFormatIssues") == []
  files = plan.fetch("files").to_h { |file| [file["path"], file] }
  expect = {
    "docs/workflow.md" => %w[safe-update update], "docs/AUTHORITY.md" => %w[conflict manual],
    "docs/references.md" => %w[app-only-change keep], "docs/new-guide.md" => %w[missing add],
    "docs/appstore-creative.md" => %w[deleted-in-template delete], "docs/README.md" => %w[safe-update update],
    "docs/security.md" => %w[safe-update manual], "specs/decisions.md" => %w[conflict manual],
    "specs/product.md" => %w[app-owned skip], "TemplateApp/ContentView.swift" => %w[app-owned skip],
    "docs/superpowers/plans/README.md" => %w[template-only skip], "tools/template-sync.sh" => %w[template-only skip],
    "AGENTS.md" => %w[up-to-date none], "Config/dedicated-simulators.json" => %w[up-to-date none],
    "tools/bootstrap-app.swift" => %w[up-to-date none],
    "docs/asc-derived-app-adoption.md" => %w[app-only-change keep],
    "docs/agent-contracts/appstore-submission.md" => %w[conflict manual],
    ".gitignore" => %w[deleted-in-template delete], "specs/acceptance.md" => %w[app-owned skip],
    "tools/lib/bounded-command.rb" => %w[safe-update update], "tools/lib/workflow-json.rb" => %w[app-only-change keep],
    "tools/lib/delivery-profile.rb" => %w[conflict manual], "tools/lib/release-verification.rb" => %w[deleted-in-template manual],
    "docs/folder-in-app.md" => %w[conflict manual], "docs/blocked/guide.md" => %w[conflict manual],
    "docs/submodule-in-app.md" => %w[conflict manual]
  }
  expect.each do |path, (status, action)|
    actual = files.fetch(path) { abort "missing #{path}" }.values_at("status", "action")
    abort "#{path}: expected #{status}/#{action}, got #{actual.join("/")}" unless actual == [status, action]
  end
  codex = files.select { |path, _| path.start_with?(".codex/") }
  abort "removed prefix members: #{codex.values.map { |f| f.values_at("path", "status", "action") }}" unless !codex.empty? && codex.values.all? { |file| file.values_at("category", "status", "action") == %w[template deleted-in-template delete] }
  mode = files["tools/lib/bounded-command.rb"]
  abort "mode-only change: #{mode}" unless mode.values_at("newMode", "baseMode", "appMode") == %w[100755 100644 100644] && mode["newDigest"] == mode["appDigest"]
  abort "app mode not recorded" unless files["tools/lib/workflow-json.rb"].values_at("appMode", "baseMode") == %w[100644 100755]
  abort "transformed README digest differs" unless files["docs/README.md"]["newDigest"] == ENV.fetch("README_DIGEST")
  abort "identity regression not flagged" unless files["docs/security.md"]["identityRegression"] == true
  abort "decision collision not reported" unless plan["decisions"] == {
    "templateNew" => [ENV.fetch("NEXT_DECISION")], "appendable" => false, "append" => [],
    "collisions" => [{"id" => ENV.fetch("NEXT_DECISION"), "template" => "テンプレートの新しい決定", "app" => "アプリ固有の決定"}],
    "note" => "番号が衝突しています。アプリ固有の決定事項を`specs/app-decisions.md`の`A-###`へ移すまで、テンプレートのD-###を追記しません。"
  }
  sims = plan["simulators"]
  abort "simulators: #{sims}" unless sims["problems"] == [] && sims["planned"].all? { |name| name.start_with?("Garden Notes ") } && sims["app"] == sims["planned"]
  abort "approvals: #{plan["approvals"]}" unless plan["approvals"].length == 1 && plan["approvals"][0].include?("D-074")
'
# App-side deletions must never be restored by the plan.
grep -Fq -- '- 追加: `docs/asc-derived-app-adoption.md`' "$work/report1/plan.md" && { echo 'plan restores an app-side deletion' >&2; exit 1; }
grep -Fq -- '- 追加: `docs/agent-contracts/appstore-submission.md`' "$work/report1/plan.md" && { echo 'plan restores a deleted, template-changed file' >&2; exit 1; }
grep -Fq -- '- 削除: `specs/acceptance.md`' "$work/report1/plan.md" && { echo 'plan deletes an app-owned file' >&2; exit 1; }
for text in '## 適用する変更' '- 追加: `docs/new-guide.md`' '- 更新: `docs/workflow.md`' '- 削除: `docs/appstore-creative.md`' \
  '## 上書きしないファイル' '`docs/references.md`' '## 手で確認するファイル' '`docs/AUTHORITY.md`（衝突する）' \
  '`docs/security.md`' '番号が衝突しています' '## 必要な承認' 'このレポートは取り込み先へ何も書き込んでいません。' \
  '- `docs/asc-derived-app-adoption.md`: アプリ側で削除したファイルなので、戻しません。' \
  '- `docs/agent-contracts/appstore-submission.md`（衝突する）: アプリ側で削除されましたが'; do
  grep -Fq -- "$text" "$work/report1/plan.md" || { echo "plan.md lacks: $text" >&2; exit 1; }
done
expect_failure existing-output '--output-dir already exists' \
  "$template/tools/template-sync.sh" report --app-root "$app1" --output-dir "$work/report1"

# A recorded base stays with D-074: no provenance, no nearest version, no inferred base (AC-6).
known_base_unchanged() {
  PLAN="$1/plan.json" ruby -rjson -e '
    plan = JSON.parse(File.read(ENV.fetch("PLAN")))
    abort "a known base got an inferred base" if plan.key?("inferredBase")
    abort "a known base got provenance" if plan.fetch("files").any? { |file| file.key?("provenance") || file.key?("nearest") }
  '
  ! grep -Fq '推定の基準' "$1/plan.md" || { echo 'plan.md shows an inferred base for a known base' >&2; exit 1; }
}
known_base_unchanged "$work/report1"

# App 2: no base record, an older identity format, and template device names.
app2="$work/app2"
make_app "$app2"
(cd "$app2" && ruby -rjson -e '
  identity = JSON.parse(File.read("Config/app-identity.json"))
  identity.delete("sourceIdentityVersion")
  File.write("Config/app-identity.json", JSON.generate(identity))
  simulators = JSON.parse(File.read("Config/dedicated-simulators.json"))
  simulators["devices"].each { |device| device["name"] = device["name"].sub("Garden Notes ", "iOS-Template ") }
  File.write("Config/dedicated-simulators.json", JSON.pretty_generate(simulators) + "\n")
')
commit_all "$app2" adopted-without-base
"$template/tools/template-sync.sh" report --app-root "$app2" --output-dir "$work/report2" --work-dir "$work/cache" >/dev/null
PLAN="$work/report2/plan.json" BASE="$base" ruby -rjson -e '
  plan = JSON.parse(File.read(ENV.fetch("PLAN")))
  abort "base should be unknown: #{plan["base"]}" unless plan.dig("base", "status") == "unknown"
  files = plan.fetch("files").to_h { |file| [file["path"], file] }
  # D-078 (AC-3, AC-4): the base version of a file, untransformed or transformed with the app Identity,
  # is a safe update. docs/AUTHORITY.md is also in the intermediate tree, but the base introduced it.
  %w[docs/workflow.md docs/verification.md docs/AUTHORITY.md].each do |path|
    actual = files.fetch(path).values_at("status", "action", "provenance")
    abort "#{path} at the base version: #{actual}" unless actual == ["safe-update", "update", {"commit" => ENV.fetch("BASE"), "method" => "exact"}]
  end
  abort "inferred base: #{plan["inferredBase"]}" unless plan.dig("inferredBase", "commit") == ENV.fetch("BASE")
  abort "missing file must be added" unless files["docs/new-guide.md"].values_at("status", "action") == %w[missing add]
  abort "deletion needs a base" if files.key?("docs/appstore-creative.md")
  abort "identity format issue not reported" unless plan.dig("app", "identityFormatIssues").any? { |issue| issue.include?("sourceIdentityVersion") }
  problems = plan.dig("simulators", "problems")
  abort "template device names not reported: #{problems}" unless problems.any? { |problem| problem.include?("テンプレート用の端末") }
  abort "planned devices must keep the app prefix" unless plan.dig("simulators", "planned").all? { |name| name.start_with?("Garden Notes ") }
  abort "simulator declaration must be manual" unless files["Config/dedicated-simulators.json"]["action"] == "manual"
'
grep -Fq '基準commit: 不明' "$work/report2/plan.md" || { echo 'plan.md does not report the unknown base' >&2; exit 1; }

# App 3: a repository that never adopted the template (no identity, no base).
app3="$work/app3"
mkdir -p "$app3/docs"
printf '%s\n' '# Existing app' >"$app3/AGENTS.md"
git -C "$template" show "$base:docs/workflow.md" >"$app3/docs/workflow.md"
git -C "$app3" init -q
commit_all "$app3" existing
"$template/tools/template-sync.sh" report --app-root "$app3" --output-dir "$work/report3" --work-dir "$work/cache" >/dev/null
PLAN="$work/report3/plan.json" ruby -rjson -e '
  plan = JSON.parse(File.read(ENV.fetch("PLAN")))
  abort "non-template repository: #{plan["app"]}" unless plan.dig("app", "transform") == "identity-unavailable" && plan.dig("app", "identity").nil?
  abort "identity bootstrap absence not reported" unless plan.dig("app", "identityFormatIssues").any? { |issue| issue.include?("Identity bootstrapが未適用") }
  files = plan.fetch("files").to_h { |file| [file["path"], file] }
  abort "transformed file without identity must be manual" unless files["docs/README.md"].values_at("status", "action") == %w[missing manual]
  abort "AGENTS.md without identity must be manual" unless files["AGENTS.md"].values_at("status", "action") == %w[conflict manual]
  abort "template file must be added" unless files["docs/AUTHORITY.md"].values_at("status", "action") == %w[missing add]
'

# App 5: the recorded base has no ownership manifest, so template-deleted files stay for review.
app5="$work/app5"
make_app "$app5" "$legacy"
(cd "$app5" && LEGACY="$legacy" ruby -rjson -e '
  File.write("Config/template-base.json", JSON.generate({"schemaVersion" => 1, "templateRepository" => "yuto1201/iOS-Template",
    "baseCommit" => ENV.fetch("LEGACY"), "recordedAt" => "2026-10-05T00:00:00Z", "method" => "created"}) + "\n")
')
commit_all "$app5" legacy-created
"$template/tools/template-sync.sh" report --app-root "$app5" --output-dir "$work/report5" --work-dir "$work/cache" >/dev/null
PLAN="$work/report5/plan.json" ruby -rjson -e '
  plan = JSON.parse(File.read(ENV.fetch("PLAN")))
  abort "legacy base not known" unless plan.dig("base", "status") == "known"
  files = plan.fetch("files").to_h { |file| [file["path"], file] }
  %w[.gitignore specs/acceptance.md docs/appstore-creative.md].each do |path|
    actual = files.fetch(path).values_at("category", "status", "action")
    abort "#{path} without base ownership: #{actual}" unless actual == %w[unknown deleted-in-template manual]
  end
  abort "no deletion may be planned without base ownership" if plan.fetch("files").any? { |file| file["action"] == "delete" }
'
known_base_unchanged "$work/report5"

# An invalid base record is reported, not trusted.
app4="$work/app4"
make_app "$app4"
printf '%s\n' '{"schemaVersion":1,"templateRepository":"yuto1201/iOS-Template","baseCommit":"0000000000000000000000000000000000000000","recordedAt":"2026-10-05T00:00:00Z","method":"created"}' \
  >"$app4/Config/template-base.json"
commit_all "$app4" unknown-commit
"$template/tools/template-sync.sh" report --app-root "$app4" --output-dir "$work/report4" --work-dir "$work/cache" >/dev/null
PLAN="$work/report4/plan.json" ruby -rjson -e '
  base = JSON.parse(File.read(ENV.fetch("PLAN")))["base"]
  abort "invalid base accepted: #{base}" unless base["status"] == "invalid" && base["reason"].include?("テンプレートの履歴にありません")
'
# An invalid record is judged like a missing one, by each file's provenance (D-078).
PLAN="$work/report4/plan.json" BASE="$base" ruby -rjson -e '
  plan = JSON.parse(File.read(ENV.fetch("PLAN")))
  workflow = plan.fetch("files").find { |file| file["path"] == "docs/workflow.md" }
  abort "invalid base without provenance: #{workflow}" unless workflow.values_at("status", "provenance") == ["safe-update", {"commit" => ENV.fetch("BASE"), "method" => "exact"}]
  abort "invalid base without an inferred base: #{plan["inferredBase"]}" unless plan.dig("inferredBase", "commit") == ENV.fetch("BASE")
'

# --- provenance without a recorded base (D-078) ----------------------------------------------
# App 6 is the intermediate version without a base record. One file is put back to the base version,
# one is changed by the app, and one differs only in its executable bit.
app6="$work/app6"
make_app "$app6" "$middle"
git -C "$template" show "$base:docs/agent-contracts/ios-reviewer.md" >"$app6/docs/agent-contracts/ios-reviewer.md"
printf '%s\n' 'アプリ側の追記。' >>"$app6/docs/AUTHORITY.md"
chmod +x "$app6/docs/references.md"
commit_all "$app6" from-middle
# Only a transformed version can match: the raw intermediate version differs from the app's file.
git -C "$template" show "$middle:docs/verification.md" >"$work/verification-raw.md"
! cmp -s "$work/verification-raw.md" "$app6/docs/verification.md" || { echo 'the transformed file equals the raw version' >&2; exit 1; }
before6=$(snapshot "$app6")
"$template/tools/template-sync.sh" report --app-root "$app6" --output-dir "$work/report6" --work-dir "$work/cache" >/dev/null
[[ "$(snapshot "$app6")" == "$before6" ]] || { echo 'the report wrote to the target repository' >&2; exit 1; }
PLAN="$work/report6/plan.json" BASE="$base" MIDDLE="$middle" ruby -rjson -e '
  plan = JSON.parse(File.read(ENV.fetch("PLAN")))
  abort "base should be unknown: #{plan["base"]}" unless plan.dig("base", "status") == "unknown"
  files = plan.fetch("files").to_h { |file| [file["path"], file] }
  exact = ->(commit) { {"commit" => ENV.fetch(commit), "method" => "exact"} }
  # AC-3, AC-4: the intermediate version, untransformed and transformed, is matched to its commit and
  # becomes the base of the comparison.
  %w[docs/workflow.md docs/verification.md].each do |path|
    file = files.fetch(path)
    abort "#{path} at the intermediate version: #{file}" unless file.values_at("status", "action", "provenance") == ["safe-update", "update", exact.call("MIDDLE")]
    abort "#{path} base: #{file}" unless file.values_at("baseDigest", "baseMode") == file.values_at("appDigest", "appMode") && file["newDigest"] != file["appDigest"]
  end
  # AC-6: the inferred base is the intermediate commit, but a file at the base version is still judged
  # by its own commit (with the intermediate commit as the base it would be an app-only change).
  inferred = plan["inferredBase"]
  abort "inferred base: #{inferred}" unless inferred&.fetch("commit") == ENV.fetch("MIDDLE") && inferred["matchedFiles"].is_a?(Integer) && inferred["matchedFiles"] > 2
  reviewer = files.fetch("docs/agent-contracts/ios-reviewer.md")
  abort "per-file provenance: #{reviewer}" unless reviewer.values_at("status", "action", "provenance") == ["safe-update", "update", exact.call("BASE")]
  # AC-5: an app change and a mode-only difference match no version; each names the nearest one.
  authority = files.fetch("docs/AUTHORITY.md")
  abort "changed file: #{authority}" unless authority.values_at("status", "action", "nearest") == ["conflict", "manual", {"commit" => ENV.fetch("BASE"), "changedLines" => 1}] && !authority.key?("provenance")
  mode = files.fetch("docs/references.md")
  abort "mode-only difference: #{mode}" unless mode.values_at("status", "action", "nearest", "appMode") == ["conflict", "manual", {"commit" => ENV.fetch("BASE"), "changedLines" => 0}, "100755"] && !mode.key?("provenance")
'
unknown_reason='基準commitが不明で、アプリ側の内容はテンプレートのどの版とも一致しません。アプリ側で変更したものとして手で確認します。'
for text in "- 推定の基準: \`$middle\`" \
  "- 更新: \`docs/workflow.md\`（テンプレートの\`${middle:0:7}\`の版から）" \
  "- 更新: \`docs/agent-contracts/ios-reviewer.md\`（テンプレートの\`${base:0:7}\`の版から）" \
  "- \`docs/AUTHORITY.md\`（衝突する）: $unknown_reason 最も近い版は\`${base:0:7}\`で、違いは1行です。" \
  "- \`docs/references.md\`（衝突する）: $unknown_reason 最も近い版は\`${base:0:7}\`で、内容は同じですがfile modeが違います。"; do
  grep -Fq -- "$text" "$work/report6/plan.md" || { echo "plan.md lacks: $text" >&2; exit 1; }
done

# The inferred base also counts an Identity-transformed file that already matches the newest version,
# through every raw version that transforms to the app's content. On a side branch, X changes
# docs/workflow.md; Y then changes the raw docs/README.md and docs/workflow.md again. With a transform
# under which every README.md version gives the same text, an app at X matches X in both files and Y in
# README.md only, so X is the inferred base; counting only Y's raw README.md would tie X with Y and pick
# the newer Y. The real transform cannot give two raw versions the same text, so it is replaced here.
git -C "$template" checkout -q -b provenance-side
printf '%s\n' '分岐で追記した手順。' >>"$template/docs/workflow.md"
commit_all "$template" side-x
side_x=$(git -C "$template" rev-parse HEAD)
printf '%s\n' '分岐で追記した説明。' >>"$template/docs/README.md"
printf '%s\n' '分岐でさらに追記した手順。' >>"$template/docs/workflow.md"
commit_all "$template" side-y
side_y=$(git -C "$template" rev-parse HEAD)
git -C "$template" checkout -q -
TEMPLATE="$template" SIDE_X="$side_x" SIDE_Y="$side_y" WORK="$work/inferred" ruby -e '
  require File.join(ARGV.fetch(0), "tools/lib/template-sync.rb")
  sync = TemplateSync
  root, x, y, work = ENV.fetch("TEMPLATE"), ENV.fetch("SIDE_X"), ENV.fetch("SIDE_Y"), ENV.fetch("WORK")
  FileUtils.mkdir_p(work)
  same = File.join(work, "same")
  FileUtils.mkdir_p(File.join(same, "docs"))
  File.write(File.join(same, "docs/README.md"), "transformed README\n")
  sync.define_singleton_method(:transformed_history) { |*_| same }
  ownership = sync.load_ownership(sync.blob(root, y, sync::OWNERSHIP_PATH))
  paths = %w[docs/README.md docs/workflow.md]
  abort "README.md must be transformed" unless sync.classify(ownership, "docs/README.md")[:transform]
  app = {"docs/README.md" => sync::Entry.new("100644", "transformed README\n"),
         "docs/workflow.md" => sync::Entry.new("100644", sync.blob(root, x, "docs/workflow.md").b)}
  identity = {"displayName" => "Garden Notes", "moduleName" => "GardenNotes", "appSlug" => "garden-notes", "bundleId" => "com.yuto.GardenNotes"}
  new_raw = sync.export_tree(root, y, File.join(work, "raw-y"))
  history = sync.file_history(root, y, ownership, paths, app, identity, new_raw, same, "applied", work)
  abort "README.md matches the newest version and gets no provenance: #{history[:files]}" if history[:files].key?("docs/README.md")
  abort "workflow.md provenance: #{history[:files]}" unless history[:files].dig("docs/workflow.md", :commit) == x
  abort "inferred base should be X, not #{history[:inferred]}" unless history[:inferred] == {"commit" => x, "matchedFiles" => 2}
' "$repo_root"

# The same raw bytes can transform differently once the transform tool changes, so a transformed file
# counts only while the content its latest state transformed to equals the app's. On another side
# branch, X2 changes docs/workflow.md; Y2 changes the transform tool, docs/workflow.md again and
# docs/references.md. docs/README.md keeps the same raw bytes, but the replaced transform gives other
# text from Y2 on. An app at X2 with Y2's docs/references.md matches X2 in README.md and workflow.md and
# Y2 only in references.md, so X2 is the inferred base; counting the unchanged raw README.md at Y2
# would tie X2 with Y2 and pick the newer Y2.
git -C "$template" checkout -q -b provenance-tool
printf '%s\n' '分岐2で追記した手順。' >>"$template/docs/workflow.md"
commit_all "$template" tool-x
tool_x=$(git -C "$template" rev-parse HEAD)
printf '%s\n' '// side branch change to the transform tool' >>"$template/tools/bootstrap-app.swift"
printf '%s\n' '分岐2でさらに追記した手順。' >>"$template/docs/workflow.md"
printf '%s\n' '分岐2で追記した参照。' >>"$template/docs/references.md"
commit_all "$template" tool-y
tool_y=$(git -C "$template" rev-parse HEAD)
git -C "$template" checkout -q -
TEMPLATE="$template" TOOL_X="$tool_x" TOOL_Y="$tool_y" WORK="$work/inferred-tool" ruby -e '
  require File.join(ARGV.fetch(0), "tools/lib/template-sync.rb")
  sync = TemplateSync
  root, x, y, work = ENV.fetch("TEMPLATE"), ENV.fetch("TOOL_X"), ENV.fetch("TOOL_Y"), ENV.fetch("WORK")
  abort "README.md raw bytes changed" unless sync.blob(root, x, "docs/README.md") == sync.blob(root, y, "docs/README.md")
  trees = %w[old new].to_h do |name|
    dir = File.join(work, name)
    FileUtils.mkdir_p(File.join(dir, "docs"))
    File.write(File.join(dir, "docs/README.md"), "README by the #{name} tool\n")
    [name, dir]
  end
  sync.define_singleton_method(:transformed_history) { |_root, sha, *_| sha == y ? trees["new"] : trees["old"] }
  ownership = sync.load_ownership(sync.blob(root, y, sync::OWNERSHIP_PATH))
  paths = %w[docs/README.md docs/workflow.md docs/references.md]
  app = {"docs/README.md" => sync::Entry.new("100644", "README by the old tool\n"),
         "docs/workflow.md" => sync::Entry.new("100644", sync.blob(root, x, "docs/workflow.md").b),
         "docs/references.md" => sync::Entry.new("100644", sync.blob(root, y, "docs/references.md").b)}
  identity = {"displayName" => "Garden Notes", "moduleName" => "GardenNotes", "appSlug" => "garden-notes", "bundleId" => "com.yuto.GardenNotes"}
  new_raw = sync.export_tree(root, y, File.join(work, "raw-y"))
  history = sync.file_history(root, y, ownership, paths, app, identity, new_raw, trees["new"], "applied", work)
  abort "inferred base should be X2, not #{history[:inferred]}" unless history[:inferred] == {"commit" => x, "matchedFiles" => 2}
' "$repo_root"

# --- preflight: other work in progress and the size of the change (D-078) --------------------
# The target is on main with a recorded base. A fake gh, first in PATH, answers only the two read-only
# list queries, from FAKE_GH_ISSUES and FAKE_GH_PRS (FAKE_GH_FAIL makes one fail or answer something
# that is not JSON), and refuses anything else, so no case reaches GitHub.
fake_bin="$work/fake-bin"
gh_log="$work/gh-calls.log"
mkdir -p "$fake_bin" "$work/plans" "$work/preflight"
cat >"$fake_bin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
case "$*" in
  'issue list --repo test-owner/garden-notes --state open --limit 1000 --json number,title,labels') kind=issue answer=${FAKE_GH_ISSUES:-[]} ;;
  'pr list --repo test-owner/garden-notes --state open --limit 1000 --json number,title,headRefName') kind=pr answer=${FAKE_GH_PRS:-[]} ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 2 ;;
esac
case "${FAKE_GH_FAIL:-}" in
  "$kind") echo 'HTTP 401: Bad credentials (https://api.github.com/graphql)' >&2; exit 1 ;;
  "$kind-garbage") echo 'Welcome to GitHub CLI!'; exit 0 ;;
  "$kind-hang") sleep 30 ;;
esac
printf '%s\n' "$answer"
EOF
chmod +x "$fake_bin/gh"

target="$work/target"
make_app "$target"
git -C "$target" symbolic-ref HEAD refs/heads/main
(cd "$target" && BASE="$base" ruby -rjson -e '
  File.write("Config/template-base.json", JSON.pretty_generate({
    "schemaVersion" => 1, "templateRepository" => "yuto1201/iOS-Template", "baseCommit" => ENV.fetch("BASE"),
    "recordedAt" => "2026-10-05T00:00:00Z", "method" => "created"
  }) + "\n")
')
commit_all "$target" created
"$template/tools/template-sync.sh" report --app-root "$target" --output-dir "$work/target-report" --work-dir "$work/cache" >/dev/null

preflight_cli() {
  PATH="$fake_bin:$PATH" FAKE_GH_LOG="$gh_log" "$template/tools/template-sync.sh" preflight "$@"
}

# run_preflight NAME PLAN: one preflight of the target. Afterwards the target's status, HEAD and every
# byte, its .git included, must be what they were (AC-6).
run_preflight() {
  local name=$1 plan=$2 status head before
  status=$(GIT_OPTIONAL_LOCKS=0 git -C "$target" status --porcelain --untracked-files=all)
  head=$(git -C "$target" rev-parse HEAD)
  before=$(snapshot "$target")
  preflight_cli --app-root "$target" --repo test-owner/garden-notes --plan "$plan" --output-dir "$work/preflight/$name" \
    --now 2026-10-13T00:00:00Z >"$work/preflight/$name.out"
  [[ "$(snapshot "$target")" == "$before" && "$(git -C "$target" rev-parse HEAD)" == "$head" &&
     "$(GIT_OPTIONAL_LOCKS=0 git -C "$target" status --porcelain --untracked-files=all)" == "$status" ]] ||
    { echo "preflight $name changed the target" >&2; exit 1; }
}

# expect_preflight NAME STATUS FINDING-KINDS SIZE REASON-KINDS: preflight.json says exactly this, the
# printed summary agrees, and preflight.md shows the status and every reason.
expect_preflight() {
  RESULT="$work/preflight/$1" STATUS=$2 KINDS=$3 SIZE=$4 REASONS=$5 ruby -rjson -rdigest -e '
    dir = ENV.fetch("RESULT")
    result = JSON.parse(File.read(File.join(dir, "preflight.json")))
    summary = JSON.parse(File.read("#{dir}.out"))
    markdown = File.read(File.join(dir, "preflight.md"))
    kinds = result["findings"].map { |finding| finding["kind"] }
    reasons = result.dig("size", "reasons")
    abort "#{dir}: #{result["status"]} with #{kinds}" unless result["status"] == ENV.fetch("STATUS") && kinds == ENV.fetch("KINDS").split
    abort "#{dir}: size #{result["size"]}" unless result.dig("size", "estimate") == ENV.fetch("SIZE") && reasons.map { |reason| reason["kind"] } == ENV.fetch("REASONS").split
    abort "#{dir}: summary #{summary}" unless summary.values_at("status", "size", "output", "planDigest") == [result["status"], ENV.fetch("SIZE"), dir, result.dig("plan", "digest")] &&
      summary["preflightDigest"] == "sha256:#{Digest::SHA256.file(File.join(dir, "preflight.json")).hexdigest}"
    abort "#{dir}: preflight.md lacks the status" unless markdown.include?("## ほかの作業中か: #{result["status"] == "busy" ? "作業中" : "作業中ではない"}\n")
    abort "#{dir}: preflight.md lacks a reason" unless reasons.all? { |reason| markdown.include?("- 理由: #{reason["message"]}\n") }
  '
}

# expect_findings NAME JSON: the findings, exactly.
expect_findings() {
  RESULT="$work/preflight/$1/preflight.json" EXPECTED=$2 ruby -rjson -e '
    findings = JSON.parse(File.read(ENV.fetch("RESULT")))["findings"]
    abort "#{ENV["RESULT"]}: #{findings}" unless findings == JSON.parse(ENV.fetch("EXPECTED"))
  '
}

expect_markdown() {
  grep -Fq -- "$2" "$work/preflight/$1/preflight.md" || { echo "preflight $1 lacks: $2" >&2; exit 1; }
}

# craft_plan NAME RUBY: the target's plan at the limits of a normal change (30 files to write, 10 to
# review by hand, only template files), then changed by RUBY, which gets `plan` and `set.call(action,
# count)` for more template files. plan.md is rendered again, so preflight accepts it as a report's plan.
craft_plan() {
  mkdir "$work/plans/$1"
  PLAN="$work/target-report/plan.json" OUT="$work/plans/$1" CHANGE=$2 ruby -r"$template/tools/lib/template-sync.rb" -rjson -e '
    plan = JSON.parse(File.read(ENV.fetch("PLAN")))
    plan["files"].each { |file| file["action"] = %w[app template-only].include?(file["category"]) ? "skip" : "none" }
    plan["decisions"].merge!("collisions" => [], "append" => [])
    set = lambda do |action, count|
      chosen = plan["files"].select { |file| file["category"] == "template" && file["action"] == "none" }.first(count)
      abort "the plan has too few template files" unless chosen.length == count
      chosen.each { |file| file["action"] = action }
    end
    set.call("add", 10)
    set.call("update", 10)
    set.call("delete", 10)
    set.call("manual", 10)
    eval(ENV.fetch("CHANGE"))
    File.write(File.join(ENV.fetch("OUT"), "plan.json"), TemplateSync.canonical_json(plan))
    File.write(File.join(ENV.fetch("OUT"), "plan.md"), TemplateSync.render_markdown(plan))
  '
}
craft_plan normal ''
normal_plan="$work/plans/normal/plan.json"

# AC-3: with nothing in progress the target is idle; an untracked file alone keeps it idle.
run_preflight idle "$normal_plan"
expect_preflight idle idle '' normal ''
PLAN="$normal_plan" RESULT="$work/preflight/idle/preflight.json" HEAD=$(git -C "$target" rev-parse HEAD) ruby -rjson -rdigest -e '
  result = JSON.parse(File.read(ENV.fetch("RESULT")))
  abort "plan digest: #{result["plan"]}" unless result.dig("plan", "digest") == "sha256:#{Digest::SHA256.file(ENV.fetch("PLAN")).hexdigest}"
  abort "heads: #{result}" unless result.dig("plan", "appHead") == ENV.fetch("HEAD") && result.dig("app", "head") == ENV.fetch("HEAD")
  abort "counts at the limits: #{result["size"]}" unless result["size"].values_at("writeFiles", "manualFiles") == [30, 10]
  abort "untracked: #{result["app"]}" unless result.dig("app", "untracked") == []
'
printf '%s\n' 'note' >"$target/local-note.txt"
run_preflight untracked "$normal_plan"
expect_preflight untracked idle '' normal ''
expect_markdown untracked '未追跡のファイルがあります（ほかの作業中かの判定には数えません）: `local-note.txt`'
rm "$target/local-note.txt"

# Each working-state label, and any blocked:* label, makes an open Issue busy; other labels do not.
for label in state:claimed state:in-progress state:verify-passed state:review-requested state:changes-requested \
  state:approved-for-merge state:paused blocked:user blocked:dependency; do
  name="issue-${label/:/-}"
  FAKE_GH_ISSUES="[{\"number\":3,\"title\":\"提案中\",\"labels\":[{\"name\":\"state:proposed\"},{\"name\":\"type:feature\"}]},
    {\"number\":12,\"title\":\"作業中のIssue\",\"labels\":[{\"name\":\"type:feature\"},{\"name\":\"$label\"}]}]" \
    run_preflight "$name" "$normal_plan"
  expect_preflight "$name" busy issue normal ''
  expect_findings "$name" "[{\"kind\":\"issue\",\"number\":12,\"title\":\"作業中のIssue\",\"labels\":[\"$label\"]}]"
  expect_markdown "$name" "- Issue #12「作業中のIssue」（${label}）"
done

FAKE_GH_PRS='[{"number":5,"title":"Add a widget","headRefName":"claude/5-add-a-widget"}]' run_preflight pull-request "$normal_plan"
expect_preflight pull-request busy pull-request normal ''
expect_findings pull-request '[{"kind":"pull-request","number":5,"title":"Add a widget","branch":"claude/5-add-a-widget"}]'
expect_markdown pull-request '- 開いているPR #5「Add a widget」（ブランチ`claude/5-add-a-widget`）'

git -C "$target" worktree add -q -b feature "$work/target-feature"
run_preflight worktree "$normal_plan"
expect_preflight worktree busy worktree normal ''
expect_findings worktree "[{\"kind\":\"worktree\",\"path\":\"$work/target-feature\",\"branch\":\"feature\",\"head\":\"$(git -C "$target" rev-parse HEAD)\"}]"
expect_markdown worktree "- 本体以外のworktree \`$work/target-feature\`（ブランチ\`feature\`）"
# A linked worktree is not the main checkout, so it cannot stand for the target.
expect_failure preflight-linked-worktree '--app-root must be the main checkout of the target' \
  preflight_cli --app-root "$work/target-feature" --repo test-owner/garden-notes --plan "$normal_plan" --output-dir "$work/preflight/linked"
git -C "$target" worktree remove "$work/target-feature"
git -C "$target" branch -q -D feature

git -C "$target" checkout -q -b other
run_preflight branch "$normal_plan"
expect_preflight branch busy branch normal ''
expect_findings branch '[{"kind":"branch","branch":"other"}]'
expect_markdown branch '- 本体のcheckoutが`main`ではなく`other`にいます。'
git -C "$target" checkout -q --detach main
run_preflight detached "$normal_plan"
expect_preflight detached busy branch normal ''
expect_findings detached '[{"kind":"branch","branch":null}]'
expect_markdown detached '（detached HEAD）'
git -C "$target" checkout -q main
git -C "$target" branch -q -D other

# A tracked change counts whether it is staged or not.
printf '%s\n' 'ローカルの変更。' >>"$target/docs/workflow.md"
printf '%s\n' 'staged' >"$target/docs/staged.md"
git -C "$target" add docs/staged.md
run_preflight uncommitted "$normal_plan"
expect_preflight uncommitted busy uncommitted-changes normal ''
expect_findings uncommitted '[{"kind":"uncommitted-changes","paths":["docs/staged.md","docs/workflow.md"]}]'
expect_markdown uncommitted '- 本体のcheckoutに未commitの変更があります: `docs/staged.md`、`docs/workflow.md`'
git -C "$target" rm -q --cached docs/staged.md
rm "$target/docs/staged.md"
git -C "$target" checkout -q -- docs/workflow.md

# AC-4: each reason alone makes the change large, and is listed.
craft_plan unknown-base 'plan["base"] = {"status" => "unknown", "reason" => "Config/template-base.jsonがありません。"}'
craft_plan invalid-base 'plan["base"] = {"status" => "invalid", "reason" => "Config/template-base.jsonを読めません。"}'
craft_plan many-writes 'set.call("update", 1)'
craft_plan many-manual 'set.call("manual", 1)'
craft_plan collision 'plan["decisions"]["collisions"] = [{"id" => "D-001", "template" => "テンプレートの決定", "app" => "アプリの決定"}]'
craft_plan no-identity 'plan["app"]["identity"] = nil'
craft_plan appended-decision 'plan["decisions"]["append"] = ["D-999"]'
for entry in unknown-base:base-unknown invalid-base:base-unknown many-writes:many-writes many-manual:many-manual \
  collision:decision-collision no-identity:identity-unavailable appended-decision:shared-settings; do
  run_preflight "size-${entry%%:*}" "$work/plans/${entry%%:*}/plan.json"
  expect_preflight "size-${entry%%:*}" idle '' large "${entry#*:}"
done
expect_markdown size-many-writes '- 理由: 書き込むファイルが31個で、30個を超えています。'
expect_markdown size-many-manual '- 理由: 手で確認するファイルが11個で、10個を超えています。'
expect_markdown size-unknown-base '- 理由: 基準commitが分かりません。Config/template-base.jsonがありません。'
expect_markdown size-collision '- 理由: 決定事項の番号が衝突しています（D-001）。'
# Every shared setting counts once the plan does anything to it. One template file leaves the manual
# review, so the shared setting is the only reason.
for path in AGENTS.md Config/repository-tests.json specs/decisions.md Config/dedicated-simulators.json; do
  name="shared-${path//\//-}"
  TOUCH=$path craft_plan "$name" 'plan["files"].find { |file| file["action"] == "manual" }["action"] = "none"
    plan["files"].find { |file| file["path"] == ENV.fetch("TOUCH") }["action"] = "manual"'
  run_preflight "$name" "$work/plans/$name/plan.json"
  expect_preflight "$name" idle '' large shared-settings
  expect_markdown "$name" "- 理由: 共有の設定（\`$path\`）に触れます。"
done

# Reports as written: the target's own plan changes specs/decisions.md; app2 has no base, app1 a decision
# collision, and app3 no Identity. Those three plans were made for other repositories, which the result notes.
FAKE_GH_PRS='[{"number":8,"title":"Sync the template","headRefName":"claude/8-sync"}]' run_preflight real-target "$work/target-report/plan.json"
run_preflight real-no-base "$work/report2/plan.json"
run_preflight real-collision "$work/report1/plan.json"
run_preflight real-no-identity "$work/report3/plan.json"
for entry in real-target:busy:shared-settings real-no-base:idle:base-unknown real-collision:idle:decision-collision \
  real-no-identity:idle:identity-unavailable; do
  IFS=: read -r name status reason <<<"$entry"
  RESULT="$work/preflight/$name/preflight.json" STATUS=$status REASON=$reason ruby -rjson -e '
    result = JSON.parse(File.read(ENV.fetch("RESULT")))
    abort "#{ENV["RESULT"]}: #{result}" unless result["status"] == ENV.fetch("STATUS") && result.dig("size", "estimate") == "large" &&
      result.dig("size", "reasons").any? { |reason| reason["kind"] == ENV.fetch("REASON") }
  '
done
expect_markdown real-target '- 理由: 共有の設定（`specs/decisions.md`）に触れます。'
expect_markdown real-no-base "計画は取り込み先の別のHEAD（\`$(git -C "$app2" rev-parse HEAD)\`）で作られています。"
! grep -Fq '計画は取り込み先の別のHEAD' "$work/preflight/real-target/preflight.md" || { echo 'the target plan was taken for another HEAD' >&2; exit 1; }

# AC-5: busy advises waiting until the other work is done, and an idle large change advises not starting
# other work meanwhile. Every result says that parallel worktrees are not recommended for a large change
# and leaves that choice to the user; none starts or decides parallel work.
for name in idle pull-request size-many-writes real-target; do
  expect_markdown "$name" '- 並行して進めるなら、worktreeを分けて行えます。ただし、大きい変更では並行をおすすめしません。'
  expect_markdown "$name" '- 並行して進めるかは、ユーザーの明示の指示だけで決めます。この判定は並行するかを決めません。'
done
for name in pull-request real-target; do
  expect_markdown "$name" '- ほかの作業中なので、取り込みを始めません。上の作業が終わるまで待ってから取り込むことをおすすめします。'
done
expect_markdown size-many-writes '- ほかの作業中ではありません。大きい変更なので、取り込みが終わるまでほかの作業を始めずに待つことをおすすめします。'
for name in size-many-writes real-target; do
  expect_markdown "$name" 'ただし、大きい変更では並行をおすすめしません。今回は大きい変更です。'
done
expect_markdown idle '- ほかの作業中ではありません。取り込み先の単独の作業として、テンプレート同期Issueで進められます。'
! grep -Fq '今回は大きい変更です。' "$work/preflight/idle/preflight.md" || { echo 'a normal change was called large' >&2; exit 1; }
if grep -E '並行(して|で)(進めます|取り込みます|行います)' "$work"/preflight/*/preflight.md; then
  echo 'a preflight decided to work in parallel' >&2
  exit 1
fi

# AC-6: when gh fails, answers something that is not JSON or not the expected list, or may have cut the
# list off, the preflight stops with no result and the target unchanged, although the target is idle.
expect_no_result() {
  local label=$1 message=$2 before
  before=$(snapshot "$target")
  expect_failure "preflight-$label" "$message" \
    preflight_cli --app-root "$target" --repo test-owner/garden-notes --plan "$normal_plan" --output-dir "$work/preflight/$label"
  [[ ! -e "$work/preflight/$label" && "$(snapshot "$target")" == "$before" ]] || { echo "preflight $label left a result or changed the target" >&2; exit 1; }
}
FAKE_GH_FAIL=issue expect_no_result gh-issue-fails 'gh issue list failed (HTTP 401: Bad credentials'
FAKE_GH_FAIL=pr expect_no_result gh-pr-fails 'gh pr list failed (HTTP 401: Bad credentials'
FAKE_GH_FAIL=issue-garbage expect_no_result gh-issue-garbage 'gh issue list returned output that is not JSON; cannot tell whether test-owner/garden-notes is busy'
# A gh that does not answer is stopped after the time limit (shortened here) instead of hanging the preflight.
IOS_TEMPLATE_SYNC_GH_TIMEOUT_SECONDS=2 FAKE_GH_FAIL=issue-hang expect_no_result gh-issue-hangs 'gh issue list did not answer within 2 seconds; cannot tell whether test-owner/garden-notes is busy'
IOS_TEMPLATE_SYNC_GH_TIMEOUT_SECONDS=0 expect_no_result gh-bad-timeout 'IOS_TEMPLATE_SYNC_GH_TIMEOUT_SECONDS must be an integer from 1 to 300'
FAKE_GH_FAIL=pr-garbage expect_no_result gh-pr-garbage 'gh pr list returned output that is not JSON; cannot tell whether test-owner/garden-notes is busy'
FAKE_GH_ISSUES='[{"number":"1","title":"x","labels":[]}]' expect_no_result gh-issue-unexpected 'gh issue list returned an unexpected answer'
FAKE_GH_ISSUES=$(ruby -rjson -e 'puts JSON.generate((1..1000).map { |number| {"number" => number, "title" => "Issue #{number}", "labels" => []} })') \
  expect_no_result gh-issue-limit 'gh issue list returned 1000 entries and may have left some out'
expect_failure preflight-repo '--repo must be owner/name' \
  preflight_cli --app-root "$target" --repo garden-notes --plan "$normal_plan" --output-dir "$work/preflight/bad-repo"
expect_failure preflight-output-inside '--output-dir must not be inside the app repository' \
  preflight_cli --app-root "$target" --repo test-owner/garden-notes --plan "$normal_plan" --output-dir "$target/preflight"
expect_failure preflight-not-a-plan '--plan must be a plan.json file' \
  preflight_cli --app-root "$target" --repo test-owner/garden-notes --plan "$work/preflight/idle/preflight.json" --output-dir "$work/preflight/not-a-plan"
[[ ! -e "$work/preflight/bad-repo" && ! -e "$target/preflight" && ! -e "$work/preflight/not-a-plan" ]] || { echo 'a rejected preflight left a result' >&2; exit 1; }
# gh was asked only the two read-only list queries.
[[ "$(sort -u "$gh_log")" == "$(printf '%s\n' \
  'issue list --repo test-owner/garden-notes --state open --limit 1000 --json number,title,labels' \
  'pr list --repo test-owner/garden-notes --state open --limit 1000 --json number,title,headRefName')" ]] ||
  { echo "unexpected gh calls: $(sort -u "$gh_log")" >&2; exit 1; }

echo "template sync report tests passed"
