#!/bin/bash
set -euo pipefail
source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby git /usr/bin/plutil shasum

# #476: tools/apply-development-bundle-id.sh gives an existing app's Debug build `<Bundle ID>.dev` and
# `<display name> Dev`, leaves Release byte for byte, changes nothing on a second run, and stops before any
# change when the app shares data or identity through its Bundle ID.

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
tool="$repo_root/tools/apply-development-bundle-id.sh"
fixture="$repo_root/tools/tests/fixtures/development-bundle-id"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-development-bundle.XXXXXX")
workspace=$(cd "$workspace" && pwd -P)
trap 'rm -rf -- "$workspace"' EXIT

fail() { echo "test-apply-development-bundle-id: $*" >&2; exit 1; }

new_app() {
  app="$workspace/$1"
  mkdir -p "$app"
  cp -R "$fixture/Config" "$fixture/SampleNotes.xcodeproj" "$app/"
  pbx="$app/SampleNotes.xcodeproj/project.pbxproj"
}

# Prints one build configuration block of the application target, located by its exact object comment.
configuration() {
  ruby -e '
    content = File.binread(ARGV[0])
    blocks = content.scan(/^\t\t[0-9A-F]{24} \/\* #{ARGV[1]} \*\/ = \{\n\t\t\tisa = XCBuildConfiguration;\n.*?^\t\t\};\n/m)
    app = blocks.select { |block| block.match?(/PRODUCT_BUNDLE_IDENTIFIER = com\.example\.SampleNotes(\.dev)?;/) }
    abort "expected one App #{ARGV[1]} configuration, found #{app.length}" unless app.length == 1
    print app.first
  ' "$1" "$2"
}

# Edits the project with a Ruby expression on `content`; aborts unless the expression changed it.
edit_project() {
  ruby -e '
    path = ARGV[0]
    content = File.binread(path)
    updated = eval(ARGV[1])
    abort "fixture edit did not change the project" if updated == content
    File.binwrite(path, updated)
  ' "$pbx" "$1"
}

expect_refusal() {
  local label=$1 status=$2 message=$3 before
  before=$(shasum -a 256 "$pbx")
  set +e
  "$tool" --root "$app" >"$workspace/out" 2>"$workspace/err"
  local actual=$?
  set -e
  [[ $actual == "$status" ]] || fail "$label: expected exit $status, got $actual: $(<"$workspace/err")"
  grep -Fq -- "$message" "$workspace/err" || fail "$label: missing message '$message': $(<"$workspace/err")"
  [[ ! -s "$workspace/out" ]] || fail "$label: printed a result"
  [[ "$before" == "$(shasum -a 256 "$pbx")" ]] || fail "$label: changed the project"
  if find "$app" -name '*.apply-development-bundle-id.*' | grep -q .; then fail "$label: left a temporary file"; fi
}

# Applies to the fixture and checks Debug, Release, and the rest of the project.
new_app applied
original="$workspace/original.pbxproj"
cp "$pbx" "$original"
"$tool" --root "$app" >"$workspace/out"
grep -Fq '"status":"applied"' "$workspace/out" || fail "first run did not apply: $(<"$workspace/out")"
debug=$(configuration "$pbx" Debug)
grep -Fqx $'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes.dev;' <<<"$debug" || fail 'Debug Bundle ID is not .dev'
grep -Fqx $'\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "Sample Notes Dev";' <<<"$debug" || fail 'Debug display name is not Dev'
[[ "$(configuration "$pbx" Release)" == "$(configuration "$original" Release)" ]] || fail 'Release configuration changed'
ruby -e '
  before, after = ARGV.map { |path| File.binread(path).lines }
  changed = before.each_index.reject { |index| before[index] == after[index] }
  abort "unexpected line count change" unless before.length == after.length
  expected = ["\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n", "\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = \"Sample Notes\";\n"]
  abort "changed lines differ: #{changed.map { |index| before[index] }}" unless changed.length == 2 && changed.map { |index| before[index] }.sort == expected.sort
' "$original" "$pbx" || fail 'the tool changed more than the two Debug lines'
[[ "$(stat -f '%Lp' "$pbx")" == "$(stat -f '%Lp' "$original")" ]] || fail 'project mode changed'

# A second run changes nothing.
applied_digest=$(shasum -a 256 <"$pbx")
"$tool" --root "$app" >"$workspace/out"
grep -Fq '"status":"already-applied"' "$workspace/out" || fail "second run was not idempotent: $(<"$workspace/out")"
[[ "$applied_digest" == "$(shasum -a 256 <"$pbx")" ]] || fail 'second run changed the project'

# Run from inside the app repository without --root.
new_app from-inside
git -C "$app" init -q
(cd "$app" && "$tool" >"$workspace/out")
grep -Fq '"status":"applied"' "$workspace/out" || fail 'run inside the repository did not apply'

# A Debug configuration without a display name gets one, in the order Xcode writes build settings.
new_app no-display
edit_project 'content.sub(/(PRODUCT_BUNDLE_IDENTIFIER = com\.example\.SampleNotes;\n)\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "Sample Notes";\n/, "\\1")'
release_before=$(configuration "$pbx" Release)
"$tool" --root "$app" >/dev/null
debug=$(configuration "$pbx" Debug)
ruby -e '
  lines = ARGV[0].lines
  index = lines.index("\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = \"Sample Notes Dev\";\n")
  abort "display name was not inserted" unless index
  abort "display name is out of order" unless lines[index - 1].include?("GENERATE_INFOPLIST_FILE") && lines[index + 1].include?("INFOPLIST_KEY_UIApplicationSceneManifest_Generation")
' "$debug" || fail 'inserted display name'
[[ "$release_before" == "$(configuration "$pbx" Release)" ]] || fail 'Release changed while inserting the display name'

# A display name with quotes and backslashes is written as a valid project string.
new_app quoted
ruby -rjson -e 'path = ARGV[0]; value = JSON.parse(File.read(path)); value["displayName"] = "Sample \"Notes\" \\ Draft"; File.write(path, JSON.pretty_generate(value) + "\n")' "$app/Config/app-identity.json"
edit_project 'content.gsub(%q{INFOPLIST_KEY_CFBundleDisplayName = "Sample Notes";}) { %q{INFOPLIST_KEY_CFBundleDisplayName = "Sample \"Notes\" \\\\ Draft";} }'
"$tool" --root "$app" >/dev/null
grep -Fq 'INFOPLIST_KEY_CFBundleDisplayName = "Sample \"Notes\" \\ Draft Dev";' "$pbx" || fail 'quoted display name'
"$tool" --root "$app" | grep -Fq '"status":"already-applied"' || fail 'quoted display name is not idempotent'

# Entitlements that do not share anything through the Bundle ID are allowed.
new_app push
mkdir -p "$app/SampleNotes"
cp "$fixture/entitlements/push.entitlements" "$app/SampleNotes/SampleNotes.entitlements"
edit_project 'content.gsub("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n", "\t\t\t\tCODE_SIGN_ENTITLEMENTS = SampleNotes/SampleNotes.entitlements;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n")'
"$tool" --root "$app" | grep -Fq '"status":"applied"' || fail 'push entitlements were refused'

# iCloud, App Groups, and shared Keychain groups stop before any change, for any target of the project.
for case in icloud:com.apple.developer.icloud-container-identifiers app-groups:com.apple.security.application-groups keychain:keychain-access-groups; do
  name=${case%%:*}
  key=${case#*:}
  new_app "shared-$name"
  mkdir -p "$app/SampleNotes"
  cp "$fixture/entitlements/$name.entitlements" "$app/SampleNotes/SampleNotes.entitlements"
  edit_project 'content.sub("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n", "\t\t\t\tCODE_SIGN_ENTITLEMENTS = \"$(SRCROOT)/SampleNotes/SampleNotes.entitlements\";\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n")'
  expect_refusal "$name entitlements" 3 "SampleNotes/SampleNotes.entitlements: $key"
done
new_app shared-release-only
mkdir -p "$app/SampleNotes"
cp "$fixture/entitlements/icloud.entitlements" "$app/SampleNotes/Release.entitlements"
edit_project 'content.sub(/(PRODUCT_BUNDLE_IDENTIFIER = com\.example\.SampleNotes;\n.*?PRODUCT_BUNDLE_IDENTIFIER = com\.example\.SampleNotes;\n)/m) { $1.sub(/PRODUCT_BUNDLE_IDENTIFIER = com\.example\.SampleNotes;\n\z/, "CODE_SIGN_ENTITLEMENTS = SampleNotes/Release.entitlements;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n") }'
expect_refusal 'iCloud entitlements on Release only' 3 'com.apple.developer.icloud-services'
new_app missing-entitlements
edit_project 'content.sub("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n", "\t\t\t\tCODE_SIGN_ENTITLEMENTS = SampleNotes/Missing.entitlements;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n")'
expect_refusal 'missing entitlements file' 1 'SampleNotes/Missing.entitlements is missing'

# Entitlements set through a configuration file, directly or through an include, are checked the same way.
new_app xcconfig-shared
mkdir -p "$app/SampleNotes"
cp "$fixture/entitlements/icloud.entitlements" "$app/SampleNotes/SampleNotes.entitlements"
printf '%s\n' 'CODE_SIGN_ENTITLEMENTS = $(SRCROOT)/SampleNotes/SampleNotes.entitlements // shared' >"$app/Config/Local.xcconfig"
expect_refusal 'iCloud entitlements from an included xcconfig' 3 'SampleNotes/SampleNotes.entitlements: com.apple.developer.icloud-container-identifiers'
new_app xcconfig-direct
mkdir -p "$app/SampleNotes"
cp "$fixture/entitlements/app-groups.entitlements" "$app/SampleNotes/SampleNotes.entitlements"
printf '%s\n' 'CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*] = SampleNotes/SampleNotes.entitlements' >"$app/Config/Public.xcconfig"
expect_refusal 'App Group entitlements from the base xcconfig' 3 'SampleNotes/SampleNotes.entitlements: com.apple.security.application-groups'
new_app xcconfig-push
mkdir -p "$app/SampleNotes"
cp "$fixture/entitlements/push.entitlements" "$app/SampleNotes/SampleNotes.entitlements"
printf '%s\n' 'CODE_SIGN_ENTITLEMENTS = SampleNotes/SampleNotes.entitlements' >"$app/Config/Local.xcconfig"
"$tool" --root "$app" | grep -Fq '"status":"applied"' || fail 'push entitlements from an xcconfig were refused'
new_app xcconfig-variable
printf '%s\n' 'CODE_SIGN_ENTITLEMENTS = $(TARGET_NAME)/App.entitlements' >"$app/Config/Local.xcconfig"
expect_refusal 'entitlements path with a build setting in an xcconfig' 1 'uses a build setting; check it by hand'
new_app xcconfig-missing-include
printf '%s\n' '#include "Shared.xcconfig"' >"$app/Config/Public.xcconfig"
expect_refusal 'missing required include' 1 'Config/Public.xcconfig includes Config/Shared.xcconfig, which is missing'
new_app xcconfig-outside
printf '%s\n' '#include "../../outside.xcconfig"' >"$app/Config/Public.xcconfig"
expect_refusal 'include outside the repository' 1 'includes a file outside the app repository'
new_app xcconfig-unreadable-reference
rm "$app/Config/Public.xcconfig"
expect_refusal 'project configuration file missing' 1 'the project uses the configuration file Public.xcconfig'
new_app xcconfig-multi-condition
mkdir -p "$app/SampleNotes"
cp "$fixture/entitlements/icloud.entitlements" "$app/SampleNotes/Shared.entitlements"
printf '%s\n' 'CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*][arch=arm64] = SampleNotes/Shared.entitlements' >"$app/Config/Local.xcconfig"
expect_refusal 'entitlements with several conditions in an xcconfig' 3 'SampleNotes/Shared.entitlements: com.apple.developer.icloud-container-identifiers'
new_app project-multi-condition
mkdir -p "$app/SampleNotes"
cp "$fixture/entitlements/app-groups.entitlements" "$app/SampleNotes/Shared.entitlements"
edit_project 'content.sub("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n", "\t\t\t\t\"CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*][arch=arm64]\" = SampleNotes/Shared.entitlements;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n")'
expect_refusal 'entitlements with several conditions in the project' 3 'SampleNotes/Shared.entitlements: com.apple.security.application-groups'
new_app xcconfig-unreadable-setting
printf '%s\n' 'CODE_SIGN_ENTITLEMENTS [sdk=iphoneos*] = SampleNotes/Shared.entitlements' >"$app/Config/Local.xcconfig"
expect_refusal 'entitlements setting the tool cannot read' 1 'Config/Local.xcconfig sets CODE_SIGN_ENTITLEMENTS in a form the tool cannot read'

# An embedded target whose Bundle ID starts with the app's stops as well.
new_app embedded
edit_project 'content.gsub("PRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotesUITests;", "PRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes.Widget;")'
expect_refusal 'embedded target' 3 'embedded target com.example.SampleNotes.Widget'
new_app development-id-taken
edit_project 'content.gsub("PRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotesUITests;", "PRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes.dev;")'
expect_refusal 'another target already uses the development Bundle ID' 3 'another target com.example.SampleNotes.dev'
new_app development-id-taken-xcconfig
printf '%s\n' 'PRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes.dev' >"$app/Config/Local.xcconfig"
expect_refusal 'development Bundle ID taken in an xcconfig' 3 'another target com.example.SampleNotes.dev'
new_app embedded-xcconfig
printf '%s\n' 'PRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes.Widget' >"$app/Config/Local.xcconfig"
expect_refusal 'embedded target from an xcconfig' 3 'embedded target com.example.SampleNotes.Widget'
new_app embedded-xcconfig-variable
printf '%s\n' 'PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_ID).Widget' >"$app/Config/Local.xcconfig"
expect_refusal 'embedded target Bundle ID from a build setting' 1 'with a build setting; check embedded targets by hand'
new_app embedded-project-variable
edit_project 'content.gsub("PRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotesUITests;", "PRODUCT_BUNDLE_IDENTIFIER = \"$(APP_BUNDLE_ID).Widget\";")'
expect_refusal 'embedded target Bundle ID from a build setting in the project' 1 'with a build setting; check embedded targets by hand'

# Project shapes the tool cannot change safely stop without writing.
new_app release-differs
edit_project 'content.sub(/(PRODUCT_BUNDLE_IDENTIFIER = com\.example\.SampleNotes;\n.*?)PRODUCT_BUNDLE_IDENTIFIER = com\.example\.SampleNotes;\n/m, "\\1PRODUCT_BUNDLE_IDENTIFIER = com.example.Other;\n")'
expect_refusal 'Release Bundle ID differs from the Identity' 1 'the Release Bundle ID is not com.example.SampleNotes'
new_app debug-differs
edit_project 'content.sub("PRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;", "PRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes.beta;")'
expect_refusal 'unexpected Debug Bundle ID' 1 'the Debug Bundle ID is com.example.SampleNotes.beta'
new_app debug-name-differs
edit_project 'content.sub(%q{INFOPLIST_KEY_CFBundleDisplayName = "Sample Notes";}, %q{INFOPLIST_KEY_CFBundleDisplayName = "Notes Beta";})'
expect_refusal 'unexpected Debug display name' 1 'the Debug display name is "Notes Beta"'
new_app conditional
edit_project 'content.sub("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n", "\t\t\t\t\"PRODUCT_BUNDLE_IDENTIFIER[sdk=iphoneos*]\" = com.example.SampleNotes;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.SampleNotes;\n")'
expect_refusal 'conditional Bundle ID' 1 'sets PRODUCT_BUNDLE_IDENTIFIER for only some SDKs'
new_app info-plist
mkdir -p "$app/SampleNotes"
/usr/bin/plutil -create xml1 "$app/SampleNotes/Info.plist"
/usr/bin/plutil -insert CFBundleDisplayName -string 'Sample Notes' "$app/SampleNotes/Info.plist"
edit_project 'content.sub("\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n", "\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n\t\t\t\tINFOPLIST_FILE = SampleNotes/Info.plist;\n")'
expect_refusal 'Info.plist display name' 1 'SampleNotes/Info.plist sets CFBundleDisplayName itself'
new_app no-identity
rm "$app/Config/app-identity.json"
expect_refusal 'missing Identity' 1 'Config/app-identity.json is missing'
new_app symlinked-project
mv "$pbx" "$workspace/real.pbxproj"
ln -s "$workspace/real.pbxproj" "$pbx"
set +e
"$tool" --root "$app" >/dev/null 2>"$workspace/err"
status=$?
set -e
[[ $status == 1 ]] && grep -Fq 'must not pass through a symbolic link' "$workspace/err" || fail 'symbolic-link project was not refused'

set +e
"$tool" --unknown >/dev/null 2>&1
status=$?
set -e
[[ $status == 2 ]] || fail 'unknown option did not exit 2'

echo 'apply-development-bundle-id tests passed'
