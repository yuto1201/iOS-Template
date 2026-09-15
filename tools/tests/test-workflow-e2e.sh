#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby swift /usr/bin/ruby /usr/bin/swiftc

[[ $# == 0 || ( $# == 1 && "$1" == scoped ) ]] || exit 64
scope="${1:-full}"
source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-workflow-e2e.XXXXXX")
cleanup_fixture() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    if [[ -n "${issue_worktree:-}" && -d "${issue_worktree:-}" ]]; then
      echo 'workflow E2E worktree status at failure:' >&2
      git -C "$issue_worktree" status --short --untracked-files=all >&2 || true
    fi
    [[ ! -f "${operation_log:-}" ]] || tail -n 30 "$operation_log" >&2
  fi
  rm -rf "$workspace"
  exit "$status"
}
trap cleanup_fixture EXIT

repository='yuto1201/iOS-Template'
issue=42
pr=77
remote="$workspace/remote.git"
seed="$workspace/seed"
primary="$workspace/primary"
fake_bin="$workspace/bin"
fake_state="$workspace/provider-state"
labels_file="$fake_state/labels.json"
comments_file="$fake_state/comments.json"
issue_body_file="$fake_state/issue-body.md"
issue_status_file="$fake_state/issue-status"
pr_state_file="$fake_state/pr-state"
pr_head_file="$fake_state/pr-head"
operation_log="$workspace/operations.log"
date_counter="$workspace/date-counter"
tracked_archive="$workspace/tracked-files.tar"
declared_origin="https://github.com/$repository.git"
real_git=$(command -v git)
host_path=$PATH

fail() { echo "workflow E2E failed: $*" >&2; exit 1; }
assert_json() { ruby -rjson -e "$2" "$1"; }
assert_fails() {
  local label=$1; shift
  if "$@" >"$workspace/$label.stdout" 2>"$workspace/$label.stderr"; then
    fail "$label unexpectedly succeeded"
  fi
}
line_number() {
  local pattern=$1
  (rg -n -F -- "$pattern" "$operation_log" | head -n 1 | cut -d: -f1) || true
}

mkdir -p "$seed" "$fake_bin" "$fake_state"
(cd "$source_root" && git ls-files -z | tar --null -T - -cf "$tracked_archive")
(cd "$seed" && tar -xf "$tracked_archive")
rm -f "$tracked_archive"
git -C "$seed" init -q -b main
git -C "$seed" config user.name 'Workflow E2E Fixture'
git -C "$seed" config user.email 'workflow-e2e@example.invalid'
git -C "$seed" add .
git -C "$seed" commit -qm 'fixture base'
git init -q --bare "$remote"
git -C "$seed" remote add origin "$remote"
git -C "$seed" push -q origin main
git -C "$remote" symbolic-ref HEAD refs/heads/main
git clone -q "$remote" "$primary"
git -C "$primary" config user.name 'Workflow E2E Fixture'
git -C "$primary" config user.email 'workflow-e2e@example.invalid'
git -C "$primary" remote set-url origin "$declared_origin"

# A sibling branch/worktree is user-owned fixture state. Issue cleanup must not
# broaden its target beyond the exact durable Issue identity.
git -C "$primary" branch unrelated-preserved main
mkdir -p "$primary/.worktrees"
git -C "$primary" worktree add -q "$primary/.worktrees/unrelated-preserved" unrelated-preserved
printf 'preserve me\n' >"$primary/.worktrees/unrelated-preserved/user-owned-untracked.txt"

cat >"$issue_body_file" <<'BODY'
## Goal

Exercise the complete documentation-only Issue shipping workflow.

## In scope

- Validate the public Issue automation CLIs against an isolated local fixture.

## Out of scope

- Run an application build or Simulator verification.

## Acceptance criteria

- AC-1: UI-direction route: not-applicable; Scope: documentation-only workflow fixture; Reason: the fixture changes no product UI; the exact Head is verified and reviewed.
- AC-2: Merge and cleanup preserve unrelated Branch and worktree state.

## Spec anchors

- [Issue workflow](specs/acceptance.md#2-issue-definition-of-ready)

## Dependencies

- None.

## UI verification

Not applicable

## Delivery stage

- Stage: harden
- Time budget: 120 minutes
- Reason: Exercise one documentation workflow without claiming release readiness.

## Delivery profile

- Profile: strict
- Reason: The fixture intentionally exercises the formal review and premerge path.

## External operations

- Operation: github.read_issue
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no
- Operation: github.update_issue
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no
- Operation: github.push_branch
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no
- Operation: github.create_pr
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no
- Operation: github.merge_pr
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no
- Operation: github.delete_branch
- Service: GitHub
- Environment: production
- Executor: Codex
- Approval required: no

## User approvals

- No additional approval.
BODY
printf '%s' '["state:approved","type:feature"]' >"$labels_file"
printf '%s' '[]' >"$comments_file"
printf '%s' 'OPEN' >"$issue_status_file"
printf '%s' 'NONE' >"$pr_state_file"
printf '%s' '0' >"$date_counter"

cat >"$fake_bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"${FAKE_OPERATION_LOG:?}"
if [[ "$*" == *'remote get-url origin'* ]]; then
  printf '%s\n' "${FAKE_DECLARED_ORIGIN:?}"
  exit 0
fi
exec "${REAL_GIT:?}" -c "url.${FAKE_LOCAL_REMOTE:?}.insteadOf=${FAKE_DECLARED_ORIGIN:?}" "$@"
GIT

cat >"$fake_bin/date" <<'DATE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 2 && "$1" == -u && "$2" == '+%Y-%m-%dT%H:%M:%SZ' ]]; then
  count=$(cat "${FAKE_DATE_COUNTER:?}")
  count=$((count + 1))
  printf '%s' "$count" >"$FAKE_DATE_COUNTER"
  FAKE_EPOCH=$(( ${FAKE_DATE_BASE_EPOCH:?} + count * 2 )) /usr/bin/ruby -rtime -e 'puts Time.at(Integer(ENV.fetch("FAKE_EPOCH"))).utc.iso8601'
  exit 0
fi
exec /bin/date "$@"
DATE

cat >"$fake_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"${FAKE_OPERATION_LOG:?}"

field_after() {
  local name=$1 index
  shift
  for ((index=1; index <= $#; index++)); do
    if [[ "${!index}" == "$name" ]]; then
      index=$((index + 1)); printf '%s\n' "${!index}"; return 0
    fi
  done
  return 1
}

case "${1:-} ${2:-}" in
  'auth status')
    printf 'Logged in to github.com account yuto1201 (keychain)\n  - Active account: true\n'
    ;;
  'repo view')
    printf '%s\n' '{"nameWithOwner":"yuto1201/iOS-Template","defaultBranchRef":{"name":"main"},"url":"https://github.com/yuto1201/iOS-Template"}'
    ;;
  'issue view')
    fields=$(field_after --json "$@")
    FIELDS="$fields" /usr/bin/ruby -rjson -e '
      labels = JSON.parse(File.binread(ENV.fetch("FAKE_LABELS_FILE"))).map { |name| {"name" => name} }
      all = {
        "title" => "Documentation workflow E2E", "body" => File.binread(ENV.fetch("FAKE_ISSUE_BODY")),
        "labels" => labels, "comments" => JSON.parse(File.binread(ENV.fetch("FAKE_COMMENTS_FILE"))).map { |comment| value=comment.dup; value["author"] ||= {"login"=>"yuto1201"}; value["createdAt"] ||= value.fetch("body", "")[/"timestamp":"([^"]+)"/, 1] || "2026-08-24T00:00:00Z"; value },
        "number" => Integer(ENV.fetch("FAKE_ISSUE")), "state" => File.binread(ENV.fetch("FAKE_ISSUE_STATUS")),
        "url" => "https://github.com/#{ENV.fetch("FAKE_REPOSITORY")}/issues/#{ENV.fetch("FAKE_ISSUE")}"
      }
      requested = ENV.fetch("FIELDS").split(",")
      abort "unsupported issue fields" unless (requested - all.keys).empty?
      puts JSON.generate(requested.to_h { |key| [key, all.fetch(key)] })
    '
    ;;
  'issue edit')
    remove=$(field_after --remove-label "$@")
    add=$(field_after --add-label "$@")
    /usr/bin/ruby -rjson -e 'path, remove, add = ARGV; labels = JSON.parse(File.binread(path)); labels.delete(remove); labels << add unless labels.include?(add); File.binwrite(path, JSON.generate(labels))' "$FAKE_LABELS_FILE" "$remove" "$add"
    ;;
  'issue comment')
    body=$(field_after --body "$@")
    /usr/bin/ruby -rjson -e 'path, body = ARGV; timestamp=body[/"timestamp":"([^"]+)"/, 1] || "2026-08-24T00:00:00Z"; comments = JSON.parse(File.binread(path)); comments << {"body" => body, "author"=>{"login"=>"yuto1201"}, "createdAt"=>timestamp}; File.binwrite(path, JSON.generate(comments))' "$FAKE_COMMENTS_FILE" "$body"
    ;;
  'pr list')
    if [[ "$(cat "$FAKE_PR_STATE")" == NONE ]]; then
      printf '[]\n'
    else
      pr_value=$("$0" pr view "$FAKE_PR" --repo "$FAKE_REPOSITORY" --json number,state,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,closingIssuesReferences,mergeCommit,url)
      PR_VALUE="$pr_value" /usr/bin/ruby -rjson -e 'puts JSON.generate([JSON.parse(ENV.fetch("PR_VALUE"))])'
    fi
    ;;
  'pr create')
    [[ "$(field_after --base "$@")" == main ]] || exit 2
    [[ "$(field_after --head "$@")" == "${FAKE_BRANCH:?}" ]] || exit 2
    "${REAL_GIT:?}" -C "${FAKE_ISSUE_WORKTREE:?}" rev-parse HEAD >"$FAKE_PR_HEAD"
    printf '%s' OPEN >"$FAKE_PR_STATE"
    printf 'https://github.com/%s/pull/%s\n' "$FAKE_REPOSITORY" "$FAKE_PR"
    ;;
  'pr view')
    fields=$(field_after --json "$@")
    FIELDS="$fields" /usr/bin/ruby -rjson -e '
      state = File.binread(ENV.fetch("FAKE_PR_STATE")); head = File.binread(ENV.fetch("FAKE_PR_HEAD")).strip
      repo = ENV.fetch("FAKE_REPOSITORY"); owner, name = repo.split("/", 2); issue = Integer(ENV.fetch("FAKE_ISSUE")); number = Integer(ENV.fetch("FAKE_PR"))
      all = {
        "number" => number, "state" => state, "baseRefName" => "main", "headRefName" => ENV.fetch("FAKE_BRANCH"),
        "headRefOid" => head, "headRepository" => {"id" => "R_fixture", "name" => name, "nameWithOwner" => repo},
        "headRepositoryOwner" => {"id" => "U_fixture", "name" => "Fixture", "login" => owner}, "isCrossRepository" => false,
        "closingIssuesReferences" => [{"id" => "I_fixture", "number" => issue, "url" => "https://github.com/#{repo}/issues/#{issue}", "repository" => {"id" => "R_fixture", "name" => name, "owner" => {"id" => "U_fixture", "login" => owner}}}],
        "mergeCommit" => state == "MERGED" ? {"oid" => "b" * 40} : nil,
        "url" => "https://github.com/#{repo}/pull/#{number}"
      }
      requested = ENV.fetch("FIELDS").split(",")
      abort "unsupported PR fields" unless (requested - all.keys).empty?
      puts JSON.generate(requested.to_h { |key| [key, all.fetch(key)] })
    '
    ;;
  'pr merge')
    [[ "${3:-}" == "$FAKE_PR" && "$(field_after --repo "$@")" == "$FAKE_REPOSITORY" ]] || exit 2
    expected=$(cat "$FAKE_PR_HEAD")
    [[ "$*" == *"--squash --match-head-commit $expected"* ]] || exit 2
    printf '%s' MERGED >"$FAKE_PR_STATE"
    printf '%s' CLOSED >"$FAKE_ISSUE_STATUS"
    ;;
  *)
    printf 'unexpected fake gh invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
