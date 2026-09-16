# frozen_string_literal: true

module IOSTemplate
  module AppStorePreparation
    class CodeInventory
      TEXT_EXTENSIONS = %w[.swift .m .mm .h .c .cpp .metal .plist .xcprivacy .entitlements .xcconfig .json .yml .yaml .js .ts .storyboard .xib .xcstrings .resolved].freeze
      DEPENDENCIES = %w[Package.swift Package.resolved Podfile Podfile.lock Cartfile Cartfile.resolved].freeze
      SDK_MARKERS = {
        "admob" => /AdMob|GoogleMobileAds|Google-Mobile-Ads|googleads-mobile-ios/i,
        "ump" => /UserMessagingPlatform|user-messaging-platform|GoogleUserMessagingPlatform|\bUMP\b/i
      }.freeze

      def self.affected?(id)
        id.start_with?("privacy.", "legal.", "iap.") || %w[privacyPolicyURL reviewNotes ageRating contentRights exportCompliance demoAccess].include?(id)
      end

      def self.feature_copy?(id)
        %w[description keywords promotionalText releaseNotes].include?(id)
      end

      def initialize(sources, values, xcode)
        @sources, @values, @xcode = sources, values, xcode
        @paths, @reasons, @detected, @permissions = [], [], [], []
        @package_identities = []
        @visited = 0
        @inventory_complete = false
      end

      def inspect_file(path, optional: false)
        bytes = @sources.read(path)
        @paths << path unless @paths.include?(path)
        if bytes.nil?
          @reasons << "code-source-unavailable" unless optional && @sources.error(path) == "missing-source"
          return
        end
        if path.end_with?(".json", ".yml", ".yaml", ".resolved") && !%w[Cartfile.resolved].include?(File.basename(path))
          # Package.resolved is JSON even though its suffix is not .json.
          value = path.end_with?(".resolved") ? JSON.parse(bytes, object_class: UniqueObject) : @sources.document(path)
          if value.nil? || @sources.sensitive_document?(value)
            @sources.reject_sensitive(path) if value && @sources.sensitive_document?(value)
            @reasons << "unsafe-code-source"
            return
          end
          if File.basename(path) == "Package.resolved"
            pins = value.is_a?(Hash) && (value["version"] == 1 ? value.dig("object", "pins") : value["pins"])
            unless value.is_a?(Hash) && [1, 2, 3].include?(value["version"]) && pins.is_a?(Array)
              @reasons << "dependency-inventory-unresolved"
              return
            end
            pins.each do |pin|
              identity = pin.is_a?(Hash) && (pin["identity"] || pin["package"])
              state = pin.is_a?(Hash) && pin["state"]
              unless identity.is_a?(String) && identity.match?(/\A[A-Za-z0-9._-]{1,128}\z/) && state.is_a?(Hash) &&
                state["revision"].is_a?(String) && state["revision"].match?(/\A[0-9a-f]{40}\z/)
                @reasons << "dependency-inventory-unresolved"
                next
              end
              @package_identities << identity
            end
          end
        elsif path.end_with?(".plist", ".xcprivacy", ".entitlements", ".pbxproj")
          output, _, status = Open3.capture3("/usr/bin/plutil", "-convert", "json", "-o", "-", "--", "-", stdin_data: bytes)
          unless status.success?
            @reasons << "invalid-code-property-list"
            return
          end
          if @sources.sensitive_document?(JSON.parse(output, object_class: UniqueObject))
            @sources.reject_sensitive(path)
            @reasons << "unsafe-code-source"
            return
          end
        end
        SDK_MARKERS.each { |name, marker| @detected << name if bytes.match?(marker) }
        @permissions.concat(bytes.scan(/NS[A-Za-z]+UsageDescription/))
      rescue JSON::ParserError, InvalidInput
        @reasons << "invalid-dependency-source"
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

      def run
        module_name = @values.call(IDENTITY, "moduleName")
        raise InvalidInput, "code-module-unresolved" unless module_name.is_a?(String) && module_name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        roots = @xcode.fetch("sourceRoots", [])
        roots = [module_name] if roots.empty?
        roots.uniq.each { |root| walk(root) }
        @xcode.fetch("sourceFiles", []).each { |path| inspect_file(path) }
        @reasons << "code-target-sources-unresolved" unless @xcode.fetch("sourceProblems", []).empty?
        walk("Config")
        inspect_file("#{module_name}.xcodeproj/project.pbxproj")
        inspect_file("#{module_name}.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", optional: true)
        if @xcode["requiresPackageResolution"] && @sources.error("#{module_name}.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
          @reasons << "dependency-lock-unavailable"
        end
        DEPENDENCIES.each { |path| inspect_file(path, optional: true) }
        @inventory_complete = @reasons.empty?
        %w[collectsData tracking].each do |field|
          value = @values.call(PRIVACY, field)
          @reasons << "privacy-declaration-unresolved" unless value == true || value == false
        end
        data_types = @values.call(PRIVACY, "dataTypes")
        @reasons << "privacy-declaration-unresolved" unless data_types.is_a?(Array) && data_types.all? { |item| item.is_a?(String) && !item.empty? }
        deletion = @values.call(PRIVACY, "accountDeletion")
        @reasons << "privacy-declaration-unresolved" unless deletion.is_a?(Hash) && deletion.keys.sort == %w[reason required] &&
          [true, false].include?(deletion["required"]) && deletion["reason"].is_a?(String) && !deletion["reason"].strip.empty?
        declared_sdks = @values.call(PRIVACY, "thirdPartySDKs")
        if !declared_sdks.is_a?(Array) || !declared_sdks.all? { |name| name.is_a?(String) }
          @reasons << "sdk-declaration-unresolved"
        else
          @detected.uniq.each do |name|
            @reasons << "sdk-declaration-missing:#{name}" unless declared_sdks.any? { |declared| declared.match?(SDK_MARKERS.fetch(name)) }
          end
          @package_identities.uniq.each do |identity|
            normalized = identity.downcase.gsub(/[^a-z0-9]/, "")
            described = declared_sdks.any? do |declared|
              declared.downcase.gsub(/[^a-z0-9]/, "").include?(normalized) ||
                SDK_MARKERS.values.any? { |marker| identity.match?(marker) && declared.match?(marker) }
            end
            @reasons << "dependency-declaration-missing" unless described
          end
        end
        declared_permissions = @values.call(PRIVACY, "permissions")
        if !declared_permissions.is_a?(Array) || !declared_permissions.all? { |name| name.is_a?(String) }
          @reasons << "permission-declaration-unresolved"
        elsif !(@permissions.uniq - declared_permissions).empty?
          @reasons << "permission-declaration-missing"
        end
        result
      rescue InvalidInput, SystemCallError, IOError
        @reasons << "code-inventory-unavailable"
        result
      end

      def result
        # Bind every inspected file, not just those containing known SDK names.
        # Human review still determines collection/tracking behavior; absence of
        # these markers is never a privacy declaration or automatic approval.
        sources = @paths.sort.map { |path| @sources.descriptor(path, "document") }
        sources.concat(@xcode.fetch("sources"))
        {"sources" => sources.uniq, "reasons" => @reasons.uniq, "inventoryComplete" => @inventory_complete}
      end
    end
  end
end
