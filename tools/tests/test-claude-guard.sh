#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

guard="$repo_root/.claude/hooks/guard-external-ops.sh"
loader="$repo_root/.claude/hooks/load-agents-md.sh"
fixtures="$repo_root/tools/tests/fixtures/claude-hook"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-claude-guard.XXXXXX")
runtime_link="$repo_root/tools/tests/fixtures/claude-hook/runtime-link.sh"
cleanup() {
  rm -f "$runtime_link"
  rm -rf "$workspace"
}
trap cleanup EXIT

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
  deny-nested-git-push
  deny-nested-git-push-no-space
  deny-absolute-nested-git-push
  deny-git-clone
  deny-absolute-git-clone
  deny-git-remote-add
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
  if [[ ! -s "$output" ]]; then
    echo "expected denied fixture $name to return a decision" >&2
    exit 1
  fi
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

write_fixture() {
  local output=$1 tool_name=$2 input_key=$3 input_value=$4
  /usr/bin/ruby -rjson -e '
    path, tool, key, value = ARGV
    File.write(path, JSON.generate({"tool_name" => tool, "tool_input" => {key => value}}))
  ' "$output" "$tool_name" "$input_key" "$input_value"
}

assert_inline_allow() {
  local name=$1 tool_name=$2 input_key=$3 input_value=$4 fixture
  fixture="$workspace/$name.json"
  write_fixture "$fixture" "$tool_name" "$input_key" "$input_value"
  fixtures="$workspace" assert_allow "$name"
  fixtures="$repo_root/tools/tests/fixtures/claude-hook"
}

assert_inline_deny() {
  local name=$1 tool_name=$2 input_key=$3 input_value=$4 fixture
  fixture="$workspace/$name.json"
  write_fixture "$fixture" "$tool_name" "$input_key" "$input_value"
  fixtures="$workspace" assert_deny "$name"
  fixtures="$repo_root/tools/tests/fixtures/claude-hook"
}

for case_name in "${allow_cases[@]}"; do
  assert_allow "$case_name"
done

for case_name in "${deny_cases[@]}"; do
  assert_deny "$case_name"
done

assert_inline_allow allow-read-public-source Read file_path "$repo_root/docs/security.md"
assert_inline_allow allow-read-environment-example Read file_path "$repo_root/Config/Local.xcconfig.example"
assert_inline_allow allow-safe-environment-build Bash command "env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version"
assert_inline_allow allow-safe-transitive-cycle Bash command "tools/tests/fixtures/claude-hook/safe-cycle-entry.sh"
assert_inline_allow allow-sh-safe-transitive-cycle Bash command "sh ./tools/tests/fixtures/claude-hook/safe-cycle-entry.sh"
assert_inline_allow allow-bash-stdin-safe-transitive-cycle Bash command "bash<tools/tests/fixtures/claude-hook/safe-cycle-entry.sh"
assert_inline_allow allow-absolute-safe-transitive-cycle Bash command "$repo_root/tools/tests/fixtures/claude-hook/safe-cycle-entry.sh"
assert_inline_allow allow-chained-safe-transitive-cycle Bash command "cd '$repo_root' && ./tools/tests/fixtures/claude-hook/safe-cycle-entry.sh"
assert_inline_allow allow-local-git-worktree Bash command "git worktree list --porcelain"
assert_inline_allow allow-local-git-diff-script-path Bash command "git diff -- tools/request-codex-op.sh"
assert_inline_allow allow-safe-find Bash command "find docs -type f -name '*.md' -print"
assert_inline_allow allow-safe-python-file Bash command "python3 tools/tests/fixtures/claude-hook/local-check.py"
assert_inline_allow allow-backtick-local-git Bash command 'printf "%s\n" `git status --short`'
assert_inline_allow allow-local-xcode-mcp mcp__XcodeBuildMCP__build_sim projectPath "$repo_root/TemplateApp.xcodeproj"
assert_inline_allow allow-registered-local-xcode-mcp mcp__xcodebuild__build_sim projectPath "$repo_root/TemplateApp.xcodeproj"
assert_inline_allow allow-local-xcode-simulator-mcp mcp__xcodebuildmcp__screenshot simulatorId "00000000-0000-0000-0000-000000000000"
assert_inline_allow allow-local-xcode-session-default mcp__xcodebuild__session_set_defaults simulatorId "00000000-0000-0000-0000-000000000000"
assert_inline_allow allow-local-migration-edit Edit file_path "$repo_root/supabase/migrations/20260826000000_example.sql"
assert_inline_allow allow-local-supabase-reset Bash command "supabase db reset --local"
assert_inline_allow allow-local-audio-inspection Bash command "afinfo '$repo_root/Assets/Audio/example.wav'"
assert_inline_allow allow-app-store-copy-edit Edit file_path "$repo_root/App Store/metadata/localizations/ja.yml"

