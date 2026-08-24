#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

guard="$repo_root/.claude/hooks/guard-external-ops.sh"
fixtures="$repo_root/tools/tests/fixtures/claude-hook"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-claude-guard.XXXXXX")
trap 'rm -rf "$workspace"' EXIT

allow_cases=(
  allow-git-status
  allow-git-diff
  allow-git-add
  allow-git-commit
  allow-xcode-build
  allow-computer-new-project
  allow-computer-simulator
  allow-public-curl
  allow-request-codex-op
  allow-request-codex-review
)

deny_cases=(
  deny-gh
  deny-git-push
  deny-git-c-push
  deny-git-dir-fetch
  deny-git-pull
  deny-direct-codex
  deny-supabase
  deny-wrangler
  deny-elevenlabs
  deny-fastlane
  deny-keychain
  deny-authenticated-curl
  deny-secret-path
  deny-unapproved-script
  deny-github-mcp
  deny-supabase-mcp
  deny-cloudflare-mcp
  deny-computer-accounts
  deny-computer-organizer
  deny-computer-signing
  deny-computer-archive-upload
  deny-computer-app-store-connect
  deny-malformed-tool-name
  deny-missing-shell-command
)

assert_allow() {
  local name=$1 output="$workspace/$1.out"
  "$guard" < "$fixtures/$name.json" > "$output"
  if [[ -s "$output" ]]; then
    echo "expected allowed fixture $name to produce no output" >&2
    exit 1
  fi
}

assert_deny() {
  local name=$1 output="$workspace/$1.out" decision reason
  "$guard" < "$fixtures/$name.json" > "$output"
  decision=$(/usr/bin/plutil -extract hookSpecificOutput.permissionDecision raw -o - "$output")
  reason=$(/usr/bin/plutil -extract hookSpecificOutput.permissionDecisionReason raw -o - "$output")
  if [[ "$decision" != "deny" ]]; then
    echo "expected denied fixture $name to return deny" >&2
    exit 1
  fi
  if [[ "$reason" != *"Codexへ委託"* ]]; then
    echo "expected denied fixture $name to delegate to Codex" >&2
    exit 1
  fi
}

for case_name in "${allow_cases[@]}"; do
  assert_allow "$case_name"
done

for case_name in "${deny_cases[@]}"; do
  assert_deny "$case_name"
done

echo "PASS: ${#allow_cases[@]} allowed and ${#deny_cases[@]} denied Claude guard fixtures"
