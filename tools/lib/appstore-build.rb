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
  module AppStoreBuild
    class Refused < StandardError; end
    module_function

    RECORD = 'appstore-build-upload'
    OPERATION = 'appstore.upload_build'
    ATTEMPT = /\Aa[0-9a-f]{24}\z/
    SHA = /\A[0-9a-f]{40}\z/
    VERSION = /\A[0-9]+(?:\.[0-9]+){1,2}\z/
    BUILD = /\A[1-9][0-9]*\z/
    PREFLIGHT_KEYS = %w[schemaVersion issue executor provider account target environment operation health checkedAt digest].freeze
    EVENT_TYPES = %w[started archive-complete export-complete upload-intent upload-result processing-readback stage-failed].freeze
    TEST_KEYS = %w[IOS_TEMPLATE_TEST_XCODEBUILD IOS_TEMPLATE_TEST_ASC_RUNNER IOS_TEMPLATE_TEST_SECURITY_BIN IOS_TEMPLATE_TEST_POLL_INTERVAL IOS_TEMPLATE_TEST_POLL_TIMEOUT].freeze
    TOOL_ROOT = File.expand_path('../..',__dir__)

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

    def exact(value, keys)
      value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def time(value)
      return nil unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      parsed = Time.iso8601(value)
      parsed if parsed.utc.iso8601 == value
    rescue ArgumentError
      nil
    end

    def safe_root(path)
      refuse('unsafe-project-root') unless path.is_a?(String) && path.start_with?('/') &&
        File.realpath(path) == path && File.directory?(path)
      path
    end

    def artifact_root(root)
      path = File.join(root, '.artifacts')
      if File.symlink?(path)
        expected = File.join(File.dirname(File.dirname(root)), '.artifacts')
        refuse('unsafe-artifact-link') unless File.basename(File.dirname(root)) == '.worktrees' &&
          File.readlink(path) == '../../.artifacts' && File.realpath(path) == expected
      else
        refuse('unsafe-artifact-root') unless File.directory?(path)
      end
      physical = File.realpath(path)
      stat = File.lstat(physical)
      refuse('unowned-artifact-root') unless stat.directory? && stat.uid == Process.uid && !stat.symlink?
      physical
    end

    def safe_path(root, relative)
      refuse('unsafe-relative-path') unless relative.is_a?(String) && relative.match?(%r{\A[A-Za-z0-9_. -]+(?:/[A-Za-z0-9_. -]+)*\z}) &&
        relative.split('/').none? { |part| part == '..' || part == '.git' }
      base, rest = relative.start_with?('.artifacts/') ? [artifact_root(root), relative.delete_prefix('.artifacts/')] : [root, relative]
      cursor = base
      rest.split('/').each do |part|
        cursor = File.join(cursor, part)
        begin
          refuse('unsafe-symlink-path') if File.lstat(cursor).symlink?
        rescue Errno::ENOENT
          break
        end
      end
      cursor
    end

    def regular_bytes(root, relative, maximum=1_000_000)
      path = safe_path(root, relative)
      before = File.lstat(path)
      refuse('unsafe-input-file') unless before.file? && before.nlink == 1 && before.uid == Process.uid && before.size <= maximum
      bytes = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        opened = file.stat
        refuse('input-changed-while-opening') unless opened.file? && opened.nlink == 1 &&
          [opened.dev,opened.ino,opened.size] == [before.dev,before.ino,before.size]
        content = file.read(maximum + 1)
        after = file.stat
        refuse('input-changed-while-reading') unless [after.dev,after.ino,after.size,after.mtime,after.ctime] ==
          [opened.dev,opened.ino,opened.size,opened.mtime,opened.ctime]
        content
      end
      refuse('input-changed-or-oversized') unless bytes.bytesize == before.size
      bytes.force_encoding(Encoding::UTF_8)
      refuse('invalid-utf8-input') unless bytes.valid_encoding? && !bytes.include?("\0")
      bytes
    end

    def document(root, relative, maximum=1_000_000)
      JSON.parse(regular_bytes(root, relative, maximum), object_class: AppStorePreparation::UniqueObject)
    end

    def safe_directory(path)
      unless File.exist?(path) || File.symlink?(path)
        safe_directory(File.dirname(path)) unless File.directory?(File.dirname(path))
        Dir.mkdir(path, 0700)
      end
      stat = File.lstat(path)
      refuse('unsafe-directory') unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0002).zero? && !stat.symlink?
      path
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
    rescue Errno::EEXIST
      refuse('existing-attempt-bytes')
    end

    def read_owned_file(path, maximum)
      before = File.lstat(path)
      refuse('unsafe-attempt-file') unless before.file? && before.nlink == 1 && before.uid == Process.uid &&
        before.mode & 0777 == 0600 && before.size <= maximum
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        opened = file.stat
        refuse('attempt-file-changed') unless [opened.dev,opened.ino,opened.size] == [before.dev,before.ino,before.size]
        bytes = file.read(maximum+1)
        after = file.stat
        refuse('attempt-file-changed') unless [after.dev,after.ino,after.size,after.mtime,after.ctime] ==
          [opened.dev,opened.ino,opened.size,opened.mtime,opened.ctime] && bytes.bytesize == before.size
        bytes
      end
    end

    def git(root, *args)
      output, _error, status = Open3.capture3({'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8'}, '/usr/bin/git', '-C', root, *args)
      refuse('git-inspection-failed') unless status.success?
      output.strip
    end

    def clean_head(root, expected)
      refuse('head-mismatch') unless git(root,'rev-parse','--show-toplevel') == root && git(root,'rev-parse','HEAD') == expected
      refuse('dirty-worktree') unless git(root,'status','--porcelain=v1','--untracked-files=all').empty?
    end

    def identity(root)
      value = document(root,'Config/app-identity.json',16_384)
      keys = %w[appSlug bundleId displayName moduleName schemaVersion sourceIdentityVersion]
      refuse('invalid-app-identity') unless exact(value,keys) && value['schemaVersion'] == 1 && value['sourceIdentityVersion'] == 1 &&
        value['appSlug'].is_a?(String) && value['appSlug'].match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) &&
        value['moduleName'].is_a?(String) && value['moduleName'].match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) &&
        value['bundleId'].is_a?(String) && value['bundleId'].match?(IssueContract::BUNDLE_IDENTIFIER)
      value
    end

    def authority(root, issue, bundle_id, now)
      base = ".artifacts/issues/#{issue}"
      contract_path = "#{base}/issue-contract.json"
      contract_bytes = regular_bytes(root,contract_path)
      contract = JSON.parse(contract_bytes, object_class: AppStorePreparation::UniqueObject)
      IssueContract.validate_snapshot!(contract, issue: issue, repository: contract.fetch('repository'))
      state = document(root,"#{base}/state.json",100_000)
      contract_digest = "sha256:#{Digest::SHA256.hexdigest(contract_bytes)}"
      refuse('issue-contract-unsealed') unless state['issue'] == issue && state['state'] == 'in-progress' &&
        %w[codex claude].include?(state['executor']) && state.dig('issueContract','path') == contract_path &&
        state.dig('issueContract','digest') == contract_digest && contract.fetch('externalOperations').include?(OPERATION)
      validate_live_issue(contract,state['executor']) unless ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
      configured = Ownership.provider_identity!(Ownership.parse(regular_bytes(root,'Config/ownership.yml',100_000)), 'app-store')
      refuse('configured-bundle-mismatch') unless configured['target'] == bundle_id && configured['account'].match?(/\A[A-Z0-9]{10}\z/)
      preflight = document(root,"#{base}/provider-preflights/app-store-upload_build.json",100_000)
      expected = {'schemaVersion'=>2,'issue'=>issue,'executor'=>state['executor'],'provider'=>'app-store',
                  'account'=>configured['account'],'target'=>bundle_id,'environment'=>'production',
                  'operation'=>OPERATION,'health'=>'healthy'}
      checked = time(preflight['checkedAt'])
      refuse('preflight-missing-or-stale') unless exact(preflight,PREFLIGHT_KEYS) && expected.all? { |key,value| preflight[key] == value } &&
        preflight['digest'] == digest(preflight.reject { |key,_| key == 'digest' }) && checked && (now-checked).between?(0,3600)
      {'teamId'=>configured['account'],'bundleId'=>bundle_id,'contractDigest'=>contract_digest,'preflightDigest'=>preflight['digest']}
    end

    def validate_live_issue(contract, executor)
      refuse('github-read-not-declared') unless contract.fetch('externalOperations').include?('github.read_issue')
      gh = %w[/opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh].find { |path| File.file?(path) && File.executable?(path) }
      refuse('github-reader-unavailable') unless gh
      command = ['/usr/bin/ruby','--disable-gems',File.join(__dir__,'bounded-command.rb'),
                 '--stage','appstore-build-issue-read','--timeout-seconds','30','--grace-seconds','1','--',
                 gh,'issue','view',contract.fetch('issue').to_s,'--repo',contract.fetch('repository'),'--json','body,labels,state']
      output, _error, status = Open3.capture3({'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8'},*command)
      refuse('live-issue-unavailable') unless status.success? && output.bytesize <= 1_000_000
      live = JSON.parse(output, object_class: AppStorePreparation::UniqueObject)
      labels = live['labels'].is_a?(Array) ? live['labels'].map { |entry| entry['name'] } : []
      kinds = labels.grep(/\Atype:(feature|regression|docs|release)\z/).map { |entry| entry.delete_prefix('type:') }.uniq
      refuse('live-issue-state-mismatch') unless live['state'] == 'OPEN' && labels.include?('state:in-progress') && kinds.length == 1
      parsed = IssueContract.parse(live.fetch('body'),issue_type:kinds.first,issue:contract['issue'],repository:contract['repository'],
        fetched_at:contract['fetchedAt'],allow_legacy_delivery_stage:!contract.key?('deliveryStage'))
      refuse('live-issue-contract-drift') unless parsed.contract == contract
      operation = parsed.external_operation_details.find { |entry| entry['operation'] == OPERATION }
      refuse('live-operation-authority-mismatch') unless operation && operation['executor'].downcase == executor &&
        operation['environment'] == 'production' && operation['service'] == 'App Store Connect'
    rescue JSON::ParserError, AppStorePreparation::InvalidInput, IssueContract::ValidationError, KeyError
      refuse('live-issue-unavailable-or-drifted')
    end

    # Reuse the read-only Xcode resolver's parser, scheme and setting resolution,
    # but select only the archived app target's Release configuration.
    def release_facts(root, module_name)
      sources = AppStorePreparation::Sources.new(root, shared_evidence: false)
      facts = AppStorePreparation::XcodeFacts.new(sources, ->(*_) { nil })
      path = "#{module_name}.xcodeproj/project.pbxproj"
      bytes = facts.source(path)
      refuse('xcode-project-unavailable') unless bytes
      output, _error, status = Open3.capture3('/usr/bin/plutil','-convert','json','-o','-','--','-',stdin_data:bytes)
      refuse('xcode-project-invalid') unless status.success?
      project = JSON.parse(output, object_class: AppStorePreparation::UniqueObject)
      refuse('unsafe-xcode-project') if sources.sensitive_xcode_document?(project)
      objects = project['objects']
      parent = objects[project['rootObject']] if objects.is_a?(Hash)
      refuse('xcode-project-invalid') unless parent.is_a?(Hash) && parent['isa'] == 'PBXProject' && parent['targets'].is_a?(Array)
      ids = parent['targets'].select { |id| objects[id].is_a?(Hash) && objects[id]['isa'] == 'PBXNativeTarget' &&
        objects[id]['productType'] == 'com.apple.product-type.application' && objects[id]['name'] == module_name }
      refuse('xcode-app-target-ambiguous') unless ids.length == 1
      target = objects.fetch(ids.first)
      facts.instance_variable_set(:@objects,objects)
      facts.instance_variable_set(:@project,parent)
      facts.validate_scheme(module_name,ids.first)
      projects = facts.configurations(parent['buildConfigurationList'])
      targets = facts.configurations(target['buildConfigurationList'])
      refuse('xcode-release-configuration-invalid') unless projects.map { |row| row['name'] }.sort == targets.map { |row| row['name'] }.sort
      project_release = projects.find { |row| row['name'] == 'Release' }
      target_release = targets.find { |row| row['name'] == 'Release' }
      refuse('xcode-release-configuration-missing') unless project_release && target_release
      settings = facts.merge_settings(facts.settings(project_release),facts.settings(target_release)).merge('TARGET_NAME'=>target['name'])
      refuse('xcode-conditional-settings-unresolved') if settings.keys.any? { |key| key.include?('[') || key.include?(']') }
      %w[PRODUCT_BUNDLE_IDENTIFIER MARKETING_VERSION CURRENT_PROJECT_VERSION CODE_SIGN_STYLE PROVISIONING_PROFILE PROVISIONING_PROFILE_SPECIFIER].to_h do |key|
        [key,facts.resolved(settings,key)]
      end
    ensure
      sources&.close
    end

    def runner(root)
      override = ENV['IOS_TEMPLATE_TEST_ASC_RUNNER']
      return File.join(TOOL_ROOT,'tools/asc-run.sh') unless ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
      executable!(override)
    end

    def executable!(path)
      AscCLI.physical_path!(path)
      stat = File.lstat(path)
      refuse('invalid-test-executable') unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid && File.executable?(path)
      path
    end

    def asc(runner_path, *command)
      args = ['--operation',OPERATION,'--',*command,'--output','json']
      env = {'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8','HOME'=>ENV.fetch('HOME')}
      if ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
        env['IOS_TEMPLATE_TEST_MODE'] = '1'
        env['IOS_TEMPLATE_TEST_SECURITY_BIN'] = ENV.fetch('IOS_TEMPLATE_TEST_SECURITY_BIN')
      end
      output, _error, status = Open3.capture3(env,runner_path,*args,unsetenv_others:true)
      refuse('asc-output-too-large') if output.bytesize > 1_048_576
      output.force_encoding(Encoding::UTF_8)
      refuse('asc-output-invalid') unless output.valid_encoding? && !output.include?("\0")
      parsed = JSON.parse(output, object_class: AppStorePreparation::UniqueObject) unless output.empty?
      [parsed,status.exitstatus || 1]
    rescue JSON::ParserError, AppStorePreparation::InvalidInput
      [nil,1]
    end

    def full_list?(response)
      return false unless response.is_a?(Hash) && response['data'].is_a?(Array)
      links = response['links']
      return false unless links.nil? || links.is_a?(Hash) && (links['next'].nil? || links['next'] == '')
      total = response.dig('meta','paging','total')
      total.nil? || total.instance_of?(Integer) && total == response['data'].length
    end

    def app_id(runner_path, bundle_id)
      response, code = asc(runner_path,'apps','list','--bundle-id',bundle_id)
      refuse('remote-app-unavailable') unless code.zero? && full_list?(response) && response['data'].length == 1
      item = response['data'].first
      refuse('remote-app-mismatch') unless item.is_a?(Hash) && item['type'] == 'apps' && item['id'].is_a?(String) &&
        item['id'].match?(/\A[1-9][0-9]*\z/) && item.dig('attributes','bundleId') == bundle_id
      item['id']
    end

    def build_list(runner_path, app_id, version, build_number)
      response, code = asc(runner_path,'builds','list','--app',app_id,'--version',version,
        '--build-number',build_number,'--platform','IOS','--paginate')
      refuse('remote-build-list-unavailable') unless code.zero? && full_list?(response)
      response['data'].each do |item|
        refuse('remote-build-list-ambiguous') unless item.is_a?(Hash) && item['type'] == 'builds' &&
          item['id'].is_a?(String) && item['id'].match?(/\A[A-Za-z0-9_-]{1,128}\z/) &&
          item.dig('attributes','version') == build_number
      end
      response['data']
    end

    def build_info(runner_path, app_id, version, build_number, expected_id)
      response, code = asc(runner_path,'builds','info','--app',app_id,'--version',version,
        '--build-number',build_number,'--platform','IOS')
      refuse('remote-build-info-unavailable') unless code.zero? && response.is_a?(Hash)
      item = response['data']
      refuse('remote-build-info-mismatch') unless item.is_a?(Hash) && item['type'] == 'builds' && item['id'] == expected_id &&
        item.dig('attributes','version') == build_number
      relation = item.dig('relationships','preReleaseVersion','data')
      included = response['included']
      refuse('remote-build-version-ambiguous') unless relation.is_a?(Hash) && relation['type'] == 'preReleaseVersions' &&
        included.is_a?(Array) && included.length == 1
      prerelease = included.first
      refuse('remote-build-version-mismatch') unless prerelease.is_a?(Hash) && prerelease['type'] == 'preReleaseVersions' &&
        prerelease['id'] == relation['id'] && prerelease.dig('attributes','version') == version &&
        prerelease.dig('attributes','platform') == 'IOS'
      state = item.dig('attributes','processingState')
      refuse('remote-build-state-ambiguous') unless %w[PROCESSING VALID FAILED INVALID].include?(state)
      {'buildId'=>expected_id,'version'=>version,'buildNumber'=>build_number,'platform'=>'IOS','processingState'=>state}
    end

    def ipa_digest(path)
      AscCLI.physical_path!(path)
      before = File.lstat(path)
      refuse('unsafe-ipa') unless before.file? && before.nlink == 1 && before.uid == Process.uid && before.size.positive? && File.extname(path) == '.ipa'
      hash = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        opened = file.stat
        refuse('ipa-changed') unless [opened.dev,opened.ino,opened.size] == [before.dev,before.ino,before.size]
        calculator = Digest::SHA256.new
        while (chunk = file.read(1_048_576))
          calculator.update(chunk)
        end
        after_read = file.stat
        refuse('ipa-changed') unless [after_read.dev,after_read.ino,after_read.size,after_read.mtime,after_read.ctime] ==
          [opened.dev,opened.ino,opened.size,opened.mtime,opened.ctime]
        calculator.hexdigest
      end
      after = File.lstat(path)
      refuse('ipa-changed') unless [before.dev,before.ino,before.size,before.mtime,before.ctime] ==
        [after.dev,after.ino,after.size,after.mtime,after.ctime]
      "sha256:#{hash}"
    end

    def xcode_child(stage, args)
      refuse('invalid-xcode-child') unless %w[archive export].include?(stage) && args.length == (stage == 'archive' ? 5 : 4) &&
        %w[ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_PATH].all? { |key| ENV[key].is_a?(String) && !ENV[key].empty? }
      key_id, issuer_id, key_path = ENV.values_at('ASC_KEY_ID','ASC_ISSUER_ID','ASC_PRIVATE_KEY_PATH')
      refuse('invalid-auth-value') unless key_id.match?(/\A[A-Za-z0-9_-]{1,128}\z/) && issuer_id.match?(/\A[A-Za-z0-9-]{1,128}\z/)
      AscCLI.physical_path!(key_path)
      binary = if ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
                 [executable!(ENV.fetch('IOS_TEMPLATE_TEST_XCODEBUILD'))]
               else
                 ['/usr/bin/xcrun','xcodebuild']
               end
      command = if stage == 'archive'
                  project, scheme, archive, derived, team = args
                  binary + ['archive','-project',project,'-scheme',scheme,'-configuration','Release',
                    '-destination','generic/platform=iOS','-archivePath',archive,'-derivedDataPath',derived,
                    '-allowProvisioningUpdates','CODE_SIGN_STYLE=Automatic',"DEVELOPMENT_TEAM=#{team}"]
                else
                  archive, export, options, _team = args
                  binary + ['-exportArchive','-archivePath',archive,'-exportPath',export,'-exportOptionsPlist',options,
                    '-allowProvisioningUpdates']
                end
      command.concat(['-authenticationKeyPath',key_path,'-authenticationKeyID',key_id,'-authenticationKeyIssuerID',issuer_id])
      timeout = stage == 'archive' ? '3600' : '900'
      # xcodebuild's raw streams may contain account values; discard both. The
      # bounded helper reports only its fixed stage and timeout metadata.
      system('/usr/bin/ruby','--disable-gems',File.join(__dir__,'bounded-command.rb'),
        '--stage',"appstore-build-#{stage}",'--timeout-seconds',timeout,'--grace-seconds','5','--',*command,
        out:File::NULL,err:File::NULL)
      $?.exitstatus || 1
    end

    def xcode(root, stage, slug, *args)
      home = ENV.fetch('HOME')
      key_path = File.join(home,'Library','Application Support','iOS-Template','secrets',slug,'app-store-connect-production.p8')
      prefix = "ios-template/#{slug}/app-store-connect/production"
      wrapper = File.join(TOOL_ROOT,'tools/run-with-private-key.sh')
      secret = File.join(TOOL_ROOT,'tools/run-with-secret.sh')
      command = [wrapper,'--app',slug,'--file',key_path,'--env','ASC_PRIVATE_KEY_PATH','--',
        secret,'--service-name',"#{prefix}/key-id",'--env','ASC_KEY_ID','--',
        secret,'--service-name',"#{prefix}/issuer-id",'--env','ASC_ISSUER_ID','--',
        '/usr/bin/ruby','--disable-gems',File.join(TOOL_ROOT,'tools/lib/appstore-build.rb'),'xcode-child',stage,*args]
      env = {'PATH'=>'/usr/bin:/bin','LANG'=>'en_US.UTF-8','HOME'=>home}
      if ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
        env.merge!('IOS_TEMPLATE_TEST_MODE'=>'1','IOS_TEMPLATE_TEST_XCODEBUILD'=>ENV.fetch('IOS_TEMPLATE_TEST_XCODEBUILD'),
          'IOS_TEMPLATE_TEST_SECURITY_BIN'=>ENV.fetch('IOS_TEMPLATE_TEST_SECURITY_BIN'))
      end
      _output, _error, status = Open3.capture3(env,*command,unsetenv_others:true)
      status.exitstatus || 1
    end

    def export_options(team_id)
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" \
        "<plist version=\"1.0\"><dict><key>method</key><string>app-store-connect</string>" \
        "<key>destination</key><string>export</string><key>signingStyle</key><string>automatic</string>" \
        "<key>teamID</key><string>#{team_id}</string><key>manageAppVersionAndBuildNumber</key><false/>" \
        "</dict></plist>\n"
    end

    def append_event(context, type, fields={})
      refuse('invalid-event-type') unless EVENT_TYPES.include?(type)
      context[:number] += 1
      event = {'schemaVersion'=>1,'recordType'=>RECORD,'eventType'=>type,'eventSequence'=>context[:number],
        'previousEventDigest'=>context[:last_digest],'issue'=>context[:issue],'attempt'=>context[:attempt],
        'headSha'=>context[:head],'version'=>context[:version],'buildNumber'=>context[:build],
        'bundleId'=>context[:bundle],'contractDigest'=>context[:contract_digest],
        'checkedAt'=>Time.now.utc.iso8601}.merge(fields)
      bytes = JSON.generate(canonical(event)) + "\n"
      path = File.join(context[:directory],format('%04d-%s.json',context[:number],type))
      write_new(path,bytes)
      context[:last_digest] = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
      event
    end

    def new_attempt(root, issue, head, version, build, bundle, authority, module_name)
      issue_dir = safe_path(root,".artifacts/appstore-builds/#{issue}")
      safe_directory(issue_dir)
      attempt = "a#{SecureRandom.hex(12)}"
      directory = File.join(issue_dir,attempt)
      Dir.mkdir(directory,0700)
      context = {directory:directory,attempt:attempt,number:0,last_digest:nil,issue:issue,head:head,version:version,
        build:build,bundle:bundle,contract_digest:authority.fetch('contractDigest'),module:module_name}
      append_event(context,'started','teamId'=>authority.fetch('teamId'),'preflightDigest'=>authority.fetch('preflightDigest'))
      context
    end

    def resume_attempt(root, issue, attempt, head, version, build, bundle, authority, module_name)
      refuse('invalid-resume-attempt') unless attempt.is_a?(String) && attempt.match?(ATTEMPT)
      directory = safe_path(root,".artifacts/appstore-builds/#{issue}/#{attempt}")
      stat = File.lstat(directory)
      refuse('unowned-attempt') unless stat.directory? && stat.uid == Process.uid && stat.mode & 0777 == 0700
      names = Dir.children(directory)
      allowed = names.all? { |name| name.match?(/\A[0-9]{4}-(?:started|archive-complete|export-complete|upload-intent|upload-result|processing-readback|stage-failed)\.json\z/) ||
        ["#{module_name}.xcarchive",'ExportOptions.plist','export','DerivedData'].include?(name) }
      refuse('unsafe-attempt-contents') unless allowed && names.none? { |name| File.symlink?(File.join(directory,name)) }
      event_names = names.grep(/\A[0-9]{4}-.+\.json\z/).sort
      refuse('missing-attempt-history') if event_names.empty?
      previous = nil
      entries = event_names.each_with_index.map do |name,index|
        refuse('invalid-event-order') unless name.start_with?(format('%04d-',index+1))
        path = File.join(directory,name)
        bytes = read_owned_file(path,100_000)
        event = JSON.parse(bytes, object_class: AppStorePreparation::UniqueObject)
        refuse('attempt-history-mismatch') unless event['recordType'] == RECORD && event['schemaVersion'] == 1 &&
          event['eventSequence'] == index+1 && name == format('%04d-%s.json',index+1,event['eventType']) &&
          event['previousEventDigest'] == previous && event['issue'] == issue && event['attempt'] == attempt &&
          event['headSha'] == head && event['version'] == version && event['buildNumber'] == build &&
          event['bundleId'] == bundle && event['contractDigest'] == authority['contractDigest'] &&
          bytes == JSON.generate(canonical(event))+"\n"
        previous = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
        event
      end
      refuse('attempt-history-mismatch') unless entries.first['eventType'] == 'started' &&
        entries.first['teamId'] == authority['teamId'] &&
        entries.first['preflightDigest'].is_a?(String) && entries.first['preflightDigest'].match?(/\Asha256:[0-9a-f]{64}\z/)
      export = entries.find { |event| event['eventType'] == 'export-complete' }
      refuse('resume-requires-export') unless export && export['ipaName'] == "#{module_name}.ipa" &&
        export['ipaDigest'].is_a?(String) && export['ipaDigest'].match?(/\Asha256:[0-9a-f]{64}\z/)
      options = File.join(directory,'ExportOptions.plist')
      refuse('export-options-mismatch') unless read_owned_file(options,10_000) == export_options(authority['teamId'])
      archive = File.join(directory,"#{module_name}.xcarchive")
      archive_stat = File.lstat(archive)
      refuse('unsafe-archive') unless archive_stat.directory? && archive_stat.uid == Process.uid && !archive_stat.symlink?
      export_dir = File.join(directory,'export')
      export_stat = File.lstat(export_dir)
      refuse('unsafe-export-directory') unless export_stat.directory? && export_stat.uid == Process.uid &&
        !export_stat.symlink? && Dir.children(export_dir).none? { |name| File.symlink?(File.join(export_dir,name)) }
      ipa = File.join(export_dir,export['ipaName'])
      refuse('ipa-digest-mismatch') unless ipa_digest(ipa) == export['ipaDigest']
      context = {directory:directory,attempt:attempt,number:entries.length,last_digest:previous,issue:issue,head:head,
        version:version,build:build,bundle:bundle,contract_digest:authority['contractDigest'],module:module_name}
      [context,ipa,export['ipaDigest'],entries]
    end

    def polling_config
      return [60.0,2700.0] unless ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
      interval = Float(ENV.fetch('IOS_TEMPLATE_TEST_POLL_INTERVAL'))
      timeout = Float(ENV.fetch('IOS_TEMPLATE_TEST_POLL_TIMEOUT'))
      refuse('invalid-test-poll-config') unless interval.between?(0.01,1.0) && timeout.between?(0.05,10.0)
      [interval,timeout]
    end

    def poll(context, runner_path, app, ipa_digest_value)
      interval, timeout = polling_config
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        begin
          rows = build_list(runner_path,app,context[:version],context[:build])
          refuse('remote-build-ambiguous') unless rows.length <= 1
          if rows.length == 1
            detail = build_info(runner_path,app,context[:version],context[:build],rows.first.fetch('id'))
            append_event(context,'processing-readback',detail.merge('ipaDigest'=>ipa_digest_value))
            return ['valid',detail['buildId']] if detail['processingState'] == 'VALID'
            return ['failed',detail['buildId']] if %w[FAILED INVALID].include?(detail['processingState'])
          end
        rescue Refused => error
          append_event(context,'processing-readback','status'=>'unknown','ipaDigest'=>ipa_digest_value,'reason'=>error.message)
          return ['unknown',nil,error.message]
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          append_event(context,'processing-readback','status'=>'timeout','ipaDigest'=>ipa_digest_value)
          return ['unknown',nil]
        end
        sleep interval
      end
    end

    def execute(root, issue, head, version, build, resume)
      root = safe_root(root)
      refuse('invalid-issue') unless issue.is_a?(Integer) && issue.positive?
      refuse('invalid-head') unless head.match?(SHA)
      refuse('invalid-version') unless version.match?(VERSION)
      refuse('invalid-build-number') unless build.match?(BUILD)
      test_mode = ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
      refuse('tool-project-root-mismatch') unless test_mode || TOOL_ROOT == root
      overrides = ENV.keys.select { |key| key.start_with?('IOS_TEMPLATE_TEST_') }
      refuse('test-overrides-in-production') unless test_mode || overrides.empty?
      refuse('unknown-test-override') unless (overrides - TEST_KEYS - ['IOS_TEMPLATE_TEST_MODE']).empty?
      executable!(ENV.fetch('IOS_TEMPLATE_TEST_XCODEBUILD')) if test_mode
      executable!(ENV.fetch('IOS_TEMPLATE_TEST_ASC_RUNNER')) if test_mode
      executable!(ENV.fetch('IOS_TEMPLATE_TEST_SECURITY_BIN')) if test_mode
      polling_config
      clean_head(root,head)
      app = identity(root)
      authority = authority(root,issue,app.fetch('bundleId'),Time.now.utc)
      settings = release_facts(root,app.fetch('moduleName'))
      refuse('xcode-bundle-mismatch') unless settings['PRODUCT_BUNDLE_IDENTIFIER'] == authority['bundleId']
      refuse('xcode-version-mismatch') unless settings['MARKETING_VERSION'] == version
      refuse('xcode-build-number-mismatch') unless settings['CURRENT_PROJECT_VERSION'] == build
      refuse('manual-signing-settings') unless settings['CODE_SIGN_STYLE'] == 'Automatic' &&
        %w[PROVISIONING_PROFILE PROVISIONING_PROFILE_SPECIFIER].all? { |key| settings[key].nil? || settings[key].empty? }
      runner_path = runner(root)
      builds_root = safe_path(root,'.artifacts/appstore-builds')
      safe_directory(builds_root)
      lock_path = File.join(builds_root,'.upload.lock')
      File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW,0600) do |lock|
        stat = lock.stat
        refuse('unsafe-upload-lock') unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid && stat.mode & 0777 == 0600
        refuse('upload-already-active') unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        app_id_value = app_id(runner_path,app['bundleId'])
        remote_rows = build_list(runner_path,app_id_value,version,build)
        if resume
          context,ipa,ipa_hash,entries = resume_attempt(root,issue,resume,head,version,build,app['bundleId'],authority,app['moduleName'])
          refuse('remote-build-ambiguous') unless remote_rows.length <= 1
          if remote_rows.length == 1
            upload_issued = entries.any? { |event| event['eventType'] == 'upload-intent' }
            rejected = entries.any? { |event| event['eventType'] == 'upload-result' && event['status'] == 'failed' }
            refuse('duplicate-remote-build') unless upload_issued && !rejected
            detail = build_info(runner_path,app_id_value,version,build,remote_rows.first.fetch('id'))
            append_event(context,'processing-readback',detail.merge('ipaDigest'=>ipa_hash))
            return {'status'=>'valid','attempt'=>resume,'buildId'=>detail['buildId'],'releaseReady'=>false} if detail['processingState'] == 'VALID'
            return {'status'=>'failed','attempt'=>resume,'buildId'=>detail['buildId'],'releaseReady'=>false} if %w[FAILED INVALID].include?(detail['processingState'])
            status, build_id, reason = poll(context,runner_path,app_id_value,ipa_hash)
            result = {'status'=>status,'attempt'=>resume,'buildId'=>build_id,'releaseReady'=>false}
            result['reason'] = reason if reason
            return result
          end
          refuse('upload-already-issued') if entries.any? { |event| event['eventType'] == 'upload-intent' }
        else
          refuse('duplicate-remote-build') unless remote_rows.empty?
          context = new_attempt(root,issue,head,version,build,app['bundleId'],authority,app['moduleName'])
          directory = context[:directory]
          archive = File.join(directory,"#{app['moduleName']}.xcarchive")
          derived = File.join(directory,'DerivedData')
          options = File.join(directory,'ExportOptions.plist')
          write_new(options,export_options(authority['teamId']))
          archive_status = xcode(root,'archive',app['appSlug'],File.join(root,"#{app['moduleName']}.xcodeproj"),app['moduleName'],archive,derived,authority['teamId'])
          unless archive_status.zero?
            append_event(context,'stage-failed','stage'=>'archive','exitStatus'=>archive_status,'timedOut'=>archive_status == 124)
            return {'status'=>'failed','attempt'=>context[:attempt],'releaseReady'=>false}
          end
          archive_stat = File.lstat(archive)
          refuse('archive-output-invalid') unless archive_stat.directory? && archive_stat.uid == Process.uid && !archive_stat.symlink?
          append_event(context,'archive-complete')
          export = File.join(directory,'export')
          export_status = xcode(root,'export',app['appSlug'],archive,export,options,authority['teamId'])
          unless export_status.zero?
            append_event(context,'stage-failed','stage'=>'export','exitStatus'=>export_status,'timedOut'=>export_status == 124)
            return {'status'=>'failed','attempt'=>context[:attempt],'releaseReady'=>false}
          end
          ipa_files = Dir.children(export).select { |name| name.end_with?('.ipa') }
          refuse('export-ipa-ambiguous') unless ipa_files == ["#{app['moduleName']}.ipa"]
          ipa = File.join(export,ipa_files.first)
          ipa_hash = ipa_digest(ipa)
          append_event(context,'export-complete','ipaName'=>ipa_files.first,'ipaDigest'=>ipa_hash)
        end
        # The intent is durable before the only upload invocation. A lost or
        # ambiguous response can be resolved by readback, never by replay.
        begin
          clean_head(root,head)
          refreshed = authority(root,issue,app.fetch('bundleId'),Time.now.utc)
          refuse('authority-changed-before-upload') unless refreshed.values_at('teamId','bundleId','contractDigest') ==
            authority.values_at('teamId','bundleId','contractDigest')
          refuse('ipa-digest-mismatch') unless ipa_digest(ipa) == ipa_hash
          refuse('duplicate-remote-build') unless build_list(runner_path,app_id_value,version,build).empty?
        rescue Refused => error
          append_event(context,'stage-failed','reason'=>error.message)
          return {'status'=>'blocked','attempt'=>context[:attempt],'reason'=>error.message,'releaseReady'=>false}
        end
        append_event(context,'upload-intent','ipaDigest'=>ipa_hash)
        response, code = asc(runner_path,'builds','upload','--app',app_id_value,'--ipa',ipa)
        # asc 5.4.0 internal/cli/builds/builds_commands.go prints
        # internal/asc/output_builds.go BuildUploadResult, not a JSON:API resource.
        accepted = code.zero? && response.is_a?(Hash) && response['uploaded'] == true &&
          response['uploadId'].is_a?(String) && response['uploadId'].match?(/\A[A-Za-z0-9_-]{1,128}\z/) &&
          response['fileId'].is_a?(String) && response['fileId'].match?(/\A[A-Za-z0-9_-]{1,128}\z/)
        rejected = !accepted && response.is_a?(Hash) && response['errors'].is_a?(Array) && !response['errors'].empty? &&
          response['errors'].all? { |entry| entry.is_a?(Hash) && entry['status'] == '422' }
        outcome = accepted ? 'accepted' : rejected ? 'failed' : 'unknown'
        result_fields = {'status'=>outcome,'ipaDigest'=>ipa_hash}
        result_fields.merge!('uploadId'=>response['uploadId'],'fileId'=>response['fileId']) if accepted
        append_event(context,'upload-result',result_fields)
        return {'status'=>outcome,'attempt'=>context[:attempt],'releaseReady'=>false} unless accepted
        status, build_id, reason = poll(context,runner_path,app_id_value,ipa_hash)
        result = {'status'=>status,'attempt'=>context[:attempt],'buildId'=>build_id,'releaseReady'=>false}
        result['reason'] = reason if reason
        result
      end
    end

    def main(args)
      if args.first == 'xcode-child'
        args.shift
        stage = args.shift
        return xcode_child(stage,args)
      end
      options = {}
      parser = OptionParser.new do |cli|
        cli.on('--project-root PATH') { |value| refuse('duplicate-project-root') if options.key?(:root); options[:root] = value }
        cli.on('--issue N') { |value| refuse('duplicate-issue') if options.key?(:issue); options[:issue] = Integer(value,10) }
        cli.on('--head-sha SHA') { |value| refuse('duplicate-head') if options.key?(:head); options[:head] = value }
        cli.on('--version VERSION') { |value| refuse('duplicate-version') if options.key?(:version); options[:version] = value }
        cli.on('--build-number N') { |value| refuse('duplicate-build') if options.key?(:build); options[:build] = value }
        cli.on('--resume-attempt ID') { |value| refuse('duplicate-resume') if options.key?(:resume); options[:resume] = value }
      end
      parser.parse!(args)
      refuse('invalid-arguments') unless args.empty? && options.values_at(:root,:issue,:head,:version,:build).all?
      result = execute(options[:root],options[:issue],options[:head],options[:version],options[:build],options[:resume])
      puts JSON.generate(result.merge('schemaVersion'=>1,'recordType'=>RECORD))
      result['status'] == 'valid' ? 0 : 1
    rescue Refused => error
      puts JSON.generate({'schemaVersion'=>1,'recordType'=>RECORD,'status'=>'blocked','reason'=>error.message,'releaseReady'=>false})
      1
    rescue IssueContract::ValidationError, Ownership::ValidationError, AppStorePreparation::InvalidInput,
           AscCLI::Refused, OptionParser::ParseError, JSON::ParserError, Psych::Exception,
           SystemCallError, IOError, ArgumentError, KeyError, TypeError
      puts JSON.generate({'schemaVersion'=>1,'recordType'=>RECORD,'status'=>'blocked','releaseReady'=>false})
      1
    rescue StandardError
      puts JSON.generate({'schemaVersion'=>1,'recordType'=>RECORD,'status'=>'blocked','releaseReady'=>false})
      1
    end
  end
end

exit IOSTemplate::AppStoreBuild.main(ARGV) if $PROGRAM_NAME == __FILE__
