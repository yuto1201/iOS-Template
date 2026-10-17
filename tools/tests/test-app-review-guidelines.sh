#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby readlink

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

skill_dir=.agents/skills/app-review-guidelines
claude_skill=.claude/skills/app-review-guidelines

for path in "$skill_dir/SKILL.md" "$skill_dir/guidelines.json"; do
  [[ -f "$path" ]] || { echo "missing app-review-guidelines resource: $path" >&2; exit 1; }
done

[[ -L "$claude_skill" ]] || { echo 'Claude app-review-guidelines route must be a symlink' >&2; exit 1; }
[[ "$(readlink "$claude_skill")" == ../../.agents/skills/app-review-guidelines ]] || {
  echo 'Claude app-review-guidelines route is not portable' >&2
  exit 1
}
[[ -f "$claude_skill/SKILL.md" ]] || { echo 'Claude app-review-guidelines route is broken' >&2; exit 1; }

ruby -rjson -rdate <<'RUBY'
# encoding: UTF-8
def fail!(message)
  abort "app-review-guidelines: #{message}"
end

def require_all(label, text, values)
  missing = values.reject { |value| text.include?(value) }
  fail!("#{label} lacks #{missing.inspect}") unless missing.empty?
end

map_path = '.agents/skills/app-review-guidelines/guidelines.json'
map = JSON.parse(File.read(map_path, encoding: 'UTF-8'))

expected_keys = %w[schemaVersion source maxAgeDays classes featureKinds containers omitted guidelines]
fail!("map keys differ: #{map.keys.inspect}") unless map.keys == expected_keys
fail!('schemaVersion must be 1') unless map['schemaVersion'] == 1
fail!('maxAgeDays must be 30') unless map['maxAgeDays'] == 30

source = map['source']
fail!("source keys differ: #{source.keys.inspect}") unless source.keys == %w[url lastUpdated retrievedAt]
fail!('source url differs') unless source['url'] == 'https://developer.apple.com/app-store/review/guidelines/'
date_pattern = /\A\d{4}-\d{2}-\d{2}\z/
%w[lastUpdated retrievedAt].each do |key|
  fail!("source #{key} is not a date") unless source[key].is_a?(String) && source[key].match?(date_pattern)
  Date.iso8601(source[key])
end
fail!('retrievedAt precedes lastUpdated') if Date.iso8601(source['retrievedAt']) < Date.iso8601(source['lastUpdated'])
fail!('lastUpdated must record the 2026-10-16 page') unless source['lastUpdated'] >= '2026-10-16'

classes = %w[always triggered user-judgment]
fail!("classes differ: #{map['classes'].keys.inspect}") unless map['classes'].keys == classes

kinds = map['featureKinds']
fail!('featureKinds must be a non-empty object') unless kinds.is_a?(Hash) && !kinds.empty?
kinds.each do |kind, description|
  fail!("feature kind is not kebab-case: #{kind}") unless kind.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
  fail!("feature kind lacks a Japanese description: #{kind}") unless description.is_a?(String) && description.match?(/\p{Han}|\p{Hiragana}|\p{Katakana}/)
end

id_pattern = /\A[1-5]\.\d+(?:\.\d+)?(?:\((?:[a-z]|i|ii|iii|iv|v|vi|vii|viii|ix|x)\))?\z/
guidelines = map['guidelines']
fail!('guidelines must be a non-empty array') unless guidelines.is_a?(Array) && !guidelines.empty?

