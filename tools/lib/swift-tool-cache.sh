# shellcheck shell=bash
# #411: runs a trusted Swift tool from a binary compiled once per source and toolchain, instead of
# interpreting the source with /usr/bin/swift on every call (the 7,600-line validator takes about 5 seconds
# per interpreted call and 0.2 seconds compiled).
#
# The cache lives outside the repository, in this user's private cache directory
# ($(getconf DARWIN_USER_CACHE_DIR)ios-template-swift-tools, or IOS_TEMPLATE_SWIFT_TOOL_CACHE when set to an
# absolute path). Each entry is keyed by the SHA-256 of the cache format, DEVELOPER_DIR, the selected developer directory,
# the toolchain version, the tool's file name, and the source bytes, so a changed source or toolchain never
# reuses an old binary. A binary is named by the SHA-256 of its own bytes and is used only when its bytes
# still match that name; a corrupt or replaced binary is removed and the source is compiled again. The root
# and every entry must be real directories owned by this user with mode 0700, or the call stops.

SWIFT_TOOL_CACHE_FORMAT="ios-template-swift-tool-cache-v1"
SWIFT_TOOL_CACHE_COMPILE_TIMEOUT_SECONDS=900

swift_tool_cache_fail() {
  echo "swift tool cache: $1" >&2
  return 1
}

# Runs a toolchain command with only the variables it needs, so that variables such as RUBYOPT, SWIFT_EXEC
# or BASH_ENV in the caller cannot change the compiler or the cache key.
swift_tool_cache_scrubbed() {
  if [[ -n "${DEVELOPER_DIR-}" ]]; then
    /usr/bin/env -i HOME="${HOME:-/var/empty}" PATH=/usr/bin:/bin LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TMPDIR=/tmp \
      DEVELOPER_DIR="$DEVELOPER_DIR" "$@"
  else
    /usr/bin/env -i HOME="${HOME:-/var/empty}" PATH=/usr/bin:/bin LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TMPDIR=/tmp "$@"
  fi
}

# Succeeds when PATH is a real directory owned by this user with mode 0700.
swift_tool_cache_private_directory() {
  local path=$1
  [[ -d "$path" && ! -L "$path" ]] || return 1
  [[ "$(/usr/bin/stat -f '%u %Lp' "$path")" == "$(/usr/bin/id -u) 700" ]]
}

swift_tool_cache_root() {
  local root=${IOS_TEMPLATE_SWIFT_TOOL_CACHE-}
  if [[ -z "$root" ]]; then
    root=$(/usr/bin/getconf DARWIN_USER_CACHE_DIR) || return 1
    root="${root%/}/ios-template-swift-tools"
  fi
  [[ "$root" == /* && "$root" != *$'\n'* ]] || { swift_tool_cache_fail 'the cache root must be an absolute path'; return 1; }
  [[ -e "$root" || -L "$root" ]] || /bin/mkdir -m 700 "$root" 2>/dev/null || [[ -d "$root" ]] ||
    { swift_tool_cache_fail "the cache root cannot be created: $root"; return 1; }
  swift_tool_cache_private_directory "$root" ||
    { swift_tool_cache_fail "the cache root is not a private directory of this user: $root"; return 1; }
  printf '%s\n' "$root"
}

# Prints the path of a verified compiled binary for the Swift source SCRIPT, compiling it when needed.
swift_tool_binary() {
  local script=$1 root key entry candidate name temporary digest compile_status
  [[ "$script" == /* && -f "$script" && ! -L "$script" ]] ||
    { swift_tool_cache_fail 'the tool source must be an absolute regular file'; return 1; }
  root=$(swift_tool_cache_root) || return 1
  key=$(
    {
      printf '%s\0' "$SWIFT_TOOL_CACHE_FORMAT"
      printf '%s\0' "${DEVELOPER_DIR-}"
      swift_tool_cache_scrubbed /usr/bin/xcode-select -p
      printf '\0'
      swift_tool_cache_scrubbed /usr/bin/swift --version 2>&1
      printf '\0%s\0' "${script##*/}"
      /bin/cat "$script"
    } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
  ) || { swift_tool_cache_fail 'the cache key could not be computed'; return 1; }
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] || { swift_tool_cache_fail 'the cache key is invalid'; return 1; }
  entry="$root/$key"
  [[ -e "$entry" || -L "$entry" ]] || /bin/mkdir -m 700 "$entry" 2>/dev/null || [[ -d "$entry" ]] ||
    { swift_tool_cache_fail 'the cache entry cannot be created'; return 1; }
  swift_tool_cache_private_directory "$entry" ||
    { swift_tool_cache_fail "the cache entry is not a private directory of this user: $entry"; return 1; }

  for candidate in "$entry"/tool-*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    name=${candidate##*/tool-}
    if [[ "$name" =~ ^[0-9a-f]{64}$ && -f "$candidate" && ! -L "$candidate" &&
          "$(/usr/bin/stat -f '%u %Lp' "$candidate")" == "$(/usr/bin/id -u) 500" &&
          "$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{print $1}')" == "$name" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    /bin/rm -f -- "$candidate"
  done

  temporary=$(/usr/bin/mktemp "$entry/compile.XXXXXX") || { swift_tool_cache_fail 'a compile file cannot be created'; return 1; }
  compile_status=0
  swift_tool_cache_scrubbed /usr/bin/ruby --disable-gems "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/bounded-command.rb" --stage swift-tool-compile \
    --timeout-seconds "$SWIFT_TOOL_CACHE_COMPILE_TIMEOUT_SECONDS" --grace-seconds 5 -- \
    /usr/bin/swiftc -o "$temporary" "$script" >&2 || compile_status=$?
  if [[ "$compile_status" -ne 0 || ! -f "$temporary" || -L "$temporary" ]]; then
    /bin/rm -f -- "$temporary"
    swift_tool_cache_fail "compiling ${script##*/} failed (status $compile_status)"
    return 1
  fi
  /bin/chmod 500 "$temporary"
  digest=$(/usr/bin/shasum -a 256 "$temporary" | /usr/bin/awk '{print $1}')
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { /bin/rm -f -- "$temporary"; swift_tool_cache_fail 'the binary digest is invalid'; return 1; }
  /bin/mv -f -- "$temporary" "$entry/tool-$digest"
  printf '%s\n' "$entry/tool-$digest"
}
