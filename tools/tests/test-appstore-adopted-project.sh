#!/usr/bin/env bash
set -euo pipefail
export LANG=en_US.UTF-8

# #326: the App Store preparation and metadata-save tests build their sample app from the live project.
# A disposable clone of this template's HEAD becomes an app after Identity bootstrap (another module name
# and Bundle ID, recorded in Config/app-identity.json) whose app target signs with an entitlements file
# and links a remote Swift package with its workspace lock. Both tests must pass inside it.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby swiftc shasum

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ios-template-appstore-adopted.XXXXXX")"
work="$(cd "$work" && pwd -P)"
trap 'rm -rf -- "$work"' EXIT

fail() { echo "adopted App Store project: $*" >&2; exit 1; }

before_head="$(git -C "$repo_root" rev-parse HEAD)"
before_status="$(git -C "$repo_root" status --porcelain)"
before_index="$(git -C "$repo_root" ls-files -s | shasum -a 256)"

app="$work/app"
git clone -q --no-hardlinks "$repo_root" "$app"
git -C "$app" checkout -q --detach "$before_head"
swiftc -o "$work/bootstrap-app" "$app/tools/bootstrap-app.swift"
"$work/bootstrap-app" apply --root "$app" --manifest "$app/Config/template-identity.json" \
  --display-name 'Trail Log' --module-name TrailLog --app-slug trail-log --bundle-id com.example.TrailLog >/dev/null
[[ -f "$app/TrailLog.xcodeproj/project.pbxproj" && -f "$app/Config/app-identity.json" ]] || fail 'the Identity bootstrap did not rename the project'

/usr/bin/ruby -rjson -rfileutils - "$app" <<'RUBY'
app = ARGV.fetch(0)
pbx_path = File.join(app, "TrailLog.xcodeproj/project.pbxproj")
pbx = File.read(pbx_path)
# The app target's two build configurations sign with an entitlements file.
entitlements = "TrailLog/TrailLog.entitlements"
signed = pbx.gsub("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;", "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = #{entitlements};")
abort "entitlements did not reach both app configurations" unless signed.scan("CODE_SIGN_ENTITLEMENTS = #{entitlements};").length == 2
pbx = signed
File.write(File.join(app, entitlements), <<~PLIST)
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
  \t<key>com.apple.developer.weatherkit</key>
  \t<true/>
  </dict>
  </plist>
PLIST
# The app target links one product of a remote Swift package.
reference = "ADA0A0A0A0A0A0A0A0A0A0A1"
product = "ADA0A0A0A0A0A0A0A0A0A0A2"
build_file = "ADA0A0A0A0A0A0A0A0A0A0A3"
frameworks = "4E7ECA3730389D2700BBA255 /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n"
edits = [
  ["\t\t\tproductRefGroup =", "\t\t\tpackageReferences = (\n\t\t\t\t#{reference} /* XCRemoteSwiftPackageReference \"trail-kit\" */,\n\t\t\t);\n\t\t\tproductRefGroup ="],
  ["/* Begin PBXFileReference section */", "/* Begin PBXBuildFile section */\n\t\t#{build_file} /* TrailKit in Frameworks */ = {isa = PBXBuildFile; productRef = #{product} /* TrailKit */; };\n/* End PBXBuildFile section */\n\n/* Begin PBXFileReference section */"],
  [frameworks, "#{frameworks}\t\t\t\t#{build_file} /* TrailKit in Frameworks */,\n"],
  ["\t\t\tpackageProductDependencies = (\n\t\t\t);", "\t\t\tpackageProductDependencies = (\n\t\t\t\t#{product} /* TrailKit */,\n\t\t\t);"],
  ["/* Begin XCBuildConfiguration section */", <<~PBX + "/* Begin XCBuildConfiguration section */"]
    /* Begin XCRemoteSwiftPackageReference section */
    \t\t#{reference} /* XCRemoteSwiftPackageReference "trail-kit" */ = {
    \t\t\tisa = XCRemoteSwiftPackageReference;
    \t\t\trepositoryURL = "https://github.com/example/trail-kit.git";
    \t\t\trequirement = {
    \t\t\t\tkind = upToNextMajorVersion;
    \t\t\t\tminimumVersion = 1.0.0;
    \t\t\t};
    \t\t};
    /* End XCRemoteSwiftPackageReference section */

    /* Begin XCSwiftPackageProductDependency section */
    \t\t#{product} /* TrailKit */ = {
    \t\t\tisa = XCSwiftPackageProductDependency;
    \t\t\tpackage = #{reference} /* XCRemoteSwiftPackageReference "trail-kit" */;
    \t\t\tproductName = TrailKit;
    \t\t};
    /* End XCSwiftPackageProductDependency section */

  PBX
]
edits.each do |anchor, replacement|
  # The app target comes first, so the first empty packageProductDependencies list is the app's.
  abort "the project lacks the anchor for the package: #{anchor.lines.first.strip}" unless pbx.include?(anchor)
  pbx = pbx.sub(anchor) { replacement }
end
app_target = pbx[/^\t\t[0-9A-F]{24} \/\* TrailLog \*\/ = \{\n\t\t\tisa = PBXNativeTarget;.*?^\t\t\};$/m] or abort "the app target is missing"
abort "the package product is not the app target's" unless app_target.include?("#{product} /* TrailKit */,")
File.write(pbx_path, pbx)
lock = File.join(app, "TrailLog.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
FileUtils.mkdir_p(File.dirname(lock))
File.write(lock, JSON.pretty_generate({"originHash" => "0" * 64, "pins" => [{
  "identity" => "trail-kit", "kind" => "remoteSourceControl", "location" => "https://github.com/example/trail-kit.git",
  "state" => {"revision" => "a" * 40, "version" => "1.2.0"}
}], "version" => 3}) + "\n")
RUBY

git -C "$app" add -A
git -C "$app" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
  -c gc.auto=0 -c maintenance.auto=false commit -q -m 'Bootstrap Trail Log with entitlements and a Swift package'
[[ -z "$(git -C "$app" status --porcelain)" ]] || fail 'the adopted app is not clean'

for test in test-appstore-metadata-save.sh test-appstore-preparation.sh; do
  (cd "$app" && bash "tools/tests/$test" >"$work/$test.log" 2>&1) || fail "$test failed in the adopted app: $(tail -3 "$work/$test.log")"
done

[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$before_head" ]] || fail 'the running repository HEAD changed'
[[ "$(git -C "$repo_root" status --porcelain)" == "$before_status" ]] || fail 'the running repository working tree changed'
[[ "$(git -C "$repo_root" ls-files -s | shasum -a 256)" == "$before_index" ]] || fail 'the running repository index changed'

echo 'App Store tests pass in an adopted project with entitlements and a Swift package'
