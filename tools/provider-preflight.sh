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
  provider-preflight.sh --issue NUMBER github --target OWNER/REPO
  provider-preflight.sh --issue NUMBER supabase --environment local|preview|staging|production
  provider-preflight.sh --issue NUMBER cloudflare --target IDENTIFIER
  provider-preflight.sh --issue NUMBER elevenlabs --operation text-to-speech|speech-to-speech|speech-to-text|sound-effect|audio-isolation|music|image|video
  provider-preflight.sh --issue NUMBER app-store --version VERSION
USAGE
  exit 2
}

[[ $# -ge 3 && $1 == --issue ]] || usage
issue_number=${2:-}
provider=${3:-}
shift 3
[[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || fail 'Issue number is invalid'
case "$provider" in
  github|supabase|cloudflare|elevenlabs|app-store) ;;
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
  elevenlabs)
    [[ -n "$requested_media_operation" && -z "$requested_target$requested_environment$requested_version" ]] || usage
    [[ "$requested_media_operation" =~ ^(text-to-speech|speech-to-speech|speech-to-text|sound-effect|audio-isolation|music|image|video)$ ]] || fail 'ElevenLabs operation is invalid'
    evidence_environment=production
    evidence_operation=elevenlabs.process_media
    ;;
  app-store)
    [[ -n "$requested_version" && -z "$requested_target$requested_environment$requested_media_operation" ]] || usage
    [[ "$requested_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || fail 'App Store version is invalid'
    evidence_environment=production
    evidence_operation=appstore.inspect_app
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
  [[ "$provider_adapter" == /* && -f "$provider_adapter" && -x "$provider_adapter" && ! -L "$provider_adapter" ]] || fail 'test provider adapter is invalid'
else
  [[ -z "${IOS_TEMPLATE_TEST_OWNERSHIP_FILE:-}${IOS_TEMPLATE_TEST_ARTIFACT_ROOT:-}${IOS_TEMPLATE_TEST_NOW:-}${IOS_TEMPLATE_TEST_PROVIDER_BIN:-}" ]] || fail 'test overrides are not allowed in production mode'
fi

[[ "$checked_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail 'checked timestamp is invalid'
[[ -f "$ownership_file" && ! -L "$ownership_file" ]] || fail 'ownership configuration is unavailable'

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-provider-preflight.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT
chmod 700 "$temporary_directory"
raw_response="$temporary_directory/raw.json"

if [[ "$test_mode" == 1 ]]; then
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
      fail 'Cloudflare target inspection requires a Codex provider adapter that is not configured'
      ;;
    elevenlabs)
      fail 'ElevenLabs entitlement inspection requires the Codex media capability'
      ;;
    app-store)
      fail 'App Store identity inspection requires the authenticated Codex App Store workflow'
      ;;
  esac
fi
chmod 600 "$raw_response"

expected_identity=$(PROVIDER="$provider" OWNERSHIP="$ownership_file" REPO_TARGET="$requested_target" ruby -rjson -ryaml -e '
  value=YAML.safe_load(File.binread(ENV.fetch("OWNERSHIP")), permitted_classes: [], aliases: false)
  abort unless value.is_a?(Hash) && value["schemaVersion"] == 1
  provider=ENV.fetch("PROVIDER")
  pair=case provider
       when "github" then [value.dig("github","login"), ENV.fetch("REPO_TARGET")]
       when "supabase" then [value.dig("supabase","organization"), value.dig("supabase","projectRef")]
       when "cloudflare" then [value.dig("cloudflare","accountId"), value.dig("cloudflare","target")]
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

candidate="$temporary_directory/candidate.json"
PROVIDER="$provider" ISSUE="$issue_number" ACCOUNT="$expected_account" TARGET="$expected_target" \
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
        "schemaVersion"=>1,"issue"=>Integer(ENV.fetch("ISSUE")),"provider"=>provider,
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
destination="$destination_physical/$provider.json"
publication=$(mktemp "$destination.tmp.XXXXXX")
/bin/cp "$candidate" "$publication"
chmod 600 "$publication"
/bin/mv -f "$publication" "$destination"
/bin/cat "$destination"
