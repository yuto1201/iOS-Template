#!/bin/bash -p
set -euo pipefail

unset CDPATH
tool_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)
# #385: the ASO check of App Store localization sources reads local files only. It never writes, and never opens
# the network, App Store Connect, a credential store, or shell startup files.
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  /usr/bin/ruby --disable-gems "$tool_root/tools/lib/bounded-command.rb" \
  --stage appstore-aso --timeout-seconds 60 -- \
  /usr/bin/ruby --disable-gems -E UTF-8 "$tool_root/tools/lib/appstore-aso.rb" "$@"
