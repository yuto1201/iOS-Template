#!/bin/bash
set -euo pipefail

script_directory=$(cd "$(dirname "$0")" && pwd -P)

fail() {
  printf '%s\n' "validate-app-icon: $1" >&2
  exit 1
}

[[ $# -eq 2 && $1 == --root ]] || { echo 'usage: validate-app-icon.sh --root REPOSITORY' >&2; exit 2; }
root=${2:-}
[[ "$root" == /* && -d "$root" && ! -L "$root" ]] || fail 'repository root is invalid'
root=$(cd "$root" && /bin/pwd -P)
[[ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" == "$root" ]] || fail 'root is not a Git top-level'

identity="$root/Config/app-identity.json"
record="$root/Config/app-icon.json"
[[ -f "$identity" && ! -L "$identity" ]] || fail 'app identity is missing or unsafe'
[[ -f "$record" && ! -L "$record" ]] || fail 'app icon record is missing or unsafe'

metadata=$(ROOT="$root" IDENTITY="$identity" RECORD="$record" /usr/bin/ruby -rjson -e '
  def refuse(message); warn message; exit 1; end
  identity=JSON.parse(File.binread(ENV.fetch("IDENTITY"))) rescue refuse("app identity is invalid")
  identity_keys=%w[appSlug bundleId displayName moduleName schemaVersion sourceIdentityVersion]
  refuse("app identity schema differs") unless identity.is_a?(Hash) && identity.keys.sort == identity_keys.sort && identity["schemaVersion"] == 1 && identity["sourceIdentityVersion"] == 1
  record=JSON.parse(File.binread(ENV.fetch("RECORD"))) rescue refuse("app icon record is invalid")
  record_keys=%w[assetPath conceptId displayName format generator heightPixels promptSummary schemaVersion sha256 widthPixels]
  refuse("app icon record schema differs") unless record.is_a?(Hash) && record.keys.sort == record_keys.sort && record["schemaVersion"] == 1
  refuse("display name differs") unless record["displayName"] == identity["displayName"]
  refuse("concept ID is invalid") unless record["conceptId"].is_a?(String) && record["conceptId"].match?(/\A[a-z][a-z0-9-]{0,63}\z/)
  refuse("generator is invalid") unless record["generator"] == "builtin-imagegen"
  prompt=record["promptSummary"]
  refuse("prompt summary is invalid") unless prompt.is_a?(String) && prompt.bytesize.between?(1,4096) && !prompt.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/)
  secret_pattern=/(api[_ -]?key|secret[_ -]?key|service_role|-----begin [a-z ]*private key-----|password\s*=|token\s*=)/i
  refuse("prompt summary contains a credential pattern") if prompt.match?(secret_pattern)
  refuse("image metadata differs") unless record["widthPixels"] == 1024 && record["heightPixels"] == 1024 && record["format"] == "png"
  expected_path="#{identity.fetch("moduleName")}/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
  refuse("asset path differs") unless record["assetPath"] == expected_path
  refuse("sha256 is invalid") unless record["sha256"].is_a?(String) && record["sha256"].match?(/\Asha256:[0-9a-f]{64}\z/)
  asset=File.join(ENV.fetch("ROOT"),expected_path)
  refuse("asset is missing or unsafe") unless File.file?(asset) && !File.symlink?(asset) && File.stat(asset).nlink == 1
  refuse("asset escapes repository") unless File.realpath(asset).start_with?(ENV.fetch("ROOT")+File::SEPARATOR)
  contents_path=File.join(File.dirname(asset),"Contents.json")
  refuse("asset catalog is missing or unsafe") unless File.file?(contents_path) && !File.symlink?(contents_path)
  contents=JSON.parse(File.binread(contents_path)) rescue refuse("asset catalog is invalid")
  refuse("asset catalog schema differs") unless contents.is_a?(Hash) && contents.keys.sort == %w[images info]
  images=contents["images"]
  refuse("asset catalog images are invalid") unless images.is_a?(Array)
  default=images.select{|entry| entry.is_a?(Hash) && !entry.key?("appearances") && entry["idiom"] == "universal" && entry["platform"] == "ios" && entry["size"] == "1024x1024"}
  refuse("default app icon entry differs") unless default.length == 1 && default.first["filename"] == "AppIcon-1024.png"
  require "digest"
  refuse("asset digest differs") unless record["sha256"] == "sha256:#{Digest::SHA256.file(asset).hexdigest}"
  puts JSON.generate({"asset"=>asset,"assetPath"=>record["assetPath"],"conceptId"=>record["conceptId"],"digest"=>record["sha256"],"displayName"=>record["displayName"]})
') || fail 'record, identity, asset catalog, or digest did not validate'

asset=$(printf '%s' "$metadata" | jq -er '.asset | strings') || fail 'validated asset path is unavailable'
temporary=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-app-icon-validation.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT
/usr/bin/xcrun swiftc -parse-as-library "$script_directory/inspect-app-icon.swift" -o "$temporary/inspect-app-icon" >/dev/null 2>&1 || fail 'image inspector could not compile'
inspection=$("$temporary/inspect-app-icon" inspect "$asset") || fail 'app icon must be a 1024 x 1024 opaque PNG'
[[ "$(printf '%s' "$inspection" | jq -er '.widthPixels')" == 1024 && "$(printf '%s' "$inspection" | jq -er '.heightPixels')" == 1024 ]] || fail 'app icon dimensions differ'
[[ "$(printf '%s' "$inspection" | jq -er '.opaque')" == true && "$(printf '%s' "$inspection" | jq -er '.encodedHasAlpha')" == false ]] || fail 'app icon is not encoded as opaque'

printf '%s' "$metadata" | /usr/bin/ruby -rjson -e '
  value=JSON.parse(STDIN.read)
  puts JSON.generate({"assetPath"=>value.fetch("assetPath"),"conceptId"=>value.fetch("conceptId"),"displayName"=>value.fetch("displayName"),"sha256"=>value.fetch("digest"),"status"=>"valid"})
'
