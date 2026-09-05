#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-claim-recovery.XXXXXX")
trap 'rm -rf "$workspace"' EXIT

remote="$workspace/remote.git"
seed="$workspace/seed"
git init --bare "$remote" >/dev/null
git init -b main "$seed" >/dev/null
git -C "$seed" config user.name Fixture
git -C "$seed" config user.email fixture@example.invalid
printf 'base\n' > "$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" commit -m base >/dev/null
git -C "$seed" push "$remote" main >/dev/null

body="$workspace/issue.md"
cat > "$body" <<'EOF'
## Goal

Recover an interrupted Claim.

## In scope

- Claim publication.

## Out of scope

- Application changes.

## Acceptance criteria

- AC-1: Every Claim boundary can resume exactly once.

## Spec anchors

- [Issue Definition of Ready](specs/acceptance.md#2-issue-definition-of-ready)

## Dependencies

- None.

## UI verification

- Not applicable.

## Delivery stage

- Stage: harden
- Time budget: 60 minutes
- Reason: Verify one Claim recovery concern.

## Delivery profile

- Profile: standard
- Reason: Local workflow recovery without a release gate.

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
EOF

for boundary in branch worktree link contract state remote-label remote-comment; do
  case_root="$workspace/$boundary"
  clone="$case_root/repo"
  mkdir -p "$case_root"
  git clone "$remote" "$clone" >/dev/null
  git -C "$clone" config user.name Fixture
  git -C "$clone" config user.email fixture@example.invalid
  cp -R "$repo_root/tools" "$clone/"
  cp -R "$repo_root/Config" "$clone/"
  cp -R "$repo_root/specs" "$clone/"
  cp -R "$repo_root/.agents" "$clone/"
  cp "$repo_root/.gitignore" "$clone/.gitignore"
  mkdir -p "$case_root/bin"
  cp "$repo_root/tools/tests/fixtures/gh" "$case_root/bin/gh"
  chmod +x "$case_root/bin/gh"
  printf '["state:approved","type:feature"]' > "$case_root/labels.json"
  printf '[]' > "$case_root/comments.json"
  : > "$case_root/gh.log"
  printf 'preserve\n' > "$clone/user-owned.txt"
  before_status=$(git -C "$clone" status --porcelain)

  if (cd "$clone" && env \
    PATH="$case_root/bin:$PATH" \
    FAKE_GH_LOG="$case_root/gh.log" \
    FAKE_GH_LABELS_FILE="$case_root/labels.json" \
    FAKE_GH_COMMENTS_FILE="$case_root/comments.json" \
    FAKE_GH_ISSUE_BODY="$body" \
    FAKE_GH_ISSUE_TITLE='Recovery screen' \
    IOS_TEMPLATE_CLAIM_FAIL_AFTER="$boundary" \
    tools/claim-issue.sh --repo yuto1201/iOS-Template --issue 42 --agent codex) > "$case_root/first.out" 2>&1; then
    echo "fault injection did not stop after $boundary" >&2
    exit 1
  fi

  (cd "$clone" && env \
    PATH="$case_root/bin:$PATH" \
    FAKE_GH_LOG="$case_root/gh.log" \
    FAKE_GH_LABELS_FILE="$case_root/labels.json" \
    FAKE_GH_COMMENTS_FILE="$case_root/comments.json" \
    FAKE_GH_ISSUE_BODY="$body" \
    FAKE_GH_ISSUE_TITLE='Recovery screen' \
    tools/claim-issue.sh --repo yuto1201/iOS-Template --issue 42 --agent codex) > "$case_root/result.json"

  BOUNDARY="$boundary" ruby -rjson -e '
    value=JSON.parse(File.read(ARGV[0])); abort "#{ENV.fetch("BOUNDARY")}: not claimed" unless value["state"]=="claimed" && value["branch"]=="codex/42-recovery-screen"
  ' "$case_root/result.json"
  ruby -rjson -e 'abort unless JSON.parse(File.read(ARGV[0])) == ["type:feature", "state:claimed"]' "$case_root/labels.json"
  ruby -rjson -e '
    comments=JSON.parse(File.read(ARGV[0])); owned=comments.select { |entry| entry.dig("author", "login")=="yuto1201" && entry.fetch("body", "").include?("ios-template-state") }; abort unless owned.length==1
  ' "$case_root/comments.json"
  [[ -f "$clone/.artifacts/issues/42/issue-contract.json" && -f "$clone/.artifacts/issues/42/state.json" ]]
  [[ -L "$clone/.worktrees/42-recovery-screen/.artifacts" && "$(readlink "$clone/.worktrees/42-recovery-screen/.artifacts")" == '../../.artifacts' ]]
  [[ "$before_status" == "$(git -C "$clone" status --porcelain)" ]] || { echo "$boundary changed the dirty primary checkout" >&2; exit 1; }
done

echo 'PASS: Claim recovers deterministically after every local and remote publication boundary'
