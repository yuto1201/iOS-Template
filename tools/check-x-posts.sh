#!/bin/bash -p
set -euo pipefail

unset CDPATH
tool_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)
# D-096: check the X post material folders under XPosts/. It reads local files only and runs ffprobe to read
# each video's length. It never writes, and never opens the network or a credential store.
[[ $# -eq 1 ]] || { echo 'usage: tools/check-x-posts.sh XPOSTS_DIR' >&2; exit 64; }
ffprobe=$(type -P ffprobe) || { echo 'check-x-posts: ffprobe is required to read video lengths' >&2; exit 69; }
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  /usr/bin/ruby --disable-gems "$tool_root/tools/lib/bounded-command.rb" \
  --stage x-posts-check --timeout-seconds 120 -- \
  /usr/bin/ruby --disable-gems -E UTF-8 "$tool_root/tools/lib/x-posts-check.rb" \
  --ffprobe "$ffprobe" --readme-template "$tool_root/.agents/skills/x-post-material/templates/README.md" "$1"
