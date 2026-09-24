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
  make_fixture = lambda do |name, external: false, approval: false, identity_mismatch: false, note_sources: {}|
    project = File.join(scratch, name)
    FileUtils.mkdir_p(project)
    write(project, '.gitignore', ".artifacts/\n")
    write(project, 'Config/app-identity.json', {'schemaVersion'=>1,'sourceIdentityVersion'=>1,
      'displayName'=>'Garden Notes','moduleName'=>'GardenNotes','appSlug'=>'garden-notes','bundleId'=>'com.example.garden'})
    ownership = YAML.safe_load(File.binread(File.join(root,'Config/ownership.yml')), permitted_classes: [], aliases: false)
    ownership['appStore'] = {'teamId'=>'TEAM123456','bundleId'=>identity_mismatch ? 'com.example.other' : 'com.example.garden'}
    write(project, 'Config/ownership.yml', YAML.dump(ownership))
    note_sources.each do |locale, content|
      relative = "App Store/testflight/what-to-test/#{locale}.txt"
      if content == :symlink
        FileUtils.mkdir_p(File.dirname(File.join(project,relative)))
        File.symlink('missing-target.txt',File.join(project,relative))
      else
        write(project,relative,content)
      end
    end
    git(project,'init','-q')
    git(project,'config','user.name','Synthetic Fixture')
    git(project,'config','user.email','fixture@example.invalid')
    git(project,'remote','add','origin','https://github.com/example/distribution-fixture.git')
    git(project,'add','Config','.gitignore')
    git(project,'add','App Store') unless note_sources.empty?
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
      'memberships'=>[],'review'=>[],'notes'=>[],'calls'=>[],'ambiguousOnce'=>false})
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
      whats_new = get.call('--whats-new') || flags.find { |part| part.start_with?('--whats-new=') }&.delete_prefix('--whats-new=')
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
          result = {'buildId'=>remote['buildId'],'appId'=>remote['appId'],'complete'=>true,'lookupMethod'=>'server-filter',
            'groupCount'=>remote['memberships'].length,
            'groups'=>remote['memberships'].map { |id| group=remote['groups'].find { |g| g['id']==id };
              {'id'=>id,'name'=>'tester@example.invalid','type'=>remote['membershipTypeOverride'] || (group['internal'] ? 'internal' : 'external'),
               'membership'=>'explicit','hasAccessToAllBuilds'=>false} }}
          if remote.delete('membershipIncompleteOnce')
            result['complete']=false
            result['failures']=[{'groupId'=>'group-internal','error'=>'fixture relationship incomplete'}]
          end
          result['groups'] << 'invalid row' if remote['nonHashMembership']
          result['groupCount'] = result['groups'].length
          result
        else
          rows = remote['groups'].map { |g| {'type'=>'betaGroups','id'=>g['id'],
            'attributes'=>{'name'=>'tester@example.invalid','isInternalGroup'=>g['internal']}} }
          rows << 'invalid row' if remote['nonHashGroup']
          {'data'=>rows}
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
      when 'builds test-notes list'
        locale = get.call('--locale')
        rows = remote['notes'].select { |row| row.is_a?(Hash) && row['locale']==locale }.map { |row|
          {'type'=>'betaBuildLocalizations','id'=>row['id'],
           'attributes'=>{'locale'=>row['locale'],'whatsNew'=>row['text']}} }
        rows << 'invalid row' if remote['nonHashNotes']
        {'data'=>rows}
      when 'builds test-notes view'
        row = remote['notes'].find { |entry| entry.is_a?(Hash) && entry['locale']==get.call('--locale') }
        {'data'=>row && {'type'=>'betaBuildLocalizations','id'=>row['id'],
          'attributes'=>{'locale'=>row['locale'],'whatsNew'=>remote['notesViewMismatch'] ? 'remote mismatch' : row['text']}}}
      when 'builds test-notes create'
        abort 'missing what to test text' unless whats_new
        row = remote['notes'].find { |entry| entry.is_a?(Hash) && entry['locale']==get.call('--locale') }
        unless remote['notesCreateNoWrite']
          if row then row['text']=whats_new
          else remote['notes'] << {'id'=>"note-#{get.call('--locale')}",'locale'=>get.call('--locale'),'text'=>whats_new}
          end
        end
        if remote.delete('notesCreateFailure')
          File.binwrite(path,JSON.generate(remote))
          exit 9
        end
        {'data'=>{'type'=>'betaBuildLocalizations','id'=>row ? row['id'] : "note-#{get.call('--locale')}"}}
      when 'testflight review submissions list'
        rows = remote['review'].map { |state| {'type'=>'betaAppReviewSubmissions','id'=>'review-1',
          'attributes'=>{'betaReviewState'=>state}} }
        rows << 'invalid row' if remote['nonHashReview']
        {'data'=>rows}
      when 'testflight review submit'
        remote['review'] = ['WAITING_FOR_REVIEW']
        {'data'=>{'type'=>'betaAppReviewSubmissions','id'=>'review-1',
          'attributes'=>{'betaReviewState'=>'WAITING_FOR_REVIEW'}}}
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

  project,env,remote,* = make_fixture.call('incomplete-membership')
  state=JSON.parse(File.binread(remote)); state['membershipIncompleteOnce']=true; File.binwrite(remote,JSON.generate(state))
  result, = invoke.call(project,env,[],success:false)
  check(result['status']=='blocked' && result['reason']=='membership-unavailable' &&
    !JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),
    'incomplete membership readback blocks group assignment')

  project,env,remote,* = make_fixture.call('group-type-mismatch')
  state=JSON.parse(File.binread(remote)); state['memberships']=['group-internal']; state['membershipTypeOverride']='external'
  File.binwrite(remote,JSON.generate(state))
  invoke.call(project,env,[],success:false)
  check(!JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),'group type mismatch rejected')

  project,env,remote,* = make_fixture.call('duplicate-input')
  invoke.call(project,env,['--group','group-internal'],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'duplicate input group rejected')

  project,env,remote,* = make_fixture.call('notes-unavailable')
  invoke.call(project,env,['--whats-new-locale','en-US','--whats-new-source','App Store/release-notes/notes.md'],success:false)
  check(JSON.parse(File.binread(remote))['calls'].empty?,'What to Test options are not accepted')

  project,env,remote,* = make_fixture.call('resume')
  state=JSON.parse(File.binread(remote)); state['ambiguousOnce']=true; File.binwrite(remote,JSON.generate(state))
  first, = invoke.call(project,env,[],success:false)
  check(first['status']=='unknown','ambiguous response recorded')
  result, = invoke.call(project,env,['--resume-attempt',first['attempt']])
  check(result['status']=='distributed','resume resolves remote membership')
  check(JSON.parse(File.binread(remote))['calls'].count('builds add-groups')==1,'ambiguous add never replayed')

  note_option = ['--what-to-test-locale','en-US']
  project,env,remote,* = make_fixture.call('notes-create',note_sources:{'en-US'=>"Try the new flow\n"})
  result, = invoke.call(project,env,note_option)
  state = JSON.parse(File.binread(remote))
  check(result['status']=='distributed' && state['notes']==[{'id'=>'note-en-US','locale'=>'en-US','text'=>'Try the new flow'}],
    'one terminal LF removed and note created')
  check(state['calls'].index('builds test-notes list') < state['calls'].index('builds test-notes create') &&
    state['calls'].index('builds test-notes view') < state['calls'].index('builds add-groups'),
    'notes readback precedes group assignment')
  events = Dir.glob(File.join(project,'.artifacts/appstore-testflight/42',result.fetch('attempt'),'*.json')).sort.map { |path| JSON.parse(File.binread(path)) }
  check(events.map { |event| event['eventType'] }.include?('notes-intent') &&
    events.map { |event| event['eventType'] }.include?('notes-readback') &&
    events.first['whatToTestSources']==[{'locale'=>'en-US','digest'=>"sha256:#{Digest::SHA256.hexdigest('Try the new flow')}"}],
    'started binds locale and digest')
  check(events.none? { |event| JSON.generate(event).include?('Try the new flow') },'journal stores digest only')
  calls_before = state['calls'].length
  event_count = events.length
  refused, = invoke.call(project,env,note_option+['--resume-attempt',result.fetch('attempt')],success:false)
  check(refused['reason']=='attempt-already-complete' && JSON.parse(File.binread(remote))['calls'].length==calls_before &&
    Dir.glob(File.join(project,'.artifacts/appstore-testflight/42',result.fetch('attempt'),'*.json')).length==event_count,
    'completed attempt refuses with no asc call or event')

  project,env,remote,* = make_fixture.call('notes-same',note_sources:{'en-US'=>'Already published'})
  state=JSON.parse(File.binread(remote)); state['notes']=[{'id'=>'note-old','locale'=>'en-US','text'=>'Already published'}]; File.binwrite(remote,JSON.generate(state))
  result, = invoke.call(project,env,note_option)
  check(result['status']=='distributed' && !JSON.parse(File.binread(remote))['calls'].include?('builds test-notes create'),
    'matching note uses view without write')

  project,env,remote,* = make_fixture.call('notes-upsert',note_sources:{'en-US'=>'Replacement'})
  state=JSON.parse(File.binread(remote)); state['notes']=[{'id'=>'note-old','locale'=>'en-US','text'=>'Old note'}]; File.binwrite(remote,JSON.generate(state))
  result, = invoke.call(project,env,note_option)
  state=JSON.parse(File.binread(remote))
  check(result['status']=='distributed' && state['notes'].first['text']=='Replacement' &&
    state['calls'].include?('builds test-notes create'),'create upserts existing note')

  project,env,remote,* = make_fixture.call('notes-leading-hyphen',note_sources:{'en-US'=>'-Try this flow'})
  result, = invoke.call(project,env,note_option)
  check(result['status']=='distributed' && JSON.parse(File.binread(remote))['notes'].first['text']=='-Try this flow',
    'leading hyphen remains note text')

  project,env,remote,* = make_fixture.call('notes-two',note_sources:{'en-US'=>'English note','ja'=>'日本語の案内'})
  result, = invoke.call(project,env,['--what-to-test-locale','ja']+note_option)
  events = Dir.glob(File.join(project,'.artifacts/appstore-testflight/42',result.fetch('attempt'),'*.json')).sort.map { |path| JSON.parse(File.binread(path)) }
  check(result['status']=='distributed' && events.first['whatToTestSources'].map { |row| row['locale'] }==%w[en-US ja] &&
    events.select { |event| event['eventType']=='notes-intent' }.map { |event| event['locale'] }==%w[en-US ja],
    'two locales are processed in sorted order')

  project,env,remote,* = make_fixture.call('notes-resume-input-mismatch',note_sources:{'en-US'=>'English','ja'=>'日本語'})
  state=JSON.parse(File.binread(remote)); state['notesCreateFailure']=true; File.binwrite(remote,JSON.generate(state))
  first, = invoke.call(project,env,note_option,success:false)
  calls_before = JSON.parse(File.binread(remote))['calls'].length
  result, = invoke.call(project,env,['--what-to-test-locale','ja','--resume-attempt',first.fetch('attempt')],success:false)
  check(result['reason']=='attempt-context-mismatch' && JSON.parse(File.binread(remote))['calls'].length==calls_before,
    'resume requires the same locale and source digest pair')

  project,env,remote,* = make_fixture.call('notes-mismatch',note_sources:{'en-US'=>'Expected'})
  state=JSON.parse(File.binread(remote)); state['notesViewMismatch']=true; File.binwrite(remote,JSON.generate(state))
  result, = invoke.call(project,env,note_option,success:false)
  check(result['status']=='unknown' && !JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),
    'mismatched readback is unknown before assignment')

  project,env,remote,* = make_fixture.call('notes-existing-mismatch',note_sources:{'en-US'=>'Expected'})
  state=JSON.parse(File.binread(remote)); state['notes']=[{'id'=>'note-old','locale'=>'en-US','text'=>'Expected'}]
  state['notesViewMismatch']=true; File.binwrite(remote,JSON.generate(state))
  result, = invoke.call(project,env,note_option,success:false)
  state=JSON.parse(File.binread(remote))
  check(result['status']=='unknown' && !state['calls'].include?('builds test-notes create') &&
    !state['calls'].include?('builds add-groups'),'matching list still requires exact view')

  project,env,remote,* = make_fixture.call('notes-ambiguous-list',note_sources:{'en-US'=>'Expected'})
  state=JSON.parse(File.binread(remote)); state['notes']=[
    {'id'=>'note-one','locale'=>'en-US','text'=>'Old one'},
    {'id'=>'note-two','locale'=>'en-US','text'=>'Old two'}]; File.binwrite(remote,JSON.generate(state))
  result, = invoke.call(project,env,note_option,success:false)
  check(result['status']=='unknown' && !JSON.parse(File.binread(remote))['calls'].include?('builds add-groups'),
    'ambiguous notes list is unknown without assignment')

  project,env,remote,* = make_fixture.call('notes-resume',note_sources:{'en-US'=>'Resumable'})
  state=JSON.parse(File.binread(remote)); state['notesCreateFailure']=true; File.binwrite(remote,JSON.generate(state))
  first, = invoke.call(project,env,note_option,success:false)
  check(first['status']=='unknown','failed create is unknown')
  result, = invoke.call(project,env,note_option+['--resume-attempt',first.fetch('attempt')])
  state=JSON.parse(File.binread(remote))
  check(result['status']=='distributed' && state['calls'].count('builds test-notes create')==1,
    'resume reads matching note without resending create')

  project,env,remote,* = make_fixture.call('notes-resume-mismatch',note_sources:{'en-US'=>'Expected'})
  state=JSON.parse(File.binread(remote)); state['notesCreateNoWrite']=true; File.binwrite(remote,JSON.generate(state))
  first, = invoke.call(project,env,note_option,success:false)
  second, = invoke.call(project,env,note_option+['--resume-attempt',first.fetch('attempt')],success:false)
  state=JSON.parse(File.binread(remote))
  check(first['status']=='unknown' && second['status']=='unknown' && state['calls'].count('builds test-notes create')==1 &&
    !state['calls'].include?('builds add-groups'),'resume mismatch remains unknown without resend')

  {'unknown-locale'=>[['--what-to-test-locale','fr'],{}],
   'duplicate-locale'=>[note_option+note_option,{'en-US'=>'Valid'}],
   'missing-source'=>[note_option,{}],
   'symlink-source'=>[note_option,{'en-US'=>:symlink}],
   'cr-source'=>[note_option,{'en-US'=>"bad\rtext"}],
   'control-source'=>[note_option,{'en-US'=>"bad\ttext"}],
   'c1-control-source'=>[note_option,{'en-US'=>"bad\u0085text"}],
   'edge-source'=>[note_option,{'en-US'=>' leading'}],
   'trailing-source'=>[note_option,{'en-US'=>'trailing '}],
   'oversized-source'=>[note_option,{'en-US'=>'A'*4001}],
   'empty-source'=>[note_option,{'en-US'=>"\n"}],
   'double-lf-source'=>[note_option,{'en-US'=>"text\n\n"}]}.each do |name,(args,sources)|
    project,env,remote,* = make_fixture.call(name,note_sources:sources)
    result, = invoke.call(project,env,args,success:false)
    check(result['status']=='blocked' && JSON.parse(File.binread(remote))['calls'].empty?,
      "#{name} refused before any asc call")
  end

  {'nonhash-group'=>['nonHashGroup','remote-groups-unavailable',false],
   'nonhash-membership'=>['nonHashMembership','membership-unavailable',false],
   'nonhash-review'=>['nonHashReview','beta-review-readback-unavailable',true],
   'nonhash-notes'=>['nonHashNotes','what-to-test-list-unavailable',false]}.each do |name,(flag,reason,external)|
    sources = name=='nonhash-notes' ? {'en-US'=>'Valid note'} : {}
    project,env,remote,* = make_fixture.call(name,external:external,note_sources:sources)
    state=JSON.parse(File.binread(remote)); state[flag]=true; File.binwrite(remote,JSON.generate(state))
    args = name=='nonhash-notes' ? note_option : external ? ['--group','group-external'] : []
    result, = invoke.call(project,env,args,success:false)
    check(result['status']=='blocked' && result['reason']==reason,"#{name} gives specific blocked result")
  end

  puts "PASS: TestFlight distribution #{count} fake-runner cases"
end
RUBY
