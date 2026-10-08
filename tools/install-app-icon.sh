#!/bin/bash
set -euo pipefail

script_directory=$(cd "$(dirname "$0")" && pwd -P)

fail() {
  printf '%s\n' "install-app-icon: $1" >&2
  exit 1
}

usage() {
  echo 'usage: install-app-icon.sh --root REPOSITORY --source PNG --concept-id ID --prompt-file FILE --generator builtin-imagegen|builtin-imagegen-reference-edit [--reference-image FILE --reference-rights user-confirmed] [--replace-accepted sha256:HEX --selection FILE]' >&2
  exit 2
}

root='' source_file='' concept_id='' prompt_file='' generator=''
reference_image='' reference_rights='' replace_accepted='' selection_file=''
seen=' '
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 && "$seen" != *" $1 "* ]] || usage
  seen="$seen$1 "
  case "$1" in
    --root) root=$2 ;;
    --source) source_file=$2 ;;
    --concept-id) concept_id=$2 ;;
    --prompt-file) prompt_file=$2 ;;
    --generator) generator=$2 ;;
    --reference-image) reference_image=$2 ;;
    --reference-rights) reference_rights=$2 ;;
    --replace-accepted) replace_accepted=$2 ;;
    --selection) selection_file=$2 ;;
    *) usage ;;
  esac
  shift 2
