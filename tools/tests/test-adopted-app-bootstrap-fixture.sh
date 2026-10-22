#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby python3 shasum swift

# Runs the adopted-app regression's `bootstrap-fixture` group on its own (#356): test-bootstrap-fixture.sh in a
# disposable app that adopted the template after its Identity bootstrap. test-adopted-app-imported-tests.sh and the
# other test-adopted-app-bootstrap-*.sh group run the rest.
exec bash "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}test-adopted-app-imported-tests.sh" bootstrap-fixture
