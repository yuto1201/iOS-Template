#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby /usr/bin/git /usr/bin/mkfifo /usr/bin/plutil /usr/bin/zip

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-appstore-preparation.XXXXXX")
test_workspace=$(cd "$test_workspace" && pwd -P)
trap 'rm -rf -- "$test_workspace"' EXIT
entrypoint="$repo_root/tools/prepare-appstore-sources.sh"
fixture_project="$test_workspace/project"
mkdir "$fixture_project"
printf '%s\n' 'Preserve this user-owned source.' > "$fixture_project/user-notes.txt"
before_digest=$(/usr/bin/shasum -a 256 "$fixture_project/user-notes.txt")

# Exercise the public route even before identity/account/source preparation exists.
# An incomplete project must retain the entire inventory, not stop at its first
# missing field or turn unknown facts into negative declarations.
set +e
"$entrypoint" --project-root "$fixture_project" > "$test_workspace/report.json" 2> "$test_workspace/stderr"
result_status=$?
set -e
[[ "$result_status" == 1 ]] || {
  echo "expected a blocked preparation report from the public entrypoint (exit=$result_status)" >&2
  exit 1
}

ruby -rjson - "$test_workspace/report.json" "$test_workspace" <<'RUBY'
report_path, private_root = ARGV
bytes = File.binread(report_path)
report = JSON.parse(bytes)
abort "preparation leaked a private absolute path" if bytes.include?(private_root)
abort "preparation report identity differs" unless report["schemaVersion"] == 1 && report["recordType"] == "appstore-preparation"
abort "missing inputs became ready" unless report["status"] == "blocked" && report["releaseReady"] == false
abort "preparation attempted remote mutation" unless report["remoteMutations"] == []

shared_fields = %w[
  identity.displayName identity.module identity.slug identity.bundleId
  platforms deviceSupport version build primaryLocale supportedLocales sku
  category secondaryCategory copyright
  reviewNotes reviewContactReference demoAccess
  privacy.collectsData privacy.dataTypes privacy.tracking privacy.permissions
  privacy.accountDeletion privacy.thirdPartySDKs ageRating contentRights exportCompliance
  legal.privacyPolicy legal.termsOfUse legal.eula
  iap.productId iap.productType iap.price iap.territories iap.availability
  iap.restore iap.offerCodeApplicability
  account.teamId account.appId account.bundleRegistration account.userAccess
]
localized_fields = %w[name subtitle description keywords promotionalText releaseNotes screenshots.iphone screenshots.ipad supportURL privacyPolicyURL marketingURL]
expected = shared_fields.map { |id| [id, nil] }
%w[en-US ja].each { |locale| localized_fields.each { |id| expected << [id, locale] } }
rows = report.fetch("fields")
keys = rows.map { |row| [row.fetch("fieldId"), row.fetch("locale")] }
abort "incomplete, duplicate or invented inventory" unless keys == expected && keys.uniq == keys
%w[en-US ja].each do |locale|
  %w[name subtitle privacyPolicyURL].each do |id|
    abort "app-wide localization routed to a version" unless rows.find { |row| row["fieldId"] == id && row["locale"] == locale }["section"] == "app-info-localization"
  end
  %w[description keywords promotionalText releaseNotes supportURL marketingURL].each do |id|
    abort "version localization routed to app information" unless rows.find { |row| row["fieldId"] == id && row["locale"] == locale }["section"] == "version-localization"
  end
end
rows.each do |row|
  abort "missing facts were promoted" unless row["state"] == "draft"
  abort "missing scope" unless row["section"].is_a?(String) && !row["section"].empty?
  classes = row["classification"]
  abort "invalid field classification" unless classes.is_a?(Array) && !classes.empty? && (classes - %w[derive public account user]).empty?
  abort "missing source provenance" unless row["sources"].is_a?(Array) && !row["sources"].empty?
  row["sources"].each do |source|
    abort "missing source descriptor" unless %w[path anchor revision digest].all? { |key| source.key?(key) }
    abort "invented missing-source digest" unless source["revision"].nil? && source["digest"].nil?
  end
  abort "missing unresolved reason" unless row["reasons"].is_a?(Array) && !row["reasons"].empty?
  abort "missing unblock condition" unless row["unblockConditions"].is_a?(Array) && !row["unblockConditions"].empty?
  abort "missing dependency inventory" unless row["dependentFields"].is_a?(Array)
end
abort "missing Team was not distinguished" unless report.fetch("registration").fetch("reasons").include?("team-unset")
RUBY

[[ "$before_digest" == "$(/usr/bin/shasum -a 256 "$fixture_project/user-notes.txt")" ]] || {
  echo 'preparation modified a user source' >&2
  exit 1
}
[[ "$(find "$fixture_project" -type f | wc -l | tr -d ' ')" == 1 ]] || {
  echo 'preparation wrote into the input project' >&2
  exit 1
}

echo 'PASS: public App Store preparation retains the complete unresolved inventory without mutation'

# All registration scenarios go through the same public CLI. The observation
# files are deliberately synthetic and can never authorize an Apple operation.
ruby -rjson -ryaml -rfileutils -ropen3 -rtime -rdigest - "$entrypoint" "$test_workspace" "$repo_root" <<'RUBY'
entrypoint, scratch, repo_root = ARGV
project = File.join(scratch, "registration")
baseline = {
  "Config/app-identity.json" => {"schemaVersion" => 1, "displayName" => "Garden Notes", "moduleName" => "GardenNotes", "appSlug" => "garden-notes", "bundleId" => "com.example.garden"},
  "Config/ownership.yml" => {"schemaVersion" => 2, "appStore" => {"teamId" => "TEAM123456", "bundleId" => "com.example.garden"}},
  "App Store/metadata/app.yml" => {
    "schemaVersion" => 1, "bundleId" => "com.example.garden", "version" => "1.0", "primaryLocale" => "en-US",
    "platforms" => {"iphone" => true, "ipad" => true}, "category" => "Utilities", "copyright" => "2026 Garden Notes",
    "supportURL" => "https://garden.example.com/support", "privacyPolicyURL" => "https://garden.example.com/privacy",
    "reviewContactReference" => "keychain://garden-notes/review-contact", "accountsSupported" => false
  },
  "App Store/metadata/preparation.json" => {"schemaVersion" => 1, "recordType" => "appstore-preparation-sources", "sku" => "garden-notes-ios", "account" => {"appId" => "1234567890", "userAccess" => "all"}},
  "App Store/metadata/localizations/en-US.yml" => {"name" => "Garden Notes"},
  ".artifacts/appstore-preparation/account-observation.json" => {
    "schemaVersion" => 1, "recordType" => "appstore-account-observation", "source" => "synthetic-fixture",
    "observedAt" => Time.now.utc.iso8601, "status" => "observed", "inventoryComplete" => true, "teamId" => "TEAM123456", "role" => "ADMIN",
    "agreements" => "current", "bundles" => ["com.example.garden"],
    "apps" => [{"appId" => "1234567890", "bundleId" => "com.example.garden", "name" => "Garden Notes", "sku" => "garden-notes-ios", "primaryLocale" => "en-US", "platforms" => ["IOS"], "userAccess" => "all"}]
  }
}
observation_path = ".artifacts/appstore-preparation/account-observation.json"
preparation_path = "App Store/metadata/preparation.json"
app_path = "App Store/metadata/app.yml"
ownership_path = "Config/ownership.yml"

