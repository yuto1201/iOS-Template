#!/usr/bin/env bash
set -u

deny_reason='個人用の認証済み外部操作または秘密情報へのアクセスです。codex-external-ops で Codexへ委託してください。'

deny() {
  /usr/bin/printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"'"$deny_reason"'"}}'
}

temporary_input=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/ios-template-claude-hook.XXXXXX") || exit 1
/bin/chmod 600 "$temporary_input"
trap '/bin/rm -f "$temporary_input"' EXIT
/bin/cat > "$temporary_input"

tool_name=''
if ! tool_name=$(/usr/bin/plutil -extract tool_name raw -expect string -o - "$temporary_input" 2>/dev/null); then
  deny
  exit 0
fi

if [[ -z "$tool_name" || "$tool_name" == *$'\n'* || "$tool_name" == *$'\r'* ]]; then
  deny
  exit 0
fi

normalized_tool=$(builtin printf '%s' "$tool_name" | /usr/bin/tr '[:upper:]' '[:lower:]')
if [[ "$normalized_tool" == *github* || "$normalized_tool" == *supabase* || "$normalized_tool" == *cloudflare* ]]; then
  deny
  exit 0
fi

if [[ "$normalized_tool" != "bash" && "$normalized_tool" != "shell" ]]; then
  if [[ "$normalized_tool" == *computer* ]]; then
    computer_input=''
    if ! computer_input=$(/usr/bin/plutil -extract tool_input xml1 -o - "$temporary_input" 2>/dev/null); then
      deny
      exit 0
    fi
    normalized_computer=$(builtin printf '%s' "$computer_input" | /usr/bin/tr '[:upper:]' '[:lower:]')
    if [[ "$normalized_computer" == *accounts* || "$normalized_computer" == *organizer* || "$normalized_computer" == *signing* || "$normalized_computer" == *"signing team"* || "$normalized_computer" == *archive*upload* || "$normalized_computer" == *"app store connect"* ]]; then
      deny
      exit 0
    fi
  fi
  exit 0
fi

command=''
if ! command=$(/usr/bin/plutil -extract tool_input.command raw -expect string -o - "$temporary_input" 2>/dev/null); then
  deny
  exit 0
fi
normalized_command=${command//$'\n'/ }
normalized_command=${normalized_command//$'\r'/ }
normalized_command=${normalized_command//$'\t'/ }
normalized_command=${normalized_command//\\/}
normalized_command=$(builtin printf '%s' "$normalized_command" | /usr/bin/tr '[:upper:]' '[:lower:]')

is_fixed_op_wrapper=false
if [[ "$normalized_command" =~ ^tools/request-codex-op\.sh[[:space:]]+--request[[:space:]]+\.artifacts/ops-requests/[a-z0-9][a-z0-9-]*\.json[[:space:]]+--result[[:space:]]+\.artifacts/ops-results/[a-z0-9][a-z0-9-]*\.json$ ]]; then
  is_fixed_op_wrapper=true
fi

is_fixed_review_wrapper=false
if [[ "$normalized_command" =~ ^tools/request-codex-review\.sh[[:space:]]+--packet[[:space:]]+\.artifacts/issues/[1-9][0-9]*/[0-9a-f]{40}/[a-z0-9][a-z0-9._-]*\.json[[:space:]]+--output[[:space:]]+\.artifacts/issues/[1-9][0-9]*/[0-9a-f]{40}/review\.json$ ]]; then
  is_fixed_review_wrapper=true
fi

if [[ "$is_fixed_op_wrapper" == true || "$is_fixed_review_wrapper" == true ]]; then
  exit 0
fi

if [[ "$normalized_command" == *"~/library/application support/ios-template/secrets/"* || "$normalized_command" == *"/library/application support/ios-template/secrets/"* ]]; then
  deny
  exit 0
fi

if [[ "$normalized_command" == *authorization:* || "$normalized_command" == *"bearer "* || "$normalized_command" == *x-api-key* || "$normalized_command" == *api_key* || "$normalized_command" == *"--user "* || "$normalized_command" == *" -u "* || "$normalized_command" == *--netrc* ]]; then
  deny
  exit 0
fi

if [[ "$normalized_command" =~ (^|[[:space:];\|&])(gh|supabase|wrangler|elevenlabs|fastlane|codex)([[:space:];\|&]|$) ]]; then
  deny
  exit 0
fi

if [[ "$normalized_command" =~ (^|[[:space:];\|&])security[[:space:]]+find-generic-password([[:space:];\|&]|$) ]]; then
  deny
  exit 0
fi

if [[ "$normalized_command" =~ (^|[[:space:];\|&])git([[:space:];\|&]|$) ]] && [[ "$normalized_command" =~ (^|[[:space:];\|&])(push|pull|fetch)([[:space:];\|&]|$) ]]; then
  deny
  exit 0
fi

project_dir=${CLAUDE_PROJECT_DIR:-$(builtin cd "$(dirname "$0")/../.." && /bin/pwd -P)}
script_path=''
if [[ "$normalized_command" =~ ^(tools/[a-z0-9._/-]+\.sh)([[:space:]]|$) ]]; then
  script_path=${BASH_REMATCH[1]}
elif [[ "$normalized_command" =~ ^(/bin/bash|bash)[[:space:]]+(tools/[a-z0-9._/-]+\.sh)([[:space:]]|$) ]]; then
  script_path=${BASH_REMATCH[2]}
fi

if [[ -n "$script_path" ]]; then
  if [[ "$script_path" == *".."* || ! -f "$project_dir/$script_path" ]] || ! /usr/bin/git -C "$project_dir" ls-files --error-unmatch -- "$script_path" >/dev/null 2>&1; then
    deny
    exit 0
  fi
  if /usr/bin/grep -Eqi '(^|[^[:alnum:]_])(gh|supabase|wrangler|elevenlabs|fastlane|codex|security[[:space:]]+find-generic-password)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])git[[:space:]].*(push|pull|fetch)([^[:alnum:]_]|$)|Library/Application[[:space:]]+Support/iOS-Template/secrets/' "$project_dir/$script_path"; then
    deny
    exit 0
  fi
fi

exit 0