assert_inline_deny deny-read-dedicated-secret Read file_path "$HOME/Library/Application Support/iOS-Template/secrets/example/key.p8"
assert_inline_deny deny-glob-environment-secret Glob pattern "$HOME/projects/example/.env.local"
assert_inline_deny deny-grep-token-path Grep path "$HOME/.config/example/api-token.txt"
assert_inline_deny deny-computer-keychain Computer prompt "Open ~/Library/Keychains/login.keychain-db"
ln -s "$HOME/Library/Keychains/login.keychain-db" "$workspace/keychain-link"
assert_inline_deny deny-read-secret-symlink Read file_path "$workspace/keychain-link"
assert_inline_deny deny-bash-secret-symlink Bash command "cat '$workspace/keychain-link'"
ln -s /opt/homebrew/bin/gh "$workspace/provider-link"
assert_inline_deny deny-bash-provider-symlink Bash command "'$workspace/provider-link' issue list"
assert_inline_deny deny-bash-environment-secret Bash command "cat .env"
assert_inline_deny deny-bash-private-key Bash command "cat '$HOME/keys/AuthKey_TEST.p8'"
assert_inline_deny deny-bash-keychain-file Bash command "cat ~/Library/Keychains/login.keychain-db"
assert_inline_deny deny-bash-netrc Bash command "sed -n '1p' ~/.netrc"
assert_inline_deny deny-bash-ssh-key Bash command "cat ~/.ssh/id_rsa"
assert_inline_deny deny-repository-secret-directory Read file_path "$repo_root/.secrets/provider-token"
assert_inline_deny deny-secret-staging-directory Write file_path "$repo_root/secret-staging/review-contact.txt"

assert_inline_deny deny-absolute-gh Bash command "/opt/homebrew/bin/gh issue list"
assert_inline_deny deny-absolute-supabase Bash command "'/usr/local/bin/supabase' db push"
assert_inline_deny deny-env-provider Bash command "/usr/bin/env GH_HOST=github.com /opt/homebrew/bin/gh issue list"
assert_inline_deny deny-env-transitive-tools-script Bash command "env SAFE_LOCAL=1 tools/tests/fixtures/claude-hook/transitive-entry.sh"
assert_inline_deny deny-env-option-transitive-tools-script Bash command "/usr/bin/env -i SAFE_LOCAL=1 ./tools/tests/fixtures/claude-hook/transitive-entry.sh"
assert_inline_deny deny-xargs-provider Bash command "printf 'issue list' | xargs gh"
assert_inline_deny deny-find-exec-provider Bash command "find . -type f -exec /opt/homebrew/bin/gh issue list ';'"
assert_inline_deny deny-keychain-write Bash command "security add-generic-password -a account -s service -w value"
assert_inline_deny deny-keychain-delete Bash command "security delete-generic-password -s service"
assert_inline_deny deny-secret-store-tool Bash command "tools/secret-store.sh store app-store review-contact"
assert_inline_deny deny-secret-child-tool Bash command "tools/run-with-secret.sh --service app-store --account review -- env"
assert_inline_deny deny-private-key-child-tool Bash command "tools/run-with-private-key.sh --app template --file AuthKey_TEST.p8 -- env"
assert_inline_deny deny-provider-preflight-tool Bash command "tools/provider-preflight.sh --issue 8 app-store --version 1.0"
assert_inline_deny deny-elevenlabs-capability-tool Bash command ".agents/skills/ios-audio-assets/scripts/check-elevenlabs-capability.sh --operation music"
assert_inline_deny deny-app-store-submission-recorder Bash command ".agents/skills/submit-appstore-release/scripts/record-section.sh --primary-model codex"
assert_inline_deny deny-app-store-connect-open Bash command "open https://appstoreconnect.apple.com/apps"
assert_inline_deny deny-app-store-browser-action Browser prompt "Open App Store Connect and submit this build for review"

