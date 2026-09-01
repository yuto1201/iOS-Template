#!/usr/bin/env bash

BOUNDED_COMMAND_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BOUNDED_COMMAND_RUBY="$BOUNDED_COMMAND_LIB_DIR/bounded-command.rb"

bounded_run() {
  local bounded_stage=$1 bounded_timeout=$2
  shift 2
  [[ "$bounded_stage" =~ ^[A-Za-z0-9_.-]{1,80}$ && "$bounded_timeout" =~ ^[1-9][0-9]*$ && $# -gt 0 ]] || return 2
  /usr/bin/ruby --disable-gems "$BOUNDED_COMMAND_RUBY" \
    --stage "$bounded_stage" --timeout-seconds "$bounded_timeout" --grace-seconds 5 -- "$@"
}
