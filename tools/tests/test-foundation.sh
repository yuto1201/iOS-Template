#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"
ignore_probe_root=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-ignore-probe.XXXXXX")
trap 'rm -rf -- "$ignore_probe_root"' EXIT
cp .gitignore "$ignore_probe_root/.gitignore"
git_dir=$(git rev-parse --absolute-git-dir)

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
  tools/publish-documentation-verify.sh
  tools/verify-fast-issue.sh
  tools/lib/delivery-profile.rb
  tools/run-repository-tests.sh
  tools/lib/run-repository-tests.rb
  tools/tests/test-repository-test-evidence.sh
  tools/lib/review-receipt.rb
  tools/lib/validate-review-receipt.rb
  tools/with-ios-simulator-lock.sh
  .agents/skills/app-bootstrap/SKILL.md
  .agents/skills/cross-model-review/SKILL.md
  .agents/skills/ios-verify/SKILL.md
  .agents/skills/spec-workflow/SKILL.md
  .agents/skills/spec-workflow/templates/decision.md
  .agents/skills/spec-workflow/scripts/check-spec-state.sh
  .agents/skills/supabase-ops/SKILL.md
  .agents/skills/supabase-ops/scripts/activate.sh
  .agents/skills/supabase-ops/scripts/validate-migrations.sh
  .agents/skills/ios-media-assets/SKILL.md
  .agents/skills/ios-media-assets/references/audio-and-speech.md
  .agents/skills/ios-media-assets/references/image-and-video.md
  .agents/skills/ios-media-assets/scripts/check-elevenlabs-capability.sh
  .agents/skills/ios-media-assets/scripts/validate-audio.sh
  .agents/skills/ios-media-assets/scripts/validate-transcript.sh
  .agents/skills/ios-media-assets/scripts/validate-visual.sh
  .agents/skills/ios-media-assets/scripts/inspect-visual.swift
  .agents/skills/prepare-appstore-assets/SKILL.md
  .agents/skills/prepare-appstore-assets/scripts/seal-package.sh
  .agents/skills/submit-appstore-release/SKILL.md
  .agents/skills/submit-appstore-release/scripts/record-section.sh
  docs/agent-contracts/appstore-submission.md
  "App Store/README.md"
  "App Store/submission/requirements.json"
  "App Store/screenshots/states.json"
  tools/secret-store.sh
  tools/run-with-secret.sh
  tools/run-with-private-key.sh
  tools/provider-preflight.sh
  tools/validate-appstore-package.sh
  tools/capture-appstore-screenshots.sh
  tools/build-appstore-screenshot-set.sh
  tools/tests/test-secret-store.sh
  tools/tests/test-provider-preflight.sh
  tools/tests/test-supabase-skill.sh
  tools/tests/test-media-skill.sh
  tools/tests/test-appstore-package.sh
  tools/tests/test-appstore-screenshots.sh
  tools/tests/test-appstore-skills.sh
)

shipping_skills=(
  plan-issue-batch
  ship-issue
  ship-issue-batch
  external-ops
)

integration_skills=(
  supabase-ops
  ios-media-assets
  prepare-appstore-assets
  submit-appstore-release
)

for skill in "${shipping_skills[@]}"; do
  required_files+=(".agents/skills/$skill/SKILL.md")
done

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

for removed in \
  .claude/hooks/guard-external-ops.sh \
  .agents/skills/codex-external-ops/SKILL.md \
  .claude/skills/codex-external-ops \
  tools/request-codex-op.sh \
  tools/validate-codex-op-request.sh \
  tools/lib/codex-external-op-instruction.md \
  tools/tests/test-claude-guard.sh \
  tools/tests/test-codex-op-transport.sh; do
  [[ ! -e "$removed" && ! -L "$removed" ]] || { echo "obsolete model-specific authority path remains: $removed" >&2; exit 1; }
done

