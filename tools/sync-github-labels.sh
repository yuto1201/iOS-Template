#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'usage: sync-github-labels.sh --repo OWNER/REPOSITORY --executor codex|claude' >&2
  exit 2
}

repo=''
executor=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --executor) executor=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'invalid repository' >&2; exit 2; }
[[ "$executor" == codex || "$executor" == claude ]] || { echo 'sync-github-labels.sh requires --executor codex or --executor claude' >&2; exit 2; }

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
manifest="$repo_root/.github/labels.yml"
[[ -f "$manifest" ]] || { echo 'label manifest is missing' >&2; exit 1; }

# This identity and repository check must complete before this script mutates GitHub.
"$repo_root/tools/github-account-preflight.sh" --repo "$repo" >/dev/null

workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-label-sync.XXXXXX")
trap 'rm -rf "$workspace"' EXIT
existing_file="$workspace/existing.json"
actions_file="$workspace/actions.tsv"

# gh paginates internally until this deliberately high bound. One snapshot is
# used for the whole reconciliation so repositories with more than 100 labels
# do not create duplicates and the script does not relist once per manifest row.
gh label list --repo "$repo" --limit 1000 --json name,color,description > "$existing_file"

ruby -rjson -ryaml - "$manifest" "$existing_file" > "$actions_file" <<'RUBY'
manifest_path = ARGV.fetch(0)
existing_path = ARGV.fetch(1)
document = YAML.safe_load(File.read(manifest_path), permitted_classes: [], aliases: false)
labels = document.is_a?(Hash) ? document["labels"] : nil
abort "labels.yml must contain a labels array" unless labels.is_a?(Array) && !labels.empty?
names = {}
manifest_labels = labels.map do |label|
  abort "each label must be a mapping" unless label.is_a?(Hash) && label.keys.sort == %w[color description name]
  name = label["name"]
  color = label["color"].to_s
  description = label["description"]
  abort "invalid label name" unless name.is_a?(String) && name.match?(/\A[a-z]+:[a-z][a-z-]*(?::[a-z][a-z-]*)?\z/)
  abort "invalid label color for #{name}" unless color.match?(/\A[0-9A-Fa-f]{6}\z/)
  abort "invalid label description for #{name}" unless description.is_a?(String) && !description.empty? && !description.match?(/[\n\t]/)
  abort "duplicate label name: #{name}" if names[name]
  names[name] = true
  {"name" => name, "color" => color.upcase, "description" => description}
end

existing = JSON.parse(File.binread(existing_path))
abort "GitHub label response must be an array" unless existing.is_a?(Array)
existing_by_name = {}
existing.each do |label|
  abort "GitHub label response is malformed" unless label.is_a?(Hash) && label["name"].is_a?(String)
  abort "GitHub returned a duplicate label name: #{label["name"]}" if existing_by_name.key?(label["name"])
  existing_by_name[label["name"]] = label
end

manifest_labels.each do |label|
  current = existing_by_name[label.fetch("name")]
  action = if current.nil?
    "create"
  elsif current["color"].to_s.upcase != label.fetch("color") || current["description"].to_s != label.fetch("description")
    "edit"
  else
    "skip"
  end
  puts [action, label.fetch("name"), label.fetch("color"), label.fetch("description")].join("\t")
end
RUBY

while IFS=$'\t' read -r action name color description; do
  case "$action" in
    create) gh label create "$name" --repo "$repo" --color "$color" --description "$description" ;;
    edit) gh label edit "$name" --repo "$repo" --color "$color" --description "$description" ;;
    skip) ;;
    *) echo "unexpected label action: $action" >&2; exit 1 ;;
  esac
done < "$actions_file"
