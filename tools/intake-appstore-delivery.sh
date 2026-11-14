#!/bin/bash -p
set -euo pipefail

unset CDPATH
tool_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)
# D-105 (#534): takes in a delivery from the App Store creative workspace and writes the folder that
# tools/build-appstore-screenshot-set.sh --composition reads. It reads local files and the local
# workspace Git repository only; it never writes into `App Store/`, never opens the network, App Store
# Connect, a credential store, or shell startup files.
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  /usr/bin/ruby --disable-gems "$tool_root/tools/lib/bounded-command.rb" \
  --stage appstore-intake --timeout-seconds 300 -- \
  /usr/bin/ruby --disable-gems -E UTF-8 "$tool_root/tools/lib/appstore-intake.rb" "$@"
