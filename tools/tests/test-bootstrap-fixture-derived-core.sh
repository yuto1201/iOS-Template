#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby bash swift python3 /usr/bin/xcrun
require_test_python_tomllib "$0"

# Runs the app-bootstrap `core` group inside the derived GardenNotes repository that test-bootstrap-fixture.sh
# rebuilds in its own temporary tree (#327). test-bootstrap-fixture.sh and the other
# test-bootstrap-fixture-derived-*.sh groups run the rest of the fixture regression.
exec bash "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}test-bootstrap-fixture.sh" derived-core
