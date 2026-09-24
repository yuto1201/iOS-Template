# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'
require 'tmpdir'
require 'tempfile'
require 'open3'
require 'fiddle'

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
  OPERATIONS = {
    'appstore.inspect_app' => {
      %w[apps list] => {'--bundle-id'=>:identifier, '--name'=>:text, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[apps info view] => {'--app'=>:id, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[versions list] => {'--app'=>:id, '--version'=>:version, '--platform'=>:platform, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[bundle-ids list] => {'--identifier'=>:identifier, '--limit'=>:limit, '--paginate'=>:boolean}
    }.freeze,
    'appstore.update_metadata' => {
      %w[apps list] => {'--bundle-id'=>:identifier, '--name'=>:text, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[apps info view] => {'--app'=>:id, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[versions list] => {'--app'=>:id, '--version'=>:version, '--platform'=>:platform, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[bundle-ids list] => {'--identifier'=>:identifier, '--limit'=>:limit, '--paginate'=>:boolean},
      %w[localizations list] => {'--version'=>:resource_id, '--app'=>:id, '--type'=>:localization_type, '--locale'=>:locale, '--paginate'=>:boolean},
      %w[localizations update] => {'--version'=>:resource_id, '--app'=>:id, '--type'=>:localization_type, '--locale'=>:locale,
                                    '--name'=>:localization_name, '--subtitle'=>:localization_subtitle,
                                    '--description'=>:localization_description, '--keywords'=>:localization_keywords,
                                    '--promotional-text'=>:localization_promotional, '--whats-new'=>:localization_whats_new}
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
    '--promotional-text'=>:localization_promotional, '--whats-new'=>:localization_whats_new
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

  def command_arguments(args)
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
      if localization_text
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
        refuse('flag value is invalid') unless value && !value.empty? && value.bytesize <= 256 && !value.start_with?('-') && !value.match?(/[\x00-\x1f\x7f]/) && !value.include?('$') && !value.include?('`')
        valid = case type
              when :id then value.match?(/\A[1-9][0-9]*\z/)
              when :resource_id then value.match?(/\A[A-Za-z0-9_-]{1,128}\z/)
              when :localization_type then %w[version app-info].include?(value)
              when :locale then %w[en-US ja].include?(value)
              when :identifier then value.match?(/\A[A-Za-z0-9][A-Za-z0-9.-]*\z/)
              when :limit then value.match?(/\A[1-9][0-9]*\z/) && value.to_i <= 200
              when :version then value.match?(/\A[0-9]+(?:\.[0-9]+){0,2}\z/)
              when :platform then %w[IOS MAC_OS TV_OS VISION_OS].include?(value)
              when :output then value == 'json'
              when :text then true
              end
      end
      refuse('flag value is invalid') unless valid
      forwarded.concat(localization_text ? ["#{flag}=#{value}"] : [flag, value]) unless type == :output
    end
    refuse('explicit app is required') if [%w[apps info view], %w[versions list]].include?(command) && !seen.include?('--app')
    if metadata_command
      kind = tail.each_cons(2).find { |pair| pair.first == '--type' }&.last
      refuse('localization type and locale are required') unless %w[version app-info].include?(kind) && seen.include?('--locale')
      selector = kind == 'version' ? '--version' : '--app'
      other = kind == 'version' ? '--app' : '--version'
      refuse('localization parent is invalid') unless seen.include?(selector) && !seen.include?(other)
      if command == %w[localizations update]
        allowed = kind == 'version' ? %w[--description --keywords --promotional-text --whats-new] : %w[--name --subtitle]
        supplied = seen & LOCALIZATION_FIELD_FLAGS.keys
        refuse('localization update fields are invalid') if supplied.empty? || !(supplied - allowed).empty?
      end
    end
    forwarded + ['--output', 'json']
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
