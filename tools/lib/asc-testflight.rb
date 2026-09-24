#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'
require 'securerandom'
require 'open3'
require 'optparse'
require_relative 'appstore-build'

module IOSTemplate
  module AscTestFlight
    class Refused < StandardError; end
    module_function

    Base = AppStoreBuild
    RECORD = 'appstore-testflight-distribution'
    OPERATION = 'appstore.distribute_testflight'
    SHA = /\A[0-9a-f]{40}\z/
    ID = /\A[A-Za-z0-9_-]{1,128}\z/
    ATTEMPT = /\Aa[0-9a-f]{24}\z/
    APPROVAL = %r{\Aapproval: user-approval://[a-z0-9-]{1,128}\z}
    EVENTS = %w[started build-readback notes-intent notes-readback group-intent group-readback review-intent review-readback distribution-result].freeze
    TEST_KEYS = %w[IOS_TEMPLATE_TEST_ASC_RUNNER IOS_TEMPLATE_TEST_OPERATION_DETAIL].freeze
    TOOL_ROOT = File.expand_path('../..', __dir__)

    def refuse(reason)
      raise Refused, reason
    end

    def canonical(value)
      Base.canonical(value)
    end

    def digest(value)
      Base.digest(value)
    end

    def bytes(root, relative, limit=1_000_000)
      Base.regular_bytes(root,relative,limit)
    end

    def document(root, relative, limit=1_000_000)
      Base.document(root,relative,limit)
    end

    def validate_options!(options)
      refuse('invalid-project-root') unless options[:root].is_a?(String)
      refuse('invalid-issue') unless options[:issue].is_a?(Integer) && options[:issue].positive?
      refuse('invalid-version') unless options[:version].is_a?(String) && options[:version].match?(Base::VERSION)
      refuse('invalid-build-number') unless options[:build].is_a?(String) && options[:build].match?(Base::BUILD)
      groups = options[:groups]
      refuse('missing-or-duplicate-group-id') unless groups.is_a?(Array) && !groups.empty? && groups.uniq == groups &&
        groups.all? { |group| group.match?(ID) }
      refuse('invalid-resume-attempt') if options[:resume] && !options[:resume].match?(ATTEMPT)
      refuse('invalid-approval') if options[:approval] && !options[:approval].match?(APPROVAL)
      refuse('approval-without-beta-review') if options[:approval] && !options[:submit]
      refuse('what-to-test-flags-must-be-paired') unless options.key?(:notes_locale) == options.key?(:notes_source)
      if options.key?(:notes_locale)
        refuse('invalid-what-to-test-locale') unless %w[en-US ja].include?(options[:notes_locale])
        source = options[:notes_source]
        refuse('invalid-what-to-test-source-path') unless source.is_a?(String) &&
          source.start_with?('App Store/release-notes/') &&
          source != 'App Store/release-notes/' && source.bytesize <= 1024 &&
          source.split('/').none? { |part| part.empty? || part == '.' || part == '..' }
      end
    end

    def notes_source(root, options)
      return nil unless options.key?(:notes_source)
      source = options.fetch(:notes_source)
      text = bytes(root,source,16_384)
      refuse('invalid-what-to-test-text') unless !text.empty? &&
        text.length <= 4000 && text.encode(Encoding::UTF_16BE).bytesize / 2 <= 4000 &&
        !text.match?(/[\x00-\x09\x0b-\x1f\x7f]/)
      # asc 5.4.0 trims --whats-new before its API request. Reject edge
      # whitespace rather than silently sending bytes unlike the source file.
      refuse('what-to-test-edge-whitespace-cannot-readback-exactly') unless text == text.strip
      {locale:options.fetch(:notes_locale),text:text,digest:"sha256:#{Digest::SHA256.hexdigest(text)}"}
    end

    def operation_detail(root, contract, issue, executor)
      if ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
        path = ENV.fetch('IOS_TEMPLATE_TEST_OPERATION_DETAIL')
        AscCLI.physical_path!(path)
        detail = JSON.parse(AscCLI.read_regular(path,16_384), object_class: AppStorePreparation::UniqueObject)
      else
        refuse('github-read-not-declared') unless contract.fetch('externalOperations').include?('github.read_issue')
        gh = %w[/opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh].find { |candidate| File.file?(candidate) && File.executable?(candidate) }
        refuse('github-reader-unavailable') unless gh
        command = ['/usr/bin/ruby','--disable-gems',File.join(__dir__,'bounded-command.rb'),
          '--stage','asc-testflight-issue-read','--timeout-seconds','30','--grace-seconds','1','--',
          gh,'issue','view',issue.to_s,'--repo',contract.fetch('repository'),'--json','body,labels,state']
        output, _error, status = Open3.capture3({'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8'},*command)
        refuse('live-issue-unavailable') unless status.success? && output.bytesize <= 1_000_000
        live = JSON.parse(output, object_class: AppStorePreparation::UniqueObject)
        labels = live.fetch('labels').map { |item| item.fetch('name') }
        types = labels.grep(/\Atype:(?:feature|regression|docs|release)\z/).map { |label| label.delete_prefix('type:') }
        refuse('live-issue-state-mismatch') unless live['state'] == 'OPEN' && labels.include?('state:in-progress') && types.length == 1
        parsed = IssueContract.parse(live.fetch('body'), issue_type:types.first, issue:issue,
          repository:contract.fetch('repository'), fetched_at:contract.fetch('fetchedAt'),
          allow_legacy_delivery_stage:!contract.key?('deliveryStage'))
        refuse('live-issue-contract-drift') unless parsed.contract == contract
        detail = parsed.external_operation_details.find { |entry| entry['operation'] == OPERATION }
      end
      refuse('operation-detail-mismatch') unless detail.is_a?(Hash) &&
        detail.keys.sort == %w[approvalReference approvalRequired environment executor operation service] &&
        detail['operation'] == OPERATION && detail['service'] == 'App Store Connect' &&
        detail['environment'] == 'production' && detail['executor'] == executor.capitalize &&
        [true,false].include?(detail['approvalRequired']) &&
        (detail['approvalRequired'] ? detail['approvalReference'].to_s.match?(APPROVAL) : detail['approvalReference'].nil?)
      detail
    end

    def authority(root, issue, identity, now)
      prefix = ".artifacts/issues/#{issue}"
      contract_relative = "#{prefix}/issue-contract.json"
      contract_bytes = bytes(root,contract_relative)
      contract = JSON.parse(contract_bytes, object_class: AppStorePreparation::UniqueObject)
      IssueContract.validate_snapshot!(contract,issue:issue,repository:contract.fetch('repository'))
      state = document(root,"#{prefix}/state.json",100_000)
      contract_digest = "sha256:#{Digest::SHA256.hexdigest(contract_bytes)}"
      refuse('issue-contract-unsealed') unless state['issue'] == issue && state['state'] == 'in-progress' &&
        %w[codex claude].include?(state['executor']) && state.dig('issueContract','path') == contract_relative &&
        state.dig('issueContract','digest') == contract_digest && contract.fetch('externalOperations').include?(OPERATION)
      refuse('release-contract-required') unless contract.dig('deliveryStage','name') == 'release' &&
        contract.dig('deliveryProfile','name') == 'strict' && contract.dig('verificationScope','name') == 'full'
      ownership = Ownership.provider_identity!(Ownership.parse(bytes(root,'Config/ownership.yml',100_000)),'app-store')
      refuse('configured-identity-mismatch') unless ownership['account'].to_s.match?(/\A[A-Z0-9]{10}\z/) &&
        ownership['target'] == identity.fetch('bundleId')
      preflight = document(root,"#{prefix}/provider-preflights/app-store-distribute_testflight.json",100_000)
      expected = {'schemaVersion'=>2,'issue'=>issue,'executor'=>state['executor'],'provider'=>'app-store',
        'account'=>ownership['account'],'target'=>identity.fetch('bundleId'),'environment'=>'production',
        'operation'=>OPERATION,'health'=>'healthy'}
      checked = Base.time(preflight['checkedAt'])
      refuse('preflight-missing-stale-or-mismatch') unless Base.exact(preflight,Base::PREFLIGHT_KEYS) &&
        expected.all? { |key,value| preflight[key] == value } &&
        preflight['digest'] == digest(preflight.reject { |key,_| key == 'digest' }) &&
        checked && (now-checked).between?(0,3600)
      detail = operation_detail(root,contract,issue,state['executor'])
      {team:ownership['account'],bundle:identity.fetch('bundleId'),head:Base.git(root,'rev-parse','HEAD'),
        contract_digest:contract_digest,preflight_digest:preflight['digest'],detail:detail}
    end

    def build_journal(root, issue, head, version, build, authority)
      parent = Base.safe_path(root,".artifacts/appstore-builds/#{issue}")
      Base.safe_directory(parent)
      matches = []
      Dir.children(parent).sort.each do |name|
        next unless name.match?(ATTEMPT)
        directory = File.join(parent,name)
        stat = File.lstat(directory)
        refuse('unsafe-build-journal') unless stat.directory? && !stat.symlink? && stat.uid == Process.uid &&
          stat.mode & 0777 == 0700
        names = Dir.children(directory).grep(/\A[0-9]{4}-.+\.json\z/).sort
        next if names.empty?
        refuse('build-journal-event-name-invalid') unless names.all? { |event| event.match?(/\A[0-9]{4}-(?:started|archive-complete|export-complete|upload-intent|upload-result|processing-readback|stage-failed)\.json\z/) }
        previous = nil
        events = names.each_with_index.map do |event_name,index|
          raw = Base.read_owned_file(File.join(directory,event_name),100_000)
          event = JSON.parse(raw, object_class: AppStorePreparation::UniqueObject)
          refuse('build-journal-chain-invalid') unless event['recordType'] == 'appstore-build-upload' &&
            event['schemaVersion'] == 1 && event['issue'] == issue && event['attempt'] == name &&
            event['eventSequence'] == index+1 && event['previousEventDigest'] == previous &&
            event_name == format('%04d-%s.json',index+1,event['eventType']) &&
            raw == JSON.generate(canonical(event))+"\n" && Base.time(event['checkedAt'])
          previous = "sha256:#{Digest::SHA256.hexdigest(raw)}"
          event
        end
        next unless events.all? { |event| event.values_at('headSha','version','buildNumber','bundleId','contractDigest') ==
          [head,version,build,authority[:bundle],authority[:contract_digest]] }
        start = events.first
        export = events.find { |event| event['eventType'] == 'export-complete' }
        upload = events.find { |event| event['eventType'] == 'upload-result' }
        last = events.last
        next unless start['eventType'] == 'started' && start['teamId'] == authority[:team] &&
          start['preflightDigest'].to_s.match?(/\Asha256:[0-9a-f]{64}\z/) &&
          export && export['ipaDigest'].to_s.match?(/\Asha256:[0-9a-f]{64}\z/) &&
          events.any? { |event| event['eventType'] == 'upload-intent' } &&
          (!upload || %w[accepted unknown].include?(upload['status'])) &&
          (!upload || upload['status'] != 'accepted' ||
            upload['uploadId'].to_s.match?(ID) && upload['fileId'].to_s.match?(ID)) &&
          events.all? { |event| !event.key?('ipaDigest') || event['ipaDigest'] == export['ipaDigest'] } &&
          last['eventType'] == 'processing-readback' && last['processingState'] == 'VALID' &&
          last.values_at('version','buildNumber','platform') == [version,build,'IOS'] && last['buildId'].to_s.match?(ID)
        matches << {build_id:last['buildId'],digest:previous,attempt:name}
      end
      refuse('build-journal-not-unique-valid-for-issue') unless matches.length == 1
      matches.first
    end

    def runner
      return File.join(TOOL_ROOT,'tools/asc-run.sh') unless ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
      path = ENV.fetch('IOS_TEMPLATE_TEST_ASC_RUNNER')
      Base.executable!(path)
    end

    def asc(runner_path, *command)
      args = ['--operation',OPERATION,'--',*command,'--output','json']
      AscCLI.command_arguments(args)
      env = {'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8','HOME'=>ENV.fetch('HOME')}
      output, _error, status = Open3.capture3(env,runner_path,*args,unsetenv_others:true)
      refuse('asc-output-too-large') if output.bytesize > 1_048_576
      output.force_encoding(Encoding::UTF_8)
      refuse('asc-output-invalid') unless output.valid_encoding? && !output.include?("\0")
      parsed = JSON.parse(output, object_class: AppStorePreparation::UniqueObject) unless output.empty?
      [parsed,status.exitstatus || 1]
    rescue JSON::ParserError, AppStorePreparation::InvalidInput
      [nil,1]
    end

    def app_and_build(runner_path, bundle, version, build, expected_id)
      response, code = asc(runner_path,'apps','list','--bundle-id',bundle)
      refuse('remote-app-unavailable') unless code.zero? && Base.full_list?(response) && response['data'].length == 1
      item = response['data'].first
      refuse('remote-app-mismatch') unless item['type'] == 'apps' && item['id'].to_s.match?(/\A[1-9][0-9]*\z/) &&
        item.dig('attributes','bundleId') == bundle
      app_id = item['id']
      response, code = asc(runner_path,'builds','list','--app',app_id,'--version',version,'--build-number',build,'--platform','IOS','--paginate')
      refuse('remote-build-unavailable') unless code.zero? && Base.full_list?(response) && response['data'].length == 1
      row = response['data'].first
      refuse('remote-build-mismatch') unless row['type'] == 'builds' && row['id'] == expected_id &&
        row.dig('attributes','version') == build
      response, code = asc(runner_path,'builds','info','--app',app_id,'--version',version,'--build-number',build,'--platform','IOS')
      refuse('remote-build-info-unavailable') unless code.zero? && response.is_a?(Hash)
      row = response['data']
      included = response['included']
      relation = row.dig('relationships','preReleaseVersion','data') if row.is_a?(Hash)
      refuse('remote-build-not-valid') unless row.is_a?(Hash) && row['type'] == 'builds' && row['id'] == expected_id &&
        row.dig('attributes','version') == build && row.dig('attributes','processingState') == 'VALID' &&
        relation.is_a?(Hash) && relation['type'] == 'preReleaseVersions' && included.is_a?(Array) && included.length == 1 &&
        included.first['type'] == 'preReleaseVersions' && included.first['id'] == relation['id'] &&
        included.first.dig('attributes','version') == version && included.first.dig('attributes','platform') == 'IOS'
      app_id
    end

    def groups(runner_path, app_id, selected)
      response, code = asc(runner_path,'testflight','groups','list','--app',app_id,'--paginate')
      refuse('remote-groups-unavailable') unless code.zero? && Base.full_list?(response)
      selected.to_h do |id|
        rows = response['data'].select { |entry| entry.is_a?(Hash) && entry['id'] == id }
        refuse('remote-group-missing-or-ambiguous') unless rows.length == 1 && rows.first['type'] == 'betaGroups' &&
          [true,false].include?(rows.first.dig('attributes','isInternalGroup'))
        [id,rows.first.dig('attributes','isInternalGroup') ? 'internal' : 'external']
      end
    end

    def membership(runner_path, app_id, build_id, group_types)
      response, code = asc(runner_path,'testflight','groups','list','--app',app_id,'--build-id',build_id)
      refuse('membership-unavailable') unless code.zero? && response.is_a?(Hash) && response['complete'] == true &&
        response['buildId'] == build_id && response['appId'] == app_id && response['groups'].is_a?(Array) &&
        response['groupCount'] == response['groups'].length && response['failures'] == []
      ids = response['groups'].map { |entry| entry['id'] }
      refuse('membership-ambiguous') unless ids.all? { |id| id.to_s.match?(ID) } && ids.uniq == ids
      group_types.to_h do |id,type|
        row = response['groups'].find { |entry| entry['id'] == id }
        refuse('membership-type-mismatch') if row && (row['type'] != type ||
          !%w[explicit all-builds explicit-and-all-builds].include?(row['membership']))
        [id,!row.nil?]
      end
    end

    def review_state(runner_path, build_id)
      response, code = asc(runner_path,'testflight','review','submissions','list','--build-id',build_id,'--paginate')
      refuse('beta-review-readback-unavailable') unless code.zero? && Base.full_list?(response) && response['data'].length <= 1
      return nil if response['data'].empty?
      row = response['data'].first
      state = row.dig('attributes','betaReviewState') if row.is_a?(Hash)
      refuse('beta-review-state-ambiguous') unless row['type'] == 'betaAppReviewSubmissions' && row['id'].to_s.match?(ID) &&
        state.is_a?(String) && state.match?(/\A[A-Z][A-Z_]{1,63}\z/)
      state
    end

    def notes_list(runner_path, build_id, locale)
      response, code = asc(runner_path,'builds','test-notes','list','--build-id',build_id,
        '--locale',locale,'--paginate')
      refuse('what-to-test-list-unavailable') unless code.zero? && Base.full_list?(response) && response['data'].length <= 1
      return nil if response['data'].empty?
      row = response['data'].first
      refuse('what-to-test-list-ambiguous') unless row.is_a?(Hash) && row['type'] == 'betaBuildLocalizations' &&
        row['id'].to_s.match?(ID) && row.dig('attributes','locale') == locale &&
        row.dig('attributes','whatsNew').is_a?(String)
      {id:row['id'],text:row.dig('attributes','whatsNew')}
    end

    def notes_view(runner_path, build_id, locale, expected_id=nil)
      response, code = asc(runner_path,'builds','test-notes','view','--build-id',build_id,'--locale',locale)
      refuse('what-to-test-readback-unavailable') unless code.zero? && response.is_a?(Hash)
      row = response['data']
      refuse('what-to-test-readback-ambiguous') unless row.is_a?(Hash) && row['type'] == 'betaBuildLocalizations' &&
        row['id'].to_s.match?(ID) && (!expected_id || row['id'] == expected_id) &&
        row.dig('attributes','locale') == locale && row.dig('attributes','whatsNew').is_a?(String)
      row.dig('attributes','whatsNew')
    end

    def apply_notes(context, entries, runner_path, notes)
      locale = notes.fetch(:locale)
      source = notes.fetch(:text)
      current = notes_list(runner_path,context[:build_id],locale)
      if current && current.fetch(:text) == source
        observed = notes_view(runner_path,context[:build_id],locale,current.fetch(:id))
        refuse('what-to-test-readback-mismatch') unless observed == source
        append_event(context,'notes-readback','locale'=>locale,'readbackDigest'=>notes.fetch(:digest))
        return true
      end
      return false if entries.any? { |event| event['eventType'] == 'notes-intent' }
      append_event(context,'notes-intent','locale'=>locale,'sourceDigest'=>notes.fetch(:digest))
      command = current ? 'update' : 'create'
      _response, code = asc(runner_path,'builds','test-notes',command,'--build-id',context[:build_id],
        '--locale',locale,'--whats-new',source)
      return false unless code.zero?
      begin
        observed = notes_view(runner_path,context[:build_id],locale,current && current.fetch(:id))
        return false unless observed == source
      rescue Refused
        return false
      end
      append_event(context,'notes-readback','locale'=>locale,'readbackDigest'=>notes.fetch(:digest))
      true
    end

    def append_event(context, type, fields={})
      refuse('invalid-event-type') unless EVENTS.include?(type)
      context[:sequence] += 1
      event = {'schemaVersion'=>1,'recordType'=>RECORD,'eventType'=>type,'eventSequence'=>context[:sequence],
        'previousEventDigest'=>context[:last_digest],'issue'=>context[:issue],'attempt'=>context[:attempt],
        'headSha'=>context[:head],'version'=>context[:version],'buildNumber'=>context[:build],
        'buildId'=>context[:build_id],'contractDigest'=>context[:contract_digest],
        'checkedAt'=>Time.now.utc.iso8601}.merge(fields)
      raw = JSON.generate(canonical(event))+"\n"
      Base.write_new(File.join(context[:directory],format('%04d-%s.json',context[:sequence],type)),raw)
      context[:last_digest] = "sha256:#{Digest::SHA256.hexdigest(raw)}"
      event
    end

    def attempt(root, issue, authority, build_journal, options)
      parent = Base.safe_path(root,".artifacts/appstore-testflight/#{issue}")
      Base.safe_directory(parent)
      if options[:resume]
        name = options[:resume]
        directory = Base.safe_path(root,".artifacts/appstore-testflight/#{issue}/#{name}")
        stat = File.lstat(directory)
        refuse('unsafe-attempt') unless stat.directory? && stat.uid == Process.uid && stat.mode & 0777 == 0700
        names = Dir.children(directory).sort
        refuse('unsafe-attempt-contents') unless !names.empty? && names.all? { |event| event.match?(/\A[0-9]{4}-(?:started|build-readback|notes-intent|notes-readback|group-intent|group-readback|review-intent|review-readback|distribution-result)\.json\z/) }
        previous = nil
        entries = names.each_with_index.map do |event_name,index|
          raw = Base.read_owned_file(File.join(directory,event_name),100_000)
          event = JSON.parse(raw, object_class: AppStorePreparation::UniqueObject)
          refuse('attempt-history-mismatch') unless event['recordType'] == RECORD && event['schemaVersion'] == 1 &&
            event['eventSequence'] == index+1 && event['previousEventDigest'] == previous &&
            event_name == format('%04d-%s.json',index+1,event['eventType']) &&
            event.values_at('issue','attempt','headSha','version','buildNumber','buildId','contractDigest') ==
              [issue,name,authority[:head],options[:version],options[:build],build_journal[:build_id],authority[:contract_digest]] &&
            raw == JSON.generate(canonical(event))+"\n" && Base.time(event['checkedAt'])
          previous = "sha256:#{Digest::SHA256.hexdigest(raw)}"
          event
        end
        started = entries.first
        refuse('attempt-context-mismatch') unless started['eventType'] == 'started' &&
          started['groupIds'] == options[:groups] && started['buildJournalDigest'] == build_journal[:digest] &&
          started['notesLocale'] == options[:notes]&.fetch(:locale) &&
          started['notesDigest'] == options[:notes]&.fetch(:digest)
        context = {directory:directory,attempt:name,sequence:entries.length,last_digest:previous,issue:issue,
          head:authority[:head],version:options[:version],build:options[:build],build_id:build_journal[:build_id],
          contract_digest:authority[:contract_digest]}
        [context,entries]
      else
        name = "a#{SecureRandom.hex(12)}"
        directory = File.join(parent,name)
        Dir.mkdir(directory,0700)
        context = {directory:directory,attempt:name,sequence:0,last_digest:nil,issue:issue,
          head:authority[:head],version:options[:version],build:options[:build],build_id:build_journal[:build_id],
          contract_digest:authority[:contract_digest]}
        started = append_event(context,'started','groupIds'=>options[:groups],
          'buildJournalDigest'=>build_journal[:digest],'preflightDigest'=>authority[:preflight_digest],
          'notesLocale'=>options[:notes]&.fetch(:locale),'notesDigest'=>options[:notes]&.fetch(:digest))
        [context,[started]]
      end
    end

    def execute(options)
      validate_options!(options)
      root = Base.safe_root(options[:root])
      options[:notes] = notes_source(root,options)
      test_mode = ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
      refuse('tool-project-root-mismatch') unless test_mode || root == TOOL_ROOT
      overrides = ENV.keys.select { |key| key.start_with?('IOS_TEMPLATE_TEST_') }
      refuse('test-overrides-in-production') unless test_mode || overrides.empty?
      refuse('unknown-test-override') unless (overrides - TEST_KEYS - ['IOS_TEMPLATE_TEST_MODE']).empty?
      Base.clean_head(root,Base.git(root,'rev-parse','HEAD'))
      identity = Base.identity(root)
      authority_value = authority(root,options[:issue],identity,Time.now.utc)
      journal = build_journal(root,options[:issue],authority_value[:head],options[:version],options[:build],authority_value)
      runner_path = runner
      Base.safe_directory(Base.safe_path(root,'.artifacts/appstore-testflight'))
      parent = Base.safe_path(root,".artifacts/appstore-testflight/#{options[:issue]}")
      Base.safe_directory(parent)
      lock_path = File.join(parent,'.distribution.lock')
      File.open(lock_path,File::RDWR|File::CREAT|File::NOFOLLOW,0600) do |lock|
        stat = lock.stat
        refuse('unsafe-distribution-lock') unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid && stat.mode & 0777 == 0600
        refuse('distribution-already-active') unless lock.flock(File::LOCK_EX|File::LOCK_NB)
        app_id = app_and_build(runner_path,authority_value[:bundle],options[:version],options[:build],journal[:build_id])
        group_types = groups(runner_path,app_id,options[:groups])
        external = group_types.values.include?('external')
        if options[:submit]
          refuse('beta-review-requires-external-group') unless external
          detail = authority_value[:detail]
          refuse('beta-review-approval-not-declared') unless detail['approvalRequired'] && options[:approval] &&
            detail['approvalReference'] == options[:approval]
        end
        context,entries = attempt(root,options[:issue],authority_value,journal,options)
        append_event(context,'build-readback','readbackDigest'=>digest({'appId'=>app_id,
          'buildId'=>journal[:build_id],'version'=>options[:version],
          'buildNumber'=>options[:build],'processingState'=>'VALID'}))
        if options[:notes] && !apply_notes(context,entries,runner_path,options[:notes])
          return {'status'=>'unknown','attempt'=>context[:attempt],'betaReviewState'=>'unknown','releaseReady'=>false}
        end
        options[:groups].each do |id|
          state = membership(runner_path,app_id,journal[:build_id],{id=>group_types.fetch(id)})
          if state.fetch(id)
            append_event(context,'group-readback','groupId'=>id,'readbackDigest'=>digest({'groupId'=>id,'membership'=>true,'type'=>group_types.fetch(id)}))
            next
          end
          if entries.any? { |event| event['eventType'] == 'group-intent' && event['groupId'] == id }
            return {'status'=>'unknown','attempt'=>context[:attempt],'betaReviewState'=>'unknown','releaseReady'=>false}
          end
          append_event(context,'group-intent','groupId'=>id)
          _response, code = asc(runner_path,'builds','add-groups','--app',app_id,'--build-number',options[:build],
            '--version',options[:version],'--platform','IOS','--group',id)
          return {'status'=>'unknown','attempt'=>context[:attempt],'betaReviewState'=>'unknown','releaseReady'=>false} unless code.zero?
          begin
            state = membership(runner_path,app_id,journal[:build_id],{id=>group_types.fetch(id)})
            return {'status'=>'unknown','attempt'=>context[:attempt],'betaReviewState'=>'unknown','releaseReady'=>false} unless state.fetch(id)
          rescue Refused
            return {'status'=>'unknown','attempt'=>context[:attempt],'betaReviewState'=>'unknown','releaseReady'=>false}
          end
          append_event(context,'group-readback','groupId'=>id,'readbackDigest'=>digest({'groupId'=>id,'membership'=>true,'type'=>group_types.fetch(id)}))
        end
        final_membership = membership(runner_path,app_id,journal[:build_id],group_types)
        refuse('membership-incomplete') unless final_membership.values.all?
        review = external ? review_state(runner_path,journal[:build_id]) : nil
        if external && options[:submit] && review.nil?
          if entries.any? { |event| event['eventType'] == 'review-intent' }
            return {'status'=>'unknown','attempt'=>context[:attempt],'betaReviewState'=>'unknown','releaseReady'=>false}
          end
          append_event(context,'review-intent')
          _response, code = asc(runner_path,'testflight','review','submit','--build-id',journal[:build_id],'--confirm')
          return {'status'=>'unknown','attempt'=>context[:attempt],'betaReviewState'=>'unknown','releaseReady'=>false} unless code.zero?
          begin
            review = review_state(runner_path,journal[:build_id])
            return {'status'=>'unknown','attempt'=>context[:attempt],'betaReviewState'=>'unknown','releaseReady'=>false} unless review
          rescue Refused
            return {'status'=>'unknown','attempt'=>context[:attempt],'betaReviewState'=>'unknown','releaseReady'=>false}
          end
        end
        review_label = external ? (review || 'not-submitted') : 'not-applicable'
        append_event(context,'review-readback','betaReviewState'=>review_label,
          'readbackDigest'=>digest({'buildId'=>journal[:build_id],'betaReviewState'=>review_label})) if external
        append_event(context,'distribution-result','betaReviewState'=>review_label,
          'readbackDigest'=>digest({'buildId'=>journal[:build_id],'groups'=>final_membership,
            'betaReviewState'=>review_label,'whatToTestDigest'=>options[:notes]&.fetch(:digest)}))
        result = {'status'=>'distributed','attempt'=>context[:attempt],'buildId'=>journal[:build_id],
          'betaReviewState'=>review_label,'releaseReady'=>false}
        result['whatToTestDigest'] = options[:notes].fetch(:digest) if options[:notes]
        result
      end
    end

    def main(argv)
      options = {groups:[],submit:false}
      parser = OptionParser.new do |cli|
        cli.on('--project-root PATH') { |value| refuse('duplicate-project-root') if options.key?(:root); options[:root]=value }
        cli.on('--issue N') { |value| refuse('duplicate-issue') if options.key?(:issue); options[:issue]=Integer(value,10) }
        cli.on('--version VERSION') { |value| refuse('duplicate-version') if options.key?(:version); options[:version]=value }
        cli.on('--build-number N') { |value| refuse('duplicate-build') if options.key?(:build); options[:build]=value }
        cli.on('--group ID') { |value| options[:groups] << value }
        cli.on('--submit-beta-review') { refuse('duplicate-submit') if options[:submit]; options[:submit]=true }
        cli.on('--approval REFERENCE') { |value| refuse('duplicate-approval') if options.key?(:approval); options[:approval]=value }
        cli.on('--resume-attempt ID') { |value| refuse('duplicate-resume') if options.key?(:resume); options[:resume]=value }
        cli.on('--whats-new-locale LOCALE') { |value| refuse('duplicate-whats-new-locale') if options.key?(:notes_locale); options[:notes_locale]=value }
        cli.on('--whats-new-source PATH') { |value| refuse('duplicate-whats-new-source') if options.key?(:notes_source); options[:notes_source]=value }
      end
      parser.parse!(argv)
      refuse('invalid-arguments') unless argv.empty?
      result = execute(options)
      puts JSON.generate(result.merge('schemaVersion'=>1,'recordType'=>RECORD))
      result['status'] == 'distributed' ? 0 : 1
    rescue Refused, Base::Refused => error
      puts JSON.generate({'schemaVersion'=>1,'recordType'=>RECORD,'status'=>'blocked','reason'=>error.message,'releaseReady'=>false})
      1
    rescue IssueContract::ValidationError, Ownership::ValidationError, AppStorePreparation::InvalidInput,
           AscCLI::Refused, OptionParser::ParseError, JSON::ParserError, Psych::Exception,
           SystemCallError, IOError, ArgumentError, KeyError, TypeError
      puts JSON.generate({'schemaVersion'=>1,'recordType'=>RECORD,'status'=>'blocked','reason'=>'invalid-input-or-environment','releaseReady'=>false})
      1
    end
  end
end

exit IOSTemplate::AscTestFlight.main(ARGV)
