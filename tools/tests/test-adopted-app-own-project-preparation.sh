#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby python3 shasum swift

# Runs the adopted-app regression's `own-project-preparation` group on its own (#433): the imported tests that read app-owned files,
# in a disposable app that adopted the template with its own specifications, project and StoreKit configuration.
# test-adopted-app-imported-tests.sh and the other test-adopted-app-*.sh groups run the rest.
exec bash "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}test-adopted-app-imported-tests.sh" own-project-preparation
