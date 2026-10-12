#!/bin/bash
set -euo pipefail

# Links one user skill of this template (D-078) into the Claude and Codex skill folders of $HOME:
# ~/.claude/skills/<name> and ~/.codex/skills/<name> become symlinks to .agents/user-skills/<name> of
# this checkout. Every destination is checked before anything changes: a folder or file of that name,
# or a symlink to another place, stops the tool with nothing changed. A symlink to this skill already
# is left as it is. A missing skills/ folder is created.

usage() {
  echo "usage: link-user-skill.sh <name>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
name=$1
[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
  echo "link-user-skill: invalid skill name: ${name}" >&2
  exit 2
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
source_dir="$repo_root/.agents/user-skills/${name}"
[[ -d "$source_dir" && ! -L "$source_dir" && -f "$source_dir/SKILL.md" && ! -L "$source_dir/SKILL.md" ]] || {
  echo "link-user-skill: no user skill with a SKILL.md at ${source_dir}" >&2
  exit 1
}
[[ -n "${HOME:-}" && "$HOME" == /* && -d "$HOME" ]] || {
  echo "link-user-skill: HOME must be an existing absolute folder" >&2
  exit 1
}

# Prints "linked" when the destination is already this skill's symlink, "create" when it can be made,
# or one refusal line, without changing anything.
destination_state() {
  local tool_dir=$1 destination="$1/skills/${name}" folder
  if [[ -L "$destination" ]]; then
    if [[ "$(readlink "$destination")" == "$source_dir" ]]; then
      echo linked
    else
      echo "refuse: ${destination} is a symlink to $(readlink "$destination"), not to ${source_dir}"
    fi
    return
  fi
  if [[ -e "$destination" ]]; then
    echo "refuse: ${destination} already exists as a folder or file"
    return
  fi
  for folder in "$tool_dir" "$tool_dir/skills"; do
    if [[ -e "$folder" || -L "$folder" ]] && [[ ! -d "$folder" ]]; then
      echo "refuse: ${folder} is not a folder"
      return
    fi
  done
  echo create
}

claude_state=$(destination_state "$HOME/.claude")
codex_state=$(destination_state "$HOME/.codex")
refused=0
for state in "$claude_state" "$codex_state"; do
  if [[ "$state" == refuse:* ]]; then
    echo "link-user-skill: ${state#refuse: }" >&2
    refused=1
  fi
done
if [[ $refused -ne 0 ]]; then
  echo "link-user-skill: nothing was changed" >&2
  exit 1
fi

link_one() {
  local tool_dir=$1 state=$2 destination="$1/skills/${name}"
  if [[ "$state" == linked ]]; then
    echo "already linked: ${destination} -> ${source_dir}"
    return
  fi
  mkdir -p "$tool_dir/skills"
  # symlink(2) fails if the destination appeared meanwhile, instead of linking inside a new folder.
  /usr/bin/ruby -e 'File.symlink(ARGV[0], ARGV[1])' "$source_dir" "$destination"
  echo "linked: ${destination} -> ${source_dir}"
}

link_one "$HOME/.claude" "$claude_state"
link_one "$HOME/.codex" "$codex_state"
