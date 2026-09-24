#!/bin/bash
set -euo pipefail
export LANG=en_US.UTF-8

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby git

root=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-appstore-build.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf -- "$scratch"' EXIT

/usr/bin/ruby --disable-gems - "$root" "$scratch" <<'RUBY'
require 'json'
require 'yaml'
require 'digest'
require 'fileutils'
require 'open3'
require 'time'

root, scratch = ARGV
project = File.join(scratch, 'project')
home = File.join(scratch, 'home')
entry = File.join(root, 'tools/export-appstore-build.sh')
FileUtils.mkdir_p(project)
FileUtils.mkdir_p(home)

def check(value, label)
  abort "FAIL: #{label}" unless value
end
def write(root, relative, value)
  path = File.join(root, relative)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, value.is_a?(String) ? value : JSON.generate(value))
  path
end
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
def git(project, *args)
  output, error, status = Open3.capture3('/usr/bin/git', '-C', project, *args)
  check(status.success?, "git #{args.first}: #{error}")
  output.strip
end

identity = {'schemaVersion'=>1,'sourceIdentityVersion'=>1,'displayName'=>'Garden Notes','moduleName'=>'GardenNotes','appSlug'=>'garden-notes','bundleId'=>'com.example.garden'}
write(project, 'Config/app-identity.json', identity)
FileUtils.cp(File.join(root,'Config/Public.xcconfig'), write(project,'Config/Public.xcconfig',''))
ownership = YAML.safe_load(File.binread(File.join(root,'Config/ownership.yml')), permitted_classes: [], aliases: false)
ownership['appStore'] = {'teamId'=>'TEAM123456','bundleId'=>'com.example.garden'}
write(project, 'Config/ownership.yml', YAML.dump(ownership))
pbx = File.binread(File.join(root,'TemplateApp.xcodeproj/project.pbxproj')).gsub('com.yuto.TemplateApp','com.example.garden').gsub('TemplateApp','GardenNotes').gsub('CURRENT_PROJECT_VERSION = 1;','CURRENT_PROJECT_VERSION = 7;')
write(project, 'GardenNotes.xcodeproj/project.pbxproj', pbx)
scheme = File.binread(File.join(root,'TemplateApp.xcodeproj/xcshareddata/xcschemes/TemplateApp.xcscheme')).gsub('TemplateApp','GardenNotes')
write(project, 'GardenNotes.xcodeproj/xcshareddata/xcschemes/GardenNotes.xcscheme', scheme)
write(project, '.gitignore', ".artifacts/\n")
git(project,'init','-q')
git(project,'config','user.name','Synthetic Fixture')
git(project,'config','user.email','fixture@example.invalid')
git(project,'remote','add','origin','https://github.com/example/build-fixture.git')
git(project,'add','Config','GardenNotes.xcodeproj','.gitignore')
git(project,'-c','core.hooksPath=/dev/null','commit','-q','-m','Synthetic build fixture')
head = git(project,'rev-parse','HEAD')

cases = %w[iphone-en iphone-ja ipad-en ipad-ja]
verification = {'bundleIdentifier'=>'com.example.garden','unitTestIdentifier'=>'GardenNotesTests/GardenNotesTests/testBuild()',
  'cases'=>cases.map { |id| {'id'=>id,'testIdentifier'=>'GardenNotesUITests/GardenNotesUITests/testBuild'} },
  'acceptanceMappings'=>[{'id'=>'AC-1','checks'=>['stage:build','stage:unit-tests']+cases.map { |id| "case:#{id}" }+cases.map { |id| "visual:#{id}" }}]}