GH

cat >"$fake_bin/claude" <<'CLAUDE'
#!/usr/bin/env ruby
require "digest"
require "json"
require "time"
File.open(ENV.fetch("FAKE_OPERATION_LOG"), "a") { |file| file.puts("reviewer claude") }
prompt = ARGV.last.to_s
packet_path = prompt[/Validated review packet: (.+)\z/, 1] or abort "packet path missing"
packet_bytes = File.binread(packet_path)
packet = JSON.parse(packet_bytes)
verify = JSON.parse(File.binread(File.join(File.dirname(packet_path), "verify.json")))
reviewed_at = (Time.iso8601(verify.fetch("completedAt")) + 1).utc.iso8601(3)
result = {
  "schemaVersion" => 2, "issue" => packet.fetch("issue"), "reviewerModel" => packet.fetch("reviewerModel"),
  "baseSha" => packet.fetch("baseSha"), "headSha" => packet.fetch("headSha"), "verifySha" => packet.fetch("verifySha"),
  "issueContractDigest" => packet.dig("issueContract", "digest"),
  "reviewPacketDigest" => "sha256:#{Digest::SHA256.hexdigest(packet_bytes)}", "verdict" => "approved", "findings" => [],
  "acceptanceAssessment" => packet.fetch("acceptanceCriteria").each_index.map { |index| {"id" => "AC-#{index + 1}", "status" => "supported", "evidence" => ["verify.json#acceptanceEvidence/#{index}"]} },
  "reviewedAt" => reviewed_at
}
puts JSON.generate(result)
CLAUDE

