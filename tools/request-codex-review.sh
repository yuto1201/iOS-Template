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
codex_bin=$(command -v codex)
[[ "$codex_bin" == /* && -x "$codex_bin" ]] || { echo 'Codex executable is unavailable' >&2; exit 1; }
review_home=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-codex-review.XXXXXX")
chmod 700 "$review_home"
review_bin="$review_home/bin"
mkdir "$review_bin"
ln -s /usr/bin/uname "$review_bin/uname"
review_codex_home=${CODEX_HOME:-"$HOME/.codex"}
trap 'rm -rf "$review_home"' EXIT
ruby -rtimeout - "$review_home" "$review_bin" "$review_codex_home" "$codex_bin" --ask-for-approval never exec --ignore-user-config --ignore-rules --strict-config -c 'mcp_servers={}' -c 'features.web_search=false' -c 'features.plugins=false' -c 'shell_environment_policy.inherit="none"' --sandbox read-only --ephemeral -- "$prompt" <<'RUBY'
  review_home, review_bin, codex_home, *command = ARGV
  environment = {"PATH" => "#{review_bin}:/bin", "HOME" => review_home, "CODEX_HOME" => codex_home, "LANG" => "C", "LC_ALL" => "C"}
  pid = Process.spawn(environment, *command, in: File::NULL, unsetenv_others: true)
  begin
    Timeout.timeout(600) { Process.wait(pid) }
  rescue Timeout::Error
    Process.kill("TERM", pid) rescue nil
    begin; Timeout.timeout(5) { Process.wait(pid) }; rescue Timeout::Error; Process.kill("KILL", pid) rescue nil; Process.wait(pid) rescue nil; end
    exit 124
  end
  exit($?.exitstatus || 1)
RUBY
