#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
test_workspace=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-secret-store.XXXXXX")
trap 'rm -rf -- "$test_workspace"' EXIT

fake_security="$repo_root/tools/tests/fixtures/security"
secret_probe="$repo_root/tools/tests/fixtures/secret-child-probe"
private_key_probe="$repo_root/tools/tests/fixtures/private-key-child-probe"
fake_db="$test_workspace/keychain-value"
fake_argv="$test_workspace/security-argv"
test_secret='fixture-secret-value-42'
service_name='ios-template/template-app/elevenlabs/production/api-key'

assert_fails() {
  local label=$1
  shift
  if "$@" >"$test_workspace/stdout" 2>"$test_workspace/stderr"; then
    echo "expected failure: $label" >&2
    exit 1
  fi
  if /usr/bin/grep -Fq -- "$test_secret" "$test_workspace/stdout" "$test_workspace/stderr"; then
    echo "secret leaked while rejecting: $label" >&2
    exit 1
  fi
}

run_secret_store() {
  IOS_TEMPLATE_TEST_MODE=1 \
    IOS_TEMPLATE_TEST_SECURITY_BIN="$fake_security" \
    FAKE_SECURITY_DB="$fake_db" \
    FAKE_SECURITY_ARGV="$fake_argv" \
    "$repo_root/tools/secret-store.sh" "$@"
}

run_with_secret() {
  IOS_TEMPLATE_TEST_MODE=1 \
    IOS_TEMPLATE_TEST_SECURITY_BIN="$fake_security" \
    FAKE_SECURITY_DB="$fake_db" \
    FAKE_SECURITY_ARGV="$fake_argv" \
    "$repo_root/tools/run-with-secret.sh" "$@"
}

: > "$fake_argv"
put_output=$(printf '%s\n' "$test_secret" | run_secret_store put \
  --app template-app --service elevenlabs --environment production --key api-key 2>&1)
[[ -z "$put_output" ]] || { echo 'put printed output' >&2; exit 1; }
[[ -f "$fake_db" ]] || { echo 'put did not store the secret' >&2; exit 1; }
if /usr/bin/grep -aFq -- "$test_secret" "$fake_argv"; then
  echo 'secret appeared in security argv' >&2
  exit 1
fi

present=$(run_secret_store check --app template-app --service elevenlabs --environment production --key api-key)
[[ "$present" == "{\"present\":true,\"serviceName\":\"$service_name\"}" ]] || {
  echo "unexpected present response: $present" >&2
  exit 1
}
rm -f -- "$fake_db"
absent=$(run_secret_store check --app template-app --service elevenlabs --environment production --key api-key)
[[ "$absent" == "{\"present\":false,\"serviceName\":\"$service_name\"}" ]] || {
  echo "unexpected absent response: $absent" >&2
  exit 1
}

printf '%s\n' "$test_secret" | run_secret_store put \
  --app template-app --service elevenlabs --environment production --key api-key
expected_digest=$(printf '%s' "$test_secret" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
child_digest=$(run_with_secret --service-name "$service_name" --env ELEVENLABS_API_KEY -- "$secret_probe")
[[ "$child_digest" == "$expected_digest" ]] || { echo 'child received the wrong secret' >&2; exit 1; }
[[ -z "${ELEVENLABS_API_KEY:-}" ]] || { echo 'secret escaped into the caller environment' >&2; exit 1; }

rm -f -- "$fake_db"
assert_fails 'missing secret' run_with_secret --service-name "$service_name" --env ELEVENLABS_API_KEY -- "$secret_probe"
assert_fails 'invalid app segment' run_secret_store check --app '../bad' --service elevenlabs --environment production --key api-key
assert_fails 'invalid service path' run_with_secret --service-name 'ios-template/template-app/../production/api-key' --env ELEVENLABS_API_KEY -- "$secret_probe"
assert_fails 'invalid environment name' run_with_secret --service-name "$service_name" --env 'bad-name' -- "$secret_probe"
assert_fails 'shell evaluation command' run_with_secret --service-name "$service_name" --env ELEVENLABS_API_KEY -- /bin/bash -c 'true'
assert_fails 'multiline secret' bash -c 'printf "one\\ntwo\\n" | "$1" put --app template-app --service elevenlabs --environment production --key api-key' _ "$repo_root/tools/secret-store.sh"

test_home="$test_workspace/home"
approved_root="$test_home/Library/Application Support/iOS-Template/secrets/template-app"
mkdir -p "$approved_root"
chmod 700 "$test_home/Library/Application Support/iOS-Template/secrets" "$approved_root"
private_key="$approved_root/AuthKey_TEST.p8"
printf '%s\n' 'PRIVATE KEY FIXTURE DATA' > "$private_key"
chmod 600 "$private_key"
expected_path_digest=$(printf '%s' "$private_key" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
private_result=$(HOME="$test_home" "$repo_root/tools/run-with-private-key.sh" \
  --app template-app --file "$private_key" --env APP_STORE_CONNECT_PRIVATE_KEY_PATH -- "$private_key_probe")
[[ "$private_result" == "$expected_path_digest 600" ]] || { echo 'private key wrapper returned an unexpected result' >&2; exit 1; }

outside_key="$test_workspace/outside.p8"
printf '%s\n' 'OUTSIDE KEY FIXTURE' > "$outside_key"
chmod 600 "$outside_key"
assert_fails 'private key outside approved root' env HOME="$test_home" "$repo_root/tools/run-with-private-key.sh" \
  --app template-app --file "$outside_key" --env APP_STORE_CONNECT_PRIVATE_KEY_PATH -- "$private_key_probe"
chmod 644 "$private_key"
assert_fails 'private key mode is too broad' env HOME="$test_home" "$repo_root/tools/run-with-private-key.sh" \
  --app template-app --file "$private_key" --env APP_STORE_CONNECT_PRIVATE_KEY_PATH -- "$private_key_probe"

for ignored_path in AuthKey_example.p8 Example.mobileprovision .env .env.production .secrets/staging-key secret-staging/key; do
  git -C "$repo_root" check-ignore -q --no-index -- "$ignored_path" || {
    echo "secret path is not ignored: $ignored_path" >&2
    exit 1
  }
done

echo 'PASS: Keychain and private-key wrappers keep secrets out of argv and logs and constrain child-only access'
