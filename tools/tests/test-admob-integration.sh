#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg ruby git shasum xcrun /usr/libexec/PlistBuddy

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
temp_root=$(mktemp -d /tmp/ios-template-admob-test.XXXXXX)

cleanup() {
  local status=$?
  if [[ "$temp_root" == /tmp/ios-template-admob-test.* && "$temp_root" != /tmp/ios-template-admob-test. ]]; then
    rm -rf -- "$temp_root"
  fi
  exit "$status"
}
trap cleanup EXIT

fail() {
  echo "test-admob-integration: $*" >&2
  exit 1
}

expect_failure() {
  local label=$1
  shift
  if "$@" >"$temp_root/$label.stdout" 2>"$temp_root/$label.stderr"; then
    fail "$label unexpectedly succeeded"
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

binding='{"fixtureRoot":"tools/tests/fixtures/admob-monetization","project":"tools/tests/fixtures/admob-monetization/AdMobFixtureApp.xcodeproj","route":"tracked-fixture-v1","schemaVersion":1,"skillRoot":".agents/skills/admob-monetization","toolPaths":["tools/activate-admob-integration.sh","tools/lib/admob-activation.rb","tools/tests/test-admob-integration.sh","tools/validate-admob-integration.sh"]}'
binding_path="$repo_root/.agents/skills/admob-monetization/application-fixture.json"
[[ -f "$binding_path" && ! -L "$binding_path" ]] || fail 'application fixture binding is missing'
[[ "$(<"$binding_path")" == "$binding" ]] || fail 'application fixture binding is not the sealed canonical JSON'
[[ $(wc -c <"$binding_path" | tr -d ' ') -eq ${#binding} ]] || fail 'application fixture binding must not end with a newline'

alias_path="$repo_root/.claude/skills/admob-monetization"
[[ -L "$alias_path" ]] || fail 'Claude skill alias must be a symlink'
[[ "$(readlink "$alias_path")" == '../../.agents/skills/admob-monetization' ]] || fail 'Claude skill alias target is wrong'
[[ -f "$repo_root/.agents/skills/admob-monetization/SKILL.md" ]] || fail 'AdMob skill entrypoint is missing'
head -20 "$repo_root/.agents/skills/admob-monetization/SKILL.md" | grep '^name: admob-monetization$' >/dev/null || fail 'skill frontmatter name is missing'

fixture="$repo_root/tools/tests/fixtures/admob-monetization"
[[ -f "$fixture/AdMobFixtureApp.xcodeproj/project.pbxproj" ]] || fail 'tracked fixture project is missing'
if find "$fixture" -type f -path '*.xcworkspace/*' -print -quit | grep -q .; then
  fail 'tracked fixture must not contain a workspace'
fi
[[ -f "$fixture/AdMobFixtureAppTests/AdMobIntegrationTests.swift" ]] || fail 'fixture unit test is missing'
[[ -f "$fixture/AdMobFixtureAppUITests/AdMobBannerSmokeTests.swift" ]] || fail 'fixture UI test is missing'
cmp -s "$repo_root/.agents/skills/admob-monetization/templates/AdMobCore.swift" "$fixture/AdMobFixtureApp/Core/AdMobRuntime.swift" || fail 'fixture must compile the exact production AdMob core'
cmp -s "$repo_root/.agents/skills/admob-monetization/templates/AdaptiveBannerHost.swift" "$fixture/AdMobFixtureApp/UI/AdaptiveBannerHost.swift" || fail 'fixture must compile the exact production adaptive host'
grep -q 'testConsentEligibilityAndRequestDeduplication' "$fixture/AdMobFixtureAppTests/AdMobIntegrationTests.swift" || fail 'fixture unit selector drifted'
grep -q 'testJapaneseBannerPlacement' "$fixture/AdMobFixtureAppUITests/AdMobBannerSmokeTests.swift" || fail 'fixture UI selector drifted'
grep -q 'func testJapanesePadBannerPlacement' "$fixture/AdMobFixtureAppUITests/AdMobBannerSmokeTests.swift" || fail 'fixture iPad UI selector drifted'
if rg -n 'GoogleMobileAds|UserMessagingPlatform|XCRemoteSwiftPackageReference' "$fixture/AdMobFixtureApp.xcodeproj" "$fixture/AdMobFixtureApp" >/dev/null; then
  fail 'tracked fixture must remain network-free'
fi

# The live project keeps the template's name until Identity bootstrap renames it; read the module from the
# app's Identity record when there is one (#345). It is used only to check that the live project is untouched.
live_module=$(ruby -rjson -e '
  path = File.join(ARGV.fetch(0), "Config/app-identity.json")
  puts File.file?(path) ? JSON.parse(File.read(path)).fetch("moduleName") : "TemplateApp"
' "$repo_root")
[[ "$live_module" =~ ^[A-Za-z][A-Za-z0-9]*$ && -f "$repo_root/$live_module.xcodeproj/project.pbxproj" && -d "$repo_root/$live_module" ]] ||
  fail "the live project for module $live_module is missing"
template_project_digest=$(sha256_file "$repo_root/$live_module.xcodeproj/project.pbxproj")
template_source_digest=$(find "$repo_root/$live_module" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')

derived="$temp_root/derived-app"
mkdir -p "$derived/Config" "$derived/GardenNotes" "$derived/GardenNotesTests" "$derived/GardenNotesUITests" "$derived/tools/lib" "$derived/.agents/skills" "$derived/App Store/metadata"
# The sample starts from the template's own project, kept in the frozen bootstrap fixture, so an app's
# module name never has to be reversed out of its project (a name such as Debug also labels configurations).
ruby -rjson -rdigest - "$repo_root/tools/tests/fixtures/bootstrap-template/source-identity.json" "$temp_root/project.pbxproj" <<'RUBY' ||
fixture, destination = ARGV
entry = JSON.parse(File.read(fixture)).fetch("files").find { |file| file["path"] == "TemplateApp.xcodeproj/project.pbxproj" }
abort "the bootstrap fixture lacks the template project" unless entry
bytes = entry.fetch("lines").join("\n")
abort "the bootstrap fixture's template project does not match its digest" unless Digest::SHA256.hexdigest(bytes) == entry.fetch("sha256")
File.binwrite(destination, bytes)
RUBY
  fail 'the template project could not be read from the bootstrap fixture'
mkdir -p "$derived/GardenNotes.xcodeproj"
ruby - "$temp_root/project.pbxproj" "$derived/GardenNotes.xcodeproj/project.pbxproj" <<'RUBY'
source, destination = ARGV
bytes = File.binread(source)
bytes = bytes.gsub("TemplateApp", "GardenNotes")
bytes = bytes.gsub("com.yuto.GardenNotes", "com.example.GardenNotes")
# Identity bootstrap adds the display name to the application target only, as in a real derived app.
anchor = "\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;\n"
abort "the template project lacks the application INFOPLIST_KEY anchor" unless bytes.scan(anchor).length == 2
bytes = bytes.gsub(anchor, "\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = \"Garden Notes\";\n#{anchor}")
File.binwrite(destination, bytes)
RUBY
printf '%s\n' '// fixture source' >"$derived/GardenNotes/App.swift"
printf '%s\n' '// fixture tests' >"$derived/GardenNotesTests/Tests.swift"
printf '%s\n' '// fixture UI tests' >"$derived/GardenNotesUITests/UITests.swift"
printf '%s\n' '// public settings' >"$derived/Config/Public.xcconfig"
printf '%s\n' '{"appSlug":"garden-notes","bundleId":"com.example.GardenNotes","displayName":"Garden Notes","moduleName":"GardenNotes","schemaVersion":1,"sourceIdentityVersion":1}' >"$derived/Config/app-identity.json"
printf '%s\n' '{"adMobDataUse":["advertising-data","device-id"],"appStoreTracking":false,"status":"reviewed"}' >"$derived/App Store/metadata/admob-privacy-review.json"
cp "$repo_root/tools/activate-admob-integration.sh" "$derived/tools/activate-admob-integration.sh"
cp "$repo_root/tools/validate-admob-integration.sh" "$derived/tools/validate-admob-integration.sh"
cp "$repo_root/tools/lib/admob-activation.rb" "$derived/tools/lib/admob-activation.rb"
cp -R "$repo_root/.agents/skills/admob-monetization" "$derived/.agents/skills/admob-monetization"

git -C "$derived" init -q -b main
git -C "$derived" config user.name 'iOS Template Test'
git -C "$derived" config user.email 'test@example.invalid'
git -C "$derived" add .
git -C "$derived" commit -qm 'fixture baseline'
remote="$temp_root/derived-remote.git"
git init -q --bare "$remote"
git -C "$derived" remote add origin "$remote"
git -C "$derived" push -q -u origin main
git -C "$remote" symbolic-ref HEAD refs/heads/main
git -C "$derived" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$derived" checkout -qb codex/test-admob

input="$temp_root/input.json"
checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
privacy_digest="sha256:$(sha256_file "$derived/App Store/metadata/admob-privacy-review.json")"
ruby -rjson - "$input" "$checked_at" "$privacy_digest" <<'RUBY'
path, checked_at, privacy_digest = ARGV
value = {
  "schemaVersion" => 1,
  "adopted" => true,
  "appIdentity" => {
    "displayName" => "Garden Notes",
    "moduleName" => "GardenNotes",
    "appSlug" => "garden-notes",
    "bundleId" => "com.example.GardenNotes",
  },
  "deploymentTarget" => "26.5",
  "placement" => {
    "includedScreens" => ["home", "journal"],
    "excludedScreens" => ["purchase", "settings"],
    "container" => "safe-area-bottom",
    "privacyOptionsEntry" => "settings.privacy",
  },
  "audience" => {
    "minimumAge" => 18,
    "regions" => ["global"],
    "childDirected" => false,
    "underAgeOfConsent" => false,
  },
  "tracking" => {
    "mode" => "non-tracking",
    "attPrompt" => false,
    "publisherFirstPartyIDEnabled" => false,
    "personalizedAds" => false,
  },
  "ump" => {"enabled" => true, "privacyOptionsEnabled" => true},
  "adFreeEntitlement" => {"enabled" => true, "source" => "entitlements.hasAdFreeAccess"},
  "identifiers" => {
    "debug" => {
      "appId" => "ca-app-pub-3940256099942544~1458002511",
      "bannerUnitId" => "ca-app-pub-3940256099942544/2435281174",
    },
    "release" => {
      "appId" => "ca-app-pub-1234567890123456~1234567890",
      "bannerUnitId" => "ca-app-pub-1234567890123456/0987654321",
      "binding" => {
        "bundleId" => "com.example.GardenNotes",
        "configuration" => "Release",
        "readbackSource" => "admob-console-readback",
        "verifiedAt" => checked_at,
      },
    },
  },
  "privacyDeclaration" => {
    "appStoreTracking" => false,
    "dataUseCategories" => ["advertising-data", "device-id"],
    "reviewedAt" => checked_at,
    "sourceDigest" => privacy_digest,
    "sourcePath" => "App Store/metadata/admob-privacy-review.json",
  },
  "officialSources" => {
    "checkedAt" => checked_at,
    "googleMobileAds" => {
      "minimumIOS" => "13.0",
      "minimumXcode" => "16.0",
      "packageURL" => "https://github.com/googleads/swift-package-manager-google-mobile-ads.git",
      "releaseURL" => "https://github.com/googleads/swift-package-manager-google-mobile-ads/releases/tag/13.10.0",
      "revision" => "12b7af0f844723a86fd3c0089b02f64b1e495605",
      "version" => "13.10.0",
    },
    "ump" => {
      "packageURL" => "https://github.com/googleads/swift-package-manager-google-user-messaging-platform.git",
      "releaseURL" => "https://github.com/googleads/swift-package-manager-google-user-messaging-platform/releases/tag/3.1.0",
      "revision" => "13b248eaa73b7826f0efb1bcf455e251d65ecb1b",
      "version" => "3.1.0",
    },
    "googleGuides" => [
      "https://developers.google.com/admob/ios/banner",
      "https://developers.google.com/admob/ios/privacy",
      "https://developers.google.com/admob/ios/privacy/strategies",
      "https://developers.google.com/admob/ios/quick-start",
      "https://developers.google.com/admob/ios/targeting",
      "https://developers.google.com/admob/ios/test-ads",
    ],
    "appleGuides" => ["https://developer.apple.com/app-store/user-privacy-and-data-use/"],
  },
  "skAdNetworkIdentifiers" => ["cstr6suwn9.skadnetwork"],
}
File.binwrite(path, JSON.generate(value) + "\n")
RUBY

invalid="$temp_root/invalid.json"
ruby -rjson - "$input" "$invalid" <<'RUBY'
source, destination = ARGV
value = JSON.parse(File.binread(source))
value["adopted"] = false
File.binwrite(destination, JSON.generate(value) + "\n")
RUBY
project_before=$(sha256_file "$derived/GardenNotes.xcodeproj/project.pbxproj")
expect_failure invalid-input "$repo_root/tools/activate-admob-integration.sh" --root "$derived" --input "$invalid"
[[ -z "$(git -C "$derived" status --porcelain=v1)" ]] || fail 'invalid input changed the derived app'
[[ "$(sha256_file "$derived/GardenNotes.xcodeproj/project.pbxproj")" == "$project_before" ]] || fail 'invalid input changed the project'

# D-087 (#398): an audience below 16, a minimum age that is not an integer, a child-directed audience, and an
# under-age-of-consent audience stop before any change, with their reasons.
age_case() {
  local label=$1 expression=$2 message=$3
  ruby -rjson -e 'value = JSON.parse(File.binread(ARGV[0])); eval(ARGV[2]); File.binwrite(ARGV[1], JSON.generate(value) + "\n")' "$input" "$invalid" "$expression"
  expect_failure "audience-$label" "$repo_root/tools/activate-admob-integration.sh" --root "$derived" --input "$invalid"
  grep -Fq "$message" "$temp_root/audience-$label.stderr" || fail "audience $label was not refused with its reason: $(cat "$temp_root/audience-$label.stderr")"
  [[ -z "$(git -C "$derived" status --porcelain=v1 --untracked-files=all)" ]] || fail "audience $label changed the derived app"
  [[ "$(sha256_file "$derived/GardenNotes.xcodeproj/project.pbxproj")" == "$project_before" ]] || fail "audience $label changed the project"
}
age_case under-16 'value["audience"]["minimumAge"] = 15' 'audience.minimumAge must be an integer of at least 16'
age_case fractional 'value["audience"]["minimumAge"] = 16.5' 'audience.minimumAge must be an integer of at least 16'
age_case string 'value["audience"]["minimumAge"] = "16"' 'audience.minimumAge must be an integer of at least 16'
age_case child-directed 'value["audience"]["childDirected"] = true' 'child-directed or under-age treatment requires a separate decision'
age_case under-age-of-consent 'value["audience"]["underAgeOfConsent"] = true' 'child-directed or under-age treatment requires a separate decision'
age_case child-directed-16 'value["audience"]["minimumAge"] = 16; value["audience"]["childDirected"] = true' 'child-directed or under-age treatment requires a separate decision'

# #375: a container other than the two safe-area edges stops before any change.
for container in inline safe-area-middle SAFE-AREA-TOP; do
  ruby -rjson -e 'value = JSON.parse(File.binread(ARGV[0])); value["placement"]["container"] = ARGV[2]; File.binwrite(ARGV[1], JSON.generate(value) + "\n")' "$input" "$invalid" "$container"
  expect_failure "invalid-container-$container" "$repo_root/tools/activate-admob-integration.sh" --root "$derived" --input "$invalid"
  grep -Fq 'placement.container must be one of safe-area-bottom, safe-area-top' "$temp_root/invalid-container-$container.stderr" ||
    fail "container $container was not refused with its reason: $(cat "$temp_root/invalid-container-$container.stderr")"
  [[ -z "$(git -C "$derived" status --porcelain=v1)" ]] || fail "container $container changed the derived app"
  [[ "$(sha256_file "$derived/GardenNotes.xcodeproj/project.pbxproj")" == "$project_before" ]] || fail "container $container changed the project"
done

wrong_binding="$temp_root/wrong-binding.json"
ruby -rjson - "$input" "$wrong_binding" <<'RUBY'
source, destination = ARGV
value = JSON.parse(File.binread(source))
value["identifiers"]["release"]["binding"]["bundleId"] = "com.example.OtherApp"
File.binwrite(destination, JSON.generate(value) + "\n")
RUBY
expect_failure wrong-release-binding "$repo_root/tools/activate-admob-integration.sh" --root "$derived" --input "$wrong_binding"
[[ -z "$(git -C "$derived" status --porcelain=v1)" ]] || fail 'wrong Release binding changed the derived app'

symlink_derived="$temp_root/symlink-derived"
git clone -q "$remote" "$symlink_derived"
git -C "$symlink_derived" config user.name 'iOS Template Test'
git -C "$symlink_derived" config user.email 'test@example.invalid'
git -C "$symlink_derived" checkout -qb codex/test-admob-symlink
outside_module="$temp_root/outside-module"
mkdir -p "$outside_module"
printf '%s\n' '// outside fixture source' >"$outside_module/App.swift"
git -C "$symlink_derived" rm -qr GardenNotes
ln -s "$outside_module" "$symlink_derived/GardenNotes"
git -C "$symlink_derived" add GardenNotes
git -C "$symlink_derived" commit -qm 'fixture symlink ancestor'
outside_before=$(find "$outside_module" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
expect_failure symlink-ancestor "$repo_root/tools/activate-admob-integration.sh" --root "$symlink_derived" --input "$input"
[[ ! -e "$outside_module/AdMob" ]] || fail 'symlink ancestor wrote outside the staged repository'
[[ "$(find "$outside_module" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')" == "$outside_before" ]] || fail 'symlink ancestor changed outside bytes'

trunk_derived="$temp_root/trunk-derived"
git clone -q "$remote" "$trunk_derived"
git -C "$trunk_derived" config user.name 'iOS Template Test'
git -C "$trunk_derived" config user.email 'test@example.invalid'
git -C "$trunk_derived" checkout -qb trunk
git -C "$trunk_derived" push -q -u origin trunk
git -C "$trunk_derived" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
expect_failure default-trunk "$repo_root/tools/activate-admob-integration.sh" --root "$trunk_derived" --input "$input"
[[ -z "$(git -C "$trunk_derived" status --porcelain=v1)" ]] || fail 'default trunk rejection changed the derived app'

package_derived="$temp_root/package-derived"
git clone -q "$remote" "$package_derived"
git -C "$package_derived" config user.name 'iOS Template Test'
git -C "$package_derived" config user.email 'test@example.invalid'
git -C "$package_derived" checkout -qb codex/test-admob-existing-package
ruby -I"$repo_root/tools/lib" -radmob-activation - "$package_derived/GardenNotes.xcodeproj/project.pbxproj" <<'RUBY'
path = ARGV.fetch(0)
identity = {"moduleName" => "GardenNotes", "bundleId" => "com.example.UnrelatedSeed"}
bytes = IOSTemplate::AdMobActivation.add_package_dependency(File.binread(path), identity)
bytes = bytes.gsub("GoogleMobileAds", "ExamplePackage")
bytes = bytes.gsub(IOSTemplate::AdMobActivation::PACKAGE_URL, "https://example.invalid/example-package.git")
bytes = bytes.gsub(IOSTemplate::AdMobActivation::PACKAGE_VERSION, "1.2.3")
File.binwrite(path, bytes)
RUBY
package_resolved="$package_derived/GardenNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
mkdir -p "$(dirname "$package_resolved")"
printf '%s\n' '{"pins":[{"identity":"example-package","kind":"remoteSourceControl","location":"https://example.invalid/example-package.git","state":{"revision":"1111111111111111111111111111111111111111","version":"1.2.3"}}],"version":3}' >"$package_resolved"
git -C "$package_derived" add GardenNotes.xcodeproj
git -C "$package_derived" commit -qm 'fixture unrelated Swift package'
package_resolved_before=$(sha256_file "$package_resolved")
"$repo_root/tools/activate-admob-integration.sh" --root "$package_derived" --input "$input" >/dev/null
grep -Fq 'productName = ExamplePackage;' "$package_derived/GardenNotes.xcodeproj/project.pbxproj" || fail 'activation removed an unrelated package product'
grep -Fq 'productName = GoogleMobileAds;' "$package_derived/GardenNotes.xcodeproj/project.pbxproj" || fail 'activation did not add GoogleMobileAds alongside an unrelated package'
[[ "$(sha256_file "$package_resolved")" == "$package_resolved_before" ]] || fail 'activation overwrote an unrelated Package.resolved graph'
"$repo_root/tools/validate-admob-integration.sh" --root "$package_derived" >/dev/null

apply_output=$({ time "$repo_root/tools/activate-admob-integration.sh" --root "$derived" --input "$input"; } 2>"$temp_root/apply.time")
[[ "$apply_output" == *'"status":"applied"'* ]] || fail 'valid activation did not report applied'
"$repo_root/tools/validate-admob-integration.sh" --root "$derived" >"$temp_root/validate.json"
grep -q '"status":"valid"' "$temp_root/validate.json" || fail 'validator did not report valid'

project="$derived/GardenNotes.xcodeproj/project.pbxproj"
grep -Fq 'repositoryURL = "https://github.com/googleads/swift-package-manager-google-mobile-ads.git";' "$project" || fail 'official package URL was not added'
grep -Fq 'version = 13.10.0;' "$project" || fail 'exact package version was not added'
grep -Fq 'productName = GoogleMobileAds;' "$project" || fail 'GoogleMobileAds product was not linked'

# #374: activation keeps the template project's own Info.plist sources. In the application Debug and Release
# configurations GENERATE_INFOPLIST_FILE stays YES and every INFOPLIST_KEY_* line (scene manifest, launch
# screen, orientations, display name) stays as it was; only the App ID setting and the ad-only plist are added.
app_settings_report() {
  ruby - "$1" <<'RUBY'
bytes = File.binread(ARGV.fetch(0))
list = bytes[/Build configuration list for PBXNativeTarget "GardenNotes" \*\/ = \{.*?\n\t\t\};/m] or abort "no application configuration list"
%w[Debug Release].each do |name|
  identifier = list[/([A-F0-9]{24}) \/\* #{name} \*\//, 1] or abort "no #{name} configuration"
  block = bytes[/\t\t#{identifier} \/\* #{name} \*\/ = \{.*?\n\t\t\};/m] or abort "no #{name} block"
  settings = block.lines.grep(/\A\t\t\t\t(?:GENERATE_INFOPLIST_FILE|INFOPLIST_FILE|INFOPLIST_KEY_|ADMOB_APPLICATION_IDENTIFIER)/)
  puts settings.map { |line| "#{name} #{line.strip}" }
end
RUBY
}
git -C "$derived" show HEAD:GardenNotes.xcodeproj/project.pbxproj >"$temp_root/source.pbxproj"
app_settings_report "$temp_root/source.pbxproj" >"$temp_root/source-settings.txt"
app_settings_report "$project" >"$temp_root/activated-settings.txt"
grep -cE '^(Debug|Release) INFOPLIST_KEY_' "$temp_root/source-settings.txt" | grep -qx 12 || fail 'the sample template project lost its INFOPLIST_KEY_* baseline'
for key in UIApplicationSceneManifest_Generation UILaunchScreen_Generation UISupportedInterfaceOrientations_iPhone UISupportedInterfaceOrientations_iPad CFBundleDisplayName; do
  for configuration in Debug Release; do
    grep -q "^$configuration INFOPLIST_KEY_$key = " "$temp_root/activated-settings.txt" || fail "$configuration lost INFOPLIST_KEY_$key"
  done
done
{
  cat "$temp_root/source-settings.txt"
  printf '%s\n' \
    'Debug ADMOB_APPLICATION_IDENTIFIER = "ca-app-pub-3940256099942544~1458002511";' \
    'Debug INFOPLIST_FILE = GardenNotes/AdMob/Info.plist;' \
    'Release ADMOB_APPLICATION_IDENTIFIER = "ca-app-pub-1234567890123456~1234567890";' \
    'Release INFOPLIST_FILE = GardenNotes/AdMob/Info.plist;'
} | LC_ALL=C sort >"$temp_root/expected-settings.txt"
LC_ALL=C sort "$temp_root/activated-settings.txt" | cmp -s - "$temp_root/expected-settings.txt" ||
  fail "activation changed the application's Info.plist settings: $(LC_ALL=C sort "$temp_root/activated-settings.txt" | diff "$temp_root/expected-settings.txt" - || true)"
grep -Fq 'GENERATE_INFOPLIST_FILE = NO;' "$project" && fail 'activation turned off the generated Info.plist'
grep -Fq 'Debug GENERATE_INFOPLIST_FILE = YES;' "$temp_root/activated-settings.txt" || fail 'Debug no longer generates its Info.plist'
grep -Fq 'Release GENERATE_INFOPLIST_FILE = YES;' "$temp_root/activated-settings.txt" || fail 'Release no longer generates its Info.plist'
# The synchronized GardenNotes folder must not also copy the ad-only plist into the bundle as a resource.
ruby -e 'exit(File.binread(ARGV.fetch(0)).include?("membershipExceptions = (\n\t\t\t\tAdMob/Info.plist,\n") ? 0 : 1)' "$project" || fail 'the ad-only plist is not excluded from the synchronized resources'
[[ ! -e "$derived/GardenNotes/AdMob/Info-Debug.plist" && ! -e "$derived/GardenNotes/AdMob/Info-Release.plist" ]] || fail 'activation still writes replacement Info.plist files'

info_plist="$derived/GardenNotes/AdMob/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :GADApplicationIdentifier' "$info_plist")" == '$(ADMOB_APPLICATION_IDENTIFIER)' ]] || fail 'the Info.plist App ID does not reference the per-configuration setting'
[[ "$(plutil -extract SKAdNetworkItems json -o - "$info_plist")" == '[{"SKAdNetworkIdentifier":"cstr6suwn9.skadnetwork"}]' ]] || fail 'SKAdNetworkItems were not added'
[[ "$(plutil -convert json -o - "$info_plist" | ruby -rjson -e 'puts JSON.parse(STDIN.read).keys.sort.join(",")')" == 'GADApplicationIdentifier,SKAdNetworkItems' ]] ||
  fail 'the ad-only plist must hold only the advertising keys'
if rg -n 'ATTrackingManager|requestTrackingAuthorization|NSUserTrackingUsageDescription' "$derived/GardenNotes/AdMob" >/dev/null; then
  fail 'non-tracking activation introduced ATT'
fi
grep -Rq 'setPublisherFirstPartyIDEnabled(false)' "$derived/GardenNotes/AdMob" || fail 'first-party ID is not disabled'
grep -Rq 'publisherPrivacyPersonalizationState = .disabled' "$derived/GardenNotes/AdMob" || fail 'personalization is not disabled'
grep -Rq 'largeAnchoredAdaptiveBanner(width:' "$derived/GardenNotes/AdMob" || fail 'current adaptive banner API is missing'
grep -Rq 'await MobileAds.shared.start()' "$derived/GardenNotes/AdMob" || fail 'Mobile Ads async start is not awaited'
grep -Rq 'requestGeneration: Int' "$derived/GardenNotes/AdMob" || fail 'consent generation is not bound to banner request deduplication'
grep -Rq 'AdSizeDelegate' "$derived/GardenNotes/AdMob" || fail 'provider does not observe SDK creative size changes'
if grep -Rq 'banner\.adSize = ' "$derived/GardenNotes/AdMob"; then
  fail 'provider must not combine adSize auto-reload with an explicit duplicate load'
fi
grep -Rq 'privacyOptionsEntry = "settings.privacy"' "$derived/GardenNotes/AdMob" || fail 'confirmed privacy-options entry was not generated'
grep -Fxq '    static let adFreeEntitlementSource = "entitlements.hasAdFreeAccess"' "$derived/GardenNotes/AdMob/AdMobConfiguration.swift" ||
  fail 'the entitlement source is not one valid Swift string literal'
grep -Rq 'func invalidateEligibility()' "$derived/GardenNotes/AdMob" || fail 'eligibility changes cannot invalidate banner hosts'
grep -Rq 'self.gate.accepts(token)' "$derived/GardenNotes/AdMob/AdaptiveBannerHost.swift" || fail 'host accepts callbacks from suppressed generations'
grep -Rq 'stateDidChange = nil' "$derived/GardenNotes/AdMob/GoogleMobileAdsProvider.swift" || fail 'detached hosts keep receiving SDK callbacks'
# D-087 (#398): the core decides the ad content rating cap from the recorded minimum age, and the provider sets
# it on the SDK request configuration. This app records 18, so the app sets no cap at run time.
grep -Fxq '    static let minimumAudienceAge = 18' "$derived/GardenNotes/AdMob/AdMobConfiguration.swift" || fail 'the 18+ audience was not generated'
grep -Fq 'minimumAge < unrestrictedMinimumAudienceAge ? .teen : .unrestricted' "$derived/GardenNotes/AdMob/AdMobCore.swift" || fail 'the core does not decide the ad content rating cap'
grep -Fxq '    static let unrestrictedMinimumAudienceAge = 18' "$derived/GardenNotes/AdMob/AdMobCore.swift" || fail 'the core does not cap audiences under 18'
grep -Fq 'switch AdMobMaxAdContentRating.cap(forMinimumAudienceAge: ActivatedAdMobConfiguration.minimumAudienceAge) {' "$derived/GardenNotes/AdMob/GoogleMobileAdsProvider.swift" ||
  fail 'the provider does not apply the core decision for the recorded audience'
grep -Fq 'requestConfiguration.maxAdContentRating = .teen' "$derived/GardenNotes/AdMob/GoogleMobileAdsProvider.swift" || fail 'the provider does not set the T cap on the SDK'

provider_modules="$temp_root/provider-modules"
mkdir -p "$provider_modules"
sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -emit-module -parse-as-library -module-name GoogleMobileAds \
  -target arm64-apple-ios26.5-simulator -sdk "$sdk_path" \
  -emit-module-path "$provider_modules/GoogleMobileAds.swiftmodule" \
  "$fixture/ProviderStubs/GoogleMobileAds.swift"
xcrun swiftc -emit-module -parse-as-library -module-name UserMessagingPlatform \
  -target arm64-apple-ios26.5-simulator -sdk "$sdk_path" \
  -emit-module-path "$provider_modules/UserMessagingPlatform.swiftmodule" \
  "$fixture/ProviderStubs/UserMessagingPlatform.swift"
# The generated configuration, runtime, host, and provider must compile together as one module.
xcrun swiftc -typecheck -target arm64-apple-ios26.5-simulator \
  -sdk "$sdk_path" -I "$provider_modules" \
  "$derived/GardenNotes/AdMob/AdMobConfiguration.swift" \
  "$derived/GardenNotes/AdMob/AdMobCore.swift" \
  "$derived/GardenNotes/AdMob/AdaptiveBannerHost.swift" \
  "$derived/GardenNotes/AdMob/GoogleMobileAdsProvider.swift"

record="$derived/Config/admob-activation.json"
cp "$record" "$temp_root/admob-activation.json"
ruby -rjson - "$record" <<'RUBY'
path = ARGV.fetch(0)
value = JSON.parse(File.binread(path))
value["inputDigest"] = "0" * 64
File.binwrite(path, JSON.generate(value) + "\n")
RUBY
expect_failure record-input-digest-tamper "$repo_root/tools/validate-admob-integration.sh" --root "$derived"
cp "$temp_root/admob-activation.json" "$record"

ruby -rjson - "$record" <<'RUBY'
path = ARGV.fetch(0)
value = JSON.parse(File.binread(path))
value["package"]["version"] = "99.0.0"
File.binwrite(path, JSON.generate(value) + "\n")
RUBY
expect_failure record-package-tamper "$repo_root/tools/validate-admob-integration.sh" --root "$derived"
cp "$temp_root/admob-activation.json" "$record"

ruby -rdigest -rjson - "$record" <<'RUBY'
def canonical(value)
  case value
  when Hash
    "{" + value.keys.sort.map { |key| "#{JSON.generate(key)}:#{canonical(value.fetch(key))}" }.join(",") + "}"
  when Array
    "[" + value.map { |entry| canonical(entry) }.join(",") + "]"
  else
    JSON.generate(value)
  end
end
path = ARGV.fetch(0)
value = JSON.parse(File.binread(path))
value["activationInput"]["placement"]["privacyOptionsEntry"] = "settings.changed-privacy"
value["inputDigest"] = Digest::SHA256.hexdigest(canonical(value["activationInput"]))
File.binwrite(path, JSON.generate(value) + "\n")
RUBY
expect_failure record-input-swap "$repo_root/tools/validate-admob-integration.sh" --root "$derived"
cp "$temp_root/admob-activation.json" "$record"
"$repo_root/tools/validate-admob-integration.sh" --root "$derived" >/dev/null

[[ ! -e "$derived/GardenNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" ]] || fail 'activation must not forge a Package.resolved file before Xcode resolves the exact package graph'

diff_before=$(git -C "$derived" diff --binary | shasum -a 256 | awk '{print $1}')
second_output=$("$repo_root/tools/activate-admob-integration.sh" --root "$derived" --input "$input")
[[ "$second_output" == *'"status":"already-complete"'* ]] || fail 'same input was not idempotent'
[[ "$(git -C "$derived" diff --binary | shasum -a 256 | awk '{print $1}')" == "$diff_before" ]] || fail 'idempotent run changed bytes'

different="$temp_root/different.json"
ruby -rjson - "$input" "$different" <<'RUBY'
source, destination = ARGV
value = JSON.parse(File.binread(source))
value["placement"]["privacyOptionsEntry"] = "settings.ad-privacy"
File.binwrite(destination, JSON.generate(value) + "\n")
RUBY
expect_failure different-input "$repo_root/tools/activate-admob-integration.sh" --root "$derived" --input "$different"
[[ "$(git -C "$derived" diff --binary | shasum -a 256 | awk '{print $1}')" == "$diff_before" ]] || fail 'different input changed existing activation'

core="$derived/GardenNotes/AdMob/AdMobCore.swift"
cp "$core" "$temp_root/AdMobCore.swift"
printf '\n// drift\n' >>"$core"
expect_failure drift "$repo_root/tools/validate-admob-integration.sh" --root "$derived"
cp "$temp_root/AdMobCore.swift" "$core"
"$repo_root/tools/validate-admob-integration.sh" --root "$derived" >/dev/null

# The validator compares on-disk identifiers, SKAdNetwork items, and sources with the recorded input
# itself, so an edit that also rewrites the record's file digest still fails.
configuration="$derived/GardenNotes/AdMob/AdMobConfiguration.swift"
pinned_files=("$record" "$info_plist" "$configuration" "$core" "$project")
for path in "${pinned_files[@]}"; do
  cp "$path" "$temp_root/$(basename "$path").pristine"
done
restore_activation() {
  for path in "${pinned_files[@]}"; do
    cp "$temp_root/$(basename "$path").pristine" "$path"
  done
}
tamper_file() {
  local label=$1 relative=$2 pattern=$3 replacement=$4 expected=$5 pin=$6
  ruby -rdigest -rjson - "$derived" "$relative" "$pattern" "$replacement" "$record" "$pin" <<'RUBY'
root, relative, pattern, replacement, record_path, pin = ARGV
path = File.join(root, relative)
bytes = File.binread(path)
changed = bytes.sub(pattern, replacement)
abort "tamper pattern not found: #{pattern}" if changed == bytes
File.binwrite(path, changed)
if pin == "pin"
  value = JSON.parse(File.binread(record_path))
  value["fileDigests"][relative] = Digest::SHA256.hexdigest(changed)
  File.binwrite(record_path, JSON.generate(value) + "\n")
end
RUBY
  expect_failure "$label" "$repo_root/tools/validate-admob-integration.sh" --root "$derived"
  grep -Fq "$expected" "$temp_root/$label.stderr" || fail "$label failed for another reason: $(<"$temp_root/$label.stderr")"
  restore_activation
}
tamper_with_digest() { tamper_file "$@" pin; }
# The Info.plist is the app's file and is not pinned by digest; its advertising keys are still checked.
tamper_info_plist() { tamper_file "$1" GardenNotes/AdMob/Info.plist "$2" "$3" "$4" unpinned; }
tamper_with_digest release-setting-app-id GardenNotes.xcodeproj/project.pbxproj \
  'ADMOB_APPLICATION_IDENTIFIER = "ca-app-pub-1234567890123456~1234567890";' 'ADMOB_APPLICATION_IDENTIFIER = "ca-app-pub-1234567890123456~1111111111";' \
  'Release ADMOB_APPLICATION_IDENTIFIER differs from the activation record'
tamper_with_digest release-setting-demo GardenNotes.xcodeproj/project.pbxproj \
  'ADMOB_APPLICATION_IDENTIFIER = "ca-app-pub-1234567890123456~1234567890";' 'ADMOB_APPLICATION_IDENTIFIER = "ca-app-pub-3940256099942544~1458002511";' \
  'Release ADMOB_APPLICATION_IDENTIFIER differs from the activation record'
tamper_with_digest debug-setting-production GardenNotes.xcodeproj/project.pbxproj \
  'ADMOB_APPLICATION_IDENTIFIER = "ca-app-pub-3940256099942544~1458002511";' 'ADMOB_APPLICATION_IDENTIFIER = "ca-app-pub-1234567890123456~1234567890";' \
  'Debug ADMOB_APPLICATION_IDENTIFIER differs from the activation record'
tamper_with_digest generated-info-plist-off GardenNotes.xcodeproj/project.pbxproj \
  $'GENERATE_INFOPLIST_FILE = YES;\n\t\t\t\tINFOPLIST_FILE = GardenNotes/AdMob/Info.plist;' $'GENERATE_INFOPLIST_FILE = NO;\n\t\t\t\tINFOPLIST_FILE = GardenNotes/AdMob/Info.plist;' \
  'GENERATE_INFOPLIST_FILE changed from the activation source'
tamper_with_digest second-info-plist-file GardenNotes.xcodeproj/project.pbxproj \
  'INFOPLIST_FILE = GardenNotes/AdMob/Info.plist;' $'INFOPLIST_FILE = GardenNotes/AdMob/Info.plist;\n\t\t\t\tINFOPLIST_FILE = GardenNotes/Info.plist;' \
  'configuration must declare exactly one INFOPLIST_FILE'
tamper_with_digest att-build-setting GardenNotes.xcodeproj/project.pbxproj \
  'INFOPLIST_KEY_UILaunchScreen_Generation = YES;' $'INFOPLIST_KEY_NSUserTrackingUsageDescription = "Track";\n\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;' \
  'configuration must not declare NSUserTrackingUsageDescription'
tamper_with_digest resource-exception-removed GardenNotes.xcodeproj/project.pbxproj \
  $'\t\t\t\tAdMob/Info.plist,\n' '' \
  'GardenNotes/AdMob/Info.plist must be excluded from the application target'"'"'s synchronized resources'
tamper_info_plist plist-app-id-literal \
  '<string>$(ADMOB_APPLICATION_IDENTIFIER)</string>' '<string>ca-app-pub-1234567890123456~1234567890</string>' \
  'GardenNotes/AdMob/Info.plist GADApplicationIdentifier must be $(ADMOB_APPLICATION_IDENTIFIER)'
tamper_info_plist plist-app-id-demo \
  '<string>$(ADMOB_APPLICATION_IDENTIFIER)</string>' '<string>ca-app-pub-3940256099942544~1458002511</string>' \
  'GardenNotes/AdMob/Info.plist GADApplicationIdentifier must be $(ADMOB_APPLICATION_IDENTIFIER)'
tamper_info_plist skadnetwork-extra \
  '<string>cstr6suwn9.skadnetwork</string>' '<string>cstr6suwn9.skadnetwork</string></dict><dict><key>SKAdNetworkIdentifier</key><string>4fzdc2evr5.skadnetwork</string>' \
  'GardenNotes/AdMob/Info.plist SKAdNetworkItems differ from the activation record'
tamper_info_plist skadnetwork-missing \
  '<string>cstr6suwn9.skadnetwork</string>' '<string>4fzdc2evr5.skadnetwork</string>' \
  'GardenNotes/AdMob/Info.plist SKAdNetworkItems differ from the activation record'
tamper_info_plist att-usage \
  '<key>SKAdNetworkItems</key>' '<key>NSUserTrackingUsageDescription</key><string>Track</string><key>SKAdNetworkItems</key>' \
  'GardenNotes/AdMob/Info.plist must not declare ATT usage'
# An Info.plist key unrelated to ads, added after activation, keeps the app valid (#374).
plutil -insert NSCameraUsageDescription -string 'Capture garden photos' "$info_plist"
plutil -insert UIBackgroundModes -json '["remote-notification"]' "$info_plist"
"$repo_root/tools/validate-admob-integration.sh" --root "$derived" >/dev/null || fail 'an unrelated Info.plist key broke validation'
restore_activation
tamper_with_digest fixture-route GardenNotes/AdMob/AdMobCore.swift \
  'import Foundation' "import Foundation
// let failure = ProcessInfo.processInfo.arguments.contains(\"--fixture-banner-failure\")" \
  'activated sources must not contain the network-free UI-test fixture route'
"$repo_root/tools/validate-admob-integration.sh" --root "$derived" >/dev/null

# The readiness report validates first, then reports facts, freshness, drift, and independent evidence
# classes without ever claiming release readiness.
readiness() { "$repo_root/tools/validate-admob-integration.sh" --root "$derived" --readiness "$@"; }
readiness >"$temp_root/readiness.json"
ruby -rjson - "$temp_root/readiness.json" <<'RUBY'
value = JSON.parse(File.binread(ARGV.fetch(0)))
abort "readiness status" unless value["status"] == "reported" && value["activation"] == "valid" && value["releaseReadiness"] == "not-proven"
abort "SDK update not reported" unless value.dig("sdk", "googleMobileAds", "status") == "update-available" &&
  value.dig("sdk", "googleMobileAds", "pinnedVersion") == "13.10.0" && value.dig("sdk", "ump", "status") == "current"
abort "Xcode status" unless %w[supported unverified].include?(value.dig("sdk", "xcodeStatus"))
abort "fresh sources" unless value.dig("officialSources", "status") == "current"
sk = value.dig("infoPlist", "skAdNetwork")
abort "SKAdNetwork drift not reported" unless sk["status"] == "drift" && sk["missingFromApp"].length == 49 && sk["notInOfficialList"].empty?
abort "privacy manifest" unless value.dig("privacy", "appPrivacyManifest", "status") == "missing"
abort "data use" unless value.dig("privacy", "appStoreDataUse", "dataUseCategories") == ["advertising-data", "device-id"]
abort "data use without a manifest must stay unverified" unless value.dig("privacy", "appStoreDataUse", "manifestConsistency", "status") == "unverified"
abort "SDK manifests must stay unverified" unless value.dig("privacy", "sdkPrivacyManifests", "status") == "unverified"
expected = {"offlineFixture" => "not-run", "googleDemoSmoke" => "not-run", "admobRemote" => "unverified", "productionRelease" => "unverified"}
abort "evidence defaults" unless value["evidence"].transform_values { |entry| entry["status"] } == expected &&
  value["evidence"].values.all? { |entry| entry["source"] == "none" }
abort "report leaked an AdMob identifier" if File.binread(ARGV.fetch(0)).include?("ca-app-pub-")
RUBY

# Freshness compares elapsed seconds: exactly 30 days is current, one second later needs a recheck.
for offset in "$((30 * 86400)):current" "$((30 * 86400 + 1)):recheck-required" "$((40 * 86400)):recheck-required"; do
  now=$(ruby -rtime -e 'puts (Time.iso8601(ARGV[0]) + Integer(ARGV[1])).utc.iso8601' "$checked_at" "${offset%%:*}")
  IOS_TEMPLATE_ADMOB_READINESS_NOW="$now" readiness | ruby -rjson -e '
    status = JSON.parse(STDIN.read).dig("officialSources", "status")
    abort "official sources at +#{ARGV[0]}s were #{status}, expected #{ARGV[1]}" unless status == ARGV[1]
  ' "${offset%%:*}" "${offset#*:}"
done

manifest="$derived/GardenNotes/PrivacyInfo.xcprivacy"
write_manifest() {
  local tracking=$1 type entries=''
  shift
  for type in "$@"; do
    entries+="<dict><key>NSPrivacyCollectedDataType</key><string>$type</string></dict>"
  done
  cat >"$manifest" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>NSPrivacyTracking</key><$tracking/>
<key>NSPrivacyCollectedDataTypes</key><array>$entries</array>
</dict></plist>
PLIST
}
# The manifest's collected data types are compared with the recorded categories (advertising-data, device-id).
assert_consistency() {
  readiness | ruby -rjson -e '
    value = JSON.parse(STDIN.read).dig("privacy", "appStoreDataUse", "manifestConsistency")
    expected = JSON.parse(ARGV.fetch(0))
    abort "manifest consistency #{value}, expected #{expected}" unless expected.all? { |key, entry| value[key] == entry }
  ' "$1"
}
write_manifest false NSPrivacyCollectedDataTypeDeviceID
readiness | ruby -rjson -e 'v = JSON.parse(STDIN.read).dig("privacy", "appPrivacyManifest"); abort "manifest #{v}" unless v["status"] == "present" && v["collectedDataTypes"] == ["NSPrivacyCollectedDataTypeDeviceID"]'
assert_consistency '{"status":"drift","missingFromManifest":["advertising-data"],"notInRecord":[],"unmappedManifestTypes":[]}'
write_manifest false NSPrivacyCollectedDataTypeDeviceID NSPrivacyCollectedDataTypeAdvertisingData
assert_consistency '{"status":"match","missingFromManifest":[],"notInRecord":[],"unmappedManifestTypes":[],"unknownRecordCategories":[]}'
write_manifest false NSPrivacyCollectedDataTypeDeviceID NSPrivacyCollectedDataTypeAdvertisingData NSPrivacyCollectedDataTypeCrashData NSPrivacyCollectedDataTypeUnknownKind
assert_consistency '{"status":"drift","missingFromManifest":[],"notInRecord":["crash-data"],"unmappedManifestTypes":["NSPrivacyCollectedDataTypeUnknownKind"]}'
write_manifest true NSPrivacyCollectedDataTypeDeviceID NSPrivacyCollectedDataTypeAdvertisingData
readiness | grep -q '"status":"tracking-inconsistent"' || fail 'a tracking privacy manifest was not reported'
rm -f "$manifest"

evidence="$temp_root/evidence.json"
printf '%s\n' "{\"schemaVersion\":1,\"classes\":{\"googleDemoSmoke\":{\"status\":\"passed\",\"recordedAt\":\"$checked_at\",\"summary\":\"Debug demo banner rendered on the dedicated iPhone\"}}}" >"$evidence"
readiness --evidence "$evidence" | ruby -rjson -e '
  evidence = JSON.parse(STDIN.read).fetch("evidence")
  abort "supplied class" unless evidence["googleDemoSmoke"].values_at("status", "source") == ["passed", "supplied"]
  others = evidence.reject { |name, _| name == "googleDemoSmoke" }
  abort "another class was inferred" unless others.values.all? { |entry| entry["source"] == "none" } &&
    others.transform_values { |entry| entry["status"] } == {"offlineFixture" => "not-run", "admobRemote" => "unverified", "productionRelease" => "unverified"}
'
for bad in \
  '{"schemaVersion":1,"classes":{"liveRevenue":{"status":"passed","recordedAt":"2026-01-01T00:00:00Z","summary":"x"}}}' \
  '{"schemaVersion":1,"classes":{"googleDemoSmoke":{"status":"skipped","recordedAt":"2026-01-01T00:00:00Z","summary":"x"}}}' \
  '{"schemaVersion":1,"classes":{"admobRemote":{"status":"passed","recordedAt":"2026-01-01T00:00:00Z","summary":"unit ca-app-pub-1234567890123456/0987654321"}}}'; do
  printf '%s\n' "$bad" >"$evidence"
  expect_failure bad-evidence readiness --evidence "$evidence"
done

packages="$temp_root/source-packages/artifacts"
for name in GoogleMobileAds UserMessagingPlatform; do
  for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    mkdir -p "$packages/$name/$name.xcframework/$slice/$name.framework"
    printf '%s\n' '<plist/>' >"$packages/$name/$name.xcframework/$slice/$name.framework/PrivacyInfo.xcprivacy"
  done
done
mkdir -p "$packages/GoogleMobileAds/GoogleMobileAds.xcframework/_CodeSignature"
printf '%s\n' 'signed' >"$packages/GoogleMobileAds/GoogleMobileAds.xcframework/_CodeSignature/CodeResources"
readiness --source-packages "$temp_root/source-packages" | ruby -rjson -e '
  value = JSON.parse(STDIN.read).dig("privacy", "sdkPrivacyManifests")
  statuses = value["packages"].to_h { |entry| [entry["name"], entry["status"]] }
  abort "unsigned UMP not reported: #{value}" unless value["status"] == "mismatch" && statuses == {"GoogleMobileAds" => "present", "UserMessagingPlatform" => "signature-missing"}
'
mkdir -p "$packages/UserMessagingPlatform/UserMessagingPlatform.xcframework/_CodeSignature"
printf '%s\n' 'signed' >"$packages/UserMessagingPlatform/UserMessagingPlatform.xcframework/_CodeSignature/CodeResources"
readiness --source-packages "$temp_root/source-packages" | grep -q '"sdkPrivacyManifests":{"packages":\[[^]]*\],"status":"present"}' ||
  fail 'signed SDK packages with privacy manifests were not reported present'

printf '\n// drift\n' >>"$core"
expect_failure readiness-after-drift readiness
restore_activation
"$repo_root/tools/validate-admob-integration.sh" --root "$derived" >/dev/null

# #374: an app that already uses its own Info.plist file (INFOPLIST_FILE with GENERATE_INFOPLIST_FILE = YES,
# like an app with HealthKit usage strings, URL schemes, and background modes) keeps that file and every key in
# it; activation only adds the two advertising keys, and each configuration still has one INFOPLIST_FILE.
new_clone() {
  local destination=$1 branch=$2
  git clone -q "$remote" "$destination"
  git -C "$destination" config user.name 'iOS Template Test'
  git -C "$destination" config user.email 'test@example.invalid'
  git -C "$destination" checkout -qb "$branch"
}
# Points the application Debug and Release configurations at the given Info.plist files; a third argument
# adds a second INFOPLIST_FILE line to Debug.
set_info_plist_file() {
  ruby -I"$repo_root/tools/lib" -radmob-activation - "$@" <<'RUBY'
path, debug, release, extra = ARGV
bytes = File.binread(path)
IOSTemplate::AdMobActivation.application_configurations(bytes, "GardenNotes").each do |name, (_, block)|
  lines = "\t\t\t\tINFOPLIST_FILE = #{name == 'Debug' ? debug : release};\n"
  lines += "\t\t\t\tINFOPLIST_FILE = #{extra};\n" if extra && name == "Debug"
  anchor = "\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n"
  changed = block.sub(anchor, anchor + lines)
  abort "#{name} has no GENERATE_INFOPLIST_FILE anchor" if changed == block
  bytes = bytes.sub(block, changed)
end
File.binwrite(path, bytes)
RUBY
}
write_app_info_plist() {
  cat >"$1" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSHealthShareUsageDescription</key>
	<string>Reads caffeine &amp; water intake from Health.</string>
	<key>NSHealthUpdateUsageDescription</key>
	<string>Saves caffeine intake to Health.</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.example.GardenNotes</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>gardennotes</string>
			</array>
		</dict>
	</array>
	<key>UIBackgroundModes</key>
	<array>
		<string>remote-notification</string>
	</array>
</dict>
</plist>
PLIST
}
plist_json_without_ads() {
  plutil -convert json -o - "$1" | ruby -rjson -e 'value = JSON.parse(STDIN.read); value.delete("GADApplicationIdentifier"); value.delete("SKAdNetworkItems"); puts JSON.generate(value.sort.to_h)'
}

own_plist_derived="$temp_root/own-plist-derived"
new_clone "$own_plist_derived" codex/test-admob-own-info-plist
write_app_info_plist "$own_plist_derived/GardenNotes/Info.plist"
set_info_plist_file "$own_plist_derived/GardenNotes.xcodeproj/project.pbxproj" GardenNotes/Info.plist GardenNotes/Info.plist
git -C "$own_plist_derived" add -A
git -C "$own_plist_derived" commit -qm 'fixture app-owned Info.plist'
app_keys_before=$(plist_json_without_ads "$own_plist_derived/GardenNotes/Info.plist")
app_settings_report "$own_plist_derived/GardenNotes.xcodeproj/project.pbxproj" >"$temp_root/own-source-settings.txt"
"$repo_root/tools/activate-admob-integration.sh" --root "$own_plist_derived" --input "$input" >/dev/null ||
  fail 'activation refused an app with its own INFOPLIST_FILE'
"$repo_root/tools/validate-admob-integration.sh" --root "$own_plist_derived" >/dev/null || fail 'an app with its own INFOPLIST_FILE did not validate'
own_plist="$own_plist_derived/GardenNotes/Info.plist"
[[ "$(plist_json_without_ads "$own_plist")" == "$app_keys_before" ]] || fail 'activation changed the app-owned Info.plist keys'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :GADApplicationIdentifier' "$own_plist")" == '$(ADMOB_APPLICATION_IDENTIFIER)' ]] || fail 'the app-owned Info.plist did not get the App ID reference'
[[ "$(plutil -extract SKAdNetworkItems json -o - "$own_plist")" == '[{"SKAdNetworkIdentifier":"cstr6suwn9.skadnetwork"}]' ]] || fail 'the app-owned Info.plist did not get SKAdNetworkItems'
head -1 "$own_plist" | grep -Fqx '<?xml version="1.0" encoding="UTF-8"?>' || fail 'the app-owned Info.plist is no longer an XML property list'
[[ ! -e "$own_plist_derived/GardenNotes/AdMob/Info.plist" ]] || fail 'activation added a second Info.plist for an app that has one'
app_settings_report "$own_plist_derived/GardenNotes.xcodeproj/project.pbxproj" >"$temp_root/own-activated-settings.txt"
for configuration in Debug Release; do
  [[ "$(grep -c "^$configuration INFOPLIST_FILE = " "$temp_root/own-activated-settings.txt")" == 1 ]] || fail "$configuration does not have exactly one INFOPLIST_FILE"
  grep -Fqx "$configuration INFOPLIST_FILE = GardenNotes/Info.plist;" "$temp_root/own-activated-settings.txt" || fail "$configuration no longer uses the app-owned Info.plist"
done
{
  cat "$temp_root/own-source-settings.txt"
  printf '%s\n' \
    'Debug ADMOB_APPLICATION_IDENTIFIER = "ca-app-pub-3940256099942544~1458002511";' \
    'Release ADMOB_APPLICATION_IDENTIFIER = "ca-app-pub-1234567890123456~1234567890";'
} | LC_ALL=C sort >"$temp_root/own-expected-settings.txt"
LC_ALL=C sort "$temp_root/own-activated-settings.txt" | cmp -s - "$temp_root/own-expected-settings.txt" ||
  fail 'activation changed the Info.plist settings of an app with its own INFOPLIST_FILE'
git -C "$own_plist_derived" diff --name-only HEAD | grep -Fqx 'GardenNotes/Info.plist' || fail 'the app-owned Info.plist change is not part of the activation'
# The app may keep editing its own Info.plist; only the advertising keys are checked.
plutil -insert NSCameraUsageDescription -string 'Capture garden photos' "$own_plist"
"$repo_root/tools/validate-admob-integration.sh" --root "$own_plist_derived" >/dev/null || fail 'an unrelated key in the app-owned Info.plist broke validation'
plutil -replace NSHealthShareUsageDescription -string 'Reads caffeine intake from Health.' "$own_plist"
"$repo_root/tools/validate-admob-integration.sh" --root "$own_plist_derived" >/dev/null || fail 'an edited app key in the app-owned Info.plist broke validation'
plutil -replace GADApplicationIdentifier -string 'ca-app-pub-1234567890123456~1234567890' "$own_plist"
expect_failure own-plist-literal-app-id "$repo_root/tools/validate-admob-integration.sh" --root "$own_plist_derived"
grep -Fq 'GardenNotes/Info.plist GADApplicationIdentifier must be $(ADMOB_APPLICATION_IDENTIFIER)' "$temp_root/own-plist-literal-app-id.stderr" ||
  fail "a literal App ID in the app-owned Info.plist failed for another reason: $(<"$temp_root/own-plist-literal-app-id.stderr")"
plutil -replace GADApplicationIdentifier -string '$(ADMOB_APPLICATION_IDENTIFIER)' "$own_plist"
plutil -insert NSUserTrackingUsageDescription -string 'Track' "$own_plist"
expect_failure own-plist-att "$repo_root/tools/validate-admob-integration.sh" --root "$own_plist_derived"
grep -Fq 'GardenNotes/Info.plist must not declare ATT usage' "$temp_root/own-plist-att.stderr" || fail "ATT in the app-owned Info.plist failed for another reason: $(<"$temp_root/own-plist-att.stderr")"

# A synchronized app folder that already excludes a file from the application target keeps that exception
# and gains the ad-only plist in the same exception set.
exception_derived="$temp_root/exception-derived"
new_clone "$exception_derived" codex/test-admob-existing-exception
printf '%s\n' 'notes' >"$exception_derived/GardenNotes/Notes.md"
ruby - "$exception_derived/GardenNotes.xcodeproj/project.pbxproj" <<'RUBY'
path = ARGV.fetch(0)
bytes = File.binread(path)
target = bytes[/\t\t([A-F0-9]{24}) \/\* GardenNotes \*\/ = \{\n\t\t\tisa = PBXNativeTarget;/, 1] or abort "no application target"
group = bytes[/\t\t([A-F0-9]{24}) \/\* GardenNotes \*\/ = \{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;/, 1] or abort "no synchronized group"
set = "\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Exceptions for \"GardenNotes\" folder in \"GardenNotes\" target */ = {\n\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n\t\t\tmembershipExceptions = (\n\t\t\t\tNotes.md,\n\t\t\t);\n\t\t\ttarget = #{target} /* GardenNotes */;\n\t\t};\n"
bytes = bytes.sub("/* Begin PBXFileSystemSynchronizedRootGroup section */", "/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */\n#{set}/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */\n\n/* Begin PBXFileSystemSynchronizedRootGroup section */")
changed = bytes.sub("\t\t#{group} /* GardenNotes */ = {\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n", "\t\t#{group} /* GardenNotes */ = {\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\texceptions = (\n\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Exceptions for \"GardenNotes\" folder in \"GardenNotes\" target */,\n\t\t\t);\n")
abort "group anchor" if changed == bytes
File.binwrite(path, changed)
RUBY
git -C "$exception_derived" add -A
git -C "$exception_derived" commit -qm 'fixture existing membership exception'
# #375: this app places the banner at the top safe-area edge; the value is accepted and recorded.
# D-087 (#398): it also has a 16+ audience, which is accepted, recorded, generated, and capped at T.
top_input="$temp_root/top-input.json"
ruby -rjson -e 'value = JSON.parse(File.binread(ARGV[0])); value["placement"]["container"] = "safe-area-top"; value["audience"]["minimumAge"] = 16; File.binwrite(ARGV[1], JSON.generate(value) + "\n")' "$input" "$top_input"
"$repo_root/tools/activate-admob-integration.sh" --root "$exception_derived" --input "$top_input" >/dev/null || fail 'activation refused an app with an existing membership exception'
[[ "$(ruby -rjson -e 'puts JSON.parse(File.binread(ARGV[0])).fetch("activationInput").fetch("placement").fetch("container")' "$exception_derived/Config/admob-activation.json")" == safe-area-top ]] ||
  fail 'the top placement container was not recorded'
[[ "$(ruby -rjson -e 'puts JSON.parse(File.binread(ARGV[0])).fetch("activationInput").fetch("audience").fetch("minimumAge").inspect' "$exception_derived/Config/admob-activation.json")" == 16 ]] ||
  fail 'the 16+ audience was not recorded'
grep -Fxq '    static let minimumAudienceAge = 16' "$exception_derived/GardenNotes/AdMob/AdMobConfiguration.swift" || fail 'the 16+ audience was not generated'
grep -Fq 'requestConfiguration.maxAdContentRating = .teen' "$exception_derived/GardenNotes/AdMob/GoogleMobileAdsProvider.swift" || fail 'the provider does not cap the ad content rating below 18'
"$repo_root/tools/validate-admob-integration.sh" --root "$exception_derived" >/dev/null || fail 'an app with an existing membership exception did not validate'
# The validator requires the T cap in the activated sources of an audience under 18, even when the edit
# also rewrites the record's file digest.
exception_provider="$exception_derived/GardenNotes/AdMob/GoogleMobileAdsProvider.swift"
exception_record="$exception_derived/Config/admob-activation.json"
cp "$exception_provider" "$temp_root/exception-provider.pristine"
cp "$exception_record" "$temp_root/exception-record.pristine"
ruby -rdigest -rjson - "$exception_provider" "$exception_record" <<'RUBY'
provider, record = ARGV
bytes = File.binread(provider)
changed = bytes.sub("requestConfiguration.maxAdContentRating = .teen", "break")
abort "the provider has no T cap to remove" if changed == bytes
File.binwrite(provider, changed)
value = JSON.parse(File.binread(record))
value["fileDigests"]["GardenNotes/AdMob/GoogleMobileAdsProvider.swift"] = Digest::SHA256.hexdigest(changed)
File.binwrite(record, JSON.generate(value) + "\n")
RUBY
expect_failure rating-cap-removed "$repo_root/tools/validate-admob-integration.sh" --root "$exception_derived"
grep -Fq 'activated core and provider must cap the ad content rating at T for an audience under 18' "$temp_root/rating-cap-removed.stderr" ||
  fail "removing the T cap failed for another reason: $(<"$temp_root/rating-cap-removed.stderr")"
cp "$temp_root/exception-provider.pristine" "$exception_provider"
cp "$temp_root/exception-record.pristine" "$exception_record"
"$repo_root/tools/validate-admob-integration.sh" --root "$exception_derived" >/dev/null || fail 'the restored 16+ activation did not validate'
ruby -e '
bytes = File.binread(ARGV.fetch(0))
abort "exception sets: #{bytes.scan("isa = PBXFileSystemSynchronizedBuildFileExceptionSet;").length}" unless bytes.scan("isa = PBXFileSystemSynchronizedBuildFileExceptionSet;").length == 1
abort "membership exceptions were not merged" unless bytes.include?("membershipExceptions = (\n\t\t\t\tAdMob/Info.plist,\n\t\t\t\tNotes.md,\n\t\t\t);")
' "$exception_derived/GardenNotes.xcodeproj/project.pbxproj" || fail 'the existing membership exception set was not reused'

# #374: a project whose Info.plist the activation cannot keep stops before any change, with the reason.
refusal_case() {
  local label=$1 expected=$2 setup=$3 clone="$temp_root/refuse-$1"
  new_clone "$clone" "codex/test-admob-refuse-$label"
  "$setup" "$clone"
  git -C "$clone" add -A
  git -C "$clone" commit -qm "fixture $label"
  local head_before tree_before
  head_before=$(git -C "$clone" rev-parse HEAD)
  tree_before=$(find "$clone" -path "$clone/.git" -prune -o -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
  expect_failure "refuse-$label" "$repo_root/tools/activate-admob-integration.sh" --root "$clone" --input "$input"
  grep -Fq "$expected" "$temp_root/refuse-$label.stderr" || fail "refusal $label failed for another reason: $(<"$temp_root/refuse-$label.stderr")"
  [[ "$(git -C "$clone" rev-parse HEAD)" == "$head_before" && -z "$(git -C "$clone" status --porcelain=v1 --untracked-files=all)" ]] || fail "refusal $label changed the app"
  [[ "$(find "$clone" -path "$clone/.git" -prune -o -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')" == "$tree_before" ]] ||
    fail "refusal $label changed a file"
  [[ "$(git -C "$clone" worktree list --porcelain | grep -c '^worktree ')" == 1 ]] || fail "refusal $label left a staging worktree"
}
setup_different_app_id() {
  write_app_info_plist "$1/GardenNotes/Info.plist"
  plutil -insert GADApplicationIdentifier -string 'ca-app-pub-1234567890123456~1234567890' "$1/GardenNotes/Info.plist"
  set_info_plist_file "$1/GardenNotes.xcodeproj/project.pbxproj" GardenNotes/Info.plist GardenNotes/Info.plist
}
setup_different_networks() {
  write_app_info_plist "$1/GardenNotes/Info.plist"
  plutil -insert SKAdNetworkItems -json '[{"SKAdNetworkIdentifier":"4fzdc2evr5.skadnetwork"}]' "$1/GardenNotes/Info.plist"
  set_info_plist_file "$1/GardenNotes.xcodeproj/project.pbxproj" GardenNotes/Info.plist GardenNotes/Info.plist
}
setup_split_files() {
  write_app_info_plist "$1/GardenNotes/Info.plist"
  write_app_info_plist "$1/GardenNotes/Info-Release.plist"
  set_info_plist_file "$1/GardenNotes.xcodeproj/project.pbxproj" GardenNotes/Info.plist GardenNotes/Info-Release.plist
}
setup_one_side_only() {
  write_app_info_plist "$1/GardenNotes/Info.plist"
  ruby -I"$repo_root/tools/lib" -radmob-activation - "$1/GardenNotes.xcodeproj/project.pbxproj" <<'RUBY'
path = ARGV.fetch(0)
bytes = File.binread(path)
_, block = IOSTemplate::AdMobActivation.application_configurations(bytes, "GardenNotes").fetch("Release")
anchor = "\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n"
File.binwrite(path, bytes.sub(block, block.sub(anchor, anchor + "\t\t\t\tINFOPLIST_FILE = GardenNotes/Info.plist;\n")))
RUBY
}
setup_duplicate_file() {
  write_app_info_plist "$1/GardenNotes/Info.plist"
  write_app_info_plist "$1/GardenNotes/Other.plist"
  set_info_plist_file "$1/GardenNotes.xcodeproj/project.pbxproj" GardenNotes/Info.plist GardenNotes/Info.plist GardenNotes/Other.plist
}
setup_missing_file() {
  set_info_plist_file "$1/GardenNotes.xcodeproj/project.pbxproj" GardenNotes/Info.plist GardenNotes/Info.plist
}
setup_symlinked_file() {
  write_app_info_plist "$1/GardenNotes/Real.plist"
  ln -s Real.plist "$1/GardenNotes/Info.plist"
  set_info_plist_file "$1/GardenNotes.xcodeproj/project.pbxproj" GardenNotes/Info.plist GardenNotes/Info.plist
}
setup_att_usage() {
  write_app_info_plist "$1/GardenNotes/Info.plist"
  plutil -insert NSUserTrackingUsageDescription -string 'Track' "$1/GardenNotes/Info.plist"
  set_info_plist_file "$1/GardenNotes.xcodeproj/project.pbxproj" GardenNotes/Info.plist GardenNotes/Info.plist
}
setup_existing_sdk() {
  ruby -I"$repo_root/tools/lib" -radmob-activation - "$1/GardenNotes.xcodeproj/project.pbxproj" <<'RUBY'
path = ARGV.fetch(0)
identity = {"moduleName" => "GardenNotes", "bundleId" => "com.example.OwnAdIntegration"}
File.binwrite(path, IOSTemplate::AdMobActivation.add_package_dependency(File.binread(path), identity))
RUBY
}
refusal_case different-app-id 'GardenNotes/Info.plist already declares a different GADApplicationIdentifier' setup_different_app_id
refusal_case different-networks 'GardenNotes/Info.plist already declares SKAdNetworkItems that differ' setup_different_networks
refusal_case split-files 'Debug and Release use different INFOPLIST_FILE values' setup_split_files
refusal_case one-side-only 'Debug and Release use different INFOPLIST_FILE values (none, GardenNotes/Info.plist)' setup_one_side_only
refusal_case duplicate-file 'Debug configuration must declare at most one INFOPLIST_FILE' setup_duplicate_file
refusal_case missing-file 'INFOPLIST_FILE GardenNotes/Info.plist must identify an existing regular file' setup_missing_file
refusal_case symlinked-file 'INFOPLIST_FILE GardenNotes/Info.plist must not traverse a symlink' setup_symlinked_file
refusal_case att-usage 'GardenNotes/Info.plist declares NSUserTrackingUsageDescription' setup_att_usage
refusal_case existing-sdk 'the project already links Google Mobile Ads outside this activation' setup_existing_sdk

[[ "$(sha256_file "$repo_root/$live_module.xcodeproj/project.pbxproj")" == "$template_project_digest" ]] || fail "root $live_module project changed"
[[ "$(find "$repo_root/$live_module" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')" == "$template_source_digest" ]] || fail "root $live_module source changed"

# #345: the same checks pass in an app whose Identity bootstrap renamed the project. A disposable clone of
# this HEAD is bootstrapped as Trail Log and runs this test once more; the running repository is untouched.
if [[ -z "${IOS_TEMPLATE_ADMOB_ADOPTED_RUN-}" && ! -e "$repo_root/Config/app-identity.json" ]]; then
  before_head=$(git -C "$repo_root" rev-parse HEAD)
  before_status=$(git -C "$repo_root" status --porcelain)
  before_index=$(git -C "$repo_root" ls-files -s | shasum -a 256)
  xcrun swiftc -o "$temp_root/bootstrap-app" "$repo_root/tools/bootstrap-app.swift" >/dev/null 2>&1 || fail 'bootstrap tool did not compile'
  # TrailLog, and Debug, a valid module name that also labels the build configurations.
  for module in TrailLog Debug; do
    adopted="$temp_root/adopted-$module"
    git clone -q --no-hardlinks "$repo_root" "$adopted"
    git -C "$adopted" checkout -q --detach "$before_head"
    "$temp_root/bootstrap-app" apply --root "$adopted" --manifest "$adopted/Config/template-identity.json" \
      --display-name "$module App" --module-name "$module" --app-slug "$(tr '[:upper:]' '[:lower:]' <<<"$module")-app" \
      --bundle-id "com.example.$module" >/dev/null || fail "Identity bootstrap of the disposable clone as $module failed"
    [[ -f "$adopted/$module.xcodeproj/project.pbxproj" && ! -e "$adopted/TemplateApp.xcodeproj" ]] || fail "the disposable clone was not renamed to $module"
    git -C "$adopted" add -A
    git -C "$adopted" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
      -c gc.auto=0 -c maintenance.auto=false commit -q -m "Bootstrap $module"
    (cd "$adopted" && IOS_TEMPLATE_ADMOB_ADOPTED_RUN=1 bash tools/tests/test-admob-integration.sh >"$temp_root/adopted-$module.log" 2>&1) ||
      fail "the test failed in a project renamed to $module: $(tail -3 "$temp_root/adopted-$module.log")"
  done
  [[ "$(git -C "$repo_root" rev-parse HEAD)" == "$before_head" ]] || fail 'the running repository HEAD changed'
  [[ "$(git -C "$repo_root" status --porcelain)" == "$before_status" ]] || fail 'the running repository working tree changed'
  [[ "$(git -C "$repo_root" ls-files -s | shasum -a 256)" == "$before_index" ]] || fail 'the running repository index changed'
fi

echo 'test-admob-integration: PASS'
