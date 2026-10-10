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
for segment in "$service_segment" "$environment_segment" "$key_segment"; do
  [[ "$segment" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail 'namespace segments must be lowercase kebab-case'
done
# An app slug, or for App Store Connect only, the Apple team namespace of the shared key (D-066).
[[ "$app_slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] ||
  [[ "$service_segment" == app-store-connect && "$app_slug" =~ ^apple-team-[A-Z0-9]{10}$ ]] ||
  fail 'namespace segments must be lowercase kebab-case'

service_name="ios-template/$app_slug/$service_segment/$environment_segment/$key_segment"
umask 077

case "$operation" in
  put)
    secret_value=''
    if [[ -t 0 ]]; then
      # Typed at a terminal: one hidden line, confirmed with Enter.
      printf 'Secret (input hidden): ' >&2
      IFS= read -rs secret_value || { printf '\n' >&2; unset secret_value; fail 'secret input ended before a line was entered'; }
      printf '\n' >&2
    else
      IFS= read -r secret_value || fail 'secret must be one newline-terminated line on stdin'
      # A second line counts even without a final newline, when read stops at the end of input.
      _extra_value=''
      if IFS= read -r _extra_value || [[ -n "$_extra_value" ]]; then
        unset secret_value _extra_value
        fail 'secret input contains more than one line'
      fi
    fi
    [[ -n "$secret_value" ]] || { unset secret_value; fail 'secret must be a nonempty single line'; }
    # Printable ASCII only: the Keychain returns any other byte in hex, so the readback could not match.
    # Checked in a subshell with the C locale; a here-string would write the value to a temporary file.
    if ( LC_ALL=C; [[ "$secret_value" == *[![:print:]]* ]] ); then
      unset secret_value
      fail 'secret must be printable ASCII on one line'
    fi
    # `security add-generic-password -w` reads no value from a pipe and stores an empty password (#277).
    # Its interactive mode takes the whole command, value included, on stdin, so the value never
    # appears in a process listing. Inside double quotes it reads \" and \\ as escapes.
    escaped_value=${secret_value//\\/\\\\}
    escaped_value=${escaped_value//\"/\\\"}
    printf 'add-generic-password -U -a %s -s %s -T "" -w "%s"\n' "$app_slug" "$service_name" "$escaped_value" |
      "$security_executable" -i >/dev/null 2>&1 || {
        unset secret_value escaped_value
        fail 'Keychain write failed'
      }
    unset escaped_value
    stored_value=$("$security_executable" find-generic-password -a "$app_slug" -s "$service_name" -w 2>/dev/null) || {
      unset secret_value stored_value
      fail 'Keychain readback failed'
    }
    if [[ "$stored_value" != "$secret_value" ]]; then
      unset secret_value stored_value
      fail 'Keychain readback differs from the entered secret; run put again'
    fi
    unset secret_value stored_value
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
