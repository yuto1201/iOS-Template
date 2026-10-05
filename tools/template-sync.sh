#!/bin/bash
# Template sync (D-074): `check` classifies every template file by ownership; `report` compares a
# target repository with the template and writes a read-only diff report and apply plan.
set -euo pipefail
exec /usr/bin/ruby "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/template-sync.rb" "$@"