assert_inline_deny deny-python-command Bash command "/usr/bin/python3 -c 'import os; os.system(\"gh issue list\")'"
assert_inline_deny deny-python-command-no-space Bash command "python3 -c'print(1)'"
assert_inline_deny deny-python-command-after-option Bash command "python3 -I -c 'print(1)'"
assert_inline_deny deny-ruby-eval Bash command "ruby -e 'exec \"gh\", \"issue\", \"list\"'"
assert_inline_deny deny-perl-eval Bash command "perl -e 'system qw(gh issue list)'"
assert_inline_deny deny-node-eval Bash command "node -e 'require(\"child_process\").execSync(\"gh issue list\")'"
assert_inline_deny deny-node-eval-after-option Bash command "node --no-warnings -e 'console.log(1)'"
assert_inline_deny deny-shell-command-after-option Bash command "bash --noprofile -c 'printf safe-looking'"
assert_inline_deny deny-backtick-provider Bash command 'printf "%s\n" `gh issue list`'
assert_inline_deny deny-backtick-interpreter Bash command 'printf "%s\n" `python3 -c "print(1)"`'
assert_inline_deny deny-intraword-quoted-provider Bash command 'g"h" issue list'
assert_inline_deny deny-assigned-provider-expansion Bash command 'x=gh; $x issue list'
assert_inline_deny deny-unlisted-mcp mcp__calendar__list_events calendarId local
assert_inline_deny deny-near-match-xcode-mcp mcp__xcodebuildx__build_sim projectPath "$repo_root/TemplateApp.xcodeproj"
assert_inline_deny deny-unknown-xcode-action mcp__xcodebuild__archive_upload projectPath "$repo_root/TemplateApp.xcodeproj"
assert_inline_deny deny-xcode-device-default mcp__xcodebuild__session_set_defaults deviceId "00000000-0000-0000-0000-000000000000"
assert_inline_deny deny-xcode-persisted-profile mcp__xcodebuild__session_use_defaults_profile profile device
assert_inline_deny deny-xcode-arbitrary-lldb mcp__xcodebuildmcp__debug_lldb_command command "platform shell gh issue list"

assert_inline_deny deny-dot-tools-script Bash command "./tools/tests/fixtures/claude-hook/unapproved-external.sh"
assert_inline_deny deny-sh-tools-script Bash command "sh tools/tests/fixtures/claude-hook/unapproved-external.sh"
assert_inline_deny deny-absolute-sh-tools-script Bash command "/bin/sh ./tools/tests/fixtures/claude-hook/unapproved-external.sh"
assert_inline_deny deny-bash-stdin-tools-script Bash command "bash<tools/tests/fixtures/claude-hook/unapproved-external.sh"
assert_inline_deny deny-absolute-tools-script Bash command "$repo_root/tools/tests/fixtures/claude-hook/unapproved-external.sh"
assert_inline_deny deny-transitive-tools-script Bash command "tools/tests/fixtures/claude-hook/transitive-entry.sh"
assert_inline_deny deny-chained-transitive-tools-script Bash command "cd '$repo_root' && ./tools/tests/fixtures/claude-hook/transitive-entry.sh"
assert_inline_deny deny-semicolon-transitive-tools-script Bash command "true; sh tools/tests/fixtures/claude-hook/transitive-entry.sh"
assert_inline_deny deny-transitive-network-script Bash command "tools/tests/fixtures/claude-hook/network-entry.sh"
ln -s unapproved-external.sh "$runtime_link"
assert_inline_deny deny-untracked-script-symlink Bash command "tools/tests/fixtures/claude-hook/runtime-link.sh"
rm "$runtime_link"

