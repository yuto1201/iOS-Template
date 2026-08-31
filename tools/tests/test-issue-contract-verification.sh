#!/usr/bin/env bash
set -euo pipefail

# Fixes the `verification` object that tools/lib/issue-contract.rb adds to the Issue
# contract snapshot. tools/verify-ios-issue.sh refuses to run without it, so a
# regression here silently disables application verification for every Issue.
#
# The mapping is declared per Issue rather than derived from repository configuration,
# so these tests also fix that a repository default cannot widen what an Issue claims.

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-issue-contract-verification.XXXXXX")
trap 'rm -rf "$workspace"' EXIT

configuration="$workspace/verification.json"
cp "$repo_root/Config/verification.json" "$configuration"

contract_for() {
  ruby "$repo_root/tools/lib/issue-contract.rb" \
    --verification-config "$configuration" \
    --body "$1" --type feature --format contract \
    --issue 1 --repo owner/repo --fetched-at 2026-01-01T00:00:00Z
}

validate_for() {
  ruby "$repo_root/tools/lib/issue-contract.rb" \
    --verification-config "$configuration" \
    --body "$1" --type feature --format validate
}

write_issue() {
  local path=$1 mapping=$2
  cat > "$path" <<EOF
## Goal

Fix the verification contract.

## In scope

- Emit the verification object.

## Out of scope

- Change the verification schema.

## Acceptance criteria

- AC-1: The contract carries a verification object.
- AC-2: Every acceptance criterion is mapped.

## Spec anchors

- [Issue Definition of Done](specs/acceptance.md#3-issue-definition-of-done)

## Dependencies

None

## UI verification

- Target screens/states: Welcome screen
- English expectations: The English title renders.
- Japanese expectations: The Japanese title renders.

${mapping}
## External operations

- Operation: github.read_issue
- Service: GitHub
- Environment: production
- Executor: Claude
- Approval required: no

## User approvals

None
EOF
}

valid_mapping='## Verification mapping

- AC-1: stage:build, stage:unit-tests
- AC-2: case:iphone-en, case:iphone-ja, visual:iphone-en, visual:iphone-ja

'

body="$workspace/issue.md"
write_issue "$body" "$valid_mapping"
contract_for "$body" > "$workspace/contract.json"

ruby -rjson -e '
  contract = JSON.parse(File.read(ARGV.fetch(0)))
  failures = []
  verification = contract["verification"]
  failures << "contract has no verification object" unless verification.is_a?(Hash)
  if verification.is_a?(Hash)
    expected_keys = %w[acceptanceMappings bundleIdentifier cases unitTestIdentifier]
    failures << "verification keys are #{verification.keys.sort.inspect}" unless verification.keys.sort == expected_keys

    identifier = %r{\A[A-Za-z0-9_]+/[A-Za-z0-9_]+/[A-Za-z0-9_]+(?:\(\))?\z}
    failures << "bundleIdentifier is invalid" unless verification["bundleIdentifier"].to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9.-]*\z/)
    failures << "unitTestIdentifier is invalid" unless verification["unitTestIdentifier"].to_s.match?(identifier)

    expected_case_ids = %w[iphone-en iphone-ja ipad-en ipad-ja]
    cases = verification["cases"]
    if cases.is_a?(Array) && cases.length == 4
      cases.each_with_index do |entry, index|
        failures << "cases[#{index}].id is wrong" unless entry.is_a?(Hash) && entry["id"] == expected_case_ids.fetch(index)
        keys = entry.is_a?(Hash) ? entry.keys.sort : []
        if keys == %w[id testIdentifier]
          failures << "cases[#{index}].testIdentifier is invalid" unless entry["testIdentifier"].to_s.match?(identifier)
        elsif keys == %w[assertion id]
          failures << "cases[#{index}].assertion is invalid" unless entry["assertion"] == {"kind" => "launch-succeeded"}
        else
          failures << "cases[#{index}] must carry exactly one action"
        end
      end
    else
      failures << "cases must contain the exact four ordered case IDs"
    end

    # The mapping must be exactly what the Issue declared, never a synthesized default.
    expected_mappings = [
      {"id" => "AC-1", "checks" => ["stage:build", "stage:unit-tests"]},
      {"id" => "AC-2", "checks" => ["case:iphone-en", "case:iphone-ja", "visual:iphone-en", "visual:iphone-ja"]}
    ]
    failures << "acceptanceMappings are #{verification["acceptanceMappings"].inspect}" unless verification["acceptanceMappings"] == expected_mappings
  end
  unless failures.empty?
    warn failures.join("\n")
    exit 1
  end
