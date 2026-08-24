#!/usr/bin/env bash
set -u

project_dir=${CLAUDE_PROJECT_DIR:-}
agents_file="$project_dir/AGENTS.md"

json_escape() {
  local value=$1 character escaped='' index
  for ((index = 0; index < ${#value}; index++)); do
    character=${value:index:1}
    case "$character" in
      '\\') escaped+='\\\\' ;;
      '"') escaped+='\\"' ;;
      $'\n') escaped+='\\n' ;;
      $'\r') escaped+='\\r' ;;
      $'\t') escaped+='\\t' ;;
      *) escaped+="$character" ;;
    esac
  done
  builtin printf '%s' "$escaped"
}

if [[ -z "$project_dir" || ! -f "$agents_file" ]]; then
  builtin printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"AGENTS.md is unavailable. Stop with blocked:environment and restore the repository contract before continuing."}}'
  exit 0
fi

agents_content=''
IFS= read -r -d '' agents_content < "$agents_file" || true
LC_ALL=C
if (( ${#agents_content} > 32768 )); then
  builtin printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"AGENTS.md exceeds 32768 bytes. Stop with blocked:environment; do not continue without the complete repository contract."}}'
  exit 0
fi

escaped_content=$(json_escape "$agents_content")
builtin printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"'"$escaped_content"'"}}'
