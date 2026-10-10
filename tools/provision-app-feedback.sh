#!/bin/bash
# App feedback provisioning (D-076): `plan` reads the app's values and the current state; `apply`
# creates the feedback repository, deploys the Worker and sets the app's host, only for the plan
# digest the user approved; `check-delivery` sends one real submission. See the app-feedback skill.
set -euo pipefail
[[ $- != *x* && $- != *v* ]] || { echo 'app feedback refused: shell tracing is not permitted' >&2; exit 1; }
exec /usr/bin/ruby "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/app-feedback-provision.rb" "$@"
