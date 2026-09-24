#!/bin/bash
set -euo pipefail
export LANG=en_US.UTF-8

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby git

root=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-metadata-save.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf -- "$scratch"' EXIT

/usr/bin/ruby --disable-gems - "$root" "$scratch" <<'RUBY'
# encoding: UTF-8
require 'json'
require 'yaml'
require 'digest'
require 'fileutils'
require 'open3'
require 'time'

root, scratch = ARGV
project = File.join(scratch, 'project')
entry = File.join(root, '.agents/skills/save-appstore-metadata/scripts/save-appstore-metadata.sh')
FileUtils.mkdir_p(project)
def check(value, label)
  abort "FAIL: #{label}" unless value
end
check(File.symlink?(File.join(root,'.claude/skills/save-appstore-metadata')) &&
  File.readlink(File.join(root,'.claude/skills/save-appstore-metadata')) == '../../.agents/skills/save-appstore-metadata', 'Claude skill alias')
check(File.binread(File.join(root,'.agents/skills/submit-appstore-release/SKILL.md')).include?('../save-appstore-metadata/SKILL.md'), 'save mode routing')
def canonical(value)
  case value
  when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
  when Array then value.map { |item| canonical(item) }
  else value
  end
end
def digest(value)
  "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
end
def write(project, path, value)
  absolute = File.join(project, path)
  FileUtils.mkdir_p(File.dirname(absolute))
  File.binwrite(absolute, value.is_a?(String) ? value : path.end_with?('.yml') ? YAML.dump(value) : JSON.generate(value))
end
def git(project, *args)
  output, status = Open3.capture2e('/usr/bin/git', '-C', project, *args)
  check(status.success?, "fixture git #{args.first}")
  output.strip
end

