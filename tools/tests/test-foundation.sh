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
  tools/check-markdown-links.swift
)

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

ruby -ryaml -e '
  data = YAML.safe_load(File.read("Config/ownership.yml"), permitted_classes: [], aliases: false)
  abort "unexpected schema version" unless data["schemaVersion"] == 1
  abort "unexpected GitHub login" unless data.dig("github", "login") == "yuto1201"
  abort "unexpected Supabase organization" unless data.dig("supabase", "organization") == "YUTO1201"
  %w[projectRef].each { |key| abort "#{key} must be null" unless data.dig("supabase", key).nil? }
  abort "Cloudflare accountId must be null" unless data.dig("cloudflare", "accountId").nil?
  abort "App Store teamId must be null" unless data.dig("appStore", "teamId").nil?
  abort "App Store bundleId must be null" unless data.dig("appStore", "bundleId").nil?
'

if [[ ! -x tools/check-markdown-links.swift ]]; then
  echo "Markdown link checker must be executable" >&2
  exit 1
fi

fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
printf '%s\n' '# Target' > "$fixture_dir/target.md"
printf '%s\n' '[Target](target.md)' > "$fixture_dir/valid.md"
printf '%s\n' '[Missing](missing.md)' > "$fixture_dir/invalid.md"

swift tools/check-markdown-links.swift "$fixture_dir/valid.md"
if swift tools/check-markdown-links.swift "$fixture_dir/invalid.md" >/dev/null 2>&1; then
  echo "Markdown link checker accepted a missing local target" >&2
  exit 1
fi

swift tools/check-markdown-links.swift

echo "Foundation repository policy checks passed"
