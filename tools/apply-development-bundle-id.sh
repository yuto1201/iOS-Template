#!/bin/bash -p
set -euo pipefail

# #476: gives an existing app's Debug build its own identity, so a build from Xcode installs beside the
# App Store app on the same iPhone instead of replacing it (and its data).
#
#   Debug:   PRODUCT_BUNDLE_IDENTIFIER = <Bundle ID>.dev; INFOPLIST_KEY_CFBundleDisplayName = "<display name> Dev";
#   Release: unchanged, byte for byte.
#
# It reads the app's Identity from Config/app-identity.json and edits only the Debug build configuration of
# the application target in <module>.xcodeproj/project.pbxproj. Running it again changes nothing.
#
# Before any change it stops (exit 3) when the app shares data or identity through its Bundle ID, because a
# development build needs a separate decision there:
#   - entitlements with iCloud (CloudKit, iCloud Drive, key-value storage), App Groups, or shared Keychain groups,
#     whether the project sets CODE_SIGN_ENTITLEMENTS or a configuration file (.xcconfig) it uses does;
#   - an embedded target (a Widget or other extension) whose Bundle ID starts with the app's Bundle ID, set in
#     the project or in a configuration file.
# Any other project shape it cannot read safely stops with exit 1. Nothing is written in either case.

usage() {
  echo 'usage: apply-development-bundle-id.sh [--root APP_REPOSITORY]' >&2
  exit 2
}

root=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) [[ $# -ge 2 && -z "$root" ]] || usage; root=$2; shift 2 ;;
    *) usage ;;
  esac
done
if [[ -z "$root" ]]; then
  root="$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null)" || {
    echo 'apply-development-bundle-id: run it inside the app repository, or pass --root' >&2
    exit 1
  }
fi
[[ -d "$root" && ! -L "$root" ]] || { echo 'apply-development-bundle-id: the app repository is not a directory' >&2; exit 1; }
root="$(builtin cd "$root" && /bin/pwd -P)"

exec /usr/bin/ruby --disable-gems -E UTF-8:UTF-8 -e '# encoding: utf-8
require "json"
require "open3"

ROOT = ARGV.fetch(0)
DEVELOPMENT_BUNDLE_SUFFIX = ".dev"
DEVELOPMENT_NAME_SUFFIX = " Dev"
SHARED_ENTITLEMENTS = {
  "com.apple.developer.icloud-container-identifiers" => "iCloud（CloudKit）のcontainer",
  "com.apple.developer.icloud-services" => "iCloudのservice",
  "com.apple.developer.icloud-container-environment" => "iCloudのcontainerの環境",
  "com.apple.developer.ubiquity-container-identifiers" => "iCloud Driveのcontainer",
  "com.apple.developer.ubiquity-kvstore-identifier" => "iCloudのkey-value storage",
  "com.apple.security.application-groups" => "App Group",
  "keychain-access-groups" => "共有のKeychain"
}.freeze

def refuse(message, status = 1)
  warn "apply-development-bundle-id: #{message}"
  exit status
end

def regular_file!(relative)
  path = File.join(ROOT, relative)
  refuse("#{relative} must be a regular file inside the app repository") if relative.start_with?("/") || relative.split("/").include?("..")
  parent = ROOT
  relative.split("/").each do |component|
    parent = File.join(parent, component)
    refuse("#{relative} must not pass through a symbolic link") if File.symlink?(parent)
  end
  refuse("#{relative} is missing") unless File.file?(path)
  path
end

def pbx_string(value)
  "\"#{value.gsub("\\") { "\\\\" }.gsub("\"") { "\\\"" }}\""
end

def pbx_value(raw)
  value = raw.strip
  return value unless value.start_with?("\"")
  refuse("a quoted build setting is malformed") unless value.end_with?("\"") && value.length >= 2
  value[1...-1].gsub(/\\(.)/) { Regexp.last_match(1) }
end

def plist(relative)
  output, error, status = Open3.capture3("/usr/bin/plutil", "-convert", "json", "-o", "-", "--", regular_file!(relative))
  refuse("#{relative} could not be read as a property list: #{error.strip}") unless status.success?
  value = JSON.parse(output)
  refuse("#{relative} is not a dictionary") unless value.is_a?(Hash)
  value
end

identity_path = regular_file!("Config/app-identity.json")
identity = JSON.parse(File.read(identity_path, encoding: "UTF-8")) rescue refuse("Config/app-identity.json is not JSON")
refuse("Config/app-identity.json is not an object") unless identity.is_a?(Hash)
display_name, module_name, bundle_id = identity.values_at("displayName", "moduleName", "bundleId")
refuse("Config/app-identity.json has no app Identity; run it in an app after Identity bootstrap") unless
  [display_name, module_name, bundle_id].all? { |value| value.is_a?(String) && !value.empty? }
