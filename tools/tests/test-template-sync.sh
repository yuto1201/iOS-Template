#!/bin/bash
set -euo pipefail

# D-074 template sync, report half: ownership classification and the read-only diff report/plan.
# A synthetic template repository holds this template's tracked files (in a derived app, the same
# files rebuilt from the frozen template Identity) as its base commit, then an intermediate commit
# and a commit with template-side changes; synthetic target repositories cover a recorded base,
# an unknown base judged by each file's provenance (D-078), a non-template repository, app-side
# changes, Identity transform, and a decision-number collision.

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

echo "template sync report tests passed"
