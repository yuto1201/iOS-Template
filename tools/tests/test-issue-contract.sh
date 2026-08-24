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
  local path=$1
  local external_operations=${2:-- None.}
  local user_approvals=${3:-None.}
  cat > "$path" <<EOF
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

$external_operations

## User approvals

- $user_approvals
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

write_feature_issue "$workspace/missing-service.md" $'- Environment: staging\n- Executor: Codex\n- Approval required: no' 'No additional approval.'
assert_fails 'external operation without a service is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/missing-service.md"

write_feature_issue "$workspace/unknown-approval-classification.md" $'- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: maybe' 'None.'
assert_fails 'unknown approval classification is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/unknown-approval-classification.md"

write_feature_issue "$workspace/missing-approval-classification.md" $'- Service: GitHub\n- Environment: production\n- Executor: Codex' 'None.'
assert_fails 'missing approval classification is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/missing-approval-classification.md"

write_feature_issue "$workspace/app-store-legal-claim.md" $'- Service: App Store Connect\n- Environment: production\n- Executor: Codex\n- Approval required: yes' 'None.'
assert_fails 'final App Store legal claim requires an approval reference' "$repo_root/tools/validate-issue-body.sh" "$workspace/app-store-legal-claim.md"

write_feature_issue "$workspace/irreversible-production-transform.md" $'- Service: Supabase\n- Environment: production\n- Executor: Codex\n- Approval required: yes' 'None.'
assert_fails 'irreversible production transform requires an approval reference' "$repo_root/tools/validate-issue-body.sh" "$workspace/irreversible-production-transform.md"

write_feature_issue "$workspace/normal-repo-operation.md" $'- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no' 'No additional approval.'
"$repo_root/tools/validate-issue-body.sh" "$workspace/normal-repo-operation.md"

write_feature_issue "$workspace/approved-external-operation.md" $'- Service: App Store Connect\n- Environment: production\n- Executor: Codex\n- Approval required: yes' 'Approval reference: #73'
"$repo_root/tools/validate-issue-body.sh" "$workspace/approved-external-operation.md"

"$repo_root/tools/validate-issue-body.sh" --type feature "$workspace/feature.md"

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

- None.

## Original PR

- #42

## Reproduction steps

1. Launch the app.
2. Open Settings.
EOF
"$repo_root/tools/validate-issue-body.sh" --type regression "$workspace/regression.md"

sed -e 's/^## Original PR$/## Original Reference/' -e 's/^## Reproduction steps$/## Steps/' "$workspace/regression.md" > "$workspace/regression-missing-both.md"
assert_fails 'Regression Issue without both regression fields is rejected' "$repo_root/tools/validate-issue-body.sh" --type regression "$workspace/regression-missing-both.md"

sed 's/^## Original PR$/## Original Reference/' "$workspace/regression.md" > "$workspace/regression-missing-original-pr.md"
assert_fails 'Regression Issue without Original PR is rejected' "$repo_root/tools/validate-issue-body.sh" --type regression "$workspace/regression-missing-original-pr.md"

sed 's/^## Reproduction steps$/## Steps/' "$workspace/regression.md" > "$workspace/regression-missing-reproduction.md"
assert_fails 'Regression Issue without reproduction steps is rejected' "$repo_root/tools/validate-issue-body.sh" --type regression "$workspace/regression-missing-reproduction.md"

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