chmod +x "$fake_bin/git" "$fake_bin/date" "$fake_bin/gh" "$fake_bin/claude"
export PATH="$fake_bin:$PATH"
export REAL_GIT="$real_git"
export FAKE_OPERATION_LOG="$operation_log"
export FAKE_DECLARED_ORIGIN="$declared_origin"
export FAKE_LOCAL_REMOTE="$remote"
export FAKE_DATE_COUNTER="$date_counter"
# Keep this general shipping fixture before the repository-test-plan cutover.
# The post-cutover strict path is exercised by test-repository-test-plan.sh.
export FAKE_DATE_BASE_EPOCH=1789304100
export FAKE_LABELS_FILE="$labels_file"
export FAKE_COMMENTS_FILE="$comments_file"
export FAKE_ISSUE_BODY="$issue_body_file"
export FAKE_ISSUE_STATUS="$issue_status_file"
export FAKE_PR_STATE="$pr_state_file"
export FAKE_PR_HEAD="$pr_head_file"
export FAKE_REPOSITORY="$repository"
export FAKE_ISSUE="$issue"
export FAKE_PR="$pr"

claim_result="$workspace/claim.json"
(cd "$primary" && tools/claim-issue.sh --repo "$repository" --issue "$issue" --agent codex) >"$claim_result"
issue_worktree=$(ruby -rjson -e 'value=JSON.parse(File.binread(ARGV.fetch(0))); print File.expand_path(value.fetch("worktree"), ARGV.fetch(1))' "$claim_result" "$primary")
branch=$(ruby -rjson -e 'print JSON.parse(File.binread(ARGV.fetch(0))).fetch("branch")' "$claim_result")
base_sha=$(ruby -rjson -e 'print JSON.parse(File.binread(ARGV.fetch(0))).fetch("baseSha")' "$claim_result")
export FAKE_ISSUE_WORKTREE="$issue_worktree"
export FAKE_BRANCH="$branch"
# Only the sealed contract belongs to the pre-plan cutover fixture. Subsequent
# evidence and provider preflights must remain fresh relative to the real run.
export FAKE_DATE_BASE_EPOCH=$(( $(/bin/date +%s) + 30 ))
printf '%s' '0' >"$date_counter"

