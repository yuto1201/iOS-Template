#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

if [[ $# -ne 2 || "$1" != '--root' ]]; then
  echo 'usage: validate-admob-integration.sh --root DERIVED_APP_ROOT' >&2
  exit 64
fi

exec ruby "$script_dir/lib/admob-activation.rb" validate --root "$2"
