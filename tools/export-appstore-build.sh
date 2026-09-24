#!/bin/bash -p
set -euo pipefail
export LANG=en_US.UTF-8

[[ $- != *x* && $- != *v* ]] || exit 1
tool_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)
if [[ ${IOS_TEMPLATE_TEST_MODE:-} == 1 ]]; then
  [[ -n ${IOS_TEMPLATE_TEST_XCODEBUILD:-} && -n ${IOS_TEMPLATE_TEST_ASC_RUNNER:-} && -n ${IOS_TEMPLATE_TEST_SECURITY_BIN:-} ]] || exit 1
  exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8 HOME="$HOME" \
    IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_XCODEBUILD="$IOS_TEMPLATE_TEST_XCODEBUILD" \
    IOS_TEMPLATE_TEST_ASC_RUNNER="$IOS_TEMPLATE_TEST_ASC_RUNNER" \
    IOS_TEMPLATE_TEST_SECURITY_BIN="$IOS_TEMPLATE_TEST_SECURITY_BIN" \
    IOS_TEMPLATE_TEST_POLL_INTERVAL="${IOS_TEMPLATE_TEST_POLL_INTERVAL:-0.05}" \
    IOS_TEMPLATE_TEST_POLL_TIMEOUT="${IOS_TEMPLATE_TEST_POLL_TIMEOUT:-1}" \
    /usr/bin/ruby --disable-gems -E UTF-8 "$tool_root/tools/lib/appstore-build.rb" "$@"
fi
[[ -z ${IOS_TEMPLATE_TEST_XCODEBUILD:-}${IOS_TEMPLATE_TEST_ASC_RUNNER:-}${IOS_TEMPLATE_TEST_SECURITY_BIN:-}${IOS_TEMPLATE_TEST_POLL_INTERVAL:-}${IOS_TEMPLATE_TEST_POLL_TIMEOUT:-} ]] || exit 1
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8 HOME="$HOME" \
  /usr/bin/ruby --disable-gems -E UTF-8 "$tool_root/tools/lib/appstore-build.rb" "$@"
