#!/bin/bash
set -euo pipefail

fail() {
  printf '%s\n' "secret-store refused: $1" >&2
  exit 1
}

[[ $- != *x* && $- != *v* ]] || fail 'shell tracing is not permitted'

security_executable=/usr/bin/security
if [[ "${IOS_TEMPLATE_TEST_MODE:-}" == 1 ]]; then
  security_executable=${IOS_TEMPLATE_TEST_SECURITY_BIN:-}
  [[ "$security_executable" == /* && -f "$security_executable" && -x "$security_executable" && ! -L "$security_executable" ]] || fail 'test security executable is invalid'
elif [[ -n "${IOS_TEMPLATE_TEST_SECURITY_BIN:-}" ]]; then
  fail 'security executable overrides are test-only'
fi
[[ -x "$security_executable" ]] || fail 'macOS security command is unavailable'

usage() {
  echo 'usage: secret-store.sh put|check --app SLUG --service NAME --environment NAME --key NAME' >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
operation=$1
shift
app_slug=''
service_segment=''
environment_segment=''
key_segment=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app_slug=${2:-}; shift 2 ;;
    --service) service_segment=${2:-}; shift 2 ;;
    --environment) environment_segment=${2:-}; shift 2 ;;
    --key) key_segment=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$operation" == put || "$operation" == check ]] || usage
for segment in "$app_slug" "$service_segment" "$environment_segment" "$key_segment"; do
  [[ "$segment" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail 'namespace segments must be lowercase kebab-case'
done

service_name="ios-template/$app_slug/$service_segment/$environment_segment/$key_segment"
umask 077

case "$operation" in
  put)
    secret_value=''
    IFS= read -r secret_value || fail 'secret must be one newline-terminated line on stdin'
    [[ -n "$secret_value" && "$secret_value" != *$'\r'* ]] || { unset secret_value; fail 'secret must be a nonempty single line'; }
    if IFS= read -r _extra_value; then
      unset secret_value _extra_value
      fail 'secret input contains more than one line'
    fi
    printf '%s\n' "$secret_value" | "$security_executable" add-generic-password \
      -U -a "$app_slug" -s "$service_name" -T '' -w >/dev/null 2>&1 || {
        unset secret_value
        fail 'Keychain write failed'
      }
    unset secret_value
    ;;
  check)
    set +e
    "$security_executable" find-generic-password -a "$app_slug" -s "$service_name" >/dev/null 2>&1
    lookup_status=$?
    set -e
    case "$lookup_status" in
      0) present=true ;;
      44) present=false ;;
      *) fail 'Keychain presence check failed' ;;
    esac
    printf '{"present":%s,"serviceName":"%s"}\n' "$present" "$service_name"
    ;;
esac
