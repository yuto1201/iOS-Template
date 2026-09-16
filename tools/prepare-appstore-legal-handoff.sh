#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
exec ruby "$repo_root/tools/lib/appstore-legal-handoff.rb" "$@"
