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

template_project_digest=$(sha256_file "$repo_root/TemplateApp.xcodeproj/project.pbxproj")
template_source_digest=$(find "$repo_root/TemplateApp" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')

derived="$temp_root/derived-app"
mkdir -p "$derived/Config" "$derived/GardenNotes" "$derived/GardenNotesTests" "$derived/GardenNotesUITests" "$derived/tools/lib" "$derived/.agents/skills" "$derived/App Store/metadata"
cp "$repo_root/TemplateApp.xcodeproj/project.pbxproj" "$temp_root/project.pbxproj"
mkdir -p "$derived/GardenNotes.xcodeproj"
ruby - "$temp_root/project.pbxproj" "$derived/GardenNotes.xcodeproj/project.pbxproj" <<'RUBY'
source, destination = ARGV
bytes = File.binread(source)
bytes = bytes.gsub("TemplateApp", "GardenNotes")
bytes = bytes.gsub("com.yuto.GardenNotes", "com.example.GardenNotes")
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
bytes = IOSTemplate::AdMobActivation.mutate_project(File.binread(path), identity)
bytes = bytes.gsub("GoogleMobileAds", "ExamplePackage")
bytes = bytes.gsub(IOSTemplate::AdMobActivation::PACKAGE_URL, "https://example.invalid/example-package.git")
bytes = bytes.gsub(IOSTemplate::AdMobActivation::PACKAGE_VERSION, "1.2.3")
bytes = bytes.gsub("GENERATE_INFOPLIST_FILE = NO;", "GENERATE_INFOPLIST_FILE = YES;")
bytes = bytes.gsub(/^\s*INFOPLIST_FILE = GardenNotes\/AdMob\/Info-(?:Debug|Release)\.plist;\n/, "")
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
grep -Fq 'GardenNotes/AdMob/Info-Debug.plist' "$project" || fail 'Debug Info.plist route is missing'
grep -Fq 'GardenNotes/AdMob/Info-Release.plist' "$project" || fail 'Release Info.plist route is missing'

debug_plist="$derived/GardenNotes/AdMob/Info-Debug.plist"
release_plist="$derived/GardenNotes/AdMob/Info-Release.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :GADApplicationIdentifier' "$debug_plist")" == 'ca-app-pub-3940256099942544~1458002511' ]] || fail 'Debug App ID is not the official demo ID'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :GADApplicationIdentifier' "$release_plist")" == 'ca-app-pub-1234567890123456~1234567890' ]] || fail 'Release App ID is not app-specific'
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
for path in "$record" "$release_plist" "$debug_plist" "$configuration" "$core"; do
  cp "$path" "$temp_root/$(basename "$path").pristine"
done
restore_activation() {
  for path in "$record" "$release_plist" "$debug_plist" "$configuration" "$core"; do
    cp "$temp_root/$(basename "$path").pristine" "$path"
  done
}
tamper_with_digest() {
  local label=$1 relative=$2 pattern=$3 replacement=$4 expected=$5
  ruby -rdigest -rjson - "$derived" "$relative" "$pattern" "$replacement" "$record" <<'RUBY'
root, relative, pattern, replacement, record_path = ARGV
path = File.join(root, relative)
bytes = File.binread(path)
changed = bytes.sub(pattern, replacement)
abort "tamper pattern not found: #{pattern}" if changed == bytes
File.binwrite(path, changed)
value = JSON.parse(File.binread(record_path))
value["fileDigests"][relative] = Digest::SHA256.hexdigest(changed)
File.binwrite(record_path, JSON.generate(value) + "\n")
RUBY
  expect_failure "$label" "$repo_root/tools/validate-admob-integration.sh" --root "$derived"
  grep -Fq "$expected" "$temp_root/$label.stderr" || fail "$label failed for another reason: $(<"$temp_root/$label.stderr")"
  restore_activation
}
tamper_with_digest release-plist-app-id GardenNotes/AdMob/Info-Release.plist \
  'ca-app-pub-1234567890123456~1234567890' 'ca-app-pub-1234567890123456~1111111111' \
  'Info-Release.plist GADApplicationIdentifier differs from the activation record'
tamper_with_digest release-plist-demo GardenNotes/AdMob/Info-Release.plist \
  'ca-app-pub-1234567890123456~1234567890' 'ca-app-pub-3940256099942544~1458002511' \
  'Info-Release.plist GADApplicationIdentifier differs from the activation record'
tamper_with_digest release-config-unit GardenNotes/AdMob/AdMobConfiguration.swift \
  'ca-app-pub-1234567890123456/0987654321' 'ca-app-pub-1234567890123456/0000000001' \
  'Release identifiers in AdMobConfiguration.swift differ from the activation record'
tamper_with_digest release-config-demo GardenNotes/AdMob/AdMobConfiguration.swift \
  'ca-app-pub-1234567890123456/0987654321' 'ca-app-pub-3940256099942544/2435281174' \
  'Release identifiers in AdMobConfiguration.swift differ from the activation record'
tamper_with_digest debug-config-production GardenNotes/AdMob/AdMobConfiguration.swift \
  'ca-app-pub-3940256099942544/2435281174' 'ca-app-pub-1234567890123456/0987654321' \
  'Debug identifiers in AdMobConfiguration.swift differ from the activation record'
tamper_with_digest skadnetwork-extra GardenNotes/AdMob/Info-Release.plist \
  '<string>cstr6suwn9.skadnetwork</string>' '<string>cstr6suwn9.skadnetwork</string></dict><dict><key>SKAdNetworkIdentifier</key><string>4fzdc2evr5.skadnetwork</string>' \
  'Info-Release.plist SKAdNetworkItems differ from the activation record'
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

[[ "$(sha256_file "$repo_root/TemplateApp.xcodeproj/project.pbxproj")" == "$template_project_digest" ]] || fail 'root TemplateApp project changed'
[[ "$(find "$repo_root/TemplateApp" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')" == "$template_source_digest" ]] || fail 'root TemplateApp source changed'

echo 'test-admob-integration: PASS'
