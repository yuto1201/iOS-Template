#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby swift python3 /usr/bin/xcrun
require_test_python_tomllib "$0"

# Runs the app-bootstrap `safety-rerun` group on its own (#327). The group has its own temporary fixtures and cleanup
# in test-app-bootstrap.sh; test-app-bootstrap.sh core and the other test-app-bootstrap-*.sh groups run the rest.
exec bash "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}test-app-bootstrap.sh" safety-rerun
