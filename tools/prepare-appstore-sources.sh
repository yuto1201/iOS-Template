#!/bin/bash -p
set -euo pipefail

unset CDPATH
tool_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)
# Preparation reads project inputs; it never executes project code, opens a
# credential store, or loads shell startup files. Explicit protected-form input
# is transient stdin only. Bound the entire process group, including Git reads.
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  /usr/bin/ruby --disable-gems "$tool_root/tools/lib/bounded-command.rb" \
  --stage appstore-preparation --timeout-seconds 120 -- \
  /usr/bin/ruby --disable-gems -E UTF-8 "$tool_root/tools/lib/appstore-preparation.rb" "$@"
