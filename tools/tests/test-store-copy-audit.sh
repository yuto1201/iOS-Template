#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby mktemp

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/store-copy-audit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

ruby -rjson -rdigest -rfileutils -ropen3 - "$repo_root" "$tmp" <<'RUBY'
# encoding: UTF-8
repo_root, tmp = ARGV
checker = File.join(repo_root, 'tools/check-store-copy.sh')
# #433: the app owns App Store/submission/requirements.json and may have none yet; the template's fixture holds
# the same requirements.
requirements_bytes = File.binread(File.join(repo_root, 'tools/tests/fixtures/appstore/requirements.json'))

def fail!(message)
  abort "store-copy-audit: #{message}"
end

# Fixture copy for a made-up focus timer. It passes every check with no warning.
VALID = {
  'en-US' => {
    'name' => 'Tempo: Focus Timer',
    'subtitle' => 'Plan work sessions and breaks',
    'description' => "Tempo splits your work into focused sessions with short breaks in between.\n\nFeatures:\n- Set the length of each session\n- See the sessions you finished today",
    'keywords' => 'study,concentration,productivity,deadline,routine,exam',
    'promotionalText' => 'New sound themes for quiet study are here.'
  },
  'ja' => {
    'name' => 'Tempo：集中タイマー',
    'subtitle' => '作業と休憩のリズムを作る',
    'description' => "Tempoは、作業を短い集中の時間と休憩に分けて進めるためのタイマーです。\n\n主な機能：\n・1回の長さを決める\n・今日終えた回数を見る",
    'keywords' => '勉強,学習,習慣,時間管理,試験,集中力',
    'promotionalText' => '静かな勉強に合う新しい音のテーマを追加しました。'
  }
}.freeze
CONFIG = { 'schemaVersion' => 1, 'competitors' => ['Focus Keeper'], 'trademarks' => ['Pomodoro Technique'] }.freeze

def copy_locales
  JSON.parse(JSON.generate(VALID))
end

def yaml_for(fields)
  fields.map { |key, value| "#{key}: #{JSON.generate(value)}" }.join("\n") + "\n"
end

$case_number = 0
def project(tmp, requirements_bytes, locales, config: CONFIG)
  $case_number += 1
  root = File.join(tmp, "case-#{$case_number}")
  FileUtils.mkdir_p(File.join(root, 'App Store/metadata/localizations'))
  FileUtils.mkdir_p(File.join(root, 'App Store/submission'))
  File.binwrite(File.join(root, 'App Store/submission/requirements.json'), requirements_bytes)
  locales.each do |locale, fields|
    File.write(File.join(root, "App Store/metadata/localizations/#{locale}.yml"), fields.is_a?(String) ? fields : yaml_for(fields))
  end
  File.write(File.join(root, 'App Store/metadata/aso.json'), JSON.generate(config)) if config
  File.realpath(root)
end

def run_checker(checker, root, extra = [])
  out, err, status = Open3.capture3(checker, '--project-root', root, *extra)
  [status.exitstatus, out, err]
end

def summary_of(label, result)
  status, out, err = result
  JSON.parse(out)
rescue JSON::ParserError
  fail!("#{label}: output is not JSON (exit #{status})\nstdout=#{out}\nstderr=#{err}")
end

def expect_finding(label, result, code:, severity:, locale: :any, field: :any, exit_code: nil)
  status = result[0]
  summary = summary_of(label, result)
  exit_code ||= severity == 'error' ? 1 : 0
  fail!("#{label}: expected exit #{exit_code}, got #{status}: #{result[1]}#{result[2]}") unless status == exit_code
  list = summary[severity == 'error' ? 'errors' : 'warnings']
  match = list.find do |entry|
    entry['code'] == code && entry['severity'] == severity &&
      (locale == :any || entry['locale'] == locale) && (field == :any || entry['field'] == field)
  end
  fail!("#{label}: no #{severity} #{code} in #{summary.inspect}") unless match
  fail!("#{label}: status differs from the errors") unless summary['status'] == (summary['errors'].empty? ? 'passed' : 'failed')
  summary
