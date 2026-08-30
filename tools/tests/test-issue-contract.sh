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

assert_json() {
  local document=$1 code=$2
  ruby -rjson -e "$code" "$document"
}

write_feature_issue() {
  local path=$1
  local external_operations=${2:-- None.}
  local user_approvals=${3:-None.}
  local delivery_profile=${4:-}
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

## UI verification

- Not applicable.

$delivery_profile

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

write_feature_issue "$workspace/missing-service.md" $'- Operation: supabase.inspect_project\n- Environment: staging\n- Executor: Codex\n- Approval required: no' 'No additional approval.'
assert_fails 'external operation without a service is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/missing-service.md"

write_feature_issue "$workspace/unknown-operation.md" $'- Operation: github.destroy_repository\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no' 'No additional approval.'
assert_fails 'an operation outside the AUTHORITY allowlist is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/unknown-operation.md"

write_feature_issue "$workspace/service-mismatch.md" $'- Operation: supabase.inspect_project\n- Service: GitHub\n- Environment: staging\n- Executor: Codex\n- Approval required: no' 'No additional approval.'
assert_fails 'an operation whose service does not match its prefix is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/service-mismatch.md"

write_feature_issue "$workspace/unknown-approval-classification.md" $'- Operation: github.push_branch\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: maybe' 'None.'
assert_fails 'unknown approval classification is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/unknown-approval-classification.md"

write_feature_issue "$workspace/missing-approval-classification.md" $'- Operation: github.push_branch\n- Service: GitHub\n- Environment: production\n- Executor: Codex' 'None.'
assert_fails 'missing approval classification is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/missing-approval-classification.md"

write_feature_issue "$workspace/duplicate-field.md" $'- Operation: github.push_branch\n- Service: GitHub\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no' 'No additional approval.'
assert_fails 'a repeated field inside an operation block is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/duplicate-field.md"

write_feature_issue "$workspace/malformed-block.md" $'- Service: GitHub\n- Operation: github.push_branch\n- Environment: production\n- Executor: Codex\n- Approval required: no' 'No additional approval.'
assert_fails 'an operation block whose fields are out of order is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/malformed-block.md"

write_feature_issue "$workspace/duplicate-operation.md" $'- Operation: github.push_branch\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n- Operation: github.push_branch\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no' 'No additional approval.'
assert_fails 'a repeated operation identifier is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/duplicate-operation.md"

write_feature_issue "$workspace/app-store-legal-claim.md" $'- Operation: appstore.submit_review\n- Service: App Store Connect\n- Environment: production\n- Executor: Codex\n- Approval required: yes' 'None.'
assert_fails 'final App Store legal claim requires an approval reference' "$repo_root/tools/validate-issue-body.sh" "$workspace/app-store-legal-claim.md"

write_feature_issue "$workspace/irreversible-production-transform.md" $'- Operation: supabase.apply_migrations\n- Service: Supabase\n- Environment: production\n- Executor: Codex\n- Approval required: yes' 'None.'
assert_fails 'irreversible production transform requires an approval reference' "$repo_root/tools/validate-issue-body.sh" "$workspace/irreversible-production-transform.md"

write_feature_issue "$workspace/no-operation-with-approval.md" '- None.' 'Approval reference: #73'
assert_fails 'an approval reference without an external operation is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/no-operation-with-approval.md"

write_feature_issue "$workspace/no-approval-operation-with-reference.md" $'- Operation: github.push_branch\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no' 'Approval reference: #73'
assert_fails 'an approval reference mismatching all no operations is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/no-approval-operation-with-reference.md"

write_feature_issue "$workspace/normal-repo-operation.md" $'- Operation: github.push_branch\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no' 'No additional approval.'
"$repo_root/tools/validate-issue-body.sh" "$workspace/normal-repo-operation.md"

write_feature_issue "$workspace/claude-repo-operation.md" $'- Operation: github.push_branch\n- Service: GitHub\n- Environment: production\n- Executor: Claude\n- Approval required: no' 'No additional approval.'
"$repo_root/tools/validate-issue-body.sh" "$workspace/claude-repo-operation.md"

write_feature_issue "$workspace/fast-profile.md" $'- Operation: github.push_branch\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no' 'No additional approval.' $'## Delivery profile\n\n- Profile: fast\n- Reason: Local non-UI logic covered by targeted tests.'
"$repo_root/tools/validate-issue-body.sh" "$workspace/fast-profile.md"
ruby "$repo_root/tools/lib/issue-contract.rb" --body "$workspace/fast-profile.md" --type feature --format contract --issue 42 --repo yuto1201/iOS-Template --fetched-at 2026-08-24T00:00:00Z > "$workspace/fast-profile.json"
assert_json "$workspace/fast-profile.json" 'value=JSON.parse(File.read(ARGV[0])); abort unless value["deliveryProfile"]=={"name"=>"fast","reason"=>"Local non-UI logic covered by targeted tests."}'
assert_fails 'fast snapshot rejects a forged UI verification object' ruby -I"$repo_root/tools/lib" -rjson -rissue-contract -e '
value=JSON.parse(File.binread(ARGV.fetch(0))); value["verification"]={}; IOSTemplate::IssueContract.validate_snapshot!(value,issue:42,repository:"yuto1201/iOS-Template")' "$workspace/fast-profile.json"

sed 's/Profile: fast/Profile: turbo/' "$workspace/fast-profile.md" > "$workspace/unknown-profile.md"
assert_fails 'an unknown delivery profile is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/unknown-profile.md"

sed 's/- Not applicable\./- Target screens\/states: Settings loaded.\n- English expectations: Settings is complete.\n- Japanese expectations: 設定が完全に表示される。/' "$workspace/fast-profile.md" > "$workspace/fast-ui.md"
assert_fails 'fast profile rejects UI verification' "$repo_root/tools/validate-issue-body.sh" "$workspace/fast-ui.md"

write_feature_issue "$workspace/fast-migration.md" $'- Operation: supabase.apply_migrations\n- Service: Supabase\n- Environment: production\n- Executor: Codex\n- Approval required: no' 'No additional approval.' $'## Delivery profile\n\n- Profile: fast\n- Reason: Incorrectly classified migration.'
assert_fails 'fast profile rejects high-risk provider mutation' "$repo_root/tools/validate-issue-body.sh" "$workspace/fast-migration.md"

write_feature_issue "$workspace/standard-deploy.md" $'- Operation: cloudflare.deploy\n- Service: Cloudflare\n- Environment: production\n- Executor: Codex\n- Approval required: no' 'No additional approval.' $'## Delivery profile\n\n- Profile: standard\n- Reason: Incorrectly classified production deploy.'
assert_fails 'standard profile rejects high-risk provider mutation' "$repo_root/tools/validate-issue-body.sh" "$workspace/standard-deploy.md"

write_feature_issue "$workspace/strict-release.md" $'- Operation: appstore.submit_review\n- Service: App Store Connect\n- Environment: production\n- Executor: Codex\n- Approval required: yes' 'Approval reference: #73' $'## Delivery profile\n\n- Profile: strict\n- Reason: App Store submission is a release boundary.'
"$repo_root/tools/validate-issue-body.sh" "$workspace/strict-release.md"

write_feature_issue "$workspace/model-neutral-providers.md" $'- Operation: linear.inspect_workspace\n- Service: Linear\n- Environment: production\n- Executor: Claude\n- Approval required: no\n\n- Operation: vercel.inspect_team\n- Service: Vercel\n- Environment: production\n- Executor: Codex\n- Approval required: no' 'No additional approval.'
"$repo_root/tools/validate-issue-body.sh" "$workspace/model-neutral-providers.md"

write_feature_issue "$workspace/unknown-executor.md" $'- Operation: github.push_branch\n- Service: GitHub\n- Environment: production\n- Executor: Cursor\n- Approval required: no' 'No additional approval.'
assert_fails 'an external operation executor outside Codex and Claude is rejected' "$repo_root/tools/validate-issue-body.sh" "$workspace/unknown-executor.md"

write_feature_issue "$workspace/approved-external-operation.md" $'- Operation: appstore.submit_review\n- Service: App Store Connect\n- Environment: production\n- Executor: Codex\n- Approval required: yes' 'Approval reference: #73'
"$repo_root/tools/validate-issue-body.sh" "$workspace/approved-external-operation.md"

write_feature_issue "$workspace/multi-provider.md" $'- Operation: github.push_branch\n- Service: GitHub\n- Environment: production\n- Executor: Codex\n- Approval required: no\n\n- Operation: supabase.inspect_project\n- Service: Supabase\n- Environment: staging\n- Executor: Codex\n- Approval required: no' 'No additional approval.'
"$repo_root/tools/validate-issue-body.sh" "$workspace/multi-provider.md"
ruby "$repo_root/tools/lib/issue-contract.rb" \
  --body "$workspace/multi-provider.md" --type feature --format envelope \
  --issue 42 --repo yuto1201/iOS-Template --fetched-at 2026-08-24T00:00:00Z \
  > "$workspace/multi-provider.json"
assert_json "$workspace/multi-provider.json" '
  value = JSON.parse(File.read(ARGV[0]))
  abort unless value.fetch("contract").fetch("externalOperations") == ["github.push_branch", "supabase.inspect_project"]
  abort unless value.fetch("externalOperationDetails") == [
    {"operation" => "github.push_branch", "service" => "GitHub", "environment" => "production", "executor" => "Codex", "approvalRequired" => false, "approvalReference" => nil},
    {"operation" => "supabase.inspect_project", "service" => "Supabase", "environment" => "staging", "executor" => "Codex", "approvalRequired" => false, "approvalReference" => nil}
  ]
  abort unless value.fetch("contract").fetch("externalOperationDetailsDigest") == "sha256:5151021cb8aa2e91cfdbb3276015aa29e28d507fcb261be4e0a539e7a62743ee"
'
ruby "$repo_root/tools/lib/issue-contract.rb" \
  --body "$workspace/multi-provider.md" --type feature --format envelope \
  --issue 42 --repo yuto1201/iOS-Template --fetched-at 2026-08-24T00:00:00Z \
  > "$workspace/multi-provider-repeat.json"
cmp -s "$workspace/multi-provider.json" "$workspace/multi-provider-repeat.json" || {
  echo 'unchanged structured operation details were not deterministic' >&2
  exit 1
}

ruby "$repo_root/tools/lib/issue-contract.rb" \
  --body "$workspace/approved-external-operation.md" --type feature --format envelope \
  --issue 73 --repo yuto1201/iOS-Template --fetched-at 2026-08-24T00:00:00Z \
  > "$workspace/approved-external-operation.json"
assert_json "$workspace/approved-external-operation.json" '
  value = JSON.parse(File.read(ARGV[0]))
  details = value.fetch("externalOperationDetails")
  abort unless details == [{"operation" => "appstore.submit_review", "service" => "App Store Connect", "environment" => "production", "executor" => "Codex", "approvalRequired" => true, "approvalReference" => "Approval reference: #73"}]
  abort unless value.dig("contract", "externalOperationDetailsDigest") == "sha256:1cd2bd746c9c77fc9fe9b4c367beca33cb25a8a2ad3038ba8fef8818cbdc685b"
'

cp "$workspace/multi-provider.md" "$workspace/multi-provider-detail-change.md"
sed -i '' 's/- Environment: staging/- Environment: preview/' "$workspace/multi-provider-detail-change.md"
ruby "$repo_root/tools/lib/issue-contract.rb" \
  --body "$workspace/multi-provider-detail-change.md" --type feature --format contract \
  --issue 42 --repo yuto1201/iOS-Template --fetched-at 2026-08-24T00:00:00Z \
  > "$workspace/multi-provider-detail-change.json"
ruby -rjson -e '
  original = JSON.parse(File.read(ARGV[0])).fetch("contract")
  changed = JSON.parse(File.read(ARGV[1]))
  abort unless original["externalOperations"] == changed["externalOperations"]
  abort if original["externalOperationDetailsDigest"] == changed["externalOperationDetailsDigest"]
' "$workspace/multi-provider.json" "$workspace/multi-provider-detail-change.json"

"$repo_root/tools/validate-issue-body.sh" --type feature "$workspace/feature.md"
"$repo_root/tools/validate-issue-body.sh" --type docs "$workspace/feature.md"
"$repo_root/tools/validate-issue-body.sh" --type release "$workspace/feature.md"
assert_fails 'an unknown Issue type is rejected' "$repo_root/tools/validate-issue-body.sh" --type maintenance "$workspace/feature.md"

sed 's/- Not applicable\./- Target screens\/states: Settings loaded\./' "$workspace/feature.md" > "$workspace/incomplete-ui.md"
assert_fails 'UI verification requires both English and Japanese expectations' "$repo_root/tools/validate-issue-body.sh" "$workspace/incomplete-ui.md"

sed 's/- Not applicable\./- Target screens\/states: Settings loaded.\n- English expectations: The title is Settings.\n- Japanese expectations: The title is 設定。/' "$workspace/feature.md" > "$workspace/ui-feature.md"
"$repo_root/tools/validate-issue-body.sh" "$workspace/ui-feature.md"

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

## UI verification

- Not applicable.

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

for heading in Goal 'In scope' 'Out of scope' 'Acceptance criteria' 'Spec anchors' Dependencies 'UI verification' 'Delivery profile' 'External operations' 'User approvals'; do
  rg -Fq "label: $heading" "$repo_root/.github/ISSUE_TEMPLATE/feature.yml" || { echo "feature form lacks $heading" >&2; exit 1; }
done
for operation in github.read_issue github.update_issue github.push_branch github.create_pr github.merge_pr github.delete_branch; do
  rg -Fq -- "Operation: $operation" "$repo_root/.github/ISSUE_TEMPLATE/feature.yml" || { echo "feature form lacks standard operation $operation" >&2; exit 1; }
  rg -Fq -- "Operation: $operation" "$repo_root/.github/ISSUE_TEMPLATE/regression.yml" || { echo "regression form lacks standard operation $operation" >&2; exit 1; }
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
  'label list') ruby -rjson -e 'labels = 130.times.map { |index| {"name" => "legacy:label-#{index}", "color" => "ABCDEF", "description" => "legacy"} }; labels << {"name" => "state:proposed", "color" => "ffffff", "description" => "wrong"}; puts JSON.generate(labels)' ;;
  'label edit'|'label create') exit 0 ;;
  *) echo "unexpected fake gh invocation: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$fake_bin/gh"
export PATH="$fake_bin:$PATH"
export FAKE_GH_LOG="$workspace/gh.log"
"$repo_root/tools/sync-github-labels.sh" --repo yuto1201/iOS-Template --executor codex
"$repo_root/tools/sync-github-labels.sh" --repo yuto1201/iOS-Template --executor claude
rg -q '^label edit state:proposed ' "$FAKE_GH_LOG"
rg -q '^label create agent:codex ' "$FAKE_GH_LOG"
[[ "$(rg -c '^label list ' "$FAKE_GH_LOG")" == 2 ]] || { echo 'each model-neutral label sync did not use one repository snapshot' >&2; exit 1; }
rg -q '^label list --repo yuto1201/iOS-Template --limit 1000 --json name,color,description$' "$FAKE_GH_LOG"

echo 'PASS: Issue forms, Definition of Ready validator, PR template, labels, and model-neutral label sync'
