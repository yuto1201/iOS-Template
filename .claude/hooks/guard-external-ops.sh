#!/usr/bin/env bash
set -u

deny_reason='個人用の認証済み外部操作または秘密情報へのアクセスです。codex-external-ops で Codexへ委託してください。'

deny() {
  /usr/bin/printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"'"$deny_reason"'"}}'
}

normalize_text() {
  builtin printf '%s' "$1" | /usr/bin/tr '[:upper:]\n\r\t' '[:lower:]   '
}

xcode_mcp_action_is_allowed() {
  case "$1" in
    boot_sim|build_run_sim|build_sim|clean|discover_projs|get_app_bundle_id|get_coverage_report|get_file_coverage|get_sim_app_path|install_app_sim|launch_app_sim|list_schemes|list_sims|open_sim|record_sim_video|screenshot|show_build_settings|snapshot_ui|stop_app_sim|test_sim) return 0 ;;
    session_clear_defaults|session_set_defaults|session_show_defaults) return 0 ;;
    batch|button|drag|gesture|key_press|key_sequence|long_press|swipe|tap|touch|type_text|wait_for_ui) return 0 ;;
    debug_attach_sim|debug_breakpoint_add|debug_breakpoint_remove|debug_continue|debug_detach|debug_stack|debug_variables) return 0 ;;
    *) return 1 ;;
  esac
}

