#!/bin/bash
set -euo pipefail
export LANG=en_US.UTF-8
source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby git
source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
exec /usr/bin/ruby --disable-gems - "$source_root" <<'RUBY'
# encoding: UTF-8
require 'json'
require 'yaml'
require 'digest'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'time'

root = ARGV.fetch(0)
entry = File.join(root, 'tools/distribute-testflight-build.sh')
def check(value, label)
  abort "FAIL: #{label}" unless value
end
def write(base, relative, bytes)
  path = File.join(base, relative)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, bytes.is_a?(String) ? bytes : JSON.generate(bytes))
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

Dir.mktmpdir('asc-testflight-test.') do |scratch|
  scratch = File.realpath(scratch)
  count = 0
  make_fixture = lambda do |name, external: false, approval: false, identity_mismatch: false, notes: nil, symlink_notes: false|
    project = File.join(scratch, name)
    FileUtils.mkdir_p(project)
    write(project, '.gitignore', ".artifacts/\n")
    write(project, 'Config/app-identity.json', {'schemaVersion'=>1,'sourceIdentityVersion'=>1,
      'displayName'=>'Garden Notes','moduleName'=>'GardenNotes','appSlug'=>'garden-notes','bundleId'=>'com.example.garden'})
    ownership = YAML.safe_load(File.binread(File.join(root,'Config/ownership.yml')), permitted_classes: [], aliases: false)
    ownership['appStore'] = {'teamId'=>'TEAM123456','bundleId'=>identity_mismatch ? 'com.example.other' : 'com.example.garden'}
    write(project, 'Config/ownership.yml', YAML.dump(ownership))
    if notes
      source = 'App Store/release-notes/what-to-test.txt'
      if symlink_notes
        write(project,'App Store/release-notes/real-notes.txt',notes)
        File.symlink('real-notes.txt',File.join(project,source))
      else
        write(project,source,notes)
      end
    end
    git(project,'init','-q')
    git(project,'config','user.name','Synthetic Fixture')
    git(project,'config','user.email','fixture@example.invalid')
    git(project,'remote','add','origin','https://github.com/example/distribution-fixture.git')
    git(project,'add','--all')
    git(project,'-c','core.hooksPath=/dev/null','commit','-q','-m','Synthetic distribution fixture')
    head = git(project,'rev-parse','HEAD')
    issue = 42
    approval_reference = 'approval: user-approval://fixture-135'
    verification = {'bundleIdentifier'=>'com.example.garden',
      'unitTestIdentifier'=>'GardenNotesTests/GardenNotesTests/testDistribution()',
      'cases'=>%w[iphone-en iphone-ja ipad-en ipad-ja].map { |id| {'id'=>id,'testIdentifier'=>'GardenNotesUITests/GardenNotesUITests/testDistribution'} },
      'acceptanceMappings'=>[{'id'=>'AC-1','checks'=>['stage:build','stage:unit-tests']+
        %w[iphone-en iphone-ja ipad-en ipad-ja].map { |id| "case:#{id}" }+
        %w[iphone-en iphone-ja ipad-en ipad-ja].map { |id| "visual:#{id}" }}]}
    body = <<~ISSUE
      ## Goal

      Synthetic TestFlight distribution.

      ## In scope

      - Assign specified groups and optionally submit beta review.

      ## Out of scope

      - Real Apple operations.

      ## Acceptance criteria

      - AC-1: UI-direction route: not-applicable; Scope: synthetic distribution; Reason: no UI changes

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
      - Reason: Distribution is sensitive.

      ## Verification scope

      - Scope: full
      - Reason: Synthetic live-operation contract.

      ## Verification

      #{JSON.generate(verification)}

      ## External operations

      - Operation: github.read_issue
      - Service: GitHub
      - Environment: production
      - Executor: Codex
      - Approval required: no

      - Operation: appstore.distribute_testflight
      - Service: App Store Connect
      - Environment: production
      - Executor: Codex
      - Approval required: #{approval ? 'yes' : 'no'}

      ## User approvals

      #{approval ? approval_reference : 'No additional approval'}
    ISSUE
    body_path = write(scratch,"#{name}-body.md",body)
    bytes, error, status = Open3.capture3('/usr/bin/ruby','--disable-gems',File.join(root,'tools/lib/issue-contract.rb'),
      '--body',body_path,'--type','release','--format','contract','--issue',issue.to_s,
      '--repo','example/distribution-fixture','--fetched-at','2026-09-24T00:00:00Z')
    check(status.success?, "fixture contract: #{error}")
    contract_path = ".artifacts/issues/#{issue}/issue-contract.json"
    write(project,contract_path,bytes)
    contract_digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    write(project,".artifacts/issues/#{issue}/state.json",{'issue'=>issue,'state'=>'in-progress','executor'=>'codex',
      'issueContract'=>{'path'=>contract_path,'digest'=>contract_digest}})
    preflight = {'schemaVersion'=>2,'issue'=>issue,'executor'=>'codex','provider'=>'app-store',
      'account'=>'TEAM123456','target'=>'com.example.garden','environment'=>'production',
      'operation'=>'appstore.distribute_testflight','health'=>'healthy','checkedAt'=>Time.now.utc.iso8601}
    preflight['digest'] = digest(preflight)
    preflight_path = write(project,".artifacts/issues/#{issue}/provider-preflights/app-store-distribute_testflight.json",preflight)
    attempt = 'a'+'1'*24
    journal_dir = File.join(project,".artifacts/appstore-builds/#{issue}/#{attempt}")
    FileUtils.mkdir_p(journal_dir)
    File.chmod(0700,journal_dir)
    previous = nil
    %w[started export-complete upload-intent upload-result processing-readback].each_with_index do |type,index|
      event = {'schemaVersion'=>1,'recordType'=>'appstore-build-upload','eventType'=>type,'eventSequence'=>index+1,
        'previousEventDigest'=>previous,'issue'=>issue,'attempt'=>attempt,'headSha'=>head,'version'=>'1.0',
        'buildNumber'=>'7','bundleId'=>'com.example.garden','contractDigest'=>contract_digest,'checkedAt'=>Time.now.utc.iso8601}
      event.merge!(case type
        when 'started' then {'teamId'=>'TEAM123456','preflightDigest'=>preflight['digest']}
        when 'export-complete','upload-intent' then {'ipaDigest'=>'sha256:'+'a'*64}
        when 'upload-result' then {'status'=>'accepted','ipaDigest'=>'sha256:'+'a'*64,'uploadId'=>'upload-1','fileId'=>'file-1'}
        when 'processing-readback' then {'buildId'=>'build-1','processingState'=>'VALID','platform'=>'IOS','ipaDigest'=>'sha256:'+'a'*64}
        end)
      event_bytes = JSON.generate(canonical(event))+"\n"
      path = write(journal_dir,format('%04d-%s.json',index+1,type),event_bytes)
      File.chmod(0600,path)
      previous = "sha256:#{Digest::SHA256.hexdigest(event_bytes)}"
    end
    remote_path = write(scratch,"#{name}-remote.json",{'appId'=>'1234567890','buildId'=>'build-1',
      'groups'=>[{'id'=>'group-internal','internal'=>true},{'id'=>'group-external','internal'=>false}],
      'memberships'=>[],'review'=>[],'notes'=>{},'calls'=>[],'ambiguousOnce'=>false})
    runner = write(scratch,"#{name}-runner", <<~'FAKE'.gsub('__REMOTE__',remote_path.dump))
      #!/usr/bin/ruby
      # encoding: UTF-8
      require 'json'
      path = __REMOTE__
      remote = JSON.parse(File.binread(path))
      abort 'wrong operation' unless ARGV.take(3) == ['--operation','appstore.distribute_testflight','--']
      args = ARGV.drop(3)
      abort 'missing json output' unless args.last(2) == ['--output','json']
      args = args[0...-2]
      command = args.take_while { |part| !part.start_with?('--') }.join(' ')
      flags = args.drop(command.split(' ').length)
      get = ->(flag) { i=flags.index(flag); i && flags[i+1] }
      note_value = -> { direct=flags.find { |flag| flag.start_with?('--whats-new=') };
        direct ? direct.delete_prefix('--whats-new=') : get.call('--whats-new') }
      remote['calls'] << command
      response = case command
      when 'apps list'
        {'data'=>[{'type'=>'apps','id'=>remote['appId'],'attributes'=>{'bundleId'=>'com.example.garden'}}]}
      when 'builds list'
        {'data'=>[{'type'=>'builds','id'=>remote['buildId'],'attributes'=>{'version'=>'7'}}]}
      when 'builds info'
        {'data'=>{'type'=>'builds','id'=>remote['buildId'],'attributes'=>{'version'=>'7','processingState'=>remote['processingState'] || 'VALID'},
          'relationships'=>{'preReleaseVersion'=>{'data'=>{'type'=>'preReleaseVersions','id'=>'pre-1'}}}},
          'included'=>[{'type'=>'preReleaseVersions','id'=>'pre-1','attributes'=>{'version'=>'1.0','platform'=>'IOS'}}]}
      when 'testflight groups list'
        if get.call('--build-id')
          {'buildId'=>remote['buildId'],'appId'=>remote['appId'],'complete'=>true,'lookupMethod'=>'server-filter',
            'groupCount'=>remote['memberships'].length,'failures'=>[],
            'groups'=>remote['memberships'].map { |id| group=remote['groups'].find { |g| g['id']==id };
              {'id'=>id,'name'=>'tester@example.invalid','type'=>remote['membershipTypeOverride'] || (group['internal'] ? 'internal' : 'external'),
               'membership'=>'explicit','hasAccessToAllBuilds'=>false} }}
        else
          {'data'=>remote['groups'].map { |g| {'type'=>'betaGroups','id'=>g['id'],
            'attributes'=>{'name'=>'tester@example.invalid','isInternalGroup'=>g['internal']}} }}
        end
      when 'builds add-groups'
        id = get.call('--group')
        remote['memberships'] << id unless remote['memberships'].include?(id)
        if remote['ambiguousOnce']
          remote['ambiguousOnce'] = false
          File.binwrite(path,JSON.generate(remote))
          warn 'tester@example.invalid secret-fixture-value'
          exit 9
        end
        {'buildId'=>remote['buildId'],'groupIds'=>[id],'action'=>'added'}
      when 'testflight review submissions list'
        {'data'=>remote['review'].map { |state| {'type'=>'betaAppReviewSubmissions','id'=>'review-1',
          'attributes'=>{'betaReviewState'=>state}} }}
      when 'testflight review submit'
        remote['review'] = ['WAITING_FOR_REVIEW']
        {'data'=>{'type'=>'betaAppReviewSubmissions','id'=>'review-1',
          'attributes'=>{'betaReviewState'=>'WAITING_FOR_REVIEW'}}}
      when 'builds test-notes list'
        locale=get.call('--locale')
        value=remote['notes'][locale]
        {'data'=>value ? [{'type'=>'betaBuildLocalizations','id'=>"note-#{locale}",
          'attributes'=>{'locale'=>locale,'whatsNew'=>value}}] : []}
      when 'builds test-notes view'
        locale=get.call('--locale')
        value=remote['notes'][locale]
        value = "#{value} altered" if value && remote['notesReadbackMismatch']
        {'data'=>{'type'=>'betaBuildLocalizations','id'=>"note-#{locale}",
          'attributes'=>{'locale'=>locale,'whatsNew'=>value}}}
      when 'builds test-notes create', 'builds test-notes update'
        locale=get.call('--locale')
        remote['notes'][locale]=note_value.call
        if remote['ambiguousNotesOnce']
          remote['ambiguousNotesOnce']=false
          File.binwrite(path,JSON.generate(remote))
          warn remote['notes'][locale]
          exit 9
        end
        {'data'=>{'type'=>'betaBuildLocalizations','id'=>"note-#{locale}",
          'attributes'=>{'locale'=>locale,'whatsNew'=>remote['notes'][locale]}}}
      else
        abort "unexpected command #{command}"
      end
      File.binwrite(path,JSON.generate(remote))
      puts JSON.generate(response)
    FAKE
    File.chmod(0700,runner)
    detail = {'operation'=>'appstore.distribute_testflight','service'=>'App Store Connect',
      'environment'=>'production','executor'=>'Codex','approvalRequired'=>approval,
      'approvalReference'=>approval ? approval_reference : nil}
    detail_path = write(scratch,"#{name}-operation.json",detail)
    env = {'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8','HOME'=>scratch,'IOS_TEMPLATE_TEST_MODE'=>'1',
      'IOS_TEMPLATE_TEST_ASC_RUNNER'=>runner,'IOS_TEMPLATE_TEST_OPERATION_DETAIL'=>detail_path}
    [project,env,remote_path,journal_dir,preflight_path,detail_path]
  end
  invoke = lambda do |project,env,extra=[], success: true|
    args = ['--project-root',project,'--issue','42','--version','1.0','--build-number','7',
      '--group','group-internal'] + extra
    out, err, status = Open3.capture3(env,entry,*args,chdir:project,unsetenv_others:true)
    count += 1
    check(success ? status.success? : !status.success?, "case #{count}: #{out} #{err}")
    check(!out.include?('tester@example.invalid') && !err.include?('tester@example.invalid') &&
      !out.include?('secret-fixture-value') && !err.include?('secret-fixture-value'), "case #{count} output leak")
    [JSON.parse(out),err]
  end

  project,env,remote,journal,preflight,detail = make_fixture.call('internal')
  result, = invoke.call(project,env)
  check(result['status']=='distributed' && result['betaReviewState']=='not-applicable','internal success')
  check(JSON.parse(File.binread(remote))['memberships']==['group-internal'],'internal membership')
  journal_root = File.join(project,'.artifacts/appstore-testflight/42')
  check(File.directory?(File.join(journal_root,result.fetch('attempt'))) &&
    File.file?(File.join(journal_root,'.distribution.lock')),"journal and lock created: #{Dir.entries(journal_root).inspect}")
  check(!Dir.glob(File.join(project,'.artifacts/appstore-testflight/42/**/*')).select { |p| File.file?(p) }.any? { |p|
    File.binread(p).include?('tester@example.invalid') || File.binread(p).include?('secret-fixture-value') },'journal is sanitized')

  project,env,remote,* = make_fixture.call('external',external:true,approval:true)
  result, = invoke.call(project,env,['--group','group-external','--submit-beta-review','--approval','approval: user-approval://fixture-135'])
  check(result['betaReviewState']=='WAITING_FOR_REVIEW','review readback')
  check(JSON.parse(File.binread(remote))['calls'].include?('testflight review submit'),'review submitted')

  project,env,remote,* = make_fixture.call('no-approval',external:true,approval:false)
  invoke.call(project,env,['--group','group-external','--submit-beta-review','--approval','approval: user-approval://fixture-135'],success:false)
  check(!JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),'unapproved mutation blocked')

  project,env,remote,* = make_fixture.call('missing-approval-reference',external:true,approval:true)
  invoke.call(project,env,['--group','group-external','--submit-beta-review'],success:false)
  check(!JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),'missing approval reference blocked')

  project,env,remote,_,_,detail = make_fixture.call('wrong-approval',external:true,approval:true)
  value = JSON.parse(File.binread(detail)); value['approvalReference']='approval: user-approval://different'; File.binwrite(detail,JSON.generate(value))
  invoke.call(project,env,['--group','group-external','--submit-beta-review','--approval','approval: user-approval://fixture-135'],success:false)
  check(!JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),'approval mismatch blocked in test mode')

  project,env,remote,* = make_fixture.call('unsubmitted',external:true)
  result, = invoke.call(project,env,['--group','group-external'])
  check(result['betaReviewState']=='not-submitted','external without submit')
  check(!JSON.parse(File.binread(remote))['calls'].include?('testflight review submit'),'review left unsubmitted')

  project,env,remote,journal,* = make_fixture.call('not-valid')
  path = Dir.glob(File.join(journal,'*-processing-readback.json')).first
  event = JSON.parse(File.binread(path)); event['processingState']='PROCESSING'; File.binwrite(path,JSON.generate(canonical(event))+"\n")
  invoke.call(project,env,[],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'unprocessed build blocked before remote')

  project,env,remote,journal,* = make_fixture.call('other-issue')
  FileUtils.mkdir_p(File.join(project,'.artifacts/appstore-builds/43'))
  FileUtils.mv(journal,File.join(project,'.artifacts/appstore-builds/43',File.basename(journal)))
  invoke.call(project,env,[],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'other issue journal rejected')

  project,env,remote,_,preflight,* = make_fixture.call('identity',identity_mismatch:true)
  invoke.call(project,env,[],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'identity mismatch rejected')

  project,env,remote,* = make_fixture.call('remote-not-valid')
  state=JSON.parse(File.binread(remote)); state['processingState']='PROCESSING'; File.binwrite(remote,JSON.generate(state))
  invoke.call(project,env,[],success:false)
  check(!JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),'remote processing build rejected')

  project,env,remote,_,preflight,* = make_fixture.call('missing-preflight')
  File.unlink(preflight)
  invoke.call(project,env,[],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'missing preflight rejected')

  project,env,remote,_,preflight,* = make_fixture.call('stale-preflight')
  value=JSON.parse(File.binread(preflight)); value['checkedAt']=(Time.now.utc-3700).iso8601
  value['digest']=digest(value.reject { |key,_| key=='digest' }); File.binwrite(preflight,JSON.generate(value))
  invoke.call(project,env,[],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'stale preflight rejected')

  project,env,remote,* = make_fixture.call('missing-group')
  state=JSON.parse(File.binread(remote)); state['groups']=[]; File.binwrite(remote,JSON.generate(state))
  invoke.call(project,env,[],success:false)
  check(!JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),'missing group rejected')

  project,env,remote,* = make_fixture.call('duplicate-group')
  state=JSON.parse(File.binread(remote)); state['groups'] << state['groups'].first; File.binwrite(remote,JSON.generate(state))
  invoke.call(project,env,[],success:false)
  check(!JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),'duplicate remote group rejected')

  project,env,remote,* = make_fixture.call('group-type-mismatch')
  state=JSON.parse(File.binread(remote)); state['memberships']=['group-internal']; state['membershipTypeOverride']='external'
  File.binwrite(remote,JSON.generate(state))
  invoke.call(project,env,[],success:false)
  check(!JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),'group type mismatch rejected')

  project,env,remote,* = make_fixture.call('duplicate-input')
  invoke.call(project,env,['--group','group-internal'],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'duplicate input group rejected')

  note_text = "-Check onboarding\nVerify date handling"
  project,env,remote,* = make_fixture.call('notes-create',notes:note_text)
  result, = invoke.call(project,env,['--whats-new-locale','en-US','--whats-new-source','App Store/release-notes/what-to-test.txt'])
  check(result['status']=='distributed' && result['whatToTestDigest']=="sha256:#{Digest::SHA256.hexdigest(note_text)}",'What to Test readback success')
  check(JSON.parse(File.binread(remote))['notes']['en-US']==note_text,'What to Test source applied')
  check(JSON.parse(File.binread(remote))['calls'].include?('builds test-notes create'),'What to Test create path')
  check(!Dir.glob(File.join(project,'.artifacts/appstore-testflight/42/**/*')).select { |p| File.file?(p) }.any? { |p|
    File.binread(p).include?(note_text) },'What to Test value absent from journal')

  project,env,remote,* = make_fixture.call('notes-update',notes:note_text)
  state=JSON.parse(File.binread(remote)); state['notes']['en-US']='Old instructions'; File.binwrite(remote,JSON.generate(state))
  result, = invoke.call(project,env,['--whats-new-locale','en-US','--whats-new-source','App Store/release-notes/what-to-test.txt'])
  check(result['whatToTestDigest']=="sha256:#{Digest::SHA256.hexdigest(note_text)}" &&
    JSON.parse(File.binread(remote))['calls'].include?('builds test-notes update'),'What to Test update path')

  project,env,remote,* = make_fixture.call('notes-mismatch',notes:note_text)
  state=JSON.parse(File.binread(remote)); state['notesReadbackMismatch']=true; File.binwrite(remote,JSON.generate(state))
  result, = invoke.call(project,env,['--whats-new-locale','en-US','--whats-new-source','App Store/release-notes/what-to-test.txt'],success:false)
  check(result['status']=='unknown' && !JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),
    'mismatched notes readback blocks distribution')

  project,env,remote,* = make_fixture.call('notes-one-flag',notes:note_text)
  invoke.call(project,env,['--whats-new-locale','en-US'],success:false)
  invoke.call(project,env,['--whats-new-source','App Store/release-notes/what-to-test.txt'],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'one-sided What to Test flags rejected')

  project,env,remote,* = make_fixture.call('notes-outside',notes:note_text)
  invoke.call(project,env,['--whats-new-locale','en-US','--whats-new-source','Config/ownership.yml'],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'outside source path rejected')

  project,env,remote,* = make_fixture.call('notes-symlink',notes:note_text,symlink_notes:true)
  invoke.call(project,env,['--whats-new-locale','en-US','--whats-new-source','App Store/release-notes/what-to-test.txt'],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'symlink source rejected')

  project,env,remote,* = make_fixture.call('notes-too-long',notes:'A'*4001)
  invoke.call(project,env,['--whats-new-locale','en-US','--whats-new-source','App Store/release-notes/what-to-test.txt'],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'oversized What to Test rejected')

  project,env,remote,* = make_fixture.call('notes-control',notes:"A\tB")
  invoke.call(project,env,['--whats-new-locale','en-US','--whats-new-source','App Store/release-notes/what-to-test.txt'],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'control character rejected')

  project,env,remote,* = make_fixture.call('notes-edge-space',notes:"A note\n")
  invoke.call(project,env,['--whats-new-locale','en-US','--whats-new-source','App Store/release-notes/what-to-test.txt'],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'edge whitespace rejected before mutation')

  project,env,remote,* = make_fixture.call('notes-resume',notes:note_text)
  state=JSON.parse(File.binread(remote)); state['ambiguousNotesOnce']=true; File.binwrite(remote,JSON.generate(state))
  first, = invoke.call(project,env,['--whats-new-locale','en-US','--whats-new-source','App Store/release-notes/what-to-test.txt'],success:false)
  check(first['status']=='unknown','ambiguous note response recorded')
  result, = invoke.call(project,env,['--whats-new-locale','en-US','--whats-new-source','App Store/release-notes/what-to-test.txt',
    '--resume-attempt',first['attempt']])
  check(result['status']=='distributed' && JSON.parse(File.binread(remote))['calls'].count('builds test-notes create')==1,
    'notes resume readback avoids duplicate mutation')

  project,env,remote,* = make_fixture.call('resume')
  state=JSON.parse(File.binread(remote)); state['ambiguousOnce']=true; File.binwrite(remote,JSON.generate(state))
  first, = invoke.call(project,env,[],success:false)
  check(first['status']=='unknown','ambiguous response recorded')
  result, = invoke.call(project,env,['--resume-attempt',first['attempt']])
  check(result['status']=='distributed','resume resolves remote membership')
  check(JSON.parse(File.binread(remote))['calls'].count('builds add-groups')==1,'ambiguous add never replayed')

  puts "PASS: TestFlight distribution #{count} fake-runner cases"
end
RUBY
