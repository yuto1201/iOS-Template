#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" jq ruby

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-provider-preflight.XXXXXX")
test_workspace=$(cd "$test_workspace" && pwd -P)
trap 'rm -rf -- "$test_workspace"' EXIT

fixture_root="$repo_root/tools/tests/fixtures/providers"
adapter="$fixture_root/provider-adapter"
asc_runner="$test_workspace/fake-asc-runner"
ownership="$fixture_root/ownership.yml"
artifact_root="$test_workspace/artifacts"
adapter_argv="$test_workspace/provider-argv"
: > "$adapter_argv"
cat > "$asc_runner" <<'FAKE_ASC'
#!/bin/bash
set -euo pipefail
[[ $# -ge 7 && $1 == --operation && $2 == appstore.inspect_app && $3 == -- ]] || exit 71
shift 3
scenario=${FAKE_ASC_SCENARIO:-success}
[[ $scenario != runner-failure ]] || exit 72
case "$1 $2" in
  'bundle-ids list')
    [[ $# == 6 && $3 == --identifier && $4 == com.yuto1201.personal && $5 == --output && $6 == json ]] || exit 73
    case "$scenario" in
      bundle-zero) printf '%s\n' '{"data":[]}' ;;
      bundle-two) printf '%s\n' '{"data":[{"type":"bundleIds","id":"B1","attributes":{"identifier":"com.yuto1201.personal","seedId":"PERSONALTEAM"}},{"type":"bundleIds","id":"B2","attributes":{"identifier":"com.yuto1201.personal","seedId":"PERSONALTEAM"}}]}' ;;
      bundle-wrong) printf '%s\n' '{"data":[{"type":"bundleIds","id":"B1","attributes":{"identifier":"com.yuto1201.other","seedId":"PERSONALTEAM"}}]}' ;;
      seed-mismatch) printf '%s\n' '{"data":[{"type":"bundleIds","id":"B1","attributes":{"identifier":"com.yuto1201.personal","seedId":"OTHERTEAM"}}]}' ;;
      malformed) printf '%s\n' '{"data":"invalid"}' ;;
      more-pages) printf '%s\n' '{"data":[{"type":"bundleIds","id":"B1","attributes":{"identifier":"com.yuto1201.personal","seedId":"PERSONALTEAM"}}],"links":{"next":"https://example.invalid/next"}}' ;;
      wrong-total) printf '%s\n' '{"data":[{"type":"bundleIds","id":"B1","attributes":{"identifier":"com.yuto1201.personal","seedId":"PERSONALTEAM"}}],"meta":{"paging":{"total":2}}}' ;;
      *) printf '%s\n' '{"data":[{"type":"bundleIds","id":"B1","attributes":{"identifier":"com.yuto1201.personal","seedId":"PERSONALTEAM"}}],"meta":{"paging":{"total":1}}}' ;;
    esac ;;
  'apps list')
    [[ $# == 6 && $3 == --bundle-id && $4 == com.yuto1201.personal && $5 == --output && $6 == json ]] || exit 74
    case "$scenario" in
      app-zero) printf '%s\n' '{"data":[]}' ;;
      app-two) printf '%s\n' '{"data":[{"type":"apps","id":"123456789","attributes":{"bundleId":"com.yuto1201.personal"}},{"type":"apps","id":"987654321","attributes":{"bundleId":"com.yuto1201.personal"}}]}' ;;
      app-wrong) printf '%s\n' '{"data":[{"type":"apps","id":"123456789","attributes":{"bundleId":"com.yuto1201.other"}}]}' ;;
      *) printf '%s\n' '{"data":[{"type":"apps","id":"123456789","attributes":{"bundleId":"com.yuto1201.personal"}}]}' ;;
    esac ;;
  'versions list')
    [[ $# == 10 && $3 == --app && $4 == 123456789 && $5 == --version && $6 == 1.0 && $7 == --platform && $8 == IOS && $9 == --output && ${10} == json ]] || exit 75
    case "$scenario" in
      version-absent) printf '%s\n' '{"data":[]}' ;;
      version-two) printf '%s\n' '{"data":[{"type":"appStoreVersions","id":"V1","attributes":{"versionString":"1.0","platform":"IOS"}},{"type":"appStoreVersions","id":"V2","attributes":{"versionString":"1.0","platform":"IOS"}}]}' ;;
      version-wrong) printf '%s\n' '{"data":[{"type":"appStoreVersions","id":"V1","attributes":{"versionString":"2.0","platform":"IOS"}}]}' ;;
      platform-wrong) printf '%s\n' '{"data":[{"type":"appStoreVersions","id":"V1","attributes":{"versionString":"1.0","platform":"MAC_OS"}}]}' ;;
      *) printf '%s\n' '{"data":[{"type":"appStoreVersions","id":"V1","attributes":{"versionString":"1.0","platform":"IOS"}}]}' ;;
    esac ;;
  *) exit 76 ;;
