#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
artifacts_root="$repo_root/.artifacts"
usage() { echo 'usage: request-codex-op.sh --request .artifacts/ops-requests/REQUEST.json --result .artifacts/ops-results/REQUEST.json' >&2; exit 2; }
[[ $# -eq 4 && "$1" == --request && "$3" == --result ]] || usage
request=$2 result=$4
request_json=$("$repo_root/tools/validate-codex-op-request.sh" --request "$request")
request_id=$(jq -er '.requestId' <<< "$request_json")
mkdir -p "$artifacts_root/ops-results"
artifacts_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$artifacts_root")
request_directory_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$artifacts_root/ops-requests")
result_directory_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$artifacts_root/ops-results")
[[ "$request_directory_real" == "$artifacts_real/"* && "$result_directory_real" == "$artifacts_real/"* ]] || { echo 'operation artifact path escapes .artifacts' >&2; exit 1; }
expected_result="$result_directory_real/$request_id.json"
request_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$request")
result_absolute=$(ruby -e 'puts File.expand_path(ARGV.fetch(0))' "$result")
[[ "$result_absolute" == "$expected_result" ]] || { echo 'result path must be the fixed path for this request ID' >&2; exit 1; }
[[ "$request_real" == "$request_directory_real/"* ]] || { echo 'request path is outside fixed request directory' >&2; exit 1; }

raw_output=$(mktemp "${TMPDIR:-/tmp}/ios-template-codex-op.XXXXXX")
trap 'rm -f "$raw_output"' EXIT
instruction=$(<"$repo_root/tools/lib/codex-external-op-instruction.md")
printf -v codex_prompt '%s\nValidated request: %s\nFixed result path: %s' "$instruction" "$request_real" "$expected_result"
codex exec --sandbox workspace-write -- "$codex_prompt" > "$raw_output"
result_source=$raw_output
[[ -f "$expected_result" ]] && result_source=$expected_result
sanitized=$(ruby "$repo_root/tools/lib/workflow-json.rb" sanitize-result "$result_source" "$request_real")
temporary=$(mktemp "${expected_result}.tmp.XXXXXX")
printf '%s\n' "$sanitized" > "$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$expected_result"
trap - EXIT
printf '%s\n' "$sanitized"
