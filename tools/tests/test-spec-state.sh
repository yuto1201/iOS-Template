#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

checker=.agents/skills/spec-workflow/scripts/check-spec-state.sh
fixture_dir="$repo_root/.artifacts/spec-state-test-$$"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir"

write_issue() {
  local name=$1
  local destination=$2
  printf '[Specification](%s)\n' "$destination" > "$fixture_dir/$name.md"
}

expect_ready() {
  local issue=$1
  local output
  output=$("$checker" "$fixture_dir/$issue.md")
  if [[ "$output" != 'Referenced specification sections are implementation-ready.' ]]; then
    echo "Specification state checker changed its success output: $output" >&2
    exit 1
  fi
}

expect_rejected() {
  local issue=$1
  local expected=$2
  local output
  if output=$("$checker" "$fixture_dir/$issue.md" 2>&1); then
    echo "Specification state checker accepted $issue" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "Specification state checker rejected $issue for the wrong reason: $output" >&2
    exit 1
  fi
}

# Mutation caught: removing document-level validation would accept the anchored
# confirmed section even though the specification as a whole is only proposed.
cat > "$fixture_dir/document-proposed.md" <<'EOF'
# Proposed specification

Status: 提案

## Confirmed section

Status: 確定
EOF
write_issue document-proposed-issue "$fixture_dir/document-proposed.md#confirmed-section"
write_issue document-proposed-whole "$fixture_dir/document-proposed.md"
expect_rejected document-proposed-issue 'document is not confirmed (提案)'
expect_rejected document-proposed-whole 'document is not confirmed (提案)'

cat > "$fixture_dir/document-confirmed.md" <<'EOF'
# Confirmed specification

Status: 確定

The prose mentions `Status: 未決`, but does not declare metadata.

```markdown
Status: 提案
## Hidden heading
Status: 未決
```

## Inherited section

This section inherits the confirmed document state.

## Confirmed section

Status: 確定
EOF
write_issue no-anchor-confirmed "$fixture_dir/document-confirmed.md"
write_issue anchor-inherited "$fixture_dir/document-confirmed.md#inherited-section"
write_issue anchor-confirmed "$fixture_dir/document-confirmed.md#confirmed-section"
expect_ready no-anchor-confirmed
expect_ready anchor-inherited
expect_ready anchor-confirmed

cat > "$fixture_dir/document-mixed.md" <<'EOF'
# Mixed specification

Status: 確定

## Proposed child

Status: 提案
EOF
write_issue document-mixed-whole "$fixture_dir/document-mixed.md"
expect_rejected document-mixed-whole 'section is not confirmed (提案)'

for state in 未決 提案 廃止; do
  cat > "$fixture_dir/document-$state.md" <<EOF
# Specification

Status: $state

## Section

Ready-looking prose.
EOF
  write_issue "document-$state-issue" "$fixture_dir/document-$state.md#section"
  expect_rejected "document-$state-issue" "document is not confirmed ($state)"
done

cat > "$fixture_dir/document-unknown.md" <<'EOF'
# Specification

Status: 承認済み

## Section
EOF
write_issue document-unknown-issue "$fixture_dir/document-unknown.md#section"
expect_rejected document-unknown-issue 'document has unknown canonical Status (承認済み)'

cat > "$fixture_dir/document-missing.md" <<'EOF'
# Specification

The phrase Status: 確定 appears in prose, not as canonical metadata.

```text
Status: 確定
```

## Section
EOF
write_issue document-missing-issue "$fixture_dir/document-missing.md#section"
expect_rejected document-missing-issue 'document has no canonical Status'

cat > "$fixture_dir/document-duplicate.md" <<'EOF'
# Specification

Status: 確定
Status: 確定

## Section
EOF
write_issue document-duplicate-issue "$fixture_dir/document-duplicate.md#section"
expect_rejected document-duplicate-issue 'document has ambiguous canonical Status'

cat > "$fixture_dir/document-conflicting.md" <<'EOF'
# Specification

Status: 確定
Status: 提案

## Section
EOF
write_issue document-conflicting-issue "$fixture_dir/document-conflicting.md#section"
expect_rejected document-conflicting-issue 'document has ambiguous canonical Status'

for state in 未決 提案 廃止; do
  cat > "$fixture_dir/section-$state.md" <<EOF
# Specification

Status: 確定

## Section

Status: $state
EOF
  write_issue "section-$state-issue" "$fixture_dir/section-$state.md#section"
  expect_rejected "section-$state-issue" "section is not confirmed ($state)"
done

cat > "$fixture_dir/section-unknown.md" <<'EOF'
# Specification

Status: 確定

## Section

Status: 承認済み
EOF
write_issue section-unknown-issue "$fixture_dir/section-unknown.md#section"
expect_rejected section-unknown-issue 'section has unknown canonical Status (承認済み)'

cat > "$fixture_dir/section-duplicate.md" <<'EOF'
# Specification

Status: 確定

## Section

Status: 確定
Status: 確定
EOF
write_issue section-duplicate-issue "$fixture_dir/section-duplicate.md#section"
expect_rejected section-duplicate-issue 'section has ambiguous canonical Status'

# The current specification format, both whole-document and anchored, remains
# accepted. This also covers the Markdown hard-break spaces after 確定.
printf '%s\n' '[Product](specs/product.md)' > "$fixture_dir/current-specs.md"
printf '%s\n' '[Architecture](specs/architecture.md#21-identity-bootstrap境界)' >> "$fixture_dir/current-specs.md"
printf '%s\n' '[Acceptance](specs/acceptance.md#2-issue-definition-of-ready)' >> "$fixture_dir/current-specs.md"
expect_ready current-specs

printf '%s\n' 'No specification reference.' > "$fixture_dir/unlinked.md"
expect_rejected unlinked 'Issue body has no local Markdown specification reference'

echo "Specification state checker tests passed"