[[ -L "$issue_worktree/.artifacts" && "$(readlink "$issue_worktree/.artifacts")" == '../../.artifacts' ]] || fail 'Claim did not install the canonical shared artifact link'
[[ "$(ruby -e 'print File.realpath(ARGV.fetch(0))' "$issue_worktree/.artifacts")" == "$(ruby -e 'print File.realpath(ARGV.fetch(0))' "$primary/.artifacts")" ]] || fail 'Issue worktree does not share the primary artifact store'
[[ -z "$(git -C "$issue_worktree" status --porcelain=v1 --untracked-files=all)" ]] || fail 'canonical artifact symlink makes a newly claimed worktree dirty'
assert_json "$primary/.artifacts/issues/$issue/issue-contract.json" '
  require "digest"
  value = JSON.parse(File.binread(ARGV.fetch(0)))
  operations = %w[github.read_issue github.update_issue github.push_branch github.create_pr github.merge_pr github.delete_branch]
  abort unless value.fetch("externalOperations") == operations
  details = operations.map { |operation| {"operation"=>operation,"service"=>"GitHub","environment"=>"production","executor"=>"Codex","approvalRequired"=>false,"approvalReference"=>nil} }
  canonical = ->(item) { item.is_a?(Hash) ? item.keys.sort.to_h { |key| [key, canonical.call(item.fetch(key))] } : item.is_a?(Array) ? item.map { |entry| canonical.call(entry) } : item }
  expected = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical.call(details)))}"
  abort unless value.fetch("externalOperationDetailsDigest") == expected