identity = {'schemaVersion'=>1, 'sourceIdentityVersion'=>1, 'displayName'=>'Garden Notes', 'moduleName'=>'GardenNotes', 'appSlug'=>'garden-notes', 'bundleId'=>'com.example.garden'}
write(project, 'Config/app-identity.json', identity)
FileUtils.cp(File.join(root, 'Config/template-identity.json'), File.join(project, 'Config/template-identity.json'))
FileUtils.cp(File.join(root, 'Config/Public.xcconfig'), File.join(project, 'Config/Public.xcconfig'))
ownership = YAML.safe_load(File.binread(File.join(root, 'Config/ownership.yml')), permitted_classes: [], aliases: false)
ownership['appStore'] = {'teamId'=>'TEAM123456', 'bundleId'=>'com.example.garden'}
write(project, 'Config/ownership.yml', ownership)
write(project, 'App Store/metadata/app.yml', {'schemaVersion'=>1, 'bundleId'=>'com.example.garden', 'version'=>'1.0', 'primaryLocale'=>'en-US', 'platforms'=>{'iphone'=>true,'ipad'=>true}, 'category'=>'Utilities', 'copyright'=>'2026 Garden Notes', 'supportURL'=>'https://example.com/support', 'privacyPolicyURL'=>'https://example.com/privacy', 'reviewContactReference'=>'none', 'accountsSupported'=>false})
write(project, 'App Store/metadata/preparation.json', {'schemaVersion'=>1, 'recordType'=>'appstore-preparation-sources', 'sku'=>'garden-notes-ios', 'build'=>'1', 'supportedLocales'=>['en-US','ja'], 'account'=>{'appId'=>'1234567890','userAccess'=>'all'}})
write(project, 'App Store/metadata/localizations/en-US.yml', {'name'=>'Garden Notes','subtitle'=>'A garden journal','description'=>'A confirmed garden journal description.','promotionalText'=>'A reviewed message.'})
write(project, 'App Store/metadata/localizations/ja.yml', {'name'=>'庭ノート','subtitle'=>'庭を記録','description'=>'確認済みの庭日記です。','promotionalText'=>'確認済みのお知らせ。'})
write(project, 'App Store/release-notes/en-US.md', "New garden journal notes.\n")
write(project, 'specs/product.md', "# Garden journal\n\nStatus: Confirmed\n\nKeep a garden journal.\n")
write(project, 'GardenNotes/Journal.swift', "struct Journal { var entries: [String] = [] }\n")
pbx = File.binread(File.join(root, 'TemplateApp.xcodeproj/project.pbxproj')).gsub('com.yuto.TemplateApp','com.example.garden').gsub('TemplateApp','GardenNotes')
pbx = pbx.gsub('PRODUCT_BUNDLE_IDENTIFIER = com.example.garden;', 'PRODUCT_BUNDLE_IDENTIFIER = com.example.garden; INFOPLIST_KEY_CFBundleDisplayName = "Garden Notes";')
write(project, 'GardenNotes.xcodeproj/project.pbxproj', pbx)
scheme = File.binread(File.join(root, 'TemplateApp.xcodeproj/xcshareddata/xcschemes/TemplateApp.xcscheme')).gsub('TemplateApp','GardenNotes')
write(project, 'GardenNotes.xcodeproj/xcshareddata/xcschemes/GardenNotes.xcscheme', scheme)
write(project, '.artifacts/appstore-preparation/account-observation.json', {'schemaVersion'=>1,'recordType'=>'appstore-account-observation','source'=>'synthetic-fixture','observedAt'=>Time.now.utc.iso8601,'status'=>'observed','inventoryComplete'=>true,'teamId'=>'TEAM123456','role'=>'APP_MANAGER','agreements'=>'current','bundles'=>['com.example.garden'],'apps'=>[{'appId'=>'1234567890','bundleId'=>'com.example.garden','name'=>'Garden Notes','sku'=>'garden-notes-ios','primaryLocale'=>'en-US','platforms'=>['IOS'],'userAccess'=>'all'}]})
git(project, 'init', '-q')
git(project, 'config', 'user.name', 'Synthetic Fixture')
git(project, 'config', 'user.email', 'fixture@example.invalid')
git(project, 'remote', 'add', 'origin', 'https://github.com/example/save-fixture.git')
git(project, 'add', 'Config', 'App Store', 'GardenNotes', 'GardenNotes.xcodeproj', 'specs')
git(project, '-c', 'core.hooksPath=/dev/null', 'commit', '-q', '-m', 'Synthetic metadata fixture')
source_revision = git(project, 'rev-parse', 'HEAD')

prepare = lambda do
  output, error, status = Open3.capture3(File.join(root, 'tools/prepare-appstore-sources.sh'), '--project-root', project)
  check(status.exitstatus == 1 && error.empty?, "preparation report executes (#{status.exitstatus}, #{error}, #{output[0,300]})")
  JSON.parse(output)
end
baseline = prepare.call
def source_descriptor(project, revision, path, anchor='document')
  bytes = File.binread(File.join(project, path))
  {'path'=>path, 'anchor'=>anchor, 'revision'=>path.start_with?('.artifacts/') ? nil : revision, 'digest'=>"sha256:#{Digest::SHA256.hexdigest(bytes)}"}
end
index = {'schemaVersion'=>1,'recordType'=>'appstore-preparation-confirmations','records'=>[]}
%w[en-US ja].each do |locale|
  fields = %w[description promotionalText]
  fields += %w[name subtitle releaseNotes] if locale == 'en-US'
  fields.each do |field|
    row = baseline.fetch('fields').find { |item| item['fieldId'] == field && item['locale'] == locale }
    check(row && row['classification'].include?('derive'), "preparation #{locale} #{field} classification")
    record = {'fieldId'=>field,'locale'=>locale,'proofs'=>{},'remoteReadback'=>nil}
    row['classification'].each do |kind|
      path = ".artifacts/appstore-preparation/proofs/#{locale.downcase}-#{field.downcase}-#{kind}.json"
      proof = {'schemaVersion'=>1,'recordType'=>'appstore-preparation-proof','kind'=>kind,'fieldId'=>field,'locale'=>locale,'section'=>row['section'],'sourceFingerprint'=>row['sourceFingerprint'],'checkedAt'=>Time.now.utc.iso8601,'reviewer'=>kind == 'user' ? 'user' : 'codex','decision'=>kind == 'user' ? 'approved' : 'reviewed','reference'=>kind == 'user' ? 'user-approval://synthetic-garden-naming' : 'review://synthetic-garden-copy','basis'=>[source_descriptor(project, source_revision, 'specs/product.md', '# Garden journal'),source_descriptor(project, source_revision, 'GardenNotes/Journal.swift')]}
      write(project, path, proof)
      record['proofs'][kind] = source_descriptor(project, source_revision, path)
    end
    index['records'] << record
  end
