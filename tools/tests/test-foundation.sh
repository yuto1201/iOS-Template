#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

required_files=(
  AGENTS.md
  README.md
  specs/product.md
  specs/architecture.md
  specs/acceptance.md
  specs/decisions.md
  docs/AUTHORITY.md
  .gitignore
  Config/Public.xcconfig
  Config/Local.xcconfig.example
  Config/ownership.yml
  Config/template-identity.json
  tools/bootstrap-app.sh
  tools/bootstrap-app.swift
  tools/tests/test-app-bootstrap.sh
  tools/check-markdown-links.swift
  .agents/skills/app-bootstrap/SKILL.md
  .agents/skills/spec-workflow/SKILL.md
  .agents/skills/spec-workflow/templates/decision.md
  .agents/skills/spec-workflow/scripts/check-spec-state.sh
)

evaluator_agents=(
  spec-reviewer
  ios-reviewer
  acceptance-auditor
  release-auditor
)

for agent in "${evaluator_agents[@]}"; do
  required_files+=(
    "docs/agent-contracts/$agent.md"
    ".codex/agents/$agent.toml"
    ".claude/agents/$agent.md"
  )
done

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "missing required foundation file: $file" >&2
    exit 1
  fi
done

if [[ -e CLAUDE.md ]] || git ls-files --error-unmatch CLAUDE.md >/dev/null 2>&1; then
  echo "CLAUDE.md must not exist or be tracked" >&2
  exit 1
fi

while IFS= read -r -d '' tracked_file; do
  case "/$tracked_file" in
    */CLAUDE.md|*/xcuserdata/*|*/DerivedData/*|*/.artifacts/*|*/.worktrees/*|*/Config/Local.xcconfig|*.p8|*.mobileprovision|*/supabase/.temp/*|*/supabase/.branches/*)
      echo "forbidden local or secret artifact is tracked: $tracked_file" >&2
      exit 1
      ;;
    */.env|*/.env.*)
      if [[ "$tracked_file" != ".env.example" ]]; then
        echo "forbidden environment file is tracked: $tracked_file" >&2
        exit 1
      fi
      ;;
  esac
done < <(git ls-files -z)

ignored_paths=(
  .artifacts/example.json
  .worktrees/example
  DerivedData/example
  Config/Local.xcconfig
  AuthKey_example.p8
  .env
  supabase/.temp/example
  supabase/.branches/example
)

for path in "${ignored_paths[@]}"; do
  rule_source=$(git check-ignore -v -- "$path" | cut -d: -f1)
  if [[ "$rule_source" != ".gitignore" ]]; then
    echo "path is not ignored by the repository .gitignore: $path" >&2
    exit 1
  fi
done

if git check-ignore -q -- .env.example; then
  echo ".env.example must remain trackable" >&2
  exit 1
fi

ruby -ryaml -rjson -e '
  data = YAML.safe_load(File.read("Config/ownership.yml"), permitted_classes: [], aliases: false)
  abort "unexpected schema version" unless data["schemaVersion"] == 1
  abort "unexpected GitHub login" unless data.dig("github", "login") == "yuto1201"
  abort "unexpected Supabase organization" unless data.dig("supabase", "organization") == "YUTO1201"
  %w[projectRef].each { |key| abort "#{key} must be null" unless data.dig("supabase", key).nil? }
  abort "Cloudflare accountId must be null" unless data.dig("cloudflare", "accountId").nil?
  abort "App Store teamId must be null" unless data.dig("appStore", "teamId").nil?
  if File.exist?("Config/app-identity.json")
    identity = JSON.parse(File.read("Config/app-identity.json"))
    abort "unexpected app identity schema version" unless identity["schemaVersion"] == 1
    abort "app identity bundleId is missing" unless identity["bundleId"].is_a?(String) && !identity["bundleId"].empty?
    abort "ownership and app identity bundleId differ" unless data.dig("appStore", "bundleId") == identity["bundleId"]
  else
    abort "App Store bundleId must be null before identity bootstrap" unless data.dig("appStore", "bundleId").nil?
  end
'

ruby -rjson -e '
  manifest = JSON.parse(File.read("Config/template-identity.json"))
  abort "unexpected identity manifest schema version" unless manifest["schemaVersion"] == 1
  abort "identity manifest source is missing" unless manifest["source"].is_a?(Hash)
  abort "identity manifest rename paths are missing" unless manifest["renamePaths"].is_a?(Array) && !manifest["renamePaths"].empty?
  abort "identity manifest live content paths are missing" unless manifest["liveContentPaths"].is_a?(Array) && !manifest["liveContentPaths"].empty?
'

if [[ ! -x tools/bootstrap-app.sh ]]; then
  echo "App bootstrap command must be executable" >&2
  exit 1
fi

if [[ ! -r tools/bootstrap-app.swift ]] || [[ ! -r tools/tests/test-app-bootstrap.sh ]]; then
  echo "App bootstrap implementation and tests must be readable" >&2
  exit 1
fi

