#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'
require 'digest'
require 'time'
require 'open3'
require 'optparse'
require_relative 'appstore-metadata-save'
require_relative 'release-verification'
require_relative 'issue-contract'
require_relative 'ownership'

module IOSTemplate
  module AppStoreReleaseSections
    class Refused < StandardError; end
    module_function

    SECTIONS = %w[app-information localization privacy screenshots build review-information submission].freeze
    BROWSER = %w[privacy review-information].freeze
    OPERATIONS = {'app-information'=>'appstore.update_metadata', 'localization'=>'appstore.update_metadata',
                  'privacy'=>'appstore.inspect_app', 'screenshots'=>'appstore.update_metadata',
                  'build'=>'appstore.submit_review', 'review-information'=>'appstore.inspect_app',
                  'submission'=>'appstore.submit_review'}.freeze
    PREFLIGHT_KEYS = %w[schemaVersion issue executor provider account target environment operation health checkedAt digest].freeze
    APP_KEYS = %w[schemaVersion bundleId version primaryLocale platforms category copyright supportURL privacyPolicyURL reviewContactReference accountsSupported].freeze
    RESULT_KEYS = %w[schemaVersion status primaryModel teamId bundleId version buildId sourceSha buildDigest packageDigest sections lastCompletedSection updatedAt].freeze
    ID = /\A[A-Za-z0-9_-]{1,128}\z/
    DIGEST = /\Asha256:[0-9a-f]{64}\z/
    SHA = /\A[0-9a-f]{40}\z/
    VERSION = /\A[0-9]+(?:\.[0-9]+){1,2}\z/
    APPROVAL = %r{\Aapproval: user-approval://[a-z0-9-]{1,128}\z}
    TEST_KEYS = %w[IOS_TEMPLATE_TEST_ASC_RUNNER IOS_TEMPLATE_TEST_OPERATION_DETAIL].freeze

    def refuse(message)
      raise Refused, message
    end

    def canonical(value)
      AppStoreMetadataSave.canonical(value)
    end

    def digest(value)
      AppStoreMetadataSave.digest(value)
    end

    def regular(path, maximum=1_048_576)
      AscCLI.read_regular(path, maximum)
    rescue AscCLI::Refused, SystemCallError
      refuse('sealed-input-unavailable-or-unsafe')
    end

    def input_path(root, supplied)
      refuse('input-path-invalid') unless supplied.is_a?(String) && supplied.start_with?('/') && File.expand_path(supplied) == supplied
      if supplied.start_with?(File.join(root, '.artifacts') + '/')
        AppStoreMetadataSave.path_in(root, supplied.delete_prefix(root + '/'))
      else
        AscCLI.physical_path!(supplied)
      end
    end

    def parse_json(path, maximum=1_048_576)
      JSON.parse(regular(path, maximum), object_class: AppStorePreparation::UniqueObject)
    rescue JSON::ParserError, AppStorePreparation::InvalidInput
      refuse('sealed-json-invalid')
    end

    def artifact_bytes(root, relative, maximum=1_048_576)
      AppStoreMetadataSave.regular_bytes(root, relative, maximum)
    rescue AppStoreMetadataSave::Refused
      refuse('issue-artifact-unavailable-or-unsafe')
    end

    def artifact_json(root, relative, maximum=1_048_576)
      JSON.parse(artifact_bytes(root, relative, maximum), object_class: AppStorePreparation::UniqueObject)
    rescue JSON::ParserError, AppStorePreparation::InvalidInput
      refuse('issue-artifact-json-invalid')
    end

    def parse_yaml(path)
      YAML.safe_load(regular(path, 65_536), permitted_classes: [], permitted_symbols: [], aliases: false)
    rescue Psych::Exception
      refuse('sealed-yaml-invalid')
    end

    def tree_digest(root)
      entries = []
      Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).sort.each do |path|
        next if %w[. ..].include?(File.basename(path))
        relative = path.delete_prefix(root + File::SEPARATOR)
        next if relative.match?(%r{\Asubmission/[0-9]+(?:\.[0-9]+){1,2}-(?:package|result)\.json\z})
        stat = File.lstat(path)
        refuse('package-path-unsafe') if stat.symlink?
        next unless stat.file?
        refuse('package-file-multiply-linked') unless stat.nlink == 1
        entries << "#{relative}\0#{Digest::SHA256.file(path).hexdigest}\0"
      end
      "sha256:#{Digest::SHA256.hexdigest(entries.join)}"
    end

    def sealed(context)
      root = context.fetch(:root)
      package = File.join(root, 'App Store')
      manifest_path = File.join(package, 'submission', "#{context.fetch(:version)}-package.json")
      manifest = parse_json(manifest_path)
      expected = %w[schemaVersion status bundleId version sourceSha verification buildDigest requirementsDigest screenshotManifestDigest packageDigest auditDigest firstPublication legalApprovalDigest preparedAt]
      refuse('sealed-package-schema-invalid') unless manifest.is_a?(Hash) && manifest.keys.sort == expected.sort &&
        manifest['schemaVersion'] == 2 && manifest['status'] == 'prepared'
      refuse('sealed-package-identity-mismatch') unless manifest.values_at('bundleId','version','sourceSha','buildDigest') ==
        [context[:bundle],context[:version],context[:head],context[:build_digest]]
      refuse('sealed-package-digest-mismatch') unless manifest['packageDigest'] == tree_digest(package)
      requirements = File.join(package, 'submission', 'requirements.json')
      screenshot_manifest = File.join(package, 'screenshots', 'manifest.json')
      refuse('requirements-digest-mismatch') unless "sha256:#{Digest::SHA256.hexdigest(regular(requirements))}" == manifest['requirementsDigest']
      refuse('screenshot-manifest-digest-mismatch') unless "sha256:#{Digest::SHA256.hexdigest(regular(screenshot_manifest))}" == manifest['screenshotManifestDigest']
      audit = parse_json(context.fetch(:audit))
      refuse('release-audit-mismatch') unless "sha256:#{Digest::SHA256.hexdigest(regular(context[:audit]))}" == manifest['auditDigest'] &&
        audit['status'] == 'approved' && audit['role'] == 'release-auditor' && audit['findings'] == [] &&
        audit.values_at('sourceSha','buildDigest','packageDigest') == [context[:head],context[:build_digest],manifest['packageDigest']]
      refuse('legal-approval-missing') if manifest['firstPublication'] == true && !manifest['legalApprovalDigest'].to_s.match?(DIGEST)
      reference = manifest.fetch('verification')
      refuse('verification-reference-invalid') unless reference.is_a?(Hash) && reference.keys.sort == %w[baseSha digest issue path]
      ReleaseVerification.with_full_proof(repo: root, issue: reference.fetch('issue'), base: reference.fetch('baseSha'),
        head: context[:head], bundle: context[:bundle], expected_reference: reference,
        artifact_digest: context[:build_digest], publish: ->(_value) {}) { |_value| nil }
      app = parse_yaml(File.join(package, 'metadata', 'app.yml'))
      refuse('app-information-schema-invalid') unless app.is_a?(Hash) && app.keys.sort == APP_KEYS.sort && app['schemaVersion'] == 1 &&
        app.values_at('bundleId','version','primaryLocale') == [context[:bundle],context[:version],'en-US'] &&
        app['platforms'].is_a?(Hash) && app['platforms'].keys.sort == %w[ipad iphone].sort &&
        app['platforms'].values.all? { |value| value == true || value == false } &&
        [true,false].include?(app['accountsSupported']) && app['reviewContactReference'].is_a?(String)
      screenshot = parse_json(screenshot_manifest)
      refuse('screenshot-manifest-identity-mismatch') unless screenshot.is_a?(Hash) && screenshot['schemaVersion'] == 1 &&
        screenshot['sourceSha'] == context[:head] && screenshot['buildDigest'] == context[:build_digest] &&
        screenshot['requirementsDigest'] == manifest['requirementsDigest'] && screenshot['cases'].is_a?(Array)
      context.merge(package: package, manifest: manifest, app: app, screenshot: screenshot)
    end

    def authority(context)
      root = context.fetch(:root)
      issue = context.fetch(:issue)
      contract_relative = ".artifacts/issues/#{issue}/issue-contract.json"
      contract_bytes = artifact_bytes(root, contract_relative)
      contract = JSON.parse(contract_bytes, object_class: AppStorePreparation::UniqueObject)
      IssueContract.validate_snapshot!(contract, issue: issue, repository: contract.fetch('repository'))
      state = artifact_json(root, ".artifacts/issues/#{issue}/state.json", 100_000)
      refuse('issue-contract-unsealed') unless state['issue'] == issue && state['state'] == 'in-progress' &&
        state['executor'] == context[:executor] && state.dig('issueContract','path') == ".artifacts/issues/#{issue}/issue-contract.json" &&
        state.dig('issueContract','digest') == "sha256:#{Digest::SHA256.hexdigest(contract_bytes)}"
      operation = OPERATIONS.fetch(context.fetch(:section))
      refuse('appstore-operation-not-declared') unless contract.fetch('externalOperations').include?(operation)
      ownership = Ownership.parse(regular(File.join(root, 'Config', 'ownership.yml'), 100_000))
      configured = Ownership.provider_identity!(ownership, 'app-store')
      refuse('configured-identity-mismatch') unless configured == {'account'=>context[:team], 'target'=>context[:bundle]}
      preflight_relative = ".artifacts/issues/#{issue}/provider-preflights/app-store-#{operation.delete_prefix('appstore.')}.json"
      preflight = File.join(root, preflight_relative)
      evidence = artifact_json(root, preflight_relative, 100_000)
      expected = {'schemaVersion'=>2,'issue'=>issue,'executor'=>context[:executor],'provider'=>'app-store',
                  'account'=>context[:team],'target'=>context[:bundle],'environment'=>'production',
                  'operation'=>operation,'health'=>'healthy'}
      checked = AppStoreMetadataSave.time(evidence['checkedAt'])
      refuse('preflight-missing-stale-or-operation-mismatch') unless evidence.is_a?(Hash) && evidence.keys.sort == PREFLIGHT_KEYS.sort &&
        expected.all? { |key,value| evidence[key] == value } && evidence['digest'] == digest(evidence.reject { |key,_| key == 'digest' }) &&
        checked && (context[:now] - checked).between?(0, 3600)
      detail = ENV['IOS_TEMPLATE_TEST_MODE'] == '1' ? test_operation_detail : validate_live_issue(contract, context, operation)
      validate_operation_approval(detail, context, operation)
      context.merge(contract: contract, contract_digest: state.dig('issueContract','digest'), preflight: preflight)
    rescue JSON::ParserError, AppStorePreparation::InvalidInput, IssueContract::ValidationError, Ownership::ValidationError
      refuse('release-authority-invalid')
    end

    def validate_live_issue(contract, context, operation)
      refuse('github-read-not-declared') unless contract.fetch('externalOperations').include?('github.read_issue')
      gh = %w[/opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh].find { |path| File.executable?(path) }
      refuse('github-reader-unavailable') unless gh
      command = ['/usr/bin/ruby','--disable-gems',File.join(__dir__,'bounded-command.rb'),
                 '--stage','appstore-release-issue-read','--timeout-seconds','30','--grace-seconds','1','--',
                 gh,'issue','view',context[:issue].to_s,'--repo',contract.fetch('repository'),'--json','body,labels,state']
      output, _error, status = Open3.capture3({'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8'}, *command)
      refuse('live-issue-unavailable') unless status.success? && output.bytesize <= 1_000_000
      live = JSON.parse(output, object_class: AppStorePreparation::UniqueObject)
      labels = live.fetch('labels').map { |entry| entry.fetch('name') }
      types = labels.grep(/\Atype:(?:feature|regression|docs|release)\z/).map { |value| value.delete_prefix('type:') }
      refuse('live-issue-state-mismatch') unless live['state'] == 'OPEN' && labels.include?('state:in-progress') && types.length == 1
      parsed = IssueContract.parse(live.fetch('body'), issue_type: types.first, issue: context[:issue],
        repository: contract['repository'], fetched_at: contract['fetchedAt'], allow_legacy_delivery_stage: !contract.key?('deliveryStage'))
      refuse('live-issue-contract-drift') unless parsed.contract == contract
      detail = parsed.external_operation_details.find { |entry| entry['operation'] == operation }
      detail
    rescue JSON::ParserError, AppStorePreparation::InvalidInput, IssueContract::ValidationError, KeyError
      refuse('live-issue-unavailable-or-drifted')
    end

    def test_operation_detail
      path = ENV.fetch('IOS_TEMPLATE_TEST_OPERATION_DETAIL')
      AscCLI.physical_path!(path)
      parse_json(path, 16_384)
    end

    def validate_operation_approval(detail, context, operation)
      refuse('live-operation-authority-mismatch') unless detail.is_a?(Hash) &&
        detail.keys.sort == %w[approvalReference approvalRequired environment executor operation service] &&
        detail['operation'] == operation && detail['executor'].to_s.downcase == context[:executor] &&
        detail['environment'] == 'production' && detail['service'] == 'App Store Connect' &&
        [true,false].include?(detail['approvalRequired']) &&
        (detail['approvalRequired'] ? detail['approvalReference'].to_s.match?(APPROVAL) : detail['approvalReference'].nil?)
      refuse('submission-approval-not-declared') if context[:section] == 'submission' && !detail['approvalRequired']
      if detail['approvalRequired']
        refuse('operation-approval-reference-mismatch') unless detail['approvalReference'] == context[:approval]
      end
    end

    def asc(context, *command)
      args = ['--operation', OPERATIONS.fetch(context.fetch(:section)), '--', *command, '--output', 'json']
      AscCLI.command_arguments(args, package_root: context[:package])
      output, _error, status = Open3.capture3({'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8'}, context.fetch(:runner), *args)
      refuse('asc-output-too-large') if output.bytesize > 1_048_576
      output.force_encoding(Encoding::UTF_8)
      refuse('asc-output-invalid') unless output.valid_encoding? && !output.include?("\0")
      parsed = JSON.parse(output, object_class: AppStorePreparation::UniqueObject) unless output.empty?
      [parsed, status.exitstatus || 1]
    rescue JSON::ParserError, AppStorePreparation::InvalidInput
      [nil, 1]
    end

    def one(response, type)
      AppStoreMetadataSave.data_one(response, type)
    rescue AppStoreMetadataSave::Refused
      refuse('remote-readback-incomplete')
    end

    def identity(context)
      bundle, code = asc(context, 'bundle-ids','list','--identifier',context[:bundle])
      refuse('remote-team-unavailable') unless code.zero?
      bundle_item = one(bundle, 'bundleIds')
      refuse('remote-team-bundle-mismatch') unless bundle_item.dig('attributes','seedId') == context[:team] &&
        bundle_item.dig('attributes','identifier') == context[:bundle]
      apps, code = asc(context, 'apps','list','--bundle-id',context[:bundle])
      refuse('remote-app-unavailable') unless code.zero?
      app = one(apps, 'apps')
      refuse('remote-app-mismatch') unless app['id'] == context[:app_id] && app.dig('attributes','bundleId') == context[:bundle] &&
        app.dig('attributes','primaryLocale') == context[:app]['primaryLocale']
      versions, code = asc(context, 'versions','list','--app',context[:app_id],'--version',context[:version],'--platform','IOS')
      refuse('remote-version-unavailable') unless code.zero?
      version = one(versions, 'appStoreVersions')
      refuse('remote-version-mismatch') unless version.dig('attributes','versionString') == context[:version] && version.dig('attributes','platform') == 'IOS'
      builds, code = asc(context, 'builds','list','--app',context[:app_id],'--version',context[:version],
        '--build-number',context[:build_number],'--platform','IOS','--paginate')
      refuse('remote-build-unavailable') unless code.zero?
      build = one(builds, 'builds')
      refuse('remote-build-id-mismatch') unless build['id'] == context[:build_id] && build.dig('attributes','version') == context[:build_number]
      detail, code = asc(context, 'builds','info','--app',context[:app_id],'--version',context[:version],
        '--build-number',context[:build_number],'--platform','IOS')
      refuse('remote-build-detail-unavailable') unless code.zero? && detail.is_a?(Hash)
      item = detail['data']
      prerelease = detail['included']
      relation = item.dig('relationships','preReleaseVersion','data') if item.is_a?(Hash)
      refuse('remote-build-version-or-state-mismatch') unless item.is_a?(Hash) && item['type'] == 'builds' && item['id'] == context[:build_id] &&
        item.dig('attributes','version') == context[:build_number] && item.dig('attributes','processingState') == 'VALID' &&
        relation.is_a?(Hash) && relation['type'] == 'preReleaseVersions' && prerelease.is_a?(Array) && prerelease.length == 1 &&
        prerelease.first['id'] == relation['id'] && prerelease.first.dig('attributes','version') == context[:version] &&
        prerelease.first.dig('attributes','platform') == 'IOS'
      context.merge(version_id: version.fetch('id'), version_resource: version)
    end

    def build_journal(context)
      supplied = context.fetch(:build_journal)
      expected_root = AppStoreMetadataSave.artifact_root(context[:root])
      directory = File.realpath(supplied)
      refuse('build-journal-path-invalid') unless directory.start_with?(File.join(expected_root, 'appstore-builds') + '/') &&
        File.directory?(directory) && !File.symlink?(supplied)
      AscCLI.physical_path!(directory)
      names = Dir.children(directory).grep(/\A[0-9]{4}-.+\.json\z/).sort
      refuse('build-journal-empty') if names.empty?
      refuse('build-journal-event-name-invalid') unless names.all? { |name| name.match?(/\A[0-9]{4}-(?:started|archive-complete|export-complete|upload-intent|upload-result|processing-readback|stage-failed)\.json\z/) }
      attempt = File.basename(directory)
      journal_issue = File.basename(File.dirname(directory))
      refuse('build-journal-attempt-invalid') unless attempt.match?(/\Aa[0-9a-f]{24}\z/) &&
        journal_issue.match?(/\A[1-9][0-9]*\z/)
      refuse('build-journal-issue-mismatch') unless journal_issue.to_i == context[:issue]
      previous = nil
      contract_digest = nil
      ipa_digest = nil
      events = names.each_with_index.map do |name,index|
        event_bytes = regular(File.join(directory,name), 100_000)
        event = JSON.parse(event_bytes, object_class: AppStorePreparation::UniqueObject)
        refuse('build-journal-issue-mismatch') unless event['issue'] == context[:issue]
        refuse('build-journal-contract-mismatch') unless event['contractDigest'] == context[:contract_digest]
        contract_digest ||= event['contractDigest']
        refuse('build-journal-chain-invalid') unless event['recordType'] == 'appstore-build-upload' &&
          event['schemaVersion'] == 1 && event['issue'] == journal_issue.to_i && event['attempt'] == attempt &&
          event['contractDigest'] == contract_digest && contract_digest.to_s.match?(DIGEST) &&
          AppStoreMetadataSave.time(event['checkedAt']) &&
          event_bytes == JSON.generate(canonical(event)) + "\n" &&
          event['eventSequence'] == index + 1 && name == format('%04d-%s.json',index+1,event['eventType']) &&
          event['previousEventDigest'] == previous && event.values_at('headSha','version','buildNumber','bundleId') ==
            [context[:head],context[:version],context[:build_number],context[:bundle]]
        ipa_digest = event['ipaDigest'] if event['eventType'] == 'export-complete'
        refuse('build-journal-ipa-digest-mismatch') if event.key?('ipaDigest') && event['eventType'] != 'export-complete' &&
          event['ipaDigest'] != ipa_digest
        previous = "sha256:#{Digest::SHA256.hexdigest(event_bytes)}"
        event
      end
      start = events.first
      intent = events.find { |event| event['eventType'] == 'upload-intent' }
      upload = events.find { |event| event['eventType'] == 'upload-result' }
      valid = events.last
      refuse('build-journal-not-readback-valid') unless start['eventType'] == 'started' && start['teamId'] == context[:team] &&
        start['preflightDigest'].to_s.match?(DIGEST) && ipa_digest.to_s.match?(DIGEST) &&
        intent && (!upload || %w[accepted unknown].include?(upload['status'])) &&
        (!upload || upload['status'] != 'accepted' ||
          upload['uploadId'].to_s.match?(ID) && upload['fileId'].to_s.match?(ID)) &&
        valid['eventType'] == 'processing-readback' &&
        valid.values_at('processingState','buildId','version','buildNumber','platform') ==
          ['VALID',context[:build_id],context[:version],context[:build_number],'IOS']
      context
    rescue SystemCallError
      refuse('build-journal-unavailable')
    end

    def form(context, section, locale)
      selector = {'section'=>section,'locale'=>locale}
      projection, baseline_digest = AppStoreMetadataSave.form_value(context[:runner],
        {'appId'=>context[:app_id]}, context[:version_id], selector)
      [projection, baseline_digest, selector.merge('remoteReference'=>projection.fetch('remoteReference'))]
    rescue AppStoreMetadataSave::Refused
      refuse('remote-form-readback-incomplete')
    end

    def form_values(context, section, locale)
      app = context[:app]
      if context[:section] == 'app-information'
        return section == 'app-info-localization' ? {'privacyPolicyUrl'=>app.fetch('privacyPolicyURL')} : {'supportUrl'=>app.fetch('supportURL')}
      end
      source = parse_yaml(File.join(context[:package], 'metadata', 'localizations', "#{locale}.yml"))
      refuse('localization-source-invalid') unless source.is_a?(Hash) && source.keys.sort == %w[name subtitle description keywords promotionalText].sort &&
        source.values.all? { |value| value.is_a?(String) }
      return source.slice('name','subtitle') if section == 'app-info-localization'
      notes = regular(File.join(context[:package], 'release-notes', "#{locale}.md"), 65_536)
      source.slice('description','keywords','promotionalText').merge('whatsNew'=>notes)
    end

    def form_projection(context)
      rows = []
      %w[en-US ja].each do |locale|
        %w[app-info-localization version-localization].each do |section|
          remote, _baseline, _form = form(context, section, locale)
          wanted = form_values(context, section, locale)
          values = wanted.keys.sort.to_h { |key| [key, remote.fetch('values').fetch(key)] }
          rows << {'locale'=>locale,'section'=>section,'remoteReference'=>remote.fetch('remoteReference'),'values'=>values}
        end
      end
      rows
    end

    def forms_match?(rows, context)
      rows.all? do |row|
        expected = form_values(context,row.fetch('section'),row.fetch('locale'))
        expected.all? { |key,value| row.fetch('values')[key] == value || value == '' && row.fetch('values')[key].nil? }
      end
    end

    def apply_forms(context)
      rows = form_projection(context)
      return rows if forms_match?(rows,context)
      rows.each do |row|
        values = form_values(context,row.fetch('section'),row.fetch('locale'))
        next if values.all? { |key,value| row.fetch('values')[key] == value || value == '' && row.fetch('values')[key].nil? }
        refuse('empty-localization-value-cannot-be-set') if values.values.any?(&:empty?)
        baseline, baseline_digest, exact_form = form(context,row['section'],row['locale'])
        _patch, expected_digest = AppStoreMetadataSave.prepare_form_patch(baseline,values)
        _response, code, readback_digest = AppStoreMetadataSave.save_form_patch(context[:runner],
          {'appId'=>context[:app_id]},context[:version_id],exact_form,values,baseline_digest,
          package_root: context[:package])
        refuse('localization-save-unknown') unless code.zero? && readback_digest == expected_digest
      end
      rows = form_projection(context)
      refuse('localization-readback-mismatch') unless forms_match?(rows,context)
      rows
    rescue AppStoreMetadataSave::Refused
      refuse('localization-save-unknown')
    end

    def category_id(context)
      categories, code = asc(context,'categories','list','--paginate')
      refuse('category-list-unavailable') unless code.zero? && categories.is_a?(Hash) && categories['data'].is_a?(Array) &&
        categories.dig('links','next').nil?
      rows = categories['data'].select { |row| row.is_a?(Hash) && row['type'] == 'appCategories' &&
        row.dig('attributes','name') == context[:app]['category'] }
      refuse('category-name-ambiguous-or-unsupported') unless rows.length == 1 && rows.first['id'].to_s.match?(ID)
      rows.first['id']
    end

    def app_information(context)
      app_info, code = asc(context,'apps','info','view','--app',context[:app_id],'--include','primaryCategory')
      refuse('app-info-readback-unavailable') unless code.zero? && app_info.is_a?(Hash)
      resource = app_info['data']
      refuse('app-info-readback-incomplete') unless resource.is_a?(Hash) && resource['type'] == 'appInfos' && resource['id'].to_s.match?(ID)
      current_category = resource.dig('relationships','primaryCategory','data','id')
      {'categoryId'=>current_category,'copyright'=>context[:version_resource].dig('attributes','copyright'),
       'forms'=>form_projection(context)}
    end

    def app_information_match?(snapshot, context, wanted_category)
      snapshot['categoryId'] == wanted_category && snapshot['copyright'] == context[:app]['copyright'] &&
        forms_match?(snapshot['forms'],context)
    end

    def apply_app_information(context)
      wanted = category_id(context)
      snapshot = app_information(context)
      return snapshot if app_information_match?(snapshot,context,wanted)
      if snapshot['categoryId'] != wanted
        _response, code = asc(context,'categories','set','--app',context[:app_id],'--primary',wanted)
        refuse('category-save-unknown') unless code.zero?
      end
      if snapshot['copyright'] != context[:app]['copyright']
        _response, code = asc(context,'versions','update','--version-id',context[:version_id],
          '--copyright',context[:app].fetch('copyright'))
        refuse('copyright-save-unknown') unless code.zero?
      end
      apply_forms(context)
      refreshed = identity(context)
      snapshot = app_information(refreshed)
      refuse('app-information-readback-mismatch') unless app_information_match?(snapshot,refreshed,wanted)
      snapshot
    end

    def screenshot_cases(context)
      rows = context[:screenshot].fetch('cases')
      seen = {}
      rows.map do |row|
        refuse('screenshot-case-invalid') unless row.is_a?(Hash) && row['path'].is_a?(String) &&
          row['path'].match?(%r{\A(?:en-US|ja)/(?:iphone-6\.9|ipad-13)/[0-9]{2}-[a-z0-9-]+\.png\z}) &&
          row['digest'].to_s.match?(DIGEST) && row['locale'] == row['path'].split('/')[0] &&
          row['family'] == row['path'].split('/')[1] && row['order'].is_a?(Integer)
        refuse('duplicate-screenshot-path') if seen[row['path']]
        seen[row['path']] = true
        path = File.join(context[:package],'screenshots',row['path'])
        bytes = regular(path, 30_000_000)
        refuse('screenshot-digest-mismatch') unless "sha256:#{Digest::SHA256.hexdigest(bytes)}" == row['digest']
        row.merge('absolutePath'=>path,'fileName'=>File.basename(path),'fileSize'=>bytes.bytesize,
                  'sourceFileChecksum'=>Digest::MD5.hexdigest(bytes),
                  # asc 5.4.0 internal/screenshotcatalog/catalog.go normalizes
                  # APP_IPHONE_69 to the API slot APP_IPHONE_67.
                  'displayType'=>row['family'] == 'iphone-6.9' ? 'APP_IPHONE_67' : 'APP_IPAD_PRO_3GEN_129')
      end.sort_by { |row| [row['locale'],row['family'],row['order']] }
    end

    def screenshot_snapshot(context, cases)
      locales = cases.map { |row| row['locale'] }.uniq
      locales.to_h do |locale|
        loc, code = asc(context,'localizations','list','--version',context[:version_id],
          '--type','version','--locale',locale,'--paginate')
        refuse('screenshot-localization-unavailable') unless code.zero?
        item = one(loc,'appStoreVersionLocalizations')
        shots, code = asc(context,'screenshots','list','--version-localization',item['id'])
        refuse('screenshot-readback-unavailable') unless code.zero? && shots.is_a?(Hash) &&
          shots['versionLocalizationId'] == item['id'] && shots['sets'].is_a?(Array)
        [locale, {'localizationId'=>item['id'],'sets'=>shots['sets']}]
      end
    end

    def screenshot_projection(snapshot, cases)
      projection = []
      snapshot.each do |locale, data|
        data.fetch('sets').each do |set|
          type = set.dig('set','attributes','screenshotDisplayType')
          refuse('screenshot-set-unrecognized') unless %w[APP_IPHONE_67 APP_IPAD_PRO_3GEN_129].include?(type) &&
            set.dig('set','id').to_s.match?(ID) && set['screenshots'].is_a?(Array)
          set['screenshots'].each_with_index do |shot,index|
            attrs = shot['attributes'] if shot.is_a?(Hash)
            refuse('screenshot-readback-incomplete') unless shot['id'].to_s.match?(ID) && attrs.is_a?(Hash) &&
              attrs['fileName'].is_a?(String) && attrs['fileSize'].is_a?(Integer) &&
              attrs['sourceFileChecksum'].to_s.match?(/\A[0-9a-f]{32}\z/) &&
              attrs.dig('assetDeliveryState','state') == 'COMPLETE'
            projection << {'locale'=>locale,'displayType'=>type,'order'=>index+1,
              'fileName'=>attrs['fileName'],'fileSize'=>attrs['fileSize'],'sourceFileChecksum'=>attrs['sourceFileChecksum']}
          end
        end
      end
      projection.sort_by { |row| [row['locale'],row['displayType'],row['order']] }
    end

    def expected_screenshots(cases)
      cases.group_by { |row| [row['locale'],row['displayType']] }.flat_map do |(locale,type),rows|
        rows.sort_by { |row| row['order'] }.each_with_index.map do |row,index|
          refuse('screenshot-order-invalid') unless row['order'] == index+1
          {'locale'=>locale,'displayType'=>type,'order'=>index+1,'fileName'=>row['fileName'],
           'fileSize'=>row['fileSize'],'sourceFileChecksum'=>row['sourceFileChecksum']}
        end
      end.sort_by { |row| [row['locale'],row['displayType'],row['order']] }
    end

    def apply_screenshots(context)
      cases = screenshot_cases(context)
      expected = expected_screenshots(cases)
      snapshot = screenshot_snapshot(context,cases)
      before = screenshot_projection(snapshot,cases)
      return before if before == expected
      refuse('existing-screenshot-set-differs') unless before.empty?
      cases.each do |row|
        loc = snapshot.fetch(row['locale']).fetch('localizationId')
        _response, code = asc(context,'screenshots','upload','--version-localization',loc,
          '--path',row['absolutePath'],'--device-type',row['displayType'])
        refuse('screenshot-upload-unknown') unless code.zero?
      end
      after = screenshot_projection(screenshot_snapshot(context,cases),cases)
      refuse('screenshot-readback-mismatch') unless after == expected
      after
    end

    def build_projection(context)
      relation = context[:version_resource].dig('relationships','build','data')
      refuse('build-attachment-ambiguous') if relation && (!relation.is_a?(Hash) || relation['type'] != 'builds')
      {'buildId'=>relation && relation['id'],'version'=>context[:version],'buildNumber'=>context[:build_number],
       'processingState'=>'VALID'}
    end

    def apply_build(context)
      snapshot = build_projection(context)
      refuse('different-build-attached') if snapshot['buildId'] && snapshot['buildId'] != context[:build_id]
      unless snapshot['buildId'] == context[:build_id]
        _response, code = asc(context,'versions','attach-build','--version-id',context[:version_id],
          '--build-id',context[:build_id])
        refuse('build-attach-unknown') unless code.zero?
      end
      refreshed = identity(context)
      after = build_projection(refreshed)
      refuse('build-readback-mismatch') unless after['buildId'] == context[:build_id]
      after
    end

    def submission_status(context)
      response, code = asc(context,'review','status','--app',context[:app_id],
        '--version-id',context[:version_id],'--platform','IOS')
      refuse('review-status-unavailable') unless code.zero? && response.is_a?(Hash) && response['appId'] == context[:app_id] &&
        response.dig('version','id') == context[:version_id] && response.dig('version','version') == context[:version]
      response
    end

    def apply_submission(context)
      refuse('submission-approval-reference-missing') unless context[:approval].to_s.match?(APPROVAL)
      refuse('build-not-attached') unless build_projection(context)['buildId'] == context[:build_id]
      before = submission_status(context)
      refuse('existing-review-submission-requires-reconciliation') if before['latestSubmission']
      response, code = asc(context,'review','submit','--app',context[:app_id],
        '--version-id',context[:version_id],'--build-id',context[:build_id],'--confirm')
      refuse('submission-unknown') unless code.zero? && response.is_a?(Hash) &&
        response.values_at('appId','versionId','buildId','platform') ==
          [context[:app_id],context[:version_id],context[:build_id],'IOS'] && response['submissionId'].to_s.match?(ID)
      after = submission_status(context)
      latest = after['latestSubmission']
      refuse('submission-readback-unknown') unless latest.is_a?(Hash) && latest['id'] == response['submissionId'] &&
        %w[READY_FOR_REVIEW WAITING_FOR_REVIEW IN_REVIEW UNRESOLVED_ISSUES].include?(latest['state'])
      {'submissionId'=>latest['id'],'versionId'=>context[:version_id],'buildId'=>context[:build_id],
       'reviewState'=>latest['state']}
    end

    def read_api_section(context, section)
      current = context.merge(section: section)
      current = identity(current)
      case section
      when 'app-information'
        category = category_id(current)
        snapshot = app_information(current)
        refuse('app-information-resume-drift') unless app_information_match?(snapshot,current,category)
        [snapshot,"asc://apps/#{current[:app_id]}/versions/#{current[:version_id]}/app-information"]
      when 'localization'
        rows = form_projection(current)
        refuse('localization-resume-drift') unless forms_match?(rows,current)
        [rows,"asc://apps/#{current[:app_id]}/versions/#{current[:version_id]}/localization"]
      when 'screenshots'
        cases = screenshot_cases(current)
        rows = screenshot_projection(screenshot_snapshot(current,cases),cases)
        refuse('screenshot-resume-drift') unless rows == expected_screenshots(cases)
        [rows,"asc://apps/#{current[:app_id]}/versions/#{current[:version_id]}/screenshots"]
      when 'build'
        snapshot = build_projection(current)
        refuse('build-resume-drift') unless snapshot['buildId'] == current[:build_id]
        [snapshot,"asc://apps/#{current[:app_id]}/builds/#{current[:build_id]}"]
      else
        refuse('api-section-invalid')
      end
    end

    def browser_evidence(context, section)
      path = context[:browser_readbacks]
      refuse('browser-readback-required') unless path
      document = parse_json(path, 100_000)
      refuse('browser-readback-schema-invalid') unless document.is_a?(Hash) && document.keys.sort == %w[schemaVersion sections].sort &&
        document['schemaVersion'] == 1 && document['sections'].is_a?(Hash)
      entry = document['sections'][section]
      checked = AppStoreMetadataSave.time(entry['checkedAt']) if entry.is_a?(Hash)
      refuse('browser-readback-required') unless entry.is_a?(Hash) && entry.keys.sort == %w[checkedAt readBackDigest remoteReference sealedSourceDigest].sort &&
        entry['readBackDigest'].to_s.match?(DIGEST) && entry['sealedSourceDigest'].to_s.match?(DIGEST) &&
        entry['remoteReference'].to_s.match?(%r{\Aasc://[A-Za-z0-9._/-]+\z}) &&
        entry['remoteReference'].start_with?("asc://apps/#{context[:app_id]}/") &&
        checked && (context[:now]-checked).between?(0,3600)
      source = section == 'privacy' ? File.join(context[:package],'privacy','data-use.yml') :
        File.join(context[:package],'review','review-notes.md')
      refuse('browser-sealed-source-mismatch') unless entry['sealedSourceDigest'] == "sha256:#{Digest::SHA256.hexdigest(regular(source,65_536))}"
      entry
    end

    def recorded(context)
      path = File.join(context[:package], 'submission', "#{context[:version]}-result.json")
      return [] unless File.exist?(path)
      value = parse_json(path)
      refuse('legacy-schemaVersion-1-result') if value.is_a?(Hash) && value['schemaVersion'] == 1
      refuse('result-schema-invalid') unless value.is_a?(Hash) && value.keys.sort == RESULT_KEYS.sort && value['schemaVersion'] == 2 &&
        value['sections'].is_a?(Array) && value.values_at('primaryModel','teamId','bundleId','version','buildId','sourceSha','buildDigest','packageDigest') ==
          [context[:executor],context[:team],context[:bundle],context[:version],context[:build_id],context[:head],context[:build_digest],context[:manifest]['packageDigest']]
      value['sections']
    end

    def verify_previous(context, entries)
      entries.each_with_index do |entry,index|
        refuse('result-section-order-invalid') unless entry.is_a?(Hash) && entry['id'] == SECTIONS[index] && entry['status'] == 'verified'
        if BROWSER.include?(entry['id'])
          evidence = browser_evidence(context,entry['id'])
          refuse('browser-resume-drift') unless entry['readBackSource'] == 'app-store-connect-browser' &&
            entry['readBackDigest'] == evidence['readBackDigest'] && entry['remoteReference'] == evidence['remoteReference']
        else
          current, reference = read_api_section(context,entry['id'])
          refuse('api-resume-drift') unless entry['readBackSource'] == 'app-store-connect-api' &&
            entry['readBackDigest'] == digest(current) && entry['remoteReference'] == reference
        end
      end
    end

    def record(context, reference, readback, source, resume)
      script = File.join(__dir__,'..','..','.agents','skills','submit-appstore-release','scripts','record-section.sh')
      args = ['--repo',context[:root],'--package-root',context[:package],
        '--package-manifest',File.join(context[:package],'submission',"#{context[:version]}-package.json"),
        '--preflight',context[:preflight],'--audit',context[:audit],
        '--result',File.join(context[:package],'submission',"#{context[:version]}-result.json"),
        '--team-id',context[:team],'--bundle-id',context[:bundle],'--version',context[:version],
        '--build-id',context[:build_id],'--source-sha',context[:head],'--build-digest',context[:build_digest],
        '--primary-model',context[:executor],'--section',context[:section],'--readback-source',source,
        '--remote-reference',reference,'--readback-digest',readback,'--resume-readback',resume ? 'yes' : 'no',
        '--now',context[:now].utc.iso8601]
      args.concat(['--submit-for-review','yes']) if context[:section] == 'submission'
      output, _error, status = Open3.capture3({'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8'},script,*args)
      refuse('section-record-failed') unless status.success? && output.bytesize <= 1_048_576
      JSON.parse(output)
    rescue JSON::ParserError
      refuse('section-record-invalid')
    end

    def run(options)
      test_mode = ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
      overrides = ENV.keys.select { |key| key.start_with?('IOS_TEMPLATE_TEST_') }
      refuse('test-overrides-in-production') unless test_mode || overrides.empty?
      refuse('unknown-test-override') unless (overrides - TEST_KEYS - ['IOS_TEMPLATE_TEST_MODE']).empty?
      root = File.realpath(options.fetch(:root))
      refuse('invalid-repository-root') unless File.directory?(root)
      now = AppStoreMetadataSave.time(options.fetch(:now))
      refuse('invalid-current-time') unless now && (ENV['IOS_TEMPLATE_TEST_MODE'] == '1' || (Time.now.utc - now).abs <= 300)
      context = options.merge(root:root, now:now,
        audit:input_path(root,options.fetch(:audit)),
        browser_readbacks:options[:browser_readbacks] && input_path(root,options[:browser_readbacks]))
      refuse('invalid-section') unless SECTIONS.include?(context[:section])
      refuse('invalid-executor') unless %w[codex claude].include?(context[:executor])
      refuse('invalid-release-identity') unless context[:version].to_s.match?(VERSION) &&
        context[:head].to_s.match?(SHA) && context[:build_digest].to_s.match?(DIGEST) &&
        context[:bundle].to_s.match?(IssueContract::BUNDLE_IDENTIFIER) &&
        context[:team].to_s.match?(/\A[A-Z0-9]{10}\z/)
      refuse('invalid-app-or-build-id') unless context[:app_id].to_s.match?(/\A[1-9][0-9]*\z/) && context[:build_id].to_s.match?(ID) &&
        context[:build_number].to_s.match?(/\A[1-9][0-9]*\z/)
      context = sealed(context)
      context = authority(context)
      context = build_journal(context)
      context = context.merge(runner: AppStoreMetadataSave.runner(root))
      previous = recorded(context)
      refuse('section-out-of-order') unless SECTIONS[previous.length] == context[:section]
      verify_previous(context,previous)
      if BROWSER.include?(context[:section])
        evidence = browser_evidence(context,context[:section])
        return record(context,evidence['remoteReference'],evidence['readBackDigest'],'browser',!previous.empty?)
      end
      current = identity(context)
      snapshot, reference = case context[:section]
                            when 'app-information'
                              [apply_app_information(current),"asc://apps/#{current[:app_id]}/versions/#{current[:version_id]}/app-information"]
                            when 'localization'
                              [apply_forms(current),"asc://apps/#{current[:app_id]}/versions/#{current[:version_id]}/localization"]
                            when 'screenshots'
                              [apply_screenshots(current),"asc://apps/#{current[:app_id]}/versions/#{current[:version_id]}/screenshots"]
                            when 'build'
                              [apply_build(current),"asc://apps/#{current[:app_id]}/builds/#{current[:build_id]}"]
                            when 'submission'
                              result = apply_submission(current)
                              [result,"asc://apps/#{current[:app_id]}/reviewSubmissions/#{result.fetch('submissionId')}"]
                            end
      record(context,reference,digest(snapshot),'api',!previous.empty?)
    rescue ReleaseVerification::InvalidProof, AppStoreMetadataSave::Refused, AscCLI::Refused,
           IssueContract::ValidationError, Ownership::ValidationError, JSON::ParserError,
           Psych::Exception, KeyError, ArgumentError, SystemCallError => error
      detail = ENV['IOS_TEMPLATE_TEST_MODE'] == '1' ? ": #{error.message}" : ''
      refuse("release-section-preflight-or-readback-failed: #{error.class}#{detail}")
    end

    def main(argv)
      values = {}
      parser = OptionParser.new do |opts|
        {'--repo'=>:root,'--issue'=>:issue,'--team-id'=>:team,'--app-id'=>:app_id,
         '--bundle-id'=>:bundle,'--version'=>:version,'--build-id'=>:build_id,
         '--build-number'=>:build_number,'--source-sha'=>:head,'--build-digest'=>:build_digest,
         '--primary-model'=>:executor,'--section'=>:section,'--audit'=>:audit,
         '--build-journal'=>:build_journal,'--browser-readbacks'=>:browser_readbacks,
         '--approval-reference'=>:approval,'--now'=>:now}.each do |flag,key|
          opts.on("#{flag} VALUE") { |value| values[key] = value }
        end
      end
      parser.parse!(argv)
      refuse('invalid-arguments') unless argv.empty?
      required = %i[root issue team app_id bundle version build_id build_number head build_digest executor section audit build_journal now]
      refuse('missing-argument') unless required.all? { |key| values[key].is_a?(String) && !values[key].empty? }
      refuse('invalid-issue') unless values[:issue].match?(/\A[1-9][0-9]*\z/)
      values[:issue] = values[:issue].to_i
      puts JSON.generate(run(values))
    rescue OptionParser::ParseError, Refused => error
      warn error.message
      exit 1
    end
  end
end

IOSTemplate::AppStoreReleaseSections.main(ARGV) if $PROGRAM_NAME == __FILE__