end
index_path = '.artifacts/appstore-preparation/confirmations.json'
write(project, index_path, index)
report = prepare.call
%w[en-US ja].each do |locale|
  fields = %w[description promotionalText]
  fields += %w[name subtitle releaseNotes] if locale == 'en-US'
  fields.each do |field|
    row = report.fetch('fields').find { |item| item['fieldId'] == field && item['locale'] == locale }
    check(row['state'] == 'confirmed', "real preparation confirmation #{locale} #{field}: #{row['reasons']}")
  end
end

case_ids = %w[iphone-en iphone-ja ipad-en ipad-ja]
verification = {'bundleIdentifier'=>'com.example.garden','unitTestIdentifier'=>'GardenNotesTests/GardenNotesTests/testMetadata()',
  'cases'=>case_ids.map { |id| {'id'=>id,'testIdentifier'=>'GardenNotesUITests/GardenNotesUITests/testMetadata'} },
  'acceptanceMappings'=>[{'id'=>'AC-1','checks'=>['stage:build','stage:unit-tests']+case_ids.map { |id| "case:#{id}" }+case_ids.map { |id| "visual:#{id}" }}]}
operations = [
  ['github.read_issue', 'GitHub'],
  ['github.update_issue', 'GitHub'],
  ['github.push_branch', 'GitHub'],
  ['github.create_pr', 'GitHub'],
  ['github.merge_pr', 'GitHub'],
  ['appstore.update_metadata', 'App Store Connect']
]
operation_blocks = operations.map do |operation, service|
  "- Operation: #{operation}\n- Service: #{service}\n- Environment: production\n- Executor: Codex\n- Approval required: no"