done
for required in --root --source --concept-id --prompt-file --generator; do
  [[ "$seen" == *" $required "* ]] || usage
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
case "$generator" in
  builtin-imagegen)
    [[ "$seen" != *' --reference-image '* && "$seen" != *' --reference-rights '* ]] || fail 'reference inputs require the builtin-imagegen-reference-edit generator'
    ;;
  builtin-imagegen-reference-edit)
    [[ "$reference_rights" == user-confirmed ]] || fail 'reference image rights must be explicitly confirmed by the user'
    [[ "$reference_image" == /* && -f "$reference_image" && ! -L "$reference_image" ]] || fail 'reference image must be an absolute regular non-symlink file'
    ;;
  *) fail 'generator must be builtin-imagegen or builtin-imagegen-reference-edit' ;;
esac
replacing=false
if [[ "$seen" == *' --replace-accepted '* || "$seen" == *' --selection '* ]]; then
  [[ "$replace_accepted" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'replacement must declare the accepted sha256 digest'
  [[ "$selection_file" == /* && -f "$selection_file" && ! -L "$selection_file" ]] || fail 'replacement requires an absolute regular non-symlink selection file'
  replacing=true
fi
source_raw_digest="sha256:$(/usr/bin/shasum -a 256 "$source_file" | /usr/bin/awk '{print $1}')"
reference_digest=''
if [[ -n "$reference_image" ]]; then
  reference_real="$(cd "$(dirname "$reference_image")" && /bin/pwd -P)/$(basename "$reference_image")"
  if [[ "$reference_real" == "$root"/* ]]; then
    reference_relative=${reference_real#"$root"/}
    ! git -C "$root" ls-files --error-unmatch -- "$reference_relative" >/dev/null 2>&1 || fail 'reference image must not be tracked by Git'
    git -C "$root" check-ignore -q -- "$reference_relative" || fail 'reference image inside the repository must be ignored by Git'
  fi
  reference_digest="sha256:$(/usr/bin/shasum -a 256 "$reference_image" | /usr/bin/awk '{print $1}')"
  [[ "$reference_digest" != "$source_raw_digest" ]] || fail 'source must be a generated edit, not the reference image itself'
fi

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
    if [[ -e "$temporary/original-asset.png" ]]; then
      /bin/cp -f "$temporary/original-asset.png" "$asset"
    elif [[ -e "$asset" && ! -e "$temporary/preexisting-asset" ]]; then
      /bin/rm -f "$asset"
    fi
    if [[ -e "$temporary/original-record.json" ]]; then
      /bin/cp -f "$temporary/original-record.json" "$record"
    elif [[ -e "$record" && ! -e "$temporary/preexisting-record" ]]; then
      /bin/rm -f "$record"
    fi
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

# A replacement binds the caller's declared accepted digest, the user's explicit selection record for a new
# immutable revision, and the selected candidate bytes before any repository file changes.
selection_revision='' supersedes='' replacement_mode=''
if [[ "$replacing" == true ]]; then
  [[ -f "$record" && ! -L "$record" && -f "$asset" && ! -L "$asset" ]] || fail 'replacement requires an accepted app icon'
  "$script_directory/validate-app-icon.sh" --root "$root" >/dev/null 2>&1 || fail 'the accepted app icon must validate before replacement'
  selection_revision=$(SELECTION="$selection_file" SOURCE="$source_file" CONCEPT_ID="$concept_id" SOURCE_DIGEST="$source_raw_digest" /usr/bin/ruby -rjson -e '
    def refuse(message); warn message; exit 1; end
    value=JSON.parse(File.binread(ENV.fetch("SELECTION"))) rescue refuse("selection is invalid")
    refuse("selection schema differs") unless value.is_a?(Hash) && value.keys.sort == %w[candidates revision schemaVersion selectedConceptId selection] && value["schemaVersion"] == 1
    refuse("selection revision is invalid") unless value["revision"].is_a?(String) && value["revision"].match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/)
    refuse("selection must record the user explicit choice") unless value["selection"] == "user-explicit"
    candidates=value["candidates"]
    refuse("selection candidates are invalid") unless candidates.is_a?(Array) && candidates.length.between?(1,4) && candidates.all?{|entry| entry.is_a?(Hash) && entry.keys.sort == %w[conceptId sha256] && entry["conceptId"].is_a?(String) && entry["conceptId"].match?(/\A[a-z][a-z0-9-]{0,63}\z/) && entry["sha256"].is_a?(String) && entry["sha256"].match?(/\Asha256:[0-9a-f]{64}\z/)}
    refuse("selection candidates are not unique") unless candidates.map{|entry| entry["conceptId"]}.uniq.length == candidates.length && candidates.map{|entry| entry["sha256"]}.uniq.length == candidates.length
    selected=candidates.find{|entry| entry["conceptId"] == value["selectedConceptId"]} or refuse("selected concept is not a candidate")
    refuse("concept ID differs from the explicit selection") unless value["selectedConceptId"] == ENV.fetch("CONCEPT_ID")
    refuse("source is not the selected candidate") unless selected["sha256"] == ENV.fetch("SOURCE_DIGEST")
    directory=File.dirname(File.realpath(ENV.fetch("SELECTION")))
    refuse("source is not stored in the selection revision") unless File.dirname(File.realpath(ENV.fetch("SOURCE"))) == directory && File.basename(directory) == value["revision"]
    puts value["revision"]
  ') || fail 'the explicit selection does not bind the source candidate'
  accepted=$(RECORD="$record" /usr/bin/ruby -rjson -e '
    value=JSON.parse(File.binread(ENV.fetch("RECORD")))
    puts JSON.generate({"current"=>{"conceptId"=>value.fetch("conceptId"),"generator"=>value.fetch("generator"),"sha256"=>value.fetch("sha256")},"selectionRevision"=>value["selectionRevision"],"supersedes"=>value["supersedes"]})
  ') || fail 'accepted app icon record is invalid'
  if [[ "$(printf '%s' "$accepted" | jq -er '.current.sha256')" == "$replace_accepted" ]]; then
    replacement_mode=replace
    supersedes=$(printf '%s' "$accepted" | jq -ce '.current')
    [[ "$digest" != "$replace_accepted" ]] || fail 'replacement must change the accepted icon'
    [[ "$(printf '%s' "$accepted" | jq -r '.selectionRevision // ""')" != "$selection_revision" ]] || fail 'replacement must come from a new selection revision'
    # Each accepted replacement commits its record, so the record's Git history names every revision
    # that was ever accepted, not only the current one.
    used_revisions=$(ROOT="$root" /usr/bin/ruby -rjson -e '
      root=ENV.fetch("ROOT")
      commits=IO.popen(["git","-C",root,"log","--format=%H","--","Config/app-icon.json"],&:read)
      exit 1 unless $?.success?
      commits.split.each do |commit|
        blob=IO.popen(["git","-C",root,"show","#{commit}:Config/app-icon.json"],err: File::NULL,&:read)
        next unless $?.success?
        revision=(JSON.parse(blob)["selectionRevision"] rescue nil)
        puts revision if revision.is_a?(String)
      end
    ') || fail 'accepted app icon history could not be read'
    ! /usr/bin/grep -Fxq -- "$selection_revision" <<<"$used_revisions" || fail 'replacement must come from a new selection revision'
  elif [[ "$(printf '%s' "$accepted" | jq -r '.supersedes.sha256? // ""')" == "$replace_accepted" ]]; then
    replacement_mode=recheck
    supersedes=$(printf '%s' "$accepted" | jq -ce '.supersedes')
  else
    fail 'declared accepted digest differs from the current app icon'
  fi
fi

PROMPT="$prompt_file" DISPLAY_NAME="$display_name" CONCEPT_ID="$concept_id" GENERATOR="$generator" MODULE_NAME="$module_name" DIGEST="$digest" REFERENCE_DIGEST="$reference_digest" SELECTION_REVISION="$selection_revision" SUPERSEDES="$supersedes" /usr/bin/ruby -rjson -e '
  def refuse(message); warn message; exit 1; end
  # Read the summary as UTF-8 text: binary bytes would make valid_encoding? always true and stop
  # JSON.generate on any non-ASCII character.
  prompt=File.binread(ENV.fetch("PROMPT")).force_encoding(Encoding::UTF_8)
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
  reference=ENV.fetch("REFERENCE_DIGEST")
  supersedes=ENV.fetch("SUPERSEDES")
  unless reference.empty? && supersedes.empty?
    value["schemaVersion"]=2
    value["referenceSha256"]=reference.empty? ? nil : reference
    value["selectionRevision"]=supersedes.empty? ? nil : ENV.fetch("SELECTION_REVISION")
    value["supersedes"]=supersedes.empty? ? nil : JSON.parse(supersedes)
  end
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

if [[ "$replacing" == true ]]; then
  if [[ "$replacement_mode" == recheck ]]; then
    if /usr/bin/cmp -s "$record" "$temporary/app-icon.json" && /usr/bin/cmp -s "$asset" "$temporary/AppIcon-1024.png"; then
      committed=true
      trap - EXIT
      /bin/rm -rf -- "$temporary"
      printf '{"conceptId":"%s","resultRecordPath":"Config/app-icon.json","status":"already-complete"}\n' "$concept_id"
      exit 0
    fi
    fail 'declared accepted digest differs from the current app icon'
  fi
  [[ -z "$(git -C "$root" status --porcelain=v1)" ]] || fail 'caller worktree must be clean before replacement'
  /bin/cp "$asset" "$temporary/original-asset.png"
  /bin/cp "$record" "$temporary/original-record.json"
  /bin/mv "$temporary/AppIcon-1024.png" "$asset"
  /bin/mv "$temporary/Contents.json" "$contents"
  /bin/mv "$temporary/app-icon.json" "$record"
  "$script_directory/validate-app-icon.sh" --root "$root" >/dev/null || fail 'replaced app icon did not validate'
  committed=true
  trap - EXIT
  /bin/rm -rf -- "$temporary"
  printf '{"conceptId":"%s","resultRecordPath":"Config/app-icon.json","status":"replaced","supersedes":"%s"}\n' "$concept_id" "$replace_accepted"
  exit 0
fi

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
