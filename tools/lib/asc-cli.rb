# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'
require 'tmpdir'
require 'tempfile'
require 'open3'
require 'fiddle'
require 'uri'
require 'yaml'

module AscCLI
  class Refused < StandardError; end
  ROOT = File.expand_path('../..', __dir__)
  PIN_KEYS = %w[asset checksumsAsset checksumsSha256 checksumsUrl platform repository reviewedAt schemaVersion sha256 url version].freeze
  TEST_KEYS = %w[IOS_TEMPLATE_TEST_ASC_PIN IOS_TEMPLATE_TEST_ASC_INSTALL_ROOT IOS_TEMPLATE_TEST_ASC_RELEASE_DIR IOS_TEMPLATE_TEST_ASC_TIMEOUT IOS_TEMPLATE_TEST_SECURITY_BIN].freeze
  SECRET_KEYS = %w[ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_PATH].freeze
  # Deliberately a subset of 5.4.0's public command flags. No URL pagination,
  # profile/config, debug, report-file, or credential flags.
  # Sources at https://github.com/rorkai/App-Store-Connect-CLI/tree/5.4.0:
  # internal/cli/{apps/apps.go,apps/app_info.go,versions/versions.go,bundleids/bundle_ids.go}
  # Metadata source: internal/cli/localizations/{localizations.go,update.go}.
  # update.go defines --name, --subtitle, --description, --keywords,
  # --promotional-text, --whats-new and the --app/--version/--type/--locale
  # selectors. Empty field flags are ignored by asc 5.4.0; refuse them here.
  # Build source at 5.4.0: internal/cli/builds/builds_commands.go defines
  # BuildsUploadCommand (--app, --ipa), BuildsListCommand (--app, --version,
  # --build-number, --platform, --processing-state, --paginate), and
  # BuildsInfoCommand (the four exact app-scoped selectors). The list version
  # is CFBundleShortVersionString; BuildAttributes.version is CFBundleVersion
  # (internal/asc/client_builds.go). Info adds a preReleaseVersion include.
  # Release sections source at 5.4.0:
  # internal/cli/versions/versions.go: update --version-id/--copyright,
  # attach-build --version-id/--build-id;
  # internal/cli/shared/categories_command.go: set --app/--primary;
  # internal/cli/apps/app_info.go: view --app/--include;
  # internal/cli/localizations/update.go: --privacy-policy-url/--support-url;
  # internal/cli/assets/assets_screenshots.go: list/upload
  # --version-localization/--path/--device-type (no --replace);
  # internal/cli/reviews/{review_submit.go,review_overview.go}:
  # submit --app/--version-id/--build-id/--confirm and status --app/--version-id.
  # TestFlight 5.4.0 source: internal/cli/builds/builds.go add-groups uses
  # app/build-number/version/platform/group; internal/cli/testflight/beta_groups.go
  # groups list supports app/paginate or build-id/app (the latter paginates
  # internally); internal/cli/testflight/testflight_review.go exposes review
  # submit --build-id/--confirm and submissions list --build-id/--paginate.
  # internal/cli/testflight/{beta_groups.go,build_group_membership.go} produces membership readback;
  # internal/asc/output_beta.go: appId/buildId/complete/groupCount/groups[id,type,membership], optional failures.
  OPERATIONS = {
    'appstore.inspect_app' => {
      %w[apps list] => {'--bundle-id'=>:identifier, '--name'=>:text, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[apps info view] => {'--app'=>:id, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[versions list] => {'--app'=>:id, '--version'=>:version, '--platform'=>:platform, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[bundle-ids list] => {'--identifier'=>:identifier, '--limit'=>:limit, '--paginate'=>:boolean}
    }.freeze,
    'appstore.update_metadata' => {
      %w[apps list] => {'--bundle-id'=>:identifier, '--name'=>:text, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[apps info view] => {'--app'=>:id, '--limit'=>:limit, '--paginate'=>:boolean, '--include'=>:app_info_include},
      %w[versions list] => {'--app'=>:id, '--version'=>:version, '--platform'=>:platform, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[bundle-ids list] => {'--identifier'=>:identifier, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[builds list] => {'--app'=>:id, '--version'=>:version, '--build-number'=>:build_number, '--platform'=>:platform, '--paginate'=>:boolean},
      %w[builds info] => {'--app'=>:id, '--version'=>:version, '--build-number'=>:build_number, '--platform'=>:platform},
      %w[localizations list] => {'--version'=>:resource_id, '--app'=>:id, '--type'=>:localization_type, '--locale'=>:locale, '--paginate'=>:boolean},
      %w[localizations update] => {'--version'=>:resource_id, '--app'=>:id, '--type'=>:localization_type, '--locale'=>:locale,
                                    '--name'=>:localization_name, '--subtitle'=>:localization_subtitle,
                                    '--description'=>:localization_description, '--keywords'=>:localization_keywords,
                                    '--promotional-text'=>:localization_promotional, '--whats-new'=>:localization_whats_new,
                                    '--privacy-policy-url'=>:https_url, '--support-url'=>:https_url},
      %w[versions update] => {'--version-id'=>:resource_id, '--copyright'=>:copyright},
      %w[categories list] => {'--paginate'=>:boolean},
      %w[categories set] => {'--app'=>:id, '--primary'=>:category},
      %w[screenshots list] => {'--version-localization'=>:resource_id},
      %w[screenshots upload] => {'--version-localization'=>:resource_id, '--path'=>:screenshot_path, '--device-type'=>:screenshot_type}
    }.freeze,
    'appstore.upload_build' => {
      %w[apps list] => {'--bundle-id'=>:identifier},
      %w[builds upload] => {'--app'=>:id, '--ipa'=>:ipa},
      %w[builds list] => {'--app'=>:id, '--version'=>:version, '--build-number'=>:build_number,
                          '--platform'=>:platform, '--processing-state'=>:processing_state, '--paginate'=>:boolean},
      %w[builds info] => {'--app'=>:id, '--version'=>:version, '--build-number'=>:build_number,
                          '--platform'=>:platform}
    }.freeze,
    'appstore.submit_review' => {
      %w[apps list] => {'--bundle-id'=>:identifier},
      %w[bundle-ids list] => {'--identifier'=>:identifier},
      %w[versions list] => {'--app'=>:id, '--version'=>:version, '--platform'=>:platform},
      %w[builds list] => {'--app'=>:id, '--version'=>:version, '--build-number'=>:build_number, '--platform'=>:platform, '--paginate'=>:boolean},
      %w[builds info] => {'--app'=>:id, '--version'=>:version, '--build-number'=>:build_number, '--platform'=>:platform},
      %w[versions attach-build] => {'--version-id'=>:resource_id, '--build-id'=>:resource_id},
      %w[review submit] => {'--app'=>:id, '--version-id'=>:resource_id, '--build-id'=>:resource_id, '--confirm'=>:boolean},
      %w[review status] => {'--app'=>:id, '--version-id'=>:resource_id, '--platform'=>:platform}
    }.freeze,
    'appstore.distribute_testflight' => {
      %w[apps list] => {'--bundle-id'=>:identifier},
      %w[builds list] => {'--app'=>:id, '--version'=>:version, '--build-number'=>:build_number, '--platform'=>:platform, '--paginate'=>:boolean},
      %w[builds info] => {'--app'=>:id, '--version'=>:version, '--build-number'=>:build_number, '--platform'=>:platform},
      %w[testflight groups list] => {'--app'=>:id, '--paginate'=>:boolean, '--build-id'=>:resource_id},
      %w[builds add-groups] => {'--app'=>:id, '--build-number'=>:build_number, '--version'=>:version, '--platform'=>:platform, '--group'=>:resource_id},
      %w[testflight review submissions list] => {'--build-id'=>:resource_id, '--paginate'=>:boolean},
      %w[testflight review submit] => {'--build-id'=>:resource_id, '--confirm'=>:boolean}
    }.freeze
  }.freeze
  LOCALIZATION_TEXT_LIMITS = {
    localization_name: [2, 30, nil], localization_subtitle: [1, 30, nil],
    localization_description: [1, 4000, nil], localization_keywords: [1, nil, 100],
    localization_promotional: [1, 170, nil], localization_whats_new: [1, 4000, nil]
  }.freeze
  LOCALIZATION_FIELD_FLAGS = {
    '--name'=>:localization_name, '--subtitle'=>:localization_subtitle,
    '--description'=>:localization_description, '--keywords'=>:localization_keywords,
    '--promotional-text'=>:localization_promotional, '--whats-new'=>:localization_whats_new,
    '--privacy-policy-url'=>:https_url, '--support-url'=>:https_url
  }.freeze
  module_function

  def refuse(message)
    raise Refused, message
  end

  # Check every existing path component, including dangling links. Never resolve
  # a link and then mistake the resolved file for the requested physical path.
  def physical_path!(path)
    refuse('path must be canonical and absolute') unless path.is_a?(String) && path.start_with?('/') && File.expand_path(path) == path && !path.match?(/[\x00-\x1f\x7f]/)
    cursor = '/'
    path.split('/').reject(&:empty?).each do |part|
      cursor = File.join(cursor, part)
      begin
        refuse('symlink path refused') if File.lstat(cursor).symlink?
      rescue Errno::ENOENT
        break
      end
    end
    path
  end

  def regular!(path)
    physical_path!(path)
    stat = File.lstat(path)
    refuse('regular single-link file required') unless stat.file? && stat.nlink == 1
    stat
  end

  def read_regular(path, max_bytes = nil)
    before = regular!(path)
    refuse('file is too large') if max_bytes && before.size > max_bytes
    File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
      after = file.stat
      refuse('file changed while opening') unless [before.dev, before.ino, before.size] == [after.dev, after.ino, after.size] && after.file? && after.nlink == 1
      bytes = file.read
      refuse('file changed while reading') unless bytes.bytesize == before.size
      bytes
    end
  end

  def configuration
    test = ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
    overrides = ENV.keys.select { |key| key.start_with?('IOS_TEMPLATE_TEST_ASC_') || key == 'IOS_TEMPLATE_TEST_SECURITY_BIN' }
    refuse('test overrides are not allowed in production mode') if !test && !overrides.empty?
    refuse('unknown test override') unless (overrides - TEST_KEYS).empty?
    home = physical_path!(ENV.fetch('HOME'))
    refuse('HOME is unavailable') unless File.directory?(home)
    pin_path = File.join(ROOT, 'Config/asc-cli.json')
    install_root = File.join(home, 'Library', 'Application Support', 'iOS-Template', 'tools', 'asc')
    timeout = 120
    if test
      %w[IOS_TEMPLATE_TEST_ASC_PIN IOS_TEMPLATE_TEST_ASC_INSTALL_ROOT IOS_TEMPLATE_TEST_ASC_RELEASE_DIR IOS_TEMPLATE_TEST_SECURITY_BIN].each do |key|
        physical_path!(ENV.fetch(key))
      end
      regular!(ENV.fetch('IOS_TEMPLATE_TEST_ASC_PIN'))
      regular!(ENV.fetch('IOS_TEMPLATE_TEST_SECURITY_BIN'))
      refuse('test security executable is invalid') unless File.executable?(ENV.fetch('IOS_TEMPLATE_TEST_SECURITY_BIN'))
      refuse('test release directory is invalid') unless File.directory?(ENV.fetch('IOS_TEMPLATE_TEST_ASC_RELEASE_DIR'))
      pin_path = ENV.fetch('IOS_TEMPLATE_TEST_ASC_PIN')
      install_root = ENV.fetch('IOS_TEMPLATE_TEST_ASC_INSTALL_ROOT')
      timeout_text = ENV.fetch('IOS_TEMPLATE_TEST_ASC_TIMEOUT', '120')
      refuse('test timeout is invalid') unless timeout_text.match?(/\A[1-9][0-9]*\z/) && timeout_text.to_i <= 120
      timeout = timeout_text.to_i
    end
    pin = validate_pin(pin_path)
    {test: test, home: home, pin: pin, root: install_root, binary: File.join(install_root, pin.fetch('version'), 'asc'), timeout: timeout}
  end

  def validate_pin(path)
    bytes = read_regular(path, 16_384)
    pin = JSON.parse(bytes)
    refuse('pin schema or canonical bytes are invalid') unless pin.is_a?(Hash) && pin.keys == PIN_KEYS && JSON.generate(pin.sort.to_h) == bytes && pin['schemaVersion'].instance_of?(Integer) && pin['schemaVersion'] == 1
    refuse('pin fields are invalid') unless (PIN_KEYS - ['schemaVersion']).all? { |key| pin[key].is_a?(String) }
    version = pin.fetch('version')
    refuse('pin version is invalid') unless version.match?(/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/)
    asset = "asc_#{version}_macOS_arm64"
    checksums = "asc_#{version}_checksums.txt"
    release = "https://github.com/rorkai/App-Store-Connect-CLI/releases/download/#{version}/"
    refuse('pin release identity differs') unless pin['repository'] == 'rorkai/App-Store-Connect-CLI' && pin['platform'] == 'macOS_arm64' && pin['asset'] == asset && pin['checksumsAsset'] == checksums && pin['url'] == release+asset && pin['checksumsUrl'] == release+checksums
    refuse('pin digests are invalid') unless %w[sha256 checksumsSha256].all? { |key| pin[key].match?(/\A[0-9a-f]{64}\z/) }
    stamp = pin.fetch('reviewedAt')
    refuse('pin review timestamp is invalid') unless stamp.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/) && Time.iso8601(stamp).utc.iso8601 == stamp
    pin
  end

  def secure_directory!(path)
    physical_path!(path)
    unless File.exist?(path)
      parent = File.dirname(path)
      secure_directory!(parent) unless File.directory?(parent)
      Dir.mkdir(path, 0700)
    end
    stat = File.lstat(path)
    refuse('installation directory ownership or mode is invalid') unless stat.directory? && stat.uid == Process.uid && stat.mode & 0777 == 0700
  end

  def binary_bytes(config)
    bytes = read_regular(config.fetch(:binary))
    stat = File.lstat(config.fetch(:binary))
    refuse('installed binary ownership or mode is invalid') unless stat.uid == Process.uid && stat.mode & 0777 == 0755
    refuse('installed binary digest differs from pin') unless Digest::SHA256.hexdigest(bytes) == config.fetch(:pin).fetch('sha256')
    bytes
  end

  def fetch_release(config, name, url, destination)
    if config.fetch(:test)
      bytes = read_regular(File.join(ENV.fetch('IOS_TEMPLATE_TEST_ASC_RELEASE_DIR'), name))
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.write(bytes) }
    else
      # -q excludes user curl config; redirects must remain HTTPS as well.
      _, _, status = Open3.capture3({'PATH'=>'/usr/bin:/bin'}, '/usr/bin/curl', '-q', '--proto', '=https', '--proto-redir', '=https', '--fail', '--silent', '--show-error', '--location', '--connect-timeout', '15', '--max-time', '120', '--output', destination, url, unsetenv_others: true)
      refuse('release download failed') unless status.success?
      File.chmod(0600, destination)
    end
  end

  def install(config, temporary)
    physical_path!(temporary)
    refuse('temporary directory is invalid') unless File.directory?(temporary) && File.stat(temporary).mode & 0777 == 0700
    unless config.fetch(:test)
      machine, status = Open3.capture2('/usr/bin/uname', '-m')
      refuse('macOS arm64 is required') unless RUBY_PLATFORM.include?('darwin') && status.success? && machine.strip == 'arm64'
    end
    target = config.fetch(:binary)
    physical_path!(target)
    if File.exist?(target)
      binary_bytes(config)
      puts 'asc already installed and verified'
      return
    end
    pin = config.fetch(:pin)
    checksums_path = File.join(temporary, 'checksums')
    asset_path = File.join(temporary, 'asset')
    fetch_release(config, pin.fetch('checksumsAsset'), pin.fetch('checksumsUrl'), checksums_path)
    checksums = read_regular(checksums_path, 65_536)
    refuse('checksums file digest differs') unless Digest::SHA256.hexdigest(checksums) == pin.fetch('checksumsSha256')
    rows = checksums.lines.map { |line| line.chomp.match(/\A([0-9a-f]{64})  ([A-Za-z0-9_.-]+)\z/) }
    refuse('checksums file format is invalid') unless !rows.empty? && rows.all?
    matching = rows.select { |row| row[2] == pin.fetch('asset') }
    refuse('checksums asset entry differs') unless matching.length == 1 && matching.first[1] == pin.fetch('sha256')
    fetch_release(config, pin.fetch('asset'), pin.fetch('url'), asset_path)
    bytes = read_regular(asset_path)
    refuse('release binary digest differs') unless Digest::SHA256.hexdigest(bytes) == pin.fetch('sha256')
    secure_directory!(config.fetch(:root))
    directory = File.dirname(target)
    secure_directory!(directory)
    # macOS renamex_np(RENAME_EXCL) atomically refuses any existing destination,
    # including symlinks. The staging file is on the destination filesystem.
    Tempfile.create(['.asc-', '.partial'], directory) do |stage|
      stage.binmode
      stage.write(bytes)
      stage.flush
      stage.fsync
      stage.chmod(0755)
      physical_path!(directory)
      rename = Fiddle::Function.new(Fiddle::Handle::DEFAULT['renamex_np'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      result = rename.call(stage.path, target, 0x00000004)
      if result != 0
        refuse('atomic installation failed') unless Fiddle.last_error == Errno::EEXIST::Errno
        binary_bytes(config) # A concurrent same-byte install is idempotent.
      end
    end
    puts 'asc installed and verified'
  end

  def command_arguments(args, package_root: File.join(ROOT, 'App Store'))
    refuse('usage: asc-run.sh --operation OPERATION -- ASC_ARGS') unless args.length >= 5 && args[0] == '--operation' && args[2] == '--'
    table = OPERATIONS[args[1]]
    refuse('operation is not allowlisted') unless table
    tail = args.drop(3)
    command = table.keys.find { |prefix| tail.take(prefix.length) == prefix }
    refuse('subcommand is not allowlisted') unless command
    flags = table.fetch(command).merge('--output'=>:output)
    metadata_command = args[1] == 'appstore.update_metadata' && command.first == 'localizations'
    remaining = tail.drop(command.length)
    forwarded = command.dup
    seen = []
    until remaining.empty?
      flag = remaining.shift
      type = flags[flag]
      refuse('flag is not allowlisted or repeated') unless type && !seen.include?(flag)
      seen << flag
      if type == :boolean
        forwarded << flag
        next
      end
      value = remaining.shift
      localization_text = LOCALIZATION_TEXT_LIMITS.key?(type)
      if type == :ipa
        valid = valid_ipa?(value)
      elsif type == :screenshot_path
        valid = valid_screenshot_path?(value)
      elsif localization_text
        refuse('flag value is invalid') unless value.is_a?(String) && value.valid_encoding? && !value.empty? &&
          !value.match?(/[\x00-\x09\x0b-\x1f\x7f]/)
        minimum, character_maximum, byte_maximum = LOCALIZATION_TEXT_LIMITS.fetch(type)
        # Apple's character limits are checked conservatively in both Unicode
        # code points and UTF-16 units. Keywords have an explicit UTF-8 byte cap.
        characters = value.length
        units = value.encode(Encoding::UTF_16BE).bytesize / 2
        valid = characters >= minimum && units >= minimum &&
          (!character_maximum || characters <= character_maximum && units <= character_maximum) &&
          (!byte_maximum || value.bytesize <= byte_maximum)
      else
        refuse('flag value is invalid') unless value && !value.empty? && value.bytesize <= (type == :https_url ? 2048 : 256) && !value.start_with?('-') && !value.match?(/[\x00-\x1f\x7f]/) && !value.include?('$') && !value.include?('`')
        valid = case type
              when :id then value.match?(/\A[1-9][0-9]*\z/)
              when :resource_id then value.match?(/\A[A-Za-z0-9_-]{1,128}\z/)
              when :localization_type then %w[version app-info].include?(value)
              when :locale then %w[en-US ja].include?(value)
              when :identifier then value.match?(/\A[A-Za-z0-9][A-Za-z0-9.-]*\z/)
              when :limit then value.match?(/\A[1-9][0-9]*\z/) && value.to_i <= 200
              when :version then value.match?(/\A[0-9]+(?:\.[0-9]+){0,2}\z/)
              when :build_number then value.match?(/\A[1-9][0-9]*\z/)
              when :platform then %w[IOS MAC_OS TV_OS VISION_OS].include?(value)
              when :processing_state then %w[VALID PROCESSING FAILED INVALID all].include?(value)
              when :output then value == 'json'
              when :text then true
              when :copyright then value.length.between?(1, 200)
              when :category then value.match?(/\A[A-Z][A-Z0-9_]{1,63}\z/)
              when :app_info_include then value == 'primaryCategory'
              when :screenshot_type then %w[APP_IPHONE_67 APP_IPAD_PRO_3GEN_129].include?(value)
              when :https_url
                valid_sealed_https_url?(value, flag, package_root)
              end
      end
      refuse('flag value is invalid') unless valid
      forwarded.concat(localization_text ? ["#{flag}=#{value}"] : [flag, value]) unless type == :output
    end
    refuse('explicit app is required') if [%w[apps info view], %w[versions list]].include?(command) && !seen.include?('--app')
    if args[1] == 'appstore.upload_build'
      case command
      when %w[apps list]
        refuse('exact bundle selector required') unless seen.include?('--bundle-id')
      when %w[builds upload]
        refuse('exact upload selectors required') unless %w[--app --ipa].all? { |flag| seen.include?(flag) }
      when %w[builds list]
        refuse('exact build selectors and pagination required') unless %w[--app --version --build-number --platform --paginate].all? { |flag| seen.include?(flag) }
      when %w[builds info]
        refuse('exact build selectors required') unless %w[--app --version --build-number --platform].all? { |flag| seen.include?(flag) }
      end
    end
    if args[1] == 'appstore.distribute_testflight'
      exact = case command
              when %w[apps list] then %w[--bundle-id]
              when %w[builds list] then %w[--app --version --build-number --platform --paginate]
              when %w[builds info] then %w[--app --version --build-number --platform]
              when %w[testflight groups list]
                seen.include?('--build-id') ? %w[--app --build-id] : %w[--app --paginate]
              when %w[builds add-groups] then %w[--app --build-number --version --platform --group]
              when %w[testflight review submissions list] then %w[--build-id --paginate]
              when %w[testflight review submit] then %w[--build-id --confirm]
              end
      refuse('exact TestFlight selectors required') unless (seen - ['--output']).sort == exact.sort
      platform = tail.each_cons(2).find { |pair| pair.first == '--platform' }&.last
      refuse('TestFlight requires IOS platform') if exact.include?('--platform') && platform != 'IOS'
    end
    if metadata_command
      kind = tail.each_cons(2).find { |pair| pair.first == '--type' }&.last
      refuse('localization type and locale are required') unless %w[version app-info].include?(kind) && seen.include?('--locale')
      selector = kind == 'version' ? '--version' : '--app'
      other = kind == 'version' ? '--app' : '--version'
      refuse('localization parent is invalid') unless seen.include?(selector) && !seen.include?(other)
      if command == %w[localizations update]
        allowed = kind == 'version' ? %w[--description --keywords --promotional-text --whats-new --support-url] : %w[--name --subtitle --privacy-policy-url]
        supplied = seen & LOCALIZATION_FIELD_FLAGS.keys
        refuse('localization update fields are invalid') if supplied.empty? || !(supplied - allowed).empty?
      end
    end
    if command == %w[screenshots upload]
      refuse('exact screenshot selectors required') unless %w[--version-localization --path --device-type].all? { |flag| seen.include?(flag) }
    end
    if command == %w[versions update]
      refuse('exact version update selectors required') unless %w[--version-id --copyright].all? { |flag| seen.include?(flag) }
    end
    if command == %w[categories set]
      refuse('exact category selectors required') unless %w[--app --primary].all? { |flag| seen.include?(flag) }
    end
    if command == %w[versions attach-build]
      refuse('exact build attachment selectors required') unless %w[--version-id --build-id].all? { |flag| seen.include?(flag) }
    end
    if command == %w[review submit]
      refuse('exact submission selectors required') unless %w[--app --version-id --build-id --confirm].all? { |flag| seen.include?(flag) }
    end
    forwarded + ['--output', 'json']
  end

  def valid_ipa?(value)
    return false unless value.is_a?(String) && value.bytesize.between?(1, 4096) && File.extname(value) == '.ipa'
    physical_path!(value)
    artifacts = File.realpath(File.join(ROOT, '.artifacts'))
    return false unless value.start_with?(File.join(artifacts, 'appstore-builds') + '/')
    regular!(value)
    true
  rescue Refused, SystemCallError
    false
  end

  def valid_screenshot_path?(value)
    return false unless value.is_a?(String) && value.bytesize.between?(1, 4096) && File.extname(value) == '.png'
    physical_path!(value)
    regular!(value)
    return false if File.size(value).zero?
    package_root = if ENV['IOS_TEMPLATE_TEST_MODE'] == '1'
                     prefix = value.split('/App Store/screenshots/', 2)
                     return false unless prefix.length == 2
                     File.join(prefix.first, 'App Store')
                   else
                     File.join(ROOT, 'App Store')
                   end
    screenshots = File.join(package_root, 'screenshots')
    return false unless value.start_with?(screenshots + '/')
    relative = value.delete_prefix(screenshots + '/')
    return false unless relative.match?(%r{\A(?:en-US|ja)/(?:iphone-6\.9|ipad-13)/[0-9]{2}-[a-z0-9-]+\.png\z})
    manifest = JSON.parse(read_regular(File.join(screenshots, 'manifest.json'), 1_000_000))
    return false unless manifest['schemaVersion'] == 1 && manifest['cases'].is_a?(Array)
    rows = manifest['cases'].select { |entry| entry.is_a?(Hash) && entry['path'] == relative }
    rows.length == 1 && rows.first['digest'] == "sha256:#{Digest::SHA256.file(value).hexdigest}"
  rescue Refused, SystemCallError, JSON::ParserError
    false
  end

  def valid_sealed_https_url?(value, flag, package_root)
    return false unless %w[--privacy-policy-url --support-url].include?(flag)
    uri = URI.parse(value)
    return false unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.fragment
    physical_path!(package_root)
    app = YAML.safe_load(read_regular(File.join(package_root, 'metadata', 'app.yml'), 65_536),
      permitted_classes: [], permitted_symbols: [], aliases: false)
    key = flag == '--privacy-policy-url' ? 'privacyPolicyURL' : 'supportURL'
    app.is_a?(Hash) && app['schemaVersion'] == 1 && app[key] == value
  rescue Refused, SystemCallError, URI::InvalidURIError, Psych::Exception
    false
  end

  def app_slug
    identity = JSON.parse(read_regular(File.join(ROOT, 'Config/app-identity.json'), 16_384))
    keys = %w[appSlug bundleId displayName moduleName schemaVersion sourceIdentityVersion]
    refuse('app identity is invalid') unless identity.is_a?(Hash) && identity.keys.sort == keys && identity['schemaVersion'] == 1 && identity['sourceIdentityVersion'] == 1
    slug = identity['appSlug']
    refuse('app slug is invalid') unless slug.is_a?(String) && slug.bytesize <= 50 && slug.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
    slug
  end

  def bounded(config, command)
    ['/usr/bin/ruby', '--disable-gems', File.join(__dir__, 'bounded-command.rb'), '--stage', 'asc-cli', '--timeout-seconds', config.fetch(:timeout).to_s, '--grace-seconds', '1', '--'] + command
  end

  def run(config, args)
    command_arguments(args)
    binary_bytes(config)
    slug = app_slug
    private_key = File.join(config.fetch(:home), 'Library', 'Application Support', 'iOS-Template', 'secrets', slug, 'app-store-connect-production.p8')
    secret_wrapper = File.join(ROOT, 'tools/run-with-secret.sh')
    command = [secret_wrapper, '--service-name', "ios-template/#{slug}/app-store-connect/production/key-id", '--env', 'ASC_KEY_ID', '--',
               secret_wrapper, '--service-name', "ios-template/#{slug}/app-store-connect/production/issuer-id", '--env', 'ASC_ISSUER_ID', '--',
               File.join(ROOT, 'tools/run-with-private-key.sh'), '--app', slug, '--file', private_key, '--env', 'ASC_PRIVATE_KEY_PATH', '--',
               '/usr/bin/ruby', '--disable-gems', File.expand_path(__FILE__), 'exec-child'] + args
    # Real HOME is retained ONLY for the existing secret wrappers. All ambient
    # ASC/proxy/debug/Ruby/shell settings are excluded before entering the chain.
    environment = {'PATH'=>'/usr/bin:/bin', 'HOME'=>config.fetch(:home), 'LANG'=>'en_US.UTF-8'}
    if config.fetch(:test)
      environment['IOS_TEMPLATE_TEST_MODE'] = '1'
      TEST_KEYS.each { |key| environment[key] = ENV[key] if ENV.key?(key) }
    end
    pid = Process.spawn(environment, *bounded(config, command), unsetenv_others: true)
    _, status = Process.waitpid2(pid)
    status.exitstatus || 128 + status.termsig
  end

  def exec_child(config, args)
    # The outer bounded-command owns this entire process group, including both
    # asc invocations. Do not create a nested process group that escapes it.
    Signal.trap('TERM') { exit 143 }
    Signal.trap('INT') { exit 130 }
    forwarded = command_arguments(args)
    binary_bytes(config)
    secrets = SECRET_KEYS.map { |key| ENV.fetch(key) }
    refuse('child credentials are unavailable') unless secrets.all? { |value| !value.empty? && !value.match?(/[\r\n\0]/) }
    # No raw child output or credential digest is written to any file.
    secret_pattern = Regexp.union(secrets.sort_by { |s| -s.bytesize }.map(&:b))
    redact = lambda { |text| text.b.gsub(secret_pattern, '[REDACTED]') }
    Dir.mktmpdir('ios-template-asc-home.', '/private/tmp') do |isolated_home|
      environment = {'PATH'=>'/usr/bin:/bin', 'HOME'=>isolated_home, 'ASC_TELEMETRY_DISABLED'=>'1', 'DO_NOT_TRACK'=>'1', 'ASC_BYPASS_KEYCHAIN'=>'1', 'ASC_CONFIG_PATH'=>File.join(isolated_home, 'unused-config.json'), 'ASC_DEFAULT_OUTPUT'=>'json', 'ASC_KEY_TYPE'=>'team'}
      SECRET_KEYS.each { |key| environment[key] = ENV.fetch(key) }
      output, _, status = Open3.capture3(environment, config.fetch(:binary), '--version', unsetenv_others: true, chdir: isolated_home)
      return status.exitstatus || 1 unless status.success?
      version_pattern = /\A#{Regexp.escape(config.fetch(:pin).fetch('version'))} \(commit: [^\r\n]+, date: [^\r\n]+\)\n?\z/
      refuse('binary reported version differs from pin') unless output.match?(version_pattern)
      binary_bytes(config)
      output, error, status = Open3.capture3(environment, config.fetch(:binary), *forwarded, unsetenv_others: true, chdir: isolated_home)
      STDOUT.write(redact.call(output))
      STDERR.write(redact.call(error))
      status.exitstatus || 128 + status.termsig
    end
  end

  def main(args)
    action = args.shift
    config = configuration
    case action
    when 'install'
      refuse('usage: install-asc-cli.sh') unless args.length == 1
      install(config, args.fetch(0))
      0
    when 'run' then run(config, args)
    when 'exec-child' then exec_child(config, args)
    else refuse('unknown asc adapter action')
    end
  rescue Refused => error
    warn "asc adapter refused: #{error.message}"
    1
  rescue JSON::ParserError, KeyError, ArgumentError, SystemCallError, IOError, Fiddle::DLError
    # Exceptions can contain file names and credential-bearing paths.
    warn 'asc adapter refused: invalid or unavailable input'
    1
  end
end

exit AscCLI.main(ARGV) if $PROGRAM_NAME == __FILE__