end.join("\n\n")
# A live App Store operation requires release/full/strict in the contract parser.
# This synthetic Issue is separate from the workflow-only implementation Issue.
issue_body = <<~ISSUE
  ## Goal

  Exercise selective metadata save against a synthetic App Store Issue.

  ## In scope

  - Guarded localization save with fake remote state.

  ## Out of scope

  - Live App Store Connect changes.

  ## Acceptance criteria

  - AC-1: UI-direction route: not-applicable; Scope: synthetic metadata save; Reason: no app UI change

  ## Spec anchors

  - [App Store acceptance](specs/acceptance.md#8)

  ## Dependencies

  - None.

  ## UI verification

  - Not applicable.

  ## Delivery stage

  - Stage: release
  - Time budget: 240 minutes
  - Reason: Exercise the contract for a simulated App Store mutation.

  ## Delivery profile

  - Profile: strict
  - Reason: App Store metadata updates are high-risk external operations.

  ## Verification scope

  - Scope: full
  - Reason: App Store operations require the full scope in the Issue contract.

  ## Verification

  #{JSON.generate(verification)}

  ## External operations

  #{operation_blocks}

  ## User approvals

  - No additional approval.
ISSUE
body_path = File.join(scratch, 'issue-body.md')
File.binwrite(body_path, issue_body)
contract_output, contract_error, contract_status = Open3.capture3('/usr/bin/ruby', '--disable-gems',
  File.join(root, 'tools/lib/issue-contract.rb'), '--body', body_path, '--type', 'release', '--format', 'contract',
  '--issue', '42', '--repo', 'yuto1201/iOS-Template', '--fetched-at', '2026-09-24T00:00:00Z')
check(contract_status.success?, "synthetic Issue contract parses: #{contract_error}")
contract = JSON.parse(contract_output)
check(contract['issue'] == 42 && contract['repository'] == 'yuto1201/iOS-Template' &&
  contract['externalOperations'].include?('github.read_issue') &&
  contract['externalOperations'].include?('appstore.update_metadata'), 'synthetic Issue contract authority')
contract_path = '.artifacts/issues/42/issue-contract.json'
write(project, contract_path, contract_output)
write(project, '.artifacts/issues/42/state.json', {'issue'=>42,'state'=>'in-progress','executor'=>'codex','issueContract'=>{'path'=>contract_path,'digest'=>"sha256:#{Digest::SHA256.file(File.join(project,contract_path)).hexdigest}"}})
preflight_path = '.artifacts/issues/42/provider-preflights/app-store-update_metadata.json'
preflight = {'schemaVersion'=>2,'issue'=>42,'executor'=>'codex','provider'=>'app-store','account'=>'TEAM123456','target'=>'com.example.garden','environment'=>'production','operation'=>'appstore.update_metadata','health'=>'healthy','checkedAt'=>Time.now.utc.iso8601}
preflight['digest'] = digest(preflight)
write(project, preflight_path, preflight)

state_path = File.join(scratch, 'remote.json')
initial_forms = %w[en-US ja].to_h do |locale|
  [locale, {'description'=>"Old #{locale} text",'keywords'=>'garden,notes','promotionalText'=>'Old promotion','whatsNew'=>'Old release notes','supportUrl'=>'https://example.com/support','marketingUrl'=>nil}]
end
initial_app_info = {'en-US'=>{'name'=>'Old Garden Name','subtitle'=>'Old subtitle','privacyPolicyUrl'=>'https://example.com/privacy','privacyChoicesUrl'=>nil,'privacyPolicyText'=>nil}}
reset_remote = lambda do |scenario='normal'|
  File.binwrite(state_path, JSON.generate({'versionStatus'=>'PREPARE_FOR_SUBMISSION','forms'=>Marshal.load(Marshal.dump(initial_forms)),'appInfo'=>Marshal.load(Marshal.dump(initial_app_info)),'scenario'=>scenario,'calls'=>[],'listCounts'=>{}}))
end
reset_remote.call
fake_runner = File.join(scratch, 'fake-asc-runner')
File.binwrite(fake_runner, <<~'FAKE'.gsub('__STATE_PATH__', state_path.dump))
  #!/usr/bin/ruby
  require 'json'
  state_path = __STATE_PATH__
  state = JSON.parse(File.binread(state_path))
  args = ARGV.drop(ARGV.index('--') + 1)
  command = args.shift(2)
  options = {}
  until args.empty?
    item = args.shift
    if item.include?('=')
      flag, value = item.split('=',2)
      options[flag] = value
    elsif item == '--paginate'
      options[item] = true
    else
      options[item] = args.shift
    end
  end
  state['calls'] << [command, options.keys]
  result = case command
  when ['bundle-ids','list'] then {'data'=>[{'type'=>'bundleIds','id'=>'B1','attributes'=>{'identifier'=>'com.example.garden','seedId'=>'TEAM123456'}}]}
  when ['apps','list'] then {'data'=>[{'type'=>'apps','id'=>'1234567890','attributes'=>{'bundleId'=>'com.example.garden'}}]}
  when ['versions','list'] then {'data'=>[{'type'=>'appStoreVersions','id'=>'V1','attributes'=>{'versionString'=>'1.0','platform'=>'IOS','appStoreState'=>state['versionStatus']}}]}
  when ['localizations','list']
    locale = options.fetch('--locale')
    state['listCounts'][locale] = state['listCounts'].fetch(locale,0) + 1
    if state['scenario'] == 'drift-before-save' && locale == 'en-US' && state['listCounts'][locale] == 2
      state.fetch('forms').fetch(locale)['keywords'] = 'another,editor'
    end
    if options['--type'] == 'app-info'
      {'data'=>[{'type'=>'appInfoLocalizations','id'=>"APPLOC-#{locale}",'attributes'=>state.fetch('appInfo').fetch(locale).merge('locale'=>locale)}]}
    else
      {'data'=>[{'type'=>'appStoreVersionLocalizations','id'=>"LOC-#{locale}",'attributes'=>state.fetch('forms').fetch(locale).merge('locale'=>locale)}]}
    end
  when ['localizations','update']
    locale = options.fetch('--locale')
    if state['scenario'] == 'fail-en' && locale == 'en-US'
      File.binwrite(state_path, JSON.generate(state))
      puts JSON.generate({'errors'=>[{'status'=>'422'}]})
      exit 17
    end
    if options['--type'] == 'app-info'
      {'--name'=>'name','--subtitle'=>'subtitle'}.each do |flag, field|
        state.fetch('appInfo').fetch(locale)[field] = options.fetch(flag) if options.key?(flag)
      end
      state.fetch('appInfo').fetch(locale)['privacyPolicyUrl'] = 'https://example.com/changed' if state['scenario'] == 'change-unselected'
    else
      {'--description'=>'description','--keywords'=>'keywords','--promotional-text'=>'promotionalText','--whats-new'=>'whatsNew'}.each do |flag, field|
        state.fetch('forms').fetch(locale)[field] = options.fetch(flag) if options.key?(flag)
      end
      state.fetch('forms').fetch(locale)['supportUrl'] = 'https://example.com/changed' if state['scenario'] == 'change-unselected'
    end
    if state['scenario'] == 'ambiguous-en' && locale == 'en-US'
      File.binwrite(state_path, JSON.generate(state))
      exit 124
    end
    {'data'=>{'type'=>options['--type'] == 'app-info' ? 'appInfoLocalizations' : 'appStoreVersionLocalizations','id'=>options['--type'] == 'app-info' ? "APPLOC-#{locale}" : "LOC-#{locale}"}}
  else
    exit 70
  end
  File.binwrite(state_path, JSON.generate(state))
  puts JSON.generate(result)
FAKE
File.chmod(0700, fake_runner)

form = lambda do |locale, section='version-localization'|
  app_info = section == 'app-info-localization'
  reference = app_info ? "asc://apps/1234567890/appInfoLocalizations/APPLOC-#{locale}" : "asc://apps/1234567890/appStoreVersionLocalizations/LOC-#{locale}"
  values = app_info ? initial_app_info.fetch(locale) : initial_forms.fetch(locale)
  {'section'=>section,'locale'=>locale,'remoteReference'=>reference,
   'baselineDigest'=>digest({'section'=>section,'locale'=>locale,'remoteReference'=>reference,'values'=>values})}
end
selected = lambda do |locale, field='description'|
  source_field = field == 'whatsNew' ? 'releaseNotes' : field
  row = report.fetch('fields').find { |item| item['fieldId'] == source_field && item['locale'] == locale }
  source_path = field == 'whatsNew' ? "App Store/release-notes/#{locale}.md" : "App Store/metadata/localizations/#{locale}.yml"
  source = row.fetch('sources').find { |item| item['path'] == source_path }
  {'fieldId'=>field,'locale'=>locale,'source'=>source.slice('path','anchor','digest')}
end
request = {'schemaVersion'=>1,'recordType'=>'appstore-metadata-save-request','issue'=>42,'executor'=>'codex','identity'=>{'teamId'=>'TEAM123456','bundleId'=>'com.example.garden','appId'=>'1234567890','platform'=>'IOS','version'=>'1.0'},'sourceRevision'=>source_revision,'requirements'=>{'checkedAt'=>Time.now.utc.iso8601,'sources'=>['https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/','https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/','https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties/']},'publicationImpactApprovalReference'=>nil,'forms'=>[form.call('en-US'),form.call('ja')],'selectedFields'=>[selected.call('en-US'),selected.call('ja')]}
request_path = '.artifacts/appstore-metadata/requests/fixture.json'
write(project, request_path, request)
release_path = File.join(project, 'App Store/submission/1.0-result.json')
FileUtils.mkdir_p(File.dirname(release_path))
File.binwrite(release_path, 'PRESERVE-RELEASE-RESULT')

invoke = lambda do |document=request, scenario: 'normal', expected: 0, resume: nil|
  if resume
    state = JSON.parse(File.binread(state_path)); state['calls'] = []; File.binwrite(state_path,JSON.generate(state))
  else
    reset_remote.call(scenario)
  end
  write(project, request_path, document)
  env = {'IOS_TEMPLATE_TEST_MODE'=>'1','IOS_TEMPLATE_TEST_ASC_RUNNER'=>fake_runner}
  arguments = ['--project-root',project,'--request',request_path]
  arguments += ['--resume-attempt',resume] if resume
  output, error, status = Open3.capture3(env, entry, *arguments)
  check(status.exitstatus == expected, "save exit #{status.exitstatus} expected #{expected}: #{error}")
  check(!output.include?('A confirmed garden journal') && !error.include?('A confirmed garden journal'), 'output contains source value')
  check(File.binread(release_path) == 'PRESERVE-RELEASE-RESULT', 'release result changed')
  [JSON.parse(output), JSON.parse(File.binread(state_path))]
end
events = lambda do |attempt|
  Dir.glob(File.join(project, '.artifacts/appstore-metadata/42', attempt, '*.json')).sort.map { |path| JSON.parse(File.binread(path)) }
end
result, remote = invoke.call
check(result['status'] == 'remote-saved' && remote['forms']['ja']['description'] == '確認済みの庭日記です。', 'successful save and readback')
check(result['outcomes'].map { |entry| [entry['locale'],entry['outcome']] } == [['en-US','remote-saved'],['ja','remote-saved']], 'per-locale result')
check(events.call(result.fetch('attempt')).any? { |event| event['eventType'] == 'outcome' && event['outcome'] == 'remote-saved' }, 'saved outcome missing')
Dir.glob(File.join(project, '.artifacts/appstore-metadata/42', result.fetch('attempt'), '*.json')).each do |path|
  bytes = File.binread(path)
  check(!bytes.include?('確認済みの庭日記') && !bytes.include?('A confirmed garden journal'), 'journal has field value')
end

bad = Marshal.load(Marshal.dump(request)); bad['selectedFields'][0]['fieldId'] = 'supportURL'
_, remote = invoke.call(bad, expected: 1)
check(remote['calls'].none? { |call| call[0] == ['localizations','update'] }, 'scope outside field wrote')
bad = Marshal.load(Marshal.dump(request)); bad['identity']['appId'] = '9999999999'
_, remote = invoke.call(bad, expected: 1)
check(remote['calls'].empty?, 'identity mismatch called runner')
unconfirmed = JSON.parse(File.binread(File.join(project,index_path)))
unconfirmed['records'].reject! { |item| item['fieldId'] == 'description' && item['locale'] == 'en-US' }
write(project,index_path,unconfirmed)
_, remote = invoke.call(request, expected: 1)
check(remote['calls'].empty?, 'unconfirmed field called runner')
write(project,index_path,index)

preflight_original = File.binread(File.join(project,preflight_path))
File.unlink(File.join(project,preflight_path))
_, remote = invoke.call(request, expected: 1)
check(remote['calls'].empty?, 'missing preflight called runner')
File.binwrite(File.join(project,preflight_path),preflight_original)
%w[old operation].each do |kind|
  changed = JSON.parse(preflight_original)
  changed[kind == 'old' ? 'checkedAt' : 'operation'] = kind == 'old' ? (Time.now.utc-7200).iso8601 : 'appstore.inspect_app'
  changed['digest'] = digest(changed.reject { |key,_| key == 'digest' })
  write(project,preflight_path,changed)
  _, remote = invoke.call(request, expected: 1)
  check(remote['calls'].empty?, "#{kind} preflight called runner")
end
File.binwrite(File.join(project,preflight_path),preflight_original)

result, remote = invoke.call(request, scenario: 'fail-en', expected: 1)
check(result['status'] == 'partial' && remote['forms']['ja']['description'] == '確認済みの庭日記です。' && remote['forms']['en-US']['description'] == 'Old en-US text', 'partial save')
result, remote = invoke.call(request, scenario: 'ambiguous-en', expected: 1)
check(result['status'] == 'partial' && events.call(result.fetch('attempt')).any? { |e| e['outcome'] == 'unknown' }, 'ambiguous outcome')
prior = result.fetch('attempt')
result, remote = invoke.call(request, resume: prior)
check(result['previousAttempt'] == prior && remote['calls'].none? { |call| call[0] == ['localizations','update'] && call[1].include?('--description') }, 'ambiguous resume retried blindly')

result, remote = invoke.call(request, scenario: 'change-unselected', expected: 1)
check(events.call(result.fetch('attempt')).any? { |e| e['reason'] == 'readback-mismatch' }, 'unselected drift accepted')
app_info_request = Marshal.load(Marshal.dump(request))
app_info_request['forms'] = [form.call('en-US','app-info-localization')]
app_info_request['selectedFields'] = [selected.call('en-US','name'), selected.call('en-US','subtitle')]
result, remote = invoke.call(app_info_request)
check(result['status'] == 'remote-saved' && remote['appInfo']['en-US']['name'] == 'Garden Notes' &&
  remote['appInfo']['en-US']['subtitle'] == 'A garden journal' && remote['appInfo']['en-US']['privacyPolicyUrl'] == 'https://example.com/privacy', 'app-info localization preservation')
result, remote = invoke.call(app_info_request, scenario: 'change-unselected', expected: 1)
check(events.call(result.fetch('attempt')).any? { |e| e['reason'] == 'readback-mismatch' }, 'app-info unselected drift accepted')
news_request = Marshal.load(Marshal.dump(request)); news_request['forms'] = [form.call('en-US')]; news_request['selectedFields'] = [selected.call('en-US','whatsNew')]
result, remote = invoke.call(news_request)
check(remote['forms']['en-US']['whatsNew'] == "New garden journal notes.\n" && result['status'] == 'remote-saved', 'whatsNew source mapping')
promo_request = Marshal.load(Marshal.dump(request)); promo_request['forms'] = [form.call('ja')]; promo_request['selectedFields'] = [selected.call('ja','promotionalText')]
promo_request['publicationImpactApprovalReference'] = 'approval: user-approval://synthetic-public-message'
result, remote = invoke.call(promo_request)
check(result['status'] == 'remote-saved' && remote['forms']['ja']['promotionalText'] == '確認済みのお知らせ。' &&
  events.call(result.fetch('attempt')).any? { |e| e['fields'].any? { |f| f['publicEffect'] == 'immediate-publication' } }, 'promotional text approval and effect')
bad = Marshal.load(Marshal.dump(request)); bad['forms'] = [bad['forms'][0]]; bad['selectedFields'] = [bad['selectedFields'][0]]; bad['forms'][0]['baselineDigest'] = 'sha256:' + '0' * 64
_, remote = invoke.call(bad, expected: 1)
check(remote['calls'].none? { |call| call[0] == ['localizations','update'] }, 'baseline drift wrote')
single = Marshal.load(Marshal.dump(request)); single['forms'] = [form.call('en-US')]; single['selectedFields'] = [selected.call('en-US')]
_, remote = invoke.call(single, scenario: 'drift-before-save', expected: 1)
check(remote['calls'].none? { |call| call[0] == ['localizations','update'] }, 'pre-dispatch baseline drift wrote')
bad = Marshal.load(Marshal.dump(request)); bad['selectedFields'] = [selected.call('ja','promotionalText')]; bad['forms'] = [form.call('ja')]
_, remote = invoke.call(bad, expected: 1)
check(remote['calls'].empty?, 'promotional text without approval called runner')
result, remote = invoke.call(request)
prior = result.fetch('attempt')
state = JSON.parse(File.binread(state_path)); state['forms']['en-US']['description'] = 'A different editor changed this.'; File.binwrite(state_path,JSON.generate(state))
result, remote = invoke.call(request, resume: prior, expected: 1)
check(events.call(result.fetch('attempt')).any? { |e| e['reason'] == 'resume-remote-drift' } &&
  remote['calls'].none? { |call| call[0] == ['localizations','update'] }, 'resume remote drift wrote')
result, remote = invoke.call(single)
prior = result.fetch('attempt')
state = JSON.parse(File.binread(state_path)); state['calls'] = []; File.binwrite(state_path,JSON.generate(state))
write(project,request_path,single)
File.open(File.join(project,request_path),'a') { |file| file.write("\n") }
output,error,status = Open3.capture3({'IOS_TEMPLATE_TEST_MODE'=>'1','IOS_TEMPLATE_TEST_ASC_RUNNER'=>fake_runner},entry,'--project-root',project,'--request',request_path,'--resume-attempt',prior)
check(status.exitstatus == 1 && JSON.parse(File.binread(state_path))['calls'].empty?, 'changed request bytes resumed')
write(project,request_path,single)
event_path = Dir.glob(File.join(project,'.artifacts/appstore-metadata/42',prior,'*.json')).sort.first
event_before = File.binread(event_path)
File.binwrite(event_path,event_before+"\n")
state = JSON.parse(File.binread(state_path)); state['calls'] = []; File.binwrite(state_path,JSON.generate(state))
output,error,status = Open3.capture3({'IOS_TEMPLATE_TEST_MODE'=>'1','IOS_TEMPLATE_TEST_ASC_RUNNER'=>fake_runner},entry,'--project-root',project,'--request',request_path,'--resume-attempt',prior)
check(status.exitstatus == 1 && JSON.parse(File.binread(state_path))['calls'].empty?, 'changed journal bytes resumed')
File.binwrite(event_path,event_before)
source_path = File.join(project,'App Store/metadata/localizations/en-US.yml')
source_before = File.binread(source_path)
File.binwrite(source_path, source_before.sub('A confirmed garden journal description.','Changed copy.'))
_, remote = invoke.call(single, expected: 1)
check(remote['calls'].empty?, 'changed source called runner')
File.binwrite(source_path,source_before)
contract_before = File.binread(File.join(project,contract_path))
state_before = File.binread(File.join(project,'.artifacts/issues/42/state.json'))
changed_contract = JSON.parse(contract_before); changed_contract['externalOperations'].delete('appstore.update_metadata')
write(project,contract_path,changed_contract)
changed_state = JSON.parse(state_before); changed_state['issueContract']['digest'] = "sha256:#{Digest::SHA256.file(File.join(project,contract_path)).hexdigest}"
write(project,'.artifacts/issues/42/state.json',changed_state)
_, remote = invoke.call(single, expected: 1)
check(remote['calls'].empty?, 'undeclared operation called runner')
File.binwrite(File.join(project,contract_path),contract_before)
File.binwrite(File.join(project,'.artifacts/issues/42/state.json'),state_before)
reset_remote.call
write(project,request_path,single)
output,error,status = Open3.capture3({'IOS_TEMPLATE_TEST_ASC_RUNNER'=>fake_runner},entry,'--project-root',project,'--request',request_path)
check(status.exitstatus == 1 && JSON.parse(File.binread(state_path))['calls'].empty?, 'production accepted fake runner')
reset_remote.call
state = JSON.parse(File.binread(state_path)); state['versionStatus'] = 'READY_FOR_SALE'; File.binwrite(state_path,JSON.generate(state))
write(project,request_path,request)
output,error,status = Open3.capture3({'IOS_TEMPLATE_TEST_MODE'=>'1','IOS_TEMPLATE_TEST_ASC_RUNNER'=>fake_runner},entry,'--project-root',project,'--request',request_path)
check(status.exitstatus == 1 && JSON.parse(File.binread(state_path))['calls'].none? { |call| call[0] == ['localizations','update'] }, 'uneditable version wrote')

puts 'PASS: selective save real preparation, fake asc, journal and resume cases'
RUBY
