#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: request-codex-op.sh --request .artifacts/ops-requests/REQUEST.json --result .artifacts/ops-results/REQUEST.json' >&2; exit 2; }
[[ $# -eq 4 && "$1" == --request && "$3" == --result ]] || usage
request=$2 result=$4
umask 077
"$repo_root/tools/validate-codex-op-request.sh" --request "$request" >/dev/null
ruby "$repo_root/tools/lib/workflow-json.rb" run-codex-transport "$request" "$result"
