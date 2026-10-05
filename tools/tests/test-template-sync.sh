#!/bin/bash
set -euo pipefail

# D-074 template sync, report half: ownership classification and the read-only diff report/plan.
# A synthetic template repository holds this template's tracked files as its base commit, then a
# second commit with template-side changes; synthetic target repositories cover a recorded base,
# an unknown base, a non-template repository, app-side changes, Identity transform, and a
# decision-number collision.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby swiftc tar shasum

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-template-sync.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name='Template Sync Test' -c user.email=template-sync@example.invalid -c commit.gpgsign=false \
    commit -q -m "$2"
}

snapshot() {
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) | shasum -a 256 | awk '{print $1}'
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

# --- ownership classification (AC-3) ----------------------------------------------------------
check_output=$("$repo_root/tools/template-sync.sh" check)
CHECK="$check_output" ruby -rjson -e '
  value = JSON.parse(ENV.fetch("CHECK"))
  abort "check did not classify the template" unless value["status"] == "classified"
  counts = value.fetch("categories")
  abort "a category is empty: #{counts}" unless counts.keys.sort == %w[app identity mixed template template-only] && counts.values.all?(&:positive?)
  abort "category counts do not cover every file" unless counts.values.sum == value["files"]
'

template="$work/template"
mkdir -p "$template"
(cd "$repo_root" && git ls-files -z | tar --null -T - -cf -) | tar -x -C "$template"
git -C "$template" init -q
commit_all "$template" base
base=$(git -C "$template" rev-parse HEAD)

printf '%s\n' 'unclassified' >"$template/UNCLASSIFIED.txt"
commit_all "$template" unclassified
expect_failure unclassified-file 'unclassified template files: UNCLASSIFIED.txt' "$template/tools/template-sync.sh" check
git -C "$template" reset -q --hard "$base"

# --- template-side changes since the base ----------------------------------------------------
printf '%s\n' 'テンプレートの手順を追記した。' >>"$template/docs/workflow.md"          # safe update
printf '%s\n' 'テンプレート側の追記。' >>"$template/docs/AUTHORITY.md"                # conflict
printf '%s\n' '# New guide' '' 'テンプレートが追加した文書。' >"$template/docs/new-guide.md" # missing
git -C "$template" rm -q docs/goldie.md                                              # deleted in template
printf '%s\n' '同期testの追記。' >>"$template/docs/README.md"                        # transformed safe update
printf '%s\n' '旧名TemplateAppを含む追記。' >>"$template/docs/security.md"           # identity regression
printf '%s\n' '' '## D-076: テンプレートの新しい決定' '' '- Status: 確定' >>"$template/specs/decisions.md"
printf '%s\n' 'テンプレートのproduct変更。' >>"$template/specs/product.md"          # app-owned
printf '%s\n' 'テンプレートの計画変更。' >>"$template/docs/superpowers/plans/README.md" # template-only
commit_all "$template" new

# --- target repositories ---------------------------------------------------------------------
bootstrap_binary="$work/bootstrap-app"
swiftc -o "$bootstrap_binary" "$repo_root/tools/bootstrap-app.swift"

make_app() {
  local app=$1
  mkdir -p "$app"
  git -C "$template" archive "$base" | tar -x -C "$app"
  "$bootstrap_binary" apply --root "$app" --manifest "$app/Config/template-identity.json" \
    --display-name 'Garden Notes' --module-name GardenNotes --app-slug garden-notes --bundle-id com.yuto.GardenNotes >/dev/null
  git -C "$app" init -q
}

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
printf '%s\n' '' '## D-076: アプリ固有の決定' '' '- Status: 確定' >>"$app1/specs/decisions.md"
commit_all "$app1" app-changes
before=$(snapshot "$app1")

expect_failure output-inside-app 'must not be inside the app repository' \
  "$template/tools/template-sync.sh" report --app-root "$app1" --output-dir "$app1/sync-report"
report1=$("$template/tools/template-sync.sh" report --app-root "$app1" --output-dir "$work/report1" \
  --work-dir "$work/cache" --now 2026-10-05T01:00:00Z)
[[ "$(snapshot "$app1")" == "$before" ]] || { echo 'the report wrote to the target repository' >&2; exit 1; }

