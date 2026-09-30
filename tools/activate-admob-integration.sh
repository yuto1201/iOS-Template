#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  echo 'usage: activate-admob-integration.sh --root DERIVED_APP_ROOT --input INPUT_JSON' >&2
  exit 64
}

root=''
input=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 && -z "$root" ]] || usage
      root="$2"
      shift 2
      ;;
    --input)
      [[ $# -ge 2 && -z "$input" ]] || usage
      input="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$root" && -n "$input" ]] || usage
exec ruby "$script_dir/lib/admob-activation.rb" apply --root "$root" --input "$input"
