#!/bin/bash -p
set -euo pipefail

unset CDPATH ENV BASH_ENV DEVELOPER_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

usage() {
  echo "usage: tools/publish-documentation-verify.sh --issue NUMBER --expected-base SHA --expected-head SHA --input PATH" >&2
  exit 64
}

[[ "$#" -eq 8 ]] || usage

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
validator="$script_dir/validate-verify-json.swift"
[[ -f "$validator" && ! -L "$validator" ]] || {
  echo "trusted verification validator is unavailable" >&2
  exit 1
}

exec /usr/bin/swift "$validator" --publish-documentation "$@"
