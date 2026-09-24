#!/bin/bash
set -euo pipefail
source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg ruby git jq swift swiftc /usr/bin/xcrun

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-release-sections.XXXXXX")
workspace=$(cd "$workspace" && pwd -P)
trap 'rm -rf -- "$workspace"' EXIT
project="$workspace/project"
mkdir -p "$project"
proof=$("$repo_root/tools/tests/test-ios-evidence.sh" --export-fixture "$project" full | tail -n 1)

REPO_ROOT="$repo_root" WORKSPACE="$workspace" PROJECT="$project" PROOF="$proof" ruby <<'RUBY'
# encoding: utf-8
require 'json'
require 'yaml'
require 'digest'
require 'base64'
require 'fileutils'
require 'open3'
require 'time'

root,scratch,project = ENV.values_at('REPO_ROOT','WORKSPACE','PROJECT')
proof = JSON.parse(ENV.fetch('PROOF'))
head,base = proof.values_at('head','base')
bundle,team,app_id,version,build_id,build_number = 'com.example.TemplateApp','TEAM123456','1234567890','1.0','BUILD123','7'
build_digest = 'sha256:' + 'b' * 64
now = Time.now.utc.iso8601
secret = 'private-demo-password-sentinel'

def check(ok, label)
  raise "assertion failed: #{label}" unless ok
end
def canon(x)
  x.is_a?(Hash) ? x.keys.sort.to_h { |k| [k,canon(x[k])] } : x.is_a?(Array) ? x.map { |v| canon(v) } : x
end
def dig(x)
  "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canon(x)))}"
end
def put(root, relative, value)
  path = File.join(root,relative)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path,value.is_a?(String) ? value : relative.end_with?('.yml') ? YAML.dump(value) : JSON.generate(value))
  path
end
def tree_digest(root)
  entries=[]
  Dir.glob(File.join(root,'**','*'),File::FNM_DOTMATCH).sort.each do |path|
    next unless File.file?(path) && !File.symlink?(path)
    relative=path.delete_prefix(root+'/')
    next if relative.match?(%r{\Asubmission/[0-9]+(?:\.[0-9]+){1,2}-(?:package|result)\.json\z})
    entries << "#{relative}\0#{Digest::SHA256.file(path).hexdigest}\0"
  end
  "sha256:#{Digest::SHA256.hexdigest(entries.join)}"
end

ownership = YAML.safe_load(File.binread(File.join(root,'Config/ownership.yml')),permitted_classes: [],aliases: false)
ownership['appStore']={'teamId'=>team,'bundleId'=>bundle}
put(project,'Config/ownership.yml',ownership)
package=File.join(project,'App Store')
put(package,'metadata/app.yml',{'schemaVersion'=>1,'bundleId'=>bundle,'version'=>version,'primaryLocale'=>'en-US',
  'platforms'=>{'iphone'=>true,'ipad'=>true},'category'=>'Utilities','copyright'=>'2026 Garden Notes',
  'supportURL'=>'https://example.com/support','privacyPolicyURL'=>'https://example.com/privacy',
  'reviewContactReference'=>'none','accountsSupported'=>false})
%w[en-US ja].each do |locale|
  english=locale=='en-US'
  put(package,"metadata/localizations/#{locale}.yml",{'name'=>english ? 'Garden Notes' : '庭ノート',
    'subtitle'=>english ? 'A garden journal' : '庭を記録',
    'description'=>english ? 'A confirmed garden journal.' : '確認済みの庭日記です。',
    'keywords'=>english ? 'garden,journal' : '庭,日記',
    'promotionalText'=>english ? 'Grow your garden.' : '庭を育てよう。'})
  put(package,"release-notes/#{locale}.md",english ? "New garden notes.\n" : "新しい庭ノート。\n")
end
put(package,'privacy/data-use.yml',{'schemaVersion'=>1,'collectsData'=>false,'tracking'=>false,'dataTypes'=>[],
  'thirdPartySDKs'=>[],'permissions'=>[],'accountDeletion'=>{'required'=>false,'reason'=>'No accounts.'}})
