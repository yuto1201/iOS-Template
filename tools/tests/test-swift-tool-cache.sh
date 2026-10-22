#!/usr/bin/env bash
# #411: a trusted Swift tool runs from a binary compiled once per source and toolchain. The cache is reused
# only while the source matches, a changed, corrupt or replaced binary is compiled again, an unsafe cache
# location stops the call, and the cache lives outside the repository.
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby /usr/bin/swift /usr/bin/swiftc /usr/bin/shasum

source_repo=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-swift-tool-cache.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf -- "$scratch"' EXIT
source "$source_repo/tools/lib/swift-tool-cache.sh"

fail() { echo "$1" >&2; exit 1; }
cache="$scratch/cache"
export IOS_TEMPLATE_SWIFT_TOOL_CACHE="$cache"
source_file="$scratch/sources/probe.swift"
mkdir -p "$scratch/sources"
printf '%s\n' 'print("first:" + CommandLine.arguments.dropFirst().joined(separator: ","))' >"$source_file"

# The first call creates a private root and entry and compiles once; the binary takes the same arguments.
first=$(swift_tool_binary "$source_file")
[[ "$first" == "$cache"/*/tool-* && -x "$first" ]] || fail "unexpected cached binary path: $first"
[[ "$(stat -f '%Lp' "$cache")" == 700 && "$(stat -f '%Lp' "$(dirname "$first")")" == 700 && "$(stat -f '%Lp' "$first")" == 500 ]] ||
  fail 'the cache is not private'
[[ "$("$first" a b)" == 'first:a,b' ]] || fail 'the cached binary output differs'
[[ "${first##*/tool-}" == "$(shasum -a 256 "$first" | awk '{print $1}')" ]] || fail 'the binary is not named by its digest'

# The second call reuses the binary without compiling.
before=$(stat -f '%m %i' "$first")
second=$(swift_tool_binary "$source_file")
[[ "$second" == "$first" && "$(stat -f '%m %i' "$second")" == "$before" ]] || fail 'an unchanged source was compiled again'
[[ -z $(find "$cache" -name 'compile.*') ]] || fail 'a compile file was left behind'

# A changed source never reuses the old binary.
printf '%s\n' 'print("second:" + CommandLine.arguments.dropFirst().joined(separator: ","))' >"$source_file"
changed=$(swift_tool_binary "$source_file")
[[ "$(dirname "$changed")" != "$(dirname "$first")" && "$("$changed" c)" == 'second:c' ]] || fail 'a changed source reused the old binary'

# A corrupt binary is removed and compiled again.
chmod 700 "$changed"
printf 'corrupt' >>"$changed"
chmod 500 "$changed"
repaired=$(swift_tool_binary "$source_file")
[[ "$("$repaired" d)" == 'second:d' && ! -e "$changed" || "$repaired" == "$changed" && "$("$repaired" d)" == 'second:d' ]] ||
  fail 'a corrupt binary was used'
[[ "${repaired##*/tool-}" == "$(shasum -a 256 "$repaired" | awk '{print $1}')" ]] || fail 'the repaired binary digest differs'

# A binary replaced by another program under the same name is not used.
other_source="$scratch/sources/other.swift"
printf '%s\n' 'print("replaced")' >"$other_source"
other=$(swift_tool_binary "$other_source")
chmod 700 "$repaired"
cp "$other" "$repaired"
chmod 500 "$repaired"
restored=$(swift_tool_binary "$source_file")
[[ "$("$restored" e)" == 'second:e' ]] || fail 'a replaced binary was used'

# A binary with a writable mode is not used.
chmod 700 "$restored"
writable_checked=$(swift_tool_binary "$source_file")
[[ "$(stat -f '%Lp' "$writable_checked")" == 500 && "$("$writable_checked" f)" == 'second:f' ]] || fail 'a writable binary was used'

# A source that does not compile fails without leaving a binary or compile file.
broken_source="$scratch/sources/broken.swift"
printf '%s\n' 'this is not swift' >"$broken_source"
if swift_tool_binary "$broken_source" >/dev/null 2>"$scratch/broken.err"; then fail 'a broken source was accepted'; fi
grep -Fq 'compiling broken.swift failed' "$scratch/broken.err" || fail 'the compile failure was not reported'
[[ -z $(find "$cache" -name 'compile.*') ]] || fail 'a failed compile left a file'

# Unsafe sources and cache locations stop the call.
if swift_tool_binary "sources/probe.swift" >/dev/null 2>&1; then fail 'a relative source was accepted'; fi
ln -s "$source_file" "$scratch/sources/link.swift"
if swift_tool_binary "$scratch/sources/link.swift" >/dev/null 2>&1; then fail 'a symbolic-link source was accepted'; fi
if IOS_TEMPLATE_SWIFT_TOOL_CACHE=relative/cache swift_tool_binary "$source_file" >/dev/null 2>&1; then fail 'a relative cache root was accepted'; fi
mkdir -m 755 "$scratch/open-cache"
if IOS_TEMPLATE_SWIFT_TOOL_CACHE="$scratch/open-cache" swift_tool_binary "$source_file" >/dev/null 2>&1; then fail 'a shared cache root was accepted'; fi
ln -s "$cache" "$scratch/linked-cache"
if IOS_TEMPLATE_SWIFT_TOOL_CACHE="$scratch/linked-cache" swift_tool_binary "$source_file" >/dev/null 2>&1; then fail 'a symbolic-link cache root was accepted'; fi
entry=$(dirname "$restored")
chmod 755 "$entry"
if swift_tool_binary "$source_file" >/dev/null 2>&1; then fail 'a shared cache entry was accepted'; fi
chmod 700 "$entry"

# Caller variables cannot change the compiler, Ruby, or the cache key.
poison_source="$scratch/sources/poison.swift"
printf '%s\n' 'print("clean")' >"$poison_source"
clean=$(swift_tool_binary "$poison_source")
rm -rf -- "$(dirname "$clean")"
poisoned=$(RUBYOPT='-r/nonexistent-poison' SWIFT_EXEC=/nonexistent-poison BASH_ENV=/nonexistent-poison swift_tool_binary "$poison_source")
[[ "$(dirname "$poisoned")" == "$(dirname "$clean")" && "$("$poisoned")" == clean ]] || fail 'caller variables changed the compile or the key'

# Without an override the cache is in this user's private cache directory, outside the repository.
default_root=$(unset IOS_TEMPLATE_SWIFT_TOOL_CACHE; swift_tool_cache_root)
[[ "$default_root" == "$(getconf DARWIN_USER_CACHE_DIR)"* && "$default_root" != "$source_repo"/* ]] ||
  fail "the default cache root is not the private cache directory: $default_root"

# The publishers run the validator through the cache.
for publisher in publish-workflow-verify.sh publish-documentation-verify.sh visual-review-packet.sh; do
  grep -Fq 'source "$script_dir/lib/swift-tool-cache.sh"' "$source_repo/tools/$publisher" &&
    ! grep -q '/usr/bin/swift ' "$source_repo/tools/$publisher" || fail "$publisher does not use the cached validator"
done

echo 'PASS: Swift tools run from a private cache keyed by source and toolchain, and unsafe or stale entries are not used'
