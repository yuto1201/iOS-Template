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
    printf 'Logged in to github.com account yuto1201 (keychain)\n  - Active account: true\n'
    ;;
  'repo view')
    printf '%s\n' '{"nameWithOwner":"yuto1201/iOS-Template","defaultBranchRef":{"name":"main"},"url":"https://github.com/yuto1201/iOS-Template"}'
    ;;
  'issue view')
    ruby -rjson -e 'puts JSON.generate({"title" => ENV.fetch("FAKE_GH_ISSUE_TITLE", "Settings screen"), "body" => File.read(ENV.fetch("FAKE_GH_ISSUE_BODY")), "labels" => JSON.parse(File.read(ENV.fetch("FAKE_GH_LABELS_FILE"))).map { |name| {"name" => name} }, "comments" => JSON.parse(File.read(ENV.fetch("FAKE_GH_COMMENTS_FILE")))})'
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
    ruby -rjson -e 'path, body = ARGV; comments = JSON.parse(File.read(path)); comments << {"body" => body}; File.write(path, JSON.generate(comments))' "$FAKE_GH_COMMENTS_FILE" "$body"
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

## External operations

- None.

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

claim_result="$workspace/claim.json"
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
  abort unless value["dependencies"] == [5] && value["externalOperations"] == []
'
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
assert_json "$labels_file" 'abort unless JSON.parse(File.read(ARGV[0])) == ["type:feature", "state:claimed"]'

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

cp "$comments_file" "$workspace/claim-comments.json"

# A blocked or paused Issue may resume only to the exact marker resumeState.
# These valid recoveries exercise the decoded string rather than JSON quoting.
printf '%s' '["type:feature","state:in-progress"]' > "$labels_file"
ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"blocked:user\",\"resumeState\":\"in-progress\",\"timestamp\":\"2026-08-24T00:00:00Z\",\"to\":\"in-progress\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
(cd "$clone" && "$resume" --repo yuto1201/iOS-Template --issue 42) > "$workspace/blocked-resume.json"
assert_json "$workspace/blocked-resume.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["state"] == "in-progress" && value["previousState"] == "blocked:user" && value["resumeState"] == "in-progress"'

printf '%s' '["type:feature","state:in-progress"]' > "$labels_file"
cp "$workspace/claim-comments.json" "$comments_file"
ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"paused\",\"resumeState\":\"in-progress\",\"timestamp\":\"2026-08-24T00:00:01Z\",\"to\":\"in-progress\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
(cd "$clone" && "$resume" --repo yuto1201/iOS-Template --issue 42) > "$workspace/paused-resume.json"
assert_json "$workspace/paused-resume.json" 'value = JSON.parse(File.read(ARGV[0])); abort unless value["state"] == "in-progress" && value["previousState"] == "paused" && value["resumeState"] == "in-progress"'

cp "$workspace/claim-comments.json" "$comments_file"
ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"blocked:user\",\"resumeState\":\"verify-passed\",\"timestamp\":\"2026-08-24T00:00:02Z\",\"to\":\"in-progress\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
assert_fails 'resume rejects a blocked recovery whose resumeState does not match' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
printf '%s' '["type:feature","state:claimed"]' > "$labels_file"
cp "$workspace/claim-comments.json" "$comments_file"

# Resume must rebuild the canonical candidate names from the current title and
# must reject only the newest transition marker when it is not usable.
export FAKE_GH_ISSUE_TITLE='Renamed Settings screen'
assert_fails 'resume rejects a stale-title Branch and worktree' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
unset FAKE_GH_ISSUE_TITLE

ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"claimed\",\"resumeState\":null,\"timestamp\":\"2026-08-24T00:00:01Z\",\"to\":\"in-progress\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
assert_fails 'resume rejects a newer marker whose state disagrees with the label' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
cp "$workspace/claim-comments.json" "$comments_file"

ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"approved\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
assert_fails 'resume rejects a malformed newest marker' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
cp "$workspace/claim-comments.json" "$comments_file"

ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); marker = "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"approved\",\"resumeState\":null,\"timestamp\":\"2026-08-24T00:00:02Z\",\"to\":\"claimed\"} -->"; comments << {"body" => "#{marker}\n#{marker}"}; File.write(path, JSON.generate(comments))' "$comments_file"
assert_fails 'resume rejects duplicate newest markers' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
cp "$workspace/claim-comments.json" "$comments_file"

ruby -rjson -e 'path = ARGV.fetch(0); comments = JSON.parse(File.read(path)); comments << {"body" => "<!-- ios-template-state {\"executor\":\"codex\",\"from\":\"done\",\"resumeState\":null,\"timestamp\":\"2026-08-24T00:00:03Z\",\"to\":\"claimed\"} -->"}; File.write(path, JSON.generate(comments))' "$comments_file"
assert_fails 'resume rejects an invalid workflow transition marker' bash -c "cd '$clone' && '$resume' --repo yuto1201/iOS-Template --issue 42"
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
