# frozen_string_literal: true

module IOSTemplate
  module AppStorePreparation
    class CodeInventory
      TEXT_EXTENSIONS = %w[.swift .m .mm .h .hh .hpp .hxx .c .cc .cpp .cxx .s .S .asm .metal .plist .xcprivacy .entitlements .xcconfig .json .yml .yaml .js .ts .html .css .xml .strings .stringsdict .storyboard .xib .xcstrings .resolved].freeze
      DEPENDENCIES = %w[Package.swift Package.resolved Podfile Podfile.lock Cartfile Cartfile.resolved].freeze
      SDK_MARKERS = {
        "admob" => /AdMob|GoogleMobileAds|Google-Mobile-Ads|googleads-mobile-ios/i,
        "ump" => /UserMessagingPlatform|user-messaging-platform|GoogleUserMessagingPlatform|\bUMP\b/i
      }.freeze
      SDK_DECLARATION_IDS = {
        "admob" => %w[admob googlemobileads google-mobile-ads google-mobile-ads-sdk googleads-mobile-ios],
        "ump" => %w[ump usermessagingplatform user-messaging-platform google-user-messaging-platform]
      }.freeze

      def self.inventory_affected?(id)
        id.start_with?("privacy.", "legal.", "iap.") || %w[privacyPolicyURL reviewNotes ageRating contentRights exportCompliance demoAccess].include?(id)
      end

      def self.feature_copy?(id)
        %w[description keywords promotionalText releaseNotes].include?(id)
      end

      def self.privacy_affected?(id)
        id.start_with?("privacy.") || %w[legal.privacyPolicy legal.termsOfUse privacyPolicyURL reviewNotes].include?(id)
      end

      def initialize(sources, values, xcode)
        @sources, @values, @xcode = sources, values, xcode
        @paths, @reasons, @detected, @permissions = [], [], [], []
        @privacy_manifest_reasons = []
        @privacy_manifest_tracking = false
        @privacy_manifest_collects_data = false
        @package_identities, @package_pins = [], {}
        @visited = 0
        @inventory_complete = false
        @inventory_reasons = nil
        @privacy_reasons = []
      end

      def inspect_file(path, optional: false)
        bytes = @sources.read(path)
        @paths << path unless @paths.include?(path)
        if bytes.nil?
          source_error = @sources.error(path)
          @reasons << (source_error == "sensitive-source" ? "unsafe-code-source" : "code-source-unavailable") unless optional && source_error == "missing-source"
          return
        end
        if path.end_with?(".json", ".yml", ".yaml", ".resolved") && !%w[Cartfile.resolved].include?(File.basename(path))
          # Package.resolved is JSON even though its suffix is not .json.
          value = @sources.document(path)
          if value.nil?
            @reasons << "unsafe-code-source"
            return
          end
          if File.basename(path) == "Package.resolved"
            pins = value.is_a?(Hash) && (value["version"] == 1 ? value.dig("object", "pins") : value["pins"])
            unless value.is_a?(Hash) && [1, 2, 3].include?(value["version"]) && pins.is_a?(Array)
              @reasons << "dependency-inventory-unresolved"
              return
            end
            parsed_pins = pins.map do |pin|
              identity = pin.is_a?(Hash) && (pin["identity"] || pin["package"])
              location = pin.is_a?(Hash) && (value["version"] == 1 ? pin["repositoryURL"] : pin["location"])
              state = pin.is_a?(Hash) && pin["state"]
              normalized = RemotePackageReference.parse(location)
              kind_valid = value["version"] == 1 || pin["kind"] == "remoteSourceControl"
              unless identity.is_a?(String) && identity.match?(/\A[A-Za-z0-9._-]{1,128}\z/) && normalized &&
                normalized["identity"] == identity.downcase && state.is_a?(Hash) &&
                state["revision"].is_a?(String) && state["revision"].match?(/\A[0-9a-f]{40}\z/) && kind_valid
                @reasons << "dependency-inventory-unresolved"
                next nil
              end
              {"identity" => identity.downcase, "location" => normalized["location"], "revision" => state["revision"]}
            end.compact
            @reasons << "dependency-inventory-unresolved" unless parsed_pins.map { |pin| pin["identity"] }.uniq.length == parsed_pins.length
            @package_pins[path] = parsed_pins
            @package_identities.concat(parsed_pins.map { |pin| pin["identity"] })
          end
        elsif path.end_with?(".plist", ".xcprivacy", ".entitlements", ".pbxproj")
          output, _, status = Open3.capture3("/usr/bin/plutil", "-convert", "json", "-o", "-", "--", "-", stdin_data: bytes)
          unless status.success?
            path.end_with?(".xcprivacy") ? @privacy_manifest_reasons << "privacy-manifest-unresolved" : @reasons << "invalid-code-property-list"
            return
          end
          property_list = JSON.parse(output, object_class: UniqueObject)
          sensitive = if path.end_with?(".pbxproj")
                        @sources.sensitive_xcode_document?(property_list)
                      else
                        @sources.sensitive_document?(property_list)
                      end
          if sensitive
            @sources.reject_sensitive(path)
            @reasons << "unsafe-code-source"
            return
          end
          if path.end_with?(".xcprivacy")
            allowed_keys = %w[NSPrivacyAccessedAPITypes NSPrivacyCollectedDataTypes NSPrivacyTracking NSPrivacyTrackingDomains]
            tracking = property_list.is_a?(Hash) ? property_list["NSPrivacyTracking"] : nil
            domains = property_list.is_a?(Hash) ? property_list.fetch("NSPrivacyTrackingDomains", []) : nil
            collected = property_list.is_a?(Hash) ? property_list.fetch("NSPrivacyCollectedDataTypes", []) : nil
            accessed = property_list.is_a?(Hash) ? property_list.fetch("NSPrivacyAccessedAPITypes", []) : nil
            collected_valid = collected.is_a?(Array) && collected.all? do |entry|
              entry.is_a?(Hash) && entry.keys.sort == %w[NSPrivacyCollectedDataType NSPrivacyCollectedDataTypeLinked NSPrivacyCollectedDataTypePurposes NSPrivacyCollectedDataTypeTracking] &&
                entry["NSPrivacyCollectedDataType"].is_a?(String) && !entry["NSPrivacyCollectedDataType"].empty? &&
                [true, false].include?(entry["NSPrivacyCollectedDataTypeLinked"]) && [true, false].include?(entry["NSPrivacyCollectedDataTypeTracking"]) &&
                entry["NSPrivacyCollectedDataTypePurposes"].is_a?(Array) && !entry["NSPrivacyCollectedDataTypePurposes"].empty? &&
                entry["NSPrivacyCollectedDataTypePurposes"].uniq == entry["NSPrivacyCollectedDataTypePurposes"] &&
                entry["NSPrivacyCollectedDataTypePurposes"].all? { |purpose| purpose.is_a?(String) && !purpose.empty? }
            end
            accessed_valid = accessed.is_a?(Array) && accessed.all? do |entry|
              entry.is_a?(Hash) && entry.keys.sort == %w[NSPrivacyAccessedAPIType NSPrivacyAccessedAPITypeReasons] &&
                entry["NSPrivacyAccessedAPIType"].is_a?(String) && !entry["NSPrivacyAccessedAPIType"].empty? &&
                entry["NSPrivacyAccessedAPITypeReasons"].is_a?(Array) && !entry["NSPrivacyAccessedAPITypeReasons"].empty? &&
                entry["NSPrivacyAccessedAPITypeReasons"].uniq == entry["NSPrivacyAccessedAPITypeReasons"] &&
                entry["NSPrivacyAccessedAPITypeReasons"].all? { |reason| reason.is_a?(String) && !reason.empty? }
            end
            valid_manifest = property_list.is_a?(Hash) && (property_list.keys - allowed_keys).empty? &&
              [true, false].include?(tracking) && domains.is_a?(Array) && domains.all? { |domain| domain.is_a?(String) && !domain.empty? } &&
              collected_valid && accessed_valid
            unless valid_manifest
              @privacy_manifest_reasons << "privacy-manifest-unresolved"
              return
            end
            detail_tracking = !domains.empty? || collected.any? { |entry| entry["NSPrivacyCollectedDataTypeTracking"] == true }
            @privacy_manifest_reasons << "privacy-manifest-unresolved" if detail_tracking && tracking == false
            @privacy_manifest_tracking ||= tracking || detail_tracking
            @privacy_manifest_collects_data ||= !collected.empty?
          end
        end
        SDK_MARKERS.each { |name, marker| @detected << name if bytes.match?(marker) }
        @permissions.concat(bytes.scan(/NS[A-Za-z]+UsageDescription/))
      rescue JSON::ParserError, InvalidInput
        path.end_with?(".xcprivacy") ? @privacy_manifest_reasons << "privacy-manifest-unresolved" : @reasons << "invalid-dependency-source"
      end

      def walk(root, depth = 0)
        raise InvalidInput, "code-inventory-depth" if depth > 32
        @sources.children(root).each do |name|
          path = "#{root}/#{name}"
          @visited += 1
          raise InvalidInput, "code-inventory-limit" if @visited > 8192
          kind = @sources.kind(path)
          if kind == "directory"
            # Asset catalogs contain images, not dependency or permission
            # declarations. Source/SDK directories are always traversed.
            next if name.end_with?(".xcassets") || %w[.git .build .swiftpm].include?(name)
            if name.end_with?(".framework", ".xcframework")
              @reasons << "embedded-sdk-audit-required"
            end
            walk(path, depth + 1)
          elsif TEXT_EXTENSIONS.include?(File.extname(name)) || DEPENDENCIES.include?(name)
            inspect_file(path)
          end
        end
      end

      def canonical_declaration(value)
        return nil unless value.is_a?(String) && value.bytesize.between?(1, 128) && value.match?(/\A[A-Za-z0-9._-]+\z/)
        value.downcase
      end

      def declared_sdk?(declared, detected)
        accepted = SDK_DECLARATION_IDS.fetch(detected).map { |value| canonical_declaration(value) }
        accepted.include?(canonical_declaration(declared))
      end

      def run
        module_name = @values.call(IDENTITY, "moduleName")
        raise InvalidInput, "code-module-unresolved" unless module_name.is_a?(String) && module_name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        roots = @xcode.fetch("sourceRoots", [])
        roots = [module_name] if roots.empty?
        roots.uniq.each { |root| walk(root) }
        @xcode.fetch("sourceFiles", []).each { |path| inspect_file(path) }
        @xcode.fetch("buildFiles", []).each do |path|
          next if @paths.include?(path)
          if @sources.kind(path) == "directory"
            walk(path)
          elsif TEXT_EXTENSIONS.include?(File.extname(path)) || DEPENDENCIES.include?(File.basename(path))
            inspect_file(path)
          end
        end
        @xcode.fetch("sources", []).each do |descriptor|
          path = descriptor["path"]
          next if !path.is_a?(String) || @paths.include?(path)
          inspect_file(path, optional: true)
        end
        @reasons << "code-target-sources-unresolved" unless @xcode.fetch("sourceProblems", []).empty?
        walk("Config")
        inspect_file("#{module_name}.xcodeproj/project.pbxproj")
        workspace_lock = "#{module_name}.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        inspect_file(workspace_lock, optional: true)
        remote_packages = @xcode.fetch("remotePackages", [])
        if !remote_packages.empty? && @sources.error(workspace_lock)
          @reasons << "dependency-lock-unavailable"
        elsif !remote_packages.empty?
          locked = @package_pins.fetch(workspace_lock, [])
          matched = remote_packages.all? do |package|
            locked.count { |pin| pin["identity"] == package["identity"] && pin["location"] == package["location"] } == 1
          end
          @reasons << "dependency-lock-mismatch" unless matched
        end
        DEPENDENCIES.each { |path| inspect_file(path, optional: true) }
        @inventory_complete = @reasons.empty?
        @inventory_reasons = @reasons.uniq
        @reasons = []
        @reasons.concat(SourceSchema.new(@sources, @values).privacy_document_reasons)
        %w[collectsData tracking].each do |field|
          value = @values.call(PRIVACY, field)
          @reasons << "privacy-declaration-unresolved" unless value == true || value == false
        end
        data_types = @values.call(PRIVACY, "dataTypes")
        @reasons << "privacy-declaration-unresolved" unless data_types.is_a?(Array) && data_types.all? { |item| item.is_a?(String) && !item.empty? }
        deletion = @values.call(PRIVACY, "accountDeletion")
        @reasons << "privacy-declaration-unresolved" unless deletion.is_a?(Hash) && deletion.keys.sort == %w[reason required] &&
          [true, false].include?(deletion["required"]) && deletion["reason"].is_a?(String) && !deletion["reason"].strip.empty?
        accounts_supported = @values.call(APP, "accountsSupported")
        @reasons << "privacy-declaration-unresolved" unless accounts_supported.equal?(true) || accounts_supported.equal?(false)
        if accounts_supported == true && !(deletion.is_a?(Hash) && deletion["required"] == true)
          @reasons << "account-deletion-declaration-inconsistent"
        elsif accounts_supported == false && deletion.is_a?(Hash) && deletion["required"] == true
          @reasons << "account-deletion-declaration-inconsistent"
        end
        declared_sdks = @values.call(PRIVACY, "thirdPartySDKs")
        if !declared_sdks.is_a?(Array) || !declared_sdks.all? { |name| name.is_a?(String) }
          @reasons << "sdk-declaration-unresolved"
        else
          @detected.uniq.each do |name|
            @reasons << "sdk-declaration-missing:#{name}" unless declared_sdks.any? { |declared| declared_sdk?(declared, name) }
          end
        end
        collects_data = @values.call(PRIVACY, "collectsData")
        tracking = @values.call(PRIVACY, "tracking")
        @reasons.concat(@privacy_manifest_reasons)
        if @privacy_manifest_tracking && tracking != true || @privacy_manifest_collects_data && collects_data != true
          @reasons << "privacy-manifest-declaration-inconsistent"
        end
        if tracking == true && collects_data != true ||
            collects_data == true && data_types.is_a?(Array) && data_types.empty? ||
            collects_data == false && (data_types.is_a?(Array) && !data_types.empty? || declared_sdks.is_a?(Array) && !declared_sdks.empty?)
          @reasons << "privacy-declaration-inconsistent"
        end
        declared_permissions = @values.call(PRIVACY, "permissions")
        if !declared_permissions.is_a?(Array) || !declared_permissions.all? { |name| name.is_a?(String) }
          @reasons << "permission-declaration-unresolved"
        elsif !(@permissions.uniq - declared_permissions).empty?
          @reasons << "permission-declaration-missing"
        end
        @privacy_reasons = @reasons.uniq
        result
      rescue InvalidInput, SystemCallError, IOError
        if @inventory_reasons
          @inventory_reasons << "code-inventory-unavailable"
          @privacy_reasons = @reasons.uniq
        else
          @reasons << "code-inventory-unavailable"
          @inventory_reasons = @reasons.uniq
        end
        result
      end

      def result
        # Bind every inspected file, not just those containing known SDK names.
        # Human review still determines collection/tracking behavior; absence of
        # these markers is never a privacy declaration or automatic approval.
        sources = @paths.sort.map { |path| @sources.descriptor(path, "document") }
        sources.concat(@xcode.fetch("sources"))
        sources.uniq!
        module_name = @values.call(IDENTITY, "moduleName")
        build_paths = @xcode.fetch("sourceRoots", []) + @xcode.fetch("sourceFiles", []) + @xcode.fetch("buildFiles", []) +
          @xcode.fetch("sources", []).map { |source| source["path"] } +
          ["Config", "#{module_name}.xcodeproj/project.pbxproj", "#{module_name}.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"] + DEPENDENCIES
        bound = @inventory_complete && @sources.build_inputs_bound?(build_paths, sources.map { |source| source["path"] })
        descriptors_current = sources.select { |source| source["digest"] }.all? { |source| source["revision"] == @sources.revision }
        source_revision_current = @inventory_complete && descriptors_current && @sources.committed_paths_current?(build_paths)
        inventory_reasons = (@inventory_reasons || @reasons).uniq
        inventory_reasons << "code-inventory-source-drift" unless bound
        privacy_reasons = @privacy_reasons.uniq
        {"sources" => sources, "reasons" => (inventory_reasons + privacy_reasons).uniq,
         "inventoryReasons" => inventory_reasons, "privacyReasons" => privacy_reasons, "inventoryComplete" => bound,
         "sourceRevisionCurrent" => source_revision_current}
      end
    end
  end
end
