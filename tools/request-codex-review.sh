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
topology=$(ruby "$repo_root/tools/lib/review-artifacts.rb" "$repo_root") || exit 1
artifacts_root=$(jq -er '.artifactsRoot' <<<"$topology")
artifact_issue_root="$artifacts_root/issues/$issue"
artifact_head_root="$artifact_issue_root/$head_sha"
artifact_contract="$artifact_issue_root/issue-contract.json"

instruction='You are the opposite-model acceptance auditor. Read only the supplied local review packet and files it references. Do not edit files, run tests, operate simulators, commit, push, use network services, authentication, or external tools. If repositoryTests is present, assess its current-Head suite and per-AC mappings as sealed evidence. Return exactly one raw JSON object conforming to docs/agent-contracts/review-packet.md Result schema, including the exact reviewPacketDigest from the schema v2 packet bytes. Do not add prose or Markdown fences before or after the JSON object.'
packet_absolute="$artifact_issue_root/$head_sha/review-packet.json"
prompt="$instruction
Validated review packet: $packet_absolute
Physical issue contract: $artifact_contract
Physical current-Head evidence root: $artifact_head_root
Resolve only the packet's canonical contract path through the physical issue contract above, and only its current-Head artifact paths through the physical evidence root above."
blocked_environment() { echo "blocked:environment: $*" >&2; exit 1; }
physical_directory() {
  local path=$1 resolved
  [[ "$path" == /* && -d "$path" && ! -L "$path" ]] || blocked_environment "unsafe directory: $path"
  resolved=$(cd "$path" && pwd -P)
  [[ "$resolved" == "$path" && "$resolved" != / ]] || blocked_environment "non-physical or broad directory: $path"
  printf '%s\n' "$resolved"
}
safe_profile_path() {
  [[ "$1" != *'"'* && "$1" != *\\* && "$1" != *$'\n'* && "$1" != *$'\r'* ]] || blocked_environment "unsafe profile path"
}

repo_root=$(physical_directory "$repo_root")
artifacts_root=$(physical_directory "$artifacts_root")
artifact_issue_root=$(physical_directory "$artifact_issue_root")
artifact_head_root=$(physical_directory "$artifact_head_root")
[[ -f "$artifact_contract" && ! -L "$artifact_contract" && $(stat -f '%l' "$artifact_contract") == 1 ]] || blocked_environment 'issue contract is not a regular single-link file'
[[ "$packet_absolute" == "$artifact_issue_root/$head_sha/review-packet.json" && -f "$packet_absolute" && ! -L "$packet_absolute" ]] || blocked_environment 'review packet physical path is not canonical'
git_file="$repo_root/.git"
[[ -f "$git_file" && ! -L "$git_file" ]] || blocked_environment 'review worktree must use a physical linked .git file'
git_dir_raw=$(/usr/bin/env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR /usr/bin/git -C "$repo_root" rev-parse --path-format=absolute --absolute-git-dir 2>/dev/null) || blocked_environment 'unable to resolve linked-worktree Git metadata'
git_common_raw=$(/usr/bin/env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR /usr/bin/git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || blocked_environment 'unable to resolve common Git metadata'
git_dir=$(physical_directory "$git_dir_raw")
git_common=$(physical_directory "$git_common_raw")
[[ "$git_common" == */.git && "$git_dir" == "$git_common"/worktrees/* && "${git_dir#"$git_common"/worktrees/}" != */* ]] || blocked_environment 'linked-worktree Git metadata is outside its exact worktree directory'
[[ $(sed -n '1p' "$git_file") == "gitdir: $git_dir" && $(sed -n '2p' "$git_file") == '' ]] || blocked_environment 'linked-worktree .git metadata is not canonical'
review_codex_home_candidate=${CODEX_HOME:-"$HOME/.codex"}
review_codex_home=$(physical_directory "$review_codex_home_candidate")
for profile_path in "$repo_root" "$git_dir" "$git_common" "$artifact_contract" "$artifact_head_root"; do safe_profile_path "$profile_path"; done
for profile_path in "$repo_root" "$git_dir" "$git_common" "$artifact_contract" "$artifact_head_root"; do
  [[ "$review_codex_home" != "$profile_path" && "$review_codex_home" != "$profile_path"/* && "$profile_path" != "$review_codex_home"/* ]] || blocked_environment 'CODEX_HOME overlaps a reviewer-readable profile root'
done

codex_candidate=$(command -v codex 2>/dev/null || true)
[[ "$codex_candidate" == /* && -x "$codex_candidate" ]] || blocked_environment 'Codex executable is unavailable'
codex_bin=$(ruby -e 'print File.realpath(ARGV.fetch(0))' "$codex_candidate" 2>/dev/null) || blocked_environment 'Codex launcher cannot be resolved'
[[ -f "$codex_bin" && ! -L "$codex_bin" && -x "$codex_bin" ]] || blocked_environment 'Codex launcher is not a regular executable'
[[ $(/usr/bin/file -b "$codex_bin") == Mach-O* ]] || blocked_environment 'Codex launcher must be a native Mach-O executable'

filesystem_profile="permissions.reviewer.filesystem={\":root\"=\"deny\",\":minimal\"=\"read\",\"$repo_root\"=\"read\",\"$repo_root/.artifacts\"=\"deny\",\"$git_dir\"=\"read\",\"$git_common\"=\"read\",\"$artifact_contract\"=\"read\",\"$artifact_head_root\"=\"read\"}"
review_home=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-codex-review.XXXXXX")
chmod 700 "$review_home"
review_bin="$review_home/bin"
mkdir "$review_bin"
ln -s /usr/bin/uname "$review_bin/uname"
trap 'rm -rf "$review_home"' EXIT
ruby -rtimeout - "$review_home" "$review_bin" "$review_codex_home" "$codex_bin" --ask-for-approval never exec --ignore-user-config --ignore-rules --strict-config -c 'default_permissions="reviewer"' -c 'permissions.reviewer.extends=":read-only"' -c "$filesystem_profile" -c 'permissions.reviewer.network={enabled=false}' -c 'mcp_servers={}' -c 'features.web_search=false' -c 'features.plugins=false' -c 'features.apps=false' -c 'features.browser_use=false' -c 'features.browser_use_external=false' -c 'features.computer_use=false' -c 'shell_environment_policy.inherit="none"' --ephemeral -- "$prompt" <<'RUBY'
  review_home, review_bin, codex_home, *command = ARGV
  environment = {"PATH" => "#{review_bin}:/bin", "HOME" => review_home, "CODEX_HOME" => codex_home, "LANG" => "C", "LC_ALL" => "C"}
  timeout_seconds = Integer(ENV.fetch("IOS_TEMPLATE_REVIEW_TIMEOUT_SECONDS", "600"), 10)
  term_grace = Integer(ENV.fetch("IOS_TEMPLATE_REVIEW_TERM_GRACE_SECONDS", "5"), 10)
  exit 2 unless (1..600).cover?(timeout_seconds) && (1..5).cover?(term_grace)
  pid = Process.spawn(environment, *command, in: File::NULL, unsetenv_others: true)
  begin
    Timeout.timeout(timeout_seconds) { Process.wait(pid) }
  rescue Timeout::Error
    Process.kill("TERM", pid) rescue nil
    begin; Timeout.timeout(term_grace) { Process.wait(pid) }; rescue Timeout::Error; Process.kill("KILL", pid) rescue nil; Process.wait(pid) rescue nil; end
    exit 124
  end
  exit($?.exitstatus || 1)
RUBY
