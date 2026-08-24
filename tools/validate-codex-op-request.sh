#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: validate-codex-op-request.sh --request .artifacts/ops-requests/REQUEST.json' >&2; exit 2; }
[[ $# -eq 2 && "$1" == --request ]] || usage
request=$2
ruby "$repo_root/tools/lib/workflow-json.rb" validate-request "$request" "$repo_root/.artifacts" "$repo_root"