'
mkdir -p "$issue_worktree/docs/nested"
printf 'nested artifact name\n' >"$issue_worktree/docs/nested/.artifacts"
if git -C "$issue_worktree" check-ignore -q docs/nested/.artifacts; then
  fail 'root artifact ignore rule hides a nested user file'
fi
rm "$issue_worktree/docs/nested/.artifacts"
rmdir "$issue_worktree/docs/nested"

# Claiming the already-claimed Issue as the same agent exercises the public
# resume path; it must not create a second Branch or worktree.
(cd "$primary" && tools/claim-issue.sh --repo "$repository" --issue "$issue" --agent codex) >"$workspace/resume.json"
cmp -s "$claim_result" "$workspace/resume.json" || fail 'same-agent Resume changed the durable claim identity'

(cd "$issue_worktree" && tools/issue-state.sh transition --repo "$repository" --issue "$issue" --from claimed --to in-progress) >/dev/null
cat >"$issue_worktree/docs/workflow-e2e-fixture.md" <<'DOC'
# Workflow E2E fixture

This documentation-only change represents both acceptance criteria in the isolated shipping test.
DOC
git -C "$issue_worktree" add docs/workflow-e2e-fixture.md
git -C "$issue_worktree" commit -qm 'docs: add workflow fixture head one'
head_one=$(git -C "$issue_worktree" rev-parse HEAD)

write_documentation_input() {
  cat >"$primary/.artifacts/issues/$issue/documentation-evidence-input.json" <<'JSON'
{
  "schemaVersion": 1,
  "reason": "Only allowlisted Markdown documentation changed",
  "acceptanceEvidence": [
    {"id": "AC-1", "evidence": ["documents:docs/workflow-e2e-fixture.md"]},
    {"id": "AC-2", "evidence": ["links:docs/workflow.md"]}
  ]
}
JSON
}

publish_and_review() {
  local head=$1
  write_documentation_input
  (cd "$issue_worktree" && tools/publish-documentation-verify.sh --issue "$issue" --expected-base "$base_sha" --expected-head "$head" --input ".artifacts/issues/$issue/documentation-evidence-input.json") >/dev/null
  (cd "$issue_worktree" && tools/issue-state.sh transition --repo "$repository" --issue "$issue" --from in-progress --to verify-passed --head-sha "$head") >/dev/null
  (cd "$issue_worktree" && tools/prepare-review-packet.sh --primary codex --issue "$issue" --base-sha "$base_sha" --head-sha "$head") >/dev/null
  (cd "$issue_worktree" && tools/issue-state.sh transition --repo "$repository" --issue "$issue" --from verify-passed --to review-requested) >/dev/null
  (cd "$issue_worktree" && tools/cross-model-review.sh --primary codex --packet ".artifacts/issues/$issue/$head/review-packet.json" --output ".artifacts/issues/$issue/$head/review.json") >/dev/null
}

publish_and_review "$head_one"
(cd "$issue_worktree" && tools/github-account-preflight.sh --repo "$repository" --issue "$issue" --intended-operation github.merge_pr --expected-head "$head_one") >/dev/null
(cd "$issue_worktree" && tools/premerge-gate.sh --repo "$repository" --issue "$issue" --head-sha "$head_one") >/dev/null
(cd "$issue_worktree" && tools/render-pr-body.sh --issue "$issue" --head-sha "$head_one") >"$workspace/head-one-pr.md"
rg -Fq 'Closes #42' "$workspace/head-one-pr.md" || fail 'renderer omitted the exact closing Issue'