app_bootstrap_skill=.agents/skills/app-bootstrap/SKILL.md
ruby -ryaml - "$app_bootstrap_skill" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
frontmatter = text.match(/\A---\n(.*?)\n---\n/m)&.captures&.first
abort "missing app bootstrap skill frontmatter" unless frontmatter
data = YAML.safe_load(frontmatter, permitted_classes: [], aliases: false)
abort "unexpected app bootstrap skill name" unless data["name"] == "app-bootstrap"
abort "missing app bootstrap skill description" unless data["description"].is_a?(String) && !data["description"].strip.empty?
RUBY

python3 - <<'PYTHON'
from pathlib import Path

for path in (Path(".agents/skills/app-bootstrap/SKILL.md"), Path("README.md")):
    content = path.read_text()
    lines = {line.strip() for line in content.splitlines()}
    missing = []
    if "git status --short --untracked-files=all" not in lines:
        missing.append("complete status")
    if "git diff --" not in lines:
        missing.append("tracked diff")
    if "git ls-files --others --exclude-standard -z" not in content:
        missing.append("NUL-delimited untracked listing")
    if not any(line.startswith('git diff --no-index -- /dev/null "$path"') for line in lines):
        missing.append("per-untracked-file diff")
    if missing:
        raise SystemExit(f"{path} lacks complete read-only bootstrap inspection: {missing!r}")
    if "git add" in content:
        raise SystemExit(f"{path} must not stage bootstrap output during inspection")

readme = Path("README.md").read_text()
if ".artifacts/DerivedData" in readme:
    raise SystemExit("README uses repository-local DerivedData")
if "mktemp -d /tmp/ios-template-derived-data.XXXXXX" not in readme:
    raise SystemExit("README does not create repository-external DerivedData")
if "mktemp -d /tmp/ios-template-result-bundles.XXXXXX" not in readme:
    raise SystemExit("README does not create repository-external result-bundle storage")

derived_data_lines = [line for line in readme.splitlines() if "-derivedDataPath" in line]
result_bundle_lines = [line for line in readme.splitlines() if "-resultBundlePath" in line]
if not derived_data_lines or any('"${TEMPLATE_DERIVED_DATA}"' not in line for line in derived_data_lines):
    raise SystemExit("README has a DerivedData path outside the external temporary directory")
if len(result_bundle_lines) != len(derived_data_lines):
    raise SystemExit("README must pair every Xcode test example with an external result bundle")
if any('"${TEMPLATE_RESULT_BUNDLES}/' not in line for line in result_bundle_lines):
    raise SystemExit("README has a result bundle outside the external temporary directory")
PYTHON

claude_app_bootstrap_skill=.claude/skills/app-bootstrap
expected_app_bootstrap_target=../../.agents/skills/app-bootstrap
if [[ ! -L "$claude_app_bootstrap_skill" ]]; then
  echo "Claude app bootstrap skill must be a symbolic link" >&2
  exit 1
fi
if [[ $(readlink "$claude_app_bootstrap_skill") != "$expected_app_bootstrap_target" ]]; then
  echo "Claude app bootstrap skill must use the portable relative target" >&2
  exit 1
fi
if [[ ! -f "$claude_app_bootstrap_skill/SKILL.md" ]]; then
  echo "Claude app bootstrap skill link does not resolve" >&2
  exit 1
fi

bootstrap_validation=$(swift tools/bootstrap-app.swift validate \
  --manifest Config/template-identity.json \
  --display-name 'Garden Notes' \
  --module-name GardenNotes \
  --app-slug garden-notes \
  --bundle-id com.yuto.GardenNotes)
ruby -rjson -e '
  result = JSON.parse(ARGV.fetch(0))
  expected = {
    "appSlug" => "garden-notes",
    "bundleId" => "com.yuto.GardenNotes",
    "displayName" => "Garden Notes",
    "moduleName" => "GardenNotes"
  }
  abort "unexpected bootstrap validation result" unless result == expected
' "$bootstrap_validation"

if [[ ! -x tools/check-markdown-links.swift ]]; then
  echo "Markdown link checker must be executable" >&2
  exit 1
fi

spec_checker=.agents/skills/spec-workflow/scripts/check-spec-state.sh
if [[ ! -x "$spec_checker" ]]; then
  echo "Specification state checker must be executable" >&2
  exit 1
fi

claude_skill=.claude/skills/spec-workflow
expected_skill_target=../../.agents/skills/spec-workflow
if [[ ! -L "$claude_skill" ]]; then
  echo "Claude specification skill must be a symbolic link" >&2
  exit 1
fi
if [[ $(readlink "$claude_skill") != "$expected_skill_target" ]]; then
  echo "Claude specification skill must use the portable relative target" >&2
  exit 1
fi
if [[ ! -f "$claude_skill/SKILL.md" ]]; then
  echo "Claude specification skill link does not resolve" >&2
  exit 1
fi

