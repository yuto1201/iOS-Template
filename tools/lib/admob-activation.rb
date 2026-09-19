#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "tempfile"
require "tmpdir"
require "time"

module IOSTemplate
  module AdMobActivation
    class Error < StandardError; end

    SCHEMA_VERSION = 1
    RECORD_PATH = "Config/admob-activation.json"
    PACKAGE_URL = "https://github.com/googleads/swift-package-manager-google-mobile-ads.git"
    PACKAGE_VERSION = "13.10.0"
    PACKAGE_REVISION = "12b7af0f844723a86fd3c0089b02f64b1e495605"
    PACKAGE_RELEASE_URL = "https://github.com/googleads/swift-package-manager-google-mobile-ads/releases/tag/13.10.0"
    UMP_PACKAGE_URL = "https://github.com/googleads/swift-package-manager-google-user-messaging-platform.git"
    UMP_VERSION = "3.1.0"
    UMP_REVISION = "13b248eaa73b7826f0efb1bcf455e251d65ecb1b"
    UMP_RELEASE_URL = "https://github.com/googleads/swift-package-manager-google-user-messaging-platform/releases/tag/3.1.0"
    DEBUG_APP_ID = "ca-app-pub-3940256099942544~1458002511"
    DEBUG_BANNER_ID = "ca-app-pub-3940256099942544/2435281174"
    REQUIRED_GOOGLE_GUIDES = %w[
      https://developers.google.com/admob/ios/banner
      https://developers.google.com/admob/ios/privacy
      https://developers.google.com/admob/ios/privacy/strategies
      https://developers.google.com/admob/ios/quick-start
      https://developers.google.com/admob/ios/targeting
      https://developers.google.com/admob/ios/test-ads
    ].freeze
    REQUIRED_APPLE_GUIDES = %w[
      https://developer.apple.com/app-store/user-privacy-and-data-use/
    ].freeze
    INPUT_KEYS = %w[
      adFreeEntitlement adopted appIdentity audience deploymentTarget identifiers
      officialSources placement privacyDeclaration schemaVersion skAdNetworkIdentifiers tracking ump
    ].sort.freeze

    module_function

    def canonical_json(value)
      case value
      when Hash
        "{" + value.keys.sort.map { |key| "#{JSON.generate(key)}:#{canonical_json(value.fetch(key))}" }.join(",") + "}"
      when Array
        "[" + value.map { |entry| canonical_json(entry) }.join(",") + "]"
      else
        JSON.generate(value)
      end
    end

    def digest(bytes)
      Digest::SHA256.hexdigest(bytes)
    end

    def fail!(message)
      raise Error, message
    end

    def exact_keys!(value, keys, label)
      fail!("#{label} must be an object") unless value.is_a?(Hash)
      actual = value.keys.sort
      expected = keys.sort
      fail!("#{label} keys must be exactly #{expected.join(', ')}") unless actual == expected
    end

    def nonempty_string!(value, label, pattern: nil)
      fail!("#{label} must be a non-empty string") unless value.is_a?(String) && !value.empty? && value == value.strip
      fail!("#{label} is invalid") if pattern && !value.match?(pattern)
      value
    end

    def boolean!(value, label)
      fail!("#{label} must be true or false") unless value == true || value == false
      value
    end

    def sorted_unique_strings!(value, label, pattern: nil, allow_empty: false)
      fail!("#{label} must be an array") unless value.is_a?(Array)
      fail!("#{label} must not be empty") if value.empty? && !allow_empty
      value.each_with_index { |entry, index| nonempty_string!(entry, "#{label}[#{index}]", pattern: pattern) }
      fail!("#{label} must be sorted and unique") unless value == value.sort.uniq
      value
    end

    def version_parts(value, label)
      nonempty_string!(value, label, pattern: /\A\d+(?:\.\d+){1,2}\z/)
      value.split(".").map(&:to_i)
    end

    def compare_versions(left, right)
      length = [left.length, right.length].max
      left.fill(0, left.length...length)
      right.fill(0, right.length...length)
      left <=> right
    end

    def checked_timestamp!(value, label, require_fresh:)
      checked_at = Time.iso8601(nonempty_string!(value, label))
      now = Time.now.utc
      fail!("#{label} must not be in the future") if checked_at > now + 300
      if require_fresh && checked_at < now - (30 * 86_400)
        fail!("#{label} is older than 30 days; recheck the source before activation")
      end
      checked_at
    rescue ArgumentError
      fail!("#{label} must be an ISO-8601 timestamp")
    end

    def repository_relative_file!(root, relative, label)
      nonempty_string!(relative, label)
      path = Pathname.new(relative)
      fail!("#{label} must be a normalized repository-relative path") if path.absolute? || path.cleanpath.to_s != relative || path.each_filename.any? { |part| part == ".." }
      absolute = File.join(root, relative)
      root_real = File.realpath(root)
      current = root_real
      path.each_filename do |part|
        current = File.join(current, part)
        stat = File.lstat(current)
        fail!("#{label} must not traverse a symlink") if stat.symlink?
      rescue Errno::ENOENT
        fail!("#{label} must identify an existing regular file")
      end
      fail!("#{label} must identify an existing regular file") unless File.file?(absolute)
      fail!("#{label} escapes the repository") unless File.realpath(absolute).start_with?(root_real + File::SEPARATOR)
      absolute
    end

    def load_json(path, label)
      fail!("#{label} must be a readable regular file") unless File.file?(path) && !File.symlink?(path) && File.readable?(path)
      JSON.parse(File.binread(path))
    rescue JSON::ParserError => error
      fail!("#{label} is not valid JSON: #{error.message}")
    end

    def resolve_root(path)
      expanded = File.expand_path(path)
      fail!("root must be an existing directory") unless File.directory?(expanded) && !File.symlink?(expanded)
      root = capture!("git", "-C", expanded, "rev-parse", "--show-toplevel").strip
      fail!("--root must identify the Git repository root") unless File.realpath(expanded) == File.realpath(root)
      expanded
    end

    def capture!(*command, stdin_data: nil)
      output, error, status = Open3.capture3(*command, stdin_data: stdin_data)
      return output if status.success?

      detail = error.strip.empty? ? output.strip : error.strip
      fail!("command failed (#{command.first}): #{detail.empty? ? status.exitstatus : detail}")
    end

    def capture_bounded!(timeout_seconds, *command)
      stdin = stdout = stderr = wait_thread = nil
      output_thread = error_thread = nil
      stdin, stdout, stderr, wait_thread = Open3.popen3(*command, pgroup: true)
      stdin.close
      output_thread = Thread.new { stdout.read }
      error_thread = Thread.new { stderr.read }
      unless wait_thread.join(timeout_seconds)
        begin
          Process.kill("TERM", -wait_thread.pid)
        rescue Errno::ESRCH
          nil
        end
        unless wait_thread.join(2)
          begin
            Process.kill("KILL", -wait_thread.pid)
          rescue Errno::ESRCH
            nil
          end
          wait_thread.join
        end
        fail!("command timed out (#{command.first})")
      end
      output = output_thread.value
      error = error_thread.value
      return output if wait_thread.value.success?

      detail = error.strip.empty? ? output.strip : error.strip
      fail!("command failed (#{command.first}): #{detail.empty? ? wait_thread.value.exitstatus : detail}")
    ensure
      [stdin, stdout, stderr].compact.each { |stream| stream.close unless stream.closed? }
      [output_thread, error_thread].compact.each { |thread| thread.join(1) }
    end

    def validate_active_xcode!(minimum)
      output = capture_bounded!(15, "/usr/bin/xcodebuild", "-version")
      active = output[/\AXcode (\d+(?:\.\d+){1,2})\b/, 1]
      fail!("active Xcode version could not be determined") unless active
      if compare_versions(version_parts(active, "active Xcode version"), version_parts(minimum, "minimumXcode")) == -1
        fail!("active Xcode #{active} is below required #{minimum}")
      end
    end

    def identity_at(root)
      path = repository_relative_file!(root, "Config/app-identity.json", "Config/app-identity.json")
      value = load_json(path, "Config/app-identity.json")
      exact_keys!(value, %w[appSlug bundleId displayName moduleName schemaVersion sourceIdentityVersion], "app identity")
      fail!("app identity schema is unsupported") unless value["schemaVersion"] == 1 && value["sourceIdentityVersion"] == 1
      nonempty_string!(value["displayName"], "app identity displayName")
      nonempty_string!(value["moduleName"], "app identity moduleName", pattern: /\A[A-Z][A-Za-z0-9_]{0,63}\z/)
      nonempty_string!(value["appSlug"], "app identity appSlug", pattern: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      nonempty_string!(value["bundleId"], "app identity bundleId", pattern: /\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/)
      value
    end

    def validate_input(value, identity, project_bytes, root:, require_fresh: true)
      exact_keys!(value, INPUT_KEYS, "activation input")
      fail!("schemaVersion must be #{SCHEMA_VERSION}") unless value["schemaVersion"] == SCHEMA_VERSION
      fail!("adopted must be true") unless value["adopted"] == true

      app_identity = value["appIdentity"]
      exact_keys!(app_identity, %w[appSlug bundleId displayName moduleName], "appIdentity")
      %w[appSlug bundleId displayName moduleName].each do |key|
        fail!("appIdentity.#{key} does not match Config/app-identity.json") unless app_identity[key] == identity[key]
      end

      deployment = version_parts(value["deploymentTarget"], "deploymentTarget")
      project_targets = project_bytes.scan(/IPHONEOS_DEPLOYMENT_TARGET = (\d+(?:\.\d+){1,2});/).flatten.uniq
      fail!("project must declare one deployment target") unless project_targets.length == 1
      fail!("deploymentTarget does not match the project") unless project_targets.first == value["deploymentTarget"]

      placement = value["placement"]
      exact_keys!(placement, %w[container excludedScreens includedScreens privacyOptionsEntry], "placement")
      screen_pattern = /\A[a-z0-9][a-z0-9._-]{0,79}\z/
      included = sorted_unique_strings!(placement["includedScreens"], "placement.includedScreens", pattern: screen_pattern)
      excluded = sorted_unique_strings!(
        placement["excludedScreens"],
        "placement.excludedScreens",
        pattern: screen_pattern,
        allow_empty: true
      )
      fail!("included and excluded screens must not overlap") unless (included & excluded).empty?
      fail!("placement.container must be safe-area-bottom") unless placement["container"] == "safe-area-bottom"
      nonempty_string!(placement["privacyOptionsEntry"], "placement.privacyOptionsEntry", pattern: screen_pattern)

      audience = value["audience"]
      exact_keys!(audience, %w[childDirected minimumAge regions underAgeOfConsent], "audience")
      fail!("audience.minimumAge must be an integer of at least 18 for the default non-tracking route") unless audience["minimumAge"].is_a?(Integer) && audience["minimumAge"] >= 18
      sorted_unique_strings!(audience["regions"], "audience.regions", pattern: /\A[a-z0-9][a-z0-9-]{0,31}\z/)
      fail!("child-directed or under-age treatment requires a separate decision") unless audience["childDirected"] == false && audience["underAgeOfConsent"] == false

      tracking = value["tracking"]
      exact_keys!(tracking, %w[attPrompt mode personalizedAds publisherFirstPartyIDEnabled], "tracking")
      fail!("tracking.mode must be non-tracking") unless tracking["mode"] == "non-tracking"
      fail!("the default route must not request ATT, personalization, or publisher first-party ID") unless tracking["attPrompt"] == false && tracking["personalizedAds"] == false && tracking["publisherFirstPartyIDEnabled"] == false

      ump = value["ump"]
      exact_keys!(ump, %w[enabled privacyOptionsEnabled], "ump")
      fail!("UMP and privacy options must be enabled") unless ump["enabled"] == true && ump["privacyOptionsEnabled"] == true

      entitlement = value["adFreeEntitlement"]
      exact_keys!(entitlement, %w[enabled source], "adFreeEntitlement")
      boolean!(entitlement["enabled"], "adFreeEntitlement.enabled")
      nonempty_string!(entitlement["source"], "adFreeEntitlement.source", pattern: /\A[a-zA-Z][a-zA-Z0-9._-]{0,127}\z/)

      identifiers = value["identifiers"]
      exact_keys!(identifiers, %w[debug release], "identifiers")
      exact_keys!(identifiers["debug"], %w[appId bannerUnitId], "identifiers.debug")
      exact_keys!(identifiers["release"], %w[appId bannerUnitId binding], "identifiers.release")
      fail!("Debug must use Google's official demo App ID and banner unit ID") unless identifiers["debug"] == {"appId" => DEBUG_APP_ID, "bannerUnitId" => DEBUG_BANNER_ID}
      app_match = nonempty_string!(identifiers.dig("release", "appId"), "identifiers.release.appId", pattern: /\Aca-app-pub-(\d{16})~\d{10}\z/).match(/\Aca-app-pub-(\d{16})~/)
      banner_match = nonempty_string!(identifiers.dig("release", "bannerUnitId"), "identifiers.release.bannerUnitId", pattern: /\Aca-app-pub-(\d{16})\/\d{10}\z/).match(/\Aca-app-pub-(\d{16})\//)
      fail!("Release identifiers must belong to the same publisher") unless app_match[1] == banner_match[1]
      fail!("Release identifiers must not use Google's demo publisher") if app_match[1] == "3940256099942544"
      binding = identifiers.dig("release", "binding")
      exact_keys!(binding, %w[bundleId configuration readbackSource verifiedAt], "identifiers.release.binding")
      fail!("Release identifier binding must match the target Bundle ID") unless binding["bundleId"] == identity["bundleId"]
      fail!("Release identifier binding must target Release") unless binding["configuration"] == "Release"
      fail!("Release identifiers require a confirmed AdMob Console readback") unless binding["readbackSource"] == "admob-console-readback"
      checked_timestamp!(binding["verifiedAt"], "identifiers.release.binding.verifiedAt", require_fresh: require_fresh)

      privacy = value["privacyDeclaration"]
      exact_keys!(privacy, %w[appStoreTracking dataUseCategories reviewedAt sourceDigest sourcePath], "privacyDeclaration")
      fail!("privacyDeclaration.appStoreTracking must remain false for the non-tracking route") unless privacy["appStoreTracking"] == false
      sorted_unique_strings!(privacy["dataUseCategories"], "privacyDeclaration.dataUseCategories", pattern: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      checked_timestamp!(privacy["reviewedAt"], "privacyDeclaration.reviewedAt", require_fresh: require_fresh)
      privacy_source = repository_relative_file!(root, privacy["sourcePath"], "privacyDeclaration.sourcePath")
      nonempty_string!(privacy["sourceDigest"], "privacyDeclaration.sourceDigest", pattern: /\Asha256:[a-f0-9]{64}\z/)
      fail!("privacy declaration source digest does not match") unless privacy["sourceDigest"] == "sha256:#{digest(File.binread(privacy_source))}"

      sources = value["officialSources"]
      exact_keys!(sources, %w[appleGuides checkedAt googleGuides googleMobileAds ump], "officialSources")
      checked_timestamp!(sources["checkedAt"], "officialSources.checkedAt", require_fresh: require_fresh)

      gma = sources["googleMobileAds"]
      exact_keys!(gma, %w[minimumIOS minimumXcode packageURL releaseURL revision version], "officialSources.googleMobileAds")
      expected_gma = {
        "packageURL" => PACKAGE_URL,
        "version" => PACKAGE_VERSION,
        "revision" => PACKAGE_REVISION,
        "minimumIOS" => "13.0",
        "minimumXcode" => "16.0",
        "releaseURL" => PACKAGE_RELEASE_URL,
      }
      fail!("Google Mobile Ads source facts do not match the reviewed integration") unless gma == expected_gma
      fail!("deployment target is below the SDK minimum") if compare_versions(deployment, version_parts(gma["minimumIOS"], "minimumIOS")) == -1
      validate_active_xcode!(gma["minimumXcode"]) if require_fresh

      ump_source = sources["ump"]
      exact_keys!(ump_source, %w[packageURL releaseURL revision version], "officialSources.ump")
      expected_ump = {"packageURL" => UMP_PACKAGE_URL, "version" => UMP_VERSION, "revision" => UMP_REVISION, "releaseURL" => UMP_RELEASE_URL}
      fail!("UMP source facts do not match the reviewed integration") unless ump_source == expected_ump
      google_guides = sorted_unique_strings!(sources["googleGuides"], "officialSources.googleGuides", pattern: %r{\Ahttps://developers\.google\.com/})
      apple_guides = sorted_unique_strings!(sources["appleGuides"], "officialSources.appleGuides", pattern: %r{\Ahttps://developer\.apple\.com/})
      fail!("required Google guides are missing") unless (REQUIRED_GOOGLE_GUIDES - google_guides).empty?
      fail!("required Apple privacy guide is missing") unless (REQUIRED_APPLE_GUIDES - apple_guides).empty?

      networks = sorted_unique_strings!(value["skAdNetworkIdentifiers"], "skAdNetworkIdentifiers", pattern: /\A[a-z0-9]{10}\.skadnetwork\z/)
      fail!("Google SKAdNetwork identifier is required") unless networks.include?("cstr6suwn9.skadnetwork")
      value
    end

    def project_path(root, identity)
      relative = "#{identity.fetch('moduleName')}.xcodeproj/project.pbxproj"
      absolute = repository_relative_file!(root, relative, "generated app project")
      [relative, absolute]
    end

    def deterministic_id(identity, purpose, existing)
      candidate = Digest::SHA256.hexdigest("#{identity.fetch('bundleId')}\0admob\0#{purpose}")[0, 24].upcase
      fail!("deterministic PBX identifier collision for #{purpose}") if existing.include?(candidate)
      candidate
    end

    def replace_once(bytes, pattern, replacement, label)
      matches = bytes.scan(pattern).length
      fail!("#{label} anchor must occur exactly once (found #{matches})") unless matches == 1
      bytes.sub(pattern, replacement)
    end

    def mutate_project(bytes, identity)
      module_name = identity.fetch("moduleName")
      existing_ids = bytes.scan(/\b[A-F0-9]{24}\b/).uniq
      build_file_id = deterministic_id(identity, "package-build-file", existing_ids)
      package_id = deterministic_id(identity, "package-reference", existing_ids + [build_file_id])
      product_id = deterministic_id(identity, "package-product", existing_ids + [build_file_id, package_id])

      target_pattern = /(\t\t([A-F0-9]{24}) \/\* #{Regexp.escape(module_name)} \*\/ = \{\n\t\t\tisa = PBXNativeTarget;.*?\n\t\t\};)/m
      target_match = bytes.match(target_pattern)
      fail!("application target #{module_name} must occur exactly once") unless target_match && bytes.scan(target_pattern).length == 1
      target_block = target_match[1]
      frameworks_id = target_block[/\n\t\t\t\t([A-F0-9]{24}) \/\* Frameworks \*\/,/, 1]
      config_list_id = target_block[/buildConfigurationList = ([A-F0-9]{24}) /, 1]
      fail!("application target framework/configuration anchors are missing") unless frameworks_id && config_list_id
      new_target = replace_once(
        target_block,
        /(packageProductDependencies = \(\n)(.*?)(\t\t\t\);)/m,
        "\\1\\2\t\t\t\t#{product_id} /* GoogleMobileAds */,\n\\3",
        "application package dependencies"
      )
      bytes = bytes.sub(target_block, new_target)

      framework_pattern = /(\t\t#{frameworks_id} \/\* Frameworks \*\/ = \{.*?\n\t\t\};)/m
      framework_block = bytes.match(framework_pattern)&.[](1)
      fail!("application Frameworks build phase is missing") unless framework_block
      new_framework = replace_once(
        framework_block,
        /(files = \(\n)(.*?)(\t\t\t\);)/m,
        "\\1\\2\t\t\t\t#{build_file_id} /* GoogleMobileAds in Frameworks */,\n\\3",
        "application Frameworks files"
      )
      bytes = bytes.sub(framework_block, new_framework)

      build_file_entry = "\t\t#{build_file_id} /* GoogleMobileAds in Frameworks */ = {isa = PBXBuildFile; productRef = #{product_id} /* GoogleMobileAds */; };\n"
      if bytes.include?("/* Begin PBXBuildFile section */")
        bytes = replace_once(bytes, %r{/\* Begin PBXBuildFile section \*/\n}, "/* Begin PBXBuildFile section */\n#{build_file_entry}", "PBXBuildFile section")
      else
        section = "/* Begin PBXBuildFile section */\n#{build_file_entry}/* End PBXBuildFile section */\n\n"
        bytes = replace_once(bytes, %r{/\* Begin PBXContainerItemProxy section \*/}, "#{section}/* Begin PBXContainerItemProxy section */", "PBXContainerItemProxy section")
      end

      project_pattern = /(\t\t[A-F0-9]{24} \/\* Project object \*\/ = \{\n\t\t\tisa = PBXProject;.*?\n\t\t\};)/m
      project_block = bytes.match(project_pattern)&.[](1)
      fail!("PBXProject object is missing") unless project_block && bytes.scan(project_pattern).length == 1
      new_project = if project_block.include?("packageReferences =")
        replace_once(
          project_block,
          /(packageReferences = \(\n)(.*?)(\t\t\t\);)/m,
          "\\1\\2\t\t\t\t#{package_id} /* XCRemoteSwiftPackageReference \"GoogleMobileAds\" */,\n\\3",
          "PBXProject package insertion"
        )
      else
        replace_once(
          project_block,
          /\n\t\t\tpreferredProjectObjectVersion =/,
          "\n\t\t\tpackageReferences = (\n\t\t\t\t#{package_id} /* XCRemoteSwiftPackageReference \"GoogleMobileAds\" */,\n\t\t\t);\n\t\t\tpreferredProjectObjectVersion =",
          "PBXProject package insertion"
        )
      end
      bytes = bytes.sub(project_block, new_project)

      config_list_pattern = /(\t\t#{config_list_id} \/\* Build configuration list for PBXNativeTarget "#{Regexp.escape(module_name)}" \*\/ = \{.*?\n\t\t\};)/m
      config_list = bytes.match(config_list_pattern)&.[](1)
      fail!("application configuration list is missing") unless config_list
      debug_id = config_list[/\n\t\t\t\t([A-F0-9]{24}) \/\* Debug \*\/,/, 1]
      release_id = config_list[/\n\t\t\t\t([A-F0-9]{24}) \/\* Release \*\/,/, 1]
      fail!("application Debug/Release configuration identifiers are missing") unless debug_id && release_id

      {debug_id => "Info-Debug.plist", release_id => "Info-Release.plist"}.each do |identifier, plist|
        config_pattern = /(\t\t#{identifier} \/\* (?:Debug|Release) \*\/ = \{.*?\n\t\t\};)/m
        config_block = bytes.match(config_pattern)&.[](1)
        fail!("application build configuration #{identifier} is missing") unless config_block
        changed = replace_once(config_block, /GENERATE_INFOPLIST_FILE = YES;/, "GENERATE_INFOPLIST_FILE = NO;", "generated Info.plist setting")
        changed = replace_once(
          changed,
          /\n\t\t\t\tLD_RUNPATH_SEARCH_PATHS =/,
          "\n\t\t\t\tINFOPLIST_FILE = #{module_name}/AdMob/#{plist};\n\t\t\t\tLD_RUNPATH_SEARCH_PATHS =",
          "Info.plist path insertion"
        )
        bytes = bytes.sub(config_block, changed)
      end

      package_reference_entry = <<~PBX
        \t\t#{package_id} /* XCRemoteSwiftPackageReference "GoogleMobileAds" */ = {
        \t\t\tisa = XCRemoteSwiftPackageReference;
        \t\t\trepositoryURL = "#{PACKAGE_URL}";
        \t\t\trequirement = {
        \t\t\t\tkind = exactVersion;
        \t\t\t\tversion = #{PACKAGE_VERSION};
        \t\t\t};
        \t\t};
      PBX
      if bytes.include?("/* Begin XCRemoteSwiftPackageReference section */")
        bytes = replace_once(
          bytes,
          %r{/\* End XCRemoteSwiftPackageReference section \*/},
          "#{package_reference_entry}/* End XCRemoteSwiftPackageReference section */",
          "XCRemoteSwiftPackageReference section"
        )
      else
        section = "/* Begin XCRemoteSwiftPackageReference section */\n#{package_reference_entry}/* End XCRemoteSwiftPackageReference section */\n\n"
        bytes = replace_once(bytes, %r{/\* Begin XCBuildConfiguration section \*/}, "#{section}/* Begin XCBuildConfiguration section */", "XCBuildConfiguration section")
      end

      product_entry = <<~PBX
        \t\t#{product_id} /* GoogleMobileAds */ = {
        \t\t\tisa = XCSwiftPackageProductDependency;
        \t\t\tpackage = #{package_id} /* XCRemoteSwiftPackageReference "GoogleMobileAds" */;
        \t\t\tproductName = GoogleMobileAds;
        \t\t};
      PBX
      if bytes.include?("/* Begin XCSwiftPackageProductDependency section */")
        bytes = replace_once(
          bytes,
          %r{/\* End XCSwiftPackageProductDependency section \*/},
          "#{product_entry}/* End XCSwiftPackageProductDependency section */",
          "XCSwiftPackageProductDependency section"
        )
      else
        section = "/* Begin XCSwiftPackageProductDependency section */\n#{product_entry}/* End XCSwiftPackageProductDependency section */\n\n"
        bytes = replace_once(bytes, %r{/\* Begin XCBuildConfiguration section \*/}, "#{section}/* Begin XCBuildConfiguration section */", "XCBuildConfiguration section")
      end
      bytes
    end

    def swift_string(value)
      JSON.generate(value).gsub("\\/", "/")
    end

    def swift_array(values)
      "[#{values.map { |value| swift_string(value) }.join(', ')}]"
    end

    def plist_network_items(values)
      values.map do |value|
        "\t\t<dict>\n\t\t\t<key>SKAdNetworkIdentifier</key>\n\t\t\t<string>#{value}</string>\n\t\t</dict>"
      end.join("\n")
    end

    def render_template(path, replacements)
      bytes = File.binread(path)
      replacements.each do |placeholder, replacement|
        fail!("template #{File.basename(path)} is missing #{placeholder}") unless bytes.include?(placeholder)
        bytes = bytes.gsub(placeholder, replacement)
      end
      unresolved = bytes.scan(/__[A-Z0-9_]+__/).uniq
      fail!("template #{File.basename(path)} has unresolved placeholders: #{unresolved.join(', ')}") unless unresolved.empty?
      bytes
    end

    def template_root(root)
      File.join(root, ".agents/skills/admob-monetization/templates")
    end

    def generated_paths(identity)
      module_name = identity.fetch("moduleName")
      project = "#{module_name}.xcodeproj"
      [
        RECORD_PATH,
        "#{module_name}/AdMob/AdMobConfiguration.swift",
        "#{module_name}/AdMob/AdMobCore.swift",
        "#{module_name}/AdMob/AdaptiveBannerHost.swift",
        "#{module_name}/AdMob/GoogleMobileAdsProvider.swift",
        "#{module_name}/AdMob/Info-Debug.plist",
        "#{module_name}/AdMob/Info-Release.plist",
        "#{project}/project.pbxproj",
      ]
    end

    def ensure_parent_and_write(root, relative, bytes)
      relative_path = Pathname.new(relative)
      fail!("unsafe activation output path: #{relative}") if relative_path.absolute? || relative_path.cleanpath.to_s != relative || relative_path.each_filename.any? { |part| part == ".." }
      root_real = File.realpath(root)
      current = root_real
      relative_path.dirname.each_filename do |part|
        current = File.join(current, part)
        begin
          stat = File.lstat(current)
          fail!("activation output ancestor is a symlink: #{relative}") if stat.symlink?
          fail!("activation output ancestor is not a directory: #{relative}") unless stat.directory?
        rescue Errno::ENOENT
          Dir.mkdir(current, 0o755)
        end
        fail!("activation output escapes the repository: #{relative}") unless File.realpath(current).start_with?(root_real + File::SEPARATOR)
      end
      path = File.join(root_real, relative)
      if File.exist?(path) || File.symlink?(path)
        stat = File.lstat(path)
        fail!("refusing to replace a symlink: #{relative}") if stat.symlink?
        fail!("refusing to replace a non-file: #{relative}") unless stat.file?
      end
      File.binwrite(path, bytes)
      File.chmod(0o644, path)
    end

    def build_outputs(stage_root, input, identity, project_relative, original_project, source_head_sha)
      templates = template_root(stage_root)
      required_templates = %w[
        AdMobConfiguration.swift.template AdMobCore.swift AdaptiveBannerHost.swift
        GoogleMobileAdsProvider.swift Info-Debug.plist.template Info-Release.plist.template
      ]
      required_templates.each do |name|
        relative = ".agents/skills/admob-monetization/templates/#{name}"
        repository_relative_file!(stage_root, relative, "activation template #{name}")
      end

      module_name = identity.fetch("moduleName")
      release = input.dig("identifiers", "release")
      debug = input.dig("identifiers", "debug")
      common = {
        "__ACTIVATION_INPUT_DIGEST__" => digest(canonical_json(input)),
        "__DEBUG_APP_ID__" => debug.fetch("appId"),
        "__DEBUG_BANNER_ID__" => debug.fetch("bannerUnitId"),
        "__RELEASE_APP_ID__" => release.fetch("appId"),
        "__RELEASE_BANNER_ID__" => release.fetch("bannerUnitId"),
        "__INCLUDED_SCREENS__" => swift_array(input.dig("placement", "includedScreens")),
        "__EXCLUDED_SCREENS__" => swift_array(input.dig("placement", "excludedScreens")),
        "__ENTITLEMENT_SOURCE__" => swift_string(input.dig("adFreeEntitlement", "source")),
        "__MINIMUM_AGE__" => input.dig("audience", "minimumAge").to_s,
        "__PRIVACY_OPTIONS_ENTRY__" => input.dig("placement", "privacyOptionsEntry"),
        "__SKADNETWORK_ITEMS__" => plist_network_items(input.fetch("skAdNetworkIdentifiers")),
      }

      outputs = {}
      outputs["#{module_name}/AdMob/AdMobCore.swift"] = File.binread(File.join(templates, "AdMobCore.swift"))
      outputs["#{module_name}/AdMob/AdaptiveBannerHost.swift"] = File.binread(File.join(templates, "AdaptiveBannerHost.swift"))
      outputs["#{module_name}/AdMob/GoogleMobileAdsProvider.swift"] = File.binread(File.join(templates, "GoogleMobileAdsProvider.swift"))
      outputs["#{module_name}/AdMob/AdMobConfiguration.swift"] = render_template(
        File.join(templates, "AdMobConfiguration.swift.template"),
        common.slice(
          "__ACTIVATION_INPUT_DIGEST__",
          "__DEBUG_APP_ID__",
          "__DEBUG_BANNER_ID__",
          "__RELEASE_APP_ID__",
          "__RELEASE_BANNER_ID__",
          "__INCLUDED_SCREENS__",
          "__EXCLUDED_SCREENS__",
          "__ENTITLEMENT_SOURCE__",
          "__MINIMUM_AGE__",
          "__PRIVACY_OPTIONS_ENTRY__"
        )
      )
      outputs["#{module_name}/AdMob/Info-Debug.plist"] = render_template(
        File.join(templates, "Info-Debug.plist.template"),
        common.slice("__DEBUG_APP_ID__", "__SKADNETWORK_ITEMS__")
      )
      outputs["#{module_name}/AdMob/Info-Release.plist"] = render_template(
        File.join(templates, "Info-Release.plist.template"),
        common.slice("__RELEASE_APP_ID__", "__SKADNETWORK_ITEMS__")
      )
      outputs[project_relative] = mutate_project(original_project, identity)

      file_digests = outputs.transform_values { |bytes| digest(bytes) }
      record = {
        "schemaVersion" => SCHEMA_VERSION,
        "status" => "activated",
        "activationInput" => input,
        "inputDigest" => digest(canonical_json(input)),
        "identity" => input.fetch("appIdentity"),
        "deploymentTarget" => input.fetch("deploymentTarget"),
        "package" => {
          "url" => PACKAGE_URL,
          "version" => PACKAGE_VERSION,
          "revision" => PACKAGE_REVISION,
          "umpVersion" => UMP_VERSION,
          "umpRevision" => UMP_REVISION,
        },
        "officialSources" => input.fetch("officialSources"),
        "policy" => {
          "configurationSeparation" => ["debug-demo", "ui-test-offline", "release-app-specific"],
          "tracking" => "non-tracking",
          "attPrompt" => false,
          "publisherFirstPartyIDEnabled" => false,
          "personalizedAds" => false,
          "releaseReadiness" => "deferred",
        },
        "sourceHeadSha" => source_head_sha,
        "sourceProjectDigest" => digest(original_project),
        "fileDigests" => file_digests,
      }
      outputs[RECORD_PATH] = canonical_json(record) + "\n"
      outputs
    end

    def validate_plist!(path, expected_app_id)
      bytes = capture!("/usr/bin/plutil", "-convert", "json", "-o", "-", path)
      value = JSON.parse(bytes)
      fail!("#{File.basename(path)} has the wrong GADApplicationIdentifier") unless value["GADApplicationIdentifier"] == expected_app_id
      fail!("#{File.basename(path)} must not declare ATT usage") if value.key?("NSUserTrackingUsageDescription")
      networks = Array(value["SKAdNetworkItems"]).map { |entry| entry["SKAdNetworkIdentifier"] }
      fail!("#{File.basename(path)} is missing Google's SKAdNetwork identifier") unless networks.include?("cstr6suwn9.skadnetwork")
    rescue JSON::ParserError
      fail!("#{File.basename(path)} could not be parsed")
    end

    def validate_activated(root)
      identity = identity_at(root)
      record = load_json(File.join(root, RECORD_PATH), RECORD_PATH)
      exact_keys!(record, %w[activationInput deploymentTarget fileDigests identity inputDigest officialSources package policy schemaVersion sourceHeadSha sourceProjectDigest status], "activation record")
      fail!("activation record schema/status is invalid") unless record["schemaVersion"] == SCHEMA_VERSION && record["status"] == "activated"
      fail!("activation identity does not match the app") unless record["identity"] == identity.slice("displayName", "moduleName", "appSlug", "bundleId")

      source_head = nonempty_string!(record["sourceHeadSha"], "activation sourceHeadSha", pattern: /\A[a-f0-9]{40}\z/)
      capture!("git", "-C", root, "cat-file", "-e", "#{source_head}^{commit}")
      project_relative, project_path = project_path(root, identity)
      source_project = capture!("git", "-C", root, "show", "#{source_head}:#{project_relative}")
      nonempty_string!(record["sourceProjectDigest"], "activation sourceProjectDigest", pattern: /\A[a-f0-9]{64}\z/)
      fail!("activation source project digest drifted") unless record["sourceProjectDigest"] == digest(source_project)

      activation_input = record["activationInput"]
      validate_input(activation_input, identity, source_project, root: root, require_fresh: false)
      expected_input_digest = digest(canonical_json(activation_input))
      nonempty_string!(record["inputDigest"], "activation inputDigest", pattern: /\A[a-f0-9]{64}\z/)
      fail!("activation input digest drifted") unless record["inputDigest"] == expected_input_digest
      fail!("activation deployment target drifted") unless record["deploymentTarget"] == activation_input["deploymentTarget"]
      fail!("activation official source record drifted") unless record["officialSources"] == activation_input["officialSources"]
      expected_package = {
        "url" => PACKAGE_URL,
        "version" => PACKAGE_VERSION,
        "revision" => PACKAGE_REVISION,
        "umpVersion" => UMP_VERSION,
        "umpRevision" => UMP_REVISION,
      }
      fail!("activation package record drifted") unless record["package"] == expected_package
      expected_policy = {
        "configurationSeparation" => ["debug-demo", "ui-test-offline", "release-app-specific"],
        "tracking" => "non-tracking",
        "attPrompt" => false,
        "publisherFirstPartyIDEnabled" => false,
        "personalizedAds" => false,
        "releaseReadiness" => "deferred",
      }
      fail!("activation policy record drifted") unless record["policy"] == expected_policy

      expected_paths = generated_paths(identity) - [RECORD_PATH]
      digests = record["fileDigests"]
      fail!("activation fileDigests do not cover the exact generated set") unless digests.is_a?(Hash) && digests.keys.sort == expected_paths.sort
      digests.each do |relative, expected|
        nonempty_string!(expected, "activation file digest for #{relative}", pattern: /\A[a-f0-9]{64}\z/)
        path = File.join(root, relative)
        fail!("activated file is missing or unsafe: #{relative}") unless File.file?(path) && !File.symlink?(path)
        fail!("activated file drifted: #{relative}") unless digest(File.binread(path)) == expected
      end

      module_name = identity.fetch("moduleName")
      project = File.binread(project_path)
      fail!("project package URL/version is missing") unless project.include?("repositoryURL = \"#{PACKAGE_URL}\";") && project.include?("kind = exactVersion;") && project.include?("version = #{PACKAGE_VERSION};")
      fail!("project does not link GoogleMobileAds") unless project.include?("productName = GoogleMobileAds;") && project.include?("GoogleMobileAds in Frameworks")
      fail!("project must use configuration-specific Info.plist sources") unless project.include?("#{module_name}/AdMob/Info-Debug.plist") && project.include?("#{module_name}/AdMob/Info-Release.plist")
      capture!("/usr/bin/plutil", "-convert", "json", "-o", "-", project_path)

      validate_plist!(File.join(root, "#{module_name}/AdMob/Info-Debug.plist"), DEBUG_APP_ID)
      release_id = File.binread(File.join(root, "#{module_name}/AdMob/Info-Release.plist"))[/<key>GADApplicationIdentifier<\/key>\s*<string>([^<]+)<\/string>/, 1]
      fail!("Release Info.plist must not use the demo App ID") unless release_id && release_id != DEBUG_APP_ID
      validate_plist!(File.join(root, "#{module_name}/AdMob/Info-Release.plist"), release_id)

      source_bytes = %w[AdMobConfiguration.swift AdMobCore.swift AdaptiveBannerHost.swift GoogleMobileAdsProvider.swift].map do |name|
        File.binread(File.join(root, module_name, "AdMob", name))
      end.join("\n")
      fail!("activated configuration is not bound to the canonical input") unless source_bytes.include?("activationInputDigest = \"#{record.fetch('inputDigest')}\"")
      fail!("activated sources must not invoke AppTrackingTransparency") if source_bytes.match?(/ATTrackingManager|requestTrackingAuthorization|AppTrackingTransparency/)
      fail!("activated provider must disable publisher first-party ID") unless source_bytes.include?("setPublisherFirstPartyIDEnabled(false)")
      fail!("activated provider must disable publisher personalization") unless source_bytes.include?("publisherPrivacyPersonalizationState = .disabled")
      fail!("activated provider must use the current large anchored adaptive API") unless source_bytes.include?("largeAnchoredAdaptiveBanner(width:")
      fail!("activated provider must update consent before checking canRequestAds") unless source_bytes.include?("requestConsentInfoUpdate") && source_bytes.include?("canRequestAds")

      record
    end

    def validate_fresh_surface!(root, identity)
      module_name = identity.fetch("moduleName")
      forbidden = [
        File.join(root, RECORD_PATH),
        File.join(root, module_name, "AdMob"),
      ]
      forbidden.each { |path| fail!("AdMob activation surface already exists without a valid record: #{path.delete_prefix(root + '/')}") if File.exist?(path) || File.symlink?(path) }
    end

    def status_paths(root)
      raw = capture!("git", "-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
      raw.split("\0").reject(&:empty?).map { |entry| entry[3..] }
    end

    def default_branch_at(root)
      output, = Open3.capture3(
        "git", "-C", root, "symbolic-ref", "--quiet", "--short",
        "refs/remotes/origin/HEAD"
      )
      ref = output.strip
      fail!("origin default branch must be resolved before activation") unless ref.match?(/\Aorigin\/[A-Za-z0-9._\/-]+\z/)
      ref.delete_prefix("origin/")
    end

    def emit(status, root, record)
      puts canonical_json(
        {
          "status" => status,
          "root" => root,
          "record" => RECORD_PATH,
          "inputDigest" => record.fetch("inputDigest"),
          "packageVersion" => record.dig("package", "version"),
        }
      )
    end

    def apply(root, input_path)
      root = resolve_root(root)
      identity = identity_at(root)
      project_relative, project_absolute = project_path(root, identity)
      original_project = File.binread(project_absolute)
      input = load_json(File.expand_path(input_path), "activation input")
      validate_input(input, identity, original_project, root: root)
      expected_input_digest = digest(canonical_json(input))

      record_path = File.join(root, RECORD_PATH)
      if File.exist?(record_path) || File.symlink?(record_path)
        record = validate_activated(root)
        fail!("AdMob is already activated with different input") unless record["inputDigest"] == expected_input_digest
        emit("already-complete", root, record)
        return
      end

      validate_fresh_surface!(root, identity)
      branch = capture!("git", "-C", root, "symbolic-ref", "--quiet", "--short", "HEAD").strip
      default_branch = default_branch_at(root)
      fail!("activation must run on a feature branch") if [default_branch, "main", "master"].include?(branch)
      fail!("derived app worktree must be clean before activation") unless status_paths(root).empty?
      start_head = capture!("git", "-C", root, "rev-parse", "HEAD").strip

      Dir.mktmpdir("ios-template-admob.") do |temporary|
        stage = File.join(temporary, "worktree")
        registered = false
        begin
          capture!("git", "-C", root, "worktree", "add", "--detach", "--quiet", stage, start_head)
          registered = true
          stage_identity = identity_at(stage)
          stage_project_relative, stage_project_absolute = project_path(stage, stage_identity)
          stage_project = File.binread(stage_project_absolute)
          validate_input(input, stage_identity, stage_project, root: stage)
          outputs = build_outputs(stage, input, stage_identity, stage_project_relative, stage_project, start_head)
          outputs.each { |relative, bytes| ensure_parent_and_write(stage, relative, bytes) }
          validate_activated(stage)

          allowed = generated_paths(stage_identity)
          capture!("git", "-C", stage, "add", "--", *allowed)
          names = capture!("git", "-C", stage, "diff", "--cached", "--name-only", "--diff-filter=ACMRTUXB", "HEAD").lines.map(&:strip).reject(&:empty?)
          fail!("staged activation changed an unexpected path") unless names.sort == allowed.sort
          deletions = capture!("git", "-C", stage, "diff", "--cached", "--name-only", "--diff-filter=D", "HEAD").strip
          fail!("activation must not delete files") unless deletions.empty?
          patch = capture!("git", "-C", stage, "diff", "--cached", "--binary", "--full-index", "HEAD", "--", *allowed)
          fail!("activation produced an empty patch") if patch.empty?

          fail!("derived app Head changed during activation") unless capture!("git", "-C", root, "rev-parse", "HEAD").strip == start_head
          fail!("derived app worktree changed during activation") unless status_paths(root).empty?
          capture!("git", "-C", root, "apply", "--check", "--binary", "-", stdin_data: patch)
          capture!("git", "-C", root, "apply", "--binary", "-", stdin_data: patch)
          begin
            record = validate_activated(root)
          rescue StandardError
            capture!("git", "-C", root, "apply", "--reverse", "--binary", "-", stdin_data: patch)
            raise
          end
          emit("applied", root, record)
        ensure
          if registered
            system("git", "-C", root, "worktree", "remove", "--force", stage, out: File::NULL, err: File::NULL)
          end
        end
      end
    end

    def parse_cli(argv)
      command = argv.shift
      fail!("command must be apply or validate") unless %w[apply validate].include?(command)
      options = {}
      until argv.empty?
        flag = argv.shift
        fail!("unexpected argument: #{flag}") unless %w[--root --input].include?(flag)
        fail!("duplicate option: #{flag}") if options.key?(flag)
        value = argv.shift
        fail!("missing value for #{flag}") unless value && !value.empty?
        options[flag] = value
      end
      fail!("--root is required") unless options["--root"]
      fail!("--input is required for apply") if command == "apply" && !options["--input"]
      fail!("--input is not allowed for validate") if command == "validate" && options["--input"]
      [command, options]
    end

    def main(argv)
      command, options = parse_cli(argv)
      if command == "apply"
        apply(options.fetch("--root"), options.fetch("--input"))
      else
        root = resolve_root(options.fetch("--root"))
        record = validate_activated(root)
        emit("valid", root, record)
      end
    rescue Error => error
      warn "admob-activation: #{error.message}"
      exit 1
    end
  end
end

IOSTemplate::AdMobActivation.main(ARGV) if $PROGRAM_NAME == __FILE__
