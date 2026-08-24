#!/bin/bash -p
set -euo pipefail

unset CDPATH
script_source="${BASH_SOURCE[0]}"
[[ "$script_source" == */* && "$script_source" != *[$'\001'-$'\037'$'\177']* ]] || {
  echo "visual packet failed: unsafe invocation path" >&2
  exit 1
}
script_source_directory="${script_source%/*}"
[[ "$script_source_directory" == /* || "$script_source_directory" == ./* ]] || {
  script_source_directory="./$script_source_directory"
}
script_dir="$({ builtin cd -P -- "$script_source_directory" >/dev/null && /bin/pwd -P; })" || {
  echo "visual packet failed: tool directory unavailable" >&2
  exit 1
}
validator="$script_dir/validate-verify-json.swift"
[[ -f "$validator" && ! -L "$validator" ]] || {
  echo "visual packet failed: trusted validator unavailable" >&2
  exit 1
}

safe_home="${HOME-}"
[[ "$safe_home" == /* && "$safe_home" != *[$'\001'-$'\037'$'\177']* && -d "$safe_home" && ! -L "$safe_home" ]] || {
  echo "visual packet failed: HOME is unavailable" >&2
  exit 1
}
safe_user="$(/usr/bin/id -un)"

if ! /usr/bin/env -i \
    HOME="$safe_home" TMPDIR=/tmp USER="$safe_user" LOGNAME="$safe_user" \
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 PATH=/usr/bin:/bin \
    /usr/bin/swift "$validator" --visual-packet "$@"; then
  echo "visual packet failed" >&2
  exit 1
fi