snapshot = lambda do
  Dir.glob(File.join(project, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.map do |path|
    stat = File.stat(path)
    [path, Digest::SHA256.file(path).hexdigest, stat.ino, stat.mode, stat.mtime.to_r]
  end
end
scenario = lambda do |label, expected, edit|
  documents = Marshal.load(Marshal.dump(baseline))
  edit.call(documents) if edit
  documents.each do |relative, document|
    path = File.join(project, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, relative.end_with?(".json") ? JSON.generate(document) : YAML.dump(document))
  end
  before = snapshot.call
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{label}: source was mutated" unless before == snapshot.call
  abort "#{label}: private path or diagnostic leak" if stdout.include?(scratch) || !stderr.empty?
  abort "#{label}: incomplete field inventory became complete" unless status.exitstatus == 1
  report = JSON.parse(stdout)
  registration = report.fetch("registration")
  abort "#{label}: invented remote action or authority" unless report["remoteMutations"] == [] &&
    report["releaseReady"] == false && report["liveRemoteInspection"] == false &&
    registration["mutationAuthorized"] == false && registration["retryAuthorized"] == false
  if expected.nil?
    abort "#{label}: exact existing app did not match: #{registration['reasons']}" unless registration["status"] == "matched-observation" && registration["reasons"] == [] && registration.dig("existingApp", "appId") == "1234567890"
    abort "#{label}: synthetic observation origin was hidden" unless registration["evidenceOrigin"] == "synthetic-fixture"
  else
    abort "#{label}: missing #{expected}: #{registration['reasons']}" unless registration["status"] == "blocked" && registration["reasons"].include?(expected) && registration["existingApp"].nil?
    report.fetch("fields").each do |row|
      if row["classification"].include?("account")
        abort "#{label}: affected account field omitted blocker" unless row["reasons"].include?("registration:#{expected}")
      elsif row["fieldId"] == "description"
        abort "#{label}: independent draft inherited account blocker" if row["reasons"].any? { |reason| reason.start_with?("registration:") }
      end
    end
  end
  [report, stdout]
end
scenario.call("matching existing app", nil, nil)
scenario.call("matching app after lost response", nil, ->(d) { d[preparation_path]["account"].delete("appId") })
scenario.call("Team unset", "team-unset", ->(d) { d[ownership_path]["appStore"]["teamId"] = nil })
scenario.call("wrong active Team", "account-mismatch", ->(d) { d[observation_path]["teamId"] = "OTHER12345" })
scenario.call("Bundle unset", "bundle-unset", ->(d) { d[ownership_path]["appStore"]["bundleId"] = nil })
scenario.call("wrong metadata identity", "bundle-identity-mismatch", ->(d) { d[app_path]["bundleId"] = "com.other.garden" })
scenario.call("Bundle not registered", "bundle-not-registered", ->(d) { d[observation_path]["bundles"] = []; d[observation_path]["apps"] = [] })
scenario.call("App absent", "app-not-created", ->(d) { d[observation_path]["apps"] = [] })
scenario.call("duplicate app", "duplicate-app-identities", ->(d) { d[observation_path]["apps"] << d[observation_path]["apps"].first.merge("appId" => "9999999999") })
scenario.call("conflicting app ID", "conflicting-app-identities", ->(d) { d[observation_path]["apps"] << d[observation_path]["apps"].first.merge("bundleId" => "com.other.garden") })
scenario.call("unexpected app ID", "app-identity-mismatch", ->(d) { d[preparation_path]["account"]["appId"] = "8888888888" })
scenario.call("name collision", "name-collision", ->(d) { d[observation_path]["apps"] = [d[observation_path]["apps"].first.merge("bundleId" => "com.other.garden", "appId" => "8888888888")] })
scenario.call("role insufficient", "missing-role", ->(d) { d[observation_path]["role"] = "DEVELOPER" })
scenario.call("agreement action", "agreement-action-required", ->(d) { d[observation_path]["agreements"] = "action-required" })
scenario.call("agreement unknown", "agreement-state-unknown", ->(d) { d[observation_path]["agreements"] = "unknown" })
scenario.call("observation timeout", "remote-state-unknown", ->(d) { d[observation_path]["status"] = "unknown"; d[observation_path]["apps"] = [] })
scenario.call("incomplete inventory cannot prove absence", "remote-state-unknown", ->(d) { d[observation_path]["inventoryComplete"] = false; d[observation_path]["apps"] = [] })
scenario.call("matching record on wrong platform", "registration-platform-mismatch", ->(d) { d[observation_path]["apps"].first["platforms"] = ["MAC_OS"] })
scenario.call("unrelated Mac app does not block exact iOS match", nil, ->(d) { d[observation_path]["apps"] << d[observation_path]["apps"].first.merge("appId" => "9999999999", "bundleId" => "com.example.other", "name" => "Other App", "platforms" => ["MAC_OS"]) })
scenario.call("stale observation", "stale-account-observation", ->(d) { d[observation_path]["observedAt"] = (Time.now.utc - 7200).iso8601 })
scenario.call("future observation", "stale-account-observation", ->(d) { d[observation_path]["observedAt"] = (Time.now.utc + 7200).iso8601 })
scenario.call("unknown observation key", "invalid-account-observation", ->(d) { d[observation_path]["ready"] = true })
scenario.call("user access differs", "registration-userAccess-mismatch", ->(d) { d[observation_path]["apps"].first["userAccess"] = "limited" })
scenario.call("SKU differs", "registration-sku-mismatch", ->(d) { d[observation_path]["apps"].first["sku"] = "other-sku" })
scenario.call("non-English primary remains unsupported", "unsupported-primary-locale", ->(d) { d[app_path]["primaryLocale"] = "ja" })
report, stdout = scenario.call("sensitive source rejected on repeated reads", "bundle-identity-mismatch", ->(d) { d[app_path]["reviewContactReference"] = "PRIVATE-CONTACT-SENTINEL" })
abort "raw contact leaked" if stdout.include?("PRIVATE-CONTACT-SENTINEL")
report.fetch("fields").select { |row| row["sources"].any? { |s| s["path"] == app_path } }.each do |row|
  sensitive_sources = row["sources"].select { |source| source["path"] == app_path }
  abort "sensitive file was hashed or error bypassed" unless row["reasons"].include?("sensitive-source") && sensitive_sources.all? { |source| source["digest"].nil? && source["revision"].nil? }
end
puts "PASS: public registration preparation distinguishes 26 synthetic matching, blocked and redacted cases without mutation"

scenario.call("restore valid sources", nil, nil)
identity_path = File.join(project, "Config/app-identity.json")
valid_identity = File.binread(identity_path)
check_source = lambda do |label, expected_reason, expected_revision = nil|
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{label}: unexpected public result" unless status.exitstatus == 1 && stderr.empty?
  report = JSON.parse(stdout)
  rows = report.fetch("fields").select { |row| row["fieldId"].start_with?("identity.") }
  rows.each do |row|
    source = row.fetch("sources").first
    if expected_reason
      abort "#{label}: source error was bypassed" unless row["reasons"].include?(expected_reason) && source["digest"].nil? && source["revision"].nil?
    else
      abort "#{label}: incorrect commit provenance" unless source["revision"] == expected_revision && source["digest"] == "sha256:#{Digest::SHA256.file(identity_path).hexdigest}"
    end
  end
end
check_source.call("untracked provenance", nil)
git = lambda do |*args|
  output, status = Open3.capture2e("/usr/bin/git", "-C", project, *args)
  abort "fixture Git failed" unless status.success?
  output.strip
end
git.call("init", "-q")
git.call("config", "user.name", "Synthetic Fixture")
git.call("config", "user.email", "fixture@example.invalid")
git.call("add", "Config/app-identity.json")
git.call("-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "synthetic identity")
sha = git.call("rev-parse", "HEAD")
check_source.call("exact committed provenance", nil, sha)
File.write(identity_path, valid_identity + "\n")
check_source.call("edited source is not attributed to old commit", nil)
File.write(identity_path, "{broken-json")
check_source.call("invalid schema repeated lookup", "invalid-source-schema")
File.write(identity_path, '{"bundleId":"com.example.garden","bundleId":"com.other.garden"}')
check_source.call("duplicate identity key", "invalid-source-schema")
File.write(identity_path, '{"displayName":"Garden Notes","reviewContact\\u0045mail":"PRIVATE-ESCAPED-CONTACT"}')
check_source.call("escaped sensitive key", "sensitive-source")
File.write(identity_path, valid_identity)
outside = File.join(scratch, "preserved-outside.json")
File.write(outside, valid_identity)
outside_before = [Digest::SHA256.file(outside).hexdigest, File.stat(outside).ino]
File.unlink(identity_path)
File.symlink(outside, identity_path)
check_source.call("source symlink", "unsafe-source")
File.unlink(identity_path)
File.link(outside, identity_path)
check_source.call("source hardlink", "unsafe-source")
File.unlink(identity_path)
File.write(identity_path, "x" * 2_000_001)
check_source.call("oversized source", "unsafe-source")
File.unlink(identity_path)
abort "fixture FIFO creation failed" unless system("/usr/bin/mkfifo", identity_path)
check_source.call("nonblocking FIFO source", "unsafe-source")
File.unlink(identity_path)
File.write(identity_path, valid_identity)
abort "external user source was changed" unless outside_before == [Digest::SHA256.file(outside).hexdigest, File.stat(outside).ino]
puts "PASS: public source provenance distinguishes committed and edited bytes and rejects sensitive/unsafe sources"

ownership_file = File.join(project, ownership_path)
valid_ownership = File.binread(ownership_file)
File.write(ownership_file, valid_ownership + "appStore:\n  teamId: OTHER12345\n  bundleId: com.other.garden\n")
stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
abort "duplicate YAML key was accepted" unless status.exitstatus == 1 && stderr.empty? && JSON.parse(stdout).fetch("fields").any? { |row| row["fieldId"] == "account.teamId" && row["reasons"].include?("invalid-source-schema") }
File.write(ownership_file, valid_ownership)
puts "PASS: duplicate JSON and YAML keys cannot override preparation identity"

# Use the actual template project structure, changing only synthetic identity.
# This is still a read-only metadata fixture, not an Xcode Build/Test claim.
pbx_path = File.join(project, "GardenNotes.xcodeproj/project.pbxproj")
FileUtils.mkdir_p(File.dirname(pbx_path))
pbx = File.binread(File.join(repo_root, "TemplateApp.xcodeproj/project.pbxproj"))
pbx = pbx.gsub("com.yuto.TemplateApp", "com.example.garden").gsub("TemplateApp", "GardenNotes")
pbx = pbx.gsub("PRODUCT_BUNDLE_IDENTIFIER = com.example.garden;", 'PRODUCT_BUNDLE_IDENTIFIER = com.example.garden; INFOPLIST_KEY_CFBundleDisplayName = "Garden Notes";')
File.write(pbx_path, pbx)
public_config = File.join(project, "Config/Public.xcconfig")
FileUtils.cp(File.join(repo_root, "Config/Public.xcconfig"), public_config)
prepared = JSON.parse(File.binread(File.join(project, preparation_path)))
prepared["build"] = "1"
prepared["supportedLocales"] = ["en-US", "ja"]
File.write(File.join(project, preparation_path), JSON.generate(prepared))
xcode_check = lambda do |label, expected_field, expected_reason|
  before = snapshot.call
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{label}: public result or preservation differs" unless status.exitstatus == 1 && stderr.empty? && before == snapshot.call
  fields = JSON.parse(stdout).fetch("fields")
  if expected_field
    row = fields.find { |field| field["fieldId"] == expected_field }
    abort "#{label}: expected #{expected_reason}, got #{row['reasons']}" unless row["reasons"].include?(expected_reason)
  else
    errors = fields.flat_map { |field| field["reasons"] }.select { |reason| reason.start_with?("xcode-", "xcconfig-") }.uniq
    abort "#{label}: valid settings rejected #{errors}" unless errors.empty?
    %w[identity.displayName identity.module identity.bundleId platforms deviceSupport version build supportedLocales].each do |id|
      row = fields.find { |field| field["fieldId"] == id }
      abort "#{label}: project provenance missing" unless row["sources"].any? { |source| source["path"] == "GardenNotes.xcodeproj/project.pbxproj" && source["digest"] == "sha256:#{Digest::SHA256.file(pbx_path).hexdigest}" }
    end
  end
end
xcode_check.call("matching actual target configurations", nil, nil)
File.write(pbx_path, pbx.sub("PRODUCT_BUNDLE_IDENTIFIER = com.example.garden;", "PRODUCT_BUNDLE_IDENTIFIER = com.other.garden;"))
xcode_check.call("one configuration has wrong Bundle", "identity.bundleId", "xcode-identity.bundleId-mismatch")
File.write(pbx_path, pbx.sub('INFOPLIST_KEY_CFBundleDisplayName = "Garden Notes";', 'INFOPLIST_KEY_CFBundleDisplayName = "Other Name";'))
xcode_check.call("display name mismatch", "identity.displayName", "xcode-identity.displayName-mismatch")
File.write(pbx_path, pbx.sub("MARKETING_VERSION = 1.0;", "MARKETING_VERSION = 2.0;"))
xcode_check.call("version mismatch", "version", "xcode-version-mismatch")
File.write(pbx_path, pbx.sub("CURRENT_PROJECT_VERSION = 1;", "CURRENT_PROJECT_VERSION = 2;"))
xcode_check.call("build mismatch", "build", "xcode-build-mismatch")
File.write(pbx_path, pbx.sub('TARGETED_DEVICE_FAMILY = "1,2";', 'TARGETED_DEVICE_FAMILY = "1";'))
xcode_check.call("device support mismatch", "deviceSupport", "xcode-deviceSupport-mismatch")
File.write(pbx_path, pbx.sub("SDKROOT = iphoneos;", "SDKROOT = macosx;"))
xcode_check.call("non-iOS SDK", "platforms", "xcode-platform-mismatch")
File.write(pbx_path, pbx.sub("PRODUCT_BUNDLE_IDENTIFIER = com.example.garden;", 'PRODUCT_BUNDLE_IDENTIFIER = "$(MISSING_SETTING)";'))
xcode_check.call("unresolved variable", "identity.bundleId", "xcode-setting-unresolved")
File.write(pbx_path, pbx)
File.write(public_config, '#include "Public.xcconfig"' + "\n")
xcode_check.call("recursive xcconfig include", "identity.bundleId", "xcconfig-include-cycle")
File.write(public_config, '#include "../../../outside.xcconfig"' + "\n")
xcode_check.call("escaping xcconfig include", "identity.bundleId", "unsafe-source-path")
FileUtils.cp(File.join(repo_root, "Config/Public.xcconfig"), public_config)
xcode_check.call("restored sources", nil, nil)
puts "PASS: real project configuration reads reconcile identity, version, devices and safe xcconfig includes"

# Confirm independent text from source-bound reviewed evidence. A user choice
# needs a user receipt as well; AI review alone cannot supply that approval.
localization_path = File.join(project, "App Store/metadata/localizations/en-US.yml")
File.write(localization_path, YAML.dump({"name" => "Garden Notes", "description" => "Keep a private garden journal."}))
spec_relative = "specs/product.md"
code_relative = "GardenNotes/Journal.swift"
FileUtils.mkdir_p(File.join(project, "specs"))
FileUtils.mkdir_p(File.join(project, "GardenNotes"))
File.write(File.join(project, spec_relative), "# Garden journal\n\nStatus: Confirmed\n\nKeep a private garden journal.\n")
File.write(File.join(project, code_relative), "struct Journal { var entries: [String] = [] }\n")
baseline_stdout, _, baseline_status = Open3.capture3(entrypoint, "--project-root", project)
abort "confirmation baseline failed" unless baseline_status.exitstatus == 1
baseline_rows = JSON.parse(baseline_stdout).fetch("fields")
source_descriptor = lambda do |relative, anchor = "document"|
  {"path" => relative, "anchor" => anchor, "revision" => nil, "digest" => "sha256:#{Digest::SHA256.file(File.join(project, relative)).hexdigest}"}
end
proof_directory = ".artifacts/appstore-preparation/proofs"
FileUtils.mkdir_p(File.join(project, proof_directory))
proof_documents = {}
index = {"schemaVersion" => 1, "recordType" => "appstore-preparation-confirmations", "records" => []}
%w[name description].each do |field_id|
  row = baseline_rows.find { |field| field["fieldId"] == field_id && field["locale"] == "en-US" }
  record = {"fieldId" => field_id, "locale" => "en-US", "proofs" => {}, "remoteReadback" => nil}
  row.fetch("classification").each do |kind|
    relative = "#{proof_directory}/#{field_id}-#{kind}.json"
    receipt = {
      "schemaVersion" => 1, "recordType" => "appstore-preparation-proof", "kind" => kind,
      "fieldId" => field_id, "locale" => "en-US", "section" => row["section"],
      "sourceFingerprint" => row["sourceFingerprint"], "checkedAt" => Time.now.utc.iso8601,
      "reviewer" => kind == "user" ? "user" : "codex", "decision" => kind == "user" ? "approved" : "reviewed",
      "reference" => kind == "user" ? "user-approval://synthetic-naming" : "review://synthetic-journal",
      "basis" => [source_descriptor.call(spec_relative, "# Garden journal"), source_descriptor.call(code_relative)]
    }
    proof_documents[relative] = receipt
    File.write(File.join(project, relative), JSON.generate(receipt))
    record["proofs"][kind] = source_descriptor.call(relative)
  end
  index["records"] << record
end
index_file = File.join(project, ".artifacts/appstore-preparation/confirmations.json")
File.write(index_file, JSON.generate(index))
valid_index = File.binread(index_file)
confirmation_check = lambda do |label, states, expected_reason = nil|
  before = snapshot.call
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{label}: partial confirmation became release-ready" unless status.exitstatus == 1 && stderr.empty?
  abort "#{label}: checker changed sources or old receipts" unless before == snapshot.call
  report = JSON.parse(stdout)
  abort "#{label}: invented readiness or remote operation" unless report["status"] == "blocked" && report["releaseReady"] == false && report["remoteMutations"] == []
  states.each do |id, state|
    row = report.fetch("fields").find { |field| field["fieldId"] == id && field["locale"] == "en-US" }
    abort "#{label}: #{id} expected #{state}, got #{row['state']}: #{row['reasons']}" unless row["state"] == state
    if state == "confirmed"
      abort "#{label}: confirmation lacks auditable sources" unless row["reasons"] == [] && row["unblockConditions"] == [] && !row["evidenceSources"].empty?
    elsif expected_reason
      abort "#{label}: missing #{expected_reason}: #{row['reasons']}" unless row["reasons"].include?(expected_reason)
    end
  end
end
confirmation_check.call("source-bound derived and user-approved text", {"name" => "confirmed", "description" => "confirmed"})
no_user = JSON.parse(valid_index)
no_user["records"].first["proofs"].delete("user")
File.write(index_file, JSON.generate(no_user))
confirmation_check.call("AI review does not approve naming", {"name" => "draft", "description" => "confirmed"}, "user-evidence-missing")
File.write(index_file, valid_index)
File.write(localization_path, YAML.dump({"name" => "Garden Notes", "description" => "A changed source requires review."}))
confirmation_check.call("changed copy invalidates old receipts", {"name" => "draft", "description" => "draft"}, "stale-derive-evidence")
File.write(localization_path, YAML.dump({"name" => "Garden Notes", "description" => "Keep a private garden journal."}))
File.write(File.join(project, code_relative), "struct Journal { var entries: [String] = []; var cloudSync = true }\n")
confirmation_check.call("changed implementation invalidates naming review basis", {"name" => "draft"}, "stale-derive-evidence-basis")
confirmation_check.call("changed implementation invalidates feature inventory", {"description" => "draft"}, "stale-derive-evidence")
File.write(File.join(project, code_relative), "struct Journal { var entries: [String] = [] }\n")
remote_claim = JSON.parse(valid_index)
remote_claim["records"].last["remoteReadback"] = {"state" => "remote-saved"}
File.write(index_file, JSON.generate(remote_claim))
confirmation_check.call("unverified save is not accepted", {"name" => "confirmed", "description" => "draft"}, "remote-readback-not-validated")
forged_index = JSON.parse(valid_index)
forged_index["records"].first["state"] = "confirmed"
File.write(index_file, JSON.generate(forged_index))
confirmation_check.call("state flag cannot replace evidence", {"name" => "draft", "description" => "draft"}, "invalid-confirmation-index")
File.write(index_file, valid_index)
confirmation_check.call("unchanged original sources and receipts still validate", {"name" => "confirmed", "description" => "confirmed"})
user_proof_path = "#{proof_directory}/name-user.json"
original_user_proof = File.binread(File.join(project, user_proof_path))
ai_approval = JSON.parse(original_user_proof)
ai_approval["reviewer"] = "codex"
File.write(File.join(project, user_proof_path), JSON.generate(ai_approval))
ai_index = JSON.parse(valid_index)
ai_index["records"].first["proofs"]["user"] = source_descriptor.call(user_proof_path)
File.write(index_file, JSON.generate(ai_index))
confirmation_check.call("AI cannot issue user approval", {"name" => "draft", "description" => "confirmed"}, "user-approval-missing")
File.write(File.join(project, user_proof_path), original_user_proof)
future_proof = JSON.parse(original_user_proof)
future_proof["checkedAt"] = (Time.now.utc + 3600).iso8601
File.write(File.join(project, user_proof_path), JSON.generate(future_proof))
future_index = JSON.parse(valid_index)
future_index["records"].first["proofs"]["user"] = source_descriptor.call(user_proof_path)
File.write(index_file, JSON.generate(future_index))
confirmation_check.call("future approval is rejected", {"name" => "draft", "description" => "confirmed"}, "invalid-user-evidence-time")
File.write(File.join(project, user_proof_path), original_user_proof)
File.write(index_file, valid_index)
puts "PASS: source-bound per-field confirmation preserves independent progress and invalidates stale or unsupported claims"

privacy_relative = "App Store/privacy/data-use.yml"
privacy_file = File.join(project, privacy_relative)
FileUtils.mkdir_p(File.dirname(privacy_file))
privacy_values = {"schemaVersion" => 1, "collectsData" => false, "tracking" => false, "dataTypes" => [], "thirdPartySDKs" => [], "permissions" => [], "accountDeletion" => {"required" => false, "reason" => "No account feature is implemented."}}
File.write(privacy_file, YAML.dump(privacy_values))
privacy_stdout, _, privacy_status = Open3.capture3(entrypoint, "--project-root", project)
abort "privacy baseline failed" unless privacy_status.exitstatus == 1
privacy_row = JSON.parse(privacy_stdout).fetch("fields").find { |row| row["fieldId"] == "privacy.collectsData" }
privacy_record = {"fieldId" => "privacy.collectsData", "locale" => nil, "proofs" => {}, "remoteReadback" => nil}
%w[derive user].each do |kind|
  relative = "#{proof_directory}/privacy-collects-data-#{kind}.json"
  receipt = {
    "schemaVersion" => 1, "recordType" => "appstore-preparation-proof", "kind" => kind,
    "fieldId" => "privacy.collectsData", "locale" => nil, "section" => "privacy",
    "sourceFingerprint" => privacy_row["sourceFingerprint"], "checkedAt" => Time.now.utc.iso8601,
    "reviewer" => kind == "user" ? "user" : "codex", "decision" => kind == "user" ? "approved" : "reviewed",
    "reference" => kind == "user" ? "user-approval://synthetic-privacy" : "review://synthetic-privacy",
    "basis" => [source_descriptor.call(spec_relative, "# Garden journal"), source_descriptor.call(code_relative)]
  }
  File.write(File.join(project, relative), JSON.generate(receipt))
  privacy_record["proofs"][kind] = source_descriptor.call(relative)
end
privacy_index = JSON.parse(valid_index)
privacy_index["records"] << privacy_record
File.write(index_file, JSON.generate(privacy_index))
privacy_check = lambda do |label, state, reason = nil|
  before = snapshot.call
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{label}: changed inputs, diagnostics or unexpected status" unless status.exitstatus == 1 && stderr.empty? && before == snapshot.call
  report = JSON.parse(stdout)
  row = report.fetch("fields").find { |field| field["fieldId"] == "privacy.collectsData" }
  abort "#{label}: privacy state differs: #{row['reasons']}" unless row["state"] == state
  abort "#{label}: expected #{reason}, got #{row['reasons']}" if reason && !row["reasons"].include?(reason)
  name_row = report.fetch("fields").find { |field| field["fieldId"] == "name" && field["locale"] == "en-US" }
  abort "#{label}: independent approved name lost" unless name_row["state"] == "confirmed"
  abort "#{label}: invented a privacy declaration" unless YAML.safe_load(File.binread(privacy_file))["collectsData"] == false
  abort "#{label}: invented readiness" unless report["releaseReady"] == false && report["remoteMutations"] == []
  report
end
privacy_check.call("reviewed inventory without SDK", "confirmed")
ads_file = File.join(project, "GardenNotes/Ads.swift")
File.write(ads_file, "import GoogleMobileAds\nimport UserMessagingPlatform\n")
report = privacy_check.call("AdMob added after old no-data review", "draft", "sdk-declaration-missing:admob")
abort "UMP was not distinguished" unless report.fetch("fields").find { |row| row["fieldId"] == "privacy.thirdPartySDKs" }["reasons"].include?("sdk-declaration-missing:ump")
abort "dependent legal row did not require re-audit" unless report.fetch("fields").find { |row| row["fieldId"] == "legal.privacyPolicy" }["reasons"].include?("sdk-declaration-missing:admob")
description = report.fetch("fields").find { |row| row["fieldId"] == "description" && row["locale"] == "en-US" }
abort "new implementation file did not invalidate feature claims" unless description["state"] == "draft" && description["reasons"].include?("stale-derive-evidence")
File.unlink(ads_file)
privacy_check.call("original inventory restored", "confirmed")
new_feature = File.join(project, "GardenNotes/NewFeature.swift")
File.write(new_feature, "struct NewFeature { let enabled = true }\n")
privacy_check.call("unknown feature addition also invalidates review", "draft", "stale-derive-evidence")
File.unlink(new_feature)
resolved_file = File.join(project, "Package.resolved")
pins = {"version" => 2, "pins" => [{"identity" => "example-library", "kind" => "remoteSourceControl", "location" => "https://github.com/example/library", "state" => {"revision" => "a" * 40, "version" => "1.0.0"}}]}
File.write(resolved_file, JSON.generate(pins))
privacy_check.call("unlisted package is not inferred absent", "draft", "dependency-declaration-missing")
privacy_with_sdk = Marshal.load(Marshal.dump(privacy_values))
privacy_with_sdk["thirdPartySDKs"] = ["example-library"]
File.write(privacy_file, YAML.dump(privacy_with_sdk))
privacy_check.call("declaring a package does not reuse old confirmation", "draft", "stale-derive-evidence")
current_stdout, _, current_status = Open3.capture3(entrypoint, "--project-root", project)
abort "package review input failed" unless current_status.exitstatus == 1
current_row = JSON.parse(current_stdout).fetch("fields").find { |row| row["fieldId"] == "privacy.collectsData" }
package_review_record = Marshal.load(Marshal.dump(privacy_record))
%w[derive user].each do |kind|
  original = JSON.parse(File.binread(File.join(project, privacy_record["proofs"][kind]["path"])))
  original["sourceFingerprint"] = current_row["sourceFingerprint"]
  original["checkedAt"] = Time.now.utc.iso8601
  relative = "#{proof_directory}/privacy-package-one-#{kind}.json"
  File.write(File.join(project, relative), JSON.generate(original))
  package_review_record["proofs"][kind] = source_descriptor.call(relative)
end
package_review_index = JSON.parse(valid_index)
package_review_index["records"] << package_review_record
File.write(index_file, JSON.generate(package_review_index))
privacy_check.call("newly reviewed exact package version", "confirmed")
pins["pins"].first["state"]["version"] = "2.0.0"
pins["pins"].first["state"]["revision"] = "b" * 40
File.write(resolved_file, JSON.generate(pins))
privacy_check.call("changed package version invalidates its own prior approval", "draft", "stale-derive-evidence")
File.unlink(resolved_file)
File.write(privacy_file, YAML.dump(privacy_values))
File.write(index_file, JSON.generate(privacy_index))
File.write(pbx_path, pbx.sub("GENERATE_INFOPLIST_FILE = YES;", 'GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_NSCameraUsageDescription = "Capture journal photos";'))
privacy_check.call("undeclared usage permission", "draft", "permission-declaration-missing")
File.write(pbx_path, pbx)
privacy_check.call("unchanged inventory and receipts validate again", "confirmed")
puts "PASS: full inspected code inventory invalidates privacy/legal/feature claims after SDK, dependency, permission and new-source changes"

# The evaluator consumes supplied snapshots; these synthetic pages are never
# fetched, published, or claimed as live Web verification by this test.
public_url = "https://fixture-garden.yutodev.com/support"
app_values = YAML.safe_load(File.binread(File.join(project, app_path)))
app_values["supportURL"] = public_url
File.write(File.join(project, app_path), YAML.dump(app_values))
support_relative = "App Store/metadata/public-text/support.md"
FileUtils.mkdir_p(File.dirname(File.join(project, support_relative)))
support_text = "# Support\n\nHelp for Garden Notes.\n"
File.write(File.join(project, support_relative), support_text)
preparation_values = JSON.parse(File.binread(File.join(project, preparation_path)))
preparation_values["publicPages"] = {"supportURL" => {"url" => public_url, "textSource" => source_descriptor.call(support_relative)}}
File.write(File.join(project, preparation_path), JSON.generate(preparation_values))
public_stdout, _, public_status = Open3.capture3(entrypoint, "--project-root", project)
abort "public page baseline failed" unless public_status.exitstatus == 1
public_row = JSON.parse(public_stdout).fetch("fields").find { |row| row["fieldId"] == "supportURL" }
page_directory = ".artifacts/appstore-preparation/public-pages"
FileUtils.mkdir_p(File.join(project, page_directory))
body_relative = "#{page_directory}/support.txt"
observation_relative = "#{page_directory}/support.json"
File.write(File.join(project, body_relative), "Support Help for Garden Notes.\n")
public_observation = {
  "schemaVersion" => 1, "recordType" => "appstore-public-page-observation", "source" => "synthetic-fixture",
  "observedAt" => Time.now.utc.iso8601, "url" => public_url, "finalURL" => public_url,
  "httpStatus" => 200, "authenticationRequired" => false, "credentialsUsed" => false,
  "contentType" => "text/html", "bodyTextSource" => source_descriptor.call(body_relative)
}
File.write(File.join(project, observation_relative), JSON.generate(public_observation))
public_record = {"fieldId" => "supportURL", "locale" => "en-US", "proofs" => {}, "remoteReadback" => nil}
public_receipts = {}
%w[public user].each do |kind|
  relative = "#{proof_directory}/support-url-#{kind}.json"
  receipt = {
    "schemaVersion" => 1, "recordType" => "appstore-preparation-proof", "kind" => kind,
    "fieldId" => "supportURL", "locale" => "en-US", "section" => "version-localization", "sourceFingerprint" => public_row["sourceFingerprint"],
    "checkedAt" => Time.now.utc.iso8601, "reviewer" => kind == "user" ? "user" : "public-page-inspector",
    "decision" => kind == "user" ? "approved" : "observed",
    "reference" => kind == "user" ? "user-approval://synthetic-support" : "public-observation://synthetic-support",
    "basis" => [source_descriptor.call(support_relative)]
  }
  receipt["observation"] = source_descriptor.call(observation_relative) if kind == "public"
  public_receipts[kind] = receipt
  File.write(File.join(project, relative), JSON.generate(receipt))
  public_record["proofs"][kind] = source_descriptor.call(relative)
end
public_index = Marshal.load(Marshal.dump(privacy_index))
public_index["records"] << public_record
File.write(index_file, JSON.generate(public_index))
public_check = lambda do |label, state, reason = nil|
  before = snapshot.call
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{label}: unexpected result or source mutation" unless status.exitstatus == 1 && stderr.empty? && before == snapshot.call
  report = JSON.parse(stdout)
  row = report.fetch("fields").find { |field| field["fieldId"] == "supportURL" }
  abort "#{label}: state differs #{row['reasons']}" unless row["state"] == state
  abort "#{label}: missing #{reason}: #{row['reasons']}" if reason && !row["reasons"].include?(reason)
  abort "#{label}: synthetic observation misreported" if state == "confirmed" && row["observationOrigins"] != ["synthetic-fixture"]
  abort "#{label}: invented live inspection or readiness" unless report["liveRemoteInspection"] == false && report["releaseReady"] == false && report["remoteMutations"] == []
end
public_check.call("approved exact page and matching body snapshot", "confirmed")
observe = lambda do |changes, body = "Support Help for Garden Notes.\n"|
  File.write(File.join(project, body_relative), body)
  updated = public_observation.merge(changes)
  updated["bodyTextSource"] = source_descriptor.call(body_relative)
  File.write(File.join(project, observation_relative), JSON.generate(updated))
  receipt = Marshal.load(Marshal.dump(public_receipts["public"]))
  receipt["checkedAt"] = Time.now.utc.iso8601
  receipt["observation"] = source_descriptor.call(observation_relative)
  receipt_path = "#{proof_directory}/support-url-public.json"
  File.write(File.join(project, receipt_path), JSON.generate(receipt))
  updated_index = Marshal.load(Marshal.dump(public_index))
  updated_index["records"].last["proofs"]["public"] = source_descriptor.call(receipt_path)
  File.write(index_file, JSON.generate(updated_index))
end
observe.call({"httpStatus" => 404})
public_check.call("unpublished URL", "draft", "public-page-not-reachable")
observe.call({"authenticationRequired" => true})
public_check.call("login-only page", "draft", "public-page-requires-authentication")
observe.call({"credentialsUsed" => true})
public_check.call("authenticated capture does not prove public access", "draft", "public-page-requires-authentication")
observe.call({"finalURL" => "https://fixture-garden.yutodev.com/other"})
public_check.call("redirect to a different page", "draft", "public-page-url-mismatch")
observe.call({}, "Support Unapproved replacement content.\n")
public_check.call("published body changed after approval", "draft", "public-content-mismatch")
observe.call({"observedAt" => (Time.now.utc - 7200).iso8601})
public_check.call("stale public observation", "draft", "stale-public-observation")
observe.call({"source" => "public-http"})
public_check.call("unrendered HTML flags do not prove visible text", "draft", "public-content-type-unverified")
observe.call({})
File.write(File.join(project, support_relative), "# Support\n\nNew approved copy needs a new approval.\n")
public_check.call("approved source changed", "draft", "stale-public-evidence-basis")
File.write(File.join(project, support_relative), support_text)
public_check.call("matching unchanged snapshot remains confirmed", "confirmed")
{
  "https://support.example.invalid/app" => "placeholder-public-url",
  "https://example.com/support" => "placeholder-public-url",
  "https://app.yutodev.com/" => "catalog-top-public-url",
  "http://fixture-garden.yutodev.com/support" => "invalid-public-url"
}.each do |url, reason|
  altered_app = app_values.merge("supportURL" => url)
  File.write(File.join(project, app_path), YAML.dump(altered_app))
  public_check.call("invalid public destination", "draft", reason)
end
File.write(File.join(project, app_path), YAML.dump(app_values))
public_check.call("restored approved destination", "confirmed")
puts "PASS: exact approved public-page/body evidence rejects unpublished, login-only, stale, mismatched and placeholder destinations"

iap_values = {"productId" => "com.example.garden.pro", "productType" => "NON_CONSUMABLE", "price" => {"currency" => "USD", "amount" => "1.99"}, "territories" => ["US", "JP"], "availability" => "available", "restore" => true, "offerCodeApplicability" => "not-applicable"}
iap_preparation = JSON.parse(File.binread(File.join(project, preparation_path)))
iap_preparation["iap"] = iap_values
File.write(File.join(project, preparation_path), JSON.generate(iap_preparation))
monetization_relative = "specs/monetization.md"
purchases_relative = "GardenNotes/Purchases.swift"
File.write(File.join(project, monetization_relative), "# Monetization\n\nStatus: Confirmed\n\nOne non-consumable purchase with restore support.\n")
File.write(File.join(project, purchases_relative), "import StoreKit\nstruct Purchases { let productID = \"com.example.garden.pro\" }\n")
iap_stdout, _, iap_status = Open3.capture3(entrypoint, "--project-root", project)
abort "IAP baseline failed" unless iap_status.exitstatus == 1
iap_row = JSON.parse(iap_stdout).fetch("fields").find { |row| row["fieldId"] == "iap.price" }
account_directory = ".artifacts/appstore-preparation/account-fields"
FileUtils.mkdir_p(File.join(project, account_directory))
account_relative = "#{account_directory}/iap-price.json"
production_product = iap_values.merge("appleId" => "9988776655")
account_observation = {
  "schemaVersion" => 1, "recordType" => "appstore-account-field-observation", "source" => "synthetic-fixture",
  "observedAt" => Time.now.utc.iso8601, "environment" => "production", "status" => "observed",
  "identity" => {"teamId" => "TEAM123456", "appId" => "1234567890", "bundleId" => "com.example.garden", "platform" => "IOS", "version" => "1.0"},
  "fieldId" => "iap.price", "locale" => nil, "section" => "iap", "sourceFingerprint" => iap_row["sourceFingerprint"],
  "valueDigest" => "sha256:#{Digest::SHA256.hexdigest(JSON.generate(iap_values['price'].sort.to_h))}",
  "remoteReference" => "asc://apps/1234567890/in-app-purchases/9988776655", "products" => [production_product]
}
File.write(File.join(project, account_relative), JSON.generate(account_observation))
iap_record = {"fieldId" => "iap.price", "locale" => nil, "proofs" => {}, "remoteReadback" => nil}
iap_receipts = {}
%w[derive user account].each do |kind|
  relative = "#{proof_directory}/iap-price-#{kind}.json"
  receipt = {
    "schemaVersion" => 1, "recordType" => "appstore-preparation-proof", "kind" => kind,
    "fieldId" => "iap.price", "locale" => nil, "section" => "iap", "sourceFingerprint" => iap_row["sourceFingerprint"],
    "checkedAt" => Time.now.utc.iso8601,
    "reviewer" => {"derive" => "codex", "user" => "user", "account" => "account-inspector"}.fetch(kind),
    "decision" => {"derive" => "reviewed", "user" => "approved", "account" => "observed"}.fetch(kind),
    "reference" => {"derive" => "review://synthetic-iap", "user" => "user-approval://synthetic-price", "account" => "account-observation://synthetic-iap"}.fetch(kind),
    "basis" => [source_descriptor.call(monetization_relative, "# Monetization"), source_descriptor.call(purchases_relative)]
  }
  receipt["observation"] = source_descriptor.call(account_relative) if kind == "account"
  iap_receipts[kind] = receipt
  File.write(File.join(project, relative), JSON.generate(receipt))
  iap_record["proofs"][kind] = source_descriptor.call(relative)
end
iap_index = Marshal.load(Marshal.dump(public_index))
iap_index["records"] << iap_record
File.write(index_file, JSON.generate(iap_index))
iap_check = lambda do |label, state, reason = nil|
  before = snapshot.call
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{label}: output or source preservation differs" unless status.exitstatus == 1 && stderr.empty? && before == snapshot.call
  report = JSON.parse(stdout)
  row = report.fetch("fields").find { |field| field["fieldId"] == "iap.price" }
  abort "#{label}: wrong IAP state #{row['reasons']}" unless row["state"] == state
  abort "#{label}: missing #{reason}: #{row['reasons']}" if reason && !row["reasons"].include?(reason)
  abort "#{label}: claimed real production inspection" if state == "confirmed" && row["observationOrigins"] != ["synthetic-fixture"]
  abort "#{label}: unexpected remote action or release readiness" unless report["liveRemoteInspection"] == false && report["remoteMutations"] == [] && report["releaseReady"] == false
end
iap_check.call("exact production IAP and approved price", "confirmed")
observe_account = lambda do |edit|
  observation = Marshal.load(Marshal.dump(account_observation))
  edit.call(observation)
  File.write(File.join(project, account_relative), JSON.generate(observation))
  receipt = Marshal.load(Marshal.dump(iap_receipts["account"]))
  receipt["checkedAt"] = Time.now.utc.iso8601
  receipt["observation"] = source_descriptor.call(account_relative)
  relative = "#{proof_directory}/iap-price-account.json"
  File.write(File.join(project, relative), JSON.generate(receipt))
  updated_index = Marshal.load(Marshal.dump(iap_index))
  updated_index["records"].last["proofs"]["account"] = source_descriptor.call(relative)
  File.write(index_file, JSON.generate(updated_index))
end
observe_account.call(->(o) { o["products"] = [] })
iap_check.call("production product absent", "draft", "production-iap-unobserved")
observe_account.call(->(o) { o["environment"] = "local-storekit" })
iap_check.call("local StoreKit is not production evidence", "draft", "non-production-account-observation")
observe_account.call(->(o) { o["identity"]["teamId"] = "OTHER12345" })
iap_check.call("different production Team", "draft", "account-field-identity-mismatch")
observe_account.call(->(o) { o["identity"]["appId"] = "9999999999" })
iap_check.call("different production App", "draft", "account-field-identity-mismatch")
observe_account.call(->(o) { o["identity"]["version"] = "2.0" })
iap_check.call("different app version", "draft", "account-field-identity-mismatch")
observe_account.call(->(o) { o["status"] = "unknown" })
iap_check.call("unknown account response", "draft", "account-field-unknown")
observe_account.call(->(o) { o["products"].first["price"]["amount"] = "9.99" })
iap_check.call("production price conflicts with approved source", "draft", "production-iap-context-mismatch")
observe_account.call(->(o) { o["products"].first["productType"] = "CONSUMABLE" })
iap_check.call("different product type is not hidden by same price", "draft", "production-iap-context-mismatch")
observe_account.call(->(o) { o["products"].first["territories"] = [] })
iap_check.call("territories unobserved", "draft", "unverified-production-territories")
observe_account.call(->(o) { o["products"].first["availability"] = "unavailable" })
iap_check.call("product not available", "draft", "production-iap-unavailable")
observe_account.call(->(o) { o["products"].first["offerCodeApplicability"] = "unknown" })
iap_check.call("offer applicability unknown", "draft", "unverified-production-offers")
observe_account.call(->(o) { o["products"] << o["products"].first.dup })
iap_check.call("duplicate production product", "draft", "production-iap-identity-mismatch")
observe_account.call(->(o) { o["sourceFingerprint"] = "sha256:" + "0" * 64 })
iap_check.call("wrong source binding", "draft", "stale-account-field-source")
observe_account.call(->(o) { o["observedAt"] = (Time.now.utc - 7200).iso8601 })
iap_check.call("stale production observation", "draft", "stale-account-field-observation")
observe_account.call(->(_) {})
iap_check.call("same exact observation restored", "confirmed")
puts "PASS: account/IAP confirmations require fresh production identity, product configuration and approved matching values"

# A genuine linked Git worktree must consume the canonical shared preparation
# evidence without weakening source-file symlink rules or following other links.
git.call("add", "Config", "GardenNotes", "GardenNotes.xcodeproj", "App Store", "specs")
git.call("-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "synthetic complete source checkout")
committed_sha = git.call("rev-parse", "HEAD")
committed_stdout, _, committed_status = Open3.capture3(entrypoint, "--project-root", project)
abort "committed source inventory failed" unless committed_status.exitstatus == 1
committed_name = JSON.parse(committed_stdout).fetch("fields").find { |row| row["fieldId"] == "name" && row["locale"] == "en-US" }
worktree_record = {"fieldId" => "name", "locale" => "en-US", "proofs" => {}, "remoteReadback" => nil}
%w[derive user].each do |kind|
  relative = "#{proof_directory}/worktree-name-#{kind}.json"
  receipt = {
    "schemaVersion" => 1, "recordType" => "appstore-preparation-proof", "kind" => kind,
    "fieldId" => "name", "locale" => "en-US", "section" => "app-info-localization", "sourceFingerprint" => committed_name["sourceFingerprint"],
    "checkedAt" => Time.now.utc.iso8601, "reviewer" => kind == "user" ? "user" : "codex", "decision" => kind == "user" ? "approved" : "reviewed",
    "reference" => kind == "user" ? "user-approval://synthetic-worktree" : "review://synthetic-worktree",
    "basis" => [source_descriptor.call(spec_relative, "# Garden journal").merge("revision" => committed_sha), source_descriptor.call(code_relative).merge("revision" => committed_sha)]
  }
  File.write(File.join(project, relative), JSON.generate(receipt))
  worktree_record["proofs"][kind] = source_descriptor.call(relative)
end
File.write(index_file, JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-preparation-confirmations", "records" => [worktree_record]}))
linked_root = File.join(project, ".worktrees/read-only-preparation")
git.call("worktree", "add", "--detach", linked_root, committed_sha)
linked_artifacts = File.join(linked_root, ".artifacts")
File.symlink("../../.artifacts", linked_artifacts)
shared_digest = Digest::SHA256.file(index_file).hexdigest
direct_stdout, _, direct_status = Open3.capture3(entrypoint, "--project-root", project)
linked_stdout, linked_stderr, linked_status = Open3.capture3(entrypoint, "--project-root", linked_root)
abort "canonical linked worktree did not return a preparation report" unless direct_status.exitstatus == 1 && linked_status.exitstatus == 1 && linked_stderr.empty?
direct_report, linked_report = JSON.parse(direct_stdout), JSON.parse(linked_stdout)
direct_name = direct_report.fetch("fields").find { |row| row["fieldId"] == "name" && row["locale"] == "en-US" }
linked_name = linked_report.fetch("fields").find { |row| row["fieldId"] == "name" && row["locale"] == "en-US" }
abort "linked worktree lost valid shared approval or source identity" unless direct_name["state"] == "confirmed" && linked_name == direct_name
abort "linked worktree leaked a private root or changed shared evidence" if linked_stdout.include?(scratch) || Digest::SHA256.file(index_file).hexdigest != shared_digest
[File.join(project, ".artifacts"), "../../other-store"].each do |target|
  File.unlink(linked_artifacts)
  File.symlink(target, linked_artifacts)
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", linked_root)
  abort "noncanonical shared-evidence link was followed" unless status.exitstatus == 2 && stderr.empty? && JSON.parse(stdout)["status"] == "invalid"
  abort "invalid link leaked private paths" if stdout.include?(scratch)
end
File.unlink(linked_artifacts)
File.symlink("../../.artifacts", linked_artifacts)
git.call("worktree", "remove", "--force", linked_root)
abort "fixture cleanup removed the shared evidence store" unless Digest::SHA256.file(index_file).hexdigest == shared_digest
puts "PASS: genuine canonical worktrees share bound evidence while arbitrary artifact aliases are rejected"

# Historical save/readback evidence is inspected, never executed. The source
# checkout, parsed Issue authority and user decision all bind the same intent.
require File.join(repo_root, "tools/lib/issue-contract")
git.call("remote", "add", "origin", "https://github.com/garden-owner/garden-notes.git")
canonical_digest = lambda { |value| "sha256:#{Digest::SHA256.hexdigest(IOSTemplate::IssueContract.canonical_json(value))}" }
save_root = ".artifacts/appstore-preparation/readbacks"
FileUtils.mkdir_p(File.join(project, save_root))
save_time = Time.now.utc.iso8601
save_identity = {"teamId" => "TEAM123456", "appId" => "1234567890", "bundleId" => "com.example.garden", "platform" => "IOS", "version" => "1.0"}
save_body = <<~BODY
  ## Goal
  Save the selected approved app name only.
  ## In scope
  Inspect and save the selected name, preserving every other form value.
  ## Out of scope
  Release submission and unselected metadata changes.
  ## Acceptance criteria
  - AC-1: UI-direction route: not-applicable; Scope: metadata save; Reason: no application UI changes. Save the approved name and verify readback.
  ## Spec anchors
  - [Product](specs/product.md#garden-journal)
  ## Dependencies
  None
  ## UI verification
  Not applicable
  ## Delivery stage
  - Stage: release
  - Time budget: 120 minutes
  - Reason: Metadata save authority and readback verification.
  ## Delivery profile
  - Profile: strict
  - Reason: Authenticated App Store metadata mutation.
  ## External operations
  - Operation: appstore.update_metadata
  - Service: App Store Connect
  - Environment: production
  - Executor: Codex
  - Approval required: yes
  ## User approvals
  approval: user-approval://synthetic-save-name
BODY
save_verification = {
  "bundleIdentifier" => "com.example.garden", "unitTestIdentifier" => "GardenNotesTests/JournalTests/testSave",
  "cases" => %w[iphone-en iphone-ja ipad-en ipad-ja].map { |id| {"id" => id, "testIdentifier" => "GardenNotesUITests/JournalUITests/testJournal"} },
  "acceptanceMappings" => [{"id" => "AC-1", "checks" => ["stage:build", "stage:unit-tests"] + %w[case visual].flat_map { |kind| %w[iphone-en iphone-ja ipad-en ipad-ja].map { |id| "#{kind}:#{id}" } }}]
}
save_body += "\n## Verification\n\n```json\n#{JSON.generate(save_verification)}\n```\n"
save_contract = IOSTemplate::IssueContract.parse(save_body, issue_type: "release", issue: 901, repository: "garden-owner/garden-notes", fetched_at: save_time).contract
selected_fields = [{"fieldId" => "name", "sourceFingerprint" => direct_name["sourceFingerprint"], "valueDigest" => canonical_digest.call("Garden Notes")}]
intent = {"identity" => save_identity, "sourceRevision" => committed_sha, "section" => direct_name["section"], "locale" => "en-US", "selectedFields" => selected_fields}
intent.merge!({"issue" => 901, "issueType" => "release", "repository" => "garden-owner/garden-notes", "executor" => "codex", "operation" => "appstore.update_metadata", "environment" => "production", "remoteState" => {"appStatus" => "PREPARE_FOR_SUBMISSION", "versionStatus" => "PREPARE_FOR_SUBMISSION", "build" => nil, "publicEffect" => "draft-only"}})
intent["remoteReference"] = "asc://apps/1234567890/appInfoLocalizations/en-us-info"
preflight = {"schemaVersion" => 2, "issue" => 901, "executor" => "codex", "provider" => "app-store", "account" => "TEAM123456", "target" => "com.example.garden", "environment" => "production", "operation" => "appstore.update_metadata", "health" => "healthy", "checkedAt" => save_time}
preflight["digest"] = canonical_digest.call(preflight)
form_values = direct_report["fields"].select { |r| r["section"] == direct_name["section"] && r["locale"] == "en-US" }.each_with_object({}) { |r, out| out[r["fieldId"]] = nil }
form_values["privacyChoicesURL"] = nil
form_values["privacyPolicyText"] = nil
form_values["name"] = "Earlier approved name"
form_values["subtitle"] = "An independent previous subtitle."
baseline_form = {"schemaVersion" => 1, "recordType" => "appstore-form-projection", "identity" => save_identity, "section" => direct_name["section"], "locale" => "en-US", "remoteReference" => intent["remoteReference"], "values" => form_values}
readback_form = Marshal.load(Marshal.dump(baseline_form))
readback_form["values"]["name"] = "Garden Notes"
approval = {"schemaVersion" => 1, "recordType" => "appstore-save-approval", "reviewer" => "user", "decision" => "approved", "reference" => "approval: user-approval://synthetic-save-name", "checkedAt" => save_time, "intentDigest" => canonical_digest.call(intent)}
save_inputs = {"contract.json" => save_contract, "issue.md" => save_body, "preflight.json" => preflight, "approval.json" => approval, "baseline.json" => baseline_form, "readback.json" => readback_form}
save_receipt = {"schemaVersion" => 2, "recordType" => "appstore-preparation-readback", "source" => "synthetic-fixture", "issue" => 901, "issueType" => "release", "repository" => "garden-owner/garden-notes", "executor" => "codex", "operation" => "appstore.update_metadata", "environment" => "production", "identity" => save_identity, "sourceRevision" => committed_sha, "section" => direct_name["section"], "locale" => "en-US", "selectedFields" => selected_fields, "savedAt" => save_time, "observedAt" => save_time, "outcome" => "remote-saved", "remoteReference" => intent["remoteReference"], "intentDigest" => canonical_digest.call(intent)}
save_receipt["remoteState"] = intent["remoteState"]
write_save = lambda do |mutate = nil|
  inputs, receipt = Marshal.load(Marshal.dump([save_inputs, save_receipt]))
  mutate.call(inputs, receipt) if mutate
  inputs.each do |name, value|
    File.write(File.join(project, save_root, name), value.is_a?(String) ? value : JSON.generate(value))
  end
  {"contract" => "contract.json", "issueBody" => "issue.md", "preflight" => "preflight.json", "approval" => "approval.json", "baseline" => "baseline.json", "readback" => "readback.json"}.each do |key, name|
    receipt[key] = source_descriptor.call("#{save_root}/#{name}")
  end
  File.write(File.join(project, save_root, "receipt.json"), JSON.generate(receipt))
  record = Marshal.load(Marshal.dump(worktree_record))
  record["remoteReadback"] = source_descriptor.call("#{save_root}/receipt.json")
  File.write(index_file, JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-preparation-confirmations", "records" => [record]}))
end
save_check = lambda do |label, expected_state, reason = nil|
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{label}: save evidence executed a mutation or broke independent draft output" unless status.exitstatus == 1 && stderr.empty?
  report = JSON.parse(stdout)
  row = report["fields"].find { |r| r["fieldId"] == "name" && r["locale"] == "en-US" }
  abort "#{label}: wrong save state #{row}" unless row["state"] == expected_state
  abort "#{label}: missing rejection #{reason}: #{row['reasons']}" if reason && !row["reasons"].include?(reason)
  abort "#{label}: fixture claimed live access" unless report["remoteMutations"] == [] && report["liveRemoteInspection"] == false && report["releaseReady"] == false
  abort "#{label}: private values leaked" if stdout.include?(scratch) || stdout.include?("An independent previous description.")
  abort "#{label}: missing supplied observation provenance" if expected_state == "remote-saved" && !row["observationOrigins"].include?("synthetic-fixture")
end
write_save.call
save_check.call("authorized exact source-bound save and readback", "remote-saved")
[
  ["unknown save response", "remote-save-unresolved", ->(_, r) { r["outcome"] = "unknown" }],
  ["unknown publication effect", "remote-public-effect-unresolved", ->(_, r) { r["remoteState"]["publicEffect"] = "unknown" }],
  ["changed publication effect invalidates approval", "remote-readback-source-mismatch", ->(_, r) { r["remoteState"]["publicEffect"] = "immediate-public-change" }],
  ["wrong target", "remote-readback-identity-mismatch", ->(_, r) { r["identity"]["appId"] = "9999999999" }],
  ["wrong locale", "remote-readback-scope-mismatch", ->(_, r) { r["locale"] = "ja" }],
  ["wrong ASC resource kind", "invalid-remote-readback-reference", ->(_, r) { r["remoteReference"] = "asc://apps/1234567890/appStoreVersions/version-one" }],
  ["another resource was not approved", "remote-readback-source-mismatch", ->(_, r) { r["remoteReference"] = "asc://apps/1234567890/appInfoLocalizations/other-info" }],
  ["readback from another resource", "incomplete-remote-form", ->(i, _) { i["readback.json"]["remoteReference"] = "asc://apps/1234567890/appInfoLocalizations/other-info" }],
  ["stale source revision", "remote-readback-source-mismatch", ->(_, r) { r["sourceRevision"] = "0" * 40 }],
  ["stale observation", "stale-remote-readback", ->(_, r) { r["observedAt"] = (Time.now.utc - 7200).iso8601 }],
  ["selected value mismatch", "remote-selected-value-mismatch", ->(i, _) { i["readback.json"]["values"]["name"] = "Another name" }],
  ["unselected field changed", "remote-preserved-value-mismatch", ->(i, _) { i["readback.json"]["values"]["subtitle"] = "Unexpected replacement" }],
  ["missing preserved field", "incomplete-remote-form", ->(i, _) { i["readback.json"]["values"].delete("subtitle") }],
  ["missing privacy property in both forms", "incomplete-remote-form", ->(i, _) { %w[baseline.json readback.json].each { |file| i[file]["values"].delete("privacyChoicesURL") } }],
  ["numeric type drift is not equality", "remote-preserved-value-mismatch", ->(i, _) { i["baseline.json"]["values"]["extraField"] = 1; i["readback.json"]["values"]["extraField"] = 1.0 }],
  ["null and empty are different", "remote-preserved-value-mismatch", ->(i, _) { i["baseline.json"]["values"]["subtitle"] = nil; i["readback.json"]["values"]["subtitle"] = "" }],
  ["Unicode normalization cannot hide drift", "remote-preserved-value-mismatch", ->(i, _) { i["baseline.json"]["values"]["subtitle"] = "caf\u00e9"; i["readback.json"]["values"]["subtitle"] = "cafe\u0301" }],
  ["private form values are not public evidence", "remote-save-evidence-missing", ->(i, _) { i["readback.json"]["values"]["password"] = "fixture-do-not-emit" }],
  ["AI cannot approve save", "remote-save-approval-missing", ->(i, _) { i["approval.json"]["reviewer"] = "codex" }],
  ["approval for other intent", "remote-save-approval-missing", ->(i, _) { i["approval.json"]["intentDigest"] = "sha256:" + "0" * 64 }],
  ["missing Issue type binding", "remote-readback-not-validated", ->(_, r) { r.delete("issueType") }],
  ["wrong Issue type cannot reinterpret a release contract", "remote-save-contract-mismatch", ->(i, r) {
    r["issueType"] = "feature"
    changed_intent = intent.merge("issueType" => "feature")
    i["approval.json"]["intentDigest"] = r["intentDigest"] = canonical_digest.call(changed_intent)
  }],
  ["different executor invalidates intent", "remote-readback-source-mismatch", ->(_, r) { r["executor"] = "claude" }],
  ["contract and body differ", "remote-save-contract-mismatch", ->(i, _) { i["issue.md"] = i["issue.md"].sub("Executor: Codex", "Executor: Claude") }],
  ["preflight account differs", "remote-save-preflight-mismatch", ->(i, _) { i["preflight.json"]["account"] = "OTHER12345" }]
].each do |label, reason, mutate|
  write_save.call(mutate)
  save_check.call(label, "draft", reason)
end
write_save.call
save_check.call("same source and readback can resume without another save", "remote-saved")
write_save.call(->(_, r) { r["outcome"] = "unchanged-verified" })
save_check.call("fresh readback of an authorized previous save needs no new mutation", "remote-saved")
write_save.call(lambda do |inputs, receipt|
  inputs["issue.md"] = inputs["issue.md"].sub("Executor: Codex", "Executor: Claude")
  inputs["contract.json"] = IOSTemplate::IssueContract.parse(inputs["issue.md"], issue_type: "release", issue: 901, repository: "garden-owner/garden-notes", fetched_at: save_time).contract
  inputs["preflight.json"]["executor"] = receipt["executor"] = "claude"
  inputs["preflight.json"]["digest"] = canonical_digest.call(inputs["preflight.json"].reject { |key, _| key == "digest" })
  updated_intent = intent.merge("executor" => "claude")
  inputs["approval.json"]["intentDigest"] = receipt["intentDigest"] = canonical_digest.call(updated_intent)
end)
save_check.call("Claude save evidence has the same exact authority checks", "remote-saved")
write_save.call
puts "PASS: supplied authorized readback binds identity, source, approval, exact selected values and preserved form fields without mutations"

# Protected values arrive only on an explicit pipe, never in source files,
# command arguments, reports, or reusable public value hashes.
protected_reference = "protected-observation://synthetic-contact-preservation"
contact_reference = "keychain://garden/review/contact"
write_save.call(lambda do |inputs, receipt|
  %w[baseline.json readback.json].each { |file| inputs[file]["values"]["contactEmail"] = contact_reference }
  receipt["protectedObservation"] = protected_reference
  inputs["approval.json"]["intentDigest"] = receipt["intentDigest"] = canonical_digest.call(intent.merge("protectedObservation" => protected_reference))
end)
protected_receipt = JSON.parse(File.binread(File.join(project, save_root, "receipt.json")))
private_contact = "private-fixture-review@sample.invalid"
protected_observation = protected_receipt.select { |key, _| %w[source identity sourceRevision section locale intentDigest savedAt observedAt].include?(key) }.merge(
  "reference" => protected_reference, "references" => {"contactEmail" => contact_reference},
  "baseline" => {"contactEmail" => private_contact}, "readback" => {"contactEmail" => private_contact})
protected_input = {"schemaVersion" => 1, "recordType" => "appstore-protected-form-input", "observations" => [protected_observation]}
protected_check = lambda do |label, input, expected_state, reason = nil|
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project, "--protected-forms-stdin", stdin_data: JSON.generate(input))
  abort "#{label}: protected input lost safe partial report" unless status.exitstatus == 1 && stderr.empty?
  report = JSON.parse(stdout)
  row = report["fields"].find { |field| field["fieldId"] == "name" && field["locale"] == "en-US" }
  abort "#{label}: wrong protected comparison state" unless row["state"] == expected_state
  abort "#{label}: missing protected comparison reason" if reason && !row["reasons"].include?(reason)
  [private_contact, Digest::SHA256.hexdigest(private_contact), canonical_digest.call(private_contact)].each do |private_value|
    abort "#{label}: private value or hash leaked" if (stdout + stderr).include?(private_value)
  end
  abort "#{label}: protected input granted authority" unless report["remoteMutations"] == [] && report["liveRemoteInspection"] == false
end
protected_check.call("protected contact preserved", protected_input, "remote-saved")
[
  "{}", "[]", JSON.generate(protected_input).sub('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1'),
  JSON.generate(protected_input.merge("observations" => [protected_observation, protected_observation])),
  JSON.generate(protected_input).sub(JSON.generate(private_contact), '1e999')
].each do |invalid_input|
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project, "--protected-forms-stdin", stdin_data: invalid_input)
  abort "malformed private pipe input was not safely rejected" unless status.exitstatus == 2 && stderr.empty? && JSON.parse(stdout)["status"] == "invalid" && !stdout.include?(private_contact)
end
save_check.call("protected observation cannot be replayed without transient values", "draft", "protected-form-input-missing")
[
  ["changed private value", "protected-form-value-mismatch", ->(o) { o["readback"]["contactEmail"] = "different-private@sample.invalid" }],
  ["wrong private identity", "protected-form-binding-mismatch", ->(o) { o["identity"]["appId"] = "9999999999" }],
  ["wrong private source", "protected-form-binding-mismatch", ->(o) { o["sourceRevision"] = "0" * 40 }],
  ["wrong private reference", "protected-form-reference-mismatch", ->(o) { o["references"]["contactEmail"] = "keychain://other/contact" }],
  ["missing protected field", "incomplete-protected-form", ->(o) { o["readback"].delete("contactEmail") }]
].each do |label, reason, mutate|
  input = Marshal.load(Marshal.dump(protected_input))
  mutate.call(input["observations"].first)
  protected_check.call(label, input, "draft", reason)
end
Dir.glob(File.join(project, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) && !File.symlink?(path) }.each do |path|
  abort "private observation was persisted" if File.binread(path).include?(private_contact)
end
write_save.call
puts "PASS: transient protected comparison verifies preserved contact values without persistence, value hashes, implicit reads or remote authority"

# Type and questionnaire checks go through the same public entrypoint. Missing
# information is retained as draft; arbitrary maps cannot become declarations.
schema_baseline = File.binread(File.join(project, preparation_path))
localization_baseline = File.binread(localization_path)
schema_case = lambda do |label, field_id, reason, edit|
  prepared_values = JSON.parse(schema_baseline)
  localized_values = YAML.safe_load(localization_baseline)
  edit.call(prepared_values, localized_values)
  File.write(File.join(project, preparation_path), JSON.generate(prepared_values))
  File.write(localization_path, YAML.dump(localized_values))
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{label}: preparation failed to retain independent rows" unless status.exitstatus == 1 && stderr.empty?
  report = JSON.parse(stdout)
  row = report["fields"].find { |r| r["fieldId"] == field_id }
  abort "#{label}: expected #{reason}, got #{row['reasons']}" unless row["state"] == "draft" && row["reasons"].include?(reason)
  abort "#{label}: parser diagnostics leaked source data" if stdout.include?(scratch)
  if reason == "sensitive-source"
    abort "#{label}: private credential or its source hash leaked" if stdout.include?("fixture-private-passphrase") || report["fields"].flat_map { |entry| entry["sources"] }.any? { |source| source["path"] == preparation_path && !source["digest"].nil? }
  end
end
[
  ["numeric description", "description", "invalid-field-type", ->(_, l) { l["description"] = 42 }],
  ["boolean localized name", "name", "invalid-field-type", ->(_, l) { l["name"] = true }],
  ["unknown preparation format", "sku", "invalid-preparation-schema", ->(p, _) { p["schemaVersion"] = 99 }],
  ["unknown preparation root key", "sku", "invalid-preparation-schema", ->(p, _) { p["pretendConfirmed"] = true }],
  ["caller state is not supported", "sku", "invalid-preparation-schema", ->(p, _) { p["state"] = "confirmed" }],
  ["credential reference must not contain a secret value", "sku", "sensitive-source", ->(p, _) { p["demoAccess"] = {"required" => true, "credentialsReference" => "fixture-private-passphrase", "instructionsSource" => "App Store/review/review-notes.md"} }],
  ["scalar locales", "supportedLocales", "invalid-field-type", ->(p, _) { p["supportedLocales"] = "en-US" }],
  ["duplicate locales", "supportedLocales", "invalid-field-value", ->(p, _) { p["supportedLocales"] = ["en-US", "en-US"] }],
  ["unmodeled supported locale", "supportedLocales", "invalid-field-value", ->(p, _) { p["supportedLocales"] = ["en-US", "fr"] }],
  ["escaping demo instructions source", "demoAccess", "invalid-field-value", ->(p, _) { p["demoAccess"] = {"required" => true, "credentialsReference" => "keychain://garden/review/demo", "instructionsSource" => "../private-demo.md"} }],
  ["missing demo instructions source", "demoAccess", "missing-source", ->(p, _) { p["demoAccess"] = {"required" => true, "credentialsReference" => "keychain://garden/review/demo", "instructionsSource" => "App Store/review/missing-demo.md"} }],
  ["unknown screenshot locale", "screenshots.iphone", "invalid-screenshot-source-schema", ->(p, _) { p["screenshots"] = {"fr" => {}} }],
  ["unknown screenshot device", "screenshots.iphone", "invalid-screenshot-source-schema", ->(p, _) { p["screenshots"] = {"en-US" => {"watch" => nil}} }],
  ["unknown public-page field", "supportURL", "invalid-public-page-schema", ->(p, _) { p["publicPages"] = {"unknownURL" => {}} }],
  ["unknown localized public-page field", "supportURL", "invalid-localized-url-schema", ->(p, _) { p["localizedPublicPages"] = {"en-US" => {"unknownURL" => {}}} }],
  ["array build", "build", "invalid-field-type", ->(p, _) { p["build"] = ["1"] }],
  ["unknown IAP key", "iap.price", "invalid-preparation-field-schema", ->(p, _) { p["iap"]["extra"] = true }],
  ["numeric IAP price", "iap.price", "invalid-field-type", ->(p, _) { p["iap"]["price"]["amount"] = 1.99 }],
  ["malformed product identity cannot crash other fields", "iap.price", "invalid-field-value", ->(p, _) { p["iap"]["productId"] = [42, "com.example.garden.pro"] }],
  ["arbitrary questionnaire", "ageRating", "invalid-questionnaire-schema", ->(p, _) { p["ageRating"] = {"rating" => "4+"} }],
  ["empty questionnaire", "ageRating", "invalid-questionnaire-schema", ->(p, _) { p["ageRating"] = {} }],
  ["unanswered content rights", "contentRights", "invalid-questionnaire-schema", ->(p, _) { p["contentRights"] = {} }],
  ["unanswered export compliance", "exportCompliance", "invalid-questionnaire-schema", ->(p, _) { p["exportCompliance"] = {} }]
].each { |label, field, reason, edit| schema_case.call(label, field, reason, edit) }
age_booleans = %w[parentalControls ageAssurance unrestrictedWebAccess userGeneratedContent socialMedia socialMediaUnder13Disabled messagingAndChat advertising healthOrWellnessTopics gambling lootBox]
age_frequencies = %w[profanityOrCrudeHumor horrorOrFearThemes alcoholTobaccoOrDrugUseOrReferences medicalOrTreatmentInformation matureOrSuggestiveThemes sexualContentOrNudity sexualContentGraphicAndNudity violenceCartoonOrFantasy violenceRealistic violenceRealisticProlongedGraphicOrSadistic gunsOrOtherWeapons gamblingSimulated contests]
age_answers = age_booleans.each_with_object({}) { |key, out| out[key] = false }.merge(age_frequencies.each_with_object({}) { |key, out| out[key] = "NONE" })
age_questionnaire = {"schemaVersion" => 1, "questionnaireVersion" => "apple-age-rating-2026-09-09", "answers" => age_answers, "ageCategory" => {"choice" => "not-applicable", "value" => nil}, "ageSuitabilityURL" => nil}
[
  ["missing content question", "questionnaire-unanswered", ->(q) { q["answers"].delete("advertising") }],
  ["explicit null answer", "questionnaire-unanswered", ->(q) { q["answers"]["gambling"] = nil }],
  ["string boolean is not an answer", "invalid-questionnaire-answer", ->(q) { q["answers"]["advertising"] = "false" }],
  ["unknown frequency", "invalid-questionnaire-answer", ->(q) { q["answers"]["medicalOrTreatmentInformation"] = "UNKNOWN" }],
  ["deprecated frequency", "invalid-questionnaire-answer", ->(q) { q["answers"]["contests"] = "INFREQUENT_OR_MILD" }],
  ["caller-selected question inventory", "invalid-questionnaire-schema", ->(q) { q["answers"]["customOnly"] = false }],
  ["unknown age questionnaire version", "unsupported-questionnaire-version", ->(q) { q["questionnaireVersion"] = "older-questionnaire" }],
  ["missing age category choice", "questionnaire-unanswered", ->(q) { q["ageCategory"]["choice"] = nil }]
].each do |label, reason, edit|
  schema_case.call(label, "ageRating", reason, lambda do |p, _|
    p["ageRating"] = Marshal.load(Marshal.dump(age_questionnaire))
    edit.call(p["ageRating"])
  end)
end
schema_values = JSON.parse(schema_baseline)
schema_values["ageRating"] = age_questionnaire
File.write(File.join(project, preparation_path), JSON.generate(schema_values))
File.write(localization_path, localization_baseline)
age_stdout, _, age_status = Open3.capture3(entrypoint, "--project-root", project)
abort "complete age questionnaire broke preparation" unless age_status.exitstatus == 1
age_row = JSON.parse(age_stdout)["fields"].find { |r| r["fieldId"] == "ageRating" }
age_record = {"fieldId" => "ageRating", "locale" => nil, "proofs" => {}, "remoteReadback" => nil}
%w[derive user].each do |kind|
  receipt = JSON.parse(File.binread(File.join(project, worktree_record["proofs"][kind]["path"])))
  receipt.merge!({"fieldId" => "ageRating", "locale" => nil, "section" => "app-information", "sourceFingerprint" => age_row["sourceFingerprint"]})
  relative = "#{proof_directory}/questionnaire-#{kind}.json"
  File.write(File.join(project, relative), JSON.generate(receipt))
  age_record["proofs"][kind] = source_descriptor.call(relative)
end
File.write(index_file, JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-preparation-confirmations", "records" => [age_record]}))
age_stdout, _, age_status = Open3.capture3(entrypoint, "--project-root", project)
age_row = JSON.parse(age_stdout)["fields"].find { |r| r["fieldId"] == "ageRating" }
abort "explicit complete age answers with current review did not confirm: #{age_row['reasons']}" unless age_status.exitstatus == 1 && age_row["state"] == "confirmed"
confirm_questionnaire = lambda do |field_id, value, expected_state, reason = nil|
  current = JSON.parse(schema_baseline)
  current[field_id] = value
  File.write(File.join(project, preparation_path), JSON.generate(current))
  stdout, _, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{field_id}: questionnaire snapshot failed" unless status.exitstatus == 1
  row = JSON.parse(stdout)["fields"].find { |r| r["fieldId"] == field_id }
  record = {"fieldId" => field_id, "locale" => nil, "proofs" => {}, "remoteReadback" => nil}
  %w[derive user].each do |kind|
    receipt = JSON.parse(File.binread(File.join(project, worktree_record["proofs"][kind]["path"])))
    receipt.merge!({"fieldId" => field_id, "locale" => nil, "section" => row["section"], "sourceFingerprint" => row["sourceFingerprint"]})
    relative = "#{proof_directory}/questionnaire-#{kind}.json"
    File.write(File.join(project, relative), JSON.generate(receipt))
    record["proofs"][kind] = source_descriptor.call(relative)
  end
  File.write(index_file, JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-preparation-confirmations", "records" => [record]}))
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{field_id}: malformed questionnaire lost partial report" unless status.exitstatus == 1 && stderr.empty?
  row = JSON.parse(stdout)["fields"].find { |r| r["fieldId"] == field_id }
  abort "#{field_id}: expected #{expected_state}, got #{row['state']}: #{row['reasons']}" unless row["state"] == expected_state
  abort "#{field_id}: missing #{reason}: #{row['reasons']}" if reason && !row["reasons"].include?(reason)
end
confirm_questionnaire.call("ageRating", age_questionnaire.merge("ageSuitabilityURL" => "https://garden.yutodev.com/age"), "draft", "public-evidence-missing")
rights = {"schemaVersion" => 1, "containsThirdPartyContent" => false, "hasNecessaryRights" => nil, "rightsReferences" => []}
confirm_questionnaire.call("contentRights", rights, "confirmed")
confirm_questionnaire.call("contentRights", rights.merge("containsThirdPartyContent" => true), "draft", "content-rights-unresolved")
confirm_questionnaire.call("contentRights", rights.merge("containsThirdPartyContent" => true, "hasNecessaryRights" => false), "draft", "content-rights-unresolved")
confirm_questionnaire.call("contentRights", rights.merge("containsThirdPartyContent" => true, "hasNecessaryRights" => true, "rightsReferences" => ["rights://synthetic-owned-license"]), "confirmed")
export = {"schemaVersion" => 1, "usesEncryption" => false, "encryptionTypes" => [], "distributedInFrance" => false, "documentationRequired" => false, "determinationReference" => "user-approval://synthetic-export-determination", "documents" => []}
confirm_questionnaire.call("exportCompliance", export, "confirmed")
confirm_questionnaire.call("exportCompliance", export.merge("usesEncryption" => nil), "draft", "questionnaire-unanswered")
confirm_questionnaire.call("exportCompliance", export.merge("usesEncryption" => true), "draft", "inconsistent-questionnaire-answers")
confirm_questionnaire.call("exportCompliance", export.merge("determinationReference" => nil), "draft", "export-determination-unresolved")
confirm_questionnaire.call("exportCompliance", export.merge("usesEncryption" => true, "encryptionTypes" => ["proprietary"]), "draft", "export-documentation-unresolved")
confirm_questionnaire.call("exportCompliance", export.merge("usesEncryption" => true, "encryptionTypes" => ["standard"], "distributedInFrance" => true), "draft", "export-documentation-unresolved")
confirm_questionnaire.call("exportCompliance", export.merge("usesEncryption" => true, "encryptionTypes" => ["proprietary"], "documentationRequired" => true, "documents" => [{"kind" => "ccats", "status" => "approved", "reference" => "asc://apps/1234567890/encryption/synthetic-doc"}]), "draft", "account-evidence-missing")
File.write(File.join(project, preparation_path), schema_baseline)
File.write(localization_path, localization_baseline)
puts "PASS: versioned preparation types and complete explicit age questionnaires reject omissions and malformed values without invented answers"

# Complete synthetic inventory: real held PNG/ZIP bytes plus supplied origin-
# labelled evidence, never an actual Xcode archive, live page or Apple mutation.
require "zlib"
full_values = JSON.parse(schema_baseline)
full_values.merge!({"secondaryCategory" => "Lifestyle", "marketingURL" => "https://fixture-garden.yutodev.com/about", "ageRating" => age_questionnaire, "contentRights" => rights, "exportCompliance" => export, "demoAccess" => {"required" => false, "credentialsReference" => nil, "instructionsSource" => nil}})
full_values["account"]["bundleRegistration"] = "com.example.garden"
full_values["publicPages"] = {}
full_app = YAML.safe_load(File.binread(File.join(project, app_path)))
full_app["privacyPolicyURL"] = "https://fixture-garden.yutodev.com/privacy"
File.write(File.join(project, app_path), YAML.dump(full_app))
%w[en-US ja].each do |locale|
  copy = {"name" => "Garden Notes", "subtitle" => "A personal garden journal", "description" => "Keep a private garden journal.", "keywords" => "garden,journal", "promotionalText" => "Remember your garden observations."}
  File.write(File.join(project, "App Store/metadata/localizations/#{locale}.yml"), YAML.dump(copy))
  FileUtils.mkdir_p(File.join(project, "App Store/release-notes"))
  File.write(File.join(project, "App Store/release-notes/#{locale}.md"), "Record your garden observations.\n")
end
FileUtils.mkdir_p(File.join(project, "App Store/review"))
File.write(File.join(project, "App Store/review/review-notes.md"), "# Review notes\n\nUse the garden journal without creating an account.\n")
{
  "supportURL" => ["App Store/metadata/public-text/support.md", full_app["supportURL"]],
  "privacyPolicyURL" => ["App Store/legal/privacy-policy.md", full_app["privacyPolicyURL"]],
  "marketingURL" => ["App Store/metadata/public-text/marketing.md", full_values["marketingURL"]],
  "legal.privacyPolicy" => ["App Store/legal/privacy-policy.md", full_app["privacyPolicyURL"]],
  "legal.termsOfUse" => ["App Store/legal/terms-of-use.md", "https://fixture-garden.yutodev.com/terms"],
  "legal.eula" => ["App Store/legal/eula.md", "https://fixture-garden.yutodev.com/eula"]
}.each do |field, (relative, url)|
  FileUtils.mkdir_p(File.dirname(File.join(project, relative)))
  File.write(File.join(project, relative), "# Garden Notes\n\nStatus: Confirmed\n\nSynthetic approved #{File.basename(relative)} text for the local-only garden journal.\n")
  full_values["publicPages"][field] = {"url" => url, "textSource" => source_descriptor.call(relative)}
end
full_values["legal"] = {"eula" => full_values["publicPages"]["legal.eula"].merge("choice" => "custom")}
artifact_directory = ".artifacts/appstore-preparation/builds"
FileUtils.mkdir_p(File.join(project, artifact_directory))
zip_root = File.join(scratch, "export")
FileUtils.mkdir_p(File.join(zip_root, "Payload/GardenNotes.app"))
File.write(File.join(zip_root, "Payload/GardenNotes.app/Info.plist"), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.garden</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string><key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array></dict></plist>')
artifact_relative = "#{artifact_directory}/garden.ipa"
_, zip_error, zip_status = Open3.capture3("/usr/bin/zip", "-q", "-r", File.join(project, artifact_relative), "Payload", chdir: zip_root)
abort "synthetic distribution fixture could not be assembled" unless zip_status.success? && zip_error.empty?
distribution_digest = source_descriptor.call(artifact_relative)["digest"]
build_relative = "#{artifact_directory}/garden.json"
File.write(File.join(project, build_relative), JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-distribution-build", "source" => "synthetic-fixture", "sourceRevision" => committed_sha, "bundleId" => "com.example.garden", "version" => "1.0", "build" => "1", "platform" => "iphoneos", "distributionMethod" => "app-store-connect", "artifact" => source_descriptor.call(artifact_relative)}))
full_values["buildArtifact"] = source_descriptor.call(build_relative)
requirements_relative = "App Store/submission/requirements.json"
FileUtils.mkdir_p(File.join(project, "App Store/submission"))
requirements_document = JSON.parse(File.binread(File.join(repo_root, "tools/tests/fixtures/appstore/requirements.json")))
requirements_document["retrievedAt"] = Time.now.utc.iso8601
File.write(File.join(project, requirements_relative), JSON.generate(requirements_document))
screenshot_cases = []
%w[en-US ja].each_with_index do |locale, locale_index|
  [["iphone", "iphone-6.9", "iPhone 17 Pro Max", 1260, 2736], ["ipad", "ipad-13", "iPad Air (M4)", 2064, 2752]].each_with_index do |(device, family, device_type, width, height), device_index|
    relative = "App Store/screenshots/#{locale}/#{family}/01-primary.png"
    FileUtils.mkdir_p(File.dirname(File.join(project, relative)))
    rgb = [40 + locale_index * 50, 80 + device_index * 50, 120].pack("C*")
    chunk = lambda { |type, bytes| [bytes.bytesize].pack("N") + type.b + bytes + [Zlib.crc32(type.b + bytes)].pack("N") }
    png = "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [width, height, 8, 2, 0, 0, 0].pack("NNC5")) + chunk.call("IDAT", Zlib::Deflate.deflate(("\0".b + rgb * width) * height, 9)) + chunk.call("IEND", "".b)
    File.binwrite(File.join(project, relative), png)
    screenshot_cases << {"locale" => locale, "family" => family, "state" => "primary", "order" => 1, "path" => relative.delete_prefix("App Store/screenshots/"), "sourceSha" => committed_sha, "buildDigest" => distribution_digest, "runtime" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "deviceType" => device_type, "width" => width, "height" => height, "digest" => source_descriptor.call(relative)["digest"]}
  end
end
review_relative = ".artifacts/appstore-preparation/proofs/screenshot-review.json"
screenshot_review = {"schemaVersion" => 1, "sourceSha" => committed_sha, "buildDigest" => distribution_digest, "visualReviewStatus" => "passed", "releaseAuditor" => {"status" => "approved", "model" => "claude"}, "cases" => screenshot_cases.map { |entry| entry.select { |key, _| %w[locale family state path digest].include?(key) }.merge("safeArea" => "passed", "textClipping" => "passed", "truthfulRepresentation" => "passed", "localeParity" => "passed") }}
File.write(File.join(project, review_relative), JSON.generate(screenshot_review))
manifest_relative = "App Store/screenshots/manifest.json"
File.write(File.join(project, manifest_relative), JSON.generate({"schemaVersion" => 1, "sourceSha" => committed_sha, "buildDigest" => distribution_digest, "runtime" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "requirementsDigest" => source_descriptor.call(requirements_relative)["digest"], "reviewDigest" => source_descriptor.call(review_relative)["digest"], "cases" => screenshot_cases}))
full_values["screenshots"] = %w[en-US ja].each_with_object({}) { |locale, out| out[locale] = %w[iphone ipad].each_with_object({}) { |device, devices| devices[device] = {"status" => "adopted", "manifest" => source_descriptor.call(manifest_relative), "review" => source_descriptor.call(review_relative), "requirements" => source_descriptor.call(requirements_relative)} } }
File.write(File.join(project, preparation_path), JSON.generate(full_values))
File.write(index_file, JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-preparation-confirmations", "records" => []}))
complete_stdout, complete_stderr, complete_status = Open3.capture3(entrypoint, "--project-root", project)
abort "full fixture inventory failed to load" unless complete_status.exitstatus == 1 && complete_stderr.empty?
complete_rows = JSON.parse(complete_stdout)["fields"]
full_index = {"schemaVersion" => 1, "recordType" => "appstore-preparation-confirmations", "records" => []}
complete_rows.each do |row|
  slug = [row["fieldId"], row["locale"]].compact.join("-").downcase.gsub(/[^a-z0-9-]/, "-")
  record = {"fieldId" => row["fieldId"], "locale" => row["locale"], "proofs" => {}, "remoteReadback" => nil}
  row["classification"].each do |kind|
    proof = {"schemaVersion" => 1, "recordType" => "appstore-preparation-proof", "kind" => kind, "fieldId" => row["fieldId"], "locale" => row["locale"], "section" => row["section"], "sourceFingerprint" => row["sourceFingerprint"], "checkedAt" => Time.now.utc.iso8601, "reviewer" => {"derive" => "codex", "user" => "user", "public" => "public-page-inspector", "account" => "account-inspector"}.fetch(kind), "decision" => {"derive" => "reviewed", "user" => "approved", "public" => "observed", "account" => "observed"}.fetch(kind), "reference" => {"derive" => "review", "user" => "user-approval", "public" => "public-observation", "account" => "account-observation"}.fetch(kind) + "://synthetic-full-#{slug}", "basis" => [source_descriptor.call(spec_relative, "# Garden journal").merge("revision" => committed_sha), source_descriptor.call(code_relative).merge("revision" => committed_sha)]}
    if kind == "public"
      page = full_values["publicPages"].fetch(row["fieldId"])
      raw_body = File.binread(File.join(project, page["textSource"]["path"]))
      plain_body = raw_body.lines.reject { |line| line.strip == "Status: Confirmed" }.map { |line| line.sub(/\A\s*\#{1,6}\s+/, "") }.join
      body = "#{page_directory}/full-#{slug}.txt"
      observation = "#{page_directory}/full-#{slug}.json"
      File.write(File.join(project, body), plain_body)
      File.write(File.join(project, observation), JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-public-page-observation", "source" => "synthetic-fixture", "observedAt" => Time.now.utc.iso8601, "url" => page["url"], "finalURL" => page["url"], "httpStatus" => 200, "authenticationRequired" => false, "credentialsUsed" => false, "contentType" => "text/plain", "bodyTextSource" => source_descriptor.call(body)}))
      proof["observation"] = source_descriptor.call(observation)
    elsif kind == "account"
      source = row["sources"].first
      bytes = File.binread(File.join(project, source["path"]))
      value = source["anchor"] == "document" ? bytes : source["anchor"].split(".").reduce(source["path"].end_with?(".json") ? JSON.parse(bytes) : YAML.safe_load(bytes)) { |v, key| v.fetch(key) }
      observation = "#{account_directory}/full-#{slug}.json"
      File.write(File.join(project, observation), JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-account-field-observation", "source" => "synthetic-fixture", "observedAt" => Time.now.utc.iso8601, "environment" => "production", "status" => "observed", "identity" => save_identity, "fieldId" => row["fieldId"], "locale" => row["locale"], "section" => row["section"], "sourceFingerprint" => row["sourceFingerprint"], "valueDigest" => canonical_digest.call(value), "remoteReference" => "asc://apps/1234567890/metadata/#{slug}", "products" => row["fieldId"].start_with?("iap.") ? [production_product] : []}))
      proof["observation"] = source_descriptor.call(observation)
    end
    proof["checkedAt"] = Time.now.utc.iso8601
    relative = "#{proof_directory}/full-#{slug}-#{kind}.json"
    File.write(File.join(project, relative), JSON.generate(proof))
    record["proofs"][kind] = source_descriptor.call(relative)
  end
  full_index["records"] << record
end
File.write(index_file, JSON.generate(full_index))
complete_stdout, complete_stderr, complete_status = Open3.capture3(entrypoint, "--project-root", project)
complete_report = JSON.parse(complete_stdout)
unresolved = complete_report.fetch("fields").reject { |row| row["state"] == "confirmed" }.map { |row| [row["fieldId"], row["locale"], row["reasons"]] }
abort "complete source inventory did not prepare: #{unresolved.inspect}" unless complete_status.success? && complete_stderr.empty? && complete_report["status"] == "prepared" && unresolved.empty?
abort "source preparation became release or remote authority" unless complete_report["releaseReady"] == false && complete_report["remoteMutations"] == [] && complete_report["liveRemoteInspection"] == false
puts "PASS: a full non-secret synthetic inventory prepares only with all required current source, public, account and asset evidence"

asset_originals = [preparation_path, build_relative, artifact_relative, manifest_relative, review_relative, requirements_relative, "App Store/screenshots/#{screenshot_cases.first['path']}"].each_with_object({}) { |relative, out| out[relative] = File.binread(File.join(project, relative)) }
asset_case = lambda do |label, field_id, expected_reason, edit|
  edit.call
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "#{label}: asset validation lost the partial report" unless status.exitstatus == 1 && stderr.empty?
  report = JSON.parse(stdout)
  row = report["fields"].find { |entry| entry["fieldId"] == field_id }
  abort "#{label}: missing #{expected_reason}: #{row['reasons']}" unless row["state"] == "draft" && row["reasons"].include?(expected_reason)
  name = report["fields"].find { |entry| entry["fieldId"] == "name" && entry["locale"] == "en-US" }
  abort "#{label}: independent confirmed name was discarded" unless name["state"] == "confirmed"
  abort "#{label}: asset inspection became a release or mutation" unless report["releaseReady"] == false && report["remoteMutations"] == [] && report["liveRemoteInspection"] == false
  asset_originals.each { |relative, bytes| File.binwrite(File.join(project, relative), bytes) }
end
asset_case.call("distribution artifact missing", "build", "distribution-artifact-mismatch", -> { File.unlink(File.join(project, artifact_relative)) })
asset_case.call("ZIP bytes changed", "build", "distribution-artifact-mismatch", -> { File.binwrite(File.join(project, artifact_relative), asset_originals[artifact_relative] + "unexpected") })
asset_case.call("valid digest is not a valid IPA identity", "build", "distribution-artifact-identity-mismatch", lambda do
  File.binwrite(File.join(project, artifact_relative), "PK\x03\x04not-an-archivePK\x05\x06".b)
  record = JSON.parse(asset_originals[build_relative])
  record["artifact"] = source_descriptor.call(artifact_relative)
  File.write(File.join(project, build_relative), JSON.generate(record))
  values = JSON.parse(asset_originals[preparation_path])
  values["buildArtifact"] = source_descriptor.call(build_relative)
  File.write(File.join(project, preparation_path), JSON.generate(values))
end)
asset_case.call("PNG CRC or stream corruption", "screenshots.iphone", "invalid-screenshot-image", lambda do
  relative = "App Store/screenshots/#{screenshot_cases.first['path']}"
  damaged = asset_originals[relative].dup
  damaged.setbyte(45, damaged.getbyte(45) ^ 255)
  File.binwrite(File.join(project, relative), damaged)
end)
asset_case.call("different valid image cannot reuse an adopted digest", "screenshots.iphone", "screenshot-image-digest-mismatch", lambda do
  target = "App Store/screenshots/#{screenshot_cases.first['path']}"
  replacement = "App Store/screenshots/#{screenshot_cases.find { |entry| entry['locale'] == 'ja' && entry['family'] == 'iphone-6.9' }['path']}"
  FileUtils.copy_file(File.join(project, replacement), File.join(project, target))
end)
refresh_asset_references = lambda do
  values = JSON.parse(asset_originals[preparation_path])
  manifest = JSON.parse(File.binread(File.join(project, manifest_relative)))
  manifest["reviewDigest"] = source_descriptor.call(review_relative)["digest"]
  manifest["requirementsDigest"] = source_descriptor.call(requirements_relative)["digest"]
  File.write(File.join(project, manifest_relative), JSON.generate(manifest))
  values["screenshots"].each_value do |devices|
    devices.each_value do |entry|
      entry["manifest"] = source_descriptor.call(manifest_relative)
      entry["review"] = source_descriptor.call(review_relative)
      entry["requirements"] = source_descriptor.call(requirements_relative)
    end
  end
  File.write(File.join(project, preparation_path), JSON.generate(values))
end
asset_case.call("fresh manifest cannot replace visual approval", "screenshots.iphone", "screenshot-review-unconfirmed", lambda do
  review = JSON.parse(asset_originals[review_relative])
  review["visualReviewStatus"] = "failed"
  File.write(File.join(project, review_relative), JSON.generate(review))
  refresh_asset_references.call
end)
asset_case.call("old screenshot requirements are not current", "screenshots.iphone", "screenshot-requirements-stale", lambda do
  requirements = JSON.parse(asset_originals[requirements_relative])
  requirements["retrievedAt"] = (Time.now.utc - 40 * 86_400).iso8601
  File.write(File.join(project, requirements_relative), JSON.generate(requirements))
  refresh_asset_references.call
end)
stdout, _, status = Open3.capture3(entrypoint, "--project-root", project)
abort "restored complete evidence failed to prepare" unless status.success? && JSON.parse(stdout)["status"] == "prepared"
puts "PASS: distribution and adopted screenshot bytes, identity, review and requirements invalidate only affected preparation without capture or release claims"

# Planning declarations are not approvals. Exercise the real public entrypoint
# using fresh, separately written proof files; original evidence is preserved.
planned_report = lambda do
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
  abort "planning lost the partial report" unless [0, 1].include?(status.exitstatus) && stderr.empty?
  JSON.parse(stdout)
end
refresh_planning_proofs = lambda do
  report = planned_report.call
  planned_index = {"schemaVersion" => 1, "recordType" => "appstore-preparation-confirmations", "records" => []}
  report["fields"].each do |row|
    original = full_index["records"].find { |entry| entry["fieldId"] == row["fieldId"] && entry["locale"] == row["locale"] }
    slug = [row["fieldId"], row["locale"]].compact.join("-").downcase.tr(".", "-")
    record = {"fieldId" => row["fieldId"], "locale" => row["locale"], "proofs" => {}, "remoteReadback" => nil}
    row["classification"].each do |kind|
      descriptor = original["proofs"][kind] || full_index["records"].find { |entry| entry["proofs"][kind] }["proofs"][kind]
      proof = JSON.parse(File.binread(File.join(project, descriptor["path"])))
      %w[fieldId locale section sourceFingerprint].each { |key| proof[key] = row[key] }
      if kind == "public"
        values = JSON.parse(File.binread(File.join(project, preparation_path)))
        page = values.dig("localizedPublicPages", row["locale"], row["fieldId"]) if row["locale"]
        if page
          observation = JSON.parse(File.binread(File.join(project, proof["observation"]["path"])))
          observation["url"] = observation["finalURL"] = page["url"]
          observation["observedAt"] = Time.now.utc.iso8601
          relative = ".artifacts/appstore-preparation/public-pages/planned-#{slug}.json"
          File.write(File.join(project, relative), JSON.generate(observation))
          proof["observation"] = source_descriptor.call(relative)
        end
      elsif kind == "account"
        observation = JSON.parse(File.binread(File.join(project, proof["observation"]["path"])))
        source = row["sources"].first
        bytes = File.binread(File.join(project, source["path"]))
        value = source["anchor"] == "document" ? bytes : source["anchor"].split(".").reduce(source["path"].end_with?(".json") ? JSON.parse(bytes) : YAML.safe_load(bytes)) { |v, key| v.fetch(key) }
        observation["sourceFingerprint"] = row["sourceFingerprint"]
        observation["valueDigest"] = canonical_digest.call(value)
        observation["observedAt"] = Time.now.utc.iso8601
        relative = "#{account_directory}/planned-#{slug}.json"
        File.write(File.join(project, relative), JSON.generate(observation))
        proof["observation"] = source_descriptor.call(relative)
      end
      proof["checkedAt"] = Time.now.utc.iso8601
      relative = "#{proof_directory}/planned-#{slug}-#{kind}.json"
      File.write(File.join(project, relative), JSON.generate(proof))
      record["proofs"][kind] = source_descriptor.call(relative)
    end
    planned_index["records"] << record
  end
  File.write(index_file, JSON.generate(planned_index))
  planned_report.call
end

demo_instructions_relative = "App Store/review/demo-instructions.md"
demo_instructions_file = File.join(project, demo_instructions_relative)
demo_instructions = "# Demo access\n\nUse the synthetic fixture account described by its Keychain reference.\n"
File.write(demo_instructions_file, demo_instructions)
demo_values = JSON.parse(asset_originals[preparation_path])
demo_values["demoAccess"] = {
  "required" => true,
  "credentialsReference" => "keychain://garden/review/demo",
  "instructionsSource" => demo_instructions_relative
}
File.write(File.join(project, preparation_path), JSON.generate(demo_values))
demo_report = refresh_planning_proofs.call
demo_row = demo_report["fields"].find { |row| row["fieldId"] == "demoAccess" && row["locale"].nil? }
demo_source = demo_row["sources"].find { |source| source["path"] == demo_instructions_relative }
abort "required demo instructions were not source-bound" unless demo_report["status"] == "prepared" && demo_row["state"] == "confirmed" &&
  demo_source && demo_source["anchor"] == "document" && demo_source["digest"] == source_descriptor.call(demo_instructions_relative)["digest"]
confirmed_demo_fingerprint = demo_row["sourceFingerprint"]
File.write(demo_instructions_file, demo_instructions + "Changed after confirmation.\n")
demo_row = planned_report.call["fields"].find { |row| row["fieldId"] == "demoAccess" && row["locale"].nil? }
abort "changed demo instructions reused old confirmation" unless demo_row["state"] == "draft" &&
  demo_row["sourceFingerprint"] != confirmed_demo_fingerprint && demo_row["reasons"].include?("stale-derive-evidence")
File.binwrite(File.join(project, preparation_path), asset_originals[preparation_path])
File.write(index_file, JSON.generate(full_index))
File.unlink(demo_instructions_file)
abort "demo instruction drift check did not restore prepared inputs" unless planned_report.call["status"] == "prepared"
puts "PASS: demo instructions bytes are held source provenance and invalidate stale confirmations"

declaration = {"fieldId" => "screenshots.iphone", "locale" => "en-US", "decision" => "deferred", "reason" => "User will adopt this screenshot later"}
planned_values = JSON.parse(asset_originals[preparation_path])
planned_values["dispositions"] = [declaration]
File.write(File.join(project, preparation_path), JSON.generate(planned_values))
report = refresh_planning_proofs.call
planned_row = ->(value) { value["fields"].find { |row| row["fieldId"] == "screenshots.iphone" && row["locale"] == "en-US" } }
abort "approved screenshot deferral did not remain blocked" unless report["status"] == "blocked" && planned_row.call(report)["state"] == "deferred"
abort "raw user planning reason leaked" if JSON.generate(report).include?(declaration["reason"])
planned_index_bytes = File.binread(index_file)
index = JSON.parse(planned_index_bytes)
index["records"].find { |row| row["fieldId"] == "screenshots.iphone" && row["locale"] == "en-US" }["proofs"].delete("user")
File.write(index_file, JSON.generate(index))
abort "unapproved declaration became deferred" unless planned_row.call(planned_report.call)["state"] == "draft"
File.binwrite(index_file, planned_index_bytes)
index = JSON.parse(planned_index_bytes)
deferred_record = index["records"].find { |row| row["fieldId"] == "screenshots.iphone" && row["locale"] == "en-US" }
proof_relative = deferred_record["proofs"]["user"]["path"]
user_proof_bytes = File.binread(File.join(project, proof_relative))
model_proof = JSON.parse(user_proof_bytes)
model_proof["reviewer"] = "codex"
File.write(File.join(project, proof_relative), JSON.generate(model_proof))
deferred_record["proofs"]["user"] = source_descriptor.call(proof_relative)
File.write(index_file, JSON.generate(index))
abort "model substituted for user deferral approval" unless planned_row.call(planned_report.call)["reasons"].include?("user-approval-missing")
File.binwrite(File.join(project, proof_relative), user_proof_bytes)
index = JSON.parse(planned_index_bytes)
index["records"].find { |row| row["fieldId"] == "screenshots.iphone" && row["locale"] == "en-US" }["remoteReadback"] = {"unexpected" => true}
File.write(index_file, JSON.generate(index))
abort "deferred row accepted remote save" unless planned_row.call(planned_report.call)["reasons"].include?("remote-readback-disposition-conflict")
File.binwrite(index_file, planned_index_bytes)
deferred_image = "App Store/screenshots/#{screenshot_cases.first['path']}"
File.unlink(File.join(project, deferred_image))
abort "deferred screenshot required existing image" unless planned_row.call(planned_report.call)["state"] == "deferred"
File.binwrite(File.join(project, deferred_image), asset_originals[deferred_image])
planned_values["dispositions"][0]["reason"] = "User changed the intended deferral"
File.write(File.join(project, preparation_path), JSON.generate(planned_values))
abort "changed reason reused prior approval" unless planned_row.call(planned_report.call)["state"] == "draft"

planned_values = JSON.parse(asset_originals[preparation_path])
planned_values["secondaryCategory"] = nil
planned_values["dispositions"] = [{"fieldId" => "secondaryCategory", "locale" => nil, "decision" => "not-applicable", "reason" => "User selects a single category"}]
File.write(File.join(project, preparation_path), JSON.generate(planned_values))
report = refresh_planning_proofs.call
abort "explicit optional-field omission did not prepare" unless report["status"] == "prepared" && report["fields"].find { |row| row["fieldId"] == "secondaryCategory" }["state"] == "not-applicable"
planned_values.delete("dispositions")
File.write(File.join(project, preparation_path), JSON.generate(planned_values))
abort "missing value inferred not applicable" unless planned_report.call["fields"].find { |row| row["fieldId"] == "secondaryCategory" }["state"] == "draft"

planned_values = JSON.parse(asset_originals[preparation_path])
planned_values["iap"] = {}
planned_values["dispositions"] = %w[productId productType price territories availability restore offerCodeApplicability].map do |key|
  {"fieldId" => "iap.#{key}", "locale" => nil, "decision" => "not-applicable", "reason" => "User and source review confirm no in-app purchase feature"}
end
File.write(File.join(project, preparation_path), JSON.generate(planned_values))
report = refresh_planning_proofs.call
abort "fully approved IAP applicability did not prepare" unless report["status"] == "prepared" && report["fields"].select { |row| row["fieldId"].start_with?("iap.") }.all? { |row| row["state"] == "not-applicable" }
planned_values["dispositions"].pop
File.write(File.join(project, preparation_path), JSON.generate(planned_values))
abort "partial IAP exemption accepted" unless planned_report.call["fields"].find { |row| row["fieldId"] == "iap.productId" }["reasons"].include?("disposition-iap-group-incomplete")

[
  ["identity.bundleId", nil, "disposition-not-applicable-forbidden"],
  ["secondaryCategory", nil, "disposition-value-conflict"],
  ["screenshots.iphone", "en-US", "disposition-not-applicable-forbidden"]
].each do |id, locale, reason|
  planned_values = JSON.parse(asset_originals[preparation_path])
  planned_values["screenshots"]["en-US"]["iphone"] = nil if id == "screenshots.iphone"
  planned_values["dispositions"] = [{"fieldId" => id, "locale" => locale, "decision" => "not-applicable", "reason" => "Attempt an invalid applicability override"}]
  File.write(File.join(project, preparation_path), JSON.generate(planned_values))
  report = planned_report.call
  row = report["fields"].find { |entry| entry["fieldId"] == id && entry["locale"] == locale }
  abort "#{id}: invalid applicability override accepted" unless row["state"] == "draft" && row["reasons"].include?(reason)
end
planned_values = JSON.parse(asset_originals[preparation_path])
planned_values["dispositions"] = [declaration, declaration, declaration]
File.write(File.join(project, preparation_path), JSON.generate(planned_values))
report = planned_report.call
abort "duplicate planning declarations accepted" unless report["planningErrors"].include?("duplicate-disposition-field") && planned_row.call(report)["plannedState"].nil?
planned_values["dispositions"] = [declaration.merge("fieldId" => "unknown", "locale" => nil)]
File.write(File.join(project, preparation_path), JSON.generate(planned_values))
report = planned_report.call
abort "unknown disposition was silently ignored" unless report["status"] == "blocked" && report["planningErrors"].include?("unknown-disposition-field")
File.binwrite(File.join(project, preparation_path), asset_originals[preparation_path])
File.write(index_file, JSON.generate(full_index))
puts "PASS: explicit source-bound user dispositions preserve deferred work, invalidate changed choices and never infer optionality from absence"

locale_values = JSON.parse(asset_originals[preparation_path])
ja_support_url = "https://fixture-garden.yutodev.com/ja/support"
locale_values["localizedURLs"] = {"ja" => {"supportURL" => ja_support_url}}
locale_values["localizedPublicPages"] = {"ja" => {"supportURL" => locale_values["publicPages"]["supportURL"].merge("url" => ja_support_url)}}
File.write(File.join(project, preparation_path), JSON.generate(locale_values))
report = refresh_planning_proofs.call
abort "separately approved localized URL did not prepare" unless report["status"] == "prepared"
support_row = ->(value, locale) { value["fields"].find { |row| row["fieldId"] == "supportURL" && row["locale"] == locale } }
abort "Japanese URL did not use exact override source" unless support_row.call(report, "ja")["sources"].first["anchor"] == "localizedURLs.ja.supportURL"
abort "Japanese override changed English source" unless support_row.call(report, "en-US")["sources"].first["path"] == "App Store/metadata/app.yml"
locale_index_bytes = File.binread(index_file)
locale_index = JSON.parse(locale_index_bytes)
english_proofs = locale_index["records"].find { |row| row["fieldId"] == "supportURL" && row["locale"] == "en-US" }["proofs"]
locale_index["records"].find { |row| row["fieldId"] == "supportURL" && row["locale"] == "ja" }["proofs"] = english_proofs
File.write(index_file, JSON.generate(locale_index))
report = planned_report.call
abort "English approval confirmed Japanese URL" unless support_row.call(report, "ja")["state"] == "draft" && support_row.call(report, "en-US")["state"] == "confirmed"
File.binwrite(index_file, locale_index_bytes)
locale_values["localizedURLs"]["ja"]["supportURL"] = nil
File.write(File.join(project, preparation_path), JSON.generate(locale_values))
report = planned_report.call
abort "explicit unknown localized URL fell back to shared source" unless support_row.call(report, "ja")["reasons"].include?("missing-value") && support_row.call(report, "ja")["sources"].first["anchor"] == "localizedURLs.ja.supportURL"
locale_values["localizedURLs"] = {"fr" => {"supportURL" => ja_support_url}}
File.write(File.join(project, preparation_path), JSON.generate(locale_values))
abort "unmodeled locale override was ignored" unless support_row.call(planned_report.call, "en-US")["reasons"].include?("invalid-localized-url-schema")
File.binwrite(File.join(project, preparation_path), asset_originals[preparation_path])
File.write(index_file, JSON.generate(full_index))
abort "localized inspection changed original prepared sources" unless planned_report.call["status"] == "prepared"
puts "PASS: exact ASC localization groups and separately approved URL overrides reject wrong-locale proofs, missing form properties and unknown-to-default fallback"

# An actual review-detail shape has one version-wide Notes field, four contact
# properties and three demo properties. Public evidence stores references only.
git.call("add", "Config", "GardenNotes", "GardenNotes.xcodeproj", "App Store", "specs")
git.call("-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "synthetic reviewed store sources")
review_sha = git.call("rev-parse", "HEAD")
review_row = planned_report.call["fields"].find { |row| row["fieldId"] == "reviewNotes" }
notes_record = {"fieldId" => "reviewNotes", "locale" => nil, "proofs" => {}, "remoteReadback" => nil}
review_row["classification"].each do |kind|
  original = full_index["records"].find { |record| record["fieldId"] == "reviewNotes" }["proofs"][kind]
  proof = JSON.parse(File.binread(File.join(project, original["path"])))
  proof["sourceFingerprint"] = review_row["sourceFingerprint"]
  proof["checkedAt"] = Time.now.utc.iso8601
  proof["basis"] = [source_descriptor.call(spec_relative, "# Garden journal").merge("revision" => review_sha), source_descriptor.call(code_relative).merge("revision" => review_sha)]
  relative = "#{proof_directory}/notes-#{kind}.json"
  File.write(File.join(project, relative), JSON.generate(proof))
  notes_record["proofs"][kind] = source_descriptor.call(relative)
end
notes_body = save_body.sub("Save the selected approved app name only.", "Save the selected approved review notes only.")
  .sub("Inspect and save the selected name,", "Inspect and save the selected review notes,")
  .sub("Save the approved name and verify readback.", "Save the approved review notes and verify readback.")
  .sub("synthetic-save-name", "synthetic-save-notes")
notes_text = File.binread(File.join(project, "App Store/review/review-notes.md"))
notes_time = Time.now.utc.iso8601
notes_receipt = save_receipt.merge("sourceRevision" => review_sha, "section" => "review", "locale" => nil,
  "remoteReference" => "asc://apps/1234567890/appStoreReviewDetails/review-one",
  "savedAt" => notes_time, "observedAt" => notes_time, "protectedObservation" => "protected-observation://review-details",
  "selectedFields" => [{"fieldId" => "reviewNotes", "sourceFingerprint" => review_row["sourceFingerprint"], "valueDigest" => canonical_digest.call(notes_text)}])
notes_intent = notes_receipt.select { |key, _| %w[issue issueType repository executor operation environment identity sourceRevision section locale selectedFields remoteState remoteReference protectedObservation].include?(key) }
notes_receipt["intentDigest"] = canonical_digest.call(notes_intent)
notes_preflight = preflight.merge("checkedAt" => notes_time)
notes_preflight["digest"] = canonical_digest.call(notes_preflight.reject { |key, _| key == "digest" })
notes_values = {"reviewNotes" => notes_text, "reviewContactReference" => "keychain://garden/review/contact", "demoAccess" => "keychain://garden/review/demo", "reviewAttachments" => []}
notes_form = {"schemaVersion" => 1, "recordType" => "appstore-form-projection", "identity" => save_identity, "section" => "review", "locale" => nil, "remoteReference" => notes_receipt["remoteReference"], "values" => notes_values}
notes_inputs = {
  "contract.json" => IOSTemplate::IssueContract.parse(notes_body, issue_type: "release", issue: 901, repository: "garden-owner/garden-notes", fetched_at: notes_time).contract,
  "issue.md" => notes_body, "preflight.json" => notes_preflight,
  "approval.json" => approval.merge("reference" => "approval: user-approval://synthetic-save-notes", "checkedAt" => notes_time, "intentDigest" => notes_receipt["intentDigest"]),
  "baseline.json" => Marshal.load(Marshal.dump(notes_form)), "readback.json" => notes_form
}
notes_inputs["baseline.json"]["values"]["reviewNotes"] = "Earlier review instructions"
notes_inputs.each { |name, value| File.write(File.join(project, save_root, "notes-#{name}"), value.is_a?(String) ? value : JSON.generate(value)) }
%w[contract issueBody preflight approval baseline readback].zip(%w[contract.json issue.md preflight.json approval.json baseline.json readback.json]).each do |key, name|
  notes_receipt[key] = source_descriptor.call("#{save_root}/notes-#{name}")
end
File.write(File.join(project, save_root, "notes-receipt.json"), JSON.generate(notes_receipt))
notes_record["remoteReadback"] = source_descriptor.call("#{save_root}/notes-receipt.json")
File.write(index_file, JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-preparation-confirmations", "records" => [notes_record]}))
private_notes_values = {
  "reviewContactReference" => {"contactFirstName" => "Review", "contactLastName" => "Fixture", "contactPhone" => "+1-555-0100", "contactEmail" => "private-review-fixture@sample.invalid"},
  "demoAccess" => {"demoAccountRequired" => false, "demoAccountName" => nil, "demoAccountPassword" => nil}
}
notes_observation = notes_receipt.select { |key, _| %w[source identity sourceRevision section locale intentDigest savedAt observedAt].include?(key) }.merge(
  "reference" => notes_receipt["protectedObservation"], "references" => notes_values.select { |key, _| %w[reviewContactReference demoAccess].include?(key) },
  "baseline" => private_notes_values, "readback" => Marshal.load(Marshal.dump(private_notes_values)))
notes_check = lambda do |label, mutation, reason|
  observation = Marshal.load(Marshal.dump(notes_observation))
  mutation.call(observation) if mutation
  payload = {"schemaVersion" => 1, "recordType" => "appstore-protected-form-input", "observations" => [observation]}
  stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project, "--protected-forms-stdin", stdin_data: JSON.generate(payload))
  abort "#{label}: failed safe review-detail output" unless status.exitstatus == 1 && stderr.empty?
  row = JSON.parse(stdout)["fields"].find { |field| field["fieldId"] == "reviewNotes" }
  abort "#{label}: wrong review-detail result #{row['reasons']}" unless reason ? row["state"] == "draft" && row["reasons"].include?(reason) : row["state"] == "remote-saved"
  abort "#{label}: review contact leaked" if stdout.include?("private-review-fixture@sample.invalid")
end
notes_check.call("version-wide review notes preserve complete private details", nil, nil)
notes_check.call("omitted demo requirement is not false", ->(o) { %w[baseline readback].each { |key| o[key]["demoAccess"].delete("demoAccountRequired") } }, "incomplete-protected-review-details")
notes_check.call("required demo needs credentials", ->(o) { %w[baseline readback].each { |key| o[key]["demoAccess"]["demoAccountRequired"] = true } }, "incomplete-protected-review-details")
notes_check.call("contact property omitted from both snapshots", ->(o) { %w[baseline readback].each { |key| o[key]["reviewContactReference"].delete("contactPhone") } }, "incomplete-protected-review-details")
notes_check.call("changed protected contact", ->(o) { o["readback"]["reviewContactReference"]["contactFirstName"] = "Changed" }, "protected-form-value-mismatch")
puts "PASS: version-wide review notes require complete observed contact and demo details and preserve their actual private values"

# A source inventory chapter is not an ASC resource. Give a local-only module
# the same valid source/contract/approval envelope as a save; it must never be
# accepted as an invented Apple metadata field.
module_row = planned_report.call["fields"].find { |row| row["fieldId"] == "identity.module" }
module_proof = JSON.parse(File.binread(File.join(project, notes_record["proofs"]["derive"]["path"])))
module_proof.merge!("fieldId" => "identity.module", "section" => "identity", "sourceFingerprint" => module_row["sourceFingerprint"])
module_proof_path = "#{proof_directory}/module-derive.json"
File.write(File.join(project, module_proof_path), JSON.generate(module_proof))
module_record = {"fieldId" => "identity.module", "locale" => nil, "proofs" => {"derive" => source_descriptor.call(module_proof_path)}, "remoteReadback" => nil}
module_index = {"schemaVersion" => 1, "recordType" => "appstore-preparation-confirmations", "records" => [module_record]}
File.write(index_file, JSON.generate(module_index))
abort "local module fixture lacks actual confirmation" unless planned_report.call["fields"].find { |row| row["fieldId"] == "identity.module" }["state"] == "confirmed"
module_body = notes_body.gsub("review notes", "module name").sub("synthetic-save-notes", "synthetic-save-module")
module_receipt = notes_receipt.reject { |key, _| key == "protectedObservation" }.merge(
  "section" => "identity", "remoteReference" => "asc://apps/1234567890/identity/module",
  "selectedFields" => [{"fieldId" => "identity.module", "sourceFingerprint" => module_row["sourceFingerprint"], "valueDigest" => canonical_digest.call("GardenNotes")}])
module_intent = module_receipt.select { |key, _| %w[issue issueType repository executor operation environment identity sourceRevision section locale selectedFields remoteState remoteReference].include?(key) }
module_receipt["intentDigest"] = canonical_digest.call(module_intent)
module_values = {"identity.displayName" => "Garden Notes", "identity.module" => "GardenNotes", "identity.slug" => "garden-notes", "identity.bundleId" => "com.example.garden"}
module_form = notes_form.merge("section" => "identity", "remoteReference" => module_receipt["remoteReference"], "values" => module_values)
module_inputs = {
  "contract.json" => IOSTemplate::IssueContract.parse(module_body, issue_type: "release", issue: 901, repository: "garden-owner/garden-notes", fetched_at: notes_time).contract,
  "issue.md" => module_body, "preflight.json" => notes_preflight,
  "approval.json" => approval.merge("reference" => "approval: user-approval://synthetic-save-module", "checkedAt" => notes_time, "intentDigest" => module_receipt["intentDigest"]),
  "baseline.json" => module_form, "readback.json" => module_form
}
module_inputs.each { |name, value| File.write(File.join(project, save_root, "module-#{name}"), value.is_a?(String) ? value : JSON.generate(value)) }
%w[contract issueBody preflight approval baseline readback].zip(%w[contract.json issue.md preflight.json approval.json baseline.json readback.json]).each do |key, name|
  module_receipt[key] = source_descriptor.call("#{save_root}/module-#{name}")
end
File.write(File.join(project, save_root, "module-receipt.json"), JSON.generate(module_receipt))
module_record["remoteReadback"] = source_descriptor.call("#{save_root}/module-receipt.json")
File.write(index_file, JSON.generate(module_index))
module_result = planned_report.call["fields"].find { |row| row["fieldId"] == "identity.module" }
abort "local module was accepted as a remote metadata save: #{module_result['state']} #{module_result['reasons']}" unless module_result["state"] == "draft" && module_result["reasons"].include?("not-a-remote-metadata-field")
puts "PASS: confirmed local module identity cannot become remote-saved through an invented ASC form"

# Shared metadata lives on distinct resources. Exercise real source rows and
# approvals, without inventing a combined "version + export" or "category +
# questionnaire" form from report chapter membership.
[
  ["copyright", "appStoreVersions", {"version" => "1.0", "copyright" => nil, "earliestReleaseDate" => nil, "releaseType" => "MANUAL", "downloadable" => true, "reviewType" => "APP_STORE", "usesIdfa" => false, "build" => nil}, "releaseType"],
  ["category", "appInfos", {"category" => nil, "primarySubcategoryOne" => nil, "primarySubcategoryTwo" => nil, "secondaryCategory" => nil, "secondarySubcategoryOne" => nil, "secondarySubcategoryTwo" => nil}, "primarySubcategoryOne"]
].each do |field_id, resource, observed_values, preserved_field|
  target_row = planned_report.call["fields"].find { |row| row["fieldId"] == field_id }
  target_source = target_row["sources"].first
  target_value = YAML.safe_load(File.binread(File.join(project, target_source["path"]))).fetch(target_source["anchor"])
  target_record = {"fieldId" => field_id, "locale" => nil, "proofs" => {}, "remoteReadback" => nil}
  %w[derive user].each do |kind|
    proof = JSON.parse(File.binread(File.join(project, notes_record["proofs"][kind]["path"])))
    proof.merge!("fieldId" => field_id, "section" => target_row["section"], "sourceFingerprint" => target_row["sourceFingerprint"])
    relative = "#{proof_directory}/#{field_id}-#{kind}.json"
    File.write(File.join(project, relative), JSON.generate(proof))
    target_record["proofs"][kind] = source_descriptor.call(relative)
  end
  target_body = notes_body.gsub("review notes", field_id).sub("synthetic-save-notes", "synthetic-save-#{field_id}")
  target_receipt = notes_receipt.reject { |key, _| key == "protectedObservation" }.merge(
    "section" => target_row["section"], "remoteReference" => "asc://apps/1234567890/#{resource}/#{field_id}-resource",
    "selectedFields" => [{"fieldId" => field_id, "sourceFingerprint" => target_row["sourceFingerprint"], "valueDigest" => canonical_digest.call(target_value)}])
  target_intent = target_receipt.select { |key, _| %w[issue issueType repository executor operation environment identity sourceRevision section locale selectedFields remoteState remoteReference].include?(key) }
  target_receipt["intentDigest"] = canonical_digest.call(target_intent)
  target_form = notes_form.merge("section" => target_row["section"], "remoteReference" => target_receipt["remoteReference"], "values" => observed_values)
  target_readback = Marshal.load(Marshal.dump(target_form))
  target_readback["values"][field_id] = target_value
  target_inputs = {
    "contract.json" => IOSTemplate::IssueContract.parse(target_body, issue_type: "release", issue: 901, repository: "garden-owner/garden-notes", fetched_at: notes_time).contract,
    "issue.md" => target_body, "preflight.json" => notes_preflight,
    "approval.json" => approval.merge("reference" => "approval: user-approval://synthetic-save-#{field_id}", "checkedAt" => notes_time, "intentDigest" => target_receipt["intentDigest"]),
    "baseline.json" => target_form, "readback.json" => target_readback
  }
  check_target = lambda do |label, mutation, expected_reason|
    inputs, receipt, record = Marshal.load(Marshal.dump([target_inputs, target_receipt, target_record]))
    mutation.call(inputs, receipt) if mutation
    inputs.each { |name, value| File.write(File.join(project, save_root, "#{field_id}-#{name}"), value.is_a?(String) ? value : JSON.generate(value)) }
    %w[contract issueBody preflight approval baseline readback].zip(%w[contract.json issue.md preflight.json approval.json baseline.json readback.json]).each do |key, name|
      receipt[key] = source_descriptor.call("#{save_root}/#{field_id}-#{name}")
    end
    relative = "#{save_root}/#{field_id}-receipt.json"
    File.write(File.join(project, relative), JSON.generate(receipt))
    record["remoteReadback"] = source_descriptor.call(relative)
    File.write(index_file, JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-preparation-confirmations", "records" => [record]}))
    stdout, stderr, status = Open3.capture3(entrypoint, "--project-root", project)
    abort "#{label}: changed read-only behavior" unless status.exitstatus == 1 && stderr.empty?
    report = JSON.parse(stdout)
    result = report["fields"].find { |row| row["fieldId"] == field_id }
    abort "#{label}: wrong #{field_id} resource result #{result['state']} #{result['reasons']}" unless expected_reason ? result["state"] == "draft" && result["reasons"].include?(expected_reason) : result["state"] == "remote-saved"
    abort "#{label}: claimed release or live operation" unless report["remoteMutations"] == [] && report["liveRemoteInspection"] == false && report["releaseReady"] == false
  end
  check_target.call("actual #{resource} projection", nil, nil)
  check_target.call("omitted #{preserved_field} in both snapshots", ->(inputs, _) { %w[baseline.json readback.json].each { |name| inputs[name]["values"].delete(preserved_field) } }, "incomplete-remote-form")
  check_target.call("changed preserved #{preserved_field}", ->(inputs, _) { inputs["readback.json"]["values"][preserved_field] = "DIFFERENT" }, "remote-preserved-value-mismatch")
  check_target.call("different #{resource} readback", ->(inputs, _) { inputs["readback.json"]["remoteReference"] = "asc://apps/1234567890/#{resource}/other-resource" }, "incomplete-remote-form")
end
puts "PASS: copyright and category readbacks bind their actual resources and complete preserved attributes without accepting unrelated source chapters"
RUBY
