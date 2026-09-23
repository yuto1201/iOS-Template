#!/bin/bash
set -euo pipefail
export LANG=en_US.UTF-8
[[ $- != *x* && $- != *v* ]] || exit 1
unset RUBYOPT RUBYLIB BASH_ENV ENV
root=$(cd "$(dirname "$0")/.." && pwd -P)
exec /usr/bin/ruby --disable-gems "$root/tools/lib/asc-cli.rb" run "$@"
