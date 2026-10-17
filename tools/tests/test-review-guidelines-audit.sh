#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby mktemp

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/review-guidelines-audit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

ruby -rjson -rdigest -rfileutils -ropen3 -rdate - "$repo_root" "$tmp" <<'RUBY'
# encoding: UTF-8
repo_root, tmp = ARGV
checker = File.join(repo_root, 'tools/check-review-guidelines.sh')
map_relative = '.agents/skills/app-review-guidelines/guidelines.json'
map_bytes = File.binread(File.join(repo_root, map_relative))
map = JSON.parse(map_bytes)
now = "#{map['source']['retrievedAt']}T12:00:00Z"
comment = 'https://github.com/example/ExampleApp/issues/12#issuecomment-345'

def fail!(message)
  abort "review-guidelines-audit: #{message}"
end

def valid_audit(map, map_bytes, comment)
  items = map['guidelines'].map do |entry|
    case entry['class']
    when 'always'
      { 'id' => entry['id'], 'status' => 'satisfied', 'evidence' => ['App Store/legal/privacy-policy.md', 'https://app.yutodev.com/apps/example/support/'] }
    when 'triggered'
      if entry['id'] == '5.1.1(v)'
        { 'id' => entry['id'], 'status' => 'satisfied', 'evidence' => ['ExampleApp/Settings/AccountDeletionView.swift:12'], 'note' => 'アプリ内で削除できる。' }
      else
        { 'id' => entry['id'], 'status' => 'not-applicable', 'reason' => '該当する機能を持たない。' }
      end
    else
      { 'id' => entry['id'], 'status' => 'user-confirmed',
        'confirmation' => { 'by' => 'user', 'confirmedAt' => "#{map['source']['retrievedAt']}T09:00:00Z", 'reference' => comment } }
    end
  end
  {
    'schemaVersion' => 1,
    'map' => { 'lastUpdated' => map['source']['lastUpdated'], 'digest' => "sha256:#{Digest::SHA256.hexdigest(map_bytes)}" },
    'app' => { 'bundleId' => 'com.example.app', 'version' => '1.2.0', 'build' => '42' },
    'auditedAt' => "#{map['source']['retrievedAt']}T10:00:00Z",
    'items' => items
  }
end

$case_number = 0
def project(tmp, map_bytes)
  $case_number += 1
  root = File.join(tmp, "case-#{$case_number}")
  FileUtils.mkdir_p(File.join(root, '.agents/skills/app-review-guidelines'))
  File.binwrite(File.join(root, '.agents/skills/app-review-guidelines/guidelines.json'), map_bytes)
  FileUtils.mkdir_p(File.join(root, 'App Store/legal'))
  File.write(File.join(root, 'App Store/legal/privacy-policy.md'), "Status: Confirmed\n")
  FileUtils.mkdir_p(File.join(root, 'ExampleApp/Settings'))
  File.write(File.join(root, 'ExampleApp/Settings/AccountDeletionView.swift'), "struct AccountDeletionView {}\n")
  FileUtils.mkdir_p(File.join(root, 'App Store/review'))
  File.realpath(root)
end

def run_checker(checker, root, audit, now, extra = [], raw: nil)
  path = File.join(root, 'App Store/review/guidelines-audit.json')
  File.write(path, raw || JSON.pretty_generate(audit)) unless audit.nil? && raw.nil?
  args = [checker, '--project-root', root, '--bundle-id', 'com.example.app', '--version', '1.2.0', '--build', '42', '--now', now] + extra
  out, err, status = Open3.capture3(*args)
  [status.exitstatus, out, err]
end

def expect(label, result, code, pattern)
  status, out, err = result
  fail!("#{label}: expected exit #{code}, got #{status}\nstdout=#{out}\nstderr=#{err}") unless status == code
  text = out + err
  fail!("#{label}: output lacks #{pattern.inspect}: #{text}") unless text.match?(pattern)
end

# A complete audit passes and reports the bound map and status counts.
root = project(tmp, map_bytes)
result = run_checker(checker, root, valid_audit(map, map_bytes, comment), now)
expect('valid audit', result, 0, /"status":"passed"/)
summary = JSON.parse(result[1])
fail!('summary map digest differs') unless summary['mapDigest'] == "sha256:#{Digest::SHA256.hexdigest(map_bytes)}"
fail!('summary lastUpdated differs') unless summary['mapLastUpdated'] == map['source']['lastUpdated']
counts = summary['counts']
expected_counts = Hash.new(0)
map['guidelines'].each do |entry|
  key = { 'always' => 'satisfied', 'user-judgment' => 'user-confirmed' }[entry['class']] ||
        (entry['id'] == '5.1.1(v)' ? 'satisfied' : 'not-applicable')
  expected_counts[key] += 1
end
fail!("summary counts differ: #{counts.inspect}") unless counts == expected_counts.sort.to_h