ruby -rjson -e '
  settings=JSON.parse(File.binread(".claude/settings.json"))
  abort "Claude settings must retain only the shared SessionStart instruction loader" unless settings.keys == ["hooks"] && settings.dig("hooks")&.keys == ["SessionStart"]
'

model_neutral_authority_files=(
  README.md
  AGENTS.md
  .agents/skills/app-bootstrap/SKILL.md
  .agents/skills/plan-issue-batch/SKILL.md
  .agents/skills/ios-verify/SKILL.md
  .claude/agents/release-auditor.md
  specs/README.md
  specs/architecture.md
  specs/acceptance.md
  docs/AUTHORITY.md
  docs/security.md
  docs/workflow.md
)
if rg -n -i 'codex-only|codex only|delegate(d)? to codex|delegated to codex|codexへ委託|codex専用|Codexが次を手動で実行|never run .*from claude|do not create .*from a claude' "${model_neutral_authority_files[@]}"; then
  echo 'active instructions must not retain model-specific external authority restrictions' >&2
  exit 1
fi
if rg -n 'CodexOperationTransport|run-codex-transport|Codex result' tools/lib/workflow-json.rb; then
  echo 'obsolete Codex-only external operation transport must not remain in shared workflow code' >&2
  exit 1
fi

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
  .secrets/example
  secret-staging/example
)

for path in "${ignored_paths[@]}"; do
  rule_source=$(git --git-dir="$git_dir" --work-tree="$ignore_probe_root" check-ignore --no-index -v -- "$path" | cut -d: -f1)
  if [[ "$rule_source" != ".gitignore" ]]; then
    echo "path is not ignored by the repository .gitignore: $path" >&2
    exit 1
  fi
done

if git --git-dir="$git_dir" --work-tree="$ignore_probe_root" check-ignore --no-index -q -- .env.example; then
  echo ".env.example must remain trackable" >&2
  exit 1
fi

for skill in "${integration_skills[@]}"; do
  shared_skill=".agents/skills/$skill/SKILL.md"
  claude_skill=".claude/skills/$skill"
  expected_target="../../.agents/skills/$skill"
  ruby -ryaml - "$shared_skill" "$skill" <<'RUBY'
path, expected_name = ARGV
text = File.binread(path)
frontmatter = text.match(/\A---\n(.*?)\n---\n/m)&.captures&.first
abort "missing integration skill frontmatter: #{path}" unless frontmatter
data = YAML.safe_load(frontmatter, permitted_classes: [], aliases: false)
abort "unexpected integration skill name: #{path}" unless data["name"] == expected_name
abort "missing integration skill description: #{path}" unless data["description"].is_a?(String) && !data["description"].strip.empty?
RUBY
  [[ -L "$claude_skill" && $(readlink "$claude_skill") == "$expected_target" && -f "$claude_skill/SKILL.md" ]] || {
    echo "Claude integration skill must be the portable shared symlink: $claude_skill" >&2
    exit 1
  }
done

for executable in \
  tools/secret-store.sh tools/run-with-secret.sh tools/run-with-private-key.sh tools/provider-preflight.sh \
  tools/validate-appstore-package.sh tools/capture-appstore-screenshots.sh tools/build-appstore-screenshot-set.sh \
  .agents/skills/supabase-ops/scripts/activate.sh .agents/skills/supabase-ops/scripts/validate-migrations.sh \
  .agents/skills/ios-media-assets/scripts/check-elevenlabs-capability.sh .agents/skills/ios-media-assets/scripts/validate-audio.sh \
  .agents/skills/ios-media-assets/scripts/validate-transcript.sh .agents/skills/ios-media-assets/scripts/validate-visual.sh \
  .agents/skills/prepare-appstore-assets/scripts/seal-package.sh .agents/skills/submit-appstore-release/scripts/record-section.sh; do
  [[ -x "$executable" ]] || { echo "integration executable is not executable: $executable" >&2; exit 1; }
done

if [[ -e supabase || -L supabase ]]; then
  echo 'Supabase must remain dormant until an app specification explicitly activates it' >&2
  exit 1
