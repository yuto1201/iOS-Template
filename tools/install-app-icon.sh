#!/bin/bash
set -euo pipefail

script_directory=$(cd "$(dirname "$0")" && pwd -P)

fail() {
  printf '%s\n' "install-app-icon: $1" >&2
  exit 1
}

usage() {
  echo 'usage: install-app-icon.sh --root REPOSITORY --source PNG --concept-id ID --prompt-file FILE --generator builtin-imagegen' >&2
  exit 2
}

root='' source_file='' concept_id='' prompt_file='' generator=''
[[ $# -eq 10 ]] || usage
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) [[ -z "$root" ]] || usage; root=${2:-}; shift 2 ;;
    --source) [[ -z "$source_file" ]] || usage; source_file=${2:-}; shift 2 ;;
    --concept-id) [[ -z "$concept_id" ]] || usage; concept_id=${2:-}; shift 2 ;;
    --prompt-file) [[ -z "$prompt_file" ]] || usage; prompt_file=${2:-}; shift 2 ;;
    --generator) [[ -z "$generator" ]] || usage; generator=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$root" == /* && -d "$root" && ! -L "$root" ]] || fail 'repository root is invalid'
root=$(cd "$root" && /bin/pwd -P)
[[ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" == "$root" ]] || fail 'root is not a Git top-level'
branch=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null) || fail 'must run on a symbolic branch'
default_branch=''
if default_ref=$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
  default_branch=${default_ref#refs/remotes/origin/}
elif git -C "$root" show-ref --verify --quiet refs/heads/main; then
  default_branch=main
elif git -C "$root" show-ref --verify --quiet refs/heads/master; then
  default_branch=master
fi
[[ -n "$default_branch" && "$branch" != "$default_branch" ]] || fail 'must not run on the default branch'
[[ "$source_file" == /* && -f "$source_file" && ! -L "$source_file" ]] || fail 'source must be an absolute regular non-symlink file'
[[ "$prompt_file" == /* && -f "$prompt_file" && ! -L "$prompt_file" ]] || fail 'prompt file must be an absolute regular non-symlink file'
[[ "$concept_id" =~ ^[a-z][a-z0-9-]{0,63}$ ]] || fail 'concept ID is invalid'
[[ "$generator" == builtin-imagegen ]] || fail 'generator must be builtin-imagegen'

identity="$root/Config/app-identity.json"
[[ -f "$identity" && ! -L "$identity" ]] || fail 'complete Identity bootstrap is required first'
identity_values=$(IDENTITY="$identity" /usr/bin/ruby -rjson -e '
  def refuse(message); warn message; exit 1; end
  value=JSON.parse(File.binread(ENV.fetch("IDENTITY"))) rescue refuse("app identity is invalid")
  keys=%w[appSlug bundleId displayName moduleName schemaVersion sourceIdentityVersion]
  refuse("app identity schema differs") unless value.is_a?(Hash) && value.keys.sort == keys.sort && value["schemaVersion"] == 1 && value["sourceIdentityVersion"] == 1
  %w[displayName moduleName appSlug bundleId].each{|key| refuse("app identity value is invalid") unless value[key].is_a?(String) && !value[key].empty?}
  puts JSON.generate(value)
') || fail 'app identity is invalid'
display_name=$(printf '%s' "$identity_values" | jq -er '.displayName | strings') || fail 'display name is invalid'
module_name=$(printf '%s' "$identity_values" | jq -er '.moduleName | strings') || fail 'module name is invalid'
[[ "$module_name" =~ ^[A-Za-z][A-Za-z0-9]{1,49}$ ]] || fail 'module name is unsafe'

asset_directory="$root/$module_name/Assets.xcassets/AppIcon.appiconset"
contents="$asset_directory/Contents.json"
record="$root/Config/app-icon.json"
asset="$asset_directory/AppIcon-1024.png"
[[ -d "$asset_directory" && ! -L "$asset_directory" && -f "$contents" && ! -L "$contents" ]] || fail 'AppIcon asset catalog is missing or unsafe'

temporary=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-app-icon-install.XXXXXX")
committed=false
rollback() {
  status=$?
  if [[ "$committed" != true ]]; then
    [[ ! -e "$temporary/original-contents.json" ]] || /bin/cp -f "$temporary/original-contents.json" "$contents"
    [[ ! -e "$asset" || -e "$temporary/preexisting-asset" ]] || /bin/rm -f "$asset"
    [[ ! -e "$record" || -e "$temporary/preexisting-record" ]] || /bin/rm -f "$record"
  fi
  /bin/rm -rf -- "$temporary"
  exit "$status"
}
trap rollback EXIT
[[ ! -e "$asset" && ! -L "$asset" ]] || touch "$temporary/preexisting-asset"
[[ ! -e "$record" && ! -L "$record" ]] || touch "$temporary/preexisting-record"
/bin/cp "$contents" "$temporary/original-contents.json"

/usr/bin/xcrun swiftc -parse-as-library "$script_directory/inspect-app-icon.swift" -o "$temporary/inspect-app-icon" >/dev/null 2>&1 || fail 'image inspector could not compile'
"$temporary/inspect-app-icon" prepare "$source_file" "$temporary/AppIcon-1024.png" >/dev/null || fail 'source must be a 1024 x 1024 PNG with no transparent pixels'
digest="sha256:$(/usr/bin/shasum -a 256 "$temporary/AppIcon-1024.png" | /usr/bin/awk '{print $1}')"

PROMPT="$prompt_file" DISPLAY_NAME="$display_name" CONCEPT_ID="$concept_id" GENERATOR="$generator" MODULE_NAME="$module_name" DIGEST="$digest" /usr/bin/ruby -rjson -e '
  def refuse(message); warn message; exit 1; end
  prompt=File.binread(ENV.fetch("PROMPT"))
  refuse("prompt summary is invalid") unless prompt.valid_encoding? && prompt.bytesize.between?(1,4096) && !prompt.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/)
  prompt=prompt.strip
  refuse("prompt summary is empty") if prompt.empty?
  secret_pattern=/(api[_ -]?key|secret[_ -]?key|service_role|-----begin [a-z ]*private key-----|password\s*=|token\s*=)/i
  refuse("prompt summary contains a credential pattern") if prompt.match?(secret_pattern)
  value={
    "schemaVersion"=>1,
    "displayName"=>ENV.fetch("DISPLAY_NAME"),
    "conceptId"=>ENV.fetch("CONCEPT_ID"),
    "promptSummary"=>prompt,
    "generator"=>ENV.fetch("GENERATOR"),
    "widthPixels"=>1024,
    "heightPixels"=>1024,
    "format"=>"png",
    "assetPath"=>"#{ENV.fetch("MODULE_NAME")}/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
    "sha256"=>ENV.fetch("DIGEST")
  }
  File.binwrite(ARGV.fetch(0),JSON.generate(value))
' "$temporary/app-icon.json" || fail 'prompt summary or record is invalid'

CONTENTS="$contents" /usr/bin/ruby -rjson -e '
  def refuse(message); warn message; exit 1; end
  value=JSON.parse(File.binread(ENV.fetch("CONTENTS"))) rescue refuse("asset catalog is invalid")
  refuse("asset catalog schema differs") unless value.is_a?(Hash) && value.keys.sort == %w[images info]
  images=value["images"]
  refuse("asset catalog images are invalid") unless images.is_a?(Array)
  default=images.select{|entry| entry.is_a?(Hash) && !entry.key?("appearances") && entry["idiom"] == "universal" && entry["platform"] == "ios" && entry["size"] == "1024x1024"}
  refuse("default app icon entry differs") unless default.length == 1
  default.first["filename"]="AppIcon-1024.png"
  File.binwrite(ARGV.fetch(0),JSON.pretty_generate(value)+"\n")
' "$temporary/Contents.json" || fail 'asset catalog could not be prepared'

if [[ -e "$record" || -L "$record" || -e "$asset" || -L "$asset" ]]; then
  [[ -f "$record" && ! -L "$record" && -f "$asset" && ! -L "$asset" ]] || fail 'existing app icon output is incomplete or unsafe'
  if /usr/bin/cmp -s "$record" "$temporary/app-icon.json" && /usr/bin/cmp -s "$asset" "$temporary/AppIcon-1024.png"; then
    "$script_directory/validate-app-icon.sh" --root "$root" >/dev/null || fail 'existing same-input app icon is invalid'
    committed=true
    trap - EXIT
    /bin/rm -rf -- "$temporary"
    printf '{"conceptId":"%s","resultRecordPath":"Config/app-icon.json","status":"already-complete"}\n' "$concept_id"
    exit 0
  fi
  fail 'an accepted app icon already exists for different input'
fi

[[ -z "$(git -C "$root" status --porcelain=v1)" ]] || fail 'caller worktree must be clean before first installation'
/bin/mv "$temporary/AppIcon-1024.png" "$asset"
/bin/mv "$temporary/Contents.json" "$contents"
/bin/mv "$temporary/app-icon.json" "$record"
"$script_directory/validate-app-icon.sh" --root "$root" >/dev/null || fail 'installed app icon did not validate'
committed=true
trap - EXIT
/bin/rm -rf -- "$temporary"
printf '{"conceptId":"%s","resultRecordPath":"Config/app-icon.json","status":"applied"}\n' "$concept_id"
