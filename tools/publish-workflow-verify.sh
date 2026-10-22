#!/bin/bash -p
set -euo pipefail

unset CDPATH ENV BASH_ENV DEVELOPER_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

usage() {
  echo "usage: tools/publish-workflow-verify.sh --issue NUMBER --expected-base SHA --expected-head SHA --input PATH" >&2
  exit 64
}

[[ "$#" -eq 8 ]] || usage

script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
validator="$script_dir/validate-verify-json.swift"
[[ -f "$validator" && ! -L "$validator" ]] || {
  echo "trusted verification validator is unavailable" >&2
  exit 1
}

# #411: the validator runs from a binary compiled once per source and toolchain (tools/lib/swift-tool-cache.sh).
source "$script_dir/lib/swift-tool-cache.sh"
validator_binary="$(swift_tool_binary "$validator")" || exit 1
exec "$validator_binary" --publish-workflow "$@"
