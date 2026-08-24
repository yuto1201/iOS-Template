#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'usage: validate-issue-body.sh [--type feature|regression] ISSUE_BODY.md' >&2
  exit 2
}

issue_type=feature
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) issue_type=${2:-}; shift 2 ;;
    *) break ;;
  esac
done
[[ "$issue_type" == feature || "$issue_type" == regression ]] || usage
[[ $# -eq 1 ]] || usage
issue_body=$1
[[ -f "$issue_body" ]] || { echo "Issue body file not found: $issue_body" >&2; exit 2; }

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)

ruby - "$issue_body" "$issue_type" <<'RUBY'
body_path = ARGV.fetch(0)
issue_type = ARGV.fetch(1)
body = File.read(body_path, encoding: "UTF-8")
required = ["Goal", "In scope", "Out of scope", "Acceptance criteria", "Spec anchors", "Dependencies", "External operations", "User approvals"]

headings = []
body.each_line.with_index(1) do |line, line_number|
  match = line.match(/\A(#+)\s+(.+?)\s*\z/)
  headings << [match[2], line_number] if match
end

failures = []
sections = {}
required.each do |heading|
  matches = headings.each_index.select { |index| headings[index][0] == heading }
  if matches.empty?
    failures << "missing required heading: #{heading}"
    next
  end
  failures << "duplicate required heading: #{heading}" if matches.length > 1
  start_line = headings[matches.first][1]
  next_heading = headings.find { |_, line_number| line_number > start_line }
  end_line = next_heading ? next_heading[1] - 1 : body.lines.length
  sections[heading] = body.lines[start_line...end_line].join
  failures << "required section is empty: #{heading}" if sections[heading].strip.empty?
end

acceptance = sections.fetch("Acceptance criteria", "")
ac_ids = acceptance.scan(/^\s*[-*]\s+(AC-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)\s*:\s*\S/m).flatten
failures << "Acceptance criteria must contain at least one '- AC-*:' item" if ac_ids.empty?
duplicates = ac_ids.group_by(&:itself).select { |_, ids| ids.length > 1 }.keys
failures << "duplicate acceptance criteria ID: #{duplicates.join(', ')}" unless duplicates.empty?

spec_anchors = sections.fetch("Spec anchors", "")
unless spec_anchors.match?(/\[[^\]]+\]\((?:<)?(?:\.\/)?specs\/[^)\s]+\.md#[^)\s]+(?:>)?\)/)
  failures << "Spec anchors must contain a local Markdown link to specs/ with a section anchor"
end

external_operations = sections.fetch("External operations", "")
approvals = sections.fetch("User approvals", "")
no_external_operation = external_operations.match?(/\A\s*(?:[-*]\s*)?None\.?\s*\z/i)
unless no_external_operation
  operation_fields = {}
  external_operations.each_line do |line|
    next if line.strip.empty?
    match = line.match(/\A\s*[-*]\s*(Service|Environment|Executor|Approval required):\s*(.*?)\s*\z/)
    unless match
      failures << "External operations must use only Service, Environment, Executor, and Approval required fields"
      next
    end
    field, value = match.captures
    if operation_fields.key?(field)
      failures << "duplicate External operations field: #{field}"
    else
      operation_fields[field] = value
    end
  end

  required_operation_fields = ["Service", "Environment", "Executor", "Approval required"]
  required_operation_fields.each do |field|
    failures << "missing External operations field: #{field}" if operation_fields[field].nil? || operation_fields[field].empty?
  end
  unless operation_fields.fetch("Environment", "").match?(/\A(?:local|preview|staging|production)\z/)
    failures << "External operations Environment must be local, preview, staging, or production"
  end
  failures << "External operations Executor must be Codex" unless operation_fields.fetch("Executor", "") == "Codex"

  approval_required = operation_fields.fetch("Approval required", "")
  unless %w[yes no].include?(approval_required)
    failures << "External operations Approval required must be yes or no"
  end
  no_additional_approval = approvals.match?(/\A\s*(?:[-*]\s*)?(?:None|No additional approval)\.?\s*\z/i)
  approval_reference = approvals.match?(/(?:https?:\/\/\S+|\B#\d+\b|\bD-\d+\b|\bapproval(?:\s+reference)?\s*:\s*\S+)/i)
  if approval_required == "yes" && !approval_reference
    failures << "Approval required: yes needs a nonempty User approvals reference"
  elsif approval_required == "no" && !no_additional_approval
    failures << "Approval required: no requires User approvals to be None or No additional approval"
  end
end

if issue_type == "regression"
  ["Original PR", "Reproduction steps"].each do |heading|
    matches = headings.each_index.select { |index| headings[index][0] == heading }
    if matches.empty?
      failures << "Regression Issue missing required heading: #{heading}"
      next
    end
    failures << "duplicate Regression heading: #{heading}" if matches.length > 1
    start_line = headings[matches.first][1]
    next_heading = headings.find { |_, line_number| line_number > start_line }
    end_line = next_heading ? next_heading[1] - 1 : body.lines.length
    content = body.lines[start_line...end_line].join
    failures << "Regression Issue section is empty: #{heading}" if content.strip.empty?
  end
end

unless failures.empty?
  warn failures.join("\n")
  exit 1
end
RUBY

"$repo_root/.agents/skills/spec-workflow/scripts/check-spec-state.sh" "$issue_body"
