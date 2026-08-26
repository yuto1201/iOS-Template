#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: $0 --repo DIR --package-root DIR --package-manifest FILE --preflight FILE --audit FILE --result FILE --team-id ID --bundle-id ID --version VERSION --build-id ID --source-sha SHA --build-digest DIGEST --primary-model codex --section ID --remote-reference REF --readback-digest DIGEST --resume-readback yes|no --now ISO8601 [--submit-for-review yes|no]" >&2
  exit 64
}

repo= package_root= package_manifest= preflight= audit= result= team_id= bundle_id= version= build_id= source_sha= build_digest=
primary_model= section= remote_reference= readback_digest= resume_readback= now= submit_for_review=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2-}; shift 2 ;;
    --package-root) package_root=${2-}; shift 2 ;;
    --package-manifest) package_manifest=${2-}; shift 2 ;;
    --preflight) preflight=${2-}; shift 2 ;;
    --audit) audit=${2-}; shift 2 ;;
    --result) result=${2-}; shift 2 ;;
    --team-id) team_id=${2-}; shift 2 ;;
    --bundle-id) bundle_id=${2-}; shift 2 ;;
    --version) version=${2-}; shift 2 ;;
    --build-id) build_id=${2-}; shift 2 ;;
    --source-sha) source_sha=${2-}; shift 2 ;;
    --build-digest) build_digest=${2-}; shift 2 ;;
    --primary-model) primary_model=${2-}; shift 2 ;;
    --section) section=${2-}; shift 2 ;;
    --remote-reference) remote_reference=${2-}; shift 2 ;;
    --readback-digest) readback_digest=${2-}; shift 2 ;;
    --resume-readback) resume_readback=${2-}; shift 2 ;;
    --now) now=${2-}; shift 2 ;;
    --submit-for-review) submit_for_review=${2-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$repo" && -n "$package_root" && -n "$package_manifest" && -n "$preflight" && -n "$audit" && -n "$result" && -n "$team_id" && -n "$bundle_id" && -n "$version" && -n "$build_id" && -n "$source_sha" && -n "$build_digest" && -n "$primary_model" && -n "$section" && -n "$remote_reference" && -n "$readback_digest" && -n "$resume_readback" && -n "$now" ]] || usage
[[ "$primary_model" == codex ]] || { echo 'primary model must be Codex for App Store operations' >&2; exit 1; }
[[ "$resume_readback" == yes || "$resume_readback" == no ]] || usage
[[ "$submit_for_review" == yes || "$submit_for_review" == no ]] || usage
[[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$build_digest" =~ ^sha256:[0-9a-f]{64}$ && "$readback_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
[[ "$version" =~ ^[0-9]+([.][0-9]+){1,2}$ && "$build_id" =~ ^[A-Za-z0-9._-]+$ ]] || usage
[[ "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9-]*([.][A-Za-z0-9][A-Za-z0-9-]*)+$ ]] || usage
[[ "$team_id" =~ ^[A-Za-z0-9._-]+$ && "$remote_reference" =~ ^asc://[A-Za-z0-9._/-]+$ ]] || usage
[[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || usage
[[ -d "$repo" && ! -L "$repo" && -d "$package_root" && ! -L "$package_root" ]] || { echo 'repository or package root is unavailable' >&2; exit 1; }
repo=$(cd "$repo" && /bin/pwd -P); package_root=$(cd "$package_root" && /bin/pwd -P)
[[ "$package_root" == "$repo/App Store" ]] || { echo 'package root is invalid' >&2; exit 1; }
for variable in package_manifest preflight audit; do
  value=${!variable}; [[ -f "$value" && ! -L "$value" ]] || { echo "$variable file is unavailable" >&2; exit 1; }
  directory=$(cd "$(dirname "$value")" && /bin/pwd -P); printf -v "$variable" '%s/%s' "$directory" "$(basename "$value")"
done
result_parent=$(cd "$(dirname "$result")" && /bin/pwd -P); result="$result_parent/$(basename "$result")"
[[ "$package_manifest" == "$package_root/submission/$version-package.json" && "$result" == "$package_root/submission/$version-result.json" ]] || {
  echo 'package manifest or submission result path is invalid' >&2; exit 1
}
[[ ! -L "$result" ]] || { echo 'submission result cannot be a symbolic link' >&2; exit 1; }

PACKAGE_ROOT="$package_root" PACKAGE_MANIFEST="$package_manifest" PREFLIGHT="$preflight" AUDIT="$audit" RESULT="$result" \
TEAM_ID="$team_id" BUNDLE_ID="$bundle_id" VERSION="$version" BUILD_ID="$build_id" SOURCE_SHA="$source_sha" \
BUILD_DIGEST="$build_digest" PRIMARY_MODEL="$primary_model" SECTION="$section" REMOTE_REFERENCE="$remote_reference" \
READBACK_DIGEST="$readback_digest" RESUME_READBACK="$resume_readback" NOW="$now" SUBMIT_FOR_REVIEW="$submit_for_review" ruby <<'RUBY'
require "json"
require "digest"
require "time"

root=ENV.fetch("PACKAGE_ROOT")
manifest_path=ENV.fetch("PACKAGE_MANIFEST")
preflight_path=ENV.fetch("PREFLIGHT")
audit_path=ENV.fetch("AUDIT")
result_path=ENV.fetch("RESULT")
team=ENV.fetch("TEAM_ID"); bundle=ENV.fetch("BUNDLE_ID"); version=ENV.fetch("VERSION"); build_id=ENV.fetch("BUILD_ID")
source_sha=ENV.fetch("SOURCE_SHA"); build_digest=ENV.fetch("BUILD_DIGEST"); now=ENV.fetch("NOW")
Time.iso8601(now)

canonical=lambda do |value|
  case value
  when Hash then value.keys.sort.to_h{|key| [key,canonical.call(value.fetch(key))]}
  when Array then value.map{|entry| canonical.call(entry)}
  else value
  end
end
tree_digest=lambda do
  entries=[]
  Dir.glob(File.join(root,"**","*"),File::FNM_DOTMATCH).sort.each do |path|
    next if [".",".."].include?(File.basename(path)); relative=path.delete_prefix(root+File::SEPARATOR)
    next unless File.file?(path) && !File.symlink?(path)
    next if relative.match?(%r{\Asubmission/[0-9]+(?:\.[0-9]+){1,2}-(?:package|result)\.json\z})
    abort "package contains a multiply-linked file" unless File.stat(path).nlink==1
    entries << "#{relative}\0#{Digest::SHA256.file(path).hexdigest}\0"
  end
  "sha256:#{Digest::SHA256.hexdigest(entries.join)}"
end

manifest=JSON.parse(File.binread(manifest_path))
manifest_keys=%w[schemaVersion status bundleId version sourceSha buildDigest requirementsDigest screenshotManifestDigest packageDigest auditDigest firstPublication legalApprovalDigest preparedAt]
abort "prepared package manifest schema is invalid" unless manifest.is_a?(Hash) && manifest.keys.sort==manifest_keys.sort && manifest["schemaVersion"]==1 && manifest["status"]=="prepared"
abort "prepared package bundle or version mismatch" unless manifest["bundleId"]==bundle && manifest["version"]==version
abort "prepared package build mismatch" unless manifest["sourceSha"]==source_sha && manifest["buildDigest"]==build_digest
abort "prepared package digest is stale" unless manifest["packageDigest"]==tree_digest.call
abort "first-publication legal approval is absent" if manifest["firstPublication"]==true && !(manifest["legalApprovalDigest"].is_a?(String) && manifest["legalApprovalDigest"].match?(/\Asha256:[0-9a-f]{64}\z/))

audit=JSON.parse(File.binread(audit_path))
abort "release audit changed after preparation" unless "sha256:#{Digest::SHA256.file(audit_path).hexdigest}"==manifest["auditDigest"]
abort "release audit is not approved for the package" unless audit.is_a?(Hash) && audit["status"]=="approved" && audit["role"]=="release-auditor" &&
  audit["sourceSha"]==source_sha && audit["buildDigest"]==build_digest && audit["packageDigest"]==manifest["packageDigest"] && audit["findings"]==[]

preflight=JSON.parse(File.binread(preflight_path))
preflight_keys=%w[schemaVersion issue provider account target environment operation health checkedAt digest]
abort "App Store preflight schema is invalid" unless preflight.is_a?(Hash) && preflight.keys.sort==preflight_keys.sort && preflight["schemaVersion"]==1
unsigned=preflight.reject{|key,_| key=="digest"}
expected_digest="sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical.call(unsigned)))}"
abort "App Store preflight digest is invalid" unless preflight["digest"]==expected_digest
abort "App Store personal team mismatch" unless preflight["provider"]=="app-store" && preflight["account"]==team
abort "App Store bundle target mismatch" unless preflight["target"]==bundle
abort "App Store preflight is not healthy production evidence" unless preflight["environment"]=="production" && preflight["operation"]=="appstore.inspect_app" && preflight["health"]=="healthy"

sections=%w[app-information localization privacy screenshots build review-information submission]
requested=ENV.fetch("SECTION")
abort "submission section is invalid" unless sections.include?(requested)
existing=File.exist?(result_path)
abort "resume requires an App Store Connect readback" if existing && ENV.fetch("RESUME_READBACK")!="yes"
abort "initial section cannot claim resume readback" if !existing && ENV.fetch("RESUME_READBACK")!="no"
if requested=="submission"
  abort "submission-for-review operation was not declared" unless ENV.fetch("SUBMIT_FOR_REVIEW")=="yes"
else
  abort "submit-for-review is only valid for the submission section" unless ENV.fetch("SUBMIT_FOR_REVIEW")=="no"
end

result_keys=%w[schemaVersion status primaryModel teamId bundleId version buildId sourceSha buildDigest packageDigest sections lastCompletedSection updatedAt]
section_keys=%w[id status remoteReference readBackDigest readBackSource verifiedAt]
if existing
  stat=File.lstat(result_path); abort "submission result is unsafe" unless stat.file? && !stat.symlink? && stat.nlink==1
  value=JSON.parse(File.binread(result_path))
  abort "submission result schema is invalid" unless value.is_a?(Hash) && value.keys.sort==result_keys.sort && value["schemaVersion"]==1
  abort "submission result identity changed" unless value.values_at("primaryModel","teamId","bundleId","version","buildId","sourceSha","buildDigest","packageDigest")==
    ["codex",team,bundle,version,build_id,source_sha,build_digest,manifest["packageDigest"]]
  completed=value["sections"]
  abort "submission result sections are invalid" unless completed.is_a?(Array) && completed.each_with_index.all?{|entry,index| entry.is_a?(Hash) && entry.keys.sort==section_keys.sort && entry["id"]==sections[index] && entry["status"]=="verified" && entry["readBackSource"]=="app-store-connect"}
else
  value={"schemaVersion"=>1,"status"=>"in-progress","primaryModel"=>"codex","teamId"=>team,"bundleId"=>bundle,
    "version"=>version,"buildId"=>build_id,"sourceSha"=>source_sha,"buildDigest"=>build_digest,"packageDigest"=>manifest["packageDigest"],
    "sections"=>[],"lastCompletedSection"=>nil,"updatedAt"=>now}
  completed=value["sections"]
end
abort "submission sections must be recorded in order" unless requested==sections.fetch(completed.length)
entry={"id"=>requested,"status"=>"verified","remoteReference"=>ENV.fetch("REMOTE_REFERENCE"),
  "readBackDigest"=>ENV.fetch("READBACK_DIGEST"),"readBackSource"=>"app-store-connect","verifiedAt"=>now}
completed << entry
value["lastCompletedSection"]=requested; value["updatedAt"]=now
value["status"]=(requested=="submission" ? "submitted" : "in-progress")
temporary="#{result_path}.tmp.#{$$}"
File.open(temporary,File::WRONLY|File::CREAT|File::EXCL,0600){|file| file.write(JSON.generate(value)+"\n"); file.flush; file.fsync}
File.rename(temporary,result_path); File.chmod(0644,result_path)
puts JSON.generate(value)
RUBY
