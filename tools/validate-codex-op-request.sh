#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: validate-codex-op-request.sh --request .artifacts/ops-requests/REQUEST.json' >&2; exit 2; }
[[ $# -eq 2 && "$1" == --request ]] || usage
request=$2
expected_account=$(ruby -ne 'puts $1 if /^\s*login:\s*([A-Za-z0-9-]+)\s*$/' "$repo_root/Config/ownership.yml")
[[ -n "$expected_account" ]] || { echo 'configured GitHub login is missing' >&2; exit 1; }
ruby "$repo_root/tools/lib/workflow-json.rb" validate-request "$request" "$repo_root/.artifacts" "$expected_account" "$repo_root"
