#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby readlink

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

skill=.agents/skills/ios-system-experiences/SKILL.md
template=.agents/skills/ios-system-experiences/templates/system-experiences-plan.md
claude_skill=.claude/skills/ios-system-experiences

for path in "$skill" "$template"; do
  [[ -f "$path" ]] || { echo "missing system-experiences resource: $path" >&2; exit 1; }
done

[[ -L "$claude_skill" ]] || { echo 'Claude system-experiences route must be a symlink' >&2; exit 1; }
[[ "$(readlink "$claude_skill")" == ../../.agents/skills/ios-system-experiences ]] || {
  echo 'Claude system-experiences route is not portable' >&2
  exit 1
}
[[ -f "$claude_skill/SKILL.md" ]] || { echo 'Claude system-experiences route is broken' >&2; exit 1; }

ruby -rjson <<'RUBY'
# encoding: UTF-8
def require_all(label, text, values)
  missing = values.reject { |value| text.include?(value) }
  abort "#{label} lacks #{missing.inspect}" unless missing.empty?
end

skill = File.read('.agents/skills/ios-system-experiences/SKILL.md', encoding: 'UTF-8')
template = File.read('.agents/skills/ios-system-experiences/templates/system-experiences-plan.md', encoding: 'UTF-8')
abort 'skill frontmatter name differs' unless skill.match?(/\A---\nname: ios-system-experiences\n/)
description = skill[/\A---\n.*?\ndescription:\s*(.+?)\n---\n/m, 1]
abort 'skill description does not route planning requests' unless description&.match?(/plan|planning|採否|system experience/i)

surfaces = ['widget', 'live-activities', 'dynamic-island', 'controls', 'siri-app-intents']
decisions = ['adopt-now', 'defer', 'not-applicable', 'blocked:user']
require_all('skill surfaces', skill.downcase, surfaces)
require_all('skill decisions', skill, decisions)
require_all('skill workflow', skill, [
  'Identity bootstrap',
  '主要Feature Issue',
  'App Icon',
  'ui-direction',
  'Apple公式',
  'developer.apple.com',
  'checkedAt',
  'availability',
  'constraints',
  '部分blocking',
  'ユーザー',
  '共有domain action',
  'App Group',
  'privacy',
  'localization',
  'release'
])

require_all('template surfaces', template.downcase, surfaces)
require_all('template decisions', template, decisions)
require_all('template common fields', template, [
  'checkedAt',
  'source URL',
  '対象ユーザーtask',
  '提供価値',
  '対象OS／device／system space',
  '開始点',
  '成功結果',
  'source of truth',
  'staleness',
  'offline／error／recovery',
  'lock-state redaction',
  'accessibility',
  '日英localization',
  'fallback',
  'telemetry privacy境界',
  '検証方法',
  'release依存',
  '再評価条件'
])
require_all('template surface details', template, [
  '## Widget detail',
  'Timeline, reload, and relevance',
  '## Live Activities detail',
  'Payload/update-frequency constraints',
  '## Dynamic Island detail',
  'Minimal presentation',
  'Compact presentation',
  'Expanded presentation',
  '## Controls detail',
  'App Intent idempotency/concurrency/error',
  '## Siri and App Intents detail',
  'App Intents Testing',
  '## Cross-surface architecture',
  'Serialized write-sets'
])
require_all('skill Issue splitting', skill, [
  'Serialize overlapping Xcode project',
  'write-sets'
])

contracts = {
  'AGENTS.md' => ['ios-system-experiences', '主要Feature Issue'],
  'README.md' => ['System Experiences Planning Gate', 'adopt-now', 'blocked:user'],
  'specs/product.md' => ['System Experiences Planning Gate', 'mandatory evaluation', 'optional adoption'],
  'specs/architecture.md' => ['System Experiences設計境界', '共有domain action', 'extension process'],
  'specs/acceptance.md' => ['System Experiences Planning Gate', '5面', '部分blocking'],
  'specs/development-stages.md' => ['system experience', 'Phase 1', 'Phase 2'],
  'specs/decisions.md' => ['全アプリでSystem Experiencesの評価を必須化する', 'Delivery stage', 'Related Issue: #73'],
  'docs/workflow.md' => ['System Experiences Planning Gate', 'ios-system-experiences'],
  '.agents/skills/app-bootstrap/SKILL.md' => ['ios-system-experiences', 'Identity bootstrap'],
  '.agents/skills/plan-issue-batch/SKILL.md' => ['ios-system-experiences', 'System Experiences Planning Issue'],
  '.agents/skills/ship-issue/SKILL.md' => ['System Experiences Planning Issue', 'dependent'],
  '.agents/skills/ship-issue-batch/SKILL.md' => ['System Experiences Planning Issue', '部分blocking'],
  'tools/tests/test-foundation.sh' => ['ios-system-experiences'],
  'tools/tests/test-app-bootstrap.sh' => ['ios-system-experiences']
}
contracts.each do |path, anchors|
  text = File.read(path, encoding: 'UTF-8')
  require_all(path, text, anchors)
end

manifest = JSON.parse(File.binread('Config/repository-tests.json'))
rule = manifest.fetch('domainRules').find { |entry| entry.fetch('domain') == 'system-experiences' }
abort 'system-experiences domain rule is missing' unless rule
abort 'system-experiences skill prefix is not mapped' unless rule.fetch('prefixes').include?('.agents/skills/ios-system-experiences/')
test = manifest.fetch('tests').find { |entry| entry.fetch('path') == 'tools/tests/test-ios-system-experiences-skill.sh' }
abort 'system-experiences test manifest entry is missing' unless test&.fetch('domains')&.include?('system-experiences')
RUBY

if git grep -n -E 'import (WidgetKit|ActivityKit|AppIntents)|com\.apple\.developer\.(aps-environment|associated-domains|siri|application-groups)' -- TemplateApp TemplateApp.xcodeproj >/dev/null 2>&1; then
  echo 'planning gate must not preinstall system-experience frameworks or entitlements' >&2
  exit 1
fi

echo 'iOS system experiences planning skill checks passed.'
