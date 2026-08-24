#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
usage() { echo 'usage: request-codex-review.sh --packet .artifacts/issues/ISSUE/HEAD/PACKET.json --output .artifacts/issues/ISSUE/HEAD/review.json' >&2; exit 2; }
[[ $# -eq 4 && "$1" == --packet && "$3" == --output ]] || usage
packet=$2 output=$4
packet_json=$("$repo_root/tools/validate-review-result.sh" --primary claude --packet "$packet")
issue=$(jq -er '.issue' <<<"$packet_json")
head_sha=$(jq -er '.headSha' <<<"$packet_json")
expected_output=".artifacts/issues/$issue/$head_sha/review.json"
[[ "$output" == "$expected_output" ]] || { echo 'review output must be the canonical Issue/Head review.json path' >&2; exit 1; }

instruction='You are the opposite-model acceptance auditor. Read only the supplied local review packet and files it references. Do not edit files, run tests, operate simulators, commit, push, use network services, authentication, or external tools. Return only one JSON object conforming exactly to docs/agent-contracts/review-packet.md Result schema.'
packet_absolute="$repo_root/$packet"
prompt="$instruction
Validated review packet: $packet_absolute"
ruby -rtimeout -e '
  command = ARGV
  pid = Process.spawn(*command, in: File::NULL)
  begin
    Timeout.timeout(600) { Process.wait(pid) }
  rescue Timeout::Error
    Process.kill("TERM", pid) rescue nil
    begin; Timeout.timeout(5) { Process.wait(pid) }; rescue Timeout::Error; Process.kill("KILL", pid) rescue nil; Process.wait(pid) rescue nil; end
    exit 124
  end
  exit($?.exitstatus || 1)
' codex exec --sandbox read-only --ephemeral -- "$prompt"
