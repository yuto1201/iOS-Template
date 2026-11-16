#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" rg git jq ruby bash swift python3 /usr/bin/xcrun
require_test_python_tomllib "$0"

# Runs the `compatibility` group of the fixture regression on its own (#563): the frozen bootstrap fixture, with
# a prose-only change, still passes the app-bootstrap transform group, and a fixture without a transformation
# anchor fails with the refresh instruction. test-bootstrap-fixture.sh and its derived-* groups run the rest.
exec bash "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}test-bootstrap-fixture.sh" compatibility
