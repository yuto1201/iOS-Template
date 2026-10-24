#!/bin/bash
set -euo pipefail

# #446: the ios-template-sync skill prepares its template source with
# .agents/user-skills/ios-template-sync/scripts/prepare-template-source.sh. A local repository stands in
# for GitHub. The source is the remote's latest main, with its whole history, outside both repositories,
# and the report comes from that version's tool. A checkout that stands for the user's own template
# checkout (another branch, uncommitted and untracked changes) is never changed. A remote that cannot be
# read, a cache that reads another remote, and a cached checkout that is not clean at its commit stop the
# script before anything is used.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby swiftc tar shasum

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
source "$repo_root/tools/tests/fixtures/template-sync/template-sample.sh"
script="$repo_root/.agents/user-skills/ios-template-sync/scripts/prepare-template-source.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-sync-source.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

fail() { printf 'template sync source regression: %s\n' "$1" >&2; exit 1; }
commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name='Template Sync Test' -c user.email=template-sync@example.invalid -c commit.gpgsign=false \
    -c gc.auto=0 -c maintenance.auto=false commit -q -m "$2"
}
# Every path, symlink target and file digest under a folder, .git included.
snapshot() {
  ruby -rdigest -e '
    root = ARGV.fetch(0)
    entries = Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |path| File.basename(path) == "." }.sort
    puts(entries.map do |path|
      full = File.join(root, path)
      if File.symlink?(full) then "#{path} -> #{File.readlink(full)}"
      elsif File.directory?(full) then "#{path}/"
      else "#{path} #{Digest::SHA256.file(full).hexdigest}"
      end
    end)
  ' "$1" | shasum -a 256
}
json_field() { ruby -rjson -e 'print JSON.parse(ARGV[0]).fetch(ARGV[1])' "$1" "$2"; }
expect_refused() {
  local label=$1 message=$2
  shift 2
  if "$@" >"$work/$label.out" 2>&1; then
    fail "$label was accepted"
  fi
  grep -Fq -- "$message" "$work/$label.out" || { cat "$work/$label.out" >&2; fail "$label: unexpected message"; }
}

[[ -x "$script" ]] || fail 'the script must be executable'

# The remote: a template sample with two commits on main and another branch.
remote="$work/remote"
build_template_sample "$repo_root" "$remote"
git -C "$remote" init -q -b main
commit_all "$remote" base
base=$(git -C "$remote" rev-parse HEAD)
git -C "$remote" branch -q side
printf '%s\n' '' '取り込み元の試験の追記。' >>"$remote/docs/README.md"
commit_all "$remote" update
latest=$(git -C "$remote" rev-parse HEAD)

# The user's own checkout: cloned from the remote, on another branch, with uncommitted and untracked changes.
user="$work/user-checkout"
git clone -q "$remote" "$user"
git -C "$user" checkout -q -b local-work "$base"
printf '%s\n' 'local edit' >>"$user/docs/AUTHORITY.md"
printf '%s\n' 'untracked' >"$user/notes.txt"
user_before=$(snapshot "$user")

# The latest main, with its whole history, as a clean checkout outside both repositories.
root="$work/source-root"
first=$("$script" --remote "$remote" --root "$root")
template=$(json_field "$first" templateRoot)
[[ "$(json_field "$first" commit)" == "$latest" && "$(json_field "$first" remote)" == "$remote" ]] || fail "unexpected result: $first"
[[ "$template" == "$root/checkouts/$latest" && -d "$template" ]] || fail "the source is not at $root/checkouts/$latest"
[[ "$(git -C "$template" rev-parse HEAD)" == "$latest" ]] || fail 'the source is not at the latest main'
[[ "$(git -C "$template" rev-list --count HEAD)" == "$(git -C "$remote" rev-list --count main)" ]] || fail 'the source lacks history'
git -C "$template" cat-file -e "$base^{commit}" || fail 'the source lacks the base commit'
[[ -z "$(git -C "$template" status --porcelain --untracked-files=all)" ]] || fail 'the source is not clean'
[[ "$(git -C "$template" remote get-url origin)" == "$remote" ]] || fail 'the source does not name its remote'
# The tool in the source is that commit's version.
[[ "$(git -C "$template" rev-parse HEAD:tools/template-sync.sh)" == "$(git -C "$remote" rev-parse main:tools/template-sync.sh)" ]] ||
  fail 'the source tool differs from the remote'

