#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
exec /usr/bin/ruby --disable-gems "$repo_root/tools/lib/appstore-creative-preview.rb" "$@"
