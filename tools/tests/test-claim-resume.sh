#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-claim-resume.XXXXXX")
trap 'rm -rf "$workspace"' EXIT

remote="$workspace/remote.git"
seed="$workspace/seed"
clone="$workspace/local"
fake_bin="$workspace/bin"
labels_file="$workspace/labels.json"
comments_file="$workspace/comments.json"
issue_body_file="$workspace/issue-body.md"
gh_log="$workspace/gh.log"

assert_fails() {
  local message=$1
  shift
  if "$@" >"$workspace/output" 2>&1; then
    echo "expected failure: $message" >&2
    exit 1
  fi
}

assert_json() {
  local document=$1 code=$2
  ruby -rjson -e "$code" "$document"
}

git init --bare "$remote" >/dev/null
git init -b main "$seed" >/dev/null
git -C "$seed" config user.name 'Claim Fixture'
git -C "$seed" config user.email 'claim-fixture@example.invalid'
printf 'fixture README\n' > "$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" commit -m 'fixture base' >/dev/null
git -C "$seed" push "$remote" main >/dev/null
git clone "$remote" "$clone" >/dev/null
git -C "$clone" config user.name 'Claim Fixture'
git -C "$clone" config user.email 'claim-fixture@example.invalid'

# The temporary clone is the only repository the tools may mutate. Copying
# uncommitted source tools lets this test exercise the current implementation.
cp -R "$repo_root/tools" "$clone/"
cp -R "$repo_root/.agents" "$clone/"
cp -R "$repo_root/Config" "$clone/"
cp -R "$repo_root/specs" "$clone/"
cp "$repo_root/.gitignore" "$clone/.gitignore"

mkdir -p "$fake_bin"
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"