all_ids = []
used_kinds = []
guidelines.each do |entry|
  fail!("guideline keys differ: #{entry.inspect}") unless entry.keys == %w[id class features summary check]
  id = entry['id']
  fail!("guideline id is malformed: #{id.inspect}") unless id.is_a?(String) && id.match?(id_pattern)
  fail!("guideline #{id} has an unknown class") unless classes.include?(entry['class'])
  features = entry['features']
  fail!("guideline #{id} features must be an array") unless features.is_a?(Array)
  fail!("guideline #{id} repeats a feature kind") unless features.uniq.size == features.size
  if entry['class'] == 'triggered'
    fail!("triggered guideline #{id} has no feature kind") if features.empty?
  else
    fail!("#{entry['class']} guideline #{id} must not have feature kinds") unless features.empty?
  end
  unknown = features - kinds.keys
  fail!("guideline #{id} uses unknown feature kinds #{unknown.inspect}") unless unknown.empty?
  used_kinds.concat(features)
  %w[summary check].each do |key|
    text = entry[key]
    fail!("guideline #{id} #{key} is empty") unless text.is_a?(String) && !text.strip.empty?
    fail!("guideline #{id} #{key} is not Japanese") unless text.match?(/\p{Hiragana}|\p{Katakana}/)
    # The map paraphrases Apple's page; a long English run suggests copied guideline text.
    fail!("guideline #{id} #{key} contains a long English run") if text.match?(/[A-Za-z][A-Za-z ,.'’()\-]{40,}/)
  end
  all_ids << id
end

containers = map['containers']
omitted = map['omitted']
[containers, omitted].each do |list|
  fail!('containers and omitted must be arrays of guideline numbers') unless list.is_a?(Array) && list.all? { |id| id.is_a?(String) && id.match?(id_pattern) }
end
everything = all_ids + containers + omitted
duplicates = everything.group_by(&:itself).select { |_, values| values.size > 1 }.keys
fail!("a guideline number appears more than once: #{duplicates.inspect}") unless duplicates.empty?
unused = kinds.keys - used_kinds
fail!("feature kinds are not used by any guideline: #{unused.inspect}") unless unused.empty?

# Every top-level section of Apple's page must be represented.
%w[1 2 3 4 5].each do |section|
  fail!("section #{section} has no guideline") unless all_ids.any? { |id| id.start_with?("#{section}.") }
end
%w[2.5.7 2.5.10 4.2.4 4.2.5 4.4.3 4.6].each do |id|
  fail!("omitted number #{id} is not recorded") unless omitted.include?(id)
end

by_id = guidelines.to_h { |entry| [entry['id'], entry] }
expectations = {
  '1.2' => ['triggered', ['user-content']],
  '1.5' => ['always', []],
  '2.1(a)' => ['always', []],
  '2.1(b)' => ['triggered', %w[digital-purchases subscriptions]],
  '2.3.3' => ['always', []],
  '3.1.1' => ['triggered', %w[digital-purchases subscriptions]],
  '3.1.2(a)' => ['triggered', ['subscriptions']],
  '4.2' => ['user-judgment', []],
  '4.3' => ['user-judgment', []],
  '4.5.4' => ['triggered', ['notifications']],
  '4.8' => ['triggered', ['third-party-login']],
  '5.1.1(i)' => ['always', []],
  '5.1.1(ii)' => ['always', []],
  '5.1.1(v)' => ['triggered', %w[accounts third-party-login]],
  '5.1.2(i)' => ['triggered', %w[personal-data tracking third-party-ai advertising]],
  '5.1.4' => ['triggered', ['kids']],
  '5.1.5' => ['triggered', ['location']],
  '5.2' => ['user-judgment', []],
  '5.6.1' => ['triggered', ['review-prompts']]
}
expectations.each do |id, (klass, features)|
  entry = by_id[id] or fail!("key guideline #{id} is missing")
  fail!("key guideline #{id} class is #{entry['class']}, expected #{klass}") unless entry['class'] == klass
  fail!("key guideline #{id} features are #{entry['features'].inspect}") unless entry['features'] == features
end
require_all('5.1.1(v) requirement', by_id['5.1.1(v)']['summary'], ['アプリ内で削除'])
require_all('4.8 requirement', by_id['4.8']['summary'] + by_id['4.8']['check'], ['同等', 'Sign in with Apple'])
require_all('3.1.1 requirement', by_id['3.1.1']['summary'], ['復元'])
require_all('1.2 requirement', by_id['1.2']['summary'], ['通報', 'ブロック'])

skill = File.read('.agents/skills/app-review-guidelines/SKILL.md', encoding: 'UTF-8')
fail!('skill frontmatter name differs') unless skill.match?(/\A---\nname: app-review-guidelines\n/)
description = skill[/\A---\n.*?\ndescription:\s*(.+?)\n---\n/m, 1]
fail!('skill description must start with "Use when" and route planning') unless description&.start_with?('Use when') && description.match?(/plann|Feature Issue/)
require_all('skill planning workflow', skill, [
  'guidelines.json',
  'D-081',
  'Last Updated',
  'lastUpdated',
  'retrievedAt',
  'maxAgeDays',
  'featureKinds',
  'always',
  'triggered',
  'user-judgment',
  '受け入れ条件',
  '当たる機能はない',
  'blocked:user',
  'ユーザーの判断',
  '対応表の更新',
  'Appleの本文を写さない',
  'test-app-review-guidelines.sh',
  '後続Issue(2)',
  '提出前の点検を行わず'
])

planning_docs = {
  '.agents/skills/plan-issue-batch/SKILL.md' => ['app-review-guidelines', 'D-081', 'triggered', 'acceptance criteria', 'no `triggered` guideline applies', 'user-judgment', 'blocked:user'],
  '.agents/skills/spec-workflow/SKILL.md' => ['app-review-guidelines', 'D-081', 'triggered', 'acceptance criterion', 'no `triggered` guideline applies', 'user-judgment', 'blocked:user'],
  'docs/agent-contracts/spec-reviewer.md' => ['app-review-guidelines', 'D-081', 'triggered', 'acceptance criterion', 'no `triggered` guideline applies', 'user-judgment'],
  '.github/ISSUE_TEMPLATE/feature.yml' => ['app-review-guidelines', 'D-081', 'App Store Review Guideline', 'AC', 'no triggered guideline applies']
}
planning_docs.each do |path, values|
  require_all(path, File.read(path, encoding: 'UTF-8'), values)
end

puts "app-review-guidelines map and planning workflow passed (#{all_ids.size} guidelines)"
RUBY