' "$workspace/contract.json"

assert_rejected() {
  local label=$1 mapping=$2
  local path="$workspace/rejected.md"
  write_issue "$path" "$mapping"
  if contract_for "$path" >/dev/null 2>&1; then
    echo "expected rejection: $label" >&2
    exit 1
  fi
}

assert_rejected "missing AC" '## Verification mapping

- AC-1: stage:build

'
assert_rejected "out-of-order AC" '## Verification mapping

- AC-2: stage:build
- AC-1: stage:build

'
assert_rejected "unknown check" '## Verification mapping

- AC-1: stage:build
- AC-2: case:iphone-xx

'
assert_rejected "non-canonical check order" '## Verification mapping

- AC-1: stage:unit-tests, stage:build
- AC-2: stage:build

'
assert_rejected "duplicate check" '## Verification mapping

- AC-1: stage:build, stage:build
- AC-2: stage:build

'
assert_rejected "visual-only mapping without an execution check" '## Verification mapping

- AC-1: visual:iphone-en
- AC-2: stage:build

'

# An Issue without the section runs no application verification and carries no object.
absent="$workspace/issue-absent.md"
write_issue "$absent" ""
contract_for "$absent" > "$workspace/contract-absent.json"
ruby -rjson -e '
  contract = JSON.parse(File.read(ARGV.fetch(0)))
  if contract.key?("verification")
    warn "contract without a mapping must not carry a verification object"
    exit 1
  end
' "$workspace/contract-absent.json"

# Not applicable is the explicit form of the same declaration.
not_applicable="$workspace/issue-not-applicable.md"
write_issue "$not_applicable" '## Verification mapping

Not applicable

'
contract_for "$not_applicable" > "$workspace/contract-not-applicable.json"
ruby -rjson -e '
  contract = JSON.parse(File.read(ARGV.fetch(0)))
  if contract.key?("verification")
    warn "Not applicable must not carry a verification object"
    exit 1
  end
' "$workspace/contract-not-applicable.json"

# A declared mapping requires the repository configuration; absence fails closed.
rm -f "$configuration"
if contract_for "$body" >/dev/null 2>&1; then
  echo "expected rejection: declared mapping without a configuration" >&2
  exit 1
fi
# An Issue that declares no mapping still needs no configuration.
contract_for "$absent" >/dev/null
validate_for "$absent" >/dev/null
cp "$repo_root/Config/verification.json" "$configuration"

assert_rejected_configuration() {
  local label=$1 payload=$2
  printf '%s' "$payload" > "$configuration"
  if contract_for "$body" >/dev/null 2>&1; then
    echo "expected rejection: $label" >&2
    exit 1
  fi
  cp "$repo_root/Config/verification.json" "$configuration"
}

