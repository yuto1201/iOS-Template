#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: validate-appstore-package.sh --root 'App Store' --project-root REPOSITORY --bundle-id ID --version VERSION --requirements FILE [--require-fresh --now ISO8601]" >&2
  exit 2
}

package_root=''
project_root=''
bundle_identifier=''
release_version=''
requirements_file=''
require_fresh=0
validation_now=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) package_root=${2:-}; shift 2 ;;
    --project-root) project_root=${2:-}; shift 2 ;;
    --bundle-id) bundle_identifier=${2:-}; shift 2 ;;
    --version) release_version=${2:-}; shift 2 ;;
    --requirements) requirements_file=${2:-}; shift 2 ;;
    --require-fresh) require_fresh=1; shift ;;
    --now) validation_now=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$package_root" && -n "$project_root" && -n "$bundle_identifier" && -n "$release_version" && -n "$requirements_file" ]] || usage
[[ "$bundle_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9-]*([.][A-Za-z0-9][A-Za-z0-9-]*)+$ ]] || usage
[[ "$release_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || usage
[[ -d "$package_root" && ! -L "$package_root" && -d "$project_root" && ! -L "$project_root" && -f "$requirements_file" && ! -L "$requirements_file" ]] || usage
package_root=$(cd "$package_root" && /bin/pwd -P)
project_root=$(cd "$project_root" && /bin/pwd -P)
requirements_file=$(cd "$(dirname "$requirements_file")" && /bin/pwd -P)/$(basename "$requirements_file")
if [[ "$require_fresh" == 1 && -z "$validation_now" ]]; then validation_now=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ); fi

PACKAGE_ROOT="$package_root" PROJECT_ROOT="$project_root" BUNDLE_ID="$bundle_identifier" VERSION="$release_version" \
  REQUIREMENTS="$requirements_file" REQUIRE_FRESH="$require_fresh" VALIDATION_NOW="$validation_now" \
  /usr/bin/ruby -rjson -ryaml -rdigest -rtime -ruri -rfind -e '
    package_root=ENV.fetch("PACKAGE_ROOT")
    project_root=ENV.fetch("PROJECT_ROOT")
    expected_bundle=ENV.fetch("BUNDLE_ID")
    expected_version=ENV.fetch("VERSION")
    errors=[]
    add_error=->(path,code){ errors << {"code"=>code,"path"=>path} unless errors.any?{|entry| entry["path"]==path && entry["code"]==code} }
    exact=->(value,keys,path){ add_error.call(path,"schema") unless value.is_a?(Hash) && value.keys.sort==keys.sort }
    safe_yaml=->(relative) do
      absolute=File.join(package_root,relative)
      unless File.file?(absolute) && !File.symlink?(absolute)
        add_error.call(relative,"missing"); next nil
      end
      begin
        value=YAML.safe_load(File.binread(absolute), permitted_classes: [], aliases: false)
        value.is_a?(Hash) ? value : (add_error.call(relative,"schema"); nil)
      rescue Psych::Exception
        add_error.call(relative,"invalid-yaml"); nil
      end
    end
    requirements=begin JSON.parse(File.binread(ENV.fetch("REQUIREMENTS"))) rescue nil end
    unless requirements.is_a?(Hash)
      add_error.call("submission/requirements.json","invalid-json")
      requirements={}
    end
    exact.call(requirements,%w[schemaVersion retrievedAt maxAgeDays sources fields screenshots],"submission/requirements.json")
    add_error.call("submission/requirements.json.schemaVersion","invalid") unless requirements["schemaVersion"]==1
    if ENV.fetch("REQUIRE_FRESH")=="1"
      begin
        retrieved=Time.iso8601(requirements.fetch("retrievedAt")); now=Time.iso8601(ENV.fetch("VALIDATION_NOW")); days=Integer(requirements.fetch("maxAgeDays"))
        add_error.call("submission/requirements.json.freshness","stale") if now > retrieved + days*86400
      rescue StandardError
        add_error.call("submission/requirements.json.freshness","invalid")
      end
    end
    fields=requirements["fields"].is_a?(Hash) ? requirements["fields"] : {}
    screenshots_requirement=requirements["screenshots"].is_a?(Hash) ? requirements["screenshots"] : {}

    app=safe_yaml.call("metadata/app.yml")
    app_keys=%w[schemaVersion bundleId version primaryLocale platforms category copyright supportURL privacyPolicyURL reviewContactReference accountsSupported]
    exact.call(app,app_keys,"metadata/app.yml") if app
    if app
      add_error.call("metadata/app.yml.schemaVersion","invalid") unless app["schemaVersion"]==1
      add_error.call("metadata/app.yml.bundleId","mismatch") unless app["bundleId"]==expected_bundle
      add_error.call("metadata/app.yml.version","mismatch") unless app["version"]==expected_version
      add_error.call("metadata/app.yml.primaryLocale","invalid") unless app["primaryLocale"]=="en-US"
      exact.call(app["platforms"],%w[iphone ipad],"metadata/app.yml.platforms")
      %w[iphone ipad].each{|platform| add_error.call("metadata/app.yml.platforms.#{platform}","invalid") unless [true,false].include?(app.dig("platforms",platform))}
      %w[supportURL privacyPolicyURL].each do |field|
        begin
          uri=URI.parse(app[field].to_s)
          valid=uri.is_a?(URI::HTTPS) && uri.host && !uri.host.end_with?(".invalid") && !uri.userinfo
          add_error.call("metadata/app.yml.#{field}","invalid-url") unless valid
        rescue URI::InvalidURIError
          add_error.call("metadata/app.yml.#{field}","invalid-url")
        end
      end
      reference=app["reviewContactReference"]
      add_error.call("metadata/app.yml.reviewContactReference","invalid") unless reference.is_a?(String) && (reference=="none" || reference.match?(/\Akeychain:\/\/[A-Za-z0-9._\/-]+\z/))
      add_error.call("metadata/app.yml.accountsSupported","invalid") unless [true,false].include?(app["accountsSupported"])
    end

    locale_limits={
      "name"=>[fields.dig("name","minCharacters"),fields.dig("name","maxCharacters")],
      "subtitle"=>[0,fields.dig("subtitle","maxCharacters")],
      "description"=>[1,fields.dig("description","maxCharacters")],
      "promotionalText"=>[0,fields.dig("promotionalText","maxCharacters")]
    }
    %w[en-US ja].each do |locale|
      relative="metadata/localizations/#{locale}.yml"
      localization=safe_yaml.call(relative)
      next unless localization
      exact.call(localization,%w[name subtitle description keywords promotionalText],relative)
      locale_limits.each do |field,(minimum,maximum)|
        value=localization[field]
        unless value.is_a?(String) && minimum.is_a?(Integer) && maximum.is_a?(Integer) && value.length.between?(minimum,maximum)
          add_error.call("#{relative}.#{field}","length")
        end
      end
      keywords=localization["keywords"]
      maximum_bytes=fields.dig("keywords","maxBytes")
      add_error.call("#{relative}.keywords","length") unless keywords.is_a?(String) && maximum_bytes.is_a?(Integer) && !keywords.empty? && keywords.bytesize<=maximum_bytes
    end

    privacy=safe_yaml.call("privacy/data-use.yml")
    privacy_keys=%w[schemaVersion collectsData tracking dataTypes thirdPartySDKs permissions accountDeletion]
    exact.call(privacy,privacy_keys,"privacy/data-use.yml") if privacy
    if privacy
      add_error.call("privacy/data-use.yml.schemaVersion","invalid") unless privacy["schemaVersion"]==1
      %w[collectsData tracking].each{|field| add_error.call("privacy/data-use.yml.#{field}","invalid") unless [true,false].include?(privacy[field])}
      %w[dataTypes thirdPartySDKs permissions].each{|field| add_error.call("privacy/data-use.yml.#{field}","invalid") unless privacy[field].is_a?(Array) && privacy[field].all?{|entry| entry.is_a?(String)}}
      exact.call(privacy["accountDeletion"],%w[required reason],"privacy/data-use.yml.accountDeletion")
      add_error.call("privacy/data-use.yml.collectsData","inconsistent") if privacy["collectsData"]==false && ((privacy["dataTypes"].is_a?(Array) && !privacy["dataTypes"].empty?) || (privacy["thirdPartySDKs"].is_a?(Array) && !privacy["thirdPartySDKs"].empty?))
      if app && app["accountsSupported"]==true && privacy.dig("accountDeletion","required")!=true
        add_error.call("privacy/data-use.yml.accountDeletion.required","inconsistent")
      end
    end

    %w[legal/privacy-policy.md legal/terms-of-use.md].each do |relative|
      absolute=File.join(package_root,relative)
      if !File.file?(absolute) || File.symlink?(absolute)
        add_error.call(relative,"missing")
      elsif !File.binread(absolute).match?(/^Status: (Draft|Confirmed)$/)
        add_error.call("#{relative}.status","invalid")
      end
    end
    review_path=File.join(package_root,"review/review-notes.md")
    if !File.file?(review_path) || File.symlink?(review_path)
      add_error.call("review/review-notes.md","missing")
    else
      review=File.binread(review_path)
      credential=/(password|api[_ -]?key|token|secret)\s*[:=]\s*(?!none\b|keychain:\/\/)[^\s]+/i
      add_error.call("review/review-notes.md.credentials","secret-like") if review.match?(credential)
    end
    %w[en-US ja].each do |locale|
      relative="release-notes/#{locale}.md"; absolute=File.join(package_root,relative)
      add_error.call(relative,"missing") unless File.file?(absolute) && !File.symlink?(absolute) && !File.binread(absolute).strip.empty?
    end
    checklist=safe_yaml.call("submission/checklist.yml")
    checklist_keys=%w[schemaVersion metadataValidated privacyAudited legalConfirmedForFirstPublication screenshotsAudited releaseAuditorApproved]
    exact.call(checklist,checklist_keys,"submission/checklist.yml") if checklist
    if checklist
      add_error.call("submission/checklist.yml.schemaVersion","invalid") unless checklist["schemaVersion"]==1
      (checklist_keys-["schemaVersion"]).each{|field| add_error.call("submission/checklist.yml.#{field}","invalid") unless [true,false].include?(checklist[field])}
    end

    required_families=screenshots_requirement["requiredFamilies"].is_a?(Array) ? screenshots_requirement["requiredFamilies"] : []
    min_count=screenshots_requirement["minimumPerFamily"]
    max_count=screenshots_requirement["maximumPerFamily"]
    formats=screenshots_requirement["formats"].is_a?(Array) ? screenshots_requirement["formats"] : []
    %w[en-US ja].each do |locale|
      required_families.each do |family|
        next unless family.is_a?(Hash) && family["id"].is_a?(String) && family["platform"].is_a?(String)
        next if app && app.dig("platforms",family["platform"])==false
        relative="screenshots/#{locale}/#{family["id"]}"; directory=File.join(package_root,relative)
        unless File.directory?(directory) && !File.symlink?(directory)
          add_error.call(relative,"missing"); next
        end
        files=Dir.children(directory).select{|name| formats.include?(File.extname(name).delete_prefix(".").downcase) && File.file?(File.join(directory,name))}
        add_error.call(relative,"count") unless min_count.is_a?(Integer) && max_count.is_a?(Integer) && files.length.between?(min_count,max_count)
      end
    end

    if privacy
      sdk_pattern=/(FirebaseAnalytics|PostHog|Sentry|Mixpanel|Supabase)/i
      permission_pattern=/NS[A-Za-z]+UsageDescription/
      found_sdk=false; found_permissions=[]
      Find.find(project_root) do |entry|
        relative=entry.delete_prefix(project_root+File::SEPARATOR)
        if File.directory?(entry)
          if relative=="App Store" || relative.start_with?("App Store/") || %w[.git .artifacts .worktrees].include?(relative)
            Find.prune
          end
          next
        end
        next unless File.file?(entry) && File.size(entry)<=2_000_000 && %w[.swift .pbxproj .plist .entitlements .xcprivacy .resolved .txt].include?(File.extname(entry))
        bytes=File.binread(entry); next if bytes.include?("\0")
        found_sdk ||= bytes.match?(sdk_pattern)
        found_permissions.concat(bytes.scan(permission_pattern))
      end
      add_error.call("privacy/data-use.yml.collectsData","project-scan-mismatch") if privacy["collectsData"]==false && found_sdk
      declared=privacy["permissions"].is_a?(Array) ? privacy["permissions"] : []
      (found_permissions.uniq-declared).each{|permission| add_error.call("privacy/data-use.yml.permissions","missing-#{permission}")}
    end

    errors.sort_by!{|entry| [entry["path"],entry["code"]]}
    result={
      "bundleId"=>expected_bundle,
      "errors"=>errors,
      "requirementsDigest"=>"sha256:#{Digest::SHA256.file(ENV.fetch("REQUIREMENTS")).hexdigest}",
      "status"=>errors.empty? ? "ready" : "invalid",
      "version"=>expected_version
    }
    puts JSON.generate(result.keys.sort.to_h{|key| [key,result[key]]})
    exit(errors.empty? ? 0 : 1)
  '