contains_restricted_material() {
  local value safe_value
  value=$(normalize_text "$1")
  value=${value//\\/}
  safe_value=${value//.env.example/.env-example-public}

  if [[ "$safe_value" == *"/library/application support/ios-template/secrets"* ||
        "$safe_value" == *"/library/keychains/"* ||
        "$safe_value" == *"/.config/gh/hosts.yml"* ||
        "$safe_value" == *"/.config/supabase/"* ||
        "$safe_value" == *"/.wrangler/"* ||
        "$safe_value" == *"/.aws/credentials"* ||
        "$safe_value" == *"/.netrc"* ||
        "$safe_value" == *"/.npmrc"* ||
        "$safe_value" == *"/.pypirc"* ]]; then
    return 0
  fi

  if [[ "$safe_value" =~ (^|[/[:space:]\"\'=])\.env([.][a-z0-9_-]+)?([^a-z0-9_-]|$) ||
        "$safe_value" =~ /\.ssh/(id_rsa|id_dsa|id_ecdsa|id_ed25519)([^a-z0-9_-]|$) ||
        "$safe_value" =~ \.(p8|p12|pem|key)([^a-z0-9_-]|$) ||
        "$safe_value" =~ (^|[/[:space:]\"\'=])[^/[:space:]\"\']*(api[-_]?token|access[-_]?token|auth[-_]?token|private[-_]?key|secret[-_]?key)[^/[:space:]\"\']*([/[:space:]\"\']|$) ]]; then
    return 0
  fi

  if [[ "$safe_value" == *authorization:* || "$safe_value" == *"bearer "* ||
        "$safe_value" == *x-api-key* || "$safe_value" == *api_key* ]]; then
    return 0
  fi
  return 1
}

command_is_forbidden() {
  local command script_mode=${2:-false}
  local provider_pattern shell_eval_pattern shell_prefixed_eval_pattern
  local interpreter_eval_pattern interpreter_prefixed_eval_pattern plumbing_pattern
  local git_token_pattern remote_git_pattern security_read_pattern network_pattern
  local shell_boundary token_left token_right
  command=$(normalize_text "$1")
  command=${command//\\/}
  # Shell quoting can split a command name without changing the executed token
  # (for example g"h"). Match the dequoted spelling and fail closed.
  command=${command//\'/}
  command=${command//\"/}

  shell_boundary="[[:space:];|&()<>{}=!?,\`\$\"']"
  token_left="(^|/|$shell_boundary)"
  token_right="($shell_boundary|$)"

  contains_restricted_material "$command" && return 0

  provider_pattern="${token_left}(gh|supabase|wrangler|elevenlabs|fastlane|codex|itms-transporter|transporter)${token_right}"
  if [[ "$command" =~ $provider_pattern ||
        "$command" =~ ${token_left}xcrun[[:space:]]+(altool|notarytool)${token_right} ]]; then
    return 0
  fi

  shell_eval_pattern="${token_left}((ba|z|da|fi)?sh|fish)[[:space:]]*(-[^[:space:]]*c|--command)"
  shell_prefixed_eval_pattern="${token_left}((ba|z|da|fi)?sh|fish)[^;|&]*[[:space:]](-[a-z]*c[a-z]*|--command)${token_right}"
  interpreter_eval_pattern="${token_left}(python[0-9.]*|ruby|perl|node)[[:space:]]*(-[^[:space:]]*[ce]|--(command|eval))"
  interpreter_prefixed_eval_pattern="${token_left}(python[0-9.]*|ruby|perl|node)[^;|&]*[[:space:]](-[ce]|--(command|eval))([=]|${token_right})"
  if [[ "$command" =~ $shell_eval_pattern || "$command" =~ $shell_prefixed_eval_pattern ||
        "$command" =~ $interpreter_eval_pattern || "$command" =~ $interpreter_prefixed_eval_pattern ||
        "$command" =~ ${token_left}(eval|osascript[[:space:]]+-e)${token_right} ]]; then
    return 0
  fi

  if [[ "$command" =~ ${token_left}xargs${token_right} ||
        "$command" =~ ${token_left}find[[:space:]].*-(exec|execdir|ok|okdir)${token_right} ]]; then
    return 0
  fi
  if [[ "$command" =~ ${token_left}env[[:space:]].*(--split-string|--chdir|-s|-c)([=]|${token_right}) ]]; then
    return 0
  fi

  if [[ "$command" == *"--user "* || "$command" == *" -u "* || "$command" == *--netrc* ||
        "$command" == *git_askpass* || "$command" == *ssh_askpass* ||
        "$command" == *git_exec_path* || "$command" == *credential.helper* ||
        "$command" == *core.sshcommand* || "$command" == *protocol.ext* ]]; then
    return 0
  fi

  security_read_pattern="${token_left}security[[:space:]]+(find-generic-password|find-internet-password|find-identity|dump-keychain|export|unlock-keychain|list-keychains)${token_right}"
  [[ "$command" =~ $security_read_pattern ]] && return 0

  plumbing_pattern="${token_left}(git-(send-pack|fetch-pack|http-fetch|http-push|credential[^[:space:];|&()]*|remote-[^[:space:];|&()]+|upload-pack|receive-pack|daemon))${token_right}"
  [[ "$command" =~ $plumbing_pattern ]] && return 0

  git_token_pattern='(^|[^[:alnum:]_.-])(/[^[:space:];|&()]*/)?git([[:space:]]|$)'
  remote_git_pattern='(^|[^[:alnum:]_-])(push|pull|fetch|clone|ls-remote|remote|submodule|archive|send-pack|fetch-pack|http-fetch|http-push|credential|upload-pack|receive-pack|daemon)([^[:alnum:]_-]|$)'
  if [[ "$command" =~ $git_token_pattern && "$command" =~ $remote_git_pattern ]]; then
    return 0
  fi
  if [[ "$command" =~ $git_token_pattern &&
        ( "$command" == *--exec-path* || "$command" =~ [[:space:]]alias\.[^[:space:]=]+[=[:space:]] ) ]]; then
    return 0
  fi

  if [[ "$command" =~ ${token_left}(ssh|scp|sftp)${token_right} ||
        "$command" =~ ${token_left}rsync[[:space:]].*(rsync://|[^[:space:]]+:[^[:space:]]+) ]]; then
    return 0
  fi

  if [[ "$script_mode" == true ]]; then
    network_pattern="${token_left}(curl|wget|nc|ncat)${token_right}"
    [[ "$command" =~ $network_pattern ]] && return 0
  fi

  return 1
}

project_dir=${CLAUDE_PROJECT_DIR:-$(builtin cd "$(dirname "$0")/../.." && /bin/pwd -P)}
project_real=$(/bin/realpath "$project_dir" 2>/dev/null || builtin printf '%s' "$project_dir")
visited_scripts=$'\n'
scanned_script_count=0

command_resolves_restricted_path() {
  local command=$1 token candidate resolved
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    token=${token//\'/}
    token=${token//\"/}
    candidate=${token#*=}
    if [[ "$candidate" != /* && "$candidate" != ~* ]]; then
      candidate="$project_dir/$candidate"
    fi
    if [[ -e "$candidate" || -L "$candidate" ]]; then
      resolved=$(/bin/realpath "$candidate" 2>/dev/null || builtin printf '%s' "$candidate")
      contains_restricted_material "$resolved" && return 0
      command_is_forbidden "$resolved" false && return 0
    fi
  done < <(builtin printf '%s\n' "$command" | /usr/bin/tr '[:space:];|&<>()' '\n')
  return 1
}

script_is_forbidden() {
  local requested=$1 depth=${2:-0} relative full resolved resolved_relative contents child
  if (( depth > 16 || scanned_script_count >= 64 )); then
    return 0
  fi

  relative=${requested#./}
  if [[ "$relative" == "$project_dir/"* ]]; then
    relative=${relative#"$project_dir/"}
  elif [[ "$relative" == /* ]]; then
    return 0
  fi
  if [[ "$relative" != tools/*.sh || "$relative" == *".."* ]]; then
    return 0
  fi

  full="$project_dir/$relative"
  [[ -f "$full" ]] || return 0
  /usr/bin/git -C "$project_dir" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 || return 0
  resolved=$(/bin/realpath "$full" 2>/dev/null) || return 0
  [[ "$resolved" == "$project_real/"* ]] || return 0
  resolved_relative=${resolved#"$project_real/"}
  /usr/bin/git -C "$project_dir" ls-files --error-unmatch -- "$resolved_relative" >/dev/null 2>&1 || return 0

  if [[ "$visited_scripts" == *$'\n'"$resolved_relative"$'\n'* ]]; then
    return 1
  fi
  visited_scripts+="$resolved_relative"$'\n'
  scanned_script_count=$((scanned_script_count + 1))

  contents=$(/bin/cat "$resolved" 2>/dev/null) || return 0
  command_is_forbidden "$contents" true && return 0

  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    script_is_forbidden "$child" $((depth + 1)) && return 0
  done < <(builtin printf '%s\n' "$contents" | /usr/bin/grep -Eo '(\./)?tools/[A-Za-z0-9._/-]+\.sh' | /usr/bin/sort -u)
  return 1
}

extract_invoked_script() {
  local command=$1 path_pattern shell_pattern end_pattern prefix
  command=${command//\\/}
  command=${command//\'/}
  command=${command//\"/}
  path_pattern='(\./)?tools/[A-Za-z0-9._/-]+\.sh'
  end_pattern='([[:space:];|&)]|$)'

  if [[ "$command" =~ ^[[:space:]]*(/[^[:space:]]*/)?env[[:space:]]+ ]]; then
    prefix=${BASH_REMATCH[0]}
    command=${command#"$prefix"}
    while [[ "$command" =~ ^(-i|--ignore-environment|--)[[:space:]]+ ]]; do
      prefix=${BASH_REMATCH[0]}
      command=${command#"$prefix"}
    done
    while [[ "$command" =~ ^(-u[[:space:]]+[^[:space:]]+|--unset(=|[[:space:]]+)[^[:space:]]+)[[:space:]]+ ]]; do
      prefix=${BASH_REMATCH[0]}
      command=${command#"$prefix"}
    done
    while [[ "$command" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+ ]]; do
      prefix=${BASH_REMATCH[0]}
      command=${command#"$prefix"}
    done
  fi

  if [[ "$command" =~ ^[[:space:]]*($path_pattern)$end_pattern ]]; then
    builtin printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$command" == "$project_dir/"* && "$command" =~ ^[[:space:]]*($project_dir/tools/[A-Za-z0-9._/-]+\.sh)$end_pattern ]]; then
    builtin printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  shell_pattern='(/[^[:space:]]*/)?(bash|sh|zsh|dash)'
  if [[ "$command" =~ ^[[:space:]]*$shell_pattern[[:space:]]+($path_pattern)$end_pattern ]]; then
    builtin printf '%s' "${BASH_REMATCH[3]}"
    return 0
  fi
  if [[ "$command" =~ ^[[:space:]]*$shell_pattern[[:space:]]*\<[[:space:]]*($path_pattern)$end_pattern ]]; then
    builtin printf '%s' "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

command_invokes_forbidden_script() {
  local command=$1 segment prefix invoked leading_group_pattern
  leading_group_pattern='^[[:space:]]*[(\!][[:space:]]*'
  while IFS= read -r segment; do
    while [[ "$segment" =~ $leading_group_pattern ]]; do
      prefix=${BASH_REMATCH[0]}
      segment=${segment#"$prefix"}
    done
    invoked=''
    if invoked=$(extract_invoked_script "$segment") && [[ -n "$invoked" ]]; then
      script_is_forbidden "$invoked" 0 && return 0
    fi
  done < <(builtin printf '%s\n' "$command" | /usr/bin/tr '\n;|&' '\n')
  return 1
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

normalized_tool=$(normalize_text "$tool_name")
# XcodeBuildMCP is the only documented local-only MCP server required for
# repository Xcode/Simulator work. Claude installations currently expose it as
# xcodebuild; retain xcodebuildmcp for installations using the descriptive name.
# Every other MCP server fails closed.
is_local_xcode_mcp=false
xcode_mcp_action=''
if [[ "$normalized_tool" == mcp__xcodebuild__?* ]]; then
  is_local_xcode_mcp=true
  xcode_mcp_action=${normalized_tool#mcp__xcodebuild__}
elif [[ "$normalized_tool" == mcp__xcodebuildmcp__?* ]]; then
  is_local_xcode_mcp=true
  xcode_mcp_action=${normalized_tool#mcp__xcodebuildmcp__}
elif [[ "$normalized_tool" == mcp__* ]]; then
  deny
  exit 0
fi
if [[ "$is_local_xcode_mcp" == true ]] && ! xcode_mcp_action_is_allowed "$xcode_mcp_action"; then
  deny
  exit 0
fi
if [[ "$normalized_tool" == *github* || "$normalized_tool" == *supabase* ||
      "$normalized_tool" == *cloudflare* || "$normalized_tool" == *elevenlabs* ||
      "$normalized_tool" == *appstore* || "$normalized_tool" == *app-store* ||
      "$normalized_tool" == *fastlane* || "$normalized_tool" == *codex* ]]; then
  deny
  exit 0
fi

tool_input=''
if ! tool_input=$(/usr/bin/plutil -extract tool_input xml1 -o - "$temporary_input" 2>/dev/null); then
  deny
  exit 0
fi
if contains_restricted_material "$tool_input"; then
  deny
  exit 0
fi

if [[ "$is_local_xcode_mcp" == true ]]; then
  normalized_xcode_input=$(normalize_text "$tool_input")
  if [[ "$normalized_xcode_input" == *accounts* || "$normalized_xcode_input" == *organizer* ||
        "$normalized_xcode_input" == *"signing team"* || "$normalized_xcode_input" == *archive*upload* ||
        "$normalized_xcode_input" == *"app store connect"* || "$normalized_xcode_input" == *keychain* ]]; then
    deny
    exit 0
  fi
  if [[ "$xcode_mcp_action" == session_set_defaults ]]; then
    for forbidden_key in deviceId platform persist; do
      if /usr/bin/plutil -extract "tool_input.$forbidden_key" raw -o - "$temporary_input" >/dev/null 2>&1; then
        deny
        exit 0
      fi
    done
  fi
fi

for input_path_key in file_path path; do
  input_path=''
  if input_path=$(/usr/bin/plutil -extract "tool_input.$input_path_key" raw -expect string -o - "$temporary_input" 2>/dev/null) &&
     [[ -n "$input_path" && ( -e "$input_path" || -L "$input_path" ) ]]; then
    resolved_input_path=$(/bin/realpath "$input_path" 2>/dev/null || builtin printf '%s' "$input_path")
    if contains_restricted_material "$resolved_input_path"; then
      deny
      exit 0
    fi
  fi
done

if [[ "$normalized_tool" != bash && "$normalized_tool" != shell ]]; then
  if [[ "$normalized_tool" == *computer* ]]; then
    normalized_computer=$(normalize_text "$tool_input")
    if [[ "$normalized_computer" == *accounts* || "$normalized_computer" == *organizer* ||
          "$normalized_computer" == *signing* || "$normalized_computer" == *"signing team"* ||
          "$normalized_computer" == *archive*upload* || "$normalized_computer" == *"app store connect"* ||
          "$normalized_computer" == *keychain* ]]; then
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

normalized_command=$(normalize_text "$command")
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

if command_resolves_restricted_path "$command"; then
  deny
  exit 0
fi

if command_is_forbidden "$command" false; then
  deny
  exit 0
fi

if command_invokes_forbidden_script "$command"; then
  deny
  exit 0
fi

exit 0
