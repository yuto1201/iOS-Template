#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
artifacts_root="$repo_root/.artifacts"
usage() { echo 'usage: request-codex-op.sh --request .artifacts/ops-requests/REQUEST.json --result .artifacts/ops-results/REQUEST.json' >&2; exit 2; }
[[ $# -eq 4 && "$1" == --request && "$3" == --result ]] || usage
request=$2 result=$4
request_json=$("$repo_root/tools/validate-codex-op-request.sh" --request "$request")
request_id=$(jq -er '.requestId' <<< "$request_json")
umask 077
mkdir -p "$artifacts_root/ops-results" "$artifacts_root/ops-requests/.sealed"
artifacts_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$artifacts_root")
request_directory_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$artifacts_root/ops-requests")
result_directory_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$artifacts_root/ops-results")
sealed_directory_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$artifacts_root/ops-requests/.sealed")
[[ "$request_directory_real" == "$artifacts_real/"* && "$result_directory_real" == "$artifacts_real/"* && "$sealed_directory_real" == "$request_directory_real/.sealed" ]] || { echo 'operation artifact path escapes .artifacts' >&2; exit 1; }
expected_result="$result_directory_real/$request_id.json"
request_real=$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$request")
result_absolute=$(ruby -e 'puts File.expand_path(ARGV.fetch(0))' "$result")
[[ "$result_absolute" == "$expected_result" ]] || { echo 'result path must be the fixed path for this request ID' >&2; exit 1; }
[[ "$request_real" == "$request_directory_real/"* ]] || { echo 'request path is outside fixed request directory' >&2; exit 1; }

raw_output=$(mktemp "${TMPDIR:-/tmp}/ios-template-codex-op.XXXXXX")
snapshot=$(mktemp "$sealed_directory_real/${request_id}.XXXXXX")
trap 'rm -f "$raw_output" "$snapshot"' EXIT
printf '%s' "$request_json" > "$snapshot"
chmod 400 "$snapshot"
snapshot_digest="sha256:$(ruby -rdigest -e 'print Digest::SHA256.hexdigest(File.binread(ARGV.fetch(0)))' "$snapshot")"
ruby "$repo_root/tools/lib/workflow-json.rb" verify-request-snapshot "$snapshot" "$snapshot_digest" "$(jq -er '.expectedAccount' <<< "$request_json")" "$repo_root" >/dev/null
instruction=$(<"$repo_root/tools/lib/codex-external-op-instruction.md")
printf -v codex_prompt '%s\nValidated request snapshot: %s\nSnapshot digest: %s\nFixed result path: %s' "$instruction" "$snapshot" "$snapshot_digest" "$expected_result"
codex exec --sandbox workspace-write -- "$codex_prompt" </dev/null > "$raw_output"
result_source=$raw_output
[[ -f "$expected_result" ]] && result_source=$expected_result
ruby "$repo_root/tools/lib/workflow-json.rb" verify-request-snapshot "$snapshot" "$snapshot_digest" "$(jq -er '.expectedAccount' <<< "$request_json")" "$repo_root" >/dev/null
sanitized=$(ruby "$repo_root/tools/lib/workflow-json.rb" sanitize-result "$result_source" "$snapshot")
temporary=$(mktemp "${expected_result}.tmp.XXXXXX")
printf '%s\n' "$sanitized" > "$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$expected_result"
rm -f "$snapshot"
trap 'rm -f "$raw_output"' EXIT
printf '%s\n' "$sanitized"