if [[ "$scope" == scoped ]]; then
  echo 'PASS: scoped public-CLI Claim/Resume, exact-Head Verify/Review, and premerge workflow'
  exit 0
fi

# A new commit is legal only after returning to in-progress. That transition
# drops the old durable Head, so neither the old approved closure nor a new
# Verify without a new review can pass the merge Gate.
(cd "$issue_worktree" && tools/issue-state.sh transition --repo "$repository" --issue "$issue" --from approved-for-merge --to in-progress) >/dev/null
jq -e 'has("headSha") | not' "$primary/.artifacts/issues/$issue/state.json" >/dev/null || fail 'return to in-progress retained the stale durable Head'
printf '\nSecond exact-Head revision.\n' >>"$issue_worktree/docs/workflow-e2e-fixture.md"
git -C "$issue_worktree" add docs/workflow-e2e-fixture.md
git -C "$issue_worktree" commit -qm 'docs: add workflow fixture head two'
head_two=$(git -C "$issue_worktree" rev-parse HEAD)
[[ "$head_two" != "$head_one" ]] || fail 'stale-review fixture did not change Head'

assert_fails stale-gate-before-verify bash -c "cd '$issue_worktree' && tools/premerge-gate.sh --repo '$repository' --issue '$issue' --head-sha '$head_two'"
write_documentation_input
(cd "$issue_worktree" && tools/publish-documentation-verify.sh --issue "$issue" --expected-base "$base_sha" --expected-head "$head_two" --input ".artifacts/issues/$issue/documentation-evidence-input.json") >/dev/null
(cd "$issue_worktree" && tools/issue-state.sh transition --repo "$repository" --issue "$issue" --from in-progress --to verify-passed --head-sha "$head_two") >/dev/null
assert_fails stale-gate-after-verify bash -c "cd '$issue_worktree' && tools/premerge-gate.sh --repo '$repository' --issue '$issue' --head-sha '$head_two'"
(cd "$issue_worktree" && tools/issue-state.sh transition --repo "$repository" --issue "$issue" --from verify-passed --to review-requested) >/dev/null
assert_fails stale-head-one-packet bash -c "cd '$issue_worktree' && tools/cross-model-review.sh --primary codex --packet '.artifacts/issues/$issue/$head_one/review-packet.json' --output '.artifacts/issues/$issue/$head_one/review.json'"

(cd "$issue_worktree" && tools/prepare-review-packet.sh --primary codex --issue "$issue" --base-sha "$base_sha" --head-sha "$head_two") >/dev/null
(cd "$issue_worktree" && tools/cross-model-review.sh --primary codex --packet ".artifacts/issues/$issue/$head_two/review-packet.json" --output ".artifacts/issues/$issue/$head_two/review.json") >/dev/null
(cd "$issue_worktree" && tools/github-account-preflight.sh --repo "$repository" --issue "$issue" --intended-operation github.merge_pr --expected-head "$head_two") >/dev/null
(cd "$issue_worktree" && tools/premerge-gate.sh --repo "$repository" --issue "$issue" --head-sha "$head_two") >/dev/null
(cd "$issue_worktree" && tools/render-pr-body.sh --issue "$issue" --head-sha "$head_two") >"$workspace/head-two-pr.md"

(cd "$issue_worktree" && tools/merge-issue.sh --repo "$repository" --issue "$issue") >"$workspace/merge.json"
HEAD_TWO="$head_two" assert_json "$workspace/merge.json" 'value=JSON.parse(File.binread(ARGV.fetch(0))); abort unless value == {"status"=>"merged","issue"=>42,"pullRequest"=>77,"headSha"=>ENV.fetch("HEAD_TWO")}'

(cd "$primary" && tools/cleanup-issue.sh --repo "$repository" --issue "$issue") >"$workspace/cleanup.json"
[[ ! -e "$issue_worktree" ]] || fail 'cleanup retained the exact Issue worktree'
git -C "$primary" show-ref --verify --quiet refs/heads/unrelated-preserved || fail 'cleanup deleted an unrelated Branch'
[[ -d "$primary/.worktrees/unrelated-preserved" && -f "$primary/.worktrees/unrelated-preserved/user-owned-untracked.txt" ]] || fail 'cleanup changed an unrelated worktree'
(cd "$primary" && tools/issue-state.sh transition --repo "$repository" --issue "$issue" --from merged --to done) >/dev/null
assert_json "$labels_file" 'abort unless JSON.parse(File.binread(ARGV.fetch(0))).sort == ["state:done", "type:feature"].sort'