fi
if [[ -e .superpowers || -L .superpowers ]]; then
  echo 'Root .superpowers implementation artifacts must not ship in the template' >&2
  exit 1
fi
if git ls-files --error-unmatch Package.swift Package.resolved >/dev/null 2>&1; then
  echo 'Foundation template must not carry a root Swift package dependency surface' >&2
  exit 1
fi
if git grep -n -I -E -- 'Supabase|ElevenLabs|Cloudflare|Firebase|PostHog|Mixpanel|Sentry|StoreKit|UserNotifications|XCRemoteSwiftPackageReference' -- TemplateApp TemplateApp.xcodeproj >/dev/null 2>&1; then
  echo 'TemplateApp contains an integration SDK, entitlement, import, or package reference before activation' >&2
  exit 1
fi

python3 - <<'PYTHON'
from pathlib import Path
import re
import subprocess

paths = subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0")
files = [Path(value.decode()) for value in paths if value]
token_patterns = (
    re.compile(rb"ghp_[A-Za-z0-9]{12,}"),
    re.compile(rb"github_pat_[A-Za-z0-9_]{12,}"),
    re.compile(rb"glpat-[A-Za-z0-9_-]{12,}"),
    re.compile(rb"xox[baprs]-[A-Za-z0-9-]{12,}"),
    re.compile(rb"(?:^|[^A-Za-z0-9])sk-(?:proj-)?[A-Za-z0-9_-]{12,}"),
    re.compile(rb"sb_secret_[A-Za-z0-9_-]{12,}"),
    re.compile(rb"AIza[0-9A-Za-z_-]{20,}"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
)
private_key = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")
password_assignment = re.compile(rb"(?i)password\s*=\s*[^\s\"']{6,}")
dedicated_filename = re.compile(rb"Library/Application Support/iOS-Template/secrets/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.(?:p8|pem|key)")
service_role_allowed = {
    ".agents/skills/ios-media-assets/scripts/validate-audio.sh",
    ".agents/skills/ios-media-assets/scripts/validate-transcript.sh",
    ".agents/skills/ios-media-assets/scripts/validate-visual.sh",
    ".agents/skills/supabase-ops/SKILL.md",
    ".agents/skills/supabase-ops/scripts/validate-migrations.sh",
    "docs/security.md",
    "docs/superpowers/plans/2026-08-21-integrations-appstore-release.md",
    "specs/product.md",
    "tools/tests/test-foundation.sh",
    "tools/tests/test-supabase-skill.sh",
}
violations = []
service_role_paths = set()
for path in files:
    try:
        data = path.read_bytes()
    except (OSError, IsADirectoryError):
        continue
    if b"\0" in data:
        continue
    name = path.as_posix()
    if b"service_role" in data:
        service_role_paths.add(name)
    for pattern in token_patterns:
        if pattern.search(data):
            violations.append(f"credential token prefix in {name}")
    if private_key.search(data):
        violations.append(f"private-key header in {name}")
    if password_assignment.search(data) and name != "tools/tests/test-visual-review-packet.sh":
        violations.append(f"password assignment in {name}")
    if dedicated_filename.search(data):
        violations.append(f"dedicated secret filename in {name}")
if service_role_paths != service_role_allowed:
    violations.append(f"service_role policy occurrence set changed: {sorted(service_role_paths)!r}")
if violations:
    raise SystemExit("tracked credential scan failed: " + "; ".join(violations))
PYTHON

python3 - <<'PYTHON'
from pathlib import Path

readme = Path("README.md").read_text()
required = (
    "## 条件付き統合と秘密管理",
    ".agents/skills/supabase-ops/SKILL.md",
    ".agents/skills/ios-media-assets/SKILL.md",
    "## App Store リリース素材",
    "App Store/submission/requirements.json",
    "submit-appstore-release",
)
missing = [value for value in required if value not in readme]
if missing:
    raise SystemExit(f"README lacks conditional integration and release guidance: {missing!r}")
PYTHON

ruby -ryaml -rjson -e '
  data = YAML.safe_load(File.read("Config/ownership.yml"), permitted_classes: [], aliases: false)
  abort "unexpected schema version" unless data["schemaVersion"] == 2
  abort "ownership top-level schema differs" unless data.keys.sort == %w[appStore cloudflare elevenlabs github linear schemaVersion supabase vercel].sort
  abort "unexpected GitHub login" unless data.dig("github", "login") == "yuto1201"
  abort "unexpected Supabase organization ID" unless data.dig("supabase", "organizationId") == "kmjpkzaqlewqnypyqwkg"
  abort "unexpected Supabase organization name" unless data.dig("supabase", "organizationName") == "yuto1201#{39.chr}s Org"
  %w[projectRef].each { |key| abort "#{key} must be null" unless data.dig("supabase", key).nil? }
  abort "unexpected Cloudflare account" unless data.dig("cloudflare", "accountId") == "7ea8e713d76506f9e303f58624829aa5" && data.dig("cloudflare", "accountName") == "Yuto Dev" && data.dig("cloudflare", "plan") == "free"
  abort "Cloudflare target must be null" unless data.dig("cloudflare", "target").nil?
  abort "unexpected Linear identity" unless data["linear"] == {"workspaceSlug"=>"yuto33004", "workspaceUrl"=>"https://linear.app/yuto33004", "teamKey"=>"YUT"}
  abort "unexpected Vercel team" unless data.dig("vercel", "teamId") == "team_ANEUn6gVL8dccPaY08wkvxFt" && data.dig("vercel", "teamSlug") == "yuto16" && data.dig("vercel", "plan") == "hobby"
  abort "Vercel projectId must be null" unless data.dig("vercel", "projectId").nil?
  %w[accountId workspaceId].each { |key| abort "ElevenLabs #{key} must be null" unless data.dig("elevenlabs", key).nil? }
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

ios_verify_skill=.agents/skills/ios-verify/SKILL.md
ruby -ryaml - "$ios_verify_skill" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
frontmatter = text.match(/\A---\n(.*?)\n---\n/m)&.captures&.first
abort "missing iOS verification skill frontmatter" unless frontmatter
data = YAML.safe_load(frontmatter, permitted_classes: [], aliases: false)
abort "unexpected iOS verification skill name" unless data["name"] == "ios-verify"
abort "missing iOS verification skill description" unless data["description"].is_a?(String) && !data["description"].strip.empty?
RUBY

claude_ios_verify_skill=.claude/skills/ios-verify
expected_ios_verify_target=../../.agents/skills/ios-verify
if [[ ! -L "$claude_ios_verify_skill" ]]; then
  echo "Claude iOS verification skill must be a symbolic link" >&2
  exit 1
fi
if [[ $(readlink "$claude_ios_verify_skill") != "$expected_ios_verify_target" ]]; then
  echo "Claude iOS verification skill must use the portable relative target" >&2
  exit 1
fi
if [[ ! -f "$claude_ios_verify_skill/SKILL.md" ]]; then
  echo "Claude iOS verification skill link does not resolve" >&2
  exit 1
fi

if [[ ! -x tools/with-ios-simulator-lock.sh ]] || [[ ! -x tools/publish-documentation-verify.sh ]] || [[ ! -x tools/run-repository-tests.sh ]] || [[ ! -x tools/tests/test-repository-test-evidence.sh ]]; then
  echo "verification tools and their evidence tests must be executable" >&2
  exit 1
fi

python3 - <<'PYTHON'
from pathlib import Path

skill = Path(".agents/skills/ios-verify/SKILL.md").read_text()
required = (
    "tools/with-ios-simulator-lock.sh",
    "tools/publish-documentation-verify.sh",
    "No canonical XcodeBuildMCP evidence producer exists",
    "tools/prepare-review-packet.sh",
    "--primary \"$PRIMARY_MODEL\" --issue \"$ISSUE\" --base-sha \"$BASE_SHA\" --head-sha \"$HEAD_SHA\"",
    "printf '%s %s\\n' \"$EVIDENCE\" \"$DIGEST\"",
)
missing = [value for value in required if value not in skill]
if missing:
    raise SystemExit(f"iOS verification skill lacks executable workflow elements: {missing!r}")
if 'executionRoute: "xcodebuild-mcp"' in skill:
    raise SystemExit("iOS verification skill advertises an unsupported MCP evidence route")
if "SHA256_OF_THAT_EXACT_FILE" in skill:
    raise SystemExit("iOS verification skill leaves an unresolved digest placeholder")

review_skill = Path(".agents/skills/cross-model-review/SKILL.md").read_text()
review_required = (
    "tools/prepare-review-packet.sh",
    "--primary \"$PRIMARY_MODEL\" --issue \"$ISSUE\" --base-sha \"$BASE_SHA\" --head-sha \"$HEAD_SHA\"",
    "jq -er '.path'",
    'tools/cross-model-review.sh',
    '--packet "$REVIEW_PACKET"',
    "reviewPacketDigest",
    "review-receipt.json",
)
review_missing = [value for value in review_required if value not in review_skill]
if review_missing:
    raise SystemExit(f"cross-model review skill lacks the sealed v2 producer route: {review_missing!r}")
for path, content in (("ios-verify", skill), ("cross-model-review", review_skill)):
    if "git diff --binary" in content:
        raise SystemExit(f"{path} skill manually produces review.diff")
if "claude --print" in review_skill or "request-codex-review.sh" in review_skill:
    raise SystemExit("cross-model review skill bypasses the canonical review orchestrator")
PYTHON

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

for skill in "${shipping_skills[@]}"; do
  shared_skill=".agents/skills/$skill/SKILL.md"
  claude_shipping_skill=".claude/skills/$skill"
  expected_shipping_target="../../.agents/skills/$skill"

  ruby -ryaml - "$shared_skill" "$skill" <<'RUBY'
path, expected_name = ARGV
text = File.read(path)
frontmatter = text.match(/\A---\n(.*?)\n---\n/m)&.captures&.first
abort "missing shared shipping skill frontmatter: #{path}" unless frontmatter
data = YAML.safe_load(frontmatter, permitted_classes: [], aliases: false)
abort "unexpected shared shipping skill name: #{path}" unless data["name"] == expected_name
description = data["description"]
abort "missing shared shipping skill description: #{path}" unless description.is_a?(String) && description.start_with?("Use when")
RUBY

  if [[ ! -L "$claude_shipping_skill" ]]; then
    echo "Claude shipping skill must be a symbolic link, not a copied directory: $claude_shipping_skill" >&2
    exit 1
  fi
  if [[ $(readlink "$claude_shipping_skill") != "$expected_shipping_target" ]]; then
    echo "Claude shipping skill has a nonportable or incorrect target: $claude_shipping_skill" >&2
    exit 1
  fi
  if [[ ! -f "$claude_shipping_skill/SKILL.md" ]]; then
    echo "Claude shipping skill link does not resolve: $claude_shipping_skill" >&2
    exit 1
  fi
done

python3 - <<'PYTHON'
from pathlib import Path

ship_issue = Path(".agents/skills/ship-issue/SKILL.md").read_text()
required = (
    'ISSUE_WORKTREE="$(git rev-parse --show-toplevel)"',
    'HEAD_SHA="$(git -C "$ISSUE_WORKTREE" rev-parse HEAD)"',
    'tools/issue-state.sh transition --repo "$REPO" --issue "$ISSUE" --from in-progress --to verify-passed --head-sha "$HEAD_SHA"',
    "clears the old durable Head binding",
    "re-resolve the current Issue worktree Head",
)
missing = [value for value in required if value not in ship_issue]
if missing:
    raise SystemExit(f"ship-issue skill lacks current-Head verification binding: {missing!r}")
PYTHON

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

Status: 確定

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