case "${1:-} ${2:-}" in
  'auth status')
    login=${FAKE_GH_LOGIN:-yuto1201}
    if [[ -n "${FAKE_GH_LOGIN_AFTER_ISSUE_READ:-}" ]] && rg -q '^issue view ' "${FAKE_GH_LOG:?}"; then login=$FAKE_GH_LOGIN_AFTER_ISSUE_READ; fi
    printf 'Logged in to github.com account %s (keychain)\n  - Active account: true\n' "$login"
    ;;
  'repo view')
    printf '%s\n' "{\"nameWithOwner\":\"${FAKE_GH_REPOSITORY:-yuto1201/iOS-Template}\",\"defaultBranchRef\":{\"name\":\"main\"},\"url\":\"https://github.com/${FAKE_GH_REPOSITORY:-yuto1201/iOS-Template}\"}"
    ;;
  'issue view')
    ruby -rjson -e 'comments = JSON.parse(File.read(ENV.fetch("FAKE_GH_COMMENTS_FILE"))).map { |comment| value=comment.dup; value["author"] ||= {"login"=>"yuto1201"}; value["createdAt"] ||= value.fetch("body", "")[/"timestamp":"([^"]+)"/, 1] || "2026-08-24T00:00:00Z"; value }; puts JSON.generate({"title" => ENV.fetch("FAKE_GH_ISSUE_TITLE", "Settings screen"), "body" => File.read(ENV.fetch("FAKE_GH_ISSUE_BODY")), "labels" => JSON.parse(File.read(ENV.fetch("FAKE_GH_LABELS_FILE"))).map { |name| {"name" => name} }, "comments" => comments})'
    ;;
  'issue edit')
    remove='' add=''
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --remove-label) remove=$2; shift 2 ;;
        --add-label) add=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    ruby -rjson -e 'path, remove, add = ARGV; labels = JSON.parse(File.read(path)); labels.delete(remove); labels << add unless labels.include?(add); File.write(path, JSON.generate(labels))' "$FAKE_GH_LABELS_FILE" "$remove" "$add"
    ;;
  'issue comment')
    body=''
    for ((index = 1; index <= $#; index += 1)); do
      if [[ "${!index}" == --body ]]; then
        next=$((index + 1)); body=${!next}; break
      fi
    done
    ruby -rjson -e 'path, body = ARGV; comments = JSON.parse(File.read(path)); timestamp=body[/"timestamp":"([^"]+)"/, 1] || "2026-08-24T00:00:00Z"; comments << {"body" => body, "author" => {"login" => "yuto1201"}, "createdAt" => timestamp}; File.write(path, JSON.generate(comments))' "$FAKE_GH_COMMENTS_FILE" "$body"
    ;;
  *)
    echo "unexpected fake gh invocation: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_bin/gh"

cat > "$issue_body_file" <<'EOF'
## Goal

Make the Settings screen deterministic.

## In scope

- Create the Settings screen workflow.

## Out of scope

- Change unrelated application screens.

## Acceptance criteria

- AC-1: The Settings screen branch is ready for implementation.
- AC-2: The Issue can resume from its durable claim marker.

## Spec anchors

- [Issue Definition of Ready](specs/acceptance.md#2-issue-definition-of-ready)

## Dependencies

- #5

## UI verification

- Not applicable.

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

- Operation: supabase.inspect_project
- Service: Supabase
- Environment: staging
- Executor: Codex
- Approval required: no

## User approvals

- None.
EOF

printf '%s' '["state:approved","type:feature"]' > "$labels_file"
printf '%s' '[]' > "$comments_file"
export PATH="$fake_bin:$PATH"
export FAKE_GH_LOG="$gh_log"
export FAKE_GH_LABELS_FILE="$labels_file"
export FAKE_GH_COMMENTS_FILE="$comments_file"
export FAKE_GH_ISSUE_BODY="$issue_body_file"

# A dirty default checkout must not be cleaned, reset, or otherwise changed.
printf 'user-owned untracked content\n' > "$clone/user-owned.txt"
printf '\nuser-owned tracked edit\n' >> "$clone/README.md"
before_status=$(git -C "$clone" status --porcelain)

claim="$clone/tools/claim-issue.sh"
resume="$clone/tools/resume-issue.sh"

# Identity and contract failures happen before Branch, worktree, sealed
# contract, durable state, label, or comment mutation.
export FAKE_GH_LOGIN=company-account
assert_fails 'Claim rejects the company GitHub account before reading the Issue' bash -c "cd '$clone' && '$claim' --repo yuto1201/iOS-Template --issue 42 --agent codex"
unset FAKE_GH_LOGIN
[[ -z "$(git -C "$clone" branch --list 'codex/42-*')" && ! -e "$clone/.worktrees/42-settings-screen" ]]

export FAKE_GH_REPOSITORY=other/iOS-Template
assert_fails 'Claim rejects a different repository before reading the Issue' bash -c "cd '$clone' && '$claim' --repo yuto1201/iOS-Template --issue 42 --agent codex"
unset FAKE_GH_REPOSITORY
[[ -z "$(git -C "$clone" branch --list 'codex/42-*')" && ! -e "$clone/.artifacts/issues/42/issue-contract.json" ]]

cp "$issue_body_file" "$workspace/issue-body.valid"
ruby -e 'path=ARGV.fetch(0); text=File.read(path); text.sub!(/- Operation: github\.read_issue\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n/, ""); File.write(path,text)' "$issue_body_file"
assert_fails 'Claim rejects a live Issue without github.read_issue' bash -c "cd '$clone' && '$claim' --repo yuto1201/iOS-Template --issue 42 --agent codex"
[[ -z "$(git -C "$clone" branch --list 'codex/42-*')" && ! -e "$clone/.artifacts/issues/42/state.json" ]]
cp "$workspace/issue-body.valid" "$issue_body_file"

export FAKE_GH_LOGIN_AFTER_ISSUE_READ=company-account
assert_fails 'Claim account change before update leaves no Branch, worktree, contract, or durable state' bash -c "cd '$clone' && '$claim' --repo yuto1201/iOS-Template --issue 42 --agent codex"
unset FAKE_GH_LOGIN_AFTER_ISSUE_READ
[[ -z "$(git -C "$clone" branch --list 'codex/42-*')" && ! -e "$clone/.worktrees/42-settings-screen" && ! -e "$clone/.artifacts/issues/42/issue-contract.json" && ! -e "$clone/.artifacts/issues/42/state.json" ]]

ruby -e 'path=ARGV.fetch(0); text=File.read(path); text.sub!(/- Operation: github\.merge_pr\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n/, ""); File.write(path,text)' "$issue_body_file"
assert_fails 'Claim rejects a non-shippable Issue before local publication' bash -c "cd '$clone' && '$claim' --repo yuto1201/iOS-Template --issue 42 --agent codex"
[[ -z "$(git -C "$clone" branch --list 'codex/42-*')" && ! -e "$clone/.artifacts/issues/42/issue-contract.json" ]]
cp "$workspace/issue-body.valid" "$issue_body_file"

claim_result="$workspace/claim.json"
# The documented shipping order inspects state before Claim. Claim must upgrade
# this exact minimal pre-Claim record instead of wedging after local publication.
(cd "$clone" && tools/issue-state.sh get --repo yuto1201/iOS-Template --issue 42) > "$workspace/preclaim-state.json"
assert_json "$clone/.artifacts/issues/42/state.json" 'value=JSON.parse(File.binread(ARGV.fetch(0))); abort unless value.keys.sort == %w[executor from resumeState state timestamp to] && value["state"] == "approved"'
(cd "$clone" && "$claim" --repo yuto1201/iOS-Template --issue 42 --agent codex) > "$claim_result"
assert_json "$claim_result" '
  value = JSON.parse(File.read(ARGV[0]))
  abort unless value["issue"] == 42
  abort unless value["branch"] == "codex/42-settings-screen"
  abort unless value["worktree"] == ".worktrees/42-settings-screen"
  abort unless value["state"] == "claimed" && value["previousState"] == "approved" && value["resumeState"].nil?
'
[[ "$before_status" == "$(git -C "$clone" status --porcelain)" ]] || { echo 'claim changed dirty main checkout' >&2; exit 1; }
[[ -f "$clone/.artifacts/issues/42/issue-contract.json" ]]
assert_json "$clone/.artifacts/issues/42/issue-contract.json" '
  value = JSON.parse(File.read(ARGV[0]))
  abort unless value["issue"] == 42 && value["repository"] == "yuto1201/iOS-Template"
  abort unless value["goal"] == "Make the Settings screen deterministic."
  abort unless value["specAnchors"] == ["specs/acceptance.md#2-issue-definition-of-ready"]
  abort unless value["acceptanceCriteria"].map { |entry| entry["id"] } == ["AC-1", "AC-2"]
  abort unless value["dependencies"] == [5]
  abort unless value["externalOperations"] == ["github.read_issue", "github.update_issue", "github.push_branch", "github.create_pr", "github.merge_pr", "github.delete_branch", "supabase.inspect_project"]
'
ruby -rjson -rdigest -e '
  def canonical(value)
    case value
    when Hash then value.keys.sort.each_with_object({}) { |key, out| out[key] = canonical(value.fetch(key)) }
    when Array then value.map { |entry| canonical(entry) }
    else value
    end
  end
  contract_path, state_path = ARGV
  contract_bytes = File.binread(contract_path)
  expected_bytes = JSON.generate(canonical(JSON.parse(contract_bytes)))
  abort "Issue contract bytes are not exact canonical JSON" unless contract_bytes == expected_bytes
  state = JSON.parse(File.binread(state_path))
  expected_digest = "sha256:#{Digest::SHA256.hexdigest(contract_bytes)}"
  abort "state Issue-contract digest does not cover exact canonical bytes" unless state.dig("issueContract", "digest") == expected_digest
' "$clone/.artifacts/issues/42/issue-contract.json" "$clone/.artifacts/issues/42/state.json"
assert_json "$clone/.artifacts/issues/42/state.json" '
  value = JSON.parse(File.read(ARGV[0]))
  abort unless value["issue"] == 42 && value["branch"] == "codex/42-settings-screen"
  abort unless value["baseSha"] =~ /\A[0-9a-f]{40}\z/
  abort unless value["primaryImplementer"] == "codex"
  abort unless value.dig("issueContract", "path") == ".artifacts/issues/42/issue-contract.json"
  abort unless value.dig("issueContract", "digest") =~ /\Asha256:[0-9a-f]{64}\z/
'
[[ -d "$clone/.worktrees/42-settings-screen" ]]
[[ "$(git -C "$clone/.worktrees/42-settings-screen" branch --show-current)" == 'codex/42-settings-screen' ]]
[[ -L "$clone/.worktrees/42-settings-screen/.artifacts" ]] || { echo 'claim did not install the shared artifact link' >&2; exit 1; }
[[ "$(readlink "$clone/.worktrees/42-settings-screen/.artifacts")" == '../../.artifacts' ]] || { echo 'claim installed a noncanonical artifact link' >&2; exit 1; }
[[ "$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$clone/.worktrees/42-settings-screen/.artifacts")" == "$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$clone/.artifacts")" ]] || { echo 'claim artifact link does not resolve to the primary store' >&2; exit 1; }
assert_json "$labels_file" 'abort unless JSON.parse(File.read(ARGV[0])) == ["type:feature", "state:claimed"]'

# Operational tools run from the Issue worktree must bind that worktree Head
# while publishing through its exact relative link to the primary artifact store.
cp -R "$clone/tools" "$clone/.worktrees/42-settings-screen/"
cp -R "$clone/Config" "$clone/.worktrees/42-settings-screen/"
worktree_head=$(git -C "$clone/.worktrees/42-settings-screen" rev-parse HEAD)
(cd "$clone/.worktrees/42-settings-screen" && tools/github-account-preflight.sh --repo yuto1201/iOS-Template --issue 42 --intended-operation github.create_pr --expected-head "$worktree_head") > "$workspace/worktree-preflight.json"
EXPECTED_HEAD="$worktree_head" assert_json "$clone/.artifacts/issues/42/github-preflight.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["headSha"] == ENV.fetch("EXPECTED_HEAD")'

# A later Push makes the same name visible locally and as origin/<branch>.
# That is still one canonical candidate, so repeated Claim must remain idempotent.
git -C "$clone" update-ref refs/remotes/origin/codex/42-settings-screen "$(git -C "$clone" rev-parse codex/42-settings-screen)"
edits_before=$(rg -c '^issue edit ' "$gh_log" || true)
(cd "$clone" && "$claim" --repo yuto1201/iOS-Template --issue 42 --agent codex) > "$workspace/repeated-claim.json"
cmp -s "$claim_result" "$workspace/repeated-claim.json"
[[ "$edits_before" == "$(rg -c '^issue edit ' "$gh_log" || true)" ]] || { echo 'repeated claim mutated Issue state' >&2; exit 1; }

assert_fails 'a different primary implementer cannot claim the same Issue' bash -c "cd '$clone' && '$claim' --repo yuto1201/iOS-Template --issue 42 --agent claude"
[[ "$before_status" == "$(git -C "$clone" status --porcelain)" ]] || { echo 'conflicting claim changed dirty main checkout' >&2; exit 1; }
assert_json "$labels_file" 'abort unless JSON.parse(File.read(ARGV[0])) == ["type:feature", "state:claimed"]'

rm "$clone/.artifacts/issues/42/state.json"
(cd "$clone" && "$resume" --repo yuto1201/iOS-Template --issue 42) > "$workspace/resume.json"
cmp -s "$claim_result" "$workspace/resume.json"
[[ -f "$clone/.artifacts/issues/42/state.json" ]]

# Resume recreates only a missing canonical link after it has proven the exact
# worktree and Git-common identity. An unsafe replacement must remain untouched.
rm "$clone/.worktrees/42-settings-screen/.artifacts"
(cd "$clone" && "$resume" --repo yuto1201/iOS-Template --issue 42) > "$workspace/resume-with-link.json"
[[ -L "$clone/.worktrees/42-settings-screen/.artifacts" && "$(readlink "$clone/.worktrees/42-settings-screen/.artifacts")" == '../../.artifacts' ]] || { echo 'resume did not restore the canonical artifact link' >&2; exit 1; }
rm "$clone/.worktrees/42-settings-screen/.artifacts"
ln -s ../../outside "$clone/.worktrees/42-settings-screen/.artifacts"
assert_fails 'resume rejects an unsafe shared artifact link without replacing it' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
[[ -L "$clone/.worktrees/42-settings-screen/.artifacts" && "$(readlink "$clone/.worktrees/42-settings-screen/.artifacts")" == '../../outside' ]] || { echo 'resume replaced an unsafe artifact link' >&2; exit 1; }
rm "$clone/.worktrees/42-settings-screen/.artifacts"
ln -s ../../.artifacts "$clone/.worktrees/42-settings-screen/.artifacts"

cp "$comments_file" "$workspace/claim-comments.json"

# A blocked or paused Issue may resume only to the exact marker resumeState.
# These valid recoveries exercise the decoded string rather than JSON quoting.
printf '%s' '["type:feature","state:in-progress"]' > "$labels_file"
ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"blocked:user\",\"resumeState\":\"in-progress\",\"timestamp\":\"2026-08-24T00:00:00Z\",\"to\":\"in-progress\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
(cd "$clone" && "$resume" --repo yuto1201/iOS-Template --issue 42) > "$workspace/blocked-resume.json"
assert_json "$workspace/blocked-resume.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["state"] == "in-progress" && value["previousState"] == "blocked:user" && value["resumeState"] == "in-progress"'
assert_json "$clone/.artifacts/issues/42/state.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["state"] == "in-progress" && value["previousState"] == "blocked:user" && value["resumeState"] == "in-progress"'

printf '%s' '["type:feature","state:in-progress"]' > "$labels_file"
cp "$workspace/claim-comments.json" "$comments_file"

# A later third-party marker cannot redirect or deny Resume. Only markers by
# the configured personal owner participate in deterministic history recovery.
printf '%s' '["type:feature","state:claimed"]' > "$labels_file"
ruby -rjson -e 'path=ARGV.fetch(0); comments=JSON.parse(File.read(path)); comments << {"body"=>"<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"blocked:user\",\"resumeState\":\"claimed\",\"timestamp\":\"2026-08-24T23:59:59Z\",\"to\":\"claimed\"} -->", "author"=>{"login"=>"attacker"}, "createdAt"=>"2026-08-24T23:59:59Z"}; File.write(path,JSON.generate(comments))' "$comments_file"
(cd "$clone" && "$resume" --repo yuto1201/iOS-Template --issue 42) > "$workspace/third-party-marker.json"
assert_json "$workspace/third-party-marker.json" 'value=JSON.parse(File.read(ARGV[0])); abort unless value["state"]=="claimed" && value["previousState"]=="approved" && value["resumeState"].nil?'
cp "$workspace/claim-comments.json" "$comments_file"
printf '%s' '["type:feature","state:in-progress"]' > "$labels_file"
ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"paused\",\"resumeState\":\"in-progress\",\"timestamp\":\"2026-08-24T00:00:01Z\",\"to\":\"in-progress\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
(cd "$clone" && "$resume" --repo yuto1201/iOS-Template --issue 42) > "$workspace/paused-resume.json"
assert_json "$workspace/paused-resume.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["state"] == "in-progress" && value["previousState"] == "paused" && value["resumeState"] == "in-progress"'
assert_json "$clone/.artifacts/issues/42/state.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["state"] == "in-progress" && value["previousState"] == "paused" && value["resumeState"] == "in-progress"'

cp "$workspace/claim-comments.json" "$comments_file"
ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"blocked:user\",\"resumeState\":\"verify-passed\",\"timestamp\":\"2026-08-24T00:00:02Z\",\"to\":\"in-progress\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
cp "$clone/.artifacts/issues/42/state.json" "$workspace/state-before-mismatched-resume.json"
assert_fails 'resume rejects a blocked recovery whose resumeState does not match' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
cmp -s "$workspace/state-before-mismatched-resume.json" "$clone/.artifacts/issues/42/state.json"
printf '%s' '["type:feature","state:claimed"]' > "$labels_file"
cp "$workspace/claim-comments.json" "$comments_file"

# Resume must rebuild the canonical candidate names from the current title and
# must reject only the newest transition marker when it is not usable.
export FAKE_GH_ISSUE_TITLE='Renamed Settings screen'
assert_fails 'resume rejects a stale-title Branch and worktree' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
unset FAKE_GH_ISSUE_TITLE

ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"claimed\",\"resumeState\":null,\"timestamp\":\"2026-08-24T00:00:01Z\",\"to\":\"in-progress\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
(cd "$clone" && "$resume" --repo yuto1201/iOS-Template --issue 42) > "$workspace/ignores-other-state-marker.json"
assert_json "$workspace/ignores-other-state-marker.json" 'value=JSON.parse(File.read(ARGV[0])); abort unless value["state"]=="claimed" && value["previousState"]=="approved"'
cp "$workspace/claim-comments.json" "$comments_file"

ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"approved\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
(cd "$clone" && "$resume" --repo yuto1201/iOS-Template --issue 42) > "$workspace/ignores-malformed-marker.json"
cp "$workspace/claim-comments.json" "$comments_file"

ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); marker = "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"approved\",\"resumeState\":null,\"timestamp\":\"2026-08-24T00:00:02Z\",\"to\":\"claimed\"} -->"; comments << {"body" => "#{marker}\n#{marker}"}; File.write(path, JSON.generate(comments))' "$comments_file"
(cd "$clone" && "$resume" --repo yuto1201/iOS-Template --issue 42) > "$workspace/ignores-malformed-duplicate-comment.json"
cp "$workspace/claim-comments.json" "$comments_file"

ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"done\",\"resumeState\":null,\"timestamp\":\"2026-08-24T00:00:03Z\",\"to\":\"claimed\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
(cd "$clone" && "$resume" --repo yuto1201/iOS-Template --issue 42) > "$workspace/ignores-invalid-transition-marker.json"
cp "$workspace/claim-comments.json" "$comments_file"

