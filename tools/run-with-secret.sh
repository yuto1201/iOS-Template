#!/bin/bash
set -euo pipefail

fail() {
  printf '%s\n' "secret execution refused: $1" >&2
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
  echo 'usage: run-with-secret.sh --service-name NAME --env VARIABLE -- ABSOLUTE_COMMAND [ARG...]' >&2
  exit 2
}

service_name=''
environment_name=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-name) service_name=${2:-}; shift 2 ;;
    --env) environment_name=${2:-}; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[[ "$service_name" =~ ^ios-template/([a-z0-9]+(-[a-z0-9]+)*)/([a-z0-9]+(-[a-z0-9]+)*)/([a-z0-9]+(-[a-z0-9]+)*)/([a-z0-9]+(-[a-z0-9]+)*)$ ]] || fail 'Service name is not canonical'
app_slug=${BASH_REMATCH[1]}
[[ "$environment_name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || fail 'environment variable name is invalid'
[[ $# -ge 1 ]] || usage
command_executable=$1
[[ "$command_executable" == /* && -f "$command_executable" && -x "$command_executable" && ! -L "$command_executable" ]] || fail 'child command must be a physical absolute executable'

command_basename=${command_executable##*/}
case "$command_basename" in
  sh|bash|zsh|dash|ksh|fish|env|xargs) fail 'shell evaluation commands are not permitted' ;;
esac
for command_argument in "$@"; do
  case "$command_argument" in
    *'$('*|*'${'*|*'`'*) fail 'shell evaluation strings are not permitted' ;;
  esac
done

secret_value=''
if ! secret_value=$("$security_executable" find-generic-password -a "$app_slug" -s "$service_name" -w 2>/dev/null); then
  unset secret_value
  fail 'required Keychain secret is unavailable'
fi
[[ -n "$secret_value" && "$secret_value" != *$'\n'* && "$secret_value" != *$'\r'* ]] || {
  unset secret_value
  fail 'Keychain secret is not a nonempty single line'
}

printf -v "$environment_name" '%s' "$secret_value"
export "$environment_name"
unset secret_value
exec "$@"