end

def expect_refusal(label, result, pattern)
  status, out, err = result
  fail!("#{label}: expected exit 2, got #{status}: #{out}#{err}") unless status == 2
  fail!("#{label}: refusal lacks #{pattern.inspect}: #{err}") unless err.match?(pattern)
  fail!("#{label}: refusal leaks a traceback: #{err}") if err.include?('.rb:') || err.include?('Errno')
end

# The fixture copy passes with no error and no warning, and both keyword lengths are reported in bytes by default.
valid_root = project(tmp, requirements_bytes, VALID)
result = run_checker(checker, valid_root)
fail!("valid copy: expected exit 0, got #{result[0]}: #{result[1]}#{result[2]}") unless result[0] == 0
summary = summary_of('valid copy', result)
fail!("valid copy has findings: #{summary.inspect}") unless summary['status'] == 'passed' && summary['errors'].empty? && summary['warnings'].empty?
fail!("valid copy locales differ: #{summary['locales'].inspect}") unless summary['locales'] == %w[en-US ja]
fail!("default keyword limit is not 100 bytes: #{summary['keywordLimit'].inspect}") unless summary['keywordLimit'] == { 'unit' => 'bytes', 'value' => 100 }
reported = summary['keywords'].map { |entry| [entry['locale'], entry['bytes'], entry['characters']] }
expected = VALID.sort.map { |locale, fields| [locale, fields['keywords'].bytesize, fields['keywords'].length] }
fail!("keyword lengths differ: #{reported.inspect}") unless reported == expected

