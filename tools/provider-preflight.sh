#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)

fail() {
  printf '%s\n' "provider preflight refused: $1" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
usage:
  provider-preflight.sh --executor codex|claude --issue NUMBER github --target OWNER/REPO
  provider-preflight.sh --executor codex|claude --issue NUMBER supabase --environment local|preview|staging|production
  provider-preflight.sh --executor codex|claude --issue NUMBER cloudflare --target IDENTIFIER
  provider-preflight.sh --executor codex|claude --issue NUMBER linear --target TEAM_KEY
  provider-preflight.sh --executor codex|claude --issue NUMBER vercel --target TEAM_SLUG
  provider-preflight.sh --executor codex|claude --issue NUMBER elevenlabs --operation text-to-speech|speech-to-speech|speech-to-text|sound-effect|audio-isolation|music|image|video
  provider-preflight.sh --executor codex|claude --issue NUMBER app-store --version VERSION [--operation appstore.OPERATION]
USAGE
  exit 2
}

[[ $# -ge 5 && $1 == --executor ]] || usage
executor=${2:-}
shift 2
[[ "$executor" == codex || "$executor" == claude ]] || fail 'Executor must be codex or claude'
[[ $1 == --issue ]] || usage
issue_number=${2:-}
provider=${3:-}
shift 3
[[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || fail 'Issue number is invalid'
case "$provider" in
  github|supabase|cloudflare|linear|vercel|elevenlabs|app-store) ;;
  *) usage ;;
esac

requested_target=''
requested_environment=''
requested_media_operation=''
requested_version=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) requested_target=${2:-}; shift 2 ;;
    --environment) requested_environment=${2:-}; shift 2 ;;
    --operation) requested_media_operation=${2:-}; shift 2 ;;
    --version) requested_version=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done

case "$provider" in
  github)
    [[ -n "$requested_target" && -z "$requested_environment$requested_media_operation$requested_version" ]] || usage
    [[ "$requested_target" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'GitHub target is invalid'
    evidence_environment=production
    evidence_operation=github.read_issue
    ;;
  supabase)
    [[ -n "$requested_environment" && -z "$requested_target$requested_media_operation$requested_version" ]] || usage
    [[ "$requested_environment" =~ ^(local|preview|staging|production)$ ]] || fail 'Supabase environment is invalid'
    evidence_environment=$requested_environment
    evidence_operation=supabase.inspect_project
    ;;
  cloudflare)
    [[ -n "$requested_target" && -z "$requested_environment$requested_media_operation$requested_version" ]] || usage
    [[ "$requested_target" =~ ^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,255}$ ]] || fail 'Cloudflare target is invalid'
    evidence_environment=production
    evidence_operation=cloudflare.inspect_account
    ;;
  linear)
    [[ -n "$requested_target" && -z "$requested_environment$requested_media_operation$requested_version" ]] || usage
    [[ "$requested_target" =~ ^[A-Za-z][A-Za-z0-9_-]{1,31}$ ]] || fail 'Linear team key is invalid'
    evidence_environment=production
    evidence_operation=linear.inspect_workspace
    ;;
  vercel)
    [[ -n "$requested_target" && -z "$requested_environment$requested_media_operation$requested_version" ]] || usage
    [[ "$requested_target" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] || fail 'Vercel team slug is invalid'
    evidence_environment=production
    evidence_operation=vercel.inspect_team
    ;;
  elevenlabs)
    [[ -n "$requested_media_operation" && -z "$requested_target$requested_environment$requested_version" ]] || usage
    [[ "$requested_media_operation" =~ ^(text-to-speech|speech-to-speech|speech-to-text|sound-effect|audio-isolation|music|image|video)$ ]] || fail 'ElevenLabs operation is invalid'
    evidence_environment=production
    evidence_operation=elevenlabs.process_media
    ;;
  app-store)
    [[ -n "$requested_version" && -z "$requested_target$requested_environment" ]] || usage
    [[ "$requested_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || fail 'App Store version is invalid'
    evidence_environment=production
    evidence_operation=${requested_media_operation:-appstore.inspect_app}
    case "$evidence_operation" in
      appstore.inspect_app|appstore.update_metadata|appstore.upload_build|appstore.submit_review|appstore.distribute_testflight) ;;
      *) fail 'App Store operation is invalid' ;;
    esac
    ;;
