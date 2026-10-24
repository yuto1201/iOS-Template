#!/bin/bash
set -euo pipefail

# Links one user skill of this template (D-078) in the Mac skill layout of D-089: ~/.agents/skills/<name>,
# which Codex reads, becomes a symlink to .agents/user-skills/<name> of this checkout, and
# ~/.claude/skills/<name> becomes the relative symlink ../../.agents/skills/<name>. Nothing is made in
# ~/.codex/skills. Every destination is checked before anything changes: a folder or file of that name,
# or a symlink to another place, stops the tool with nothing changed. A symlink that is already the
# expected one is left as it is. A missing skills/ folder is created.

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

# Prints "linked" when the destination is already the expected symlink, "create" when it can be made, or
# one refusal line, without changing anything.
destination_state() {
  local tool_dir=$1 target=$2 destination="$1/skills/${name}" folder
  if [[ -L "$destination" ]]; then
    if [[ "$(readlink "$destination")" == "$target" ]]; then
      echo linked
    else
      echo "refuse: ${destination} is a symlink to $(readlink "$destination"), not to ${target}"
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

agents_target=$source_dir
claude_target="../../.agents/skills/${name}"
agents_state=$(destination_state "$HOME/.agents" "$agents_target")
claude_state=$(destination_state "$HOME/.claude" "$claude_target")
refused=0
for state in "$agents_state" "$claude_state"; do
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
  local tool_dir=$1 target=$2 state=$3 destination="$1/skills/${name}"
  if [[ "$state" == linked ]]; then
    echo "already linked: ${destination} -> ${target}"
    return
  fi
  mkdir -p "$tool_dir/skills"
  # symlink(2) fails if the destination appeared meanwhile, instead of linking inside a new folder.
  /usr/bin/ruby -e 'File.symlink(ARGV[0], ARGV[1])' "$target" "$destination"
  echo "linked: ${destination} -> ${target}"
}

# The Codex link is made first, so the Claude link never points at a missing entry.
link_one "$HOME/.agents" "$agents_target" "$agents_state"
link_one "$HOME/.claude" "$claude_target" "$claude_state"
