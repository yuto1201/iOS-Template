#!/bin/bash -p
set -euo pipefail

unset CDPATH
script_source="${BASH_SOURCE[0]}"
[[ "$script_source" == */* ]] || script_source="./$script_source"
script_dir=$(cd -P -- "${script_source%/*}" && /bin/pwd -P)
usage() { echo 'usage: prepare-review-packet.sh --primary codex|claude --issue NUMBER --base-sha SHA --head-sha SHA' >&2; exit 2; }

primary='' issue='' base_sha='' head_sha=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary) [[ -z "$primary" && $# -ge 2 ]] || usage; primary=$2; shift 2 ;;
    --issue) [[ -z "$issue" && $# -ge 2 ]] || usage; issue=$2; shift 2 ;;
    --base-sha) [[ -z "$base_sha" && $# -ge 2 ]] || usage; base_sha=$2; shift 2 ;;
    --head-sha) [[ -z "$head_sha" && $# -ge 2 ]] || usage; head_sha=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ ( "$primary" == codex || "$primary" == claude ) && "$issue" =~ ^[1-9][0-9]*$ && "$base_sha" =~ ^[0-9a-f]{40}$ && "$head_sha" =~ ^[0-9a-f]{40}$ ]] || usage
exec /usr/bin/ruby "$script_dir/lib/prepare-review-packet.rb" "${script_dir%/tools}" "$primary" "$issue" "$base_sha" "$head_sha"