push_line=$(line_number "push origin $head_two:refs/heads/$branch")
create_line=$(line_number "gh pr create --repo $repository --base main --head $branch")
merge_line=$(line_number "gh pr merge $pr --repo $repository --squash --match-head-commit $head_two")
delete_line=$(line_number "push --force-with-lease=refs/heads/$branch:$head_two origin :refs/heads/$branch")
[[ -n "$push_line" && -n "$create_line" && -n "$merge_line" && -n "$delete_line" ]] || fail 'expected public shipping operations were not recorded'
(( push_line < create_line && create_line < merge_line && merge_line < delete_line )) || fail 'shipping operations were not ordered push, PR, merge, delete'
[[ "$(rg -c '^reviewer claude$' "$operation_log")" == 2 ]] || fail 'fresh Head did not receive its own opposite-model review'
[[ ! -e "$primary/.artifacts/issues/$issue/$head_two/iphone-en.png" ]] || fail 'docs-only E2E fabricated Simulator evidence'

echo 'PASS: public-CLI Claim/Resume, exact-Head Verify/Review recovery, Gate, Squash Merge, cleanup, and done workflow'

# Claim an application Issue in a separate primary/provider state so Issue 42's
# completed documentation workflow and its unrelated worktree remain intact.
application_primary="$workspace/application-primary"
application_state="$workspace/application-provider-state"
mkdir -p "$application_state"
git clone -q "$remote" "$application_primary"
git -C "$application_primary" config user.name 'Workflow E2E Fixture'
git -C "$application_primary" config user.email 'workflow-e2e@example.invalid'
git -C "$application_primary" remote set-url origin "$declared_origin"
cat >"$application_state/issue-body.md" <<'BODY'
## Goal

Exercise Claim-produced application verification contracts without changing product UI.

## In scope

- Validate application verification tooling with fake Xcode and Simulator commands.

## Out of scope

- Product UI changes and real Simulator verification.

## Acceptance criteria

- AC-1: UI-direction route: not-applicable; Scope: application verification contract fixture; Reason: this synthetic tooling test changes no product UI; build and unit tests pass.
- AC-2: Four localized cases and their visual checks are mapped.

## Spec anchors

