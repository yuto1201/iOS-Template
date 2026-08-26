#!/bin/bash
set -euo pipefail

fail() {
  printf '%s\n' "private-key execution refused: $1" >&2
  exit 1
}

[[ $- != *x* && $- != *v* ]] || fail 'shell tracing is not permitted'

usage() {
  echo 'usage: run-with-private-key.sh --app SLUG --file ABSOLUTE_P8 --env VARIABLE -- ABSOLUTE_COMMAND [ARG...]' >&2
  exit 2
}

app_slug=''
private_key_file=''
environment_name=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app_slug=${2:-}; shift 2 ;;
    --file) private_key_file=${2:-}; shift 2 ;;
    --env) environment_name=${2:-}; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[[ "$app_slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail 'app slug is invalid'
[[ "$environment_name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || fail 'environment variable name is invalid'
[[ "${HOME:-}" == /* ]] || fail 'HOME must be an absolute directory'
[[ "$private_key_file" == /* && "$private_key_file" == *.p8 && -f "$private_key_file" && ! -L "$private_key_file" ]] || fail 'private key must be a physical absolute .p8 file'
[[ $# -ge 1 ]] || usage

approved_parent="$HOME/Library/Application Support/iOS-Template/secrets"
approved_directory="$approved_parent/$app_slug"
[[ -d "$approved_parent" && ! -L "$approved_parent" && -d "$approved_directory" && ! -L "$approved_directory" ]] || fail 'approved secret directory is unavailable'
physical_parent=$(cd "$approved_parent" && /bin/pwd -P)
physical_directory=$(cd "$approved_directory" && /bin/pwd -P)
physical_file_parent=$(cd "$(dirname "$private_key_file")" && /bin/pwd -P)
physical_home=$(cd "$HOME" && /bin/pwd -P)
expected_physical_parent="$physical_home/Library/Application Support/iOS-Template/secrets"
expected_physical_directory="$expected_physical_parent/$app_slug"
[[ "$physical_parent" == "$expected_physical_parent" && "$physical_directory" == "$expected_physical_directory" && "$physical_file_parent" == "$expected_physical_directory" ]] || fail 'private key path contains a symlink or leaves the approved directory'
relative_private_key=${private_key_file#"$approved_directory/"}
[[ "$relative_private_key" != "$private_key_file" && -n "$relative_private_key" && "$relative_private_key" != */* ]] || fail 'private key must be directly inside the app secret directory'

current_uid=$(/usr/bin/id -u)
for secure_directory in "$approved_parent" "$approved_directory"; do
  [[ "$(/usr/bin/stat -f '%u' "$secure_directory")" == "$current_uid" ]] || fail 'secret directory owner differs'
  [[ "$(/usr/bin/stat -f '%Lp' "$secure_directory")" == 700 ]] || fail 'secret directory mode must be 0700'
done
[[ "$(/usr/bin/stat -f '%u' "$private_key_file")" == "$current_uid" ]] || fail 'private key owner differs'
[[ "$(/usr/bin/stat -f '%Lp' "$private_key_file")" == 600 ]] || fail 'private key mode must be 0600'
[[ "$(/usr/bin/stat -f '%l' "$private_key_file")" == 1 ]] || fail 'private key must have one hard link'

command_executable=$1
[[ "$command_executable" == /* && -f "$command_executable" && -x "$command_executable" && ! -L "$command_executable" ]] || fail 'child command must be a physical absolute executable'
command_basename=${command_executable##*/}
case "$command_basename" in
  sh|bash|zsh|dash|ksh|fish|env|xargs) fail 'shell evaluation commands are not permitted' ;;
esac
for command_argument in "$@"; do
  case "$command_argument" in
    *'$('*|*'${'*|*'`'*) fail 'shell evaluation strings are not permitted' ;;
  esac
done

printf -v "$environment_name" '%s' "$private_key_file"
export "$environment_name"
exec "$@"