# Each rejected or flagged copy: [label, locale, field, value, code, severity]. `nil` as the value removes the field.
long_ja_keywords = (['勉強時間'] * 8).each_with_index.map { |term, index| "#{term}#{index}" }.join(',')
cases = [
  ['name too long', 'en-US', 'name', 'Tempo: Focus Timer for Every Long Day', 'length', 'error'],
  ['name too short', 'en-US', 'name', 'T', 'length', 'error'],
  ['subtitle too long', 'ja', 'subtitle', '作業と休憩のリズムを作る' * 3, 'length', 'error'],
  ['promotional text too long', 'en-US', 'promotionalText', 'A' * 171, 'length', 'error'],
  ['description too long', 'ja', 'description', 'Tempoは集中のためのタイマーです。' + ('あ' * 4000), 'length', 'error'],
  ['space after a comma', 'en-US', 'keywords', 'study, routine', 'space-around-comma', 'error'],
  ['space before a comma', 'ja', 'keywords', '勉強 ,学習', 'space-around-comma', 'error'],
  ['full-width comma', 'ja', 'keywords', '勉強、学習', 'full-width-comma', 'error'],
  ['empty term', 'en-US', 'keywords', 'study,,routine', 'empty-term', 'error'],
  ['trailing comma', 'en-US', 'keywords', 'study,routine,', 'empty-term', 'error'],
  ['duplicate term', 'en-US', 'keywords', 'study,routine,Study', 'duplicate-term', 'error'],
  ['duplicate term after width folding', 'ja', 'keywords', '勉強,ＡＢＣ,abc', 'duplicate-term', 'error'],
  ['keyword in the name', 'en-US', 'keywords', 'study,timer', 'keyword-overlap', 'warning'],
  ['keyword word in the subtitle', 'en-US', 'keywords', 'study,work time', 'keyword-overlap', 'warning'],
  ['Japanese keyword in the name', 'ja', 'keywords', '勉強,タイマー', 'keyword-overlap', 'warning'],
  ['Japanese keyword in the subtitle', 'ja', 'keywords', '勉強,リズム', 'keyword-overlap', 'warning'],
  ['broad English term', 'en-US', 'keywords', 'study,app', 'broad-term', 'warning'],
  ['broad game term', 'en-US', 'keywords', 'study,games', 'broad-term', 'warning'],
  ['broad Japanese term', 'ja', 'keywords', '勉強,アプリ', 'broad-term', 'warning'],
  ['special character', 'en-US', 'keywords', 'study,#focus', 'special-character', 'warning'],
  ['Japanese special character', 'ja', 'keywords', '勉強,時間★管理', 'special-character', 'warning'],
  ['English plural', 'en-US', 'keywords', 'exam,exams,study', 'plural-duplicate', 'warning'],
  ['English plural with es', 'en-US', 'keywords', 'class,classes', 'plural-duplicate', 'warning'],
  ['English plural with ies', 'en-US', 'keywords', 'study,studies', 'plural-duplicate', 'warning'],
  ['English plural in a phrase', 'en-US', 'keywords', 'exam prep,exams', 'plural-duplicate', 'warning'],
  ['English plural in the Japanese field', 'ja', 'keywords', '勉強,deadline,deadlines', 'plural-duplicate', 'warning'],
  ['keywords over 100 bytes', 'ja', 'keywords', long_ja_keywords, 'keywords-length', 'error'],
  ['keywords over 100 characters', 'en-US', 'keywords', 'a' * 101, 'keywords-length', 'error'],
  ['free in the subtitle', 'en-US', 'subtitle', 'Free focus sessions', 'price', 'error'],
  ['price in the subtitle', 'en-US', 'subtitle', 'Focus sessions for $0.99', 'price', 'error'],
  ['discount in the subtitle', 'en-US', 'subtitle', 'Focus sessions 50% off', 'price', 'error'],
  ['無料 in the name', 'ja', 'name', 'Tempo：無料の集中タイマー', 'price', 'error'],
  ['yen price in the subtitle', 'ja', 'subtitle', '月120円で作業と休憩を計画', 'price', 'error'],
  ['full-width yen price in the name', 'ja', 'name', 'Tempo ￥120', 'price', 'error'],
  ['No.1 in the subtitle', 'en-US', 'subtitle', 'The No.1 focus timer', 'unverifiable-claim', 'error'],
  ['#1 in the subtitle', 'en-US', 'subtitle', 'The #1 study planner', 'unverifiable-claim', 'error'],
  ['best in the name', 'en-US', 'name', 'Tempo: Best Focus Timer', 'unverifiable-claim', 'error'],
  ['world\'s best in the subtitle', 'en-US', 'subtitle', "The world's best planner", 'unverifiable-claim', 'error'],
  ['世界一 in the subtitle', 'ja', 'subtitle', '世界一かんたんな集中タイマー', 'unverifiable-claim', 'error'],
  ['最高 in the name', 'ja', 'name', 'Tempo：最高の集中タイマー', 'unverifiable-claim', 'error'],
  ['No.1 in the Japanese subtitle', 'ja', 'subtitle', '満足度Ｎｏ．１の集中タイマー', 'unverifiable-claim', 'error'],
  ['competitor in the keywords', 'en-US', 'keywords', 'study,focus keeper', 'competitor-name', 'error'],
  ['competitor in the subtitle', 'en-US', 'subtitle', 'Like Focus Keeper, but calm', 'competitor-name', 'error'],
  ['trademark in the name', 'en-US', 'name', 'Pomodoro Technique Timer', 'trademark', 'error'],
  ['competitor in the description', 'en-US', 'description', 'Tempo is a calm alternative to Focus Keeper.', 'competitor-name', 'warning'],
  ['competitor in the promotional text', 'ja', 'promotionalText', 'Focus Keeperから移った方にも使いやすくしました。', 'competitor-name', 'warning'],
  ['description opens with a list', 'ja', 'description', "・1回の長さを決める\n・今日終えた回数を見る", 'first-sentence-missing', 'error'],
  ['description opens with a blank line', 'en-US', 'description', "\nTempo splits your work into sessions.", 'first-sentence-missing', 'error'],
  ['description opens with a heading', 'en-US', 'description', "# Features\nTempo splits your work into sessions.", 'first-sentence-missing', 'error'],
  ['description first sentence too long', 'ja', 'description', 'Tempoは' + ('作業を区切る' * 12) + 'タイマーです。', 'first-sentence-long', 'warning'],
  ['English first sentence too long', 'en-US', 'description', ('Tempo splits your work into focused sessions ' * 3) + 'and breaks.', 'first-sentence-long', 'warning'],
  ['price in the description', 'ja', 'description', 'Tempoは集中のためのタイマーです。月額300円で全機能を使えます。', 'price', 'warning'],
  ['promotional text as keywords', 'en-US', 'promotionalText', 'study,focus,timer,exam,deadline', 'keyword-list', 'warning'],
  ['Japanese promotional text as keywords', 'ja', 'promotionalText', '勉強、集中、タイマー、試験、習慣', 'keyword-list', 'warning'],
  ['missing name', 'en-US', 'name', nil, 'missing', 'error'],
  ['missing description', 'ja', 'description', nil, 'missing', 'error'],
  ['missing keywords', 'ja', 'keywords', '', 'missing', 'error'],
  ['non-text field', 'en-US', 'subtitle', 42, 'invalid-field', 'error']
]
cases.each do |label, locale, field, value, code, severity|
  locales = copy_locales
  if value.nil?
    locales[locale].delete(field)
  else
    locales[locale][field] = value
  end
  expect_finding(label, run_checker(checker, project(tmp, requirements_bytes, locales)), code: code, severity: severity, locale: locale, field: field)