refuse("the module name is invalid") unless module_name.match?(/\A[A-Za-z][A-Za-z0-9]{1,49}\z/)
refuse("the Bundle ID is invalid") unless bundle_id.match?(/\A[A-Za-z0-9][A-Za-z0-9-]{0,62}(?:\.[A-Za-z0-9][A-Za-z0-9-]{0,62})+\z/)
refuse("the Bundle ID already ends with .dev") if bundle_id.end_with?(DEVELOPMENT_BUNDLE_SUFFIX)
development_bundle_id = bundle_id + DEVELOPMENT_BUNDLE_SUFFIX
development_name = display_name + DEVELOPMENT_NAME_SUFFIX
refuse("the development Bundle ID would be longer than 255 characters") if development_bundle_id.length > 255

pbx_relative = "#{module_name}.xcodeproj/project.pbxproj"
pbx_path = regular_file!(pbx_relative)
content = File.binread(pbx_path).force_encoding(Encoding::UTF_8)
refuse("#{pbx_relative} is not UTF-8") unless content.valid_encoding?

object = "[0-9A-F]{24}"
blocks = {}
content.scan(/^\t\t(#{object}) \/\* [^\n]*? \*\/ = \{\n(.*?)^\t\t\};\n/m) do
  match = Regexp.last_match
  refuse("#{pbx_relative} has a duplicate object #{match[1]}") if blocks.key?(match[1])
  blocks[match[1]] = {text: match[0], offset: match.begin(0), body: match[2]}
end
application_targets = blocks.select do |_id, block|
  block[:body].start_with?("\t\t\tisa = PBXNativeTarget;\n") &&
    block[:body].include?("\n\t\t\tname = #{module_name};\n") &&
    block[:body].include?("\n\t\t\tproductType = \"com.apple.product-type.application\";\n")
end
refuse("#{pbx_relative} must have exactly one application target named #{module_name}") unless application_targets.length == 1
target = application_targets.values.first
list_ids = target[:body].scan(/^\t\t\tbuildConfigurationList = (#{object}) /).flatten
refuse("the application target has no single build configuration list") unless list_ids.length == 1 && blocks[list_ids.first]
list = blocks.fetch(list_ids.first)
refuse("the application build configuration list is malformed") unless list[:body].start_with?("\t\t\tisa = XCConfigurationList;\n")
configurations = list[:body][/^\t\t\tbuildConfigurations = \(\n(.*?)^\t\t\t\);\n/m, 1].to_s.scan(/^\t\t\t\t(#{object}) \/\* ([^\n]*?) \*\/,\n/)
names = configurations.map(&:last)
refuse("the application target must have exactly one Debug and one Release configuration") unless
  names.count("Debug") == 1 && names.count("Release") == 1
configuration = lambda do |name|
  id = configurations.find { |_id, config_name| config_name == name }.first
  block = blocks[id]
  refuse("the #{name} configuration is missing") unless block && block[:body].start_with?("\t\t\tisa = XCBuildConfiguration;\n") &&
                                                         block[:body].end_with?("\t\t\tname = #{name};\n")
  block
end
debug = configuration.call("Debug")
release = configuration.call("Release")

setting_lines = lambda do |block, key|
  block[:text].scan(/^\t\t\t\t#{Regexp.escape(key)} = ([^\n]*);\n/).flatten
end
conditional = lambda do |block, key|
  block[:text].match?(/^\t\t\t\t"?#{Regexp.escape(key)}\[/)
end
%w[PRODUCT_BUNDLE_IDENTIFIER INFOPLIST_KEY_CFBundleDisplayName].each do |key|
  [debug, release].each do |block|
    refuse("a configuration sets #{key} for only some SDKs or architectures; change it by hand") if conditional.call(block, key)
  end
end
release_bundles = setting_lines.call(release, "PRODUCT_BUNDLE_IDENTIFIER").map { |value| pbx_value(value) }
refuse("the Release Bundle ID is not #{bundle_id} from Config/app-identity.json") unless release_bundles == [bundle_id]

# Build settings can also come from configuration files (baseConfigurationReference) and their includes.
# Every .xcconfig in the repository is read, so an inherited CODE_SIGN_ENTITLEMENTS is checked too; a
# configuration file the tool cannot find or follow inside the repository stops before any change.
skipped_directories = %w[DerivedData build Pods Carthage].freeze
xcconfigs = []
pending = []
Dir.glob("**/*.xcconfig", base: ROOT).sort.each do |relative|
  components = relative.split("/")
  next if components[0...-1].any? { |name| name.start_with?(".") || skipped_directories.include?(name) }
  pending << relative
end
until pending.empty?
  relative = pending.shift
  next if xcconfigs.include?(relative)
  path = regular_file!(relative)
  xcconfigs << relative
  File.read(path, encoding: "UTF-8").each_line do |line|
    directive = line.match(/\A\s*#include(\?)?\s*(.*?)\s*\z/)
    next unless directive
    target = directive[2][/\A"([^"]+)"\z/, 1]
    refuse("#{relative} has an include the tool cannot follow; check its entitlements by hand") unless target && !target.start_with?("/")
    resolved = File.expand_path(target, File.join(ROOT, File.dirname(relative)))
    refuse("#{relative} includes a file outside the app repository; check its entitlements by hand") unless resolved.start_with?("#{ROOT}/")
    included = resolved.delete_prefix("#{ROOT}/")
    if File.exist?(resolved) || File.symlink?(resolved)
      pending << included
    elsif directive[1].nil?
      refuse("#{relative} includes #{included}, which is missing")
    end
  end
end
content.scan(/^\t\t#{object} \/\* [^\n]*? \*\/ = \{isa = PBXFileReference;[^\n]*\};\n/).each do |reference|
  path = reference[/ path = ("(?:[^"\\]|\\.)*"|[^;]+);/, 1]
  next unless path && pbx_value(path).end_with?(".xcconfig")
  path = pbx_value(path)
  tree = reference[/ sourceTree = ("[^"]*"|[^;]+);/, 1].to_s.delete("\"")
  unless %w[<group> SOURCE_ROOT].include?(tree) && !path.start_with?("/") && !path.split("/").include?("..") &&
         xcconfigs.any? { |relative| relative == path || relative.end_with?("/#{path}") }
    refuse("the project uses the configuration file #{path}, which the tool cannot find inside the app repository; check its entitlements by hand")
  end
end
# Reads one setting from every configuration file, with any number of conditions ([sdk=...][arch=...]).
# A line that names the setting in a form the tool cannot read stops before any change.
xcconfig_values = lambda do |key|
  xcconfigs.flat_map do |relative|
    File.read(File.join(ROOT, relative), encoding: "UTF-8").each_line.map do |line|
      setting_line = line.sub(%r{\s*//.*\z}m, "")
      next unless setting_line.match?(/\A\s*"?#{key}\b/)
      setting = setting_line.match(/\A\s*#{key}(?:\[[^\]\n]*\])*\s*=\s*(.*?)\s*;?\s*\z/)
      refuse("#{relative} sets #{key} in a form the tool cannot read; check it by hand") unless setting
      setting[1].delete_prefix("\"").delete_suffix("\"")
    end.compact
  end
end
xcconfig_entitlements = xcconfig_values.call("CODE_SIGN_ENTITLEMENTS")

# Entitlements of every target in the project: a development Bundle ID changes what they share.
project_values = lambda do |text, key|
  values = text.scan(/^\t\t\t\t"?#{key}(?:\[[^\]\n]*\])*"? = ([^\n]*);\n/).flatten
  # Every assignment counts, also one that shares a line with another setting.
  unless values.length == text.scan(/(?<![\w$(])"?#{key}(?:\[[^\]\n]*\])*"?\s*=/).length
    refuse("the project sets #{key} in a form the tool cannot read; check it by hand")
  end
  values.map { |raw| pbx_value(raw) }
end
entitlement_paths = (project_values.call(content, "CODE_SIGN_ENTITLEMENTS") + xcconfig_entitlements)
  .map { |value| value.sub(%r{\A\$[({](?:SRCROOT|PROJECT_DIR)[)}]/}, "") }.uniq.sort
shared = entitlement_paths.flat_map do |relative|
  refuse("the entitlements path #{relative} uses a build setting; check it by hand") if relative.include?("$")
  values = plist(relative)
  SHARED_ENTITLEMENTS.keys.select { |key| values.key?(key) }.map { |key| [relative, key] }
end
other_targets = content.sub(debug[:text], "").sub(release[:text], "")
# Bundle IDs of the other targets, set in the project or in a configuration file. One built from a build
# setting may start with the Bundle ID of the app without showing it, so it stops before any change.
embedded = project_values.call(other_targets, "PRODUCT_BUNDLE_IDENTIFIER") + xcconfig_values.call("PRODUCT_BUNDLE_IDENTIFIER")
embedded.each do |value|
  refuse("a target sets PRODUCT_BUNDLE_IDENTIFIER = #{value} with a build setting; check embedded targets by hand") if value.include?("$")
end
# Another target that already uses the development Bundle ID would collide with the Debug app, so it stops too.
embedded = embedded.select { |value| value.start_with?("#{bundle_id}.") }.uniq.sort
unless shared.empty? && embedded.empty?
  lines = ["the app shares data or identity through its Bundle ID, so nothing was changed. Decide in a separate Issue how the development build handles:"]
  shared.each { |relative, key| lines << "  - #{relative}: #{key} (#{SHARED_ENTITLEMENTS.fetch(key)}). 開発版が本番と同じものを使うか、開発用を別に用意するか。" }
  embedded.each do |value|
    if value == development_bundle_id
      lines << "  - another target #{value}: 開発版のアプリと同じBundle IDを、別のtargetがすでに使っている。開発版でのBundle IDをどうするか。"
    else
      lines << "  - embedded target #{value}: 埋め込むtarget（Widgetなど）のBundle IDは親のBundle IDで始まる必要がある。開発版でのBundle IDをどうするか。"
    end
  end
  refuse(lines.join("\n"), 3)
end

# The Debug Info.plist must come from the build settings this tool changes.
generated = setting_lines.call(debug, "GENERATE_INFOPLIST_FILE").map { |value| pbx_value(value) }
refuse("the Debug configuration does not generate its Info.plist; change it by hand") unless generated == ["YES"]
info_files = setting_lines.call(debug, "INFOPLIST_FILE").map { |value| pbx_value(value).sub(%r{\A\$[({](?:SRCROOT|PROJECT_DIR)[)}]/}, "") }
refuse("the Debug configuration has more than one INFOPLIST_FILE") if info_files.length > 1
info_files.each do |relative|
  refuse("the Debug INFOPLIST_FILE uses a build setting; check it by hand") if relative.include?("$")
  info = plist(relative)
  refuse("#{relative} sets CFBundleDisplayName itself; change it by hand") if info.key?("CFBundleDisplayName")
  if info.key?("CFBundleIdentifier") && info["CFBundleIdentifier"] != "$(PRODUCT_BUNDLE_IDENTIFIER)"
    refuse("#{relative} sets CFBundleIdentifier itself; change it by hand")
  end
end

text = debug[:text].dup
bundles = setting_lines.call(debug, "PRODUCT_BUNDLE_IDENTIFIER")
refuse("the Debug configuration must set PRODUCT_BUNDLE_IDENTIFIER exactly once") unless bundles.length == 1
case pbx_value(bundles.first)
when development_bundle_id then nil
when bundle_id
  text = text.sub("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = #{bundles.first};\n") do
    "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = #{development_bundle_id};\n"
  end
else
  refuse("the Debug Bundle ID is #{pbx_value(bundles.first)}, neither #{bundle_id} nor #{development_bundle_id}; change it by hand")
end
names = setting_lines.call(debug, "INFOPLIST_KEY_CFBundleDisplayName")
refuse("the Debug configuration sets the display name more than once") if names.length > 1
development_line = "\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = #{pbx_string(development_name)};\n"
if names.empty?
  # Keep the build settings in the order Xcode writes them.
  lines = text.lines
  start = lines.index("\t\t\tbuildSettings = {\n")
  finish = lines.index("\t\t\t};\n")
  refuse("the Debug build settings are malformed") unless start && finish && start < finish
  insert_at = (start + 1...finish).find do |index|
    key = lines[index][/\A\t\t\t\t"?([A-Za-z0-9_]+)/, 1]
    key && key > "INFOPLIST_KEY_CFBundleDisplayName"
  end || finish
  lines.insert(insert_at, development_line)
  text = lines.join
else
  case pbx_value(names.first)
  when development_name then nil
  when display_name
    text = text.sub("\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = #{names.first};\n") { development_line }
  else
    refuse("the Debug display name is #{pbx_value(names.first).inspect}, neither #{display_name.inspect} nor #{development_name.inspect}; change it by hand")
  end
end

if text == debug[:text]
  puts JSON.generate("status" => "already-applied", "project" => pbx_relative,
                     "debug" => {"bundleId" => development_bundle_id, "displayName" => development_name},
                     "release" => {"bundleId" => bundle_id, "changed" => false})
  exit 0
end
updated = content[0...debug[:offset]] + text + content[(debug[:offset] + debug[:text].length)..]
release_offset = updated.index(release[:text])
refuse("the Release configuration would change") unless release_offset && updated.scan(release[:text]).length == 1
temporary = "#{pbx_path}.apply-development-bundle-id.#{Process.pid}"
begin
  File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, File.stat(pbx_path).mode & 0o7777) { |file| file.write(updated) }
  File.rename(temporary, pbx_path)
ensure
  File.unlink(temporary) if File.exist?(temporary)
end
puts JSON.generate("status" => "applied", "project" => pbx_relative,
                   "debug" => {"bundleId" => development_bundle_id, "displayName" => development_name},
                   "release" => {"bundleId" => bundle_id, "changed" => false})
' "$root"
