#!/bin/bash -p
set -euo pipefail

# Bash bracket ranges follow the locale's collation order, so [$'\001'-$'\037'] does not
# match a newline under en_US.UTF-8 and the guard silently passes. tools/lib/xcode.sh
# forces that locale for scrubbed execution, so the range form is never reliable here.
# An explicit set is matched by membership and is locale independent.
readonly CONTROL_CHARACTERS=$'\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177'

unset CDPATH
script_source="${BASH_SOURCE[0]}"
[[ "$script_source" == */* && "$script_source" != *["$CONTROL_CHARACTERS"]* ]] || {
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
[[ "$safe_home" == /* && "$safe_home" != *["$CONTROL_CHARACTERS"]* && -d "$safe_home" && ! -L "$safe_home" ]] || {
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