end

# A normal sentence with commas is not a keyword list, and words that only contain a listed word are not matches.
locales = copy_locales
locales['en-US']['promotionalText'] = 'New themes, sounds, colors, and timers are here.'
locales['ja']['promotionalText'] = '新しいテーマ、音、色、通知に対応しました。'
locales['en-US']['subtitle'] = 'Sugar-free, bestseller plans'
locales['en-US']['keywords'] = 'study,concentration,applause,gamer'
fine = run_checker(checker, project(tmp, requirements_bytes, locales))
fine_summary = summary_of('near misses', fine)
fail!("near misses were flagged: #{fine_summary.inspect}") unless fine[0] == 0 && fine_summary['errors'].empty? && fine_summary['warnings'].empty?

# AC-5: the keyword limit is reported in both units and is bytes unless the config chooses characters.
locales = copy_locales
locales['ja']['keywords'] = long_ja_keywords
fail!('fixture keywords must be over 100 bytes and within 100 characters') unless long_ja_keywords.bytesize > 100 && long_ja_keywords.length <= 100
[CONFIG, CONFIG.merge('keywordLimit' => 'bytes'), nil].each_with_index do |config, index|
  summary = expect_finding("bytes limit #{index}", run_checker(checker, project(tmp, requirements_bytes, locales, config: config)),
                           code: 'keywords-length', severity: 'error', locale: 'ja', field: 'keywords')
  fail!("bytes limit #{index}: unit is not bytes") unless summary['keywordLimit'] == { 'unit' => 'bytes', 'value' => 100 }
  report = summary['keywords'].find { |entry| entry['locale'] == 'ja' }
  fail!("bytes limit #{index}: lengths differ") unless report == { 'locale' => 'ja', 'bytes' => long_ja_keywords.bytesize, 'characters' => long_ja_keywords.length }