esac
FAKE_ASC
chmod 700 "$asc_runner"

run_preflight() {
  local response_file=$1
  shift
  IOS_TEMPLATE_TEST_MODE=1 \
    IOS_TEMPLATE_TEST_PROVIDER_BIN="$adapter" \
    IOS_TEMPLATE_TEST_ASC_RUNNER="${IOS_TEMPLATE_TEST_ASC_RUNNER:-$asc_runner}" \
    IOS_TEMPLATE_TEST_PROVIDER_RESPONSE_FILE="$response_file" \
    IOS_TEMPLATE_TEST_OWNERSHIP_FILE="$ownership" \
    IOS_TEMPLATE_TEST_ARTIFACT_ROOT="$artifact_root" \
    IOS_TEMPLATE_TEST_NOW='2026-08-26T06:10:00Z' \
    FAKE_PROVIDER_RESPONSE_FILE="$response_file" \
    FAKE_PROVIDER_ARGV="$adapter_argv" \
    FAKE_ASC_SCENARIO="${FAKE_ASC_SCENARIO:-success}" \
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
  local found=''
  if [[ $provider == app-store ]]; then
    found=$(find "$artifact_root/issues/42/provider-preflights" -maxdepth 1 -name 'app-store*.json' -print 2>/dev/null || true)
  elif [[ -e "$artifact_root/issues/42/provider-preflights/$provider.json" ]]; then
    found=yes
  fi
  [[ -z "$found" ]] || {
    echo "failed preflight published an artifact: $label" >&2
    exit 1
  }
  if /usr/bin/grep -Fq -- 'must-not-survive' "$test_workspace/stdout" "$test_workspace/stderr"; then
    echo "raw provider response leaked: $label" >&2
    exit 1
  fi
}

