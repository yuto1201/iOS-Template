#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'
require 'digest'
require 'time'
require 'securerandom'
require 'open3'
require 'optparse'
require_relative 'appstore-preparation'
require_relative 'issue-contract'
require_relative 'ownership'
require_relative 'asc-cli'

module IOSTemplate
  module AppStoreMetadataSave
    class Refused < StandardError; end
    module_function

    RECORD = 'appstore-metadata-save'
    REQUEST = 'appstore-metadata-save-request'
    DIGEST = /\Asha256:[0-9a-f]{64}\z/
    ATTEMPT = /\Aa[0-9a-f]{24}\z/
    RELATIVE = /\A[A-Za-z0-9_. -]+(?:\/[A-Za-z0-9_. -]+)*\z/
    APPROVAL = %r{\Aapproval: user-approval://[a-z0-9-]{1,128}\z}
    VERSION_STATES = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED READY_FOR_REVIEW WAITING_FOR_REVIEW INVALID_BINARY].freeze
    EFFECTS = {'name'=>'next-version', 'subtitle'=>'next-version', 'description'=>'next-version',
               'keywords'=>'next-version', 'whatsNew'=>'next-version', 'promotionalText'=>'immediate-publication'}.freeze
    SECTIONS = {
      'app-info-localization'=>{'type'=>'appInfoLocalizations','ascType'=>'app-info','values'=>%w[name subtitle privacyPolicyUrl privacyChoicesUrl privacyPolicyText]},
      'version-localization'=>{'type'=>'appStoreVersionLocalizations','ascType'=>'version','values'=>%w[description keywords promotionalText whatsNew supportUrl marketingUrl]}
    }.freeze
    FLAGS = {'name'=>'--name','subtitle'=>'--subtitle','description'=>'--description','keywords'=>'--keywords',
             'promotionalText'=>'--promotional-text','whatsNew'=>'--whats-new',
             'privacyPolicyUrl'=>'--privacy-policy-url','supportUrl'=>'--support-url'}.freeze
    FIELD_SECTIONS = {'name'=>'app-info-localization','subtitle'=>'app-info-localization',
                      'description'=>'version-localization','keywords'=>'version-localization',
                      'promotionalText'=>'version-localization','whatsNew'=>'version-localization'}.freeze
    REQUIREMENT_URLS = [
      'https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/',
      'https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/',
      'https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties/'
    ].freeze
    PREFLIGHT_KEYS = %w[schemaVersion issue executor provider account target environment operation health checkedAt digest].freeze

    def refuse(reason)
      raise Refused, reason
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def digest(value)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
    end

    def time(value)
      return nil unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      parsed = Time.iso8601(value)
      parsed if parsed.utc.iso8601 == value
    rescue ArgumentError
      nil
    end

    def exact(value, keys)
      value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def safe_root(path)
      refuse('unsafe-project-root') unless path.is_a?(String) && path.start_with?('/') && File.realpath(path) == path && File.directory?(path)
      path
    end

    def artifact_root(root)
      path = File.join(root, '.artifacts')
      if File.symlink?(path)
        # Canonical issue worktrees share the primary checkout's artifact root.
        expected = File.join(File.dirname(File.dirname(root)), '.artifacts')
        refuse('unsafe-artifact-link') unless File.basename(File.dirname(root)) == '.worktrees' &&
          File.readlink(path) == '../../.artifacts' && File.realpath(path) == expected
      else
        refuse('unsafe-artifact-root') unless File.directory?(path)
      end
      stat = File.lstat(File.realpath(path))
      refuse('unowned-artifact-root') unless stat.directory? && stat.uid == Process.uid
      File.realpath(path)
    end

    def path_in(root, relative)
      refuse('unsafe-relative-path') unless relative.is_a?(String) && relative.match?(RELATIVE) &&
        !relative.split('/').include?('..') && !relative.split('/').include?('.git')
      if relative.start_with?('.artifacts/')
        base = artifact_root(root)
        rest = relative.delete_prefix('.artifacts/')
      else
        base = root
        rest = relative
      end
      cursor = base
      rest.split('/').each do |component|
        cursor = File.join(cursor, component)
        begin
          refuse('unsafe-symlink-path') if File.lstat(cursor).symlink?
        rescue Errno::ENOENT
          break
        end
      end
      cursor
    end

    def regular_bytes(root, relative, maximum=1_000_000)
      path = path_in(root, relative)
      stat = File.lstat(path)
      refuse('unsafe-input-file') unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid && stat.size <= maximum
      bytes = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        opened = file.stat
        refuse('input-changed-while-opening') unless opened.file? && opened.nlink == 1 &&
          [opened.dev,opened.ino,opened.size] == [stat.dev,stat.ino,stat.size]
        content = file.read(maximum + 1)
        after = file.stat
        refuse('input-changed-while-reading') unless [after.dev,after.ino,after.size,after.mtime,after.ctime] ==
          [opened.dev,opened.ino,opened.size,opened.mtime,opened.ctime]
        content
      end
      refuse('input-changed-or-oversized') unless bytes.bytesize == stat.size
      bytes.force_encoding(Encoding::UTF_8)
      refuse('invalid-utf8-input') unless bytes.valid_encoding? && !bytes.include?("\0")
      bytes
    end

    def document(root, relative, maximum=1_000_000)
      JSON.parse(regular_bytes(root, relative, maximum), object_class: AppStorePreparation::UniqueObject)
    end

    def safe_directory(path, mode=0700)
      unless File.exist?(path) || File.symlink?(path)
        safe_directory(File.dirname(path), mode) unless File.directory?(File.dirname(path))
        Dir.mkdir(path, mode)
      end
      stat = File.lstat(path)
      refuse('unsafe-journal-directory') unless stat.directory? && stat.uid == Process.uid &&
        (stat.mode & 0002).zero? && !stat.symlink?
      path
    end

    def write_new(path, value)
      bytes = JSON.generate(canonical(value)) + "\n"
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
    rescue Errno::EEXIST
      refuse('existing-event-or-attempt')
    end

    def runner(root)
      override = ENV['IOS_TEMPLATE_TEST_ASC_RUNNER']
      if ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
        refuse('test-runner-required') unless override
        AscCLI.physical_path!(override)
        stat = File.lstat(override)
        refuse('invalid-test-runner') unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid && File.executable?(override)
        override
      else
        refuse('test-runner-in-production') if override || ENV.keys.any? { |key| key.start_with?('IOS_TEMPLATE_TEST_') }
        File.join(__dir__, '..', 'asc-run.sh')
      end
    end

    def asc(runner_path, operation, *command, package_root: nil)
      args = ['--operation', operation, '--', *command, '--output', 'json']
      AscCLI.command_arguments(args, package_root: package_root || File.join(AscCLI::ROOT, 'App Store'))
      output, _error, status = Open3.capture3({'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8'}, runner_path, *args)
      refuse('asc-output-too-large') if output.bytesize > 1_048_576
      output.force_encoding(Encoding::UTF_8)
      refuse('asc-output-invalid') unless output.valid_encoding? && !output.include?("\0")
      parsed = JSON.parse(output, object_class: AppStorePreparation::UniqueObject) unless output.empty?
      [parsed, status.exitstatus || 1]
    rescue JSON::ParserError, AppStorePreparation::InvalidInput
      [nil, 1]
    end

    def data_one(response, type)
      refuse('remote-response-incomplete') unless response.is_a?(Hash) && response['data'].is_a?(Array) && response['data'].length == 1 &&
        (!response.key?('links') || response.dig('links', 'next').nil?) &&
        (!response.key?('meta') || response.dig('meta','paging','total').nil? || response.dig('meta','paging','total') == 1)
      entry = response['data'].first
      refuse('remote-resource-mismatch') unless entry.is_a?(Hash) && entry['type'] == type &&
        entry['id'].is_a?(String) && entry['id'].match?(/\A[A-Za-z0-9_-]{1,128}\z/) && entry['attributes'].is_a?(Hash)
      entry
    end

    def inspect_identity(runner_path, identity)
      bundle, code = asc(runner_path, 'appstore.update_metadata', 'bundle-ids', 'list', '--identifier', identity.fetch('bundleId'))
      refuse('remote-identity-unavailable') unless code.zero?
      resource = data_one(bundle, 'bundleIds')
      refuse('remote-team-bundle-mismatch') unless resource['attributes']['identifier'] == identity['bundleId'] && resource['attributes']['seedId'] == identity['teamId']
      apps, code = asc(runner_path, 'appstore.update_metadata', 'apps', 'list', '--bundle-id', identity.fetch('bundleId'))
      refuse('remote-identity-unavailable') unless code.zero?
      resource = data_one(apps, 'apps')
      refuse('remote-app-bundle-mismatch') unless resource['id'] == identity['appId'] && resource['attributes']['bundleId'] == identity['bundleId']
      versions, code = asc(runner_path, 'appstore.update_metadata', 'versions', 'list', '--app', identity.fetch('appId'), '--version', identity.fetch('version'), '--platform', 'IOS')
      refuse('remote-version-unavailable') unless code.zero?
      resource = data_one(versions, 'appStoreVersions')
      attrs = resource['attributes']
      refuse('remote-version-mismatch') unless attrs['versionString'] == identity['version'] && attrs['platform'] == 'IOS'
      state = attrs['appStoreState']
      refuse('version-not-editable') unless VERSION_STATES.include?(state)
      [resource.fetch('id'), state]
    end

    def form_value(runner_path, identity, version_id, form)
      section = SECTIONS.fetch(form.fetch('section'))
      command = ['localizations','list']
      if section['ascType'] == 'version'
        command.concat(['--version', version_id, '--type', 'version'])
      else
        command.concat(['--app', identity.fetch('appId'), '--type', 'app-info'])
      end
      command.concat(['--locale', form.fetch('locale'), '--paginate'])
      response, code = asc(runner_path, 'appstore.update_metadata', *command)
      refuse('remote-form-unavailable') unless code.zero?
      item = data_one(response, section['type'])
      reference = "asc://apps/#{identity.fetch('appId')}/#{section['type']}/#{item.fetch('id')}"
      refuse('remote-form-reference-mismatch') if form.key?('remoteReference') && reference != form.fetch('remoteReference')
      attrs = item.fetch('attributes')
      expected = section['values'] + ['locale']
      refuse('remote-form-incomplete') unless attrs.keys.sort == expected.sort && attrs['locale'] == form['locale'] &&
        section['values'].all? { |field| attrs[field].nil? || attrs[field].is_a?(String) }
      projection = {'section'=>form['section'],'locale'=>form['locale'],'remoteReference'=>reference,
                    'values'=>section['values'].to_h { |key| [key, attrs.fetch(key)] }}
      [projection, digest(projection)]
    end

    # Shared full-form baseline, patch and readback path for selective save and
    # sealed release sections. The latter supplies values from its package only.
    def prepare_form_patch(baseline, values)
      section = SECTIONS.fetch(baseline.fetch('section'))
      refuse('invalid-form-patch') unless values.is_a?(Hash) && !values.empty? &&
        values.keys.all? { |key| section['values'].include?(key) && FLAGS.key?(key) && values[key].is_a?(String) && !values[key].empty? }
      intended = baseline.fetch('values').merge(values)
      [digest(values), digest(baseline.merge('values'=>intended))]
    end

    def save_form_patch(runner_path, identity, version_id, form, values, baseline_digest, package_root: nil)
      _again, before_digest = form_value(runner_path, identity, version_id, form)
      refuse('baseline-drift-before-save') unless before_digest == baseline_digest
      section = SECTIONS.fetch(form.fetch('section'))
      args = ['localizations','update']
      args.concat(section['ascType'] == 'version' ? ['--version',version_id,'--type','version'] : ['--app',identity.fetch('appId'),'--type','app-info'])
      args.concat(['--locale',form.fetch('locale')])
      values.each { |field,value| args.concat([FLAGS.fetch(field),value]) }
      response, code = asc(runner_path, 'appstore.update_metadata', *args, package_root: package_root)
      readback_digest = begin
        form_value(runner_path, identity, version_id, form).last
      rescue Refused
        nil
      end
      [response, code, readback_digest]
    end

    def field_source(root, selected, report)
      field = selected.fetch('fieldId')
      locale = selected.fetch('locale')
      source_id = field == 'whatsNew' ? 'releaseNotes' : field
      row = report.fetch('fields').find { |entry| entry['fieldId'] == source_id && entry['locale'] == locale }
      refuse('field-unconfirmed') unless row && row['state'] == 'confirmed' && row['reasons'] == [] &&
        row['evidenceSources'].is_a?(Array) && !row['evidenceSources'].empty?
      source = selected.fetch('source')
      path = field == 'whatsNew' ? "App Store/release-notes/#{locale}.md" : "App Store/metadata/localizations/#{locale}.yml"
      anchor = field == 'whatsNew' ? 'document' : field
      refuse('source-descriptor-mismatch') unless exact(source, %w[path anchor digest]) && source['path'] == path && source['anchor'] == anchor &&
        source['digest'].is_a?(String) && source['digest'].match?(DIGEST) &&
        row['sources'].any? { |entry| entry['path'] == path && entry['anchor'] == anchor && entry['digest'] == source['digest'] }
      bytes = regular_bytes(root, path, 65_536)
      refuse('source-digest-drift') unless "sha256:#{Digest::SHA256.hexdigest(bytes)}" == source['digest']
      value = if field == 'whatsNew'
                bytes
              else
                document = YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
                document.is_a?(Hash) ? document[anchor] : nil
              end
      refuse('field-value-invalid') unless value.is_a?(String) && !value.empty?
      # Keep Apple limits and the asc 5.4.0 flag parser on the same path before
      # any remote call. The runner checks them again at dispatch.
      section = FIELD_SECTIONS.fetch(field)
      selector = section == 'version-localization' ? ['--version','V1','--type','version'] : ['--app','123','--type','app-info']
      AscCLI.command_arguments(['--operation','appstore.update_metadata','--','localizations','update',*selector,'--locale',locale,FLAGS.fetch(field),value])
      [value, row]
    end

    def validate_request(root, request)
      refuse('invalid-request-schema') unless exact(request, %w[schemaVersion recordType issue executor identity sourceRevision requirements publicationImpactApprovalReference forms selectedFields]) &&
        request['schemaVersion'] == 1 && request['recordType'] == REQUEST && request['issue'].is_a?(Integer) && request['issue'].positive? &&
        %w[codex claude].include?(request['executor']) && request['sourceRevision'].is_a?(String) && request['sourceRevision'].match?(/\A[0-9a-f]{40}\z/)
      identity = request.fetch('identity')
      refuse('invalid-request-identity') unless exact(identity, %w[teamId bundleId appId platform version]) &&
        identity['teamId'].is_a?(String) && identity['teamId'].match?(/\A[A-Z0-9]{10}\z/) &&
        identity['bundleId'].is_a?(String) && identity['bundleId'].match?(IssueContract::BUNDLE_IDENTIFIER) &&
        identity['appId'].is_a?(String) && identity['appId'].match?(/\A[1-9][0-9]*\z/) && identity['platform'] == 'IOS' &&
        identity['version'].is_a?(String) && identity['version'].match?(/\A[0-9]+(?:\.[0-9]+){1,2}\z/)
      requirements = request.fetch('requirements')
      now = Time.now.utc
      checked = time(requirements['checkedAt']) if requirements.is_a?(Hash)
      refuse('requirements-not-current') unless exact(requirements, %w[checkedAt sources]) && checked && (now-checked).between?(0,3600) &&
        requirements['sources'].is_a?(Array) && (REQUIREMENT_URLS - requirements['sources']).empty? &&
        (requirements['sources'] - REQUIREMENT_URLS).empty? && requirements['sources'].uniq == requirements['sources']
      approval = request['publicationImpactApprovalReference']
      refuse('invalid-publication-approval-reference') unless approval.nil? || approval.is_a?(String) && approval.match?(APPROVAL)
      forms, selected = request.values_at('forms','selectedFields')
      refuse('invalid-form-selection') unless forms.is_a?(Array) && forms.length.between?(1,16) && selected.is_a?(Array) && selected.length.between?(1,32)
      keys = []
      forms.each do |form|
        refuse('invalid-form') unless exact(form, %w[section locale remoteReference baselineDigest]) && SECTIONS.key?(form['section']) &&
          %w[en-US ja].include?(form['locale']) && form['baselineDigest'].is_a?(String) && form['baselineDigest'].match?(DIGEST)
        resource = SECTIONS.fetch(form['section'])['type']
        reference = %r{\Aasc://apps/#{Regexp.escape(identity['appId'])}/#{resource}/[A-Za-z0-9_-]{1,128}\z}
        refuse('invalid-remote-reference') unless form['remoteReference'].is_a?(String) && form['remoteReference'].match?(reference)
        keys << [form['section'], form['locale']]
      end
      refuse('duplicate-form') unless keys.uniq == keys
      selected_keys = []
      selected.each do |entry|
        refuse('scope-outside-save') unless exact(entry, %w[fieldId locale source]) && EFFECTS.key?(entry['fieldId']) && %w[en-US ja].include?(entry['locale']) &&
          keys.include?([FIELD_SECTIONS.fetch(entry['fieldId']),entry['locale']])
        selected_keys << [entry['fieldId'],entry['locale']]
      end
      refuse('duplicate-field') unless selected_keys.uniq == selected_keys &&
        forms.all? { |form| selected.any? { |entry| entry['locale'] == form['locale'] && FIELD_SECTIONS[entry['fieldId']] == form['section'] } }
      refuse('publication-approval-missing') if selected.any? { |entry| entry['fieldId'] == 'promotionalText' } && approval.nil?
    end

    def validate_authority(root, request, now)
      issue = request.fetch('issue')
      base = ".artifacts/issues/#{issue}"
      contract_path = "#{base}/issue-contract.json"
      contract_bytes = regular_bytes(root, contract_path, 1_000_000)
      contract = JSON.parse(contract_bytes, object_class: AppStorePreparation::UniqueObject)
      IssueContract.validate_snapshot!(contract, issue: issue, repository: contract.fetch('repository'))
      state = document(root, "#{base}/state.json", 100_000)
      refuse('issue-contract-unsealed') unless state['issue'] == issue && state['state'] == 'in-progress' &&
        state['executor'] == request['executor'] && state.dig('issueContract','path') == contract_path &&
        state.dig('issueContract','digest') == "sha256:#{Digest::SHA256.hexdigest(contract_bytes)}" &&
        contract.fetch('externalOperations').include?('appstore.update_metadata')
      validate_live_issue(contract, request) unless ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
      ownership = Ownership.parse(regular_bytes(root, 'Config/ownership.yml', 100_000))
      configured = Ownership.provider_identity!(ownership, 'app-store')
      identity = request.fetch('identity')
      refuse('configured-identity-mismatch') unless configured == {'account'=>identity['teamId'],'target'=>identity['bundleId']}
      preflight_path = "#{base}/provider-preflights/app-store-update_metadata.json"
      preflight = document(root, preflight_path, 100_000)
      expected = {'schemaVersion'=>2,'issue'=>issue,'executor'=>request['executor'],'provider'=>'app-store',
                  'account'=>identity['teamId'],'target'=>identity['bundleId'],'environment'=>'production',
                  'operation'=>'appstore.update_metadata','health'=>'healthy'}
      checked = time(preflight['checkedAt'])
      refuse('preflight-missing-or-stale') unless exact(preflight,PREFLIGHT_KEYS) && expected.all? { |key,value| preflight[key] == value } &&
        preflight['digest'] == digest(preflight.reject { |key,_| key == 'digest' }) && checked && (now-checked).between?(0,3600)
      {'path'=>contract_path,'digest'=>"sha256:#{Digest::SHA256.hexdigest(contract_bytes)}",'preflightDigest'=>preflight['digest']}
    end

    def validate_live_issue(contract, request)
      refuse('github-read-not-declared') unless contract.fetch('externalOperations').include?('github.read_issue')
      gh = %w[/opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh].find { |path| File.file?(path) && File.executable?(path) }
      refuse('github-reader-unavailable') unless gh
      command = ['/usr/bin/ruby','--disable-gems',File.join(__dir__,'bounded-command.rb'),
                 '--stage','appstore-save-issue-read','--timeout-seconds','30','--grace-seconds','1','--',
                 gh,'issue','view',request.fetch('issue').to_s,'--repo',contract.fetch('repository'),
                 '--json','body,labels,state']
      output, _error, status = Open3.capture3({'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8'},*command)
      refuse('live-issue-unavailable') unless status.success? && output.bytesize <= 1_000_000
      live = JSON.parse(output, object_class: AppStorePreparation::UniqueObject)
      labels = live['labels'].is_a?(Array) ? live['labels'].map { |entry| entry['name'] } : []
      issue_type = labels.grep(/\Atype:(feature|regression|docs|release)\z/).map { |entry| entry.delete_prefix('type:') }.uniq
      refuse('live-issue-state-mismatch') unless live['state'] == 'OPEN' && labels.include?('state:in-progress') && issue_type.length == 1
      parsed = IssueContract.parse(live.fetch('body'), issue_type: issue_type.first, issue: request['issue'],
        repository: contract['repository'], fetched_at: contract['fetchedAt'],
        allow_legacy_delivery_stage: !contract.key?('deliveryStage'))
      refuse('live-issue-contract-drift') unless parsed.contract == contract
      operation = parsed.external_operation_details.find { |entry| entry['operation'] == 'appstore.update_metadata' }
      refuse('live-operation-authority-mismatch') unless operation && operation['executor'].downcase == request['executor'] &&
        operation['environment'] == 'production' && operation['service'] == 'App Store Connect'
      if operation['approvalRequired']
        refuse('operation-approval-reference-mismatch') unless operation['approvalReference'] == request['publicationImpactApprovalReference']
      end
    rescue JSON::ParserError, AppStorePreparation::InvalidInput, IssueContract::ValidationError, KeyError
      refuse('live-issue-unavailable-or-drifted')
    end

    def preparation(root, request)
      report = AppStorePreparation::Report.new(root).run
      identity = request.fetch('identity')
      registration = report.fetch('registration')
      refuse('preparation-identity-mismatch') unless report['sourceRevision'] == request['sourceRevision'] &&
        registration['status'] == 'matched-observation' && registration.dig('existingApp','appId') == identity['appId'] &&
        (ENV['IOS_TEMPLATE_TEST_MODE'] == '1' || registration['evidenceOrigin'] == 'app-store-connect')
      request.fetch('selectedFields').each { |entry| field_source(root, entry, report) }
      report
    end

    def previous_events(root, issue, attempt, request_digest)
      refuse('invalid-resume-attempt') unless attempt.is_a?(String) && attempt.match?(ATTEMPT)
      relative = ".artifacts/appstore-metadata/#{issue}/#{attempt}"
      directory = path_in(root, relative)
      stat = File.lstat(directory)
      refuse('unowned-attempt') unless stat.directory? && stat.uid == Process.uid && stat.mode & 0777 == 0700
      names = Dir.children(directory).sort
      refuse('invalid-attempt-events') unless !names.empty? && names.each_with_index.all? do |name,index|
        name.match?(Regexp.new("\\A#{format('%04d', index+1)}-(?:intent|outcome)\\.json\\z"))
      end
      names.map do |name|
        event_path = "#{relative}/#{name}"
        bytes = regular_bytes(root, event_path, 100_000)
        refuse('unsafe-attempt-event') unless File.lstat(path_in(root,event_path)).mode & 0777 == 0600
        entry = JSON.parse(bytes, object_class: AppStorePreparation::UniqueObject)
        refuse('attempt-history-mismatch') unless entry['recordType'] == RECORD && entry['schemaVersion'] == 1 &&
          entry['issue'] == issue && entry['attempt'] == attempt && entry['requestDigest'] == request_digest &&
          name.end_with?("-#{entry['eventType']}.json") && %w[intent outcome].include?(entry['eventType']) &&
          bytes == JSON.generate(canonical(entry)) + "\n"
        entry
      end
    end

    def event_base(request, request_digest, attempt, previous, authority, form, fields, prepared)
      {'schemaVersion'=>1,'recordType'=>RECORD,'issue'=>request['issue'],'attempt'=>attempt,'previousAttempt'=>previous,
       'requestDigest'=>request_digest,'contractReference'=>authority.slice('path','digest'),
       'executor'=>request['executor'],'operation'=>'appstore.update_metadata','sourceRevision'=>request['sourceRevision'],
       'requirements'=>request['requirements'],'identity'=>request['identity'],'preflightDigest'=>authority['preflightDigest'],
       'publicationImpactApprovalReference'=>request['publicationImpactApprovalReference'],
       'section'=>form['section'],'locale'=>form['locale'],'remoteReference'=>form['remoteReference'],
       'fields'=>fields.map do |entry|
         source_id = entry.fetch('fieldId') == 'whatsNew' ? 'releaseNotes' : entry.fetch('fieldId')
         row = prepared.fetch('fields').find { |item| item['fieldId'] == source_id && item['locale'] == entry['locale'] }
         {'fieldId'=>entry.fetch('fieldId'),'publicEffect'=>EFFECTS.fetch(entry.fetch('fieldId')),
          'source'=>entry.fetch('source'),'sourceFingerprint'=>row.fetch('sourceFingerprint'),
          'confirmationReferences'=>row.fetch('evidenceSources').select { |descriptor| descriptor['path'].start_with?('.artifacts/appstore-preparation/proofs/') }}
       end}
    end

    def run(root, request_path, resume)
      root = safe_root(root)
      refuse('invalid-request-path') unless request_path.is_a?(String) && request_path.match?(%r{\A\.artifacts/appstore-metadata/requests/[a-z0-9-]+\.json\z})
      request_bytes = regular_bytes(root, request_path, 100_000)
      request = JSON.parse(request_bytes, object_class: AppStorePreparation::UniqueObject)
      request_digest = "sha256:#{Digest::SHA256.hexdigest(request_bytes)}"
      validate_request(root, request)
      started = Time.now.utc
      authority = validate_authority(root, request, started)
      prepared = preparation(root, request)
      runner_path = runner(root)
      prior = resume ? previous_events(root, request['issue'], resume, request_digest) : []
      version_id, version_state = inspect_identity(runner_path, request.fetch('identity'))
      issue_dir = path_in(root, ".artifacts/appstore-metadata/#{request['issue']}")
      safe_directory(issue_dir)
      attempt = "a#{SecureRandom.hex(12)}"
      attempt_dir = File.join(issue_dir, attempt)
      Dir.mkdir(attempt_dir, 0700)
      event_number = 0
      form_outcomes = []
      append = lambda do |event|
        event_number += 1
        write_new(File.join(attempt_dir, format('%04d-%s.json',event_number,event.fetch('eventType'))), event)
        if event['eventType'] == 'outcome'
          form_outcomes << {'section'=>event['section'],'locale'=>event['locale'],
                            'fields'=>event['fields'].map { |entry| entry['fieldId'] },'outcome'=>event['outcome']}
        end
      end
      outcomes = []
      request.fetch('forms').each do |form|
        fields = request.fetch('selectedFields').select { |entry| entry['locale'] == form['locale'] && FIELD_SECTIONS[entry['fieldId']] == form['section'] }
        base = event_base(request, request_digest, attempt, resume, authority, form, fields, prepared)
        begin
          baseline, baseline_digest = form_value(runner_path, request['identity'], version_id, form)
          relevant = prior.select { |event| event['section'] == form['section'] && event['locale'] == form['locale'] }
          last = relevant.last
          retry_from_baseline = last && %w[blocked stale].include?(last['outcome'])
          expected_event = if retry_from_baseline
                             relevant.reverse.find { |event| event['expectedReadbackDigest'] == baseline_digest }
                           elsif last && last['expectedReadbackDigest'] == baseline_digest
                             last
                           end
          if expected_event
            append.call(base.merge('eventType'=>'outcome','outcome'=>'unchanged-verified','reason'=>nil,
              'baselineDigest'=>baseline_digest,'intendedPatchDigest'=>expected_event['intendedPatchDigest'],
              'expectedReadbackDigest'=>expected_event['expectedReadbackDigest'],'readbackDigest'=>baseline_digest,
              'versionStatus'=>version_state,'checkedAt'=>Time.now.utc.iso8601))
            outcomes << 'unchanged-verified'
            next
          end
          if retry_from_baseline
            unless baseline_digest == form['baselineDigest']
              append.call(base.merge('eventType'=>'outcome','outcome'=>'blocked','reason'=>'baseline-drift',
                'baselineDigest'=>baseline_digest,'intendedPatchDigest'=>nil,'expectedReadbackDigest'=>nil,'readbackDigest'=>nil,
                'versionStatus'=>version_state,'checkedAt'=>Time.now.utc.iso8601))
              outcomes << 'blocked'
              next
            end
          elsif last
            unless baseline_digest == last['baselineDigest'] && !%w[remote-saved unchanged-verified].include?(last['outcome'])
              append.call(base.merge('eventType'=>'outcome','outcome'=>'stale','reason'=>'resume-remote-drift',
                'baselineDigest'=>baseline_digest,'intendedPatchDigest'=>nil,'expectedReadbackDigest'=>nil,'readbackDigest'=>nil,
                'versionStatus'=>version_state,'checkedAt'=>Time.now.utc.iso8601))
              outcomes << 'stale'
              next
            end
          elsif baseline_digest != form['baselineDigest']
            append.call(base.merge('eventType'=>'outcome','outcome'=>'blocked','reason'=>'baseline-drift',
              'baselineDigest'=>baseline_digest,'intendedPatchDigest'=>nil,'expectedReadbackDigest'=>nil,'readbackDigest'=>nil,
              'versionStatus'=>version_state,'checkedAt'=>Time.now.utc.iso8601))
            outcomes << 'blocked'
            next
          end
          values = fields.to_h { |entry| [entry['fieldId'], field_source(root, entry, prepared).first] }
          patch_digest, expected_digest = prepare_form_patch(baseline, values)
          if expected_digest == baseline_digest
            append.call(base.merge('eventType'=>'outcome','outcome'=>'unchanged-verified','reason'=>nil,
              'baselineDigest'=>baseline_digest,'intendedPatchDigest'=>patch_digest,'expectedReadbackDigest'=>expected_digest,
              'readbackDigest'=>baseline_digest,'versionStatus'=>version_state,'checkedAt'=>Time.now.utc.iso8601))
            outcomes << 'unchanged-verified'
            next
          end
          append.call(base.merge('eventType'=>'intent','outcome'=>nil,'reason'=>nil,
            'baselineDigest'=>baseline_digest,'intendedPatchDigest'=>patch_digest,'expectedReadbackDigest'=>expected_digest,
            'readbackDigest'=>nil,'versionStatus'=>version_state,'checkedAt'=>Time.now.utc.iso8601))
          validate_authority(root, request, Time.now.utc)
          preparation(root, request)
          fresh_version, fresh_state = inspect_identity(runner_path, request['identity'])
          refuse('version-changed-before-save') unless fresh_version == version_id && fresh_state == version_state
          response, code, readback_digest = save_form_patch(runner_path, request['identity'], version_id, form, values, baseline_digest)
          outcome = nil
          reason = nil
          if !code.zero?
            outcome = response.is_a?(Hash) && response['errors'].is_a?(Array) && !response['errors'].empty? &&
              response['errors'].all? { |error| error.is_a?(Hash) && error['status'] == '422' } ? 'failed' : 'unknown'
            reason = outcome == 'failed' ? 'remote-validation' : 'ambiguous-response'
          elsif readback_digest == expected_digest
            outcome = 'remote-saved'
          else
            outcome = 'unknown'
            reason = readback_digest ? 'readback-mismatch' : 'readback-unavailable'
          end
          append.call(base.merge('eventType'=>'outcome','outcome'=>outcome,'reason'=>reason,
            'baselineDigest'=>baseline_digest,'intendedPatchDigest'=>patch_digest,'expectedReadbackDigest'=>expected_digest,
            'readbackDigest'=>readback_digest,'versionStatus'=>version_state,'checkedAt'=>Time.now.utc.iso8601))
          outcomes << outcome
        rescue Refused => error
          append.call(base.merge('eventType'=>'outcome','outcome'=>'blocked','reason'=>error.message,
            'baselineDigest'=>nil,'intendedPatchDigest'=>nil,'expectedReadbackDigest'=>nil,'readbackDigest'=>nil,
            'versionStatus'=>version_state,'checkedAt'=>Time.now.utc.iso8601))
          outcomes << 'blocked'
        end
      end
      status = if outcomes.all? { |outcome| outcome == 'remote-saved' }
                 'remote-saved'
               elsif outcomes.all? { |outcome| %w[remote-saved unchanged-verified].include?(outcome) }
                 'unchanged-verified'
               else
                 'partial'
               end
      puts JSON.generate({'schemaVersion'=>1,'recordType'=>RECORD,'issue'=>request['issue'],'attempt'=>attempt,
        'previousAttempt'=>resume,'status'=>status,'outcomes'=>form_outcomes,'releaseReady'=>false})
      status == 'partial' ? 1 : 0
    end

    def main(args)
      options = {}
      parser = OptionParser.new do |cli|
        cli.on('--project-root PATH') { |value| refuse('duplicate-project-root') if options.key?(:root); options[:root] = value }
        cli.on('--request PATH') { |value| refuse('duplicate-request') if options.key?(:request); options[:request] = value }
        cli.on('--resume-attempt ID') { |value| refuse('duplicate-resume') if options.key?(:resume); options[:resume] = value }
      end
      parser.parse!(args)
      refuse('invalid-arguments') unless args.empty? && options[:root] && options[:request]
      run(options[:root], options[:request], options[:resume])
    rescue Refused, IssueContract::ValidationError, Ownership::ValidationError,
           AppStorePreparation::InvalidInput, AscCLI::Refused, OptionParser::ParseError,
           JSON::ParserError, Psych::Exception, SystemCallError, IOError, ArgumentError, KeyError
      # Do not echo paths, ASC responses, source values or exception payloads.
      puts JSON.generate({'schemaVersion'=>1,'recordType'=>RECORD,'status'=>'blocked','releaseReady'=>false})
      1
    end
  end
end

exit IOSTemplate::AppStoreMetadataSave.main(ARGV) if $PROGRAM_NAME == __FILE__
