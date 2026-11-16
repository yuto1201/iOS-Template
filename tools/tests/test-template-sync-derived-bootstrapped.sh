#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby swiftc tar shasum cc python3

# Runs the `after-bootstrap` group of the derived-app template sync regression on its own (#564): the report and
# apply regressions after Identity bootstrap of a disposable derived copy, and their early failure with a broken
# ownership manifest. test-template-sync-derived.sh runs the state before Identity bootstrap.
exec bash "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}test-template-sync-derived.sh" after-bootstrap