put(package,'review/review-notes.md',"No account is required.\n")
requirements=put(package,'submission/requirements.json',{'schemaVersion'=>1,'fixture'=>'release-sections'})
requirements_digest="sha256:#{Digest::SHA256.file(requirements).hexdigest}"
png=Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
cases=[]
%w[en-US ja].each do |locale|
  %w[iphone-6.9 ipad-13].each do |family|
    relative="#{locale}/#{family}/01-primary.png"
    path=put(package,"screenshots/#{relative}",png+"#{locale}:#{family}")
    cases << {'locale'=>locale,'family'=>family,'state'=>'primary','order'=>1,'path'=>relative,
      'digest'=>"sha256:#{Digest::SHA256.file(path).hexdigest}"}
  end
end
shots=put(package,'screenshots/manifest.json',{'schemaVersion'=>1,'sourceSha'=>head,
  'buildDigest'=>build_digest,'requirementsDigest'=>requirements_digest,'cases'=>cases})
verification={'issue'=>42,'baseSha'=>base,'path'=>".artifacts/issues/42/#{head}/verify.json",
  'digest'=>"sha256:#{Digest::SHA256.file(File.join(project,'.artifacts','issues','42',head,'verify.json')).hexdigest}"}
package_tree=tree_digest(package)
audit=put(scratch,'audit.json',{'schemaVersion'=>1,'status'=>'approved','role'=>'release-auditor',
  'sourceSha'=>head,'buildDigest'=>build_digest,'packageDigest'=>package_tree,'findings'=>[]})
put(package,"submission/#{version}-package.json",{'schemaVersion'=>2,'status'=>'prepared','bundleId'=>bundle,
  'version'=>version,'sourceSha'=>head,'verification'=>verification,'buildDigest'=>build_digest,
  'requirementsDigest'=>requirements_digest,'screenshotManifestDigest'=>"sha256:#{Digest::SHA256.file(shots).hexdigest}",
  'packageDigest'=>package_tree,'auditDigest'=>"sha256:#{Digest::SHA256.file(audit).hexdigest}",
  'firstPublication'=>false,'legalApprovalDigest'=>nil,'preparedAt'=>now})
require File.join(root,'tools/lib/release-verification')
IOSTemplate::ReleaseVerification.with_full_proof(repo: project,issue: 42,base: base,head: head,bundle: bundle,
  expected_reference: verification,artifact_digest: build_digest,publish: ->(_value) {}) { nil }

ids=%w[iphone-en iphone-ja ipad-en ipad-ja]
verification_contract={'bundleIdentifier'=>bundle,'unitTestIdentifier'=>'GardenTests/GardenTests/testRelease()',
  'cases'=>ids.map { |id| {'id'=>id,'testIdentifier'=>'GardenUITests/GardenUITests/testRelease'} },
  'acceptanceMappings'=>[{'id'=>'AC-1','checks'=>['stage:build','stage:unit-tests']+ids.map { |id| "case:#{id}" }+ids.map { |id| "visual:#{id}" }}]}
ops=[['github.read_issue','GitHub'],['appstore.inspect_app','App Store Connect'],
     ['appstore.update_metadata','App Store Connect'],['appstore.submit_review','App Store Connect']]
