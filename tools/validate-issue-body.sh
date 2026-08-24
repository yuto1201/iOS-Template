#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'usage: validate-issue-body.sh ISSUE_BODY.md' >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
issue_body=$1
[[ -f "$issue_body" ]] || { echo "Issue body file not found: $issue_body" >&2; exit 2; }

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)

ruby - "$issue_body" <<'RUBY'
body_path = ARGV.fetch(0)
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
operation_declared = !external_operations.match?(/\A\s*(?:[-*]\s*)?(?:none|not applicable|なし|不要)\.?\s*\z/i)
if operation_declared && (!external_operations.match?(/\bcodex\b|Codex/) || !external_operations.match?(/\b(?:local|preview|staging|production)\b|(?:ローカル|プレビュー|ステージング|本番)/i))
  failures << "External operations must name the service, environment, and Codex executor"
end
approval_required = external_operations.match?(/(?:production\s+(?:(?:data|database)\s+)?(?:delete|deletion|destroy|irreversible)|\b(?:billing|budget|price|paid)\b|new\s+external\s+service|app\s+store.*(?:initial|first)|domain\s+transfer|dns.*(?:replace|replacement)|\b(?:team|organization)\s+membership\b|\bpermissions?\b|本番.*(?:削除|破壊|不可逆)|(?:課金|予算|価格)|新しい外部サービス|(?:App\s*Store|アップストア).*(?:初回|最初)|ドメイン移管|DNS.*(?:置換|変更)|(?:権限|チーム|組織).*メンバー)/i)
approvals = sections.fetch("User approvals", "")
approval_reference = approvals.match?(/(?:https?:\/\/\S+|\B#\d+\b|\bD-\d+\b|\bapproval(?:\s+reference)?\s*:\s*\S+|承認(?:参照)?\s*[:：]\s*\S+)/i)
if approval_required && !approval_reference
  failures << "approval-required external operation needs a User approvals reference"
end

regression_markers = ["Original PR", "Reproduction steps"]
if regression_markers.any? { |heading| headings.any? { |title, _| title == heading } }
  regression_markers.each do |heading|
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