end
characters = run_checker(checker, project(tmp, requirements_bytes, locales, config: CONFIG.merge('keywordLimit' => 'characters')))
summary = expect_finding('characters limit', characters, code: 'keywords-length-other-unit', severity: 'warning', locale: 'ja', field: 'keywords')
fail!('characters limit still reports a length error') unless summary['errors'].empty?
fail!("characters limit unit differs: #{summary['keywordLimit'].inspect}") unless summary['keywordLimit'] == { 'unit' => 'characters', 'value' => 100 }
locales['en-US']['keywords'] = 'a' * 101
expect_finding('characters limit over 100 characters', run_checker(checker, project(tmp, requirements_bytes, locales, config: CONFIG.merge('keywordLimit' => 'characters'))),
               code: 'keywords-length', severity: 'error', locale: 'en-US', field: 'keywords')
# A character limit recorded in requirements.json is used when it exists.
requirements = JSON.parse(requirements_bytes)
requirements['fields']['keywords']['maxCharacters'] = 30
summary = expect_finding('recorded character limit', run_checker(checker, project(tmp, JSON.generate(requirements), copy_locales, config: CONFIG.merge('keywordLimit' => 'characters'))),
                         code: 'keywords-length', severity: 'error', locale: 'en-US', field: 'keywords')
fail!('recorded character limit is not used') unless summary['keywordLimit'] == { 'unit' => 'characters', 'value' => 30 }

# Both ja and en-US are expected; one missing is a warning, none is an error.
expect_finding('missing en-US', run_checker(checker, project(tmp, requirements_bytes, { 'ja' => VALID['ja'] })), code: 'missing-locale', severity: 'warning', locale: 'en-US')
expect_finding('missing ja', run_checker(checker, project(tmp, requirements_bytes, { 'en-US' => VALID['en-US'] })), code: 'missing-locale', severity: 'warning', locale: 'ja')
expect_finding('no localization', run_checker(checker, project(tmp, requirements_bytes, {})), code: 'no-localizations', severity: 'error')
expect_finding('invalid YAML', run_checker(checker, project(tmp, requirements_bytes, { 'ja' => VALID['ja'], 'en-US' => "name: [unclosed\n" })), code: 'invalid-localization', severity: 'error', locale: 'en-US')
extra = run_checker(checker, project(tmp, requirements_bytes, copy_locales.merge('fr' => VALID['en-US'])))
fail!('an extra locale is not checked') unless summary_of('extra locale', extra)['locales'] == %w[en-US fr ja]

# Draft candidates outside App Store/ are checked with --localizations; the app's requirements and config still apply.
draft_root = project(tmp, requirements_bytes, {})
draft = File.join(draft_root, '.artifacts/appstore-draft/candidate-a/localizations')
FileUtils.mkdir_p(draft)
VALID.each { |locale, fields| File.write(File.join(draft, "#{locale}.yml"), yaml_for(fields)) }
drafted = run_checker(checker, draft_root, ['--localizations', '.artifacts/appstore-draft/candidate-a/localizations'])
fail!("draft candidate did not pass: #{drafted.inspect}") unless drafted[0] == 0 && summary_of('draft', drafted)['warnings'].empty?

# Refusals: exit 2 with a short message and no traceback.
expect_refusal('relative project root', run_checker(checker, 'relative/root'), /absolute directory/)
expect_refusal('missing requirements', run_checker(checker, valid_root, ['--requirements', 'missing.json']), /requirements is missing/)
expect_refusal('malformed requirements', run_checker(checker, project(tmp, '{not json', VALID)), /not valid JSON/)
expect_refusal('missing explicit config', run_checker(checker, valid_root, ['--config', 'App Store/metadata/other.json']), /ASO config is missing/)
expect_refusal('unknown config key', run_checker(checker, project(tmp, requirements_bytes, VALID, config: CONFIG.merge('extra' => true))), /config keys/)
expect_refusal('unknown keyword unit', run_checker(checker, project(tmp, requirements_bytes, VALID, config: CONFIG.merge('keywordLimit' => 'words'))), /bytes or characters/)
expect_refusal('config without schema', run_checker(checker, project(tmp, requirements_bytes, VALID, config: { 'competitors' => [] })), /schemaVersion/)
expect_refusal('empty competitor name', run_checker(checker, project(tmp, requirements_bytes, VALID, config: CONFIG.merge('competitors' => [' ']))), /list of names/)
expect_refusal('missing localizations directory', run_checker(checker, valid_root, ['--localizations', 'nowhere']), /localizations directory is missing/)
link_root = project(tmp, requirements_bytes, { 'ja' => VALID['ja'] })
outside = File.join(tmp, 'outside.yml')
File.write(outside, yaml_for(VALID['en-US']))
File.symlink(outside, File.join(link_root, 'App Store/metadata/localizations/en-US.yml'))
expect_refusal('linked localization', run_checker(checker, link_root), /must not be a symbolic link/)
expect_refusal('unexpected argument', run_checker(checker, valid_root, ['extra']), /unexpected arguments/)

