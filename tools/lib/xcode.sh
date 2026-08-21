#!/usr/bin/env bash

resolve_xcode_environment() {
  local preferred="/Applications/Xcode.app/Contents/Developer"
  local selected=""
  local version_output=""

  if [[ -d "$preferred" ]] && version_output="$(DEVELOPER_DIR="$preferred" xcodebuild -version 2>/dev/null)"; then
    selected="$preferred"
  else
    selected="$(xcode-select -p 2>/dev/null)" || return 1
    [[ "$selected" == /* && -d "$selected" ]] || return 1
    selected="$(cd "$selected" && pwd -P)" || return 1
    version_output="$(DEVELOPER_DIR="$selected" xcodebuild -version 2>/dev/null)" || return 1
  fi

  XCODE_DEVELOPER_DIR="$selected"
  XCODE_VERSION="$(printf '%s\n' "$version_output" | sed -n 's/^Xcode[[:space:]]\{1,\}//p' | head -n 1)"
  XCODE_BUILD="$(printf '%s\n' "$version_output" | sed -n 's/^Build version[[:space:]]\{1,\}//p' | head -n 1)"
  [[ -n "$XCODE_VERSION" && -n "$XCODE_BUILD" ]] || return 1
  export XCODE_DEVELOPER_DIR XCODE_VERSION XCODE_BUILD
}

run_xcodebuild() {
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild "$@"
}

run_xcrun() {
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun "$@"
}