# The source's own tool reports on an app made from the base commit.
bootstrap_binary="$work/bootstrap-app"
swiftc -o "$bootstrap_binary" "$repo_root/tools/bootstrap-app.swift"
app="$work/app"
mkdir -p "$app"
git -C "$remote" archive -o "$work/app.tar" "$base"
tar -xf "$work/app.tar" -C "$app"
rm -f "$work/app.tar"
"$bootstrap_binary" apply --root "$app" --manifest "$app/Config/template-identity.json" \
  --display-name 'Garden Notes' --module-name GardenNotes --app-slug garden-notes --bundle-id com.yuto.GardenNotes >/dev/null
git -C "$app" init -q
(cd "$app" && BASE="$base" ruby -rjson -e '
  File.write("Config/template-base.json", JSON.pretty_generate({
    "schemaVersion" => 1, "templateRepository" => "yuto1201/iOS-Template", "baseCommit" => ENV.fetch("BASE"),
    "recordedAt" => "2026-10-25T00:00:00Z", "method" => "created"
  }) + "\n")
')
commit_all "$app" created
"$template/tools/template-sync.sh" report --app-root "$app" --template-ref "$latest" --output-dir "$work/report" \
  --work-dir "$work/sync-work" --now 2026-10-25T01:00:00Z >/dev/null
PLAN="$work/report/plan.json" LATEST="$latest" ruby -rjson -e '
  plan = JSON.parse(File.read(ENV.fetch("PLAN")))
  abort "the report is not for the latest main" unless plan.fetch("template").fetch("commit") == ENV.fetch("LATEST")
' || fail 'the report does not name the prepared commit'
[[ -z "$(git -C "$template" status --porcelain --untracked-files=all)" ]] || fail 'the report changed the source'

# A second run reuses the same clean checkout.
again=$("$script" --remote "$remote" --root "$root")
[[ "$again" == "$first" ]] || fail 'a second run gave another result'

# A newer main gets its own checkout, and the earlier one stays.
printf '%s\n' '' '二つ目の追記。' >>"$remote/docs/README.md"
commit_all "$remote" newer
newer=$(git -C "$remote" rev-parse HEAD)
third=$("$script" --remote "$remote" --root "$root")
[[ "$(json_field "$third" commit)" == "$newer" && -d "$root/checkouts/$newer" && -d "$template" ]] || fail "the newer main was not prepared: $third"

# The user's checkout did not change at any point.
[[ "$(snapshot "$user")" == "$user_before" ]] || fail "the user's checkout changed"
[[ "$(git -C "$user" symbolic-ref --short HEAD)" == local-work ]] || fail "the user's branch changed"

# Refusals: an unreadable remote, a cache that reads another remote, and a cached checkout that is not
# clean at its commit.
expect_refused missing-remote 'cannot read main from' "$script" --remote "$work/no-such-remote" --root "$work/other-root"
[[ ! -e "$work/other-root/checkouts" ]] || [[ -z "$(ls -A "$work/other-root/checkouts")" ]] || fail 'a refused run left a checkout'
other_remote="$work/other-remote"
git clone -q --bare "$remote" "$other_remote"
expect_refused other-remote 'reads another remote' "$script" --remote "$other_remote" --root "$root"
newer_checkout="$root/checkouts/$newer"
git -C "$newer_checkout" checkout -q --detach "$base"
expect_refused moved-checkout "is at $base, not at main $newer" "$script" --remote "$remote" --root "$root"
git -C "$newer_checkout" checkout -q --detach "$newer"
printf '%s\n' 'edit' >>"$newer_checkout/docs/README.md"
expect_refused changed-checkout 'has changes' "$script" --remote "$remote" --root "$root"
git -C "$newer_checkout" checkout -q -- docs/README.md
printf '%s\n' 'x' >"$newer_checkout/untracked.txt"
expect_refused untracked-checkout 'has changes' "$script" --remote "$remote" --root "$root"
rm -f "$newer_checkout/untracked.txt"
expect_refused relative-root '--root must be an absolute path' "$script" --remote "$remote" --root relative/root
expect_refused unknown-argument 'usage: prepare-template-source.sh' "$script" --branch main
[[ "$("$script" --remote "$remote" --root "$root")" == "$third" ]] || fail 'the restored checkout was not accepted'

echo "template sync source tests passed"
