# frozen_string_literal: true

require "pathname"

module IOSTemplate
  module AppStorePreparation
    # Read build configuration as data. Never execute a project, a build phase,
    # package resolution, shell expansion, or an xcconfig include as code.
    class XcodeFacts
      FIELDS = %w[identity.displayName identity.module identity.bundleId platforms deviceSupport version build supportedLocales].freeze
      KEYS = %w[PRODUCT_BUNDLE_IDENTIFIER PRODUCT_NAME PRODUCT_MODULE_NAME INFOPLIST_KEY_CFBundleDisplayName MARKETING_VERSION CURRENT_PROJECT_VERSION TARGETED_DEVICE_FAMILY SUPPORTED_PLATFORMS SDKROOT GENERATE_INFOPLIST_FILE INFOPLIST_FILE].freeze

      def initialize(sources, values)
        @sources, @values = sources, values
        @paths = []
        @errors = Hash.new { |hash, key| hash[key] = [] }
        @source_roots, @source_files, @source_problems = [], [], []
        @requires_package_resolution = false
      end

      def reject(code)
        raise InvalidInput, code
      end

      def source(path)
        @sources.path!(path)
        @paths << path unless @paths.include?(path)
        @sources.read(path)
      end

      def configurations(list_id)
        list = @objects[list_id]
        reject("xcode-configuration-list-invalid") unless list.is_a?(Hash) && list["isa"] == "XCConfigurationList" &&
          list["buildConfigurations"].is_a?(Array) && !list["buildConfigurations"].empty?
        ids = list.fetch("buildConfigurations")
        reject("xcode-configuration-list-invalid") unless ids.uniq == ids
        configs = ids.map do |id|
          config = @objects[id]
          reject("xcode-configuration-invalid") unless config.is_a?(Hash) && config["isa"] == "XCBuildConfiguration" &&
            config["name"].is_a?(String) && config["buildSettings"].is_a?(Hash)
          config
        end
        reject("xcode-configuration-ambiguous") unless configs.map { |config| config["name"] }.uniq.length == configs.length
        configs
      end

      def reference_path(id, seen = [])
        reject("xcode-reference-cycle") if seen.include?(id) || seen.length > 32
        object = @objects[id]
        reject("xcode-reference-invalid") unless object.is_a?(Hash)
        tree = object["sourceTree"]
        component = object.fetch("path", "")
        reject("xcode-reference-invalid") unless component.is_a?(String)
        if tree == "SOURCE_ROOT"
          path = component
        elsif tree == "<group>" || id == @project["mainGroup"]
          if id == @project["mainGroup"]
            path = component
          else
            parents = @objects.select { |_, candidate| candidate.is_a?(Hash) && candidate["children"].is_a?(Array) && candidate["children"].include?(id) }.keys
            reject("xcode-reference-ambiguous") unless parents.length == 1
            parent = reference_path(parents.first, seen + [id])
            path = parent.empty? ? component : File.join(parent, component)
          end
        else
          reject("xcode-reference-unresolved")
        end
        return "" if path.empty? && id == @project["mainGroup"]
        @sources.path!(path)
      end

      def xcconfig(path, seen = [])
        reject("xcconfig-include-cycle") if seen.include?(path) || seen.length > 32
        bytes = source(path)
        reject("xcconfig-source-unavailable") unless bytes
        settings = {}
        # Comments are not build settings. Multi-line continuation and complex
        # conditional expressions are explicitly unresolved, never guessed.
        text = bytes.gsub(%r{/\*.*?\*/}m, "")
        text.each_line do |line|
          line = line.strip
          next if line.empty? || line.start_with?("//")
          if (include_line = line.match(/\A#include(\?)?\s+"([^"]+)"\s*(?:\/\/.*)?\z/))
            include_path = Pathname.new(File.join(File.dirname(path), include_line[2])).cleanpath.to_s
            @sources.path!(include_path)
            included = source(include_path)
            next if included.nil? && include_line[1] && @sources.error(include_path) == "missing-source"
            reject("xcconfig-source-unavailable") unless included
            settings.merge!(xcconfig(include_path, seen + [path]))
          elsif (assignment = line.match(/\A([A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]+\])*)\s*=\s*(.*?)\s*;?\z/))
            key, value = assignment[1], assignment[2].sub(/\s+\/\/.*\z/, "")
            reject("xcconfig-settings-unresolved") if value.end_with?("\\")
            settings[key] = value.sub(/\A"(.*)"\z/, '\1')
          else
            reject("xcconfig-settings-unresolved")
          end
        end
        settings
      end

      def settings(configuration)
        base = configuration["baseConfigurationReference"]
        result = base ? xcconfig(reference_path(base)) : {}
        result.merge(configuration.fetch("buildSettings"))
      end

      def resolved(settings, key, seen = [])
        reject("xcode-setting-cycle") if seen.include?(key) || seen.length > 32
        value = settings[key]
        return nil if value.nil?
        value = value.join(" ") if value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
        reject("xcode-setting-invalid") unless value.is_a?(String)
        value = value.gsub(/\$\(([^)]+)\)|\$\{([^}]+)\}/) do
          variable = Regexp.last_match(1) || Regexp.last_match(2)
          replacement = resolved(settings, variable, seen + [key])
          reject("xcode-setting-unresolved") unless replacement
          replacement
        end
        reject("xcode-setting-unresolved") if value.include?("$")
        value
      end

      def compare(field, actual, expected)
        @errors[field] << "xcode-#{field}-mismatch" unless !actual.nil? && actual == expected
      end

      def target_sources(target)
        groups = target.fetch("fileSystemSynchronizedGroups", [])
        reject("xcode-source-groups-invalid") unless groups.is_a?(Array)
        groups.each do |id|
          group = @objects[id]
          reject("xcode-source-group-invalid") unless group.is_a?(Hash) && group["isa"] == "PBXFileSystemSynchronizedRootGroup"
          @source_roots << reference_path(id)
        end
        phases = target.fetch("buildPhases", [])
        reject("xcode-build-phases-invalid") unless phases.is_a?(Array)
        phases.each do |id|
          phase = @objects[id]
          reject("xcode-build-phase-invalid") unless phase.is_a?(Hash)
          if phase["isa"] == "PBXShellScriptBuildPhase"
            @source_problems << "generated-source-audit-required"
          end
          next unless phase["isa"] == "PBXSourcesBuildPhase"
          files = phase["files"]
          reject("xcode-build-files-invalid") unless files.is_a?(Array)
          files.each do |file_id|
            file = @objects[file_id]
            reject("xcode-source-file-invalid") unless file.is_a?(Hash) && file["isa"] == "PBXBuildFile" && file["fileRef"]
            @source_files << reference_path(file["fileRef"])
          end
        end
        @objects.each_value do |object|
          next unless object.is_a?(Hash)
          if object["isa"] == "XCLocalSwiftPackageReference"
            path = object["relativePath"]
            @sources.path!(path)
            @source_roots << path
          elsif object["isa"] == "XCRemoteSwiftPackageReference"
            @requires_package_resolution = true
          end
        end
      rescue InvalidInput
        @source_problems << "target-source-resolution-required"
      end

      def run
        module_name = @values.call(IDENTITY, "moduleName")
        reject("xcode-module-unresolved") unless module_name.is_a?(String) && module_name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        path = "#{module_name}.xcodeproj/project.pbxproj"
        bytes = source(path)
        reject("xcode-project-unavailable") unless bytes
        output, _, status = Open3.capture3("/usr/bin/plutil", "-convert", "json", "-o", "-", "--", "-", stdin_data: bytes)
        reject("xcode-project-invalid") unless status.success?
        project = JSON.parse(output, object_class: UniqueObject)
        if @sources.sensitive_document?(project)
          @sources.reject_sensitive(path)
          reject("unsafe-xcode-project")
        end
        @objects = project["objects"]
        reject("xcode-project-invalid") unless @objects.is_a?(Hash)
        @project = @objects[project["rootObject"]]
        reject("xcode-project-invalid") unless @project.is_a?(Hash) && @project["isa"] == "PBXProject" && @project["targets"].is_a?(Array)
        targets = @project["targets"].map { |id| @objects[id] }.select do |target|
          target.is_a?(Hash) && target["isa"] == "PBXNativeTarget" && target["productType"] == "com.apple.product-type.application" && target["name"] == module_name
        end
        reject("xcode-app-target-ambiguous") unless targets.length == 1
        target = targets.first
        target_sources(target)
        project_configs = configurations(@project["buildConfigurationList"])
        target_configs = configurations(target["buildConfigurationList"])
        reject("xcode-project-configuration-mismatch") unless project_configs.map { |config| config["name"] }.sort == target_configs.map { |config| config["name"] }.sort
        target_configs.each do |target_config|
          project_config = project_configs.find { |config| config["name"] == target_config["name"] }
          actual = settings(project_config).merge(settings(target_config)).merge("TARGET_NAME" => target["name"])
          if actual.keys.any? { |key| KEYS.any? { |critical| key.start_with?("#{critical}[") } }
            reject("xcode-conditional-settings-unresolved")
          end
          compare("identity.bundleId", resolved(actual, "PRODUCT_BUNDLE_IDENTIFIER"), @values.call(IDENTITY, "bundleId"))
          compare("identity.module", resolved(actual, "PRODUCT_MODULE_NAME") || resolved(actual, "PRODUCT_NAME"), module_name)
          compare("identity.displayName", resolved(actual, "INFOPLIST_KEY_CFBundleDisplayName"), @values.call(IDENTITY, "displayName"))
          compare("version", resolved(actual, "MARKETING_VERSION"), @values.call(APP, "version"))
          compare("build", resolved(actual, "CURRENT_PROJECT_VERSION"), @values.call(VALUES, "build"))
          if resolved(actual, "GENERATE_INFOPLIST_FILE") != "YES" || actual.key?("INFOPLIST_FILE")
            reject("xcode-explicit-infoplist-unresolved")
          end
          families = resolved(actual, "TARGETED_DEVICE_FAMILY").to_s.split(",").map(&:strip).sort
          reject("xcode-device-family-unresolved") unless !families.empty? && families.uniq == families && (families - %w[1 2]).empty?
          declared = @values.call(APP, "platforms")
          compare("deviceSupport", {"iphone" => families.include?("1"), "ipad" => families.include?("2")}, declared)
          sdk = resolved(actual, "SDKROOT")
          @errors["platforms"] << "xcode-platform-mismatch" unless sdk == "iphoneos"
          platforms = resolved(actual, "SUPPORTED_PLATFORMS")
          if platforms && platforms.split.sort != %w[iphoneos iphonesimulator]
            @errors["platforms"] << "xcode-platform-mismatch"
          end
        end
        locales = @values.call(VALUES, "supportedLocales")
        regions = @project["knownRegions"]
        normalized = regions.is_a?(Array) ? regions.reject { |region| region == "Base" }.map { |region| region == "en" ? "en-US" : region }.sort : nil
        compare("supportedLocales", normalized, locales.is_a?(Array) ? locales.sort : nil)
        result
      rescue InvalidInput => error
        FIELDS.each { |field| @errors[field] << error.message }
        result
      rescue JSON::ParserError, TypeError, NoMethodError, SystemCallError
        FIELDS.each { |field| @errors[field] << "xcode-project-invalid" }
        result
      end

      def result
        {"fields" => @errors.transform_values(&:uniq), "sources" => @paths.map { |path| @sources.descriptor(path, "build-settings") },
         "sourceRoots" => @source_roots.uniq, "sourceFiles" => @source_files.uniq,
         "sourceProblems" => @source_problems.uniq, "requiresPackageResolution" => @requires_package_resolution}
      end
    end
  end
end