assert_inline_deny deny-git-send-pack Bash command "git send-pack origin HEAD"
assert_inline_deny deny-absolute-git-fetch-pack Bash command "/usr/libexec/git-core/git-fetch-pack origin"
assert_inline_deny deny-git-http-transport Bash command "git http-fetch deadbeef https://example.com/repo.git"
assert_inline_deny deny-git-credential-fill Bash command "printf 'protocol=https\\nhost=github.com\\n' | git credential fill"
assert_inline_deny deny-absolute-credential-helper Bash command "/usr/libexec/git-core/git-credential-osxkeychain get"
assert_inline_deny deny-git-exec-path Bash command "git --exec-path=/tmp status"
assert_inline_deny deny-direct-ssh-git-plumbing Bash command "ssh git@github.com git-receive-pack yuto1201/iOS-Template.git"
assert_inline_deny deny-direct-rsync-remote Bash command "rsync -a docs/ example@example.com:/tmp/docs/"

loader_project="$workspace/loader-project"
mkdir -p "$loader_project"

assert_loader_exact_bytes() {
  local name=$1 expected=$2 output
  output="$workspace/$name.out"
  CLAUDE_PROJECT_DIR="$loader_project" "$loader" > "$output"
  EXPECTED="$expected" /usr/bin/ruby -rjson -e '
    value = JSON.parse(File.binread(ARGV.fetch(0))).fetch("hookSpecificOutput").fetch("additionalContext")
    expected = File.binread(ENV.fetch("EXPECTED"))
    abort "additionalContext bytes differ" unless value.b == expected
  ' "$output"
}

quote_controls="$workspace/quote-controls.bin"
/usr/bin/ruby -e 'File.binwrite(ARGV.fetch(0), "quote:\" backslash:\\\nnewline:\ncarriage:\rtab:\tend")' "$quote_controls"
cp "$quote_controls" "$loader_project/AGENTS.md"
assert_loader_exact_bytes loader-quote-controls "$quote_controls"

c0_controls="$workspace/c0-controls.bin"
/usr/bin/ruby -e 'File.binwrite(ARGV.fetch(0), "c0:".b + (0..31).to_a.pack("C*") + ":utf8:日本語\n")' "$c0_controls"
cp "$c0_controls" "$loader_project/AGENTS.md"
assert_loader_exact_bytes loader-c0-controls "$c0_controls"

exact_limit="$workspace/exact-limit.bin"
/usr/bin/ruby -e 'File.binwrite(ARGV.fetch(0), "a" * 32_768)' "$exact_limit"
cp "$exact_limit" "$loader_project/AGENTS.md"
assert_loader_exact_bytes loader-exact-limit "$exact_limit"

/usr/bin/ruby -e 'File.binwrite(ARGV.fetch(0), "a" * 32_769)' "$loader_project/AGENTS.md"
CLAUDE_PROJECT_DIR="$loader_project" "$loader" > "$workspace/loader-oversized.out"
/usr/bin/ruby -rjson -e '
  context = JSON.parse(File.binread(ARGV.fetch(0))).fetch("hookSpecificOutput").fetch("additionalContext")
  abort "oversized contract did not fail visibly" unless context.include?("blocked:environment") && context.include?("32768")
' "$workspace/loader-oversized.out"

chmod 000 "$loader_project/AGENTS.md"
CLAUDE_PROJECT_DIR="$loader_project" "$loader" > "$workspace/loader-unreadable.out"
chmod 600 "$loader_project/AGENTS.md"
/usr/bin/ruby -rjson -e '
  context = JSON.parse(File.binread(ARGV.fetch(0))).fetch("hookSpecificOutput").fetch("additionalContext")
  abort "unreadable contract did not fail visibly" unless context.include?("blocked:environment") && context.include?("unreadable")
' "$workspace/loader-unreadable.out"

echo "PASS: Claude hooks preserve AGENTS bytes, allow only local work, and deny hidden external/secret operations"
