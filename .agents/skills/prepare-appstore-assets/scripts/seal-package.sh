#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: $0 --repo DIR --package-root DIR --requirements FILE --bundle-id ID --version VERSION --source-sha SHA --build-digest DIGEST --verification-issue NUMBER --verification-base SHA --audit FILE --first-publication yes|no --legal-approval FILE|none --output FILE --now ISO8601" >&2
  exit 64
}

repo= package_root= requirements= bundle_id= version= source_sha= build_digest= audit= first_publication= legal_approval= output= now=
verification_issue= verification_base=
tool_root=$(cd "$(dirname "$0")/../../../.." && /bin/pwd -P)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2-}; shift 2 ;;
    --package-root) package_root=${2-}; shift 2 ;;
    --requirements) requirements=${2-}; shift 2 ;;
    --bundle-id) bundle_id=${2-}; shift 2 ;;
    --version) version=${2-}; shift 2 ;;
    --source-sha) source_sha=${2-}; shift 2 ;;
    --build-digest) build_digest=${2-}; shift 2 ;;
    --verification-issue) verification_issue=${2-}; shift 2 ;;
    --verification-base) verification_base=${2-}; shift 2 ;;
    --audit) audit=${2-}; shift 2 ;;
    --first-publication) first_publication=${2-}; shift 2 ;;
    --legal-approval) legal_approval=${2-}; shift 2 ;;
    --output) output=${2-}; shift 2 ;;
    --now) now=${2-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$repo" && -n "$package_root" && -n "$requirements" && -n "$bundle_id" && -n "$version" && -n "$source_sha" && -n "$build_digest" && -n "$audit" && -n "$first_publication" && -n "$legal_approval" && -n "$output" && -n "$now" ]] || usage
[[ "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9-]*([.][A-Za-z0-9][A-Za-z0-9-]*)+$ ]] || usage
[[ "$version" =~ ^[0-9]+([.][0-9]+){1,2}$ && "$source_sha" =~ ^[0-9a-f]{40}$ && "$build_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
[[ "$first_publication" == yes || "$first_publication" == no ]] || usage
[[ "$verification_issue" =~ ^[1-9][0-9]*$ && "$verification_base" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || usage
[[ -d "$repo" && ! -L "$repo" && -d "$package_root" && ! -L "$package_root" ]] || { echo 'repository or App Store package is unavailable' >&2; exit 1; }
repo=$(cd "$repo" && /bin/pwd -P); package_root=$(cd "$package_root" && /bin/pwd -P)
[[ "$package_root" == "$repo/App Store" ]] || { echo 'package root must be the repository App Store directory' >&2; exit 1; }
[[ -z "$(/usr/bin/find "$package_root" -type l -print -quit)" ]] || { echo 'package contains a symbolic link' >&2; exit 1; }
for variable in requirements audit; do
  value=${!variable}; [[ -f "$value" && ! -L "$value" ]] || { echo "$variable file is unavailable" >&2; exit 1; }
  directory=$(cd "$(dirname "$value")" && /bin/pwd -P); printf -v "$variable" '%s/%s' "$directory" "$(basename "$value")"
done
if [[ "$first_publication" == yes ]]; then
  [[ "$legal_approval" != none && -f "$legal_approval" && ! -L "$legal_approval" ]] || { echo 'first-publication legal approval is required' >&2; exit 1; }
  legal_directory=$(cd "$(dirname "$legal_approval")" && /bin/pwd -P); legal_approval="$legal_directory/$(basename "$legal_approval")"
else
  [[ "$legal_approval" == none ]] || { echo 'legal approval must be none when this is not the first publication' >&2; exit 1; }
fi
output_parent=$(cd "$(dirname "$output")" && /bin/pwd -P); output="$output_parent/$(basename "$output")"
[[ "$output" == "$package_root/submission/$version-package.json" ]] || { echo 'package manifest output path is invalid' >&2; exit 1; }
[[ ! -e "$output" && ! -L "$output" ]] || { echo 'package manifest already exists; refusing overwrite' >&2; exit 1; }

validator="$repo/tools/validate-appstore-package.sh"
[[ -x "$validator" ]] || { echo 'App Store package validator is unavailable' >&2; exit 1; }
validation=$(
  "$validator" --root "$package_root" --project-root "$repo" --bundle-id "$bundle_id" --version "$version" \
    --requirements "$requirements" --require-fresh --now "$now"
) || { echo 'App Store package validation failed' >&2; exit 1; }
[[ "$validation" == *'"status":"ready"'* ]] || { echo 'App Store package validation did not return ready' >&2; exit 1; }

PACKAGE_ROOT="$package_root" REQUIREMENTS="$requirements" AUDIT="$audit" APPROVAL="$legal_approval" OUTPUT="$output" \
BUNDLE_ID="$bundle_id" VERSION="$version" SOURCE_SHA="$source_sha" BUILD_DIGEST="$build_digest" \
FIRST_PUBLICATION="$first_publication" NOW="$now" VERIFICATION_REPO="$repo" VERIFICATION_ISSUE="$verification_issue" \
VERIFICATION_BASE="$verification_base" ruby -r"$tool_root/tools/lib/release-verification" <<'RUBY'
require "json"
require "digest"
require "time"

root=ENV.fetch("PACKAGE_ROOT")
requirements=ENV.fetch("REQUIREMENTS")
audit_path=ENV.fetch("AUDIT")
output=ENV.fetch("OUTPUT")
source_sha=ENV.fetch("SOURCE_SHA")
build_digest=ENV.fetch("BUILD_DIGEST")
bundle_id=ENV.fetch("BUNDLE_ID")
version=ENV.fetch("VERSION")
first_publication=ENV.fetch("FIRST_PUBLICATION")=="yes"
now=ENV.fetch("NOW")
Time.iso8601(now)
publisher=lambda do |value|
  temporary="#{output}.tmp.#{$$}"
  File.open(temporary,File::WRONLY|File::CREAT|File::EXCL,0600){|file| file.write(JSON.generate(value)+"\n"); file.flush; file.fsync}
  File.rename(temporary,output); File.chmod(0644,output)
  puts JSON.generate(value)
end
IOSTemplate::ReleaseVerification.with_full_proof(
  repo: ENV.fetch("VERIFICATION_REPO"), issue: Integer(ENV.fetch("VERIFICATION_ISSUE")),
  base: ENV.fetch("VERIFICATION_BASE"), head: source_sha, bundle: bundle_id, publish: publisher
) do |verification|

package_digest=lambda do
  entries=[]
  Dir.glob(File.join(root,"**","*"),File::FNM_DOTMATCH).sort.each do |path|
    next if [".",".."].include?(File.basename(path))
    relative=path.delete_prefix(root+File::SEPARATOR)
    next unless File.file?(path) && !File.symlink?(path)
    next if relative.match?(%r{\Asubmission/[0-9]+(?:\.[0-9]+){1,2}-(?:package|result)\.json\z})
    abort "package file has multiple hard links" unless File.stat(path).nlink==1
    entries << "#{relative}\0#{Digest::SHA256.file(path).hexdigest}\0"
  end
  "sha256:#{Digest::SHA256.hexdigest(entries.join)}"
end
digest=package_digest.call
requirements_digest="sha256:#{Digest::SHA256.file(requirements).hexdigest}"

screenshot_path=File.join(root,"screenshots","manifest.json")
abort "screenshot manifest is unavailable" unless File.file?(screenshot_path) && !File.symlink?(screenshot_path)
screenshots=JSON.parse(File.binread(screenshot_path))
abort "screenshot manifest identity mismatch" unless screenshots.is_a?(Hash) && screenshots["schemaVersion"]==1 &&
  screenshots["sourceSha"]==source_sha && screenshots["buildDigest"]==build_digest && screenshots["requirementsDigest"]==requirements_digest && screenshots["cases"].is_a?(Array)
seen={}
screenshots.fetch("cases").each do |entry|
  abort "screenshot manifest case is invalid" unless entry.is_a?(Hash) && entry["path"].is_a?(String) && entry["digest"].is_a?(String)
  relative=entry.fetch("path")
  abort "screenshot manifest path is unsafe" unless relative.match?(%r{\A(?:en-US|ja)/[a-z0-9.-]+/[0-9]{2}-[a-z0-9-]+\.png\z})
  absolute=File.join(root,"screenshots",relative); stat=File.lstat(absolute)
  abort "screenshot file is unsafe" unless stat.file? && !stat.symlink?
  actual="sha256:#{Digest::SHA256.file(absolute).hexdigest}"
  abort "screenshot digest mismatch" unless entry["digest"]==actual
  abort "screenshot path is duplicated" if seen[relative]; seen[relative]=true
end

legal_paths=%w[legal/privacy-policy.md legal/terms-of-use.md]
if first_publication
  legal_paths.each do |relative|
    text=File.binread(File.join(root,relative))
    abort "first-publication legal text is not confirmed" unless text.match?(/^Status: Confirmed$/)
  end
end

audit=JSON.parse(File.binread(audit_path))
audit_keys=%w[schemaVersion status role sourceSha buildDigest packageDigest findings]
abort "release audit schema is invalid" unless audit.is_a?(Hash) && audit.keys.sort==audit_keys.sort && audit["schemaVersion"]==1
abort "release audit is not approved" unless audit["status"]=="approved" && audit["role"]=="release-auditor" && audit["findings"]==[]
abort "release audit identity mismatch" unless audit["sourceSha"]==source_sha && audit["buildDigest"]==build_digest && audit["packageDigest"]==digest

approval_digest=nil
if first_publication
  approval_path=ENV.fetch("APPROVAL")
  approval=JSON.parse(File.binread(approval_path))
  approval_keys=%w[schemaVersion status scope bundleId version packageDigest approvedAt]
  abort "first-publication legal approval schema is invalid" unless approval.is_a?(Hash) && approval.keys.sort==approval_keys.sort && approval["schemaVersion"]==1
  abort "first-publication legal approval is invalid" unless approval["status"]=="approved" && approval["scope"]=="first-publication-legal" &&
    approval["bundleId"]==bundle_id && approval["version"]==version && approval["packageDigest"]==digest
  Time.iso8601(approval.fetch("approvedAt"))
  approval_digest="sha256:#{Digest::SHA256.file(approval_path).hexdigest}"
end

value={
  "schemaVersion"=>2,"status"=>"prepared","bundleId"=>bundle_id,"version"=>version,"sourceSha"=>source_sha,
  "verification"=>verification,
  "buildDigest"=>build_digest,"requirementsDigest"=>requirements_digest,
  "screenshotManifestDigest"=>"sha256:#{Digest::SHA256.file(screenshot_path).hexdigest}","packageDigest"=>digest,
  "auditDigest"=>"sha256:#{Digest::SHA256.file(audit_path).hexdigest}","firstPublication"=>first_publication,
  "legalApprovalDigest"=>approval_digest,"preparedAt"=>now
}
value
end
RUBY
