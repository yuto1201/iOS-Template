#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-issue-contract.XXXXXX")
trap 'rm -rf "$workspace"' EXIT

assert_fails() {
  local message=$1
  shift
  if "$@" >"$workspace/output" 2>&1; then
    echo "expected failure: $message" >&2
    exit 1
  fi
}

write_feature_issue() {
  cat > "$1" <<'EOF'
## Goal

Make the workflow contract testable.

## In scope

- Validate Issue Definition of Ready.

## Out of scope

- Change application behavior.

## Acceptance criteria

- AC-1: A complete Feature Issue passes validation.
- AC-2: Each AC ID is stable and unique.

## Spec anchors

- [Issue Definition of Ready](specs/acceptance.md#2-issue-definition-of-ready)

## Dependencies

- None.

## External operations

- None.

## User approvals

- Not required.
EOF
}

write_feature_issue "$workspace/feature.md"
"$repo_root/tools/validate-issue-body.sh" "$workspace/feature.md"
sed 's/^## /### /' "$workspace/feature.md" > "$workspace/github-form-feature.md"
"$repo_root/tools/validate-issue-body.sh" "$workspace/github-form-feature.md"

sed '/## Acceptance criteria/,/## Spec anchors/d' "$workspace/feature.md" > "$workspace/missing-ac.md"
assert_fails 'missing acceptance criteria is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/missing-ac.md"

sed 's/AC-2:/AC-1:/' "$workspace/feature.md" > "$workspace/duplicate-ac.md"
assert_fails 'duplicate acceptance criteria ID is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/duplicate-ac.md"

sed '/## Spec anchors/,/## Dependencies/d' "$workspace/feature.md" > "$workspace/missing-anchor.md"
assert_fails 'missing specification anchors are rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/missing-anchor.md"

sed 's/- None\./- Production database deletion./' "$workspace/feature.md" > "$workspace/approval-required.md"
assert_fails 'approval-required operation without approval reference is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/approval-required.md"

cat > "$workspace/regression.md" <<'EOF'
## Goal

Prevent a merged bug from recurring.

## In scope

- Reproduce and correct the regression.

## Out of scope

- Redesign the feature.

## Acceptance criteria

- AC-1: The reported regression no longer occurs.

## Spec anchors

- [Issue Definition of Ready](specs/acceptance.md#2-issue-definition-of-ready)

## Dependencies

- Original PR: #42

## External operations

- None.

## User approvals

- Not required.

## Original PR

- #42

## Reproduction steps

1. Launch the app.
2. Open Settings.
EOF
"$repo_root/tools/validate-issue-body.sh" "$workspace/regression.md"

for required in \
  '.github/ISSUE_TEMPLATE/feature.yml' \
  '.github/ISSUE_TEMPLATE/regression.yml' \
  '.github/pull_request_template.md' \
  '.github/labels.yml' \
  'tools/sync-github-labels.sh'; do
  [[ -f "$repo_root/$required" ]] || { echo "missing required workflow file: $required" >&2; exit 1; }
done

for heading in Goal 'In scope' 'Out of scope' 'Acceptance criteria' 'Spec anchors' Dependencies 'External operations' 'User approvals'; do
  rg -Fq "label: $heading" "$repo_root/.github/ISSUE_TEMPLATE/feature.yml" || { echo "feature form lacks $heading" >&2; exit 1; }
done
rg -Fq 'Original PR' "$repo_root/.github/ISSUE_TEMPLATE/regression.yml"
rg -Fq 'Reproduction steps' "$repo_root/.github/ISSUE_TEMPLATE/regression.yml"
for heading in Summary Specification Verification 'Opposite-model review' 'Remaining work'; do
  rg -Fq "## $heading" "$repo_root/.github/pull_request_template.md" || { echo "PR template lacks $heading" >&2; exit 1; }
done
rg -Fq 'Closes #' "$repo_root/.github/pull_request_template.md"

for label in \
  state:proposed state:approved state:claimed state:in-progress state:verify-passed \
  state:review-requested state:changes-requested state:approved-for-merge state:merged \
  state:done state:paused state:superseded state:blocked:user state:blocked:ops \
  state:blocked:review state:blocked:conflict state:blocked:dependency \
  state:blocked:environment state:blocked:repeated-failure agent:codex agent:claude \
  type:feature type:regression type:docs type:release; do
  rg -Fq "name: $label" "$repo_root/.github/labels.yml" || { echo "label manifest lacks $label" >&2; exit 1; }
done

fake_bin="$workspace/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
case "$1 $2" in
  'auth status') printf 'Logged in to github.com account yuto1201 (keychain)\n  - Active account: true\n' ;;
  'repo view') printf '%s\n' '{"nameWithOwner":"yuto1201/iOS-Template","defaultBranchRef":{"name":"main"},"url":"https://github.com/yuto1201/iOS-Template"}' ;;
  'label list') printf '%s\n' '[{"name":"state:proposed","color":"ffffff","description":"wrong"}]' ;;
  'label edit'|'label create') exit 0 ;;
  *) echo "unexpected fake gh invocation: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$fake_bin/gh"
export PATH="$fake_bin:$PATH"
export FAKE_GH_LOG="$workspace/gh.log"
"$repo_root/tools/sync-github-labels.sh" --repo yuto1201/iOS-Template --executor codex
rg -q '^label edit state:proposed ' "$FAKE_GH_LOG"
rg -q '^label create agent:codex ' "$FAKE_GH_LOG"

echo 'PASS: Issue forms, Definition of Ready validator, PR template, labels, and Codex label sync'
