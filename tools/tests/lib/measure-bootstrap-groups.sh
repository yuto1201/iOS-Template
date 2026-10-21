#!/bin/bash
# #327 (AC-6): records the elapsed time of every split app-bootstrap and bootstrap-fixture entrypoint, once in a
# disposable clone of the current Head run as the template, and once in a disposable clone of the same Head that
# was Identity-bootstrapped and committed. Each entrypoint runs with its repository as the source root and a
# 300-second limit. The record is canonical JSON written to --output, outside the repository. This is a manual
# measurement helper, not a test entrypoint; the repository suite does not run it.
set -euo pipefail
export LANG=en_US.UTF-8

usage() { echo 'usage: tools/tests/lib/measure-bootstrap-groups.sh --output PATH' >&2; exit 2; }
[[ $# == 2 && "$1" == --output ]] || usage
output=$2

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
head_sha=$(git -C "$repo_root" rev-parse HEAD)
[[ -z "$(git -C "$repo_root" status --porcelain)" ]] || { echo 'the repository has uncommitted changes' >&2; exit 1; }
output_dir=$(cd "$(dirname "$output")" && pwd -P) || { echo 'the output directory does not exist' >&2; exit 1; }
[[ "$output_dir" != "$repo_root" && "$output_dir" != "$repo_root/"* ]] || [[ "$output_dir" == "$repo_root/.artifacts/"* ]] ||
  { echo 'write the record outside the tracked repository' >&2; exit 1; }
output="$output_dir/$(basename "$output")"
script_path="$repo_root/tools/tests/lib/measure-bootstrap-groups.sh"

now() { perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }

measured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
load_at_start=$(sysctl -n vm.loadavg)
script_sha=$(shasum -a 256 "$script_path" | awk '{print $1}')

work=$(mktemp -d "${TMPDIR:-/tmp}/measure-bootstrap-groups.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
results=$work/results.tsv
: >"$results"

template=$work/template-clone
bootstrapped=$work/bootstrapped-clone
git clone -q --no-local "$repo_root" "$template"
git -C "$template" checkout -q -b measure/template "$head_sha"
git clone -q --no-local "$repo_root" "$bootstrapped"
git -C "$bootstrapped" checkout -q -b measure/bootstrapped "$head_sha"
(
  cd "$bootstrapped"
  bash tools/bootstrap-app.sh --display-name 'Garden Notes' --module-name GardenNotes \
    --app-slug garden-notes --bundle-id com.yuto.GardenNotes >/dev/null
  git add -A
  git -c user.name='Bootstrap Measure' -c user.email=bootstrap-measure@example.invalid -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null commit -q -m 'test: bootstrap GardenNotes for the group timing'
)
[[ -z "$(git -C "$template" status --porcelain)" && -z "$(git -C "$bootstrapped" status --porcelain)" ]] || {
  echo 'a disposable repository is not clean before measurement' >&2; exit 1; }
template_head=$(git -C "$template" rev-parse HEAD)
bootstrapped_head=$(git -C "$bootstrapped" rev-parse HEAD)
bootstrapped_files=$(git -C "$bootstrapped" ls-files | wc -l | tr -d ' ')

entrypoints=(
  "tools/tests/test-app-bootstrap.sh|core"
  "tools/tests/test-app-bootstrap-transform.sh|"
  "tools/tests/test-app-bootstrap-safety-rejection.sh|"
  "tools/tests/test-app-bootstrap-safety-rerun.sh|"
  "tools/tests/test-bootstrap-fixture.sh|"
  "tools/tests/test-bootstrap-fixture-derived-core.sh|"
  "tools/tests/test-bootstrap-fixture-derived-transform.sh|"
  "tools/tests/test-bootstrap-fixture-derived-safety-rejection.sh|"
  "tools/tests/test-bootstrap-fixture-derived-safety-rerun.sh|"
)

for context in template-clone bootstrapped-clone; do
  repo=$work/$context
  for entry in "${entrypoints[@]}"; do
    path=${entry%%|*}
    argument=${entry#*|}
    log=$work/$context-$(basename "$path" .sh)${argument:+-$argument}.log
    start=$(now)
    set +e
    if [[ -n "$argument" ]]; then
      (cd "$repo" && perl -e 'alarm 300; exec @ARGV' /bin/bash "$path" "$argument") >"$log" 2>&1
    else
      (cd "$repo" && perl -e 'alarm 300; exec @ARGV' /bin/bash "$path") >"$log" 2>&1
    fi
    status=$?
    set -e
    end=$(now)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$context" "$path" "$argument" "$status" "$start" "$end" >>"$results"
    printf '%s %s %s exit=%s\n' "$context" "$path" "$argument" "$status"
    [[ $status -eq 0 ]] || tail -5 "$log" >&2
  done
  [[ -z "$(git -C "$repo" status --porcelain)" ]] || echo "WARNING: $context is dirty after measurement" >&2
done

umask 077
ruby -rjson - "$results" "$output" "$head_sha" "$measured_at" "$load_at_start" "$script_sha" \
  "$template_head" "$bootstrapped_head" "$bootstrapped_files" <<'RUBY'
results, output, head_sha, measured_at, load, script_sha, template_head, bootstrapped_head, files = ARGV
def canonical(value)
  case value
  when Hash then value.keys.sort.each_with_object({}) { |key, result| result[key] = canonical(value[key]) }
  when Array then value.map { |entry| canonical(entry) }
  else value
  end
end
rows = File.readlines(results, chomp: true).map { |line| line.split("\t", -1) }
contexts = {
  "template-clone" => {"headSha" => template_head,
    "description" => "git clone --no-local of the repository at Head, run as the template"},
  "bootstrapped-clone" => {"headSha" => bootstrapped_head,
    "description" => "git clone --no-local of the repository at Head, converted with tools/bootstrap-app.sh " \
      "--display-name 'Garden Notes' --module-name GardenNotes --app-slug garden-notes " \
      "--bundle-id com.yuto.GardenNotes and committed clean (#{files} tracked files); " \
      "entrypoints run with this repository as the source root"}
}
contexts.each do |name, context|
  context["entrypoints"] = rows.select { |row| row[0] == name }.map do |_, path, argument, status, start, finish|
    {"path" => path, "arguments" => argument.empty? ? [] : [argument], "exitStatus" => Integer(status),
     "elapsedSeconds" => (Float(finish) - Float(start)).round(3)}
  end
end
all = contexts.values.flat_map { |context| context["entrypoints"] }
document = {
  "schemaVersion" => 1, "headSha" => head_sha, "measuredAt" => measured_at,
  "hostLoadAtStart" => load, "measurementScriptSha256" => script_sha,
  "contexts" => contexts, "maxElapsedSeconds" => all.map { |entry| entry["elapsedSeconds"] }.max,
  "allWithin150Seconds" => all.length == 18 && all.all? { |entry| entry["exitStatus"].zero? && entry["elapsedSeconds"] <= 150 }
}
File.open(output, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(canonical(document))) }
File.chmod(0o600, output)
RUBY
echo "wrote $output"