assert_rejected_configuration "unordered case IDs" '{"schemaVersion":1,"bundleIdentifier":"com.example.App","unitTestIdentifier":"A/B/c","cases":[{"id":"ipad-en","testIdentifier":"A/B/c"},{"id":"iphone-ja","testIdentifier":"A/B/c"},{"id":"iphone-en","testIdentifier":"A/B/c"},{"id":"ipad-ja","testIdentifier":"A/B/c"}]}'
assert_rejected_configuration "invalid unit test identifier" '{"schemaVersion":1,"bundleIdentifier":"com.example.App","unitTestIdentifier":"nope","cases":[{"id":"iphone-en","testIdentifier":"A/B/c"},{"id":"iphone-ja","testIdentifier":"A/B/c"},{"id":"ipad-en","testIdentifier":"A/B/c"},{"id":"ipad-ja","testIdentifier":"A/B/c"}]}'
assert_rejected_configuration "unknown key" '{"schemaVersion":1,"bundleIdentifier":"com.example.App","unitTestIdentifier":"A/B/c","cases":[{"id":"iphone-en","testIdentifier":"A/B/c"},{"id":"iphone-ja","testIdentifier":"A/B/c"},{"id":"ipad-en","testIdentifier":"A/B/c"},{"id":"ipad-ja","testIdentifier":"A/B/c"}],"extra":true}'
assert_rejected_configuration "malformed JSON" 'not json'

# The Ruby identifier rules must match tools/validate-verify-json.swift exactly, or Claim
# seals a contract the Swift validator rejects before Build.
assert_rejected_configuration "single-component bundle identifier" '{"schemaVersion":1,"bundleIdentifier":"App","unitTestIdentifier":"A/B/c","cases":[{"id":"iphone-en","testIdentifier":"A/B/c"},{"id":"iphone-ja","testIdentifier":"A/B/c"},{"id":"ipad-en","testIdentifier":"A/B/c"},{"id":"ipad-ja","testIdentifier":"A/B/c"}]}'
assert_rejected_configuration "digit-leading test identifier component" '{"schemaVersion":1,"bundleIdentifier":"com.example.App","unitTestIdentifier":"1A/B/c","cases":[{"id":"iphone-en","testIdentifier":"A/B/c"},{"id":"iphone-ja","testIdentifier":"A/B/c"},{"id":"ipad-en","testIdentifier":"A/B/c"},{"id":"ipad-ja","testIdentifier":"A/B/c"}]}'

# A configuration swapped between Claim sealing the digest and the producer reading the
# file must be rejected rather than sealed.
sealed_digest="sha256:$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$configuration")"
printf '%s' '{"schemaVersion":1,"bundleIdentifier":"com.attacker.App","unitTestIdentifier":"A/B/c","cases":[{"id":"iphone-en","testIdentifier":"A/B/c"},{"id":"iphone-ja","testIdentifier":"A/B/c"},{"id":"ipad-en","testIdentifier":"A/B/c"},{"id":"ipad-ja","testIdentifier":"A/B/c"}]}' > "$configuration"
if ruby "$repo_root/tools/lib/issue-contract.rb" \
     --verification-config "$configuration" --verification-config-digest "$sealed_digest" \
     --body "$body" --type feature --format contract \
     --issue 1 --repo owner/repo --fetched-at 2026-01-01T00:00:00Z >/dev/null 2>&1; then
  echo "expected rejection: configuration swapped after the digest was sealed" >&2
  exit 1
fi
cp "$repo_root/Config/verification.json" "$configuration"

# An Issue without a mapping must not be blocked by an unrelated broken configuration.
printf '%s' 'not json' > "$configuration"
contract_for "$absent" >/dev/null
cp "$repo_root/Config/verification.json" "$configuration"

# fast delivery profile and a declared mapping are mutually exclusive.
fast_body="$workspace/issue-fast.md"
write_issue "$fast_body" "$valid_mapping"
ruby -e '
  path = ARGV.fetch(0)
  text = File.read(path)
  text.sub!(/## UI verification\n\n(?:- .*\n)+/, "## UI verification\n\nNot applicable\n") or abort "UI block not found"
  text.sub!("## Verification mapping", "## Delivery profile\n\n- Profile: fast\n- Reason: Local non-UI logic.\n\n## Verification mapping") or abort "mapping heading not found"
  File.write(path, text)
' "$fast_body"
if contract_for "$fast_body" >/dev/null 2>&1; then
  echo "expected rejection: fast profile with a Verification mapping" >&2
  exit 1
fi

echo "issue contract verification tests passed"
