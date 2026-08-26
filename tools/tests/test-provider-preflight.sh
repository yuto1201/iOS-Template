#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-provider-preflight.XXXXXX")
trap 'rm -rf -- "$test_workspace"' EXIT

fixture_root="$repo_root/tools/tests/fixtures/providers"
adapter="$fixture_root/provider-adapter"
ownership="$fixture_root/ownership.yml"
artifact_root="$test_workspace/artifacts"
adapter_argv="$test_workspace/provider-argv"
: > "$adapter_argv"

run_preflight() {
  local response_file=$1
  shift
  IOS_TEMPLATE_TEST_MODE=1 \
    IOS_TEMPLATE_TEST_PROVIDER_BIN="$adapter" \
    IOS_TEMPLATE_TEST_PROVIDER_RESPONSE_FILE="$response_file" \
    IOS_TEMPLATE_TEST_OWNERSHIP_FILE="$ownership" \
    IOS_TEMPLATE_TEST_ARTIFACT_ROOT="$artifact_root" \
    IOS_TEMPLATE_TEST_NOW='2026-08-26T06:10:00Z' \
    FAKE_PROVIDER_RESPONSE_FILE="$response_file" \
    FAKE_PROVIDER_ARGV="$adapter_argv" \
    "$repo_root/tools/provider-preflight.sh" "$@"
}

assert_fails_without_artifact() {
  local label=$1 provider=$2 response_file=$3
  shift 3
  rm -rf -- "$artifact_root/issues/42/provider-preflights"
  if run_preflight "$response_file" --issue 42 "$provider" "$@" >"$test_workspace/stdout" 2>"$test_workspace/stderr"; then
    echo "expected failure: $label" >&2
    exit 1
  fi
  [[ ! -e "$artifact_root/issues/42/provider-preflights/$provider.json" ]] || {
    echo "failed preflight published an artifact: $label" >&2
    exit 1
  }
  if /usr/bin/grep -Fq -- 'must-not-survive' "$test_workspace/stdout" "$test_workspace/stderr"; then
    echo "raw provider response leaked: $label" >&2
    exit 1
  fi
}

assert_record() {
  local provider=$1 expected_account=$2 expected_target=$3 expected_environment=$4 expected_operation=$5
  local record="$artifact_root/issues/42/provider-preflights/$provider.json"
  [[ -f "$record" && ! -L "$record" ]] || { echo "missing provider artifact: $provider" >&2; exit 1; }
  PROVIDER="$provider" ACCOUNT="$expected_account" TARGET="$expected_target" ENVIRONMENT="$expected_environment" OPERATION="$expected_operation" \
    ruby -rjson -rdigest -e '
      value=JSON.parse(File.binread(ARGV.fetch(0)))
      abort unless value.keys.sort == %w[schemaVersion issue provider account target environment operation health checkedAt digest].sort
      abort unless value["schemaVersion"] == 1 && value["issue"] == 42
      abort unless value.values_at("provider","account","target","environment","operation","health","checkedAt") == [ENV.fetch("PROVIDER"),ENV.fetch("ACCOUNT"),ENV.fetch("TARGET"),ENV.fetch("ENVIRONMENT"),ENV.fetch("OPERATION"),"healthy","2026-08-26T06:10:00Z"]
      canonical = ->(entry) { entry.is_a?(Hash) ? entry.keys.sort.to_h { |key| [key, canonical.call(entry.fetch(key))] } : entry.is_a?(Array) ? entry.map { |item| canonical.call(item) } : entry }
      unsigned=value.reject{|key,_| key=="digest"}
      abort unless value["digest"] == "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical.call(unsigned)))}"
    ' "$record"
  if /usr/bin/grep -Fq -- 'must-not-survive' "$record"; then
    echo "provider artifact contains raw response data: $provider" >&2
    exit 1
  fi
}

rm -rf -- "$artifact_root/issues/42/provider-preflights"
github_output=$(run_preflight "$fixture_root/github-personal.json" --issue 42 github --target yuto1201/iOS-Template)
assert_record github yuto1201 yuto1201/iOS-Template production github.read_issue
[[ "$github_output" == *'"provider":"github"'* && "$github_output" != *'must-not-survive'* ]] || { echo 'GitHub output is not sanitized' >&2; exit 1; }

rm -rf -- "$artifact_root/issues/42/provider-preflights"
run_preflight "$fixture_root/supabase-personal.json" --issue 42 supabase --environment production >/dev/null
assert_record supabase YUTO1201 personal-project production supabase.inspect_project

rm -rf -- "$artifact_root/issues/42/provider-preflights"
run_preflight "$fixture_root/cloudflare-personal.json" --issue 42 cloudflare --target personal-worker >/dev/null
assert_record cloudflare personal-cloudflare personal-worker production cloudflare.inspect_account

rm -rf -- "$artifact_root/issues/42/provider-preflights"
run_preflight "$fixture_root/elevenlabs-personal.json" --issue 42 elevenlabs --operation sound-effect >/dev/null
assert_record elevenlabs personal-elevenlabs personal-workspace production elevenlabs.generate_audio

rm -rf -- "$artifact_root/issues/42/provider-preflights"
run_preflight "$fixture_root/app-store-personal.json" --issue 42 app-store --version 1.0 >/dev/null
assert_record app-store PERSONALTEAM com.yuto1201.personal production appstore.inspect_app

assert_fails_without_artifact 'company Supabase identity' supabase "$fixture_root/supabase-company.json" --environment production
assert_fails_without_artifact 'unhealthy Supabase project' supabase "$fixture_root/supabase-unhealthy.json" --environment production
assert_fails_without_artifact 'Cloudflare target mismatch' cloudflare "$fixture_root/cloudflare-personal.json" --target another-worker
assert_fails_without_artifact 'ElevenLabs music entitlement' elevenlabs "$fixture_root/elevenlabs-personal.json" --operation music
assert_fails_without_artifact 'App Store Team and Bundle mismatch' app-store "$fixture_root/app-store-company.json" --version 1.0
assert_fails_without_artifact 'App Store version mismatch' app-store "$fixture_root/app-store-personal.json" --version 2.0

missing_ownership="$test_workspace/missing-ownership.yml"
/bin/cp "$ownership" "$missing_ownership"
/usr/bin/sed -i '' 's/projectRef: personal-project/projectRef: null/' "$missing_ownership"
ownership=$missing_ownership
assert_fails_without_artifact 'missing ownership target' supabase "$fixture_root/supabase-personal.json" --environment production

echo '{not-json' > "$test_workspace/malformed.json"
ownership="$fixture_root/ownership.yml"
assert_fails_without_artifact 'malformed provider response' supabase "$test_workspace/malformed.json" --environment production

echo 'PASS: provider preflights publish only sanitized evidence for exact personal identities and healthy targets'