expected_readme_digest="sha256:$( { cat "$app1/docs/README.md"; printf '%s\n' '同期testの追記。'; } | shasum -a 256 | awk '{print $1}')"
PLAN="$work/report1/plan.json" BASE="$base" README_DIGEST="$expected_readme_digest" REPORT="$report1" ruby -rjson -rdigest -e '
  plan = JSON.parse(File.read(ENV.fetch("PLAN")))
  abort "report digest differs" unless JSON.parse(ENV.fetch("REPORT"))["planDigest"] == "sha256:#{Digest::SHA256.file(ENV.fetch("PLAN")).hexdigest}"
  abort "base not recorded: #{plan["base"]}" unless plan["base"] == {"status" => "known", "commit" => ENV.fetch("BASE"), "method" => "created", "recordedAt" => "2026-10-05T00:00:00Z"}
  abort "transform not applied" unless plan.dig("app", "transform") == "applied" && plan.dig("app", "identityFormatIssues") == []
  files = plan.fetch("files").to_h { |file| [file["path"], file] }
  expect = {
    "docs/workflow.md" => %w[safe-update update], "docs/AUTHORITY.md" => %w[conflict manual],
    "docs/references.md" => %w[app-only-change keep], "docs/new-guide.md" => %w[missing add],
    "docs/goldie.md" => %w[deleted-in-template delete], "docs/README.md" => %w[safe-update update],
    "docs/security.md" => %w[safe-update manual], "specs/decisions.md" => %w[conflict manual],
    "specs/product.md" => %w[app-owned skip], "TemplateApp/ContentView.swift" => %w[app-owned skip],
    "docs/superpowers/plans/README.md" => %w[template-only skip], "tools/template-sync.sh" => %w[template-only skip],
    "AGENTS.md" => %w[up-to-date none], "Config/dedicated-simulators.json" => %w[up-to-date none],
    "tools/bootstrap-app.swift" => %w[up-to-date none]
  }
  expect.each do |path, (status, action)|
    actual = files.fetch(path) { abort "missing #{path}" }.values_at("status", "action")
    abort "#{path}: expected #{status}/#{action}, got #{actual.join("/")}" unless actual == [status, action]
  end
  abort "transformed README digest differs" unless files["docs/README.md"]["newDigest"] == ENV.fetch("README_DIGEST")
  abort "identity regression not flagged" unless files["docs/security.md"]["identityRegression"] == true
  abort "decision collision not reported" unless plan["decisions"] == {
    "templateNew" => ["D-076"], "appendable" => false,
    "collisions" => [{"id" => "D-076", "template" => "テンプレートの新しい決定", "app" => "アプリ固有の決定"}],
    "note" => "番号が衝突しています。アプリ固有の決定事項をA-###へ移すまで、テンプレートのD-###を追記しません。"
  }
  sims = plan["simulators"]
  abort "simulators: #{sims}" unless sims["problems"] == [] && sims["planned"].all? { |name| name.start_with?("Garden Notes ") } && sims["app"] == sims["planned"]
  abort "approvals: #{plan["approvals"]}" unless plan["approvals"].length == 1 && plan["approvals"][0].include?("D-074")
'
for text in '## 適用する変更' '- 追加: `docs/new-guide.md`' '- 更新: `docs/workflow.md`' '- 削除: `docs/goldie.md`' \
  '## 上書きしないファイル' '`docs/references.md`' '## 手で確認するファイル' '`docs/AUTHORITY.md`（衝突する）' \
  '`docs/security.md`' '番号が衝突しています' '## 必要な承認' 'このレポートは取り込み先へ何も書き込んでいません。'; do
  grep -Fq -- "$text" "$work/report1/plan.md" || { echo "plan.md lacks: $text" >&2; exit 1; }
done
expect_failure existing-output '--output-dir already exists' \
  "$template/tools/template-sync.sh" report --app-root "$app1" --output-dir "$work/report1"

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
PLAN="$work/report2/plan.json" ruby -rjson -e '
  plan = JSON.parse(File.read(ENV.fetch("PLAN")))
  abort "base should be unknown: #{plan["base"]}" unless plan.dig("base", "status") == "unknown"
  files = plan.fetch("files").to_h { |file| [file["path"], file] }
  abort "unknown-base difference must be manual" unless files["docs/workflow.md"].values_at("status", "action") == %w[conflict manual]
  abort "missing file must be added" unless files["docs/new-guide.md"].values_at("status", "action") == %w[missing add]
  abort "deletion needs a base" if files.key?("docs/goldie.md")
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

echo "template sync report tests passed"