ops = [['github.read_issue','GitHub'],['appstore.upload_build','App Store Connect']]
operation_blocks = ops.map { |operation,service| "- Operation: #{operation}\n- Service: #{service}\n- Environment: production\n- Executor: Codex\n- Approval required: no" }.join("\n\n")
body = <<~ISSUE
  ## Goal

  Synthetic build upload.

  ## In scope

  - Archive, export, upload and readback.

  ## Out of scope

  - Real Apple operations.

  ## Acceptance criteria

  - AC-1: UI-direction route: not-applicable; Scope: synthetic build; Reason: no UI changes

  ## Spec anchors

  - [App Store adapter](specs/architecture.md#72-app-store-connect-api-adapter)

  ## Dependencies

  - None.

  ## UI verification

  Not applicable

  ## Delivery stage

  - Stage: release
  - Time budget: 240 minutes
  - Reason: Simulated release operation.

  ## Delivery profile

  - Profile: strict
  - Reason: Binary upload is sensitive.

  ## Verification scope

  - Scope: full
  - Reason: Synthetic live-operation contract.

  ## Verification

  #{JSON.generate(verification)}

  ## External operations

  #{operation_blocks}

  ## User approvals

  - No additional approval.
ISSUE
body_path = write(scratch,'issue-body.md',body)
contract_bytes, contract_error, contract_status = Open3.capture3('/usr/bin/ruby','--disable-gems',File.join(root,'tools/lib/issue-contract.rb'),
  '--body',body_path,'--type','release','--format','contract','--issue','42','--repo','example/build-fixture','--fetched-at','2026-09-24T00:00:00Z')
check(contract_status.success?, "synthetic contract: #{contract_error}")
contract_path = '.artifacts/issues/42/issue-contract.json'
write(project,contract_path,contract_bytes)
state_path = '.artifacts/issues/42/state.json'
state = {'issue'=>42,'state'=>'in-progress','executor'=>'codex','issueContract'=>{'path'=>contract_path,'digest'=>"sha256:#{Digest::SHA256.hexdigest(contract_bytes)}"}}
write(project,state_path,state)
preflight_path = '.artifacts/issues/42/provider-preflights/app-store-upload_build.json'
preflight = {'schemaVersion'=>2,'issue'=>42,'executor'=>'codex','provider'=>'app-store','account'=>'TEAM123456','target'=>'com.example.garden',
  'environment'=>'production','operation'=>'appstore.upload_build','health'=>'healthy','checkedAt'=>Time.now.utc.iso8601}
preflight['digest'] = digest(preflight)
write(project,preflight_path,preflight)

secret_parent = File.join(home,'Library','Application Support','iOS-Template','secrets')
secret_dir = File.join(secret_parent,'garden-notes')
FileUtils.mkdir_p(secret_dir)
File.chmod(0700,secret_parent,secret_dir)
key_path = write(secret_dir,'app-store-connect-production.p8',"synthetic private key\n")
File.chmod(0600,key_path)
security = write(scratch,'fake-security',<<~'FAKE')
  #!/usr/bin/ruby
  name = ARGV[ARGV.index('-s')+1]
  value = name.end_with?('/key-id') ? 'fixture-key-133' : name.end_with?('/issuer-id') ? 'fixture-issuer-133' : nil
  abort unless value
  puts value
FAKE
File.chmod(0700,security)
remote_path = write(scratch,'remote.json',{'scenario'=>'normal','calls'=>[],'build'=>nil,'polls'=>0})
fake_xcode = write(scratch,'fake-xcodebuild',<<~'FAKE'.gsub('__REMOTE__',remote_path.dump))
  #!/usr/bin/ruby
  require 'json'
  remote_path = __REMOTE__
  state = JSON.parse(File.binread(remote_path))
  abort 'missing key env' unless ENV['ASC_KEY_ID'] == 'fixture-key-133' && ENV['ASC_ISSUER_ID'] == 'fixture-issuer-133' &&
    File.binread(ENV.fetch('ASC_PRIVATE_KEY_PATH')) == "synthetic private key\n"
  abort 'missing signing args' unless ARGV.each_cons(2).any? { |a,b| a == '-authenticationKeyID' && b == ENV['ASC_KEY_ID'] } &&
    ARGV.each_cons(2).any? { |a,b| a == '-authenticationKeyIssuerID' && b == ENV['ASC_ISSUER_ID'] } &&
    ARGV.each_cons(2).any? { |a,b| a == '-authenticationKeyPath' && b == ENV['ASC_PRIVATE_KEY_PATH'] } &&
    ARGV.include?('-allowProvisioningUpdates')
  abort 'manual signing' if ARGV.any? { |arg| arg.include?('CODE_SIGN_STYLE=Manual') || arg.include?('signing') }
  action = ARGV.include?('archive') ? 'archive' : ARGV.include?('-exportArchive') ? 'export' : 'unknown'
  if action == 'archive'
    abort 'archive configuration' unless ARGV.each_cons(2).any? { |a,b| a == '-configuration' && b == 'Release' } &&
      ARGV.each_cons(2).any? { |a,b| a == '-destination' && b == 'generic/platform=iOS' } &&
      ARGV.include?('-derivedDataPath') && ARGV.include?('CODE_SIGN_STYLE=Automatic') &&
      ARGV.include?('DEVELOPMENT_TEAM=TEAM123456')
  elsif action == 'export'
    options = File.binread(ARGV[ARGV.index('-exportOptionsPlist')+1])
    abort 'unsafe export options' unless options.include?('<string>app-store-connect</string>') &&
      options.include?('<string>export</string>') && options.include?('<string>automatic</string>') &&
      options.include?('<string>TEAM123456</string>') &&
      options.include?('<key>manageAppVersionAndBuildNumber</key><false/>')
  end
  state['calls'] << action
  File.binwrite(remote_path,JSON.generate(state))
  puts "#{ENV['ASC_KEY_ID']} #{ENV['ASC_ISSUER_ID']} #{ENV['ASC_PRIVATE_KEY_PATH']}"
  warn "#{ENV['ASC_KEY_ID']} #{ENV['ASC_ISSUER_ID']} #{ENV['ASC_PRIVATE_KEY_PATH']}"
  exit 7 if state['scenario'] == "#{action}-fail"
  if action == 'archive'
    path = ARGV[ARGV.index('-archivePath')+1]
    Dir.mkdir(path)
    File.binwrite(File.join(path,'archive.marker'),'synthetic archive')
  elsif action == 'export'
    path = ARGV[ARGV.index('-exportPath')+1]
    Dir.mkdir(path)
    File.binwrite(File.join(path,'GardenNotes.ipa'),'synthetic ipa bytes')
  else
    exit 8
  end
FAKE
File.chmod(0700,fake_xcode)
fake_runner = write(scratch,'fake-asc-runner',<<~'FAKE'.gsub('__REMOTE__',remote_path.dump))
  #!/usr/bin/ruby
  require 'json'
  state_path = __REMOTE__
  state = JSON.parse(File.binread(state_path))
  abort 'wrong operation' unless ARGV.take(3) == ['--operation','appstore.upload_build','--']
  args = ARGV.drop(3)
  action = args.take(2).join(' ')
  state['calls'] << action
  response = nil
  case action
  when 'apps list'
    response = {'data'=>[{'type'=>'apps','id'=>'1234567890','attributes'=>{'bundleId'=>'com.example.garden'}}]}
  when 'builds list'
    abort 'missing selectors' unless ['--app','--version','--build-number','--platform','--paginate'].all? { |flag| args.include?(flag) }
    state['polls'] += 1
    build = state['build']
    response = {'data'=>build ? [{'type'=>'builds','id'=>'BUILD123','attributes'=>{'version'=>'7','processingState'=>build}}] : []}
  when 'builds info'
    response = {'data'=>{'type'=>'builds','id'=>'BUILD123','attributes'=>{'version'=>'7','processingState'=>state['build']},
      'relationships'=>{'preReleaseVersion'=>{'data'=>{'type'=>'preReleaseVersions','id'=>'PRERELEASE1'}}}},
      'included'=>[{'type'=>'preReleaseVersions','id'=>'PRERELEASE1','attributes'=>{'version'=>'1.0','platform'=>'IOS'}}]}
  when 'builds upload'
    abort 'invalid upload args' unless args.length == 8 && args[2] == '--app' && args[4] == '--ipa' && args[6..] == ['--output','json']
    path = args[5]
    abort 'invalid ipa' unless path.start_with?('/') && File.file?(path) && File.binread(path) == 'synthetic ipa bytes'
    state['build'] = 'PROCESSING' unless state['scenario'] == 'upload-reject'
    response = {'uploadId'=>'UPLOAD1','fileId'=>'FILE1','fileName'=>'GardenNotes.ipa','fileSize'=>19,'uploaded'=>true}
  else
    abort "unallowlisted #{action}"
  end
  File.binwrite(state_path,JSON.generate(state))
  if action == 'builds upload' && state['scenario'] == 'upload-reject'
    puts JSON.generate({'errors'=>[{'status'=>'422'}]})
    exit 9
  end
  exit 10 if action == 'builds upload' && state['scenario'] == 'upload-ambiguous'
  if action == 'builds list' && state['scenario'] == 'duplicate'
    response = {'data'=>[{'type'=>'builds','id'=>'EXISTING','attributes'=>{'version'=>'7','processingState'=>'VALID'}}]}
  elsif action == 'builds list' && state['scenario'] == 'processing-failed' && state['build']
    state['build'] = 'FAILED'; File.binwrite(state_path,JSON.generate(state)); response['data'][0]['attributes']['processingState'] = 'FAILED'
  elsif action == 'builds list' && state['scenario'] == 'normal' && state['build'] && state['polls'] > 1
    state['build'] = 'VALID'; File.binwrite(state_path,JSON.generate(state)); response['data'][0]['attributes']['processingState'] = 'VALID'
  end
  puts JSON.generate(response)
FAKE
File.chmod(0700,fake_runner)

env = {'HOME'=>home,'IOS_TEMPLATE_TEST_MODE'=>'1','IOS_TEMPLATE_TEST_XCODEBUILD'=>fake_xcode,
  'IOS_TEMPLATE_TEST_ASC_RUNNER'=>fake_runner,'IOS_TEMPLATE_TEST_SECURITY_BIN'=>security,
  'IOS_TEMPLATE_TEST_POLL_INTERVAL'=>'0.05','IOS_TEMPLATE_TEST_POLL_TIMEOUT'=>'0.3'}
base_args = ['--project-root',project,'--issue','42','--head-sha',head,'--version','1.0','--build-number','7']
invoke = lambda do |expected, args=base_args, overrides={}|
  output, error, status = Open3.capture3(env.merge(overrides),entry,*args)
  check(status.exitstatus == expected,"exit #{status.exitstatus} expected #{expected}: #{error} #{output}")
  check(!["fixture-key-133","fixture-issuer-133",key_path].any? { |secret| output.include?(secret) || error.include?(secret) },'secret leaked to output')
  [JSON.parse(output),JSON.parse(File.binread(remote_path))]
end
reset = lambda do |scenario='normal', build=nil|
  File.binwrite(remote_path,JSON.generate({'scenario'=>scenario,'calls'=>[],'build'=>build,'polls'=>0}))
end
events = lambda do |attempt|
  Dir.glob(File.join(project,'.artifacts/appstore-builds/42',attempt,'[0-9][0-9][0-9][0-9]-*.json')).sort.map { |path| JSON.parse(File.binread(path)) }
end

reset.call
result, remote = invoke.call(0)
check(result['status'] == 'valid' && remote['calls'].count('builds upload') == 1,'normal archive export upload readback')
check(remote['calls'].include?('archive') && remote['calls'].include?('export'),'xcode stages ran')
attempt = result.fetch('attempt')
history = events.call(attempt)
check(history.any? { |event| event['eventType'] == 'export-complete' && event['ipaDigest'] == "sha256:#{Digest::SHA256.hexdigest('synthetic ipa bytes')}" },'IPA digest journal')
check(history.any? { |event| event['eventType'] == 'processing-readback' && event['processingState'] == 'VALID' && event['buildId'] == 'BUILD123' },'VALID identity journal')
Dir.glob(File.join(project,'.artifacts/appstore-builds/42',attempt,'*.json')).each do |path|
  bytes = File.binread(path)
  check(!['fixture-key-133','fixture-issuer-133',key_path].any? { |secret| bytes.include?(secret) },'secret leaked to journal')
end
check(history.each_with_index.all? { |event,index| event['eventSequence'] == index+1 &&
  event['previousEventDigest'] == (index.zero? ? nil : "sha256:#{Digest::SHA256.file(File.join(project,'.artifacts/appstore-builds/42',attempt,format('%04d-%s.json',index,history[index-1]['eventType']))).hexdigest}") },'journal chain')
reset.call('normal','VALID')
resumed, remote = invoke.call(0,base_args+['--resume-attempt',attempt])
check(resumed['status'] == 'valid' && !remote['calls'].include?('builds upload'),'completed attempt resumes by readback')

assert_prearchive_block = lambda do |label,args=base_args|
  result, remote = invoke.call(1,args)
  check(result['status'] == 'blocked' && !remote['calls'].include?('archive') &&
    !remote['calls'].include?('export') && !remote['calls'].include?('builds upload'),label)
end
reset.call
dirty = write(project,'Config/dirty.txt','untracked')
assert_prearchive_block.call('dirty worktree')
File.unlink(dirty)
reset.call
assert_prearchive_block.call('head mismatch',base_args.each_slice(2).flat_map { |a,b| a == '--head-sha' ? [a,'f'*40] : [a,b] })
reset.call
assert_prearchive_block.call('version mismatch',base_args.each_slice(2).flat_map { |a,b| a == '--version' ? [a,'2.0'] : [a,b] })
reset.call
assert_prearchive_block.call('build number mismatch',base_args.each_slice(2).flat_map { |a,b| a == '--build-number' ? [a,'8'] : [a,b] })

pbx_path = File.join(project,'GardenNotes.xcodeproj/project.pbxproj')
original_pbx = File.binread(pbx_path)
File.binwrite(pbx_path,original_pbx.gsub('com.example.garden','com.example.other'))
git(project,'add','GardenNotes.xcodeproj/project.pbxproj')
git(project,'-c','core.hooksPath=/dev/null','commit','-q','-m','Synthetic bundle mismatch')
head = git(project,'rev-parse','HEAD')
base_args = ['--project-root',project,'--issue','42','--head-sha',head,'--version','1.0','--build-number','7']
reset.call
assert_prearchive_block.call('Release bundle mismatch',base_args)
File.binwrite(pbx_path,original_pbx)
git(project,'add','GardenNotes.xcodeproj/project.pbxproj')
git(project,'-c','core.hooksPath=/dev/null','commit','-q','-m','Restore synthetic bundle')
head = git(project,'rev-parse','HEAD')
base_args = ['--project-root',project,'--issue','42','--head-sha',head,'--version','1.0','--build-number','7']
File.binwrite(pbx_path,original_pbx.gsub('CODE_SIGN_STYLE = Automatic;','CODE_SIGN_STYLE = Manual;'))
git(project,'add','GardenNotes.xcodeproj/project.pbxproj')
git(project,'-c','core.hooksPath=/dev/null','commit','-q','-m','Synthetic manual signing')
head = git(project,'rev-parse','HEAD')
base_args = ['--project-root',project,'--issue','42','--head-sha',head,'--version','1.0','--build-number','7']
reset.call
assert_prearchive_block.call('manual signing configuration',base_args)
File.binwrite(pbx_path,original_pbx)
git(project,'add','GardenNotes.xcodeproj/project.pbxproj')
git(project,'-c','core.hooksPath=/dev/null','commit','-q','-m','Restore automatic signing')
head = git(project,'rev-parse','HEAD')
base_args = ['--project-root',project,'--issue','42','--head-sha',head,'--version','1.0','--build-number','7']

preflight_file = File.join(project,preflight_path)
original_preflight = File.binread(preflight_file)
File.rename(preflight_file,preflight_file+'.saved')
reset.call
assert_prearchive_block.call('missing preflight',base_args)
File.rename(preflight_file+'.saved',preflight_file)
old = JSON.parse(original_preflight)
old['checkedAt'] = (Time.now.utc-3700).iso8601
old['digest'] = digest(old.reject { |key,_| key == 'digest' })
File.binwrite(preflight_file,JSON.generate(old))
reset.call
assert_prearchive_block.call('stale preflight',base_args)
wrong = JSON.parse(original_preflight)
wrong['operation'] = 'appstore.inspect_app'
wrong['digest'] = digest(wrong.reject { |key,_| key == 'digest' })
File.binwrite(preflight_file,JSON.generate(wrong))
reset.call
assert_prearchive_block.call('wrong preflight operation',base_args)
File.binwrite(preflight_file,original_preflight)

contract_file = File.join(project,contract_path)
state_file = File.join(project,state_path)
other_body = write(scratch,'other-issue.md',body.gsub('appstore.upload_build','appstore.inspect_app'))
other_contract, other_error, other_status = Open3.capture3('/usr/bin/ruby','--disable-gems',File.join(root,'tools/lib/issue-contract.rb'),
  '--body',other_body,'--type','release','--format','contract','--issue','42','--repo','example/build-fixture','--fetched-at','2026-09-24T00:00:00Z')
check(other_status.success?,"synthetic undeclared contract: #{other_error}")
File.binwrite(contract_file,other_contract)
state['issueContract']['digest'] = "sha256:#{Digest::SHA256.hexdigest(other_contract)}"
File.binwrite(state_file,JSON.generate(state))
reset.call
assert_prearchive_block.call('contract omits upload operation',base_args)
File.binwrite(contract_file,contract_bytes)
state['issueContract']['digest'] = "sha256:#{Digest::SHA256.hexdigest(contract_bytes)}"
File.binwrite(state_file,JSON.generate(state))

reset.call('duplicate','VALID')
assert_prearchive_block.call('duplicate remote build',base_args)
reset.call('archive-fail')
failed, remote = invoke.call(1,base_args)
check(failed['status'] == 'failed' && remote['calls'].include?('archive') && !remote['calls'].include?('export'),'archive signing failure')
reset.call('export-fail')
failed, remote = invoke.call(1,base_args)
check(failed['status'] == 'failed' && remote['calls'].include?('export') && !remote['calls'].include?('builds upload'),'export failure')
reset.call('upload-reject')
failed, remote = invoke.call(1,base_args)
check(failed['status'] == 'failed' && remote['calls'].count('builds upload') == 1,'upload rejection')
reset.call('processing-failed')
failed, remote = invoke.call(1,base_args)
check(failed['status'] == 'failed' && remote['calls'].count('builds upload') == 1 &&
  events.call(failed['attempt']).any? { |event| event['processingState'] == 'FAILED' },'processing FAILED')
reset.call('processing-timeout')
unknown, remote = invoke.call(1,base_args)
check(unknown['status'] == 'unknown' && remote['calls'].count('builds upload') == 1 &&
  events.call(unknown['attempt']).any? { |event| event['status'] == 'timeout' },'processing timeout')

reset.call('upload-ambiguous')
unknown, remote = invoke.call(1,base_args)
check(unknown['status'] == 'unknown' && remote['calls'].count('builds upload') == 1,'ambiguous upload outcome')
ambiguous_attempt = unknown.fetch('attempt')
ipa_path = File.join(project,'.artifacts/appstore-builds/42',ambiguous_attempt,'export/GardenNotes.ipa')
File.binwrite(ipa_path,'different bytes')
state_remote = JSON.parse(File.binread(remote_path)); state_remote['calls'] = []; state_remote['scenario'] = 'normal'
File.binwrite(remote_path,JSON.generate(state_remote))
assert_prearchive_block.call('resume IPA digest mismatch',base_args+['--resume-attempt',ambiguous_attempt])
File.binwrite(ipa_path,'synthetic ipa bytes')
state_remote = JSON.parse(File.binread(remote_path)); state_remote['calls'] = []; state_remote['build'] = nil
File.binwrite(remote_path,JSON.generate(state_remote))
assert_prearchive_block.call('resume refuses second upload when remote build is absent',base_args+['--resume-attempt',ambiguous_attempt])
state_remote = JSON.parse(File.binread(remote_path)); state_remote['calls'] = []; state_remote['build'] = 'PROCESSING'
File.binwrite(remote_path,JSON.generate(state_remote))
refreshed = JSON.parse(original_preflight)
refreshed['checkedAt'] = (Time.now.utc-1).iso8601
refreshed['digest'] = digest(refreshed.reject { |key,_| key == 'digest' })
File.binwrite(preflight_file,JSON.generate(refreshed))
resumed, remote = invoke.call(0,base_args+['--resume-attempt',ambiguous_attempt])
check(resumed['status'] == 'valid' && !remote['calls'].include?('builds upload'),'ambiguous response resolved by remote readback after fresh preflight')

File.rename(ipa_path,ipa_path+'.saved')
File.symlink(ipa_path+'.saved',ipa_path)
reset.call('normal','VALID')
assert_prearchive_block.call('resume rejects symlink IPA',base_args+['--resume-attempt',ambiguous_attempt])
File.unlink(ipa_path)
File.rename(ipa_path+'.saved',ipa_path)

production_env = env.reject { |key,_| key == 'IOS_TEMPLATE_TEST_MODE' }
output, error, status = Open3.capture3(production_env,entry,*base_args)
check(!status.success? && !output.include?('fixture-key-133') && !error.include?('fixture-key-133'),'production rejects test overrides')
puts 'PASS: appstore build upload'
RUBY
