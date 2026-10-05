#!/bin/bash
set -euo pipefail

# D-076: the feedback Worker template in the app-feedback skill. Runs the Worker's own tests on the
# template and on a copy written with sample app values, and checks the placeholder contract.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" node ruby

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
skill="$repo_root/.agents/skills/app-feedback"
template="$skill/templates/feedback-worker"
work=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-feedback-worker.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

major=$(node -p 'process.versions.node.split(".")[0]')
(( major >= 24 )) || {
  echo "test prerequisite unavailable (${0##*/}): Node 24 or later is required; see docs/verification.md (test prerequisites)" >&2
  exit 69
}

run_worker_tests() {
  local directory=$1 label=$2
  if ! (cd "$directory" && node test/all.ts) >"$work/$label.log" 2>&1; then
    echo "feedback Worker tests failed ($label)" >&2
    tail -40 "$work/$label.log" >&2
    exit 1
  fi
}

[[ -L "$repo_root/.claude/skills/app-feedback" &&
   "$(readlink "$repo_root/.claude/skills/app-feedback")" == "../../.agents/skills/app-feedback" ]] || {
  echo 'Claude alias for app-feedback must point to the shared skill' >&2
  exit 1
}
grep -Fxq '.dev.vars' "$template/.gitignore" || { echo 'the Worker template must ignore .dev.vars' >&2; exit 1; }

run_worker_tests "$template" template

# The placeholder contract: exactly the contract's keys, only in wrangler.jsonc, and no app's values.
ruby -rjson -e '
  skill, template = ARGV
  contract = JSON.parse(File.read(File.join(skill, "worker-values.json")))
  abort "worker-values.json schema differs" unless contract.keys.sort == %w[placeholders schemaVersion template] &&
    contract["schemaVersion"] == 1 && contract["template"] == "templates/feedback-worker"
  found = Hash.new { |hash, key| hash[key] = [] }
  Dir.glob("**/*", File::FNM_DOTMATCH, base: template).sort.each do |relative|
    path = File.join(template, relative)
    next unless File.file?(path)
    text = File.read(path)
    abort "app-specific value remains in #{relative}" if text.match?(/paycycle/i)
    # Tests may quote a placeholder to prove an unwritten value is refused; nothing else may.
    next if relative.start_with?("test/")
    text.scan(/\{\{([A-Z_]+)\}\}/).flatten.each { |name| found[name] << relative }
  end
  abort "placeholders #{found.keys.sort} differ from the contract #{contract["placeholders"].keys.sort}" unless found.keys.sort == contract["placeholders"].keys.sort
  found.each { |name, files| abort "#{name} appears outside wrangler.jsonc: #{files.uniq}" unless files.uniq == ["wrangler.jsonc"] }
  contract["placeholders"].each do |name, rule|
    abort "#{name} rule differs" unless rule.keys.sort == %w[pattern value] && Regexp.new(rule["pattern"])
  end
' "$skill" "$template"

# Write the template with sample values, as the provisioning tool will, and run the same tests.
write_worker() {
  local destination=$1 worker_name=$2 repository=$3 namespace=$4
  mkdir -p "$destination"
  cp -R "$template/." "$destination/"
  ruby -rjson -e '
    skill, destination, worker, repository, namespace = ARGV
    contract = JSON.parse(File.read(File.join(skill, "worker-values.json")))["placeholders"]
    values = {"WORKER_NAME" => worker, "GITHUB_REPOSITORY" => repository, "RATE_LIMIT_NAMESPACE_ID" => namespace}
    path = File.join(destination, "wrangler.jsonc")
    text = File.read(path).gsub(/\{\{([A-Z_]+)\}\}/) { values.fetch($1) }
    File.write(path, text)
    abort "a placeholder remains" if text.include?("{{")
    puts values.all? { |name, value| value.match?(Regexp.new(contract.fetch(name)["pattern"])) }
  ' "$skill" "$destination" "$worker_name" "$repository" "$namespace"
}

[[ "$(write_worker "$work/garden-notes" garden-notes-feedback example-owner/GardenNotes-feedback 4242)" == true ]]
run_worker_tests "$work/garden-notes" rendered

# A value outside the contract makes the Worker's own config test fail.
[[ "$(write_worker "$work/bad-name" Bad_Name example-owner/GardenNotes-feedback 4242)" == false ]]
if (cd "$work/bad-name" && node test/all.ts) >"$work/bad-name.log" 2>&1; then
  echo 'the Worker config test accepted an invalid Worker name' >&2
  exit 1
fi
grep -Fq 'WORKER_NAME has an invalid value' "$work/bad-name.log" || { echo 'unexpected failure for an invalid Worker name' >&2; tail -20 "$work/bad-name.log" >&2; exit 1; }

echo "feedback Worker template tests passed"
