#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-delivery-stage.XXXXXX")
trap 'rm -rf "$workspace"' EXIT

assert_fails() {
  local message=$1
  shift
  if "$@" >"$workspace/output" 2>&1; then
    echo "expected failure: $message" >&2
    exit 1
  fi
}

write_issue() {
  local path=$1 stage=$2 budget=$3 profile=$4 scope=$5 cases=$6 mappings=$7
  cat >"$path" <<EOF
## Goal

Make a delivery-stage fixture operable.

## In scope

- Exercise one bounded workflow.

## Out of scope

- Claim release readiness early.

## Acceptance criteria

- AC-1: The selected stage verification passes.

## Spec anchors

- [Issue Definition of Ready](specs/acceptance.md#2-issue-definition-of-ready)

## Dependencies

- None.

## UI verification

- Target screens/states: Welcome flow.
- English expectations: Only when selected by the stage target.
- Japanese expectations: The primary flow remains operable.

## Delivery stage

- Stage: $stage
- Time budget: $budget minutes
- Reason: Exercise the explicit stage contract.

## Delivery profile

- Profile: $profile
- Reason: Fixture risk classification.

## Verification scope

- Scope: $scope
- Reason: Fixture target selection.

## Verification

\`\`\`json
{
  "bundleIdentifier": "com.yuto.TemplateApp",
  "unitTestIdentifier": "TemplateAppTests/TemplateAppTests/welcomeMessageLocalizations()",
  "cases": $cases,
  "acceptanceMappings": $mappings
}
\`\`\`

## External operations

- None.

## User approvals

- None.
EOF
}

shape_cases='[{"id":"iphone-ja","testIdentifier":"TemplateAppUITests/TemplateAppUITests/testJapaneseWelcomeTitle"}]'
shape_mappings='[{"id":"AC-1","checks":["stage:build","stage:unit-tests","case:iphone-ja"]}]'
write_issue "$workspace/shape.md" shape 120 standard iphone-ja "$shape_cases" "$shape_mappings"
"$repo_root/tools/validate-issue-body.sh" --type feature "$workspace/shape.md"
ruby "$repo_root/tools/lib/issue-contract.rb" --body "$workspace/shape.md" --type feature \
  --format contract --issue 45 --repo yuto1201/iOS-Template --fetched-at 2026-09-02T00:00:00Z \
  >"$workspace/shape.json"
ruby -I"$repo_root/tools/lib" -rjson -rdelivery-profile -e '
  value=JSON.parse(File.binread(ARGV.fetch(0)))
  abort unless value.fetch("deliveryStage") == {"name"=>"shape","timeBudgetMinutes"=>120,"reason"=>"Exercise the explicit stage contract."}
  abort unless value.fetch("verificationScope") == {"name"=>"iphone-ja","reason"=>"Fixture target selection."}
  abort unless IOSTemplate::DeliveryProfile.review_required?(value) == false
' "$workspace/shape.json"

# Documentation-only hardening does not invent a Simulator scope.
ruby -I"$repo_root/tools/lib" -rverification-scope -e '
  value={"deliveryStage"=>{"name"=>"harden","timeBudgetMinutes"=>60,"reason"=>"One documentation concern."},"deliveryProfile"=>{"name"=>"standard","reason"=>"Ordinary documentation."}}
  abort unless IOSTemplate::VerificationScope.validate_contract!(value) == "full"
'

sed 's/Time budget: 120 minutes/Time budget: 0 minutes/' "$workspace/shape.md" >"$workspace/zero-budget.md"
assert_fails 'zero shape budget is rejected' "$repo_root/tools/validate-issue-body.sh" --type feature "$workspace/zero-budget.md"
sed 's/Stage: shape/Stage: prototype/' "$workspace/shape.md" >"$workspace/unknown-stage.md"
assert_fails 'unknown stage is rejected' "$repo_root/tools/validate-issue-body.sh" --type feature "$workspace/unknown-stage.md"
sed '/## Delivery stage/,/## Delivery profile/d' "$workspace/shape.md" >"$workspace/missing-stage.md"
assert_fails 'new Issue missing Delivery stage is rejected' "$repo_root/tools/validate-issue-body.sh" --type feature "$workspace/missing-stage.md"

full_cases='[{"id":"iphone-en","testIdentifier":"TemplateAppUITests/TemplateAppUITests/testEnglishWelcomeTitle"},{"id":"iphone-ja","testIdentifier":"TemplateAppUITests/TemplateAppUITests/testJapaneseWelcomeTitle"},{"id":"ipad-en","testIdentifier":"TemplateAppUITests/TemplateAppUITests/testEnglishWelcomeTitle"},{"id":"ipad-ja","testIdentifier":"TemplateAppUITests/TemplateAppUITests/testJapaneseWelcomeTitle"}]'
full_mappings='[{"id":"AC-1","checks":["stage:build","stage:unit-tests","case:iphone-en","case:iphone-ja","case:ipad-en","case:ipad-ja","visual:iphone-en","visual:iphone-ja","visual:ipad-en","visual:ipad-ja"]}]'
write_issue "$workspace/shape-full.md" shape 120 standard full "$full_cases" "$full_mappings"
assert_fails 'shape full matrix and visual evidence are rejected' "$repo_root/tools/validate-issue-body.sh" --type feature "$workspace/shape-full.md"

harden_cases='[{"id":"iphone-en","testIdentifier":"TemplateAppUITests/TemplateAppUITests/testEnglishWelcomeTitle"},{"id":"ipad-ja","testIdentifier":"TemplateAppUITests/TemplateAppUITests/testJapaneseWelcomeTitle"}]'
harden_mappings='[{"id":"AC-1","checks":["stage:build","stage:unit-tests","case:iphone-en","case:ipad-ja"]}]'
write_issue "$workspace/harden.md" harden 180 standard targeted "$harden_cases" "$harden_mappings"
"$repo_root/tools/validate-issue-body.sh" --type feature "$workspace/harden.md"
ruby "$repo_root/tools/lib/issue-contract.rb" --body "$workspace/harden.md" --type feature \
  --format contract --issue 46 --repo yuto1201/iOS-Template --fetched-at 2026-09-02T00:00:00Z \
  >"$workspace/harden.json"
ruby -rjson -e '
  value=JSON.parse(File.binread(ARGV.fetch(0)))
  abort unless value.dig("deliveryStage","name") == "harden"
  abort unless value.dig("verificationScope","name") == "targeted"
  abort unless value.dig("verification","cases").map { |entry| entry.fetch("id") } == %w[iphone-en ipad-ja]
' "$workspace/harden.json"

write_issue "$workspace/release.md" release 480 strict full "$full_cases" "$full_mappings"
"$repo_root/tools/validate-issue-body.sh" --type release "$workspace/release.md"
ruby "$repo_root/tools/lib/issue-contract.rb" --body "$workspace/release.md" --type release \
  --format contract --issue 47 --repo yuto1201/iOS-Template --fetched-at 2026-09-02T00:00:00Z \
  >"$workspace/release.json"
ruby -I"$repo_root/tools/lib" -rjson -rdelivery-profile -e '
  value=JSON.parse(File.binread(ARGV.fetch(0)))
  abort unless IOSTemplate::DeliveryProfile.review_required?(value)
' "$workspace/release.json"
sed 's/Profile: strict/Profile: standard/' "$workspace/release.md" >"$workspace/release-standard.md"
assert_fails 'release requires strict profile' "$repo_root/tools/validate-issue-body.sh" --type release "$workspace/release-standard.md"
sed 's/visual:ipad-ja"]/["case:iphone-en"]/' "$workspace/release.md" >"$workspace/release-incomplete.md"
assert_fails 'release requires every visual case' "$repo_root/tools/validate-issue-body.sh" --type release "$workspace/release-incomplete.md"

# Already sealed contracts remain byte-compatible and default to legacy release-level gates.
sed '/## Delivery stage/,/## Delivery profile/d' "$workspace/release.md" \
  | sed 's/- Scope: full/- Scope: full\
- Stage: release/' >"$workspace/legacy.md"
ruby "$repo_root/tools/lib/issue-contract.rb" --allow-legacy-delivery-stage \
  --body "$workspace/legacy.md" --type feature --format contract \
  --issue 44 --repo yuto1201/iOS-Template --fetched-at 2026-09-01T00:00:00Z \
  >"$workspace/legacy.json"
ruby -I"$repo_root/tools/lib" -rjson -rdelivery-stage -rdelivery-profile -e '
  value=JSON.parse(File.binread(ARGV.fetch(0)))
  abort if value.key?("deliveryStage")
  abort unless IOSTemplate::DeliveryStage.effective_name(value) == "release"
  abort unless IOSTemplate::DeliveryProfile.review_required?(value)
' "$workspace/legacy.json"

# A sealed pre-migration fast contract keeps its former no-review path.
ruby -I"$repo_root/tools/lib" -rdelivery-profile -e '
  value={"deliveryProfile"=>{"name"=>"fast","reason"=>"Legacy focused verification."}}
  abort if IOSTemplate::DeliveryProfile.review_required?(value)
'

# Risk remains independent: strict shape still requires formal review.
ruby -I"$repo_root/tools/lib" -rjson -rdelivery-profile -e '
  value=JSON.parse(File.binread(ARGV.fetch(0)))
  value["deliveryProfile"]={"name"=>"strict","reason"=>"Sensitive shape."}
  abort unless IOSTemplate::DeliveryProfile.review_required?(value)
' "$workspace/shape.json"

for form in feature regression release; do
  path="$repo_root/.github/ISSUE_TEMPLATE/$form.yml"
  [[ -f "$path" ]] || { echo "missing $form Issue form" >&2; exit 1; }
  rg -Fq 'label: Delivery stage' "$path"
done
rg -Fq 'Stage: shape' "$repo_root/.github/ISSUE_TEMPLATE/feature.yml"
rg -Fq 'Stage: harden' "$repo_root/.github/ISSUE_TEMPLATE/regression.yml"
rg -Fq 'Stage: release' "$repo_root/.github/ISSUE_TEMPLATE/release.yml"
rg -Fq 'Time budget: 120 minutes' "$repo_root/.github/ISSUE_TEMPLATE/feature.yml"

echo 'delivery stage tests passed'
