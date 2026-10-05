#!/bin/bash
set -euo pipefail

# D-074 template sync, apply half: approval bound to the plan digest, the Codex route through the
# fixed read-only launcher, and apply on a synthetic target. A synthetic template repository holds
# this template's tracked files as its base commit, then a second commit with template-side changes.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby swiftc tar shasum cc

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-template-sync-apply.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name='Template Sync Test' -c user.email=template-sync@example.invalid -c commit.gpgsign=false \
    -c gc.auto=0 -c maintenance.auto=false commit -q -m "$2"
}

# Every entry (directories and symlinks included), every file's bytes and every mode, outside .git.
snapshot() {
  (cd "$1" && { find . -path ./.git -prune -o -print | LC_ALL=C sort
    find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
    find . -path ./.git -prune -o -type f -perm -u+x -print | LC_ALL=C sort; }) | shasum -a 256 | awk '{print $1}'
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

# The apply must stop without changing anything in the target.
expect_untouched() {
  local label=$1 message=$2 app=$3
  shift 3
  local before
  before=$(snapshot "$app")
  expect_failure "$label" "$message" "$@"
  [[ "$(snapshot "$app")" == "$before" ]] || { echo "$label wrote to the target" >&2; exit 1; }
}

sync="$work/template/tools/template-sync.sh"
comment_url='https://github.com/yuto1201/iOS-GardenNotes/issues/7#issuecomment-1001'
codex_url='https://github.com/yuto1201/iOS-GardenNotes/issues/7#issuecomment-1002'

# --- synthetic template ----------------------------------------------------------------------
template="$work/template"
mkdir -p "$template"
(cd "$repo_root" && git ls-files -z | tar --null -T - -cf "$work/template.tar")
tar -x -f "$work/template.tar" -C "$template"
rm -f "$work/template.tar"
git -C "$template" init -q
commit_all "$template" base
base=$(git -C "$template" rev-parse HEAD)

printf '%s\n' 'テンプレートの手順を追記した。' >>"$template/docs/workflow.md"           # safe update
printf '%s\n' 'テンプレート側の追記。' >>"$template/docs/AUTHORITY.md"                 # conflict
printf '%s\n' '# New guide' '' 'テンプレートが追加した文書。' >"$template/docs/new-guide.md"  # missing
ln -s new-guide.md "$template/docs/new-guide-link.md"                                 # missing symlink
git -C "$template" rm -q docs/goldie.md                                               # deleted in template
printf '%s\n' '同期testの追記。' >>"$template/docs/README.md"                         # transformed safe update
printf '%s\n' '旧名TemplateAppを含む追記。' >>"$template/docs/security.md"            # identity regression
chmod +x "$template/tools/lib/bounded-command.rb"                                     # mode-only update
printf '%s\n' 'テンプレートのproduct変更。' >>"$template/specs/product.md"           # app-owned
printf '%s\n' 'テンプレートの計画変更。' >>"$template/docs/superpowers/plans/README.md" # template-only
next_decision=$(ruby -e 'ids = File.read(ARGV[0]).scan(/^## D-(\d{3,}):/).flatten.map(&:to_i); printf("D-%03d", ids.max + 1)' "$template/specs/decisions.md")
printf '%s\n' '' "## $next_decision: テンプレートの新しい決定" '' '- Status: 確定' '- Decision: 同期testで追記する。' >>"$template/specs/decisions.md"
commit_all "$template" new
new=$(git -C "$template" rev-parse HEAD)

bootstrap_binary="$work/bootstrap-app"
swiftc -o "$bootstrap_binary" "$repo_root/tools/bootstrap-app.swift"

# A target created from the base with a recorded base commit, on a template sync branch.
make_app() {
  local app=$1
  mkdir -p "$app"
  git -C "$template" archive "$base" | tar -x -C "$app"
  "$bootstrap_binary" apply --root "$app" --manifest "$app/Config/template-identity.json" \
    --display-name 'Garden Notes' --module-name GardenNotes --app-slug garden-notes --bundle-id com.yuto.GardenNotes >/dev/null
  (cd "$app" && BASE="$base" ruby -rjson -e '
    File.write("Config/template-base.json", JSON.pretty_generate({
      "baseCommit" => ENV.fetch("BASE"), "method" => "created", "recordedAt" => "2026-10-05T00:00:00Z",
      "schemaVersion" => 1, "templateRepository" => "yuto1201/iOS-Template"
    }) + "\n")
  ')
  git -C "$app" init -q -b main
  commit_all "$app" created
  printf '%s\n' 'アプリ側の追記。' >>"$app/docs/AUTHORITY.md"
  printf '%s\n' 'アプリ側だけの追記。' >>"$app/docs/references.md"
}

report() {
  "$sync" report --app-root "$1" --output-dir "$2" --work-dir "$work/cache" --now 2026-10-05T01:00:00Z >/dev/null
}

# --- the main target ---------------------------------------------------------------------------
app="$work/app"
make_app "$app"
commit_all "$app" app-changes
report "$app" "$work/plan"
plan="$work/plan/plan.json"

# A user approval needs a comment URL and records the plan digest.
expect_failure approve-without-reference '--reference with the Issue comment URL' \
  "$sync" approve --plan "$plan" --approver user --output "$work/approval-none.json"
expect_failure approve-bad-reference '--reference must be a GitHub Issue or pull request comment URL' \
  "$sync" approve --plan "$plan" --approver user --reference 'https://example.invalid/approved' --output "$work/approval-bad.json"
"$sync" approve --plan "$plan" --approver user --reference "$comment_url" --output "$work/approval.json" --now 2026-10-05T02:00:00Z >/dev/null
PLAN="$plan" APPROVAL="$work/approval.json" URL="$comment_url" ruby -rjson -rdigest -e '
  approval = JSON.parse(File.read(ENV.fetch("APPROVAL")))
  expected = {"approvedAt" => "2026-10-05T02:00:00Z", "approver" => "user", "decision" => "approved",
              "planDigest" => "sha256:#{Digest::SHA256.file(ENV.fetch("PLAN")).hexdigest}", "reference" => ENV.fetch("URL"),
              "schemaVersion" => 1, "scope" => "template-sync-plan"}
  abort "approval record: #{approval}" unless approval == expected
'

# AC-3: no valid approval, a changed plan, a dirty target, and main all stop before any write.
expect_untouched apply-without-approval 'missing-approval.json' "$app" \
  "$sync" apply --plan "$plan" --approval "$work/missing-approval.json" --app-root "$app" --work-dir "$work/cache"
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["decision"] = "rejected"; File.write(ARGV[1], JSON.generate(value))' \
  "$work/approval.json" "$work/approval-rejected.json"
expect_untouched apply-rejected-approval 'approval decision must be approved' "$app" \
  "$sync" apply --plan "$plan" --approval "$work/approval-rejected.json" --app-root "$app" --work-dir "$work/cache"
cp -R "$work/plan" "$work/plan-edited"
printf '%s\n' '- 追加: `docs/extra.md`' >>"$work/plan-edited/plan.md"
expect_failure approve-edited-markdown 'plan.md does not match plan.json' \
  "$sync" approve --plan "$work/plan-edited/plan.json" --approver user --reference "$comment_url" --output "$work/approval-markdown.json"
# A hand-edited plan, with plan.md rendered from it as the report would.
ruby -r"$template/tools/lib/template-sync.rb" -e '
  plan = JSON.parse(File.read(ARGV[0]))
  plan["files"].find { |file| file["path"] == "docs/AUTHORITY.md" }["action"] = "update"
  File.write(ARGV[0], TemplateSync.canonical_json(plan))
  File.write(ARGV[1], TemplateSync.render_markdown(plan))
' "$work/plan-edited/plan.json" "$work/plan-edited/plan.md"
expect_untouched apply-changed-plan 'the plan changed after it was approved' "$app" \
  "$sync" apply --plan "$work/plan-edited/plan.json" --approval "$work/approval.json" --app-root "$app" --work-dir "$work/cache"
expect_untouched apply-on-main 'never on main' "$app" \
  "$sync" apply --plan "$plan" --approval "$work/approval.json" --app-root "$app" --work-dir "$work/cache"
git -C "$app" checkout -q -b template-sync/7
# Even an approval of the edited plan cannot make the tool write what the report did not decide.
"$sync" approve --plan "$work/plan-edited/plan.json" --approver user --reference "$comment_url" --output "$work/approval-edited.json" >/dev/null
expect_untouched apply-edited-plan-approved 'the plan no longer matches the template and the target' "$app" \
  "$sync" apply --plan "$work/plan-edited/plan.json" --approval "$work/approval-edited.json" --app-root "$app" --work-dir "$work/cache"
printf '%s\n' 'draft' >"$app/docs/draft.md"
expect_untouched apply-untracked-change 'the target has uncommitted changes' "$app" \
  "$sync" apply --plan "$plan" --approval "$work/approval.json" --app-root "$app" --work-dir "$work/cache"
rm "$app/docs/draft.md"
printf '%s\n' 'edit' >>"$app/docs/references.md"
expect_untouched apply-modified-file 'the target has uncommitted changes' "$app" \
  "$sync" apply --plan "$plan" --approval "$work/approval.json" --app-root "$app" --work-dir "$work/cache"
git -C "$app" checkout -q -- docs/references.md
cp "$work/approval.json" "$app/.git/approval.json"
expect_untouched apply-approval-inside-app 'the plan and the approval must be outside the app repository' "$app" \
  "$sync" apply --plan "$plan" --approval "$app/.git/approval.json" --app-root "$app" --work-dir "$work/cache"
rm "$app/.git/approval.json"

# AC-4: the Codex route runs only with the user's request, through the fixed read-only launcher.
fake_bin="$work/fake-bin"
mkdir -p "$fake_bin" "$work/fake-codex-home"
"${CC:-cc}" -Wall -Werror "$repo_root/tools/tests/fixtures/cross-model-review/codex-native.c" -o "$fake_bin/codex"
cp "$repo_root/tools/tests/fixtures/template-sync/codex" "$fake_bin/codex-fixture"
chmod +x "$fake_bin/codex-fixture"
export CODEX_HOME="$work/fake-codex-home"
expect_failure codex-without-user-request 'missing options: --user-request' \
  env PATH="$fake_bin:$PATH" "$sync" codex-review --plan "$plan" --output "$work/codex-none.json"
printf '%s\n' '{"verdict":"changes-requested","summary":"確認が必要です。","findings":[{"path":"docs/AUTHORITY.md","problem":"衝突を確認してください。"}]}' \
  >"$fake_bin/codex-answer.json"
PATH="$fake_bin:$PATH" "$sync" codex-review --plan "$plan" --user-request "$codex_url" --output "$work/codex-changes.json" --now 2026-10-05T02:10:00Z >"$work/codex-changes.out"
grep -Fq '"verdict":"changes-requested"' "$work/codex-changes.out" || { echo 'Codex changes-requested not reported' >&2; exit 1; }
grep -Fxq 'gpt-6-sol' "$fake_bin/codex-arguments" || { echo 'Codex did not run with the fixed model' >&2; exit 1; }
grep -Fxq 'permissions.reviewer.network={enabled=false}' "$fake_bin/codex-arguments" || { echo 'Codex network not disabled' >&2; exit 1; }
expect_failure approve-codex-changes 'Codex asked for changes, so the plan is not approved' \
  "$sync" approve --plan "$plan" --approver codex --review "$work/codex-changes.json" --output "$work/approval-codex-changes.json"
printf '%s\n' '{"verdict":"approved","summary":"問題はありません。","findings":[{"path":"docs/AUTHORITY.md","problem":"x"}]}' >"$fake_bin/codex-answer.json"
expect_failure codex-approved-with-findings 'an approved Codex review must have no findings' \
  env PATH="$fake_bin:$PATH" "$sync" codex-review --plan "$plan" --user-request "$codex_url" --output "$work/codex-bad.json"
[[ ! -e "$work/codex-bad.json" ]] || { echo 'an invalid Codex answer was recorded' >&2; exit 1; }
printf '%s\n' '{"verdict":"approved","summary":"問題はありません。","findings":[]}' >"$fake_bin/codex-answer.json"
PATH="$fake_bin:$PATH" "$sync" codex-review --plan "$plan" --user-request "$codex_url" --output "$work/codex-review.json" --now 2026-10-05T02:20:00Z >/dev/null
expect_failure approve-codex-with-reference 'do not pass --reference' \
  "$sync" approve --plan "$plan" --approver codex --review "$work/codex-review.json" --reference "$comment_url" --output "$work/approval-codex-ref.json"
expect_failure approve-codex-other-plan 'the Codex review is for another plan' \
  "$sync" approve --plan "$work/plan-edited/plan.json" --approver codex --review "$work/codex-review.json" --output "$work/approval-codex-other.json"
"$sync" approve --plan "$plan" --approver codex --review "$work/codex-review.json" --output "$work/approval-codex.json" --now 2026-10-05T02:30:00Z >/dev/null
# The Codex review alone is not an approval of anything.
expect_untouched apply-with-codex-review 'approval keys differ' "$app" \
  "$sync" apply --plan "$plan" --approval "$work/codex-review.json" --app-root "$app" --work-dir "$work/cache"
REVIEW="$work/codex-review.json" APPROVAL="$work/approval-codex.json" URL="$codex_url" ruby -rjson -e '
  review = JSON.parse(File.read(ENV.fetch("REVIEW")))
  approval = JSON.parse(File.read(ENV.fetch("APPROVAL")))
  abort "Codex review: #{review}" unless review.values_at("reviewer", "model", "verdict", "userRequest", "scope") == ["codex", "gpt-6-sol", "approved", ENV.fetch("URL"), "template-sync-plan"]
  abort "Codex approval: #{approval}" unless approval.values_at("approver", "reference", "scope") == ["codex", ENV.fetch("URL"), "template-sync-plan"] && approval["codexReview"] == review
'

# AC-5: apply the approved plan (Codex route) and check every kind of file.
before_authority=$(shasum -a 256 "$app/docs/AUTHORITY.md")
before_references=$(shasum -a 256 "$app/docs/references.md")
before_security=$(shasum -a 256 "$app/docs/security.md")
before_product=$(shasum -a 256 "$app/specs/product.md")
before_agents=$(shasum -a 256 "$app/AGENTS.md")
before_plans=$(shasum -a 256 "$app/docs/superpowers/plans/README.md")
before_simulators=$(shasum -a 256 "$app/Config/dedicated-simulators.json")
cp "$app/specs/decisions.md" "$work/decisions-before.md"
"$sync" apply --plan "$plan" --approval "$work/approval-codex.json" --app-root "$app" --work-dir "$work/cache" --now 2026-10-05T03:00:00Z >"$work/apply.json"
for pair in "$before_authority" "$before_references" "$before_security" "$before_product" "$before_agents" "$before_plans" "$before_simulators"; do
  (cd "$work" && printf '%s\n' "$pair" | shasum -a 256 -c --status) || { echo "a file that must stay was changed: $pair" >&2; exit 1; }
done
cmp -s "$template/docs/workflow.md" "$app/docs/workflow.md" || { echo 'safe update not applied' >&2; exit 1; }
cmp -s "$template/docs/new-guide.md" "$app/docs/new-guide.md" || { echo 'missing file not added' >&2; exit 1; }
[[ -L "$app/docs/new-guide-link.md" && "$(readlink "$app/docs/new-guide-link.md")" == new-guide.md ]] || { echo 'symlink not added' >&2; exit 1; }
[[ ! -e "$app/docs/goldie.md" ]] || { echo 'template deletion not applied' >&2; exit 1; }
[[ -x "$app/tools/lib/bounded-command.rb" ]] || { echo 'mode update not applied' >&2; exit 1; }
tail -n 1 "$app/docs/README.md" | grep -Fxq '同期testの追記。' || { echo 'transformed update not applied' >&2; exit 1; }
! grep -Fq 'TemplateApp' "$app/docs/README.md" || { echo 'the transformed README has the template name' >&2; exit 1; }
cmp -s "$work/decisions-before.md" <(head -c "$(wc -c <"$work/decisions-before.md")" "$app/specs/decisions.md") || { echo 'earlier decisions changed' >&2; exit 1; }
tail -n 4 "$app/specs/decisions.md" | head -n 1 | grep -Fxq "## $next_decision: テンプレートの新しい決定" || { echo 'decision not appended at the end' >&2; tail -n 6 "$app/specs/decisions.md" >&2; exit 1; }
APPLY="$work/apply.json" NEW="$new" NEXT_DECISION="$next_decision" APP="$app" ruby -rjson -e '
  result = JSON.parse(File.read(ENV.fetch("APPLY")))
  abort "apply status: #{result}" unless result["status"] == "applied" && result["approver"] == "codex"
  written = %w[docs/README.md docs/new-guide-link.md docs/new-guide.md docs/workflow.md specs/decisions.md tools/lib/bounded-command.rb]
  abort "written: #{result["written"]}" unless result["written"] == written
  abort "deleted: #{result["deleted"]}" unless result["deleted"] == ["docs/goldie.md"]
  abort "decisions: #{result["decisionsAppended"]}" unless result["decisionsAppended"] == [ENV.fetch("NEXT_DECISION")]
  abort "manual: #{result["manual"]}" unless (%w[docs/AUTHORITY.md docs/security.md specs/decisions.md] - result["manual"]).empty?
  abort "simulators: #{result["simulators"]}" unless result["simulators"].length == 2 && result["simulators"].all? { |name| name.start_with?("Garden Notes ") }
  base = JSON.parse(File.read(File.join(ENV.fetch("APP"), "Config/template-base.json")))
  expected = {"baseCommit" => ENV.fetch("NEW"), "method" => "created", "recordedAt" => "2026-10-05T03:00:00Z",
              "schemaVersion" => 1, "templateRepository" => "yuto1201/iOS-Template"}
  abort "base record: #{base}" unless base == expected && result["baseRecord"] == expected
'
[[ "$(git -C "$app" diff --cached --name-only)" == '' ]] || { echo 'apply changed the index' >&2; exit 1; }

# The checks after writing: a transformed file that gained template names fails, and a target
# without a valid base record is recorded as adopted.
unit="$work/unit"
mkdir -p "$unit/Config" "$unit/docs"
cp "$app/Config/dedicated-simulators.json" "$unit/Config/"
printf '%s\n' 'TemplateApp' >"$unit/docs/guide.md"
UNIT="$unit" ruby -r"$template/tools/lib/template-sync.rb" -e '
  unit = ENV.fetch("UNIT")
  plan = {"app" => {"identity" => {"displayName" => "Garden Notes"}}, "base" => {"status" => "invalid"},
          "template" => {"commit" => "0" * 40, "repository" => "yuto1201/iOS-Template"}, "files" => []}
  tokens = %w[TemplateApp com.yuto.TemplateApp]
  change = ->(text) { [{path: "docs/guide.md", action: "update", entry: TemplateSync::Entry.new("100644", text.b), transform: true, allowed: 1}] }
  begin
    TemplateSync.write_changes(unit, plan, change.call("TemplateApp com.yuto.TemplateApp\n"), tokens, "2026-10-05T04:00:00Z")
    abort "a transformed file with more template names was accepted"
  rescue TemplateSync::Failure => error
    abort "unexpected: #{error.message}" unless error.message.include?("still has the template")
  end
  result = TemplateSync.write_changes(unit, plan, change.call("GardenNotes TemplateApp\n"), tokens, "2026-10-05T04:00:00Z")
  abort "base record: #{result["baseRecord"]}" unless result["baseRecord"]["method"] == "adopted"
'

# --- a decision-number collision stops the whole apply ---------------------------------------
collide="$work/app-collide"
make_app "$collide"
printf '%s\n' '' "## $next_decision: アプリ固有の決定" '' '- Status: 確定' >>"$collide/specs/decisions.md"
commit_all "$collide" collision
git -C "$collide" checkout -q -b template-sync/8
report "$collide" "$work/plan-collide"
"$sync" approve --plan "$work/plan-collide/plan.json" --approver user --reference "$comment_url" --output "$work/approval-collide.json" >/dev/null
grep -Fq -- '## 追記する決定事項' "$work/plan-collide/plan.md" || { echo 'plan.md lacks the decision section' >&2; exit 1; }
expect_untouched apply-decision-collision 'A-### in specs/app-decisions.md' "$collide" \
  "$sync" apply --plan "$work/plan-collide/plan.json" --approval "$work/approval-collide.json" --app-root "$collide" --work-dir "$work/cache"

# --- a declaration that points at the template's Simulators stops the apply ------------------
devices="$work/app-devices"
make_app "$devices"
ruby -rjson -e '
  path = ARGV[0]
  value = JSON.parse(File.read(path))
  value["devices"].each { |device| device["name"] = device["name"].sub("Garden Notes ", "iOS-Template ") }
  File.write(path, JSON.pretty_generate(value) + "\n")
' "$devices/Config/dedicated-simulators.json"
commit_all "$devices" template-devices
git -C "$devices" checkout -q -b template-sync/9
report "$devices" "$work/plan-devices"
"$sync" approve --plan "$work/plan-devices/plan.json" --approver user --reference "$comment_url" --output "$work/approval-devices.json" >/dev/null
expect_untouched apply-template-devices 'テンプレート用の端末' "$devices" \
  "$sync" apply --plan "$work/plan-devices/plan.json" --approval "$work/approval-devices.json" --app-root "$devices" --work-dir "$work/cache"

# --- an ignored file where the plan adds one is not overwritten; a target that moved stops ---
ignored="$work/app-ignored"
make_app "$ignored"
printf '%s\n' 'docs/new-guide.md' >>"$ignored/.gitignore"
commit_all "$ignored" ignore-guide
git -C "$ignored" checkout -q -b template-sync/10
printf '%s\n' 'local notes' >"$ignored/docs/new-guide.md"
report "$ignored" "$work/plan-ignored"
"$sync" approve --plan "$work/plan-ignored/plan.json" --approver user --reference "$comment_url" --output "$work/approval-ignored.json" >/dev/null
expect_untouched apply-ignored-file 'docs/new-guide.md already exists in the working tree' "$ignored" \
  "$sync" apply --plan "$work/plan-ignored/plan.json" --approval "$work/approval-ignored.json" --app-root "$ignored" --work-dir "$work/cache"
printf '%s\n' 'later' >>"$ignored/docs/references.md"
commit_all "$ignored" later
expect_untouched apply-target-moved 'the target moved since the plan was made' "$ignored" \
  "$sync" apply --plan "$work/plan-ignored/plan.json" --approval "$work/approval-ignored.json" --app-root "$ignored" --work-dir "$work/cache"

echo "template sync apply tests passed"