esac

test_mode=${IOS_TEMPLATE_TEST_MODE:-0}
ownership_file="$repo_root/Config/ownership.yml"
artifact_root="$repo_root/.artifacts"
checked_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
provider_adapter=''
if [[ "$test_mode" == 1 ]]; then
  ownership_file=${IOS_TEMPLATE_TEST_OWNERSHIP_FILE:-}
  artifact_root=${IOS_TEMPLATE_TEST_ARTIFACT_ROOT:-}
  checked_at=${IOS_TEMPLATE_TEST_NOW:-}
  provider_adapter=${IOS_TEMPLATE_TEST_PROVIDER_BIN:-}
  [[ "$ownership_file" == /* && -f "$ownership_file" && ! -L "$ownership_file" ]] || fail 'test ownership file is invalid'
  [[ "$artifact_root" == /* ]] || fail 'test artifact root is invalid'
  if [[ "$provider" != app-store ]]; then
    [[ "$provider_adapter" == /* && -f "$provider_adapter" && -x "$provider_adapter" && ! -L "$provider_adapter" ]] || fail 'test provider adapter is invalid'
  fi
else
  [[ -z "${IOS_TEMPLATE_TEST_OWNERSHIP_FILE:-}${IOS_TEMPLATE_TEST_ARTIFACT_ROOT:-}${IOS_TEMPLATE_TEST_NOW:-}${IOS_TEMPLATE_TEST_PROVIDER_BIN:-}${IOS_TEMPLATE_TEST_ASC_RUNNER:-}" ]] || fail 'test overrides are not allowed in production mode'
fi

[[ "$checked_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail 'checked timestamp is invalid'
[[ -f "$ownership_file" && ! -L "$ownership_file" ]] || fail 'ownership configuration is unavailable'

if [[ "$provider" == app-store ]]; then
  issue_root="$artifact_root/issues/$issue_number"
  [[ -f "$issue_root/issue-contract.json" && ! -L "$issue_root/issue-contract.json" && -f "$issue_root/state.json" && ! -L "$issue_root/state.json" ]] || fail 'sealed Issue contract is unavailable'
  ISSUE="$issue_number" OPERATION="$evidence_operation" /usr/bin/ruby --disable-gems -rjson -rdigest -e '
    issue=Integer(ENV.fetch("ISSUE"))
    contract_path,state_path=ARGV
    [contract_path,state_path].each do |path|
      stat=File.lstat(path)
      abort unless stat.file? && stat.nlink == 1
    end
    bytes=File.binread(contract_path)
    contract=JSON.parse(bytes)
    state=JSON.parse(File.binread(state_path))
    abort unless contract.is_a?(Hash) && contract["issue"] == issue && contract["externalOperations"].is_a?(Array) && contract["externalOperations"].include?(ENV.fetch("OPERATION"))
    seal=state.fetch("issueContract")
    abort unless state["issue"] == issue && seal.fetch("path") == ".artifacts/issues/#{issue}/issue-contract.json" && seal.fetch("digest") == "sha256:#{Digest::SHA256.hexdigest(bytes)}"
  ' "$issue_root/issue-contract.json" "$issue_root/state.json" 2>/dev/null || fail 'App Store operation is not in the sealed Issue contract'
  expected_bundle_id=$(/usr/bin/ruby --disable-gems "$repo_root/tools/lib/ownership.rb" --file "$ownership_file" --provider app-store | jq -er '.target | strings') || fail 'configured App Store Bundle ID is missing or invalid'
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-provider-preflight.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT
chmod 700 "$temporary_directory"
raw_response="$temporary_directory/raw.json"

run_app_store_inspection() {
  /usr/bin/ruby --disable-gems - "$repo_root" "$expected_bundle_id" "$requested_version" > "$raw_response" 2>/dev/null <<'RUBY' || fail 'App Store inspection failed'
require "json"
require "open3"

# asc 5.4.0 source: internal/cli/{bundleids/bundle_ids.go,apps/apps.go,
# versions/versions.go} pass API responses to internal/cli/shared/shared.go
# PrintOutput/printOutput, whose JSON branch uses internal/asc/output_core.go
# PrintJSON to encode the response object.
# internal/asc/types/resources.go defines data[], resource id/attributes,
# links.next and meta.paging.total. internal/asc/{signing.go,client_apps.go,
# client_versions.go} define attributes.identifier/seedId, bundleId,
# versionString and platform.
module AppStoreASCPreflight
  MAX_OUTPUT_BYTES = 1_048_576
  class Refused < StandardError; end
  module_function

  def refuse
    raise Refused
  end

  def runner(root)
    override = ENV["IOS_TEMPLATE_TEST_ASC_RUNNER"]
    return File.join(root, "tools/asc-run.sh") unless override
    refuse unless ENV["IOS_TEMPLATE_TEST_MODE"] == "1"
    refuse unless override.start_with?("/") && File.expand_path(override) == override
    cursor = "/"
    override.split("/").reject(&:empty?).each do |component|
      cursor = File.join(cursor, component)
      refuse if File.lstat(cursor).symlink?
    end
    stat = File.lstat(override)
    refuse unless stat.file? && File.executable?(override)
    override
  end

  def list(runner_path, type, *command)
    output, _error, status = Open3.capture3(runner_path, "--operation", "appstore.inspect_app", "--", *command, "--output", "json")
    refuse unless status.success? && output.bytesize <= MAX_OUTPUT_BYTES
    value = JSON.parse(output)
    refuse unless value.is_a?(Hash) && value["data"].is_a?(Array)
    links = value["links"]
    refuse unless links.nil? || (links.is_a?(Hash) && (links["next"].nil? || links["next"] == ""))
    total = value.dig("meta", "paging", "total")
    refuse if !total.nil? && (!total.instance_of?(Integer) || total != value["data"].length)
    value["data"].each do |item|
      refuse unless item.is_a?(Hash) && item["type"] == type && item["id"].is_a?(String) && !item["id"].empty? && item["attributes"].is_a?(Hash)
    end
    value["data"]
  end

  def one(items)
    refuse unless items.length == 1
    items.first
  end

  def main(root, bundle_id, version)
    refuse unless bundle_id.match?(/\A[A-Za-z0-9][A-Za-z0-9.-]*\z/) && version.match?(/\A[0-9]+(?:\.[0-9]+){1,2}\z/)
    run = runner(root)
    bundle = one(list(run, "bundleIds", "bundle-ids", "list", "--identifier", bundle_id))
    refuse unless bundle.dig("attributes", "identifier") == bundle_id
    seed_id = bundle.dig("attributes", "seedId")
    refuse unless seed_id.is_a?(String) && seed_id.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
    app = one(list(run, "apps", "apps", "list", "--bundle-id", bundle_id))
    refuse unless app.dig("attributes", "bundleId") == bundle_id
    app_id = app["id"]
    refuse unless app_id.match?(/\A[1-9][0-9]*\z/)
    versions = list(run, "appStoreVersions", "versions", "list", "--app", app_id, "--version", version, "--platform", "IOS")
    found = one(versions)
    refuse unless found.dig("attributes", "versionString") == version && found.dig("attributes", "platform") == "IOS"
    STDOUT.write(JSON.generate({"provider"=>"app-store", "account"=>seed_id, "target"=>bundle_id, "health"=>"healthy", "versions"=>versions.map { |entry| entry.dig("attributes", "versionString") }}))
    STDOUT.write("\n")
    0
  rescue Refused, JSON::ParserError, ArgumentError, TypeError, SystemCallError
    warn "App Store inspection failed"
    1
  end
end

exit AppStoreASCPreflight.main(*ARGV)
RUBY
}

if [[ "$provider" == app-store ]]; then
  run_app_store_inspection
elif [[ "$test_mode" == 1 ]]; then
  "$provider_adapter" "$provider" "$evidence_operation" > "$raw_response" 2>/dev/null || fail 'provider adapter failed'
else
  case "$provider" in
    github)
      command -v gh >/dev/null 2>&1 || fail 'GitHub CLI is unavailable'
      github_account=$(gh api user --jq .login 2>/dev/null) || fail 'GitHub identity inspection failed'
      github_target=$(gh repo view "$requested_target" --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || fail 'GitHub target inspection failed'
      ACCOUNT="$github_account" TARGET="$github_target" ruby -rjson -e 'puts JSON.generate({"provider"=>"github","account"=>ENV.fetch("ACCOUNT"),"target"=>ENV.fetch("TARGET"),"health"=>"healthy"})' > "$raw_response"
      ;;
    supabase)
      command -v supabase >/dev/null 2>&1 || fail 'Supabase CLI is unavailable'
      supabase projects list --output json > "$temporary_directory/provider-native.json" 2>/dev/null || fail 'Supabase project inspection failed'
      /usr/bin/ruby -rjson -e '
        expected=ARGV.fetch(1); entries=JSON.parse(File.binread(ARGV.fetch(0))); abort unless entries.is_a?(Array)
        project=entries.find{|entry| entry.is_a?(Hash) && [entry["id"],entry["project_ref"],entry["ref"]].compact.include?(expected)} or abort
        account=project["organization_name"] || project["organization_slug"] || project["organization_id"]
        status=(project["status"] || project["health"] || "").to_s.downcase
        health=%w[healthy active active_healthy].include?(status) ? "healthy" : "unhealthy"
        puts JSON.generate({"provider"=>"supabase","account"=>account,"target"=>expected,"health"=>health})
      ' "$temporary_directory/provider-native.json" "$(ruby "$repo_root/tools/lib/ownership.rb" --file "$ownership_file" --provider supabase | jq -er .target)" > "$raw_response" 2>/dev/null || fail 'Supabase response could not prove the configured project'
      ;;
    cloudflare)
      fail 'Cloudflare target inspection requires an authenticated provider adapter that is not configured'
      ;;
    linear)
      fail 'Linear workspace inspection requires an authenticated provider adapter that is not configured'
      ;;
    vercel)
      fail 'Vercel team inspection requires an authenticated provider adapter that is not configured'
      ;;
    elevenlabs)
      fail 'ElevenLabs entitlement inspection requires an authenticated media capability'
      ;;
    app-store)
      fail 'App Store inspection dispatch is invalid'
      ;;
  esac
fi
chmod 600 "$raw_response"

expected_identity=$(PROVIDER="$provider" OWNERSHIP="$ownership_file" REPO_TARGET="$requested_target" ruby -rjson -ryaml -e '
  value=YAML.safe_load(File.binread(ENV.fetch("OWNERSHIP")), permitted_classes: [], aliases: false)
  abort unless value.is_a?(Hash) && value["schemaVersion"] == 2
  provider=ENV.fetch("PROVIDER")
  pair=case provider
       when "github" then [value.dig("github","login"), ENV.fetch("REPO_TARGET")]
       when "supabase" then [value.dig("supabase","organizationId"), value.dig("supabase","projectRef")]
       when "cloudflare" then [value.dig("cloudflare","accountId"), value.dig("cloudflare","target")]
       when "linear" then [value.dig("linear","workspaceSlug"), value.dig("linear","teamKey")]
       when "vercel" then [value.dig("vercel","teamId"), value.dig("vercel","teamSlug")]
       when "elevenlabs" then [value.dig("elevenlabs","accountId"), value.dig("elevenlabs","workspaceId")]
       when "app-store" then [value.dig("appStore","teamId"), value.dig("appStore","bundleId")]
       else abort
       end
  safe=/\A[A-Za-z0-9][A-Za-z0-9 ._:@\/-]{0,255}\z/
  abort unless pair.all?{|entry| entry.is_a?(String) && entry.match?(safe)}
  puts JSON.generate({"account"=>pair[0],"target"=>pair[1]})
' 2>/dev/null) || fail 'configured personal provider identity is missing or invalid'
expected_account=$(jq -er '.account | strings' <<< "$expected_identity")
expected_target=$(jq -er '.target | strings' <<< "$expected_identity")
if [[ "$provider" == github && "$requested_target" != "$expected_target" ]]; then fail 'GitHub target differs from the requested repository'; fi
if [[ "$provider" == cloudflare && "$requested_target" != "$expected_target" ]]; then fail 'Cloudflare target differs from configured ownership'; fi
if [[ "$provider" == linear && "$requested_target" != "$expected_target" ]]; then fail 'Linear target differs from configured ownership'; fi
if [[ "$provider" == vercel && "$requested_target" != "$expected_target" ]]; then fail 'Vercel target differs from configured ownership'; fi

candidate="$temporary_directory/candidate.json"
PROVIDER="$provider" EXECUTOR="$executor" ISSUE="$issue_number" ACCOUNT="$expected_account" TARGET="$expected_target" \
  ENVIRONMENT="$evidence_environment" OPERATION="$evidence_operation" MEDIA_OPERATION="$requested_media_operation" \
  VERSION="$requested_version" CHECKED_AT="$checked_at" ruby -rjson -rdigest -rtime -e '
    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h{|key| [key,canonical(value.fetch(key))]}
      when Array then value.map{|entry| canonical(entry)}
      else value
      end
    end
    begin
      raw=JSON.parse(File.binread(ARGV.fetch(0)))
      raise unless raw.is_a?(Hash)
      provider=ENV.fetch("PROVIDER")
      safe=/\A[A-Za-z0-9][A-Za-z0-9 ._:@\/-]{0,255}\z/
      raise unless raw["provider"] == provider && raw["account"] == ENV.fetch("ACCOUNT") && raw["target"] == ENV.fetch("TARGET")
      raise unless raw["account"].is_a?(String) && raw["account"].match?(safe) && raw["target"].is_a?(String) && raw["target"].match?(safe)
      raise unless raw["health"] == "healthy"
      if provider == "elevenlabs"
        requested=ENV.fetch("MEDIA_OPERATION")
        capability=raw["capabilities"].is_a?(Hash) ? raw["capabilities"][requested] : nil
        if capability == "paid_plan_required"
          warn "blocked:ops: paid_plan_required"
          exit 3
        end
        raise unless capability == "available"
      end
      if provider == "app-store"
        versions=raw["versions"]
        raise unless versions.is_a?(Array) && versions.all?{|entry| entry.is_a?(String)} && versions.include?(ENV.fetch("VERSION"))
      end
      Time.iso8601(ENV.fetch("CHECKED_AT"))
      value={
        "schemaVersion"=>2,"issue"=>Integer(ENV.fetch("ISSUE")),"executor"=>ENV.fetch("EXECUTOR"),"provider"=>provider,
        "account"=>ENV.fetch("ACCOUNT"),"target"=>ENV.fetch("TARGET"),
        "environment"=>ENV.fetch("ENVIRONMENT"),"operation"=>ENV.fetch("OPERATION"),
        "health"=>"healthy","checkedAt"=>ENV.fetch("CHECKED_AT")
      }
      value["digest"]="sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
      File.binwrite(ARGV.fetch(1), JSON.generate(canonical(value))+"\n")
    rescue JSON::ParserError, ArgumentError, TypeError
      warn "provider response validation failed"
      exit 2
    rescue StandardError
      warn "provider response validation failed"
      exit 2
    end
  ' "$raw_response" "$candidate" || fail 'provider identity, target, health, entitlement, or version did not match'
chmod 600 "$candidate"

destination_directory="$artifact_root/issues/$issue_number/provider-preflights"
umask 077
mkdir -p "$destination_directory"
[[ -d "$artifact_root" && ! -L "$artifact_root" && -d "$destination_directory" && ! -L "$destination_directory" ]] || fail 'artifact directory is unavailable or unsafe'
artifact_physical=$(cd "$artifact_root" && /bin/pwd -P)
destination_physical=$(cd "$destination_directory" && /bin/pwd -P)
[[ "$destination_physical" == "$artifact_physical/issues/$issue_number/provider-preflights" ]] || fail 'artifact path escapes the configured root'
destination_name="$provider.json"
if [[ "$provider" == app-store ]]; then destination_name="app-store-${evidence_operation#appstore.}.json"; fi
destination="$destination_physical/$destination_name"
publication=$(mktemp "$destination.tmp.XXXXXX")
/bin/cp "$candidate" "$publication"
chmod 600 "$publication"
/bin/mv -f "$publication" "$destination"
/bin/cat "$destination"
