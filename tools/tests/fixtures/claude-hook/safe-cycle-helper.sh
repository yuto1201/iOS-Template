#!/usr/bin/env bash
set -euo pipefail

if [[ ${IOS_TEMPLATE_GUARD_TEST_CYCLE:-0} == 1 ]]; then
  tools/tests/fixtures/claude-hook/safe-cycle-entry.sh
fi
git status --short