ruby -rjson -e 'path=ARGV.fetch(0); comments=JSON.parse(File.read(path)); timestamp="2099-08-24T12:34:56Z"; comments << {"body"=>"<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"approved\",\"resumeState\":null,\"timestamp\":\"#{timestamp}\",\"to\":\"claimed\"} -->", "author"=>{"login"=>"yuto1201"}, "createdAt"=>timestamp}; comments << {"body"=>"<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"blocked:user\",\"resumeState\":\"claimed\",\"timestamp\":\"#{timestamp}\",\"to\":\"claimed\"} -->", "author"=>{"login"=>"yuto1201"}, "createdAt"=>timestamp}; File.write(path,JSON.generate(comments))' "$comments_file"
assert_fails 'resume fails closed when two owned current-state markers share the latest timestamp' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
cp "$workspace/claim-comments.json" "$comments_file"

# Resume refuses an absent marker and a second Issue branch without attempting a
# GitHub transition or changing the existing canonical worktree.
printf '%s' '[]' > "$comments_file"
assert_fails 'resume requires a state-transition marker' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
assert_json "$labels_file" 'abort unless JSON.parse(File.read(ARGV[0])) == ["type:feature", "state:claimed"]'

cp "$workspace/claim-comments.json" "$comments_file"
base_sha=$(git -C "$clone" rev-parse codex/42-settings-screen)
git -C "$clone" branch claude/42-settings-screen "$base_sha"
assert_fails 'resume rejects multiple Issue branch candidates' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
[[ -d "$clone/.worktrees/42-settings-screen" ]]

echo 'PASS: deterministic Issue claim, idempotency, conflict refusal, dirty-main preservation, and marker-based resume'