blocks=ops.map { |op,service| "- Operation: #{op}\n- Service: #{service}\n- Environment: production\n- Executor: Codex\n- Approval required: #{op=='appstore.submit_review' ? 'yes' : 'no'}" }.join("\n\n")
body=<<~ISSUE
  ## Goal

  Synthetic complete App Store release.

  ## In scope

  - Exact sealed section readback.

  ## Out of scope

  - Real Apple operations.

  ## Acceptance criteria

  - AC-1: UI-direction route: not-applicable; Scope: synthetic release tooling; Reason: no app UI change

  ## Spec anchors

  - [App Store adapter](specs/architecture.md#72-app-store-connect-api-adapter)

  ## Dependencies

  - Release-unit status: intentionally independent and unbound workflow infrastructure.

  ## UI verification

  Not applicable

  ## Delivery stage

  - Stage: release
  - Time budget: 240 minutes
  - Reason: Synthetic release section transaction.

  ## Delivery profile

  - Profile: strict
  - Reason: Submission is sensitive.

  ## Verification scope

  - Scope: full
  - Reason: Synthetic live-operation contract.

  ## Verification

  #{JSON.generate(verification_contract)}

  ## External operations

  #{blocks}

  ## User approvals

  - approval: user-approval://synthetic-release
ISSUE
body_path=put(scratch,'issue-body.md',body)
contract_output,contract_error,contract_status=Open3.capture3('/usr/bin/ruby','--disable-gems',
  File.join(root,'tools/lib/issue-contract.rb'),'--body',body_path,'--type','release','--format','contract',
  '--issue','77','--repo','example/release-fixture','--fetched-at',now)
check(contract_status.success?,"synthetic contract: #{contract_error}")
contract=JSON.parse(contract_output)
contract_path=put(project,'.artifacts/issues/77/issue-contract.json',contract)
put(project,'.artifacts/issues/77/state.json',{'issue'=>77,'state'=>'in-progress','executor'=>'codex',
  'issueContract'=>{'path'=>'.artifacts/issues/77/issue-contract.json',
                   'digest'=>"sha256:#{Digest::SHA256.file(contract_path).hexdigest}"}})
ops.drop(1).each do |op,_|
  value={'schemaVersion'=>2,'issue'=>77,'executor'=>'codex','provider'=>'app-store','account'=>team,
    'target'=>bundle,'environment'=>'production','operation'=>op,'health'=>'healthy','checkedAt'=>now}
  value['digest']=dig(value)
  put(project,".artifacts/issues/77/provider-preflights/app-store-#{op.delete_prefix('appstore.')}.json",value)
end

journal=File.join(project,'.artifacts/appstore-builds/77/a123456789012345678901234')
previous=nil
[['started',{'teamId'=>team,'preflightDigest'=>dig('preflight')}],
 ['export-complete',{'ipaName'=>'GardenNotes.ipa','ipaDigest'=>dig('ipa')}],
 ['upload-intent',{'ipaDigest'=>dig('ipa')}],
 ['upload-result',{'status'=>'accepted','ipaDigest'=>dig('ipa'),'uploadId'=>'UPLOAD1','fileId'=>'FILE1'}],
 ['processing-readback',{'buildId'=>build_id,'platform'=>'IOS','processingState'=>'VALID','ipaDigest'=>dig('ipa')}]
].each_with_index do |(type,extra),index|
  event={'schemaVersion'=>1,'recordType'=>'appstore-build-upload','eventType'=>type,'eventSequence'=>index+1,
    'previousEventDigest'=>previous,'issue'=>77,'attempt'=>File.basename(journal),'headSha'=>head,
    'version'=>version,'buildNumber'=>build_number,'bundleId'=>bundle,'contractDigest'=>dig(contract),'checkedAt'=>now}.merge(extra)
  path=put(journal,format('%04d-%s.json',index+1,type),JSON.generate(canon(event))+"\n")
  previous="sha256:#{Digest::SHA256.file(path).hexdigest}"
end

fake=put(scratch,'fake-asc',<<~'FAKE')
  #!/usr/bin/env ruby
  require 'json'
  require 'digest'
  require 'time'
  state_path=ENV.fetch('FAKE_ASC_STATE')
  state=JSON.parse(File.binread(state_path))
  args=ARGV.dup
  abort 'operation absent' unless args.shift=='--operation'
  operation=args.shift
  abort 'separator absent' unless args.shift=='--'
  command=args[0,3]==%w[apps info view] ? args.shift(3).join(' ') : args.shift(2).join(' ')
  flags={}
  until args.empty?
    key,value=args.shift.split('=',2)
    flags[key]=value || (args.empty? || args.first.start_with?('--') ? true : args.shift)
  end
  state['calls'] << "#{operation}:#{command}"
  result=case command
  when 'bundle-ids list'
    {'data'=>[{'type'=>'bundleIds','id'=>'BUNDLE1','attributes'=>{'identifier'=>state['bundle'],
      'seedId'=>state['scenario']=='identity-team' ? 'OTHERTEAM' : state['team']}}]}
  when 'apps list'
    {'data'=>[{'type'=>'apps','id'=>state['appId'],'attributes'=>{'bundleId'=>state['bundle'],'primaryLocale'=>'en-US'}}]}
  when 'versions list'
    attached=state['attached'] && {'type'=>'builds','id'=>state['scenario']=='build-readback' ? 'OTHERBUILD' : state['buildId']}
    {'data'=>[{'type'=>'appStoreVersions','id'=>'VERSION1','attributes'=>{'versionString'=>state['version'],
      'platform'=>'IOS','appStoreState'=>'PREPARE_FOR_SUBMISSION','copyright'=>state['copyright']},
      'relationships'=>{'build'=>{'data'=>attached}}}]}
  when 'builds list'
    {'data'=>[{'type'=>'builds','id'=>state['buildId'],'attributes'=>{'version'=>state['buildNumber']}}]}
  when 'builds info'
    {'data'=>{'type'=>'builds','id'=>state['buildId'],'attributes'=>{'version'=>state['buildNumber'],
      'processingState'=>'VALID'},'relationships'=>{'preReleaseVersion'=>{'data'=>{'type'=>'preReleaseVersions','id'=>'PR1'}}}},
      'included'=>[{'type'=>'preReleaseVersions','id'=>'PR1','attributes'=>{'version'=>state['version'],'platform'=>'IOS'}}]}
  when 'categories list'
    {'data'=>[{'type'=>'appCategories','id'=>'UTILITIES','attributes'=>{'name'=>'Utilities'}}],'links'=>{}}
  when 'categories set'
    state['category']=flags.fetch('--primary')
    {'data'=>{'type'=>'appInfos','id'=>'INFO1'}}
  when 'apps info view'
    category=state['scenario']=='app-information-readback' && state['category'] ? 'OTHER' : state['category']
    {'data'=>{'type'=>'appInfos','id'=>'INFO1','attributes'=>{},
      'relationships'=>{'primaryCategory'=>{'data'=>category && {'type'=>'appCategories','id'=>category}}}}}
  when 'versions update'
    state['copyright']=flags.fetch('--copyright')
    {'data'=>{'type'=>'appStoreVersions','id'=>'VERSION1'}}
  when 'localizations list'
    locale=flags.fetch('--locale'); type=flags.fetch('--type')
    attributes=state.fetch('forms').fetch("#{type}:#{locale}").dup
    attributes['description']='Unexpected remote description' if state['scenario']=='localization-readback' && state['localizationMutated'] && type=='version'
    {'data'=>[{'type'=>type=='version' ? 'appStoreVersionLocalizations' : 'appInfoLocalizations',
      'id'=>"LOC_#{type=='version' ? 'V' : 'A'}_#{locale=='en-US' ? 'EN' : 'JA'}",'attributes'=>attributes}]}
  when 'localizations update'
    type=flags.fetch('--type'); locale=flags.fetch('--locale')
    {'--name'=>'name','--subtitle'=>'subtitle','--description'=>'description','--keywords'=>'keywords',
     '--promotional-text'=>'promotionalText','--whats-new'=>'whatsNew','--support-url'=>'supportUrl',
     '--privacy-policy-url'=>'privacyPolicyUrl'}.each do |flag,field|
      state['forms']["#{type}:#{locale}"][field]=flags[flag] if flags.key?(flag)
    end
    state['localizationMutated']=true
    {'data'=>{'type'=>'localizations','id'=>'LOC1'}}
  when 'screenshots list'
    loc=flags.fetch('--version-localization'); locale=loc.end_with?('_EN') ? 'en-US' : 'ja'
    sets=state['shots'][locale].map do |type,shots|
      {'set'=>{'type'=>'appScreenshotSets','id'=>"SET_#{locale=='en-US' ? 'EN' : 'JA'}_#{type}",
        'attributes'=>{'screenshotDisplayType'=>type}},
       'screenshots'=>shots.map do |shot|
         item=Marshal.load(Marshal.dump(shot))
         item['attributes']['sourceFileChecksum']='0'*32 if state['scenario']=='screenshots-readback'
         item
       end}
    end
    {'versionLocalizationId'=>loc,'sets'=>sets}
  when 'screenshots upload'
    loc=flags.fetch('--version-localization'); locale=loc.end_with?('_EN') ? 'en-US' : 'ja'
    type=flags.fetch('--device-type'); path=flags.fetch('--path')
    shots=state['shots'][locale][type] ||= []
    shots << {'type'=>'appScreenshots','id'=>"SHOT#{state['calls'].length}",
      'attributes'=>{'fileName'=>File.basename(path),'fileSize'=>File.size(path),
        'sourceFileChecksum'=>Digest::MD5.file(path).hexdigest,'assetDeliveryState'=>{'state'=>'COMPLETE'}}}
    {'versionLocalizationId'=>loc,'setId'=>"SET_#{type}",'displayType'=>type,
      'results'=>[{'fileName'=>File.basename(path)}]}
  when 'versions attach-build'
    state['attached']=true
    {'data'=>{'type'=>'appStoreVersions','id'=>'VERSION1'}}
  when 'review status'
    latest=state['submitted'] && {'id'=>'SUBMISSION1',
      'state'=>state['scenario']=='submission-readback' ? 'UNKNOWN' : 'WAITING_FOR_REVIEW'}
    {'appId'=>state['appId'],'version'=>{'id'=>'VERSION1','version'=>state['version'],'platform'=>'IOS',
      'state'=>'PREPARE_FOR_SUBMISSION'},'reviewDetailConfigured'=>true,'latestSubmission'=>latest,
      'reviewState'=>latest ? latest['state'] : 'NOT_SUBMITTED','nextAction'=>'none',
      'demoAccountPassword'=>state['secret']}
  when 'review submit'
    state['submitted']=true
    {'appId'=>state['appId'],'version'=>state['version'],'versionId'=>'VERSION1','buildId'=>state['buildId'],
      'platform'=>'IOS','submissionId'=>'SUBMISSION1','submittedDate'=>Time.now.utc.iso8601}
  else
    abort "unexpected fake command #{command}"
  end
  File.binwrite(state_path,JSON.generate(state))
  puts JSON.generate(result)
FAKE
File.chmod(0700,fake)
state_path=File.join(scratch,'remote.json')
forms={}
%w[en-US ja].each do |locale|
  forms["app-info:#{locale}"]={'locale'=>locale,'name'=>'Old Name','subtitle'=>'Old subtitle',
    'privacyPolicyUrl'=>nil,'privacyChoicesUrl'=>nil,'privacyPolicyText'=>nil}
  forms["version:#{locale}"]={'locale'=>locale,'description'=>'Old description','keywords'=>'old',
    'promotionalText'=>nil,'whatsNew'=>nil,'supportUrl'=>nil,'marketingUrl'=>nil}
end
initial={'team'=>team,'bundle'=>bundle,'appId'=>app_id,'version'=>version,'buildId'=>build_id,
  'buildNumber'=>build_number,'category'=>nil,'copyright'=>'Old copyright','forms'=>forms,
  'shots'=>{'en-US'=>{},'ja'=>{}},'attached'=>false,'submitted'=>false,'localizationMutated'=>false,
  'scenario'=>'normal','calls'=>[],'secret'=>secret}
File.binwrite(state_path,JSON.generate(initial))
ENV['IOS_TEMPLATE_TEST_MODE']='1'
ENV['IOS_TEMPLATE_TEST_ASC_RUNNER']=fake
ENV['FAKE_ASC_STATE']=state_path

browser=put(scratch,'browser.json',{'schemaVersion'=>1,'sections'=>{
  'privacy'=>{'checkedAt'=>now,'remoteReference'=>"asc://apps/#{app_id}/privacy/DECL1",'readBackDigest'=>dig('privacy-readback'),
    'sealedSourceDigest'=>"sha256:#{Digest::SHA256.file(File.join(package,'privacy/data-use.yml')).hexdigest}"},
  'review-information'=>{'checkedAt'=>now,'remoteReference'=>"asc://apps/#{app_id}/reviewDetails/DETAIL1",
    'readBackDigest'=>dig('review-readback'),
    'sealedSourceDigest'=>"sha256:#{Digest::SHA256.file(File.join(package,'review/review-notes.md')).hexdigest}"}
}})
result_path=File.join(package,'submission',"#{version}-result.json")
entry=File.join(root,'tools/lib/appstore-release-sections.rb')
require entry
args=['--repo',project,'--issue','77','--team-id',team,'--app-id',app_id,'--bundle-id',bundle,
  '--version',version,'--build-id',build_id,'--build-number',build_number,'--source-sha',head,
  '--build-digest',build_digest,'--primary-model','codex','--audit',audit,'--build-journal',journal,
  '--browser-readbacks',browser,'--now',now]
invoke=lambda do |section, expected=0, extra=[]|
  if expected == 1 || section != 'app-information'
    # The full proof is exercised above, by the first section CLI, and by
    # record-section.sh for every successful section. In-process calls avoid
    # recompiling the same Swift proof for each additional branch check.
    validator=IOSTemplate::ReleaseVerification
    original=validator.method(:with_full_proof)
    validator.define_singleton_method(:with_full_proof) { |**_options,&block| block.call(nil) }
    error=nil
    outcome=nil
    begin
      begin
        outcome=IOSTemplate::AppStoreReleaseSections.run({root:project,issue:77,team:team,app_id:app_id,
          bundle:bundle,version:version,build_id:build_id,build_number:build_number,head:head,
          build_digest:build_digest,executor:'codex',section:section,audit:audit,
          build_journal:journal,browser_readbacks:browser,now:now,
          approval:extra.last})
      rescue IOSTemplate::AppStoreReleaseSections::Refused => failure
        error=failure.message
      end
    ensure
      validator.define_singleton_method(:with_full_proof,original)
    end
    if expected == 1
      check(error,'expected section refusal: '+section)
      check(!error.include?(secret),'no secret in refused output')
      next ['',error]
    end
    check(error.nil?,"unexpected #{section} refusal: #{error}")
    output=JSON.generate(outcome)
    check(!output.include?(secret),'no secret in section result')
    next [output,'']
  end
  output,error,status=Open3.capture3('/usr/bin/ruby',entry,*args,'--section',section,*extra)
  check(status.exitstatus==expected,"#{section} exit #{status.exitstatus} != #{expected}: #{error} #{output}")
  check(!output.include?(secret) && !error.include?(secret),'no secret in output or log')
  [output,error]
end
scenario=lambda do |name|
  data=JSON.parse(File.binread(state_path)); data['scenario']=name
  File.binwrite(state_path,JSON.generate(data))
end

preflight_path=File.join(project,'.artifacts/issues/77/provider-preflights/app-store-update_metadata.json')
preflight_bytes=File.binread(preflight_path)
bad=JSON.parse(preflight_bytes); bad['operation']='appstore.inspect_app'
bad['digest']=dig(bad.reject { |k,_| k=='digest' })
File.binwrite(preflight_path,JSON.generate(bad))
invoke.call('app-information',1)
File.binwrite(preflight_path,preflight_bytes)

app_path=File.join(package,'metadata/app.yml')
app_bytes=File.binread(app_path)
File.open(app_path,'ab') { |file| file.write("\nchanged\n") }
invoke.call('app-information',1)
File.binwrite(app_path,app_bytes)
scenario.call('identity-team'); invoke.call('app-information',1); scenario.call('normal')
scenario.call('app-information-readback'); invoke.call('app-information',1); scenario.call('normal')
first,_=invoke.call('app-information')
first=JSON.parse(first)
check(first['schemaVersion']==2 && first['sections'].first['readBackSource']=='app-store-connect-api',
  'schema 2 API result')

scenario.call('localization-readback'); invoke.call('localization',1); scenario.call('normal')
saved=File.binread(result_path)
legacy=JSON.parse(saved); legacy['schemaVersion']=1
File.binwrite(result_path,JSON.generate(legacy))
invoke.call('localization',1)
File.binwrite(result_path,saved)
scenario.call('app-information-readback'); invoke.call('localization',1); scenario.call('normal')
invoke.call('localization')

invoke.call('privacy')
check(JSON.parse(File.binread(result_path))['sections'].last['readBackSource']=='app-store-connect-browser',
  'browser result source')
browser_doc=JSON.parse(File.binread(browser))
browser_doc['sections']['privacy']['readBackDigest']=dig('privacy-drift')
File.binwrite(browser,JSON.generate(browser_doc))
invoke.call('screenshots',1)
browser_doc['sections']['privacy']['readBackDigest']=dig('privacy-readback')
browser_doc['sections']['privacy']['checkedAt']=(Time.iso8601(now)-7200).utc.iso8601
File.binwrite(browser,JSON.generate(browser_doc))
invoke.call('screenshots',1)
browser_doc['sections']['privacy']['checkedAt']=now
File.binwrite(browser,JSON.generate(browser_doc))

scenario.call('screenshots-readback'); invoke.call('screenshots',1); scenario.call('normal')
remote=JSON.parse(File.binread(state_path))
remote['shots']['en-US']['APP_IPHONE_67'][0]['attributes']['sourceFileChecksum']='f'*32
File.binwrite(state_path,JSON.generate(remote))
invoke.call('screenshots',1)
remote['shots']['en-US']['APP_IPHONE_67'][0]['attributes']['sourceFileChecksum']=
  Digest::MD5.file(File.join(package,'screenshots/en-US/iphone-6.9/01-primary.png')).hexdigest
File.binwrite(state_path,JSON.generate(remote))
invoke.call('screenshots')

journal_last=File.join(journal,'0005-processing-readback.json')
journal_bytes=File.binread(journal_last)
invalid=JSON.parse(journal_bytes); invalid['processingState']='PROCESSING'
File.binwrite(journal_last,JSON.generate(canon(invalid))+"\n")
invoke.call('build',1)
File.binwrite(journal_last,journal_bytes)
scenario.call('build-readback'); invoke.call('build',1); scenario.call('normal')
invoke.call('build')
invoke.call('review-information')

invoke.call('submission',1)
scenario.call('submission-readback')
invoke.call('submission',1,['--approval-reference','approval: user-approval://synthetic-release'])
scenario.call('normal')
remote=JSON.parse(File.binread(state_path)); remote['submitted']=false
File.binwrite(state_path,JSON.generate(remote))
invoke.call('submission',0,['--approval-reference','approval: user-approval://synthetic-release'])
final=JSON.parse(File.binread(result_path))
check(final['status']=='submitted' && final['sections'].map { |row| row['id'] }==
  %w[app-information localization privacy screenshots build review-information submission], 'all sections ordered')
check(final['sections'].map { |row| row['readBackSource'] }==
  %w[app-store-connect-api app-store-connect-api app-store-connect-browser app-store-connect-api app-store-connect-api app-store-connect-browser app-store-connect-api],
  'API and browser readback sources')
check(!File.binread(result_path).include?(secret),'no secret in result')

record=File.join(root,'.agents/skills/submit-appstore-release/scripts/record-section.sh')
record_args=['--repo',project,'--package-root',package,'--package-manifest',File.join(package,'submission',"#{version}-package.json"),
  '--preflight',preflight_path,'--audit',audit,'--result',result_path,'--team-id',team,'--bundle-id',bundle,
  '--version',version,'--build-id',build_id,'--source-sha',head,'--build-digest',build_digest,
  '--primary-model','codex','--section','app-information','--readback-source','browser',
  '--remote-reference',"asc://apps/#{app_id}/test",'--readback-digest',dig('readback'),
  '--resume-readback','yes','--now',now]
_out,error,status=Open3.capture3(record,*record_args)
check(!status.success? && error.include?('section and readback source mismatch'),'route mismatch rejected')
record_args[record_args.index('browser')]='api'
File.binwrite(preflight_path,JSON.generate(bad))
_out,error,status=Open3.capture3(record,*record_args)
check(!status.success? && error.include?('preflight operation mismatch'),'operation mismatch rejected')
File.binwrite(preflight_path,preflight_bytes)

puts 'PASS: App Store release sections verify API and browser sources, sealed inputs, resume and approval'
RUBY
