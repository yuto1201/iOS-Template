#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  echo 'usage: validate-admob-integration.sh --root DERIVED_APP_ROOT [--readiness [--source-packages DIR] [--evidence FILE]]' >&2
  exit 64
}

[[ $# -ge 2 && "$1" == '--root' ]] || usage
root=$2
shift 2
[[ $# -eq 0 ]] && exec ruby "$script_dir/lib/admob-activation.rb" validate --root "$root"
[[ "$1" == '--readiness' ]] || usage
shift
exec ruby "$script_dir/lib/admob-activation.rb" readiness --root "$root" "$@"
