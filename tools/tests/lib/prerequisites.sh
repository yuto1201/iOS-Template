#!/bin/bash

# Test entrypoints call this before creating fixtures or evaluating assertions.
# type -P requires an external executable, not an interactive alias/function.
require_test_commands() {
  local test_name=${1##*/} required_command executable
  shift
  for required_command in "$@"; do
    executable=$(type -P -- "$required_command") || executable=''
    if [[ -z "$executable" || ! -x "$executable" || -d "$executable" ]]; then
      printf "test prerequisite unavailable (%s): missing executable '%s'; see docs/verification.md (test prerequisites)\n" \
        "$test_name" "$required_command" >&2
      return 69
    fi
  done
}

require_test_python_tomllib() {
  require_test_commands "$1" python3 || return $?
  if ! python3 -c 'import sys, tomllib; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
    printf 'test prerequisite unavailable (%s): Python 3.11+ with tomllib is required; see docs/verification.md (test prerequisites)\n' "${1##*/}" >&2
    return 69
  fi
}
