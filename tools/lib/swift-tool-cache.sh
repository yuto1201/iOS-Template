# shellcheck shell=bash
# #411: runs a trusted Swift tool from a binary compiled once per source and toolchain, instead of
# interpreting the source with /usr/bin/swift on every call (the 7,600-line validator takes about 5 seconds
# per interpreted call and 0.2 seconds compiled).
#
# The cache lives outside the repository, in this user's private cache directory
# ($(getconf DARWIN_USER_CACHE_DIR)ios-template-swift-tools, or IOS_TEMPLATE_SWIFT_TOOL_CACHE when set to an
# absolute path). Each entry is keyed by the SHA-256 of the cache format, DEVELOPER_DIR, the selected developer directory,
# the toolchain version, the tool's file name, and the source bytes, so a changed source or toolchain never
# reuses an old binary. An entry holds the binary, named by the SHA-256 of its bytes, and a binding file that
# names the entry's key and that digest; the binary is used only when the binding names this entry's key, the
# binary's bytes match the bound digest, and both have their private modes. A corrupt, replaced or unbound
# binary is compiled again. The root and every entry must be real directories owned by this user with mode
# 0700, and the root must not overlap the repository that holds the tool or its primary checkout (which holds
# the canonical artifact store), or the call stops.

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

# Prints the physical form of an absolute PATH whose parent exists, resolving symbolic links in the parent.
swift_tool_cache_physical() {
  local path=$1 parent
  if [[ -d "$path" && ! -L "$path" ]]; then
    (builtin cd -P -- "$path" && /bin/pwd -P)
  else
    parent=$(builtin cd -P -- "${path%/*}/" 2>/dev/null && /bin/pwd -P) || return 1
    printf '%s/%s\n' "${parent%/}" "${path##*/}"
  fi
}

# Succeeds when the physical paths A and B are the same or one contains the other.
swift_tool_cache_overlaps() {
  [[ "$1" == "$2" || "$1" == "$2"/* || "$2" == "$1"/* ]]
}

# Prints the cache root for the tool SCRIPT after checking that it is private and outside the repository.
swift_tool_cache_root() {
  local script=$1 root physical tool_directory checkout common primary
  root=${IOS_TEMPLATE_SWIFT_TOOL_CACHE-}
  if [[ -z "$root" ]]; then
    root=$(/usr/bin/getconf DARWIN_USER_CACHE_DIR) || return 1
    root="${root%/}/ios-template-swift-tools"
  fi
  [[ "$root" == /* && "$root" != *$'\n'* ]] || { swift_tool_cache_fail 'the cache root must be an absolute path'; return 1; }
  physical=$(swift_tool_cache_physical "$root") ||
    { swift_tool_cache_fail "the cache root's parent does not exist: $root"; return 1; }
  tool_directory=$(builtin cd -P -- "${script%/*}/" && /bin/pwd -P) || return 1
  if checkout=$(swift_tool_cache_scrubbed /usr/bin/git -C "$tool_directory" rev-parse --show-toplevel 2>/dev/null); then
    checkout=$(swift_tool_cache_physical "$checkout") || return 1
    swift_tool_cache_overlaps "$physical" "$checkout" &&
      { swift_tool_cache_fail "the cache root overlaps the repository: $root"; return 1; }
    common=$(swift_tool_cache_scrubbed /usr/bin/git -C "$tool_directory" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
      { swift_tool_cache_fail 'the primary checkout cannot be found'; return 1; }
    primary=$(swift_tool_cache_physical "${common%/.git}") || return 1
    swift_tool_cache_overlaps "$physical" "$primary" &&
      { swift_tool_cache_fail "the cache root overlaps the primary checkout or its artifact store: $root"; return 1; }
  fi
  [[ -e "$physical" || -L "$physical" ]] || /bin/mkdir -m 700 "$physical" 2>/dev/null || [[ -d "$physical" ]] ||
    { swift_tool_cache_fail "the cache root cannot be created: $root"; return 1; }
  swift_tool_cache_private_directory "$physical" ||
    { swift_tool_cache_fail "the cache root is not a private directory of this user: $root"; return 1; }
  printf '%s\n' "$physical"
}

# Prints the path of a verified compiled binary for the Swift source SCRIPT, compiling it when needed.
swift_tool_binary() {
  local script=$1 root key entry binding bound temporary binding_temporary digest compile_status
  [[ "$script" == /* && -f "$script" && ! -L "$script" ]] ||
    { swift_tool_cache_fail 'the tool source must be an absolute regular file'; return 1; }
  root=$(swift_tool_cache_root "$script") || return 1
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

  binding="$entry/binding"
  if [[ -f "$binding" && ! -L "$binding" && "$(/usr/bin/stat -f '%u %Lp' "$binding")" == "$(/usr/bin/id -u) 400" ]]; then
    bound=$(/bin/cat "$binding")
    if [[ "$bound" =~ ^([0-9a-f]{64})\ ([0-9a-f]{64})$ && "${BASH_REMATCH[1]}" == "$key" ]]; then
      digest=${BASH_REMATCH[2]}
      if [[ -f "$entry/tool-$digest" && ! -L "$entry/tool-$digest" &&
            "$(/usr/bin/stat -f '%u %Lp' "$entry/tool-$digest")" == "$(/usr/bin/id -u) 500" &&
            "$(/usr/bin/shasum -a 256 "$entry/tool-$digest" | /usr/bin/awk '{print $1}')" == "$digest" ]]; then
        printf '%s\n' "$entry/tool-$digest"
        return 0
      fi
      /bin/rm -f -- "$entry/tool-$digest"
    fi
  fi

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
  binding_temporary=$(/usr/bin/mktemp "$entry/binding.XXXXXX") || { /bin/rm -f -- "$temporary"; swift_tool_cache_fail 'a binding file cannot be created'; return 1; }
  printf '%s %s\n' "$key" "$digest" >"$binding_temporary"
  /bin/chmod 400 "$binding_temporary"
  /bin/mv -f -- "$temporary" "$entry/tool-$digest"
  /bin/mv -f -- "$binding_temporary" "$entry/binding"
  printf '%s\n' "$entry/tool-$digest"
}
