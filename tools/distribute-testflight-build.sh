#!/bin/bash -p
set -euo pipefail
export LANG=en_US.UTF-8
[[ $- != *x* && $- != *v* ]] || exit 1
tool_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)
if [[ ${IOS_TEMPLATE_TEST_MODE:-} == 1 ]]; then
  [[ -n ${IOS_TEMPLATE_TEST_ASC_RUNNER:-} && -n ${IOS_TEMPLATE_TEST_OPERATION_DETAIL:-} ]] || exit 1
  exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8 HOME="$HOME" \
    IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_ASC_RUNNER="$IOS_TEMPLATE_TEST_ASC_RUNNER" \
    IOS_TEMPLATE_TEST_OPERATION_DETAIL="$IOS_TEMPLATE_TEST_OPERATION_DETAIL" \
    /usr/bin/ruby --disable-gems -E UTF-8 "$tool_root/tools/lib/asc-testflight.rb" "$@"
fi
[[ -z ${IOS_TEMPLATE_TEST_ASC_RUNNER:-}${IOS_TEMPLATE_TEST_OPERATION_DETAIL:-} ]] || exit 1
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8 HOME="$HOME" \
  /usr/bin/ruby --disable-gems -E UTF-8 "$tool_root/tools/lib/asc-testflight.rb" "$@"
