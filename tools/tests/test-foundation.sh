#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby swift python3
require_test_python_tomllib "$0"

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"
ignore_probe_root=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-ignore-probe.XXXXXX")
trap 'rm -rf -- "$ignore_probe_root"' EXIT
cp .gitignore "$ignore_probe_root/.gitignore"
git_dir=$(git rev-parse --absolute-git-dir)

required_files=(
  AGENTS.md
  docs/README.md
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
  tools/install-app-icon.sh
  tools/validate-app-icon.sh
  tools/inspect-app-icon.swift
  tools/tests/test-app-icon-workflow.sh
  tools/tests/test-ui-direction-skill.sh
  tools/check-markdown-links.swift
  tools/publish-documentation-verify.sh
  tools/verify-fast-issue.sh
  tools/lib/bounded-command.rb
  tools/lib/bounded-command.sh
  tools/lib/delivery-stage.rb
  tools/lib/delivery-profile.rb
  tools/lib/verification-scope.rb
  tools/lib/release-verification.rb
  tools/run-repository-tests.sh
  tools/lib/run-repository-tests.rb
  tools/tests/test-repository-test-evidence.sh
  tools/tests/test-bounded-command.sh
  tools/tests/test-delivery-stages.sh
  tools/lib/review-receipt.rb
  tools/lib/review-route.rb
  tools/lib/validate-review-receipt.rb
  tools/request-grok-review.sh
  tools/tests/test-review-route.sh
  tools/with-ios-simulator-lock.sh
  .github/ISSUE_TEMPLATE/feature.yml
  .github/ISSUE_TEMPLATE/regression.yml
  .github/ISSUE_TEMPLATE/release.yml
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

# #356: these App Store files belong to the app (tools/template-sync/ownership.json), and the template sync
# never brings them into an app that adopted the template (it records Config/template-base.json, D-074). The
# app prepares its own when it releases, so they are required here only in the template itself.
if [[ ! -f Config/template-base.json ]]; then
  required_files+=(
    "App Store/submission/requirements.json"
    "App Store/screenshots/states.json"
  )
fi

workflow_skills=(
  ui-direction
  ios-system-experiences
  plan-issue-batch
  ship-issue
  ship-issue-batch
  external-ops
)

integration_skills=(
  app-feedback
  app-icon
  supabase-ops
  ios-media-assets
  ios-3d-assets
  prepare-appstore-assets
  submit-appstore-release
)

for skill in "${workflow_skills[@]}"; do
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

# D-075: AGENTS.md is the only document at the repository root, and AGENTS.md itself carries the
# root-document rule and the user-approval rule for its own changes.
if [[ -e README.md || -L README.md ]] || git ls-files --error-unmatch README.md >/dev/null 2>&1; then
  echo "the repository root must not have README.md; use docs/README.md (D-075)" >&2
  exit 1
fi
for rule in \
  'リポジトリのルートに置く文書は`AGENTS.md`だけとし、`README.md`を置かない。`README.md`はフォルダ内の説明が必要な場合（例：`docs/README.md`）だけに使う。' \
  '`AGENTS.md`を書き換えるときは、変更する文面をユーザーに示し、merge前に必ず承認を得て、その承認をIssueのコメントに記録する。'; do
  grep -Fq -- "- $rule" AGENTS.md || { echo "AGENTS.md lacks the D-075 rule: $rule" >&2; exit 1; }
done

xcode_library="$repo_root/tools/lib/xcode.sh"
zsh_bounded_command=$(/bin/zsh -c 'source "$1"; print -r -- "$BOUNDED_COMMAND_PATH"' xcode-library "$xcode_library")
[[ "$zsh_bounded_command" == "$repo_root/tools/lib/bounded-command.rb" ]] || {
  echo "Xcode timeout wrapper did not resolve its own directory when sourced from zsh" >&2
  exit 1
}

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
  docs/README.md
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

if git ls-files | rg '(^|/)\.cursor(/|$)'; then
  echo 'tracked repository content must not restore the removed general-purpose third-party development path' >&2
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
  tools/install-app-icon.sh tools/validate-app-icon.sh tools/tests/test-app-icon-workflow.sh \
  tools/tests/test-ui-direction-skill.sh \
  tools/secret-store.sh tools/run-with-secret.sh tools/run-with-private-key.sh tools/provider-preflight.sh \
  tools/validate-appstore-package.sh tools/capture-appstore-screenshots.sh tools/build-appstore-screenshot-set.sh \
  .agents/skills/supabase-ops/scripts/activate.sh .agents/skills/supabase-ops/scripts/validate-migrations.sh \
  .agents/skills/ios-media-assets/scripts/check-elevenlabs-capability.sh .agents/skills/ios-media-assets/scripts/validate-audio.sh \
  .agents/skills/ios-media-assets/scripts/validate-transcript.sh .agents/skills/ios-media-assets/scripts/validate-visual.sh \
  .agents/skills/prepare-appstore-assets/scripts/seal-package.sh .agents/skills/submit-appstore-release/scripts/record-section.sh; do
  [[ -x "$executable" ]] || { echo "integration executable is not executable: $executable" >&2; exit 1; }
done

# The product specification adopts Supabase with the same two exact lines that
# .agents/skills/supabase-ops/scripts/activate.sh requires before it creates supabase/ (#329).
supabase_adopted() {
  /usr/bin/grep -Eq '^Status:[[:space:]]*確定[[:space:]]*$' "$1" &&
    /usr/bin/grep -Eq '^Supabase:[[:space:]]*required[[:space:]]*$' "$1"
}
# check_supabase_directory ROOT STATE: dormant means no supabase/ at all; adopted means supabase/ is absent
# or a real directory, never a symlink or a file.
check_supabase_directory() {
  local path="$1/supabase"
  if [[ "$2" == adopted ]]; then
    [[ ! -L "$path" && ( ! -e "$path" || -d "$path" ) ]] || { echo 'An adopted Supabase keeps supabase/ as a real directory' >&2; return 1; }
  else
    [[ ! -e "$path" && ! -L "$path" ]] || { echo 'Supabase must remain dormant until an app specification explicitly activates it' >&2; return 1; }
  fi
}
supabase_state=dormant
supabase_adopted specs/product.md && supabase_state=adopted
check_supabase_directory . "$supabase_state" || exit 1
if [[ -e .superpowers || -L .superpowers ]]; then
  echo 'Root .superpowers implementation artifacts must not ship in the template' >&2
  exit 1
fi
if git ls-files --error-unmatch Package.swift Package.resolved >/dev/null 2>&1; then
  echo 'Foundation template must not carry a root Swift package dependency surface' >&2
  exit 1
fi
if git grep -n -I -E -- 'Supabase|ElevenLabs|Cloudflare|Firebase|PostHog|Mixpanel|Sentry|UserNotifications|XCRemoteSwiftPackageReference' -- TemplateApp TemplateApp.xcodeproj >/dev/null 2>&1; then
  echo 'TemplateApp contains an integration SDK, entitlement, import, or package reference before activation' >&2
  exit 1
fi

# #419: StoreKit stays out of TemplateApp except the exact `import StoreKit` that Apple's rating request
# (`requestReview`, #383) needs in the review prompt. In-app purchase code, Xcode project references and
# StoreKit configuration files stay refused until an app adopts the conditional StoreKit entitlement (D-064).
check_storekit_boundary() {
  local root=$1 line path rest text
  while IFS= read -r line; do
    path=${line%%:*}
    rest=${line#*:}
    text=${rest#*:}
    [[ "$path" == TemplateApp/Features/ReviewPrompt/*.swift && "$text" == 'import StoreKit' ]] || {
      echo "TemplateApp refers to StoreKit outside the review prompt's import: $path" >&2
      return 1
    }
  done < <(git -C "$root" grep -n -I -e StoreKit -- TemplateApp || true)
  if git -C "$root" grep -n -I -E -- 'Product\.(products|purchase)|Transaction\.(updates|currentEntitlements|all|latest|unfinished)|AppStore\.(sync|showManageSubscriptions)|\.purchase\(|ProductView|StoreView|SubscriptionStoreView|SubscriptionOfferView|AppTransaction|VerificationResult|RenewalInfo|currentEntitlement|subscriptionStatus|inAppPurchaseOptions|onInAppPurchase|storeButton|offerCodeRedemption|manageSubscriptionsSheet|refundRequestSheet|SKPaymentQueue|SKProduct|SKPayment|SKReceipt|SKRequest' -- TemplateApp >/dev/null 2>&1; then
    echo 'TemplateApp contains in-app purchase code before activation' >&2
    return 1
  fi
  # In a file that imports StoreKit, the StoreKit purchase types are refused by name as well (SwiftUI's own
  # Transaction elsewhere in TemplateApp is not affected).
  local storekit_files=()
  while IFS= read -r path; do storekit_files+=("$path"); done < <(git -C "$root" grep -l -I -e '^import StoreKit$' -- TemplateApp || true)
  if (( ${#storekit_files[@]} > 0 )) &&
     git -C "$root" grep -n -I -w -E -- 'Product|Transaction|AppStore' -- "${storekit_files[@]}" >/dev/null 2>&1; then
    echo 'the review prompt uses StoreKit purchase types' >&2
    return 1
  fi
  if git -C "$root" grep -n -I -e StoreKit -- TemplateApp.xcodeproj >/dev/null 2>&1; then
    echo 'TemplateApp.xcodeproj refers to StoreKit before activation' >&2
    return 1
  fi
  if [[ -n "$(git -C "$root" ls-files -- '*.storekit')" ]]; then
    echo 'the repository carries a StoreKit configuration file before activation' >&2
    return 1
  fi
}

storekit_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-foundation-storekit.XXXXXX")
# Builds a disposable repository with the review prompt's import, applies one change, and runs the check.
storekit_case() {
  local name=$1 root="$storekit_workspace/$1"
  mkdir -p "$root/TemplateApp/Features/ReviewPrompt" "$root/TemplateApp.xcodeproj" "$root/Config"
  git -C "$root" init -q
  printf '%s\n' 'import StoreKit' 'import SwiftUI' >"$root/TemplateApp/Features/ReviewPrompt/ReviewPromptView.swift"
  printf '%s\n' '// project' >"$root/TemplateApp.xcodeproj/project.pbxproj"
  case "$name" in
    baseline) ;;
    import-elsewhere) printf '%s\n' 'import StoreKit' >"$root/TemplateApp/Store.swift" ;;
    other-mention) printf '%s\n' '// StoreKit purchases' >>"$root/TemplateApp/Features/ReviewPrompt/ReviewPromptView.swift" ;;
    purchase-code) printf '%s\n' 'let products = try await Product.products(for: ["remove_ads"])' >"$root/TemplateApp/Purchases.swift" ;;
    legacy-purchase-code) printf '%s\n' 'SKPaymentQueue.default().add(payment)' >"$root/TemplateApp/Purchases.swift" ;;
    prompt-product-view) printf '%s\n' 'ProductView(id: "com.example.remove_ads")' >>"$root/TemplateApp/Features/ReviewPrompt/ReviewPromptView.swift" ;;
    prompt-instance-purchase) printf '%s\n' 'func buy(_ item: Item) async throws { _ = try await item.purchase() }' >>"$root/TemplateApp/Features/ReviewPrompt/ReviewPromptView.swift" ;;
    prompt-product-type) printf '%s\n' 'let item: Product? = nil' >>"$root/TemplateApp/Features/ReviewPrompt/ReviewPromptView.swift" ;;
    prompt-store-view) printf '%s\n' 'SubscriptionStoreView(groupID: "group")' >>"$root/TemplateApp/Features/ReviewPrompt/ReviewPromptView.swift" ;;
    project-reference) printf '%s\n' 'StoreKit.framework in Frameworks' >>"$root/TemplateApp.xcodeproj/project.pbxproj" ;;
    configuration-file) printf '%s\n' '{}' >"$root/Config/Products.storekit" ;;
  esac
  git -C "$root" add -A
  check_storekit_boundary "$root" 2>"$storekit_workspace/$name.err"
}
storekit_case baseline || { cat "$storekit_workspace/baseline.err" >&2; echo 'the review prompt import was refused' >&2; exit 1; }
for storekit_mutation in import-elsewhere other-mention purchase-code legacy-purchase-code prompt-product-view \
  prompt-instance-purchase prompt-product-type prompt-store-view project-reference configuration-file; do
  if storekit_case "$storekit_mutation"; then
    echo "the StoreKit boundary accepted $storekit_mutation" >&2
    exit 1
  fi
done
rm -rf -- "$storekit_workspace"
check_storekit_boundary . || exit 1

if ! credential_scan_output=$(bash "$repo_root/tools/tests/test-tracked-credential-scan.sh" --root "$repo_root" 2>&1); then
  if [[ "$credential_scan_output" == 'tracked credential scan failed:'* ]]; then
    printf '%s\n' "$credential_scan_output" >&2
  else
    printf 'tracked credential scan failed: %s\n' "$credential_scan_output" >&2
  fi
  exit 1
fi

python3 - <<'PYTHON'
from pathlib import Path

readme = Path("docs/README.md").read_text()
required = (
    "### App icon",
    ".agents/skills/app-icon/SKILL.md",
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

# docs/README.md states the current dedicated devices, asc operations, and team-scoped key location.
python3 - <<'PYTHON'
import json
import re
from pathlib import Path

readme = Path("docs/README.md").read_text()
devices = json.loads(Path("Config/dedicated-simulators.json").read_text())["devices"]
for device in devices:
    model = re.sub(r"\A.*?(?=iPhone|iPad)", "", device["name"])
    if model not in readme:
        raise SystemExit(f"docs/README.md does not name the dedicated device {model!r}")
operations = re.findall(r"^    '(appstore\.[a-z_]+)' => \{", Path("tools/lib/asc-cli.rb").read_text(), re.M)
if not operations or f"{len(operations)}種類" not in readme or any(f"`{name}`" not in readme for name in operations):
    raise SystemExit(f"docs/README.md must list the asc operations {operations!r}")
key_path = "secrets/apple-team-<teamId>/app-store-connect-production.p8"
if key_path not in readme or "apple-team-<teamId>" not in Path("docs/security.md").read_text():
    raise SystemExit("docs/README.md must name the team-scoped App Store Connect key path")
for stale in ("Pro Max を除く", "iPad Air", "4種類の読取command", "secrets/${appSlug}/"):
    if stale in readme:
        raise SystemExit(f"docs/README.md keeps a stale fact: {stale!r}")
PYTHON

ownership_check=$(cat <<'RUBY'
  data = YAML.safe_load(File.read("Config/ownership.yml", encoding: "UTF-8"), permitted_classes: [], aliases: false)
  abort "unexpected schema version" unless data["schemaVersion"] == 2
  abort "ownership top-level schema differs" unless data.keys.sort == %w[appStore cloudflare elevenlabs github linear schemaVersion supabase vercel].sort
  abort "unexpected GitHub login" unless data.dig("github", "login") == "yuto1201"
  abort "unexpected Supabase organization ID" unless data.dig("supabase", "organizationId") == "kmjpkzaqlewqnypyqwkg"
  abort "unexpected Supabase organization name" unless data.dig("supabase", "organizationName") == "yuto1201#{39.chr}s Org"
  project_ref = data.dig("supabase", "projectRef")
  if ENV.fetch("SUPABASE_STATE", "dormant") == "adopted"
    # A configured ref is the 20-letter Supabase project ref, never the organization ID (#329).
    abort "Supabase projectRef must be null or a 20-letter project ref" unless project_ref.nil? ||
      (project_ref.is_a?(String) && project_ref.match?(/\A[a-z]{20}\z/) && project_ref != data.dig("supabase", "organizationId"))
  else
    abort "projectRef must be null" unless project_ref.nil?
  end
  abort "unexpected Cloudflare account" unless data.dig("cloudflare", "accountId") == "7ea8e713d76506f9e303f58624829aa5" && data.dig("cloudflare", "accountName") == "Yuto Dev" && data.dig("cloudflare", "plan") == "free"
  # The app-feedback skill (D-076) records the app's Worker as the target once the Identity exists.
  cloudflare_target = data.dig("cloudflare", "target")
  if File.exist?("Config/app-identity.json")
    worker = "#{JSON.parse(File.read("Config/app-identity.json", encoding: "UTF-8"))["appSlug"]}-feedback"
    abort "Cloudflare target must be null or #{worker}" unless cloudflare_target.nil? || cloudflare_target == worker
  else
    abort "Cloudflare target must be null" unless cloudflare_target.nil?
  end
  abort "unexpected Linear identity" unless data["linear"] == {"workspaceSlug"=>"yuto33004", "workspaceUrl"=>"https://linear.app/yuto33004", "teamKey"=>"YUT"}
  abort "unexpected Vercel team" unless data.dig("vercel", "teamId") == "team_ANEUn6gVL8dccPaY08wkvxFt" && data.dig("vercel", "teamSlug") == "yuto16" && data.dig("vercel", "plan") == "hobby"
  abort "Vercel projectId must be null" unless data.dig("vercel", "projectId").nil?
  %w[accountId workspaceId].each { |key| abort "ElevenLabs #{key} must be null" unless data.dig("elevenlabs", key).nil? }
  abort "unexpected App Store team" unless data.dig("appStore", "teamId") == "AUZ2MV247A" && data.dig("appStore", "apiKeyType") == "team-app-manager"
  if File.exist?("Config/app-identity.json")
    identity = JSON.parse(File.read("Config/app-identity.json", encoding: "UTF-8"))
    abort "unexpected app identity schema version" unless identity["schemaVersion"] == 1
    abort "app identity bundleId is missing" unless identity["bundleId"].is_a?(String) && !identity["bundleId"].empty?
    abort "ownership and app identity bundleId differ" unless data.dig("appStore", "bundleId") == identity["bundleId"]
  else
    abort "App Store bundleId must be null before identity bootstrap" unless data.dig("appStore", "bundleId").nil?
  end
RUBY
)
SUPABASE_STATE="$supabase_state" ruby -ryaml -rjson -e "$ownership_check"

# #332: the Cloudflare target before and after Identity bootstrap, on disposable copies of the ownership file.
ownership_fixture=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-ownership.XXXXXX")
check_ownership_fixture() {
  local expected=$1 target=$2 identity=$3 dir
  dir=$(mktemp -d "$ownership_fixture/case.XXXXXX")
  mkdir -p "$dir/Config"
  TARGET="$target" IDENTITY="$identity" ruby -ryaml -rjson -e '
    data = YAML.safe_load(File.read(ARGV.fetch(0), encoding: "UTF-8"), permitted_classes: [], aliases: false)
    data["cloudflare"]["target"] = ENV.fetch("TARGET") == "null" ? nil : ENV.fetch("TARGET")
    if ENV.fetch("IDENTITY") == "bootstrapped"
      identity = {"appSlug" => "garden-notes", "bundleId" => "com.yuto.GardenNotes", "displayName" => "Garden Notes",
                  "moduleName" => "GardenNotes", "schemaVersion" => 1, "sourceIdentityVersion" => 1}
      File.write(File.join(ARGV.fetch(1), "Config/app-identity.json"), JSON.generate(identity))
      data["appStore"]["bundleId"] = identity.fetch("bundleId")
    else
      data["appStore"]["bundleId"] = nil
    end
    File.write(File.join(ARGV.fetch(1), "Config/ownership.yml"), data.to_yaml)
  ' Config/ownership.yml "$dir"
  if (cd "$dir" && ruby -ryaml -rjson -e "$ownership_check" 2>"$dir/stderr"); then
    [[ "$expected" == pass ]] || { echo "ownership check accepted Cloudflare target $target ($identity)" >&2; exit 1; }
  else
    [[ "$expected" == fail ]] && grep -Fq 'Cloudflare target' "$dir/stderr" ||
      { echo "ownership check gave an unexpected result for Cloudflare target $target ($identity): $(cat "$dir/stderr")" >&2; exit 1; }
  fi
}
check_ownership_fixture pass null template
check_ownership_fixture fail garden-notes-feedback template
check_ownership_fixture pass null bootstrapped
check_ownership_fixture pass garden-notes-feedback bootstrapped
check_ownership_fixture fail other-feedback bootstrapped
rm -rf -- "$ownership_fixture"

ruby -rjson -e '
  manifest = JSON.parse(File.read("Config/template-identity.json", encoding: "UTF-8"))
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
text = File.read(path, encoding: "UTF-8")
frontmatter = text.match(/\A---\n(.*?)\n---\n/m)&.captures&.first
abort "missing app bootstrap skill frontmatter" unless frontmatter
data = YAML.safe_load(frontmatter, permitted_classes: [], aliases: false)
abort "unexpected app bootstrap skill name" unless data["name"] == "app-bootstrap"
abort "missing app bootstrap skill description" unless data["description"].is_a?(String) && !data["description"].strip.empty?
RUBY

python3 - <<'PYTHON'
from pathlib import Path

for path in (Path(".agents/skills/app-bootstrap/SKILL.md"), Path("docs/README.md")):
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

readme = Path("docs/README.md").read_text()
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
text = File.read(path, encoding: "UTF-8")
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

for skill in "${workflow_skills[@]}"; do
  shared_skill=".agents/skills/$skill/SKILL.md"
  claude_workflow_skill=".claude/skills/$skill"
  expected_workflow_target="../../.agents/skills/$skill"

  ruby -ryaml - "$shared_skill" "$skill" <<'RUBY'
path, expected_name = ARGV
text = File.read(path, encoding: "UTF-8")
frontmatter = text.match(/\A---\n(.*?)\n---\n/m)&.captures&.first
abort "missing shared workflow skill frontmatter: #{path}" unless frontmatter
data = YAML.safe_load(frontmatter, permitted_classes: [], aliases: false)
abort "unexpected shared workflow skill name: #{path}" unless data["name"] == expected_name
description = data["description"]
abort "missing shared workflow skill description: #{path}" unless description.is_a?(String) && description.start_with?("Use when")
RUBY

  if [[ ! -L "$claude_workflow_skill" ]]; then
    echo "Claude workflow skill must be a symbolic link, not a copied directory: $claude_workflow_skill" >&2
    exit 1
  fi
  if [[ $(readlink "$claude_workflow_skill") != "$expected_workflow_target" ]]; then
    echo "Claude workflow skill has a nonportable or incorrect target: $claude_workflow_skill" >&2
    exit 1
  fi
  if [[ ! -f "$claude_workflow_skill/SKILL.md" ]]; then
    echo "Claude workflow skill link does not resolve: $claude_workflow_skill" >&2
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
text = File.read(path, encoding: "UTF-8")
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

fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-foundation.XXXXXX")
spec_fixture_dir="$fixture_dir/spec-workflow"
trap 'rm -rf -- "$fixture_dir" "$ignore_probe_root"' EXIT
printf '%s\n' '# Target' > "$fixture_dir/target.md"
printf '%s\n' '[Target](target.md)' > "$fixture_dir/valid.md"
printf '%s\n' '[Missing](missing.md)' > "$fixture_dir/invalid.md"
printf '%s\n' '[Target](target.md)' '```diff' '+[Quoted](missing.md)' '```' > "$fixture_dir/fenced.md"
printf '%s\n' '```' 'code' '```' '[Missing](missing.md)' > "$fixture_dir/after-fence.md"

swift tools/check-markdown-links.swift "$fixture_dir/valid.md"
if swift tools/check-markdown-links.swift "$fixture_dir/invalid.md" >/dev/null 2>&1; then
  echo "Markdown link checker accepted a missing local target" >&2
  exit 1
fi
swift tools/check-markdown-links.swift "$fixture_dir/fenced.md" || { echo "Markdown link checker followed a link inside a fenced code block" >&2; exit 1; }
if swift tools/check-markdown-links.swift "$fixture_dir/after-fence.md" >/dev/null 2>&1; then
  echo "Markdown link checker ignored a missing target after a closed fence" >&2
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

absolute_spec_path="$spec_fixture_dir/spec.md"
printf '[Confirmed](<%s#confirmed-choice>)\n' "$absolute_spec_path" > "$spec_fixture_dir/confirmed-issue.md"
printf '[Pending](<%s#pending-choice>)\n' "$absolute_spec_path" > "$spec_fixture_dir/pending-issue.md"
printf '[Proposed](<%s#proposed-choice>)\n' "$absolute_spec_path" > "$spec_fixture_dir/proposed-issue.md"
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

# #329: only a confirmed specification with the exact activation line lifts the Supabase dormancy checks.
supabase_fixture_dir="$fixture_dir/supabase-adoption"
mkdir -p "$supabase_fixture_dir"
printf '%s\n' '# Product' '' 'Status: 確定' 'Supabase: required' > "$supabase_fixture_dir/adopted.md"
printf '%s\n' '# Product' '' 'Status: 確定' 'Supabase: not required' > "$supabase_fixture_dir/not-required.md"
printf '%s\n' '# Product' '' 'Status: 提案' 'Supabase: required' > "$supabase_fixture_dir/proposed.md"
printf '%s\n' '# Product' '' 'Status: 確定' '- Supabase: required' > "$supabase_fixture_dir/list-item.md"
printf '%s\n' '# Product' '' 'Status: 確定' 'Supabase: required later' > "$supabase_fixture_dir/qualified.md"
printf '%s\n' '# Product' '' 'Status: 確定' 'Supabaseの採用は別のIssueで決める。' > "$supabase_fixture_dir/undeclared.md"
supabase_adopted "$supabase_fixture_dir/adopted.md" || { echo 'a confirmed Supabase: required specification was not treated as adopted' >&2; exit 1; }
for dormant_spec in not-required proposed list-item qualified undeclared; do
  if supabase_adopted "$supabase_fixture_dir/$dormant_spec.md"; then
    echo "Supabase adoption accepted a specification without the exact confirmed line: $dormant_spec" >&2
    exit 1
  fi
done
# supabase/ itself: a real directory only once adopted; a symlink or a file never.
for case_spec in 'dormant none pass' 'dormant directory fail' 'adopted none pass' 'adopted directory pass' 'adopted symlink fail' 'adopted file fail'; do
  read -r case_state case_kind case_expected <<<"$case_spec"
  case_root="$supabase_fixture_dir/root-$case_state-$case_kind"
  mkdir -p "$case_root" "$supabase_fixture_dir/elsewhere"
  case "$case_kind" in
    directory) mkdir -p "$case_root/supabase/migrations" ;;
    symlink) ln -s ../elsewhere "$case_root/supabase" ;;
    file) printf '%s\n' file > "$case_root/supabase" ;;
  esac
  if check_supabase_directory "$case_root" "$case_state" 2>/dev/null; then case_result=pass; else case_result=fail; fi
  [[ "$case_result" == "$case_expected" ]] || { echo "supabase/ check for $case_state $case_kind gave $case_result" >&2; exit 1; }
done
# projectRef: null or a 20-letter ref other than the organization ID once adopted; null only while dormant.
for case_spec in 'dormant null pass' 'dormant abcdefghijklmnopqrst fail' 'adopted null pass' 'adopted abcdefghijklmnopqrst pass' \
  'adopted kmjpkzaqlewqnypyqwkg fail' 'adopted ABCDEFGHIJKLMNOPQRST fail' 'adopted short fail'; do
  read -r case_state case_ref case_expected <<<"$case_spec"
  case_root="$supabase_fixture_dir/ref-$case_state-$case_ref"
  mkdir -p "$case_root/Config"
  REF="$case_ref" ruby -ryaml -e '
    data = YAML.safe_load(File.read(ARGV.fetch(0), encoding: "UTF-8"), permitted_classes: [], aliases: false)
    data["supabase"]["projectRef"] = ENV.fetch("REF") == "null" ? nil : ENV.fetch("REF")
    data["cloudflare"]["target"] = nil
    data["appStore"]["bundleId"] = nil
    File.write(ARGV.fetch(1), data.to_yaml)
  ' Config/ownership.yml "$case_root/Config/ownership.yml"
  if (cd "$case_root" && SUPABASE_STATE="$case_state" ruby -ryaml -rjson -e "$ownership_check" 2>"$case_root/stderr"); then case_result=pass; else case_result=fail; fi
  [[ "$case_result" == "$case_expected" ]] || { echo "projectRef $case_ref ($case_state) gave $case_result: $(cat "$case_root/stderr")" >&2; exit 1; }
  [[ "$case_result" == pass ]] || grep -Fq 'projectRef' "$case_root/stderr" || { echo "projectRef $case_ref ($case_state) failed for another reason: $(cat "$case_root/stderr")" >&2; exit 1; }
done

if [[ ! -f Config/template-base.json ]]; then
  swift tools/check-markdown-links.swift
else
  # #356: docs/superpowers/ is template-only (tools/template-sync/ownership.json), so in an app that adopted the
  # template (it records Config/template-base.json, D-074) the imported documents' links into it have no
  # target. Only those are left out there; every other missing target still fails, and the template is
  # checked as before.
  if ! link_errors=$(swift tools/check-markdown-links.swift 2>&1); then
    python3 - "$link_errors" <<'PYTHON'
import os
import sys

lines = sys.argv[1].splitlines()
remaining = [] if lines else ["the Markdown link check failed without naming a target"]
for line in lines:
    source, separator, destination = line.partition(": missing local Markdown target: ")
    resolved = os.path.normpath(os.path.join(os.path.dirname(source), destination)) if separator else ""
    if not (separator and resolved.startswith("docs/superpowers/")):
        remaining.append(line)
if remaining:
    print("\n".join(remaining), file=sys.stderr)
    sys.exit(1)
PYTHON
  fi
fi

# #333: the Ruby checks above read UTF-8 files whatever the caller's locale. With LANG and LC_ALL set to C,
# Ruby's default external encoding is US-ASCII, so the same checks run once more there and must pass the same way.
if [[ -z "${IOS_TEMPLATE_FOUNDATION_C_LOCALE_RUN:-}" ]]; then
  c_locale_encoding=$(env -u RUBYOPT LANG=C LC_ALL=C ruby -e 'print Encoding.default_external')
  [[ "$c_locale_encoding" == US-ASCII ]] ||
    { echo "the C locale did not make Ruby read files as US-ASCII: $c_locale_encoding" >&2; exit 1; }
  if ! c_locale_output=$(env -u RUBYOPT LANG=C LC_ALL=C IOS_TEMPLATE_FOUNDATION_C_LOCALE_RUN=1 \
    bash "$repo_root/tools/tests/test-foundation.sh" 2>&1); then
    echo "Foundation checks failed with LANG=C and LC_ALL=C: $c_locale_output" >&2
    exit 1
  fi
  [[ "$c_locale_output" == *"Foundation repository policy checks passed"* ]] ||
    { echo "Foundation checks did not pass with LANG=C and LC_ALL=C: $c_locale_output" >&2; exit 1; }
fi

echo "Foundation repository policy checks passed"
