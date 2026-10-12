#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
command -v node >/dev/null || { echo 'node is required for the appstore-creative render extension' >&2; exit 1; }
exec node "$repo_root/tools/lib/appstore-creative-render.mjs" "$@"
