#!/bin/bash
# Template sync (D-074): the fixed read-only launcher that asks Codex to review one apply plan.
# `tools/template-sync.sh codex-review` calls it only when the user chose the Codex route. Codex can
# read only the two plan files, has no network, tools or plugins, and its answer approves only that plan.
set -euo pipefail

usage() { echo 'usage: template-sync-codex-review.sh --plan-dir DIR --output FILE' >&2; exit 2; }
[[ $# -eq 4 && "$1" == --plan-dir && "$3" == --output ]] || usage
plan_dir=$2 output=$4
blocked_environment() { echo "blocked:environment: $*" >&2; exit 1; }
physical_directory() {
  local path=$1 resolved
  [[ "$path" == /* && -d "$path" && ! -L "$path" ]] || blocked_environment "unsafe directory: $path"
  resolved=$(cd "$path" && pwd -P)
  [[ "$resolved" == "$path" && "$resolved" != / ]] || blocked_environment "non-physical or broad directory: $path"
  printf '%s\n' "$resolved"
}
safe_profile_path() {
  [[ "$1" != *'"'* && "$1" != *\\* && "$1" != *$'\n'* && "$1" != *$'\r'* ]] || blocked_environment 'unsafe profile path'
}

plan_dir=$(physical_directory "$plan_dir")
[[ "$(cd "$plan_dir" && /bin/ls -A | LC_ALL=C sort | tr '\n' ' ')" == 'plan.json plan.md ' ]] ||
  blocked_environment 'the plan directory must hold only plan.json and plan.md'
for name in plan.json plan.md; do
  [[ -f "$plan_dir/$name" && ! -L "$plan_dir/$name" ]] || blocked_environment "$name must be a regular file"
done
[[ "$output" == /* && ! -e "$output" && ! -L "$output" ]] || blocked_environment 'output must be a new absolute path'
physical_directory "$(dirname "$output")" >/dev/null
safe_profile_path "$plan_dir"
codex_home=$(physical_directory "${CODEX_HOME:-"$HOME/.codex"}")
[[ "$codex_home" != "$plan_dir" && "$codex_home" != "$plan_dir"/* && "$plan_dir" != "$codex_home"/* ]] ||
  blocked_environment 'CODEX_HOME overlaps the plan directory'

codex_candidate=$(command -v codex 2>/dev/null || true)
[[ "$codex_candidate" == /* && -x "$codex_candidate" ]] || blocked_environment 'Codex executable is unavailable'
codex_bin=$(/usr/bin/ruby -e 'print File.realpath(ARGV.fetch(0))' "$codex_candidate" 2>/dev/null) || blocked_environment 'Codex launcher cannot be resolved'
[[ -f "$codex_bin" && ! -L "$codex_bin" && -x "$codex_bin" ]] || blocked_environment 'Codex launcher is not a regular executable'
[[ $(/usr/bin/file -b "$codex_bin") == Mach-O* ]] || blocked_environment 'Codex launcher must be a native Mach-O executable'

review_home=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-sync-review.XXXXXX")
review_home=$(cd "$review_home" && pwd -P)
chmod 700 "$review_home"
trap 'rm -rf "$review_home"' EXIT
review_bin="$review_home/bin"
mkdir "$review_bin"
ln -s /usr/bin/uname "$review_bin/uname"
schema="$review_home/answer-schema.json"
cat >"$schema" <<'JSON'
{"type":"object","additionalProperties":false,"required":["verdict","summary","findings"],"properties":{"verdict":{"type":"string","enum":["approved","changes-requested"]},"summary":{"type":"string"},"findings":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["path","problem"],"properties":{"path":{"type":"string"},"problem":{"type":"string"}}}}}}
JSON
answer="$review_home/answer.json"

prompt="You review one template sync apply plan for an iOS app repository (decision D-074). Read only $plan_dir/plan.json and $plan_dir/plan.md. Do not edit files, run tests, use the network, or call other tools. The plan was produced by a deterministic tool; check it for internal consistency and for risk to the target app:
- Only files with action add, update or delete will be written. A file the app changed (conflict, app-only-change), an app-owned file, a mixed file and a template-only file must never be written.
- A deletion must come from a known base commit and an app file that still matches the base.
- Identity-transformed files must not carry more template names (TemplateApp, com.yuto.TemplateApp) than before; identityRegression files must be manual.
- specs/decisions.md may receive only the decision IDs in decisions.append, and nothing when decisions.collisions is not empty.
- The dedicated Simulator declaration must keep the app's two devices named with the app's display name, never the iOS-Template devices.
- AGENTS.md changes always need the user's own approval (D-075); your answer never approves them.
Your answer approves only this exact plan for the template sync apply step. It is not approval for any other change, operation, review or merge.
Answer with verdict approved and an empty findings list only if nothing above is violated and the plan is safe to apply as written. Otherwise answer changes-requested and list each problem with the plan path it concerns. Write the summary in Japanese."

/usr/bin/ruby -rtimeout - "$review_home" "$review_bin" "$codex_home" "$codex_bin" --ask-for-approval never exec --ignore-user-config --ignore-rules --strict-config --skip-git-repo-check -C "$plan_dir" -m gpt-6-sol -c 'model_reasoning_effort="high"' -c 'default_permissions="reviewer"' -c 'permissions.reviewer.extends=":read-only"' -c "permissions.reviewer.filesystem={\":root\"=\"deny\",\":minimal\"=\"read\",\"$plan_dir\"=\"read\"}" -c 'permissions.reviewer.network={enabled=false}' -c 'mcp_servers={}' -c 'features.web_search=false' -c 'features.plugins=false' -c 'features.apps=false' -c 'features.browser_use=false' -c 'features.browser_use_external=false' -c 'features.computer_use=false' -c 'shell_environment_policy.inherit="none"' --ephemeral --output-schema "$schema" --output-last-message "$answer" -- "$prompt" <<'RUBY'
  review_home, review_bin, codex_home, *command = ARGV
  environment = {"PATH" => "#{review_bin}:/bin", "HOME" => review_home, "CODEX_HOME" => codex_home, "LANG" => "C", "LC_ALL" => "C"}
  timeout_seconds = Integer(ENV.fetch("IOS_TEMPLATE_REVIEW_TIMEOUT_SECONDS", "600"), 10)
  term_grace = Integer(ENV.fetch("IOS_TEMPLATE_REVIEW_TERM_GRACE_SECONDS", "5"), 10)
  exit 2 unless (1..600).cover?(timeout_seconds) && (1..5).cover?(term_grace)
  pid = Process.spawn(environment, *command, in: File::NULL, out: File::NULL, unsetenv_others: true)
  begin
    Timeout.timeout(timeout_seconds) { Process.wait(pid) }
  rescue Timeout::Error
    Process.kill("TERM", pid) rescue nil
    begin; Timeout.timeout(term_grace) { Process.wait(pid) }; rescue Timeout::Error; Process.kill("KILL", pid) rescue nil; Process.wait(pid) rescue nil; end
    exit 124
  end
  exit($?.exitstatus || 1)
RUBY
[[ -f "$answer" && ! -L "$answer" && -s "$answer" ]] || blocked_environment 'Codex wrote no answer'
cp "$answer" "$output"
