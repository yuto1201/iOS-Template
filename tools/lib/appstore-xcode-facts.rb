# frozen_string_literal: true

require "pathname"
require "rexml/document"

module IOSTemplate
  module AppStorePreparation
    module RemotePackageReference
      module_function

      def parse(value)
        return nil unless value.is_a?(String) && value.bytesize.between?(1, 2048) && !value.match?(/[\x00-\x20\x7f?#]/)
        location, path = if (match = value.match(%r{\A(https)://([A-Za-z0-9.-]+)(:[0-9]+)?/([A-Za-z0-9._/-]+)\z}))
                           ["#{match[1]}://#{match[2].downcase}#{match[3]}/#{match[4]}", match[4]]
                         elsif (match = value.match(%r{\A(ssh)://([A-Za-z0-9._-]+@)?([A-Za-z0-9.-]+)(:[0-9]+)?/([A-Za-z0-9._/-]+)\z}))
                           ["#{match[1]}://#{match[2]}#{match[3].downcase}#{match[4]}/#{match[5]}", match[5]]
                         elsif (match = value.match(%r{\A([A-Za-z0-9._-]+)@([A-Za-z0-9.-]+):([A-Za-z0-9._/-]+)\z}))
                           ["ssh://#{match[1]}@#{match[2].downcase}/#{match[3]}", match[3]]
                         end
        return nil unless location && path && path.split("/", -1).none? { |part| part.empty? || part == "." || part == ".." }
        location = location.sub(%r{/\z}, "").sub(/\.git\z/i, "")
        component = path.sub(%r{/\z}, "").split("/").last.sub(/\.git\z/i, "").downcase
        return nil unless component.match?(/\A[a-z0-9][a-z0-9._-]{0,127}\z/)
        {"identity" => component, "location" => location}
      end
    end

    # Read build configuration as data. Never execute a project, a build phase,
    # package resolution, shell expansion, or an xcconfig include as code.
    class XcodeFacts
      FIELDS = %w[identity.displayName identity.module identity.bundleId platforms deviceSupport version build supportedLocales].freeze
      KEYS = %w[PRODUCT_BUNDLE_IDENTIFIER PRODUCT_NAME PRODUCT_MODULE_NAME INFOPLIST_KEY_CFBundleDisplayName MARKETING_VERSION CURRENT_PROJECT_VERSION TARGETED_DEVICE_FAMILY SUPPORTED_PLATFORMS SDKROOT GENERATE_INFOPLIST_FILE INFOPLIST_FILE].freeze
      FILE_INPUT_SETTINGS = %w[
        CODE_SIGN_ENTITLEMENTS GCC_PREFIX_HEADER INFOPLIST_PREFIX_HEADER MODULEMAP_FILE
        SWIFT_OBJC_BRIDGING_HEADER
      ].freeze
      UNRESOLVED_INPUT_SETTINGS = %w[
        FRAMEWORK_SEARCH_PATHS HEADER_SEARCH_PATHS LIBRARY_SEARCH_PATHS OTHER_CFLAGS
        INFOPLIST_OTHER_PREPROCESSOR_FLAGS OTHER_CPLUSPLUSFLAGS
        OTHER_LDFLAGS OTHER_SWIFT_FLAGS SWIFT_INCLUDE_PATHS SYSTEM_FRAMEWORK_SEARCH_PATHS
        SYSTEM_HEADER_SEARCH_PATHS SYSTEM_LIBRARY_SEARCH_PATHS USER_HEADER_SEARCH_PATHS
      ].freeze

      def initialize(sources, values)
        @sources, @values = sources, values
        @paths = []
        @errors = Hash.new { |hash, key| hash[key] = [] }
        @source_roots, @source_files, @build_files, @source_problems = [], [], [], []
        @remote_packages = []
        @package_references = {}
        @target_source_resolution_complete = false
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
        unless component.empty? && id == @project["mainGroup"]
          reject("xcode-reference-unresolved") if component.start_with?("/", "~") ||
            component.include?("$") || component.include?("\\") || component.match?(/[\x00-\x1f\x7f]/)
        end
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

      def system_sdk_reference?(reference)
        return false unless reference["sourceTree"] == "SDKROOT"
        path = reference["path"]
        return false unless path.is_a?(String) && path.bytesize.between?(1, 512) &&
          !path.start_with?("/", "~") && !path.include?("$") && !path.include?("\\") && !path.match?(/[\x00-\x1f\x7f]/)
        parts = path.split("/", -1)
        parts.none? { |part| part.empty? || part == "." || part == ".." } &&
          %w[.framework .tbd .dylib].include?(File.extname(path))
      end

      def xcconfig(path, seen = [], inherited_settings = {})
        reject("xcconfig-include-cycle") if seen.include?(path) || seen.length > 32
        bytes = source(path)
        reject("xcconfig-source-unavailable") unless bytes
        settings = inherited_settings.dup
        # Comments are not build settings. Multi-line continuation and complex
        # conditional expressions are explicitly unresolved, never guessed.
        text = bytes.gsub(%r{/\*.*?\*/}m, "")
        text.each_line do |line|
          line = line.strip
          next if line.empty? || line.start_with?("//")
          if (include_line = line.match(/\A#include(\?)?\s+"([^"]+)"\s*(?:\/\/.*)?\z/))
            operand = include_line[2]
            reject("xcconfig-include-path-unresolved") if operand.start_with?("/", "~") ||
              operand.include?("$") || operand.include?("\\") || operand.match?(/[\x00-\x1f\x7f]/)
            include_path = Pathname.new(File.join(File.dirname(path), operand)).cleanpath.to_s
            @sources.path!(include_path)
            included = source(include_path)
            next if included.nil? && include_line[1] && @sources.error(include_path) == "missing-source"
            reject("xcconfig-source-unavailable") unless included
            settings = xcconfig(include_path, seen + [path], settings)
          elsif (assignment = line.match(/\A([A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]+\])*)\s*=\s*(.*?)\s*;?\z/))
            key, value = assignment[1], assignment[2].sub(/\s+\/\/.*\z/, "")
            reject("xcconfig-settings-unresolved") if value.end_with?("\\")
            settings = merge_settings(settings, key => value.sub(/\A"(.*)"\z/, '\1'))
          else
            reject("xcconfig-settings-unresolved")
          end
        end
        settings
      end

      def settings(configuration)
        base = configuration["baseConfigurationReference"]
        result = base ? xcconfig(reference_path(base)) : {}
        merge_settings(result, configuration.fetch("buildSettings"))
      end

      def merge_settings(parent, child)
        child.each_with_object(parent.dup) do |(key, value), merged|
          has_inherited_value = merged.key?(key)
          inherited = merged[key]
          inherited = inherited.join(" ") if inherited.is_a?(Array) && inherited.all? { |item| item.is_a?(String) }
          inherited = "" if inherited.nil?
          reject("xcode-setting-invalid") unless inherited.is_a?(String)
          if value.is_a?(String)
            merged[key] = has_inherited_value ? value.gsub(/\$\(inherited\)|\$\{inherited\}/, inherited) : value
          elsif value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
            merged[key] = has_inherited_value ? value.map { |item| item.gsub(/\$\(inherited\)|\$\{inherited\}/, inherited) } : value
          else
            merged[key] = value
          end
        end
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

      def source_path_setting(settings, key)
        value = settings[key]
        return nil if value.nil?
        value = value.join(" ") if value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
        reject("xcode-build-input-setting-invalid") unless value.is_a?(String)
        value = value.strip.sub(/\A"(.*)"\z/, '\\1')
        return nil if value.empty?
        if (match = value.match(%r{\A(?:\$\((?:SRCROOT|PROJECT_DIR)\)|\$\{(?:SRCROOT|PROJECT_DIR)\})/(.+)\z}))
          value = match[1]
        elsif value.start_with?("/", "~") || value.include?("$")
          reject("xcode-build-input-setting-unresolved")
        end
        reject("xcode-build-input-setting-unresolved") if value.match?(/[\x00-\x1f\x7f]/)
        @sources.path!(value)
      end

      def nonempty_setting?(settings, key)
        value = settings[key]
        return false if value.nil?
        values = value.is_a?(Array) ? value : [value]
        reject("xcode-build-input-setting-invalid") unless values.all? { |item| item.is_a?(String) }
        values.any? { |item| !item.strip.empty? && item.strip != "$(inherited)" && item.strip != "${inherited}" }
      end

      def target_sources(target)
        framework_product_refs = []
        groups = target.fetch("fileSystemSynchronizedGroups", [])
        reject("xcode-source-groups-invalid") unless groups.is_a?(Array)
        groups.each do |id|
          group = @objects[id]
          reject("xcode-source-group-invalid") unless group.is_a?(Hash) && group["isa"] == "PBXFileSystemSynchronizedRootGroup"
          @source_roots << reference_path(id)
        end
        build_rules = target["buildRules"]
        reject("xcode-build-rules-invalid") unless build_rules.is_a?(Array) && build_rules.uniq == build_rules
        @source_problems << "generated-source-audit-required" unless build_rules.empty?
        phases = target["buildPhases"]
        reject("xcode-build-phases-invalid") unless phases.is_a?(Array) && phases.uniq == phases
        phases.each do |id|
          phase = @objects[id]
          reject("xcode-build-phase-invalid") unless phase.is_a?(Hash)
          if phase["isa"] == "PBXShellScriptBuildPhase"
            @source_problems << "generated-source-audit-required"
            next
          end
          if phase["isa"] == "PBXFrameworksBuildPhase"
            files = phase["files"]
            reject("xcode-build-files-invalid") unless files.is_a?(Array)
            files.each do |file_id|
              file = @objects[file_id]
              reject("xcode-source-file-invalid") unless file.is_a?(Hash) && file["isa"] == "PBXBuildFile"
              if file["fileRef"]
                reference = @objects[file["fileRef"]]
                reject("xcode-reference-invalid") unless reference.is_a?(Hash)
                if reference["sourceTree"] == "SDKROOT"
                  reject("xcode-system-framework-reference-invalid") unless system_sdk_reference?(reference)
                  next
                end
                @build_files << reference_path(file["fileRef"])
                @source_problems << "linked-dependency-audit-required"
              elsif file["productRef"]
                reject("xcode-package-product-invalid") unless file["productRef"].is_a?(String)
                framework_product_refs << file["productRef"]
              else
                reject("xcode-source-file-invalid")
              end
            end
            next
          end
          if phase["isa"] == "PBXCopyFilesBuildPhase"
            files = phase["files"]
            reject("xcode-build-files-invalid") unless files.is_a?(Array)
            @source_problems << "embedded-product-audit-required" unless files.empty?
            next
          end
          unless %w[PBXSourcesBuildPhase PBXResourcesBuildPhase].include?(phase["isa"])
            files = phase["files"]
            reject("xcode-build-files-invalid") unless files.is_a?(Array)
            @source_problems << "unsupported-build-phase-audit-required" unless files.empty?
            next
          end
          files = phase["files"]
          reject("xcode-build-files-invalid") unless files.is_a?(Array)
          files.each do |file_id|
            file = @objects[file_id]
            reject("xcode-source-file-invalid") unless file.is_a?(Hash) && file["isa"] == "PBXBuildFile" && file["fileRef"]
            path = reference_path(file["fileRef"])
            phase["isa"] == "PBXSourcesBuildPhase" ? @source_files << path : @build_files << path
          end
        end
        dependencies = target.fetch("dependencies", [])
        reject("xcode-target-dependencies-invalid") unless dependencies.is_a?(Array) && dependencies.uniq == dependencies
        @source_problems << "linked-target-audit-required" unless dependencies.empty?
        product_dependencies = target.fetch("packageProductDependencies", [])
        reject("xcode-package-products-invalid") unless product_dependencies.is_a?(Array) &&
          product_dependencies.all? { |id| id.is_a?(String) } && product_dependencies.uniq == product_dependencies
        package_references = @project.fetch("packageReferences", [])
        reject("xcode-package-references-invalid") unless package_references.is_a?(Array) &&
          package_references.all? { |id| id.is_a?(String) } && package_references.uniq == package_references
        package_references.each do |reference_id|
          object = @objects[reference_id]
          reject("xcode-package-reference-invalid") unless object.is_a?(Hash)
          if object["isa"] == "XCLocalSwiftPackageReference"
            path = object["relativePath"]
            reject("xcode-package-reference-invalid") unless path.is_a?(String)
            @sources.path!(path)
            @source_roots << path
            @package_references[reference_id] = {"kind" => "local", "path" => path}
          elsif object["isa"] == "XCRemoteSwiftPackageReference"
            package = RemotePackageReference.parse(object["repositoryURL"])
            reject("xcode-package-reference-invalid") unless package
            @remote_packages << package
            @package_references[reference_id] = package.merge("kind" => "remote")
          else
            reject("xcode-package-reference-invalid")
          end
        end
        reject("xcode-package-reference-ambiguous") unless @remote_packages.uniq == @remote_packages
        product_dependencies.each do |dependency_id|
          dependency = @objects[dependency_id]
          reject("xcode-package-product-invalid") unless dependency.is_a?(Hash) &&
            dependency["isa"] == "XCSwiftPackageProductDependency" &&
            dependency["productName"].is_a?(String) && dependency["productName"].match?(/\A[A-Za-z0-9._-]{1,128}\z/) &&
            @package_references.key?(dependency["package"])
        end
        reject("xcode-package-product-linkage-invalid") unless framework_product_refs.uniq == framework_product_refs &&
          framework_product_refs.sort == product_dependencies.sort
        @target_source_resolution_complete = true
      rescue InvalidInput
        @source_problems << "target-source-resolution-required"
      end

      def validate_scheme(module_name, target_id)
        path = "#{module_name}.xcodeproj/xcshareddata/xcschemes/#{module_name}.xcscheme"
        bytes = source(path)
        unless bytes
          reject(@sources.error(path) == "sensitive-source" ? "xcode-scheme-runtime-input-unsupported" : "xcode-scheme-unavailable")
        end
        reject("xcode-scheme-invalid") if bytes.match?(/<!DOCTYPE|<!ENTITY/i)
        document = REXML::Document.new(bytes)
        root = document.root
        reject("xcode-scheme-invalid") unless root&.name == "Scheme"
        elements = Hash.new { |hash, key| hash[key] = [] }
        pending = [[root, 0]]
        node_count = 0
        attribute_count = 0
        until pending.empty?
          node, depth = pending.pop
          node_count += 1
          reject("xcode-scheme-invalid") if depth > 100 || node_count > 100_000
          if node.is_a?(REXML::Element)
            elements[node.name] << node
            node.attributes.each_attribute do |attribute|
              attribute_count += 1
              reject("xcode-scheme-invalid") if attribute_count > 100_000 ||
                attribute.name.to_s.bytesize > 512 || attribute.value.to_s.bytesize > 65_536
            end
          end
          children = node.respond_to?(:children) ? node.children : []
          children.each { |child| pending << [child, depth + 1] }
        end

        runtime_inputs = elements["EnvironmentVariable"] + elements["CommandLineArgument"]
        unless runtime_inputs.empty?
          @sources.reject_sensitive(path)
          reject("xcode-scheme-runtime-input-unsupported")
        end
        execution_actions = elements["ExecutionAction"]
        unless execution_actions.empty?
          @sources.reject_sensitive(path)
          reject("xcode-scheme-script-action-unsupported")
        end

        direct = lambda do |node, name|
          node.children.select { |child| child.is_a?(REXML::Element) && child.name == name }
        end
        build_actions = direct.call(root, "BuildAction")
        reject("xcode-scheme-build-action-invalid") unless build_actions.length == 1
        entry_containers = direct.call(build_actions.first, "BuildActionEntries")
        reject("xcode-scheme-build-action-invalid") unless entry_containers.length == 1
        entries = direct.call(entry_containers.first, "BuildActionEntry")
        archive_entries = entries.select { |entry| entry.attributes["buildForArchiving"] == "YES" }
        reject("xcode-scheme-archive-target-ambiguous") unless archive_entries.length == 1
        references = direct.call(archive_entries.first, "BuildableReference")
        reject("xcode-scheme-archive-target-ambiguous") unless references.length == 1
        reference = references.first
        expected = {
          "BuildableIdentifier" => "primary",
          "BlueprintIdentifier" => target_id,
          "BuildableName" => "#{module_name}.app",
          "BlueprintName" => module_name,
          "ReferencedContainer" => "container:#{module_name}.xcodeproj"
        }
        reject("xcode-scheme-archive-target-mismatch") unless expected.all? { |key, value| reference.attributes[key] == value }

        archive_actions = direct.call(root, "ArchiveAction")
        reject("xcode-scheme-archive-configuration-invalid") unless archive_actions.length == 1 &&
          archive_actions.first.attributes["buildConfiguration"] == "Release"
      rescue REXML::ParseException
        reject("xcode-scheme-invalid")
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
        if @sources.sensitive_xcode_document?(project)
          @sources.reject_sensitive(path)
          reject("unsafe-xcode-project")
        end
        @objects = project["objects"]
        reject("xcode-project-invalid") unless @objects.is_a?(Hash)
        @project = @objects[project["rootObject"]]
        reject("xcode-project-invalid") unless @project.is_a?(Hash) && @project["isa"] == "PBXProject" && @project["targets"].is_a?(Array)
        target_ids = @project["targets"].select do |id|
          target = @objects[id]
          target.is_a?(Hash) && target["isa"] == "PBXNativeTarget" && target["productType"] == "com.apple.product-type.application" && target["name"] == module_name
        end
        reject("xcode-app-target-ambiguous") unless target_ids.length == 1
        target = @objects.fetch(target_ids.first)
        target_sources(target)
        validate_scheme(module_name, target_ids.first)
        project_configs = configurations(@project["buildConfigurationList"])
        target_configs = configurations(target["buildConfigurationList"])
        reject("xcode-project-configuration-mismatch") unless project_configs.map { |config| config["name"] }.sort == target_configs.map { |config| config["name"] }.sort
        target_configs.each do |target_config|
          project_config = project_configs.find { |config| config["name"] == target_config["name"] }
          actual = merge_settings(settings(project_config), settings(target_config)).merge("TARGET_NAME" => target["name"])
          if actual.keys.any? { |key| key.include?("[") || key.include?("]") }
            reject("xcode-conditional-settings-unresolved")
          end
          reject("xcode-build-input-setting-unresolved") if UNRESOLVED_INPUT_SETTINGS.any? { |key| nonempty_setting?(actual, key) }
          FILE_INPUT_SETTINGS.each do |key|
            path = source_path_setting(actual, key)
            @build_files << path if path
          end
          compare("identity.bundleId", resolved(actual, "PRODUCT_BUNDLE_IDENTIFIER"), @values.call(IDENTITY, "bundleId"))
          compare("identity.module", resolved(actual, "PRODUCT_MODULE_NAME") || resolved(actual, "PRODUCT_NAME"), module_name)
          compare("identity.displayName", resolved(actual, "INFOPLIST_KEY_CFBundleDisplayName"), @values.call(IDENTITY, "displayName"))
          compare("version", resolved(actual, "MARKETING_VERSION"), @values.call(APP, "version"))
          compare("build", resolved(actual, "CURRENT_PROJECT_VERSION"), @values.call(VALUES, "build"))
          generated_info = resolved(actual, "GENERATE_INFOPLIST_FILE") == "YES"
          info_path = source_path_setting(actual, "INFOPLIST_FILE")
          reject("xcode-infoplist-unresolved") unless generated_info && info_path.nil? || !generated_info && info_path
          @build_files << info_path if info_path
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
        @source_problems << "target-build-settings-resolution-required" if @target_source_resolution_complete
        FIELDS.each { |field| @errors[field] << error.message }
        result
      rescue JSON::ParserError, TypeError, NoMethodError, SystemCallError
        @source_problems << "target-build-settings-resolution-required" if @target_source_resolution_complete
        FIELDS.each { |field| @errors[field] << "xcode-project-invalid" }
        result
      end

      def result
        source_problems = @source_problems.dup
        source_problems << "target-source-resolution-required" unless @target_source_resolution_complete
        {"fields" => @errors.transform_values(&:uniq), "sources" => @paths.map { |path| @sources.descriptor(path, "build-settings") },
         "sourceRoots" => @source_roots.uniq, "sourceFiles" => @source_files.uniq, "buildFiles" => @build_files.uniq,
         "sourceProblems" => source_problems.uniq, "requiresPackageResolution" => !@remote_packages.empty?,
         "remotePackages" => @remote_packages.uniq}
      end
    end
  end
end