assert_record() {
  local provider=$1 expected_executor=$2 expected_account=$3 expected_target=$4 expected_environment=$5 expected_operation=$6
  local record="$artifact_root/issues/42/provider-preflights/$provider.json"
  if [[ $provider == app-store ]]; then record="$artifact_root/issues/42/provider-preflights/app-store-${expected_operation#appstore.}.json"; fi
  [[ -f "$record" && ! -L "$record" ]] || { echo "missing provider artifact: $provider" >&2; exit 1; }
  PROVIDER="$provider" EXECUTOR="$expected_executor" ACCOUNT="$expected_account" TARGET="$expected_target" ENVIRONMENT="$expected_environment" OPERATION="$expected_operation" \
    ruby -rjson -rdigest -e '
      value=JSON.parse(File.binread(ARGV.fetch(0)))
      abort unless value.keys.sort == %w[schemaVersion issue executor provider account target environment operation health checkedAt digest].sort
      abort unless value["schemaVersion"] == 2 && value["issue"] == 42
      abort unless value.values_at("executor","provider","account","target","environment","operation","health","checkedAt") == [ENV.fetch("EXECUTOR"),ENV.fetch("PROVIDER"),ENV.fetch("ACCOUNT"),ENV.fetch("TARGET"),ENV.fetch("ENVIRONMENT"),ENV.fetch("OPERATION"),"healthy","2026-08-26T06:10:00Z"]
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
github_output=$(run_preflight "$fixture_root/github-personal.json" --executor codex --issue 42 github --target yuto1201/iOS-Template)
assert_record github codex yuto1201 yuto1201/iOS-Template production github.read_issue
[[ "$github_output" == *'"provider":"github"'* && "$github_output" != *'must-not-survive'* ]] || { echo 'GitHub output is not sanitized' >&2; exit 1; }

rm -rf -- "$artifact_root/issues/42/provider-preflights"
run_preflight "$fixture_root/supabase-personal.json" --executor claude --issue 42 supabase --environment production >/dev/null
assert_record supabase claude kmjpkzaqlewqnypyqwkg personal-project production supabase.inspect_project

rm -rf -- "$artifact_root/issues/42/provider-preflights"
run_preflight "$fixture_root/cloudflare-personal.json" --executor codex --issue 42 cloudflare --target personal-worker >/dev/null
assert_record cloudflare codex personal-cloudflare personal-worker production cloudflare.inspect_account

rm -rf -- "$artifact_root/issues/42/provider-preflights"
run_preflight "$fixture_root/linear-personal.json" --executor claude --issue 42 linear --target YUT >/dev/null
assert_record linear claude yuto33004 YUT production linear.inspect_workspace

rm -rf -- "$artifact_root/issues/42/provider-preflights"
run_preflight "$fixture_root/vercel-personal.json" --executor codex --issue 42 vercel --target yuto16 >/dev/null
assert_record vercel codex team_ANEUn6gVL8dccPaY08wkvxFt yuto16 production vercel.inspect_team

rm -rf -- "$artifact_root/issues/42/provider-preflights"
run_preflight "$fixture_root/elevenlabs-personal.json" --executor claude --issue 42 elevenlabs --operation sound-effect >/dev/null
assert_record elevenlabs claude personal-elevenlabs personal-workspace production elevenlabs.process_media

for operation in text-to-speech speech-to-speech speech-to-text audio-isolation image; do
  rm -rf -- "$artifact_root/issues/42/provider-preflights"
  run_preflight "$fixture_root/elevenlabs-personal.json" --executor codex --issue 42 elevenlabs --operation "$operation" >/dev/null
  assert_record elevenlabs codex personal-elevenlabs personal-workspace production elevenlabs.process_media
done

write_appstore_contract() {
  local operations=$1
  mkdir -p "$artifact_root/issues/42"
  OPERATIONS="$operations" ruby -rjson -rdigest -e '
    root=ARGV.fetch(0)
    contract=JSON.generate({"issue"=>42,"externalOperations"=>ENV.fetch("OPERATIONS").split(",")})
    File.binwrite("#{root}/issue-contract.json",contract)
    state=JSON.generate({"issue"=>42,"issueContract"=>{"digest"=>"sha256:#{Digest::SHA256.hexdigest(contract)}","path"=>".artifacts/issues/42/issue-contract.json"}})
    File.binwrite("#{root}/state.json",state)
  ' "$artifact_root/issues/42"
}

write_appstore_contract 'appstore.inspect_app,appstore.update_metadata,appstore.upload_build,appstore.submit_review,appstore.distribute_testflight'
rm -rf -- "$artifact_root/issues/42/provider-preflights"
run_preflight "$fixture_root/app-store-personal.json" --executor claude --issue 42 app-store --version 1.0 >/dev/null
assert_record app-store claude PERSONALTEAM com.yuto1201.personal production appstore.inspect_app
[[ ! -e "$artifact_root/issues/42/provider-preflights/app-store.json" ]] || { echo 'legacy App Store evidence was published' >&2; exit 1; }
for operation in appstore.update_metadata appstore.upload_build appstore.submit_review appstore.distribute_testflight; do
  run_preflight "$fixture_root/app-store-personal.json" --executor codex --issue 42 app-store --version 1.0 --operation "$operation" >/dev/null
  assert_record app-store codex PERSONALTEAM com.yuto1201.personal production "$operation"
done

write_appstore_contract 'appstore.inspect_app'
assert_fails_without_artifact 'undeclared App Store operation' app-store "$fixture_root/app-store-personal.json" --executor codex --version 1.0 --operation appstore.update_metadata
assert_fails_without_artifact 'unknown App Store operation' app-store "$fixture_root/app-store-personal.json" --executor codex --version 1.0 --operation appstore.delete_app
write_appstore_contract 'appstore.inspect_app,appstore.update_metadata'
for scenario in seed-mismatch bundle-zero bundle-two bundle-wrong app-zero app-two app-wrong version-absent version-two version-wrong platform-wrong runner-failure malformed more-pages wrong-total; do
  FAKE_ASC_SCENARIO="$scenario" assert_fails_without_artifact "App Store $scenario" app-store "$fixture_root/app-store-personal.json" --executor codex --version 1.0
done
write_appstore_contract 'appstore.update_metadata'
assert_fails_without_artifact 'default App Store operation is undeclared' app-store "$fixture_root/app-store-personal.json" --executor codex --version 1.0
write_appstore_contract 'appstore.inspect_app'
echo ' ' >> "$artifact_root/issues/42/issue-contract.json"
assert_fails_without_artifact 'tampered sealed contract' app-store "$fixture_root/app-store-personal.json" --executor codex --version 1.0
write_appstore_contract 'appstore.inspect_app'
if IOS_TEMPLATE_TEST_ASC_RUNNER="$asc_runner" "$repo_root/tools/provider-preflight.sh" --executor codex --issue 42 app-store --version 1.0 >"$test_workspace/stdout" 2>"$test_workspace/stderr"; then
  echo 'production accepted a test asc runner override' >&2
  exit 1
fi
[[ ! -s "$test_workspace/stdout" ]] || { echo 'rejected runner leaked output' >&2; exit 1; }
ln -s "$asc_runner" "$test_workspace/asc-runner-link"
: > "$test_workspace/asc-runner-not-executable"
for invalid_runner in relative-runner "$test_workspace/asc-runner-link" "$test_workspace/asc-runner-not-executable"; do
  IOS_TEMPLATE_TEST_ASC_RUNNER="$invalid_runner" assert_fails_without_artifact "invalid asc runner $invalid_runner" app-store "$fixture_root/app-store-personal.json" --executor codex --version 1.0
done

assert_fails_without_artifact 'company Supabase identity' supabase "$fixture_root/supabase-company.json" --executor claude --environment production
assert_fails_without_artifact 'unhealthy Supabase project' supabase "$fixture_root/supabase-unhealthy.json" --executor codex --environment production
assert_fails_without_artifact 'Cloudflare target mismatch' cloudflare "$fixture_root/cloudflare-personal.json" --executor claude --target another-worker
assert_fails_without_artifact 'wrong Linear workspace' linear "$fixture_root/linear-wrong-workspace.json" --executor codex --target YUT
assert_fails_without_artifact 'wrong Vercel team' vercel "$fixture_root/vercel-wrong-team.json" --executor claude --target yuto16
assert_fails_without_artifact 'ElevenLabs music entitlement' elevenlabs "$fixture_root/elevenlabs-personal.json" --executor claude --operation music
assert_fails_without_artifact 'ElevenLabs video entitlement' elevenlabs "$fixture_root/elevenlabs-personal.json" --executor codex --operation video
assert_fails_without_artifact 'ElevenLabs invalid operation' elevenlabs "$fixture_root/elevenlabs-personal.json" --executor claude --operation dubbing
assert_fails_without_artifact 'App Store version mismatch' app-store "$fixture_root/app-store-personal.json" --executor claude --version 2.0
assert_fails_without_artifact 'unknown executor' github "$fixture_root/github-personal.json" --executor unsupported --target yuto1201/iOS-Template

missing_ownership="$test_workspace/missing-ownership.yml"
/bin/cp "$ownership" "$missing_ownership"
/usr/bin/sed -i '' 's/projectRef: personal-project/projectRef: null/' "$missing_ownership"
ownership=$missing_ownership
assert_fails_without_artifact 'missing ownership target' supabase "$fixture_root/supabase-personal.json" --executor claude --environment production

echo '{not-json' > "$test_workspace/malformed.json"
ownership="$fixture_root/ownership.yml"
assert_fails_without_artifact 'malformed provider response' supabase "$test_workspace/malformed.json" --executor codex --environment production

echo 'PASS: provider preflights apply the same exact account and target policy to Codex and Claude'