# The checker never changes the sources it reads.
def tree_digest(root)
  Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).sort.map do |path|
    next if %w[. ..].include?(File.basename(path))
    stat = File.lstat(path)
    "#{path.delete_prefix(root)}\0#{stat.mode}\0#{stat.file? ? Digest::SHA256.file(path).hexdigest : File.symlink?(path) ? File.readlink(path) : 'dir'}"
  end.compact.join("\n")
end
locales = copy_locales
locales['en-US']['keywords'] = 'study, study'
untouched = project(tmp, requirements_bytes, locales)
before = tree_digest(untouched)
run_checker(checker, untouched)
run_checker(checker, untouched, ['--localizations', 'App Store/metadata/localizations'])
fail!('the checker changed the project') unless tree_digest(untouched) == before

# The checker reads local files only and writes nothing.
library = File.read(File.join(repo_root, 'tools/lib/store-copy-audit.rb'), encoding: 'UTF-8')
%w[net/http net/https open-uri socket open3 resolv fileutils tempfile].each do |name|
  fail!("checker must not load #{name}") if library.match?(/require\s+["']#{Regexp.escape(name)}["']/)
end
fail!('checker must not run commands') if library.match?(/\b(system|spawn|exec|IO\.popen|fork)\b|`/)
fail!('checker must not write files') if library.match?(/\b(?:binwrite|write|syswrite|mkdir|mkpath|rename|unlink|delete|chmod|truncate)\s*\(|File\.open|\.open\s*\(/)
wrapper = File.read(checker)
fail!('checker wrapper must clear the environment') unless wrapper.include?('/usr/bin/env -i PATH=/usr/bin:/bin')
fail!('checker wrapper must bound the run') unless wrapper.include?('bounded-command.rb') && wrapper.include?('--timeout-seconds')

def require_all(label, text, values)
  missing = values.reject { |value| text.include?(value) }
  fail!("#{label} lacks #{missing.inspect}") unless missing.empty?
end

# AC-3: the guide has every section, separates Apple's statements from practitioner knowledge, cites a source with
# a check date in each section, and says that the keyword unit and the en-US handling in Japan are not settled.
guide = File.read(File.join(repo_root, 'docs/store-copy-aso.md'), encoding: 'UTF-8')
# Headings inside fenced examples are not sections of the guide.
outline = guide.gsub(/^```.*?^```\n/m, '')
sections = ['アプリ名', 'サブタイトル', 'キーワード', 'プロモーション用テキスト', '説明', "What's New", 'スクリーンショットの見出し', '計測と改善']
sections.each do |title|
  body = outline[/^## #{Regexp.escape(title)}\n(.*?)(?=^## |\z)/m, 1] or fail!("guide lacks the section #{title}")
  fail!("guide section #{title} has no check date") unless body.include?('確認日：2026-10-21')
  official = body[/^### Apple公式\n(.*?)(?=^### |\z)/m, 1] or fail!("guide section #{title} lacks Apple's statements")
  practice = body[/^### 実務の知見\n(.*?)(?=^### |\z)/m, 1] or fail!("guide section #{title} lacks practitioner knowledge")
  fail!("guide section #{title} cites no Apple page") unless official.include?('https://developer.apple.com/')
  { 'Apple' => official, 'practitioner' => practice }.each do |kind, text|
    claims = text.lines.select { |line| line.start_with?('- ') }
    fail!("guide section #{title} has no #{kind} entry") if claims.empty?
    uncited = claims.reject { |line| line.include?('https://') || line.include?('実務の出典はありません') }
    fail!("guide section #{title} has #{kind} claims without a source: #{uncited.inspect}") unless uncited.empty?
  end
  fail!("guide section #{title} mixes practitioner sources into Apple's statements") if official.match?(%r{https://(?!developer\.apple\.com/)})
  %w[何を書くか 避けること 検査toolが確かめるか].each do |part|
    fail!("guide section #{title} lacks #{part}") unless body.include?(part)
  end
end
require_all('guide', guide, [
  '### Apple公式', '### 実務の知見', '確認日：2026-10-21',
  'https://developer.apple.com/app-store/search/',
  'https://developer.apple.com/app-store/product-page/',
  'https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information',
  'https://developer.apple.com/app-store/review/guidelines/',
  'https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations/',
  'https://developer.apple.com/app-store/product-page-optimization/',
  'https://developer.apple.com/app-store/custom-product-pages/',
  'https://www.apptweak.com/en/aso-blog/how-to-optimize-your-ios-keyword-field',
  'https://appfigures.com/resources/guides/app-store-algorithm-update-2025',
  'https://www.consultmyapp.com/blog/-is-apple-now-indexing-screenshot-titles-on-the-app-store',
  '100バイト', '100 characters', 'tools/check-store-copy.sh', 'App Store/metadata/aso.json', 'aso-decisions.md',
  '2.3.3', '2.3.7', '2.3.12', '2.3.14', '5.6.1'
])
unsettled = outline[/^## 決まっていないこと\n(.*?)(?=^## |\z)/m, 1] or fail!('guide lacks the unsettled section')
require_all('guide unsettled section', unsettled, ['100バイト', '100 characters', '英語（米国）', 'Appleは明記して', 'バイト数'])
%w[error warning].each { |severity| fail!("guide does not explain #{severity}") unless guide.include?("`#{severity}`") }
codes = library.scan(/finding\("(?:error|warning)", [^,]+, [^,]+, "([a-z-]+)"/).flatten.uniq + %w[competitor-name trademark]
fail!('no finding codes were found in the checker') if codes.length < 15
undocumented = codes.reject { |code| guide.include?("`#{code}`") }
fail!("guide does not explain the codes #{undocumented.inspect}") unless undocumented.empty?

# AC-6: the preparation skill drafts two or three candidates, runs the checker, records the user's choice and its
# reasons, and keeps the existing no-invention rule and the save boundary. The creative skill points at the guide.
prepare = File.read(File.join(repo_root, '.agents/skills/prepare-appstore-assets/SKILL.md'), encoding: 'UTF-8')
require_all('prepare skill', prepare, [
  'docs/store-copy-aso.md', 'tools/check-store-copy.sh', 'two or three', '--localizations', 'aso-decisions.md',
  'explicit choice', 'target', 'avoided', 'Do not invent marketing, privacy, account-deletion, or legal claims.',
  'save-appstore-metadata', 'not approval'
])
creative = File.read(File.join(repo_root, '.agents/skills/appstore-creative/SKILL.md'), encoding: 'UTF-8')
fail!('creative skill does not point at the screenshot section of the guide') unless creative.scan('docs/store-copy-aso.md#スクリーンショットの見出し').length >= 2
fail!('creative skill still waits for the guide') if creative.include?('when it exists') || creative.include?('until the App Store copy guide (ASO) exists')

puts "App Store ASO checker passed (#{cases.size} copy cases, keyword-limit, locale, refusal, read-only and guide checks)"
RUBY