for agent in "${evaluator_agents[@]}"; do
  codex_agent=".codex/agents/$agent.toml"
  claude_agent=".claude/agents/$agent.md"
  contract="docs/agent-contracts/$agent.md"

  if ! grep -Fqx "name = \"$agent\"" "$codex_agent"; then
    echo "Codex evaluator has an unexpected name: $codex_agent" >&2
    exit 1
  fi
  if ! grep -Fqx 'sandbox_mode = "read-only"' "$codex_agent"; then
    echo "Codex evaluator must use a read-only sandbox: $codex_agent" >&2
    exit 1
  fi
  if ! grep -Fq "docs/agent-contracts/$agent.md" "$codex_agent"; then
    echo "Codex evaluator does not reference its shared contract: $codex_agent" >&2
    exit 1
  fi
  python3 - "$codex_agent" "$agent" <<'PYTHON'
import pathlib
import sys
import tomllib

path = pathlib.Path(sys.argv[1])
expected_name = sys.argv[2]
with path.open("rb") as file:
    data = tomllib.load(file)
if data.get("name") != expected_name:
    raise SystemExit(f"unexpected Codex evaluator name: {path}")
if data.get("sandbox_mode") != "read-only":
    raise SystemExit(f"Codex evaluator is not read-only: {path}")
for field in ("description", "developer_instructions"):
    if not isinstance(data.get(field), str) or not data[field].strip():
        raise SystemExit(f"Codex evaluator lacks {field}: {path}")
PYTHON

  ruby -ryaml - "$claude_agent" "$agent" <<'RUBY'
path, expected_name = ARGV
text = File.read(path)
frontmatter = text.match(/\A---\n(.*?)\n---\n/m)&.captures&.first
abort "missing Claude evaluator frontmatter: #{path}" unless frontmatter
data = YAML.safe_load(frontmatter, permitted_classes: [], aliases: false)
abort "unexpected Claude evaluator name: #{path}" unless data["name"] == expected_name
abort "Claude evaluator tools must be exactly Read, Glob, Grep: #{path}" unless data["tools"] == %w[Read Glob Grep]
RUBY

  if ! grep -Fq "docs/agent-contracts/$agent.md" "$claude_agent"; then
    echo "Claude evaluator does not reference its shared contract: $claude_agent" >&2
    exit 1
  fi

  for heading in '## Inputs' '## Ordered checks' '## Finding schema' '## Severity' '## Approval rule' '## Prohibited actions'; do
    if ! grep -Fqx "$heading" "$contract"; then
      echo "Shared evaluator contract lacks $heading: $contract" >&2
      exit 1
    fi
  done
done

fixture_dir=$(mktemp -d)
spec_fixture_dir="$repo_root/.artifacts/spec-workflow-test-$$"
trap 'rm -rf "$fixture_dir" "$spec_fixture_dir"' EXIT
printf '%s\n' '# Target' > "$fixture_dir/target.md"
printf '%s\n' '[Target](target.md)' > "$fixture_dir/valid.md"
printf '%s\n' '[Missing](missing.md)' > "$fixture_dir/invalid.md"

swift tools/check-markdown-links.swift "$fixture_dir/valid.md"
if swift tools/check-markdown-links.swift "$fixture_dir/invalid.md" >/dev/null 2>&1; then
  echo "Markdown link checker accepted a missing local target" >&2
  exit 1
fi

mkdir -p "$spec_fixture_dir"
cat > "$spec_fixture_dir/spec.md" <<'EOF'
# Decisions

## Confirmed choice

Status: 確定

Implementation may rely on this choice.

## Pending choice

Status: 未決

Implementation acceptance depends on this choice.

## Proposed choice

Status: 提案

Implementation acceptance may not rely on this choice yet.
EOF

relative_spec_path=${spec_fixture_dir#"$repo_root/"}/spec.md
printf '[Confirmed](%s#confirmed-choice)\n' "$relative_spec_path" > "$spec_fixture_dir/confirmed-issue.md"
printf '[Pending](%s#pending-choice)\n' "$relative_spec_path" > "$spec_fixture_dir/pending-issue.md"
printf '[Proposed](%s#proposed-choice)\n' "$relative_spec_path" > "$spec_fixture_dir/proposed-issue.md"
printf '%s\n' 'No specification reference.' > "$spec_fixture_dir/unlinked-issue.md"

"$spec_checker" "$spec_fixture_dir/confirmed-issue.md"
if "$spec_checker" "$spec_fixture_dir/pending-issue.md" >/dev/null 2>&1; then
  echo "Specification state checker accepted an unresolved referenced section" >&2
  exit 1
fi
if "$spec_checker" "$spec_fixture_dir/proposed-issue.md" >/dev/null 2>&1; then
  echo "Specification state checker accepted a proposed referenced section" >&2
  exit 1
fi
if "$spec_checker" "$spec_fixture_dir/unlinked-issue.md" >/dev/null 2>&1; then
  echo "Specification state checker accepted an Issue without specification references" >&2
  exit 1
fi

swift tools/check-markdown-links.swift

echo "Foundation repository policy checks passed"
