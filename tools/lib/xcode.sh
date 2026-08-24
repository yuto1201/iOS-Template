#!/usr/bin/env bash

TRUSTED_XCODE_SELECT="/usr/bin/xcode-select"
TRUSTED_XCRUN="/usr/bin/xcrun"
PREFERRED_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

initialize_trusted_environment() {
  [[ -z "${TRUSTED_ENVIRONMENT_READY-}" ]] || return 0
  local record="" account="" password="" uid="" gid="" class="" change="" expire="" gecos="" user_home="" shell=""
  local physical_home="" user_tmp="" physical_tmp="" actual_uid=""
  record="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/id -P)" || return 1
  IFS=: read -r account password uid gid class change expire gecos user_home shell <<<"$record"
  actual_uid="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/id -u)" || return 1
  [[ "$uid" == "$actual_uid" && "$account" =~ ^[A-Za-z0-9._-]+$ && "$user_home" == /* && -d "$user_home" ]] || return 1
  physical_home="$(cd "$user_home" && pwd -P)" || return 1
  [[ "$physical_home" == "$user_home" ]] || return 1
  [[ "$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/stat -f '%u' "$physical_home")" == "$uid" ]] || return 1
  user_tmp="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$physical_home" /usr/bin/getconf DARWIN_USER_TEMP_DIR)" || return 1
  [[ "$user_tmp" == /* && -d "$user_tmp" ]] || return 1
  physical_tmp="$(cd "$user_tmp" && pwd -P)" || return 1
  [[ "$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/stat -f '%u' "$physical_tmp")" == "$uid" ]] || return 1
  TRUSTED_BASE_ENV=(
    "HOME=$physical_home" "TMPDIR=$physical_tmp" "USER=$account" "LOGNAME=$account"
    "LANG=en_US.UTF-8" "LC_ALL=en_US.UTF-8" "PATH=/usr/bin:/bin"
  )
  TRUSTED_ENVIRONMENT_READY=1
  export TRUSTED_ENVIRONMENT_READY
}

run_scrubbed() {
  initialize_trusted_environment || return 1
  /usr/bin/env -i "${TRUSTED_BASE_ENV[@]}" "$@" 9>&-
}

derive_xcode_tools() {
  local developer="$1"
  local physical="" swift_candidate="" swift_physical=""
  [[ "$developer" == /* && -d "$developer" ]] || return 1
  physical="$(cd "$developer" && pwd -P)" || return 1
  [[ "$physical" == "$developer" ]] || return 1

  XCODEBUILD_PATH="$developer/usr/bin/xcodebuild"
  swift_candidate="$developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
  [[ -f "$XCODEBUILD_PATH" && -x "$XCODEBUILD_PATH" && ! -L "$XCODEBUILD_PATH" ]] || return 1
  [[ -e "$swift_candidate" ]] || return 1
  swift_physical="$(run_scrubbed /usr/bin/ruby --disable-gems -e 'puts File.realpath(ARGV.fetch(0))' "$swift_candidate" 2>/dev/null)" || return 1
  [[ "$swift_physical" == "$developer/"* && -f "$swift_physical" && -x "$swift_physical" ]] || return 1
  XCODE_SWIFT_PATH="$swift_candidate"
  XCODE_DEVELOPER_DIR="$developer"
  export XCODEBUILD_PATH XCODE_SWIFT_PATH XCODE_DEVELOPER_DIR
}

select_fallback_xcode_environment() {
  local selected=""
  selected="$(run_scrubbed "$TRUSTED_XCODE_SELECT" -p 2>/dev/null)" || return 1
  [[ "$selected" == /* && -d "$selected" ]] || return 1
  selected="$(cd "$selected" && pwd -P)" || return 1
  derive_xcode_tools "$selected"
}

select_initial_xcode_environment() {
  if derive_xcode_tools "$PREFERRED_DEVELOPER_DIR"; then
    return 0
  else
    select_fallback_xcode_environment
  fi
}

probe_xcode_environment() {
  local version_output=""
  version_output="$(run_xcodebuild -version 2>/dev/null)" || return 1
  XCODE_VERSION="$(printf '%s\n' "$version_output" | /usr/bin/sed -n 's/^Xcode[[:space:]]\{1,\}//p' | /usr/bin/head -n 1)"
  XCODE_BUILD="$(printf '%s\n' "$version_output" | /usr/bin/sed -n 's/^Build version[[:space:]]\{1,\}//p' | /usr/bin/head -n 1)"
  [[ -n "$XCODE_VERSION" && -n "$XCODE_BUILD" ]] || return 1
  export XCODE_DEVELOPER_DIR XCODE_VERSION XCODE_BUILD
}

resolve_xcode_environment() {
  select_initial_xcode_environment || return 1
  if probe_xcode_environment; then
    return 0
  fi
  select_fallback_xcode_environment || return 1
  probe_xcode_environment
}

run_xcodebuild() {
  run_scrubbed DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" "$XCODEBUILD_PATH" "$@"
}

run_xcrun() {
  run_scrubbed DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" "$TRUSTED_XCRUN" "$@"
}

run_xcode_swift() {
  run_scrubbed DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" "$XCODE_SWIFT_PATH" "$@"
}
