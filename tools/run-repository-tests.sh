#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
exec /usr/bin/ruby "$script_dir/lib/run-repository-tests.rb" "${script_dir%/tools}" "$@"
