#!/bin/bash
set -euo pipefail
source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" xcodebuild /usr/bin/plutil ruby

# #512 (D-100): the Release build keeps the production identity. The Release build settings and the
# Info.plist of a Release app built from them both carry the production Bundle ID and the production name,
# never a "Dev" name. In the template (no Config/app-identity.json yet) the Debug build settings must also
# carry <Bundle ID>.dev and "<name> Dev". The Identity comes from Config/app-identity.json in an app and
# from Config/template-identity.json in the template. The app is built for the Simulator SDK without a
# device and without signing, in a scratch DerivedData that is removed afterwards.

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-release-identity.XXXXXX")
workspace=$(cd "$workspace" && pwd -P)
trap 'rm -rf -- "$workspace"' EXIT

fail() { echo "test-template-release-identity: $*" >&2; exit 1; }

# Prints the module, the Bundle ID, the display name and whether this is the template, one per line.
identity=$(ruby -E UTF-8:UTF-8 -rjson -e '
  root = ARGV[0]
  app = File.join(root, "Config/app-identity.json")
  if File.file?(app)
    data = JSON.parse(File.read(app))
    puts data.fetch("moduleName"), data.fetch("bundleId"), data.fetch("displayName"), "app"
  else
    source = JSON.parse(File.read(File.join(root, "Config/template-identity.json"))).fetch("source")
    puts source.fetch("module"), source.fetch("bundleId"), source.fetch("module"), "template"
  end
' "$repo_root") || fail "the Identity could not be read"
{ read -r module; read -r bundle_id; read -r display_name; read -r kind; } <<<"$identity"
project="$repo_root/$module.xcodeproj"
[[ -d "$project" ]] || fail "$module.xcodeproj is missing"

# Prints one build setting of the app target for a configuration.
setting() {
  local configuration=$1 key=$2
  xcodebuild -project "$project" -target "$module" -configuration "$configuration" \
    -showBuildSettings 2>/dev/null | /usr/bin/awk -v key="$key" '$1 == key && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }'
}

[[ "$(setting Release PRODUCT_BUNDLE_IDENTIFIER)" == "$bundle_id" ]] ||
  fail "the Release build setting PRODUCT_BUNDLE_IDENTIFIER is not $bundle_id"
release_name=$(setting Release INFOPLIST_KEY_CFBundleDisplayName)
[[ -z "$release_name" || "$release_name" == "$display_name" ]] ||
  fail "the Release build setting INFOPLIST_KEY_CFBundleDisplayName is $release_name, not $display_name"
if [[ "$kind" == template ]]; then
  [[ "$(setting Debug PRODUCT_BUNDLE_IDENTIFIER)" == "$bundle_id.dev" ]] ||
    fail "the Debug build setting PRODUCT_BUNDLE_IDENTIFIER is not $bundle_id.dev"
  [[ "$(setting Debug INFOPLIST_KEY_CFBundleDisplayName)" == "$display_name Dev" ]] ||
    fail "the Debug build setting INFOPLIST_KEY_CFBundleDisplayName is not \"$display_name Dev\""
fi

products="$workspace/Products"
if ! "$repo_root/tools/xcodebuild-in-worktree.sh" --scratch -project "$project" \
  -scheme "$module" -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CONFIGURATION_BUILD_DIR="$products" build >"$workspace/build.log" 2>&1; then
  tail -40 "$workspace/build.log" >&2
  fail "the Release build failed"
fi
info="$products/$module.app/Info.plist"
[[ -f "$info" ]] || fail "the Release build did not produce $module.app/Info.plist"
identifier=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info") || fail "the built Info.plist has no CFBundleIdentifier"
[[ "$identifier" == "$bundle_id" ]] || fail "the built Release app's CFBundleIdentifier is $identifier, not $bundle_id"
name=$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$info" 2>/dev/null) ||
  name=$(/usr/bin/plutil -extract CFBundleName raw -o - "$info") || fail "the built Info.plist has no name"
[[ "$name" == "$display_name" ]] || fail "the built Release app is named $name, not $display_name"

echo 'template Release identity tests passed'