mutations = {
  'missing guideline' => [->(a) { a['items'].reject! { |i| i['id'] == '1.1.1' } }, /audit misses guideline 1\.1\.1/],
  'duplicate guideline' => [->(a) { a['items'] << a['items'].first.dup }, /appears 2 times/],
  'unknown guideline' => [->(a) { a['items'] << { 'id' => '9.9', 'status' => 'not-applicable', 'reason' => 'x' } }, /not in the guideline map/],
  'always marked not applicable' => [->(a) { i = a['items'].find { |x| x['id'] == '5.1.1(i)' }; i.replace('id' => i['id'], 'status' => 'not-applicable', 'reason' => '不要') }, /not allowed for always/],
  'user-judgment decided by AI as satisfied' => [->(a) { i = a['items'].find { |x| x['id'] == '4.2' }; i.replace('id' => '4.2', 'status' => 'satisfied', 'evidence' => ['App Store/legal/privacy-policy.md']) }, /not allowed for user-judgment/],
  'user-judgment confirmed by AI' => [->(a) { a['items'].find { |x| x['id'] == '4.3' }['confirmation']['by'] = 'claude' }, /confirmed by the user/],
  'confirmation without a comment URL' => [->(a) { a['items'].find { |x| x['id'] == '4.3' }['confirmation']['reference'] = 'said yes in chat' }, /GitHub Issue comment URL/],
  'satisfied without evidence' => [->(a) { a['items'].find { |x| x['id'] == '1.5' }['evidence'] = [] }, /needs at least one evidence/],
  'missing evidence path' => [->(a) { a['items'].find { |x| x['id'] == '1.5' }['evidence'] = ['App Store/legal/support.md'] }, /evidence path does not exist/],
  'evidence outside the project' => [->(a) { a['items'].find { |x| x['id'] == '1.5' }['evidence'] = ['../secrets.txt'] }, /inside the project/],
  'not applicable without reason' => [->(a) { a['items'].find { |x| x['id'] == '1.2' }['reason'] = ' ' }, /needs a reason/],
  'unknown item key' => [->(a) { a['items'].find { |x| x['id'] == '1.2' }['decidedBy'] = 'ai' }, /keys must be/],
  'unknown audit key' => [->(a) { a['extra'] = true }, /audit keys must be exactly/],
  'map date mismatch' => [->(a) { a['map']['lastUpdated'] = '2026-01-01' }, /lastUpdated differs/],
  'map digest mismatch' => [->(a) { a['map']['digest'] = "sha256:#{'0' * 64}" }, /digest differs/],
  'version mismatch' => [->(a) { a['app']['version'] = '1.1.0' }, /app version differs/],
  'build mismatch' => [->(a) { a['app']['build'] = '41' }, /app build differs/],
  'bundle mismatch' => [->(a) { a['app']['bundleId'] = 'com.example.other' }, /app bundleId differs/],
  'secret-like note' => [->(a) { a['items'].find { |x| x['id'] == '2.1(a)' }['note'] = 'demo password: hunter2' }, /secret-like/]
}
mutations.each do |label, (mutate, pattern)|
  audit = valid_audit(map, map_bytes, comment)
  mutate.call(audit)
  expect(label, run_checker(checker, project(tmp, map_bytes), audit, now), 1, pattern)
end

stale_now = "#{(Date.iso8601(map['source']['retrievedAt']) + map['maxAgeDays'] + 1).iso8601}T00:00:00Z"
expect('stale map', run_checker(checker, project(tmp, map_bytes), valid_audit(map, map_bytes, comment), stale_now), 1, /beyond 30 days/)

expect('missing audit', run_checker(checker, project(tmp, map_bytes), nil, now), 2, /audit is missing/)
expect('malformed audit', run_checker(checker, project(tmp, map_bytes), nil, now, raw: '{not json'), 2, /not valid JSON/)
expect('relative project root', run_checker(checker, 'relative/root', nil, now), 2, /absolute directory/)
expect('missing version', Open3.capture3(checker, '--project-root', project(tmp, map_bytes), '--bundle-id', 'b', '--build', '1').then { |o, e, s| [s.exitstatus, o, e] }, 2, /--version is required/)

# The checker reads local files only.
library = File.read(File.join(repo_root, 'tools/lib/review-guidelines-audit.rb'))
%w[net/http open-uri socket open3 resolv].each do |name|
  fail!("checker must not load #{name}") if library.match?(/require\s+["']#{Regexp.escape(name)}["']/)
end
fail!('checker must not run commands') if library.match?(/\b(system|spawn|exec|IO\.popen)\b|`/)
wrapper = File.read(checker)
fail!('checker wrapper must clear the environment') unless wrapper.include?('/usr/bin/env -i PATH=/usr/bin:/bin')
fail!('checker wrapper must bound the run') unless wrapper.include?('bounded-command.rb') && wrapper.include?('--timeout-seconds')

# The skill and the submission documents use the checker as a gate.
def require_all(label, text, values)
  missing = values.reject { |value| text.include?(value) }
  fail!("#{label} lacks #{missing.inspect}") unless missing.empty?
end
skill = File.read(File.join(repo_root, '.agents/skills/app-review-guidelines/SKILL.md'), encoding: 'UTF-8')
require_all('skill pre-submission audit', skill, [
  '## 提出前の点検', 'App Store/review/guidelines-audit.json', 'tools/check-review-guidelines.sh',
  'satisfied', 'not-applicable', 'user-confirmed', 'issuecomment', 'Last Updated', '審査通過の証拠'
])
{
  '.agents/skills/prepare-appstore-assets/SKILL.md' => ['tools/check-review-guidelines.sh', 'app-review-guidelines', 'D-081', 'release-auditor', 'seal'],
  '.agents/skills/submit-appstore-release/SKILL.md' => ['tools/check-review-guidelines.sh', 'D-081', 'resume', 'authenticated write'],
  'docs/agent-contracts/release-auditor.md' => ['tools/check-review-guidelines.sh', 'D-081', 'user-judgment', 'App Review'],
  'docs/agent-contracts/appstore-submission.md' => ['tools/check-review-guidelines.sh', 'D-081', 'App Store/review/guidelines-audit.json', 'not evidence that App Review']
}.each do |path, values|
  require_all(path, File.read(File.join(repo_root, path), encoding: 'UTF-8'), values)
end

puts "review guidelines audit checker passed (#{mutations.size + 5} rejection cases)"
RUBY