- [Issue workflow](specs/acceptance.md#2-issue-definition-of-ready)

## Dependencies

None

## UI verification

Not applicable

## Delivery stage

- Stage: release
- Time budget: 240 minutes
- Reason: Exercise the complete application verification contract.

## Delivery profile

- Profile: strict
- Reason: Exercise the verification gate contract.

## Verification scope

- Scope: full
- Reason: Cover all four canonical cases.

## Verification

```json
{
  "bundleIdentifier": "com.example.TemplateApp",
  "unitTestIdentifier": "TemplateAppTests/UnitSmokeTests/testUnit()",
  "cases": [
    {"id": "iphone-en", "testIdentifier": "TemplateAppUITests/SmokeTests/testLaunch"},
    {"id": "iphone-ja", "assertion": {"kind": "launch-succeeded"}},
    {"id": "ipad-en", "testIdentifier": "TemplateAppUITests/SmokeTests/testLaunch"},
    {"id": "ipad-ja", "assertion": {"kind": "launch-succeeded"}}
  ],
  "acceptanceMappings": [
    {"id": "AC-1", "checks": ["stage:build", "stage:unit-tests"]},
    {"id": "AC-2", "checks": ["case:iphone-en", "case:iphone-ja", "case:ipad-en", "case:ipad-ja", "visual:iphone-en", "visual:iphone-ja", "visual:ipad-en", "visual:ipad-ja"]}
  ]
}
```

BODY
# Reuse only the fake Issue's six operation declarations and user approvals.
sed -n '/^## External operations/,$p' "$issue_body_file" >>"$application_state/issue-body.md"
printf '%s' '["state:approved","type:release"]' >"$application_state/labels.json"
printf '%s' '[]' >"$application_state/comments.json"
printf '%s' 'OPEN' >"$application_state/issue-status"
printf '%s' 'NONE' >"$application_state/pr-state"
(
  export FAKE_LABELS_FILE="$application_state/labels.json"
  export FAKE_COMMENTS_FILE="$application_state/comments.json"
  export FAKE_ISSUE_BODY="$application_state/issue-body.md"
  export FAKE_ISSUE_STATUS="$application_state/issue-status"
  export FAKE_PR_STATE="$application_state/pr-state"
  export FAKE_PR_HEAD="$application_state/pr-head"
  unset FAKE_ISSUE_WORKTREE FAKE_BRANCH
  cd "$application_primary"
  tools/claim-issue.sh --repo "$repository" --issue "$issue" --agent codex
) >"$workspace/application-claim.json"
application_contract="$application_primary/.artifacts/issues/$issue/issue-contract.json"
documentation_contract="$primary/.artifacts/issues/$issue/issue-contract.json"
jq -e '.state == "claimed" and .primaryImplementer == "codex"' "$workspace/application-claim.json" >/dev/null
jq -e 'has("verification")' "$application_contract" >/dev/null
jq -e 'has("verification") | not' "$documentation_contract" >/dev/null

# CI-capable contract coverage: the real runner executes on fake Xcode/simctl.
# Drafts here are synthetic test outputs, never real Simulator or visual evidence.
# Source the runner fixture once in a child process: both fixtures own EXIT traps
# and scratch directories, and the Swift validator only needs one compilation.
PATH="$host_path" /bin/bash -s -- "$source_root" "$application_contract" "$documentation_contract" <<'RUNNER'
set -euo pipefail
source "$1/tools/tests/lib/ios-runner-fixture.sh"

assert_claimed_contract() {
  local label=$1 input=$2 expected=$3 result=0
  prepare_repo "$label" "external:$input" present full || return 1
  cmp -s "$input" "$contract" || { echo "$label: Claim contract bytes changed before runner" >&2; return 1; }
  run_execute >"$scratch/$label.stdout" 2>"$scratch/$label.stderr" || result=$?
  cmp -s "$input" "$contract" || { echo "$label: runner changed Claim contract bytes" >&2; return 1; }
  if [[ "$expected" == draft ]]; then
    if [[ "$result" -ne 0 || ! -f "$draft" || -e "$final" ]]; then
      cat "$scratch/$label.stderr" >&2
      echo "$label: Claim-produced application contract did not publish only a draft (exit $result)" >&2
      return 1
    fi
    /usr/bin/ruby -rjson -rdigest - "$draft" "$input" "$head_sha" <<'RUBY' || return 1
draft_path, input, head = ARGV
value = JSON.parse(File.binread(draft_path))
abort "wrong draft identity/status" unless value.fetch("issue") == 42 && value.fetch("headSha") == head && value.fetch("status") == "awaiting-visual-review"
abort "draft lost Claim contract identity" unless value.fetch("issueContract") == {
  "path" => ".artifacts/issues/42/issue-contract.json",
  "digest" => "sha256:#{Digest::SHA256.file(input).hexdigest}"
}
abort "draft omitted application cases" unless value.fetch("cases").map { |entry| entry.fetch("id") } == %w[iphone-en iphone-ja ipad-en ipad-ja]
RUBY
    grep -q '^xcodebuild' "$fake_log" || { echo "$label: runner never called fake Xcode" >&2; return 1; }
  else
    [[ "$result" -ne 0 && ! -e "$draft" && ! -e "$final" ]] || { echo "$label: absent verification was accepted" >&2; return 1; }
    grep -Fq 'verification contract is absent or incomplete' "$scratch/$label.stderr" || {
      cat "$scratch/$label.stderr" >&2
      echo "$label: runner did not report absent verification" >&2
      return 1
    }
    if grep -q '^xcodebuild' "$fake_log"; then
      echo "$label: absent verification reached Xcode" >&2
      return 1
    fi
  fi
  echo "PASS: $label Claim contract through application runner ($expected)"
}

failures=0
assert_claimed_contract AC-1 "$2" draft || failures=$((failures + 1))
assert_claimed_contract AC-2 "$3" rejected || failures=$((failures + 1))
[[ "$failures" == 0 ]]
RUNNER
