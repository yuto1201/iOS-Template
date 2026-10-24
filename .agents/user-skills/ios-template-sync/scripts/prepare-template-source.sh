#!/bin/bash
set -euo pipefail

# Prepares the template source of a sync (#446): the latest `main` of the template on GitHub, as a clean
# checkout with its whole history under ~/.ios-template-sync/template-source/, outside the template and
# the target repositories. It never reads or changes the user's own template checkout, and never writes
# to the remote. The cache keeps one bare repository (main only) and one checkout per commit; a checkout
# that exists is used only while it is clean and at its commit. On success it prints one JSON line:
# {"commit":"<sha>","remote":"<url>","templateRoot":"<checkout>"}.

usage() {
  echo 'usage: prepare-template-source.sh [--remote URL] [--root FOLDER]' >&2
  exit 2
}
fail() {
  echo "prepare-template-source: $1" >&2
  exit 1
}

remote=https://github.com/yuto1201/iOS-Template.git
root=${HOME:?HOME is not set}/.ios-template-sync/template-source
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) [[ $# -ge 2 && -n "$2" ]] || usage; remote=$2; shift 2 ;;
    --root) [[ $# -ge 2 && -n "$2" ]] || usage; root=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$root" == /* ]] || fail '--root must be an absolute path'

# Only this script's git runs here: no user hooks, no fsmonitor, no global or system settings.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
git_() { /usr/bin/git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c gc.auto=0 -c maintenance.auto=false "$@"; }

# The commit main points to on the remote now.
listing=$(git_ ls-remote "$remote" refs/heads/main 2>/dev/null) || fail "cannot read main from ${remote}"
expected=${listing%%$'\t'*}
[[ "$expected" =~ ^[0-9a-f]{40}$ && "$listing" == "$expected"$'\t'refs/heads/main ]] || fail "main was not found on ${remote}"

mkdir -p "$root/checkouts"
cache="$root/cache.git"
if [[ ! -d "$cache" ]]; then
  git_ init -q --bare "$cache"
  git_ -C "$cache" remote add origin "$remote"
fi
[[ "$(git_ -C "$cache" remote get-url origin)" == "$remote" ]] ||
  fail "the cache at ${cache} reads another remote; use another --root"
git_ -C "$cache" fetch -q --no-tags origin +refs/heads/main:refs/heads/main || fail "cannot fetch main from ${remote}"
fetched=$(git_ -C "$cache" rev-parse --verify -q refs/heads/main) || fail 'the fetched main is missing'
[[ "$fetched" == "$expected" ]] || fail "main moved while it was fetched (${expected} then ${fetched}); run again"

checkout="$root/checkouts/$fetched"
if [[ -e "$checkout" || -L "$checkout" ]]; then
  [[ -d "$checkout" && ! -L "$checkout" ]] || fail "${checkout} is not a folder"
  head=$(git_ -C "$checkout" rev-parse --verify -q HEAD) || fail "${checkout} is not a checkout"
  [[ "$head" == "$fetched" ]] || fail "${checkout} is at ${head}, not at main ${fetched}; remove it and run again"
  [[ -z "$(git_ -C "$checkout" status --porcelain --untracked-files=all)" ]] ||
    fail "${checkout} has changes; remove it and run again"
else
  staging=$(mktemp -d "$root/checkouts/.staging.XXXXXX")
  trap 'rm -rf -- "$staging"' EXIT
  git_ clone -q --no-hardlinks --no-checkout "$cache" "$staging/checkout"
  git_ -C "$staging/checkout" checkout -q --detach "$fetched"
  git_ -C "$staging/checkout" remote set-url origin "$remote"
  # rename(2) is atomic, so another run sees either no checkout or a complete one, and it fails instead of
  # moving into a checkout that appeared meanwhile.
  /usr/bin/ruby -e 'File.rename(ARGV[0], ARGV[1])' "$staging/checkout" "$checkout"
  rm -rf -- "$staging"
  trap - EXIT
fi

/usr/bin/ruby -rjson -e 'puts JSON.generate({"commit" => ARGV[0], "remote" => ARGV[1], "templateRoot" => ARGV[2]})' \
  "$fetched" "$remote" "$checkout"
