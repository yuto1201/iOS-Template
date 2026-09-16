#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby

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

# Exercise the public validator as well as the checker with real UTF-8 input.
cat > "$fixture_dir/locale-feature.md" <<'EOF'
## Goal

仕様の状態をロケールに依存せず検証する。

## In scope

- Validate non-UI workflow metadata.

## Out of scope

- Change application behavior.

## Acceptance criteria

- AC-1: UI-direction route: not-applicable; Scope: specification metadata; Reason: no UI changes. Confirmed specifications remain accepted.

## Spec anchors

- [Issue Definition of Ready](specs/acceptance.md#2-issue-definition-of-ready)

## Dependencies

None

## UI verification

Not applicable

## Delivery stage

- Stage: harden
- Time budget: 30 minutes
- Reason: Exercise a single metadata check.

## Delivery profile

- Profile: fast
- Reason: Non-UI local validation fixture.

## External operations

None

## User approvals

None
EOF
for locale_profile in unset C POSIX en_US.UTF-8; do
  locale_command=(env -u LANG -u LC_ALL -u LC_CTYPE)
  if [[ "$locale_profile" != unset ]]; then
    locale_command+=("LANG=$locale_profile" "LC_ALL=$locale_profile" "LC_CTYPE=$locale_profile")
  fi
  output=$("${locale_command[@]}" tools/validate-issue-body.sh --type feature "$fixture_dir/locale-feature.md")
  [[ "$output" == 'Referenced specification sections are implementation-ready.' ]] || {
    echo "public validation changed under locale $locale_profile" >&2; exit 1;
  }
  if output=$("${locale_command[@]}" "$checker" "$fixture_dir/document-proposed-issue.md" 2>&1); then
    echo "proposed specification accepted under locale $locale_profile" >&2; exit 1
  fi
  [[ "$output" == *'document is not confirmed (提案)'* ]] || {
    echo "wrong rejection under locale $locale_profile: $output" >&2; exit 1;
  }
  scrubbed_locale=$("${locale_command[@]}" /bin/bash -c '
    source "$1"
    run_scrubbed /usr/bin/ruby -e "abort unless Encoding.default_external.name == %q(UTF-8); print ENV.fetch(%q(LANG))"
  ' scrubbed-locale "$repo_root/tools/lib/xcode.sh")
  [[ "$scrubbed_locale" == en_US.UTF-8 ]] || {
    echo "trusted scrubbed locale changed under $locale_profile" >&2; exit 1;
  }
done

# Check source parsing independently of Ruby's default external string encoding.
# In particular, -E UTF-8 alone does not set stdin source encoding on system Ruby.
ruby -ropen3 -rrbconfig - <<'RUBY'
paths, status = Open3.capture2("git", "ls-files", "-z", "--", "*.sh")
abort "cannot enumerate tracked shell sources" unless status.success?
checked = 0
paths.split("\0").each do |path|
  next unless File.file?(path)
  lines = File.readlines(path)
  lines.each_with_index do |line, index|
    next unless line.include?("<<'RUBY'")
    finish = ((index + 1)...lines.length).find { |i| lines[i].strip == "RUBY" }
    abort "unterminated Ruby source: #{path}:#{index + 1}" unless finish
    source = lines[(index + 1)...finish].join
    next if source.ascii_only?
    output, result = Open3.capture2e(
      {"LANG" => "C", "LC_ALL" => "C", "LC_CTYPE" => "C"},
      RbConfig.ruby, "-E", "UTF-8", "-c", stdin_data: source
    )
    abort "non-ASCII Ruby source is locale-dependent: #{path}:#{index + 1}\n#{output}" unless result.success?
    checked += 1
  end
end
abort "no non-ASCII Ruby sources were checked" if checked.zero?
RUBY

# Phase routing is consumer-visible: new Issue forms tell planners where the
# canonical binding lives, while planning, shipping, bootstrap, and verification
# skills preserve the same release/revision/phase identity without inventing a
# mutable field or retrofitting legacy contracts.
ruby - <<'RUBY'
forms = %w[
  .github/ISSUE_TEMPLATE/feature.yml
  .github/ISSUE_TEMPLATE/regression.yml
  .github/ISSUE_TEMPLATE/release.yml
]
forms.each do |path|
  text = File.binread(path)
  abort "Issue form lacks Release-phase binding guidance: #{path}" unless text.include?("Release-phase binding:")
end

skills = %w[
  .agents/skills/plan-issue-batch/SKILL.md
  .agents/skills/ship-issue/SKILL.md
  .agents/skills/ship-issue-batch/SKILL.md
  .agents/skills/app-bootstrap/SKILL.md
  .agents/skills/ios-verify/SKILL.md
]
skills.each do |path|
  text = File.binread(path)
  abort "workflow skill lacks release-phase routing: #{path}" unless
    text.include?("Release-phase binding:") && text.include?("legacy-unbound")
end

ship = File.binread(".agents/skills/ship-issue/SKILL.md")
abort "ship skill bypasses canonical Claim validation" unless ship.include?("tools/claim-issue.sh") && ship.include?("implementation")
batch = File.binread(".agents/skills/ship-issue-batch/SKILL.md")
abort "batch skill lacks phase ordering" unless batch.include?("previous Phase") && batch.include?("read-only")
abort "batch skill lacks Mac-wide/session Simulator routing" unless
  batch.include?("Mac-wide resource manager") && batch.include?("four total") && batch.include?("per inherited session")
bootstrap = File.binread(".agents/skills/app-bootstrap/SKILL.md")
abort "bootstrap does not route its four Simulator cases through shared ownership" unless
  bootstrap.include?("tools/with-ios-simulator-lock.sh") &&
  bootstrap.include?("tools/lib/ios-simulator-resource.rb") &&
  bootstrap.include?("one device at a time") &&
  bootstrap.include?("Mac-wide cap remains four")
workflow = File.binread("docs/workflow.md").force_encoding(Encoding::UTF_8)
%w[proposed approved claimed in-progress paused blocked:* superseded done].each do |state|
  abort "workflow migration lacks #{state} handling" unless workflow.include?("`#{state}`")
end
abort "workflow migration does not preserve a sealed binding" unless
  workflow.include?("Release-phase binding:") &&
  workflow.include?("\u4fdd\u8b77\u5bfe\u8c61") &&
  workflow.include?("legacy-unbound") &&
  workflow.include?("successor")
[
  ".agents/skills/ios-verify/SKILL.md",
  "docs/workflow.md",
  "specs/development-stages.md"
].each do |path|
  text = File.binread(path).force_encoding(Encoding::UTF_8)
  abort "workflow-only App Store boundary is stale: #{path}" unless
    text.include?("local") && text.include?("allowlist") &&
    text.include?("metadata") && text.include?("operation")
end
verify = File.binread(".agents/skills/ios-verify/SKILL.md")
%w[Phase\ 3 Phase\ 4 Phase\ 5 Phase\ 6 evidence-applicability.json].each do |required|
  abort "verification skill lacks #{required}" unless verify.include?(required.gsub("\\ ", " "))
end
RUBY

# Reuse the canonical phase engine regression instead of duplicating its
# fixtures. It covers normal progression, the Phase 3 implementation gate,
# minor and major backtracking, unclassified/independent lanes, and emergency
# reuse while the assertions above verify the user-facing consumers.
ruby tools/lib/workflow-release-phase-test.rb

printf '%s\n' 'No specification reference.' > "$fixture_dir/unlinked.md"
expect_rejected unlinked 'Issue body has no local Markdown specification reference'

echo "Specification state checker tests passed"
