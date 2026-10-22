#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby /usr/bin/git
repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-preparation-migration.XXXXXX")
trap 'rm -rf -- "$test_workspace"' EXIT

ruby -rjson -rfileutils -ropen3 -rdigest - "$repo_root" "$test_workspace" <<'RUBY'
repo, scratch = ARGV
project = File.realpath(scratch)
metadata = File.join(project, "App Store/metadata")
FileUtils.mkdir_p(metadata)
ledger = File.join(metadata, "reviewed-draft.md")
ledger_bytes = <<~MARKDOWN
  # Previously reviewed app draft
  SKU: garden-reviewed-sku
  State: confirmed
  Remote state: remote-saved
  Age rating: unanswered
  Review contact: keychain://garden/review/contact
  Decision history: preserve this user-authored wording.
MARKDOWN
File.binwrite(ledger, ledger_bytes)
# #356: App Store/metadata/app.yml belongs to the app, and an app that adopted the template (it records
# Config/template-base.json, D-074) has its own or none yet. There the fixture uses the template's sample
# below; the template itself keeps copying its own file.
adopted = File.file?(File.join(repo, "Config/template-base.json"))
app_schema = if adopted
  <<~YAML.b
    schemaVersion: 1
    bundleId: "com.yuto.TemplateApp"
    version: "1.0"
    primaryLocale: "en-US"
    platforms:
      iphone: true
      ipad: true
    category: "Utilities"
    copyright: "Draft \u2014 replace for the app release"
    supportURL: "https://support.example.invalid/template-app"
    privacyPolicyURL: "https://support.example.invalid/template-app/privacy"
    reviewContactReference: "keychain://app-store-connect/review-contact"
    accountsSupported: false
  YAML
else
  File.binread(File.join(repo, "App Store/metadata/app.yml"))
end
File.binwrite(File.join(metadata, "app.yml"), app_schema)
File.binwrite(File.join(project, "user-notes.txt"), "User notes remain unchanged.\n")
FileUtils.mkdir_p(File.join(project, "App Store/submission"))
# Opaque historical bytes are preservation fixtures, not fabricated valid
# release receipts. Actual package/result compatibility has its own suite.
File.binwrite(File.join(project, "App Store/submission/legacy-package.json"), "{\"immutableHistoricalFixture\":\"package\"}\n")
File.binwrite(File.join(project, "App Store/submission/legacy-result.json"), "{\"immutableHistoricalFixture\":\"result\"}\n")
snapshot = lambda do
  Dir.glob(File.join(project, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.to_h do |path|
    [path.delete_prefix(project + "/"), Digest::SHA256.file(path).hexdigest]
  end
end
inspect_sources = lambda do
  before = snapshot.call
  stdout, stderr, status = Open3.capture3(File.join(repo, "tools/prepare-appstore-sources.sh"), "--project-root", project)
  abort "migration inspection failed" unless status.exitstatus == 1 && stderr.empty?
  report = JSON.parse(stdout)
  abort "migration inspection wrote user sources" unless snapshot.call == before
  abort "migration inspection invented authority" unless report["status"] == "blocked" && report["remoteMutations"] == [] && report["releaseReady"] == false && report["liveRemoteInspection"] == false
  report
end
row = ->(report, id) { report["fields"].find { |entry| entry["fieldId"] == id } }
before_migration = inspect_sources.call
abort "ledger status became confirmation" unless row.call(before_migration, "sku")["state"] == "draft" && row.call(before_migration, "sku")["reasons"].include?("missing-source")
abort "ledger silently generated preparation JSON" if File.exist?(File.join(metadata, "preparation.json"))

# This explicit fixture action models the documented reviewed transcription,
# not a parser guessing values or a mutating checker. No confirmation is copied.
File.binwrite(File.join(metadata, "preparation.json"), JSON.generate({"schemaVersion" => 1, "recordType" => "appstore-preparation-sources", "sku" => "garden-reviewed-sku"}))
after_migration = inspect_sources.call
sku = row.call(after_migration, "sku")
abort "copied wording became confirmed" unless sku["state"] == "draft" && sku["sources"].first["anchor"] == "sku" && sku["sources"].first["digest"].start_with?("sha256:") && sku["sources"].first["revision"].nil?
abort "migration invented questionnaire answers" unless row.call(after_migration, "ageRating")["state"] == "draft" && row.call(after_migration, "ageRating")["reasons"].include?("missing-value")
abort "migration rewrote the original ledger" unless File.binread(ledger) == ledger_bytes
abort "migration changed exact legacy app schema" unless File.binread(File.join(metadata, "app.yml")) ==
  (adopted ? app_schema : File.binread(File.join(repo, "App Store/metadata/app.yml")))
puts "PASS: explicit reviewed-draft transcription preserves original and historical bytes, never copies status into evidence, and keeps unanswered fields unresolved"
RUBY
