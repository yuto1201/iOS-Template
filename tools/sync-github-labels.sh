#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'usage: sync-github-labels.sh --repo OWNER/REPOSITORY --executor codex' >&2
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
[[ "$executor" == codex ]] || { echo 'sync-github-labels.sh is Codex-only; pass --executor codex' >&2; exit 2; }

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
manifest="$repo_root/.github/labels.yml"
[[ -f "$manifest" ]] || { echo 'label manifest is missing' >&2; exit 1; }

# This identity and repository check must complete before this script mutates GitHub.
"$repo_root/tools/github-account-preflight.sh" --repo "$repo" >/dev/null

ruby -rjson -ryaml - "$manifest" <<'RUBY' | while IFS=$'\t' read -r name color description; do
manifest_path = ARGV.fetch(0)
document = YAML.safe_load(File.read(manifest_path), permitted_classes: [], aliases: false)
labels = document.is_a?(Hash) ? document["labels"] : nil
abort "labels.yml must contain a labels array" unless labels.is_a?(Array) && !labels.empty?
names = {}
labels.each do |label|
  abort "each label must be a mapping" unless label.is_a?(Hash) && label.keys.sort == %w[color description name]
  name = label["name"]
  color = label["color"].to_s
  description = label["description"]
  abort "invalid label name" unless name.is_a?(String) && name.match?(/\A[a-z]+:[a-z][a-z-]*(?::[a-z][a-z-]*)?\z/)
  abort "invalid label color for #{name}" unless color.match?(/\A[0-9A-Fa-f]{6}\z/)
  abort "invalid label description for #{name}" unless description.is_a?(String) && !description.empty? && !description.include?("\n")
  abort "duplicate label name: #{name}" if names[name]
  names[name] = true
  puts [name, color.upcase, description].join("\t")
end
RUBY
  existing=$(gh label list --repo "$repo" --limit 100 --json name,color,description)
  action=$(ruby -rjson - "$existing" "$name" "$color" "$description" <<'RUBY'
labels = JSON.parse(ARGV.fetch(0))
name, color, description = ARGV.drop(1)
current = labels.find { |label| label["name"] == name }
if current.nil?
  puts "create"
elsif current["color"].to_s.upcase != color || current["description"].to_s != description
  puts "edit"
else
  puts "skip"
end
RUBY
)
  case "$action" in
    create) gh label create "$name" --repo "$repo" --color "$color" --description "$description" ;;
    edit) gh label edit "$name" --repo "$repo" --color "$color" --description "$description" ;;
    skip) ;;
    *) echo "unexpected label action: $action" >&2; exit 1 ;;
  esac
done
