#!/bin/bash -p
set -euo pipefail

unset CDPATH ENV BASH_ENV GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

script_source="${BASH_SOURCE[0]}"
[[ "$script_source" == */* ]] || script_source="./$script_source"
script_dir=$(cd -P -- "${script_source%/*}" && /bin/pwd -P)

usage() {
  echo 'usage: tools/evaluate-evidence-applicability.sh --issue NUMBER --base-sha SHA --head-sha SHA --input PATH' >&2
  exit 64
}

issue='' base_sha='' head_sha='' input=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) [[ -z "$issue" && $# -ge 2 ]] || usage; issue=$2; shift 2 ;;
    --base-sha) [[ -z "$base_sha" && $# -ge 2 ]] || usage; base_sha=$2; shift 2 ;;
    --head-sha) [[ -z "$head_sha" && $# -ge 2 ]] || usage; head_sha=$2; shift 2 ;;
    --input) [[ -z "$input" && $# -ge 2 ]] || usage; input=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$issue" =~ ^[1-9][0-9]*$ && "$base_sha" =~ ^[0-9a-f]{40}$ && "$head_sha" =~ ^[0-9a-f]{40}$ && -n "$input" ]] || usage
repo_root="${script_dir%/tools}"
input_parent=$(cd -P -- "$(dirname "$input")" && /bin/pwd -P)
input="$input_parent/$(basename "$input")"

exec /usr/bin/ruby "$script_dir/lib/evidence-applicability-cli.rb" "$repo_root" "$issue" "$base_sha" "$head_sha" "$input"
