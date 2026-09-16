#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" bash jq readlink ruby swift

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

skill=.agents/skills/report-template-issue/SKILL.md
example=.agents/skills/report-template-issue/templates/example-issue.md
claude_skill=.claude/skills/report-template-issue

for path in "$skill" "$example"; do
  [[ -f "$path" ]] || { echo "missing report-template-issue resource: $path" >&2; exit 1; }
done
for path in \
  .agents/skills/plan-issue-batch/SKILL.md \
  .agents/skills/spec-workflow/SKILL.md \
  .agents/skills/external-ops/SKILL.md; do
  [[ -f "$path" ]] || { echo "missing report-template-issue dependency: $path" >&2; exit 1; }
done

[[ -L "$claude_skill" ]] || { echo 'Claude report-template-issue route must be a symlink' >&2; exit 1; }
[[ "$(readlink "$claude_skill")" == ../../.agents/skills/report-template-issue ]] || {
  echo 'Claude report-template-issue route is not portable' >&2
  exit 1
}
[[ -f "$claude_skill/SKILL.md" ]] || { echo 'Claude report-template-issue route is broken' >&2; exit 1; }

ruby -rjson <<'RUBY'
# encoding: UTF-8
def require_all(label, text, values)
  missing = values.reject { |value| text.include?(value) }
  abort "#{label} lacks #{missing.inspect}" unless missing.empty?
end

skill = File.read('.agents/skills/report-template-issue/SKILL.md', encoding: 'UTF-8')
abort 'skill frontmatter name differs' unless skill.match?(/\A---\nname: report-template-issue\n/)
description = skill[/\A---\n.*?\ndescription:\s*(.+?)\n---\n/m, 1]
abort 'skill description does not route template reports' unless description&.match?(/template|テンプレート/i)

require_all('trigger coverage', skill, [
  'この問題をテンプレート側に報告して',
  'アプリで直した共通処理をテンプレートにも反映したい',
  '明示呼出し'
])
require_all('fixed destination and source separation', skill, [
  'yuto1201/iOS-Template',
  '発見元repository',
  '報告先repository',
  'origin',
  'upstream remote',
  'ローカルcheckout',
  '推測しない'
])
require_all('classification and current-template comparison', skill, [
  'app-specific',
  'template-common',
  'environment-only',
  'current template',
  '適用元revision',
  '観測事実',
  '仮説'
])
require_all('duplicate handling', skill, [
  'open',
  'closed',
  '既存Issue',
  '解決内容',
  '再発',
  '重複作成しない'
])
require_all('issue body requirements', skill, [
  '問題',
  '期待動作',
  '再現手順',
  '最小例',
  '環境',
  'revision',
  '影響',
  '回避策',
  '共通化すべき理由',
  'Acceptance criteria',
  '秘密',
  '個人情報',
  '未加工ログ'
])
require_all('shared workflow routing', skill, [
  '../plan-issue-batch/SKILL.md',
  '../spec-workflow/SKILL.md',
  '../external-ops/SKILL.md',
  'validate-issue-body.sh',
  'github.create_issue',
  'github.read_issue',
  'github.update_issue',
  'github-account-preflight.sh',
  'Executor',
  '現在の依頼',
  '継続中の明示承認'
])
require_all('result integrity', skill, [
  'repository、番号、URL、本文',
  'readback',
  '曖昧',
  '無条件に再実行しない',
  'newly-created',
  'existing-issue',
  'already-fixed',
  'local-draft-only',
  '実装完了とは報告しない'
])
require_all('existing-app adoption', skill, [
  '既存派生アプリへの導入',
  '.agents/skills/report-template-issue/',
  '.claude/skills/report-template-issue',
  'Config/repository-tests.json',
  '同名path',
  '上書きせず'
])

scenarios = {
  'new-common-problem' => 'newly-created',
  'duplicate-open-or-closed' => 'existing-issue',
  'fixed-in-current-template' => 'already-fixed',
  'app-specific-problem' => 'local-draft-only',
  'missing-upstream-remote' => 'continue-with-explicit-target',
  'unknown-create-authority' => 'local-draft-only',
  'ambiguous-create-result' => 'reconcile-before-retry'
}
scenarios.each do |input, outcome|
  require_all("scenario #{input}", skill, [input, outcome])
end

contracts = {
  'README.md' => ['report-template-issue', 'yuto1201/iOS-Template'],
  'specs/architecture.md' => ['report-template-issue', '派生アプリ'],
  'specs/decisions.md' => ['report-template-issue', 'Related Issue: #67']
}
contracts.each do |path, anchors|
  text = File.read(path, encoding: 'UTF-8')
  require_all(path, text, anchors)
end

manifest = JSON.parse(File.binread('Config/repository-tests.json'))
rule = manifest.fetch('domainRules').find { |entry| entry.fetch('domain') == 'template-issue-reporting' }
abort 'template-issue-reporting domain rule is missing' unless rule
abort 'report skill prefix is not mapped' unless rule.fetch('prefixes').include?('.agents/skills/report-template-issue/')
abort 'Claude report route is not mapped' unless rule.fetch('paths').include?('.claude/skills/report-template-issue')
test = manifest.fetch('tests').find { |entry| entry.fetch('path') == 'tools/tests/test-report-template-issue-skill.sh' }
abort 'report-template-issue test manifest entry is missing' unless test&.fetch('domains')&.include?('template-issue-reporting')
RUBY

tools/validate-issue-body.sh --type docs "$example" >/dev/null
swift tools/check-markdown-links.swift "$skill" README.md >/dev/null

echo 'Template Issue reporting skill checks passed.'
