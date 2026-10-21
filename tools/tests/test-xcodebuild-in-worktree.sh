#!/usr/bin/env bash
set -euo pipefail

# #368 (D-084): the ad-hoc xcodebuild entry point reuses one fixed DerivedData per worktree outside the
# repository, removes result bundles, keeps at most three on request, removes a scratch DerivedData on
# success, failure and TERM, and stops before xcodebuild for an unsafe location.

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby shasum

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tool="$repo_root/tools/xcodebuild-in-worktree.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/ios-template-xcodebuild-in-worktree.XXXXXX")"
work="$(cd "$work" && pwd -P)"
trap 'rm -rf -- "$work"' EXIT

fail() { echo "xcodebuild-in-worktree test: $*" >&2; exit 1; }

# The fake records its arguments and follows a mode file, since the tool runs it with a scrubbed environment.
fake="$work/fake-xcodebuild"
cat > "$fake" <<EOF
#!/bin/bash
log="$work/fake.log"
mode=\$(cat "$work/fake-mode")
printf '%s\n' "\$@" > "$work/last-arguments"
printf 'run\n' >> "\$log"
bundle=""
previous=""
for argument in "\$@"; do
  [[ "\$previous" == -resultBundlePath ]] && bundle="\$argument"
  previous="\$argument"
done
[[ -n "\$bundle" ]] && mkdir -p "\$bundle" && wc -l < "\$log" | tr -d ' ' > "\$bundle/run"
case "\$mode" in
  ok) exit 0 ;;
  fail) exit 65 ;;
  sleep) touch "$work/sleeping"; sleep 60; exit 0 ;;
esac
EOF
chmod +x "$fake"

make_repository() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m init
}
alpha="$work/alpha checkout"
beta="$work/beta"
make_repository "$alpha"
make_repository "$beta"
root="$work/derived-data"

run_tool() {
  local directory=$1
  shift
  (cd "$directory" && IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT="$root" \
    IOS_TEMPLATE_TEST_XCODEBUILD="$fake" "$tool" "$@")
}
argument_after() { awk -v flag="$1" 'previous == flag { print; exit } { previous = $0 }' "$work/last-arguments"; }
expected_id() {
  local physical
  physical="$(cd "$1" && pwd -P)"
  printf '%s-%s' "$(basename "$physical" | sed 's/[^A-Za-z0-9_.-]/-/g')" "$(printf '%s' "$physical" | shasum -a 256 | cut -c1-64)"
}
alpha_id="$(expected_id "$alpha")"
beta_id="$(expected_id "$beta")"
[[ "$alpha_id" == alpha-checkout-* ]] || fail "unexpected worktree ID: $alpha_id"
count_bundles() { find "$root" -name '*.xcresult' | wc -l | tr -d ' '; }

# Two runs in the same worktree share one DerivedData, named like the verify runner's worktree ID.
echo ok > "$work/fake-mode"
run_tool "$alpha" -scheme Example build >/dev/null 2>&1 || fail 'the first run failed'
first="$(argument_after -derivedDataPath)"
run_tool "$alpha" -scheme Example test >/dev/null 2>&1 || fail 'the second run failed'
[[ "$(argument_after -derivedDataPath)" == "$first" && "$first" == "$root/$alpha_id/DerivedData" ]] || fail "unexpected DerivedData: $first"
[[ "$(grep -c '^-derivedDataPath$' "$work/last-arguments")" == 1 ]] || fail 'the DerivedData path was not passed once'
[[ "$(find "$root" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 1 ]] || fail 'the same worktree used more than one directory'
[[ "$(find "$root" -name DerivedData -type d | wc -l | tr -d ' ')" == 1 ]] || fail 'more than one DerivedData exists'
[[ "$(cat "$root/$alpha_id/owner.json")" == "{\"schemaVersion\":1,\"worktree\":\"$(cd "$alpha" && pwd -P)\"}" ]] || fail 'the owner record is wrong'
[[ "$(count_bundles)" == 0 && -z "$(ls -A "$root/$alpha_id/Runs")" ]] || fail 'a result bundle remained after a successful run'
[[ "$(stat -f '%Lp' "$root/$alpha_id")" == 700 ]] || fail 'the worktree directory is not private'

# Another worktree uses its own directory; both are outside both repositories.
run_tool "$beta" -scheme Example build >/dev/null 2>&1 || fail 'the other worktree run failed'
[[ "$(argument_after -derivedDataPath)" == "$root/$beta_id/DerivedData" ]] || fail 'the other worktree did not use its own DerivedData'
[[ "$(find "$root" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 2 ]] || fail 'the two worktrees did not get two directories'

# A failing run passes on the status and removes its result bundle.
echo fail > "$work/fake-mode"
status=0
run_tool "$alpha" -scheme Example test >/dev/null 2>&1 || status=$?
[[ "$status" == 65 ]] || fail "the failing status was not passed on: $status"
[[ "$(count_bundles)" == 0 ]] || fail 'a result bundle remained after a failing run'

# --keep-result keeps only the newest three result bundles of the worktree.
echo ok > "$work/fake-mode"
# The four runs finish within the same second, so the order cannot come from whole seconds.
rm -f "$work/fake.log"
for run in 1 2 3 4; do
  run_tool "$alpha" --keep-result -scheme Example test >/dev/null 2>&1 || fail "kept run $run failed"
done
kept="$(ls "$root/$alpha_id/Results")"
[[ "$(wc -l <<<"$kept" | tr -d ' ')" == 3 ]] || fail "unexpected kept results: $kept"
[[ "$(for name in $kept; do cat "$root/$alpha_id/Results/$name/run"; done | tr '\n' ' ')" == '2 3 4 ' ]] || fail "the newest three runs were not kept: $kept"
[[ -z "$(ls -A "$root/$beta_id/Results")" ]] || fail 'another worktree kept a result'

# --scratch uses a separate DerivedData that is removed after success and after failure.
for mode in ok fail; do
  echo "$mode" > "$work/fake-mode"
  run_tool "$alpha" --scratch -scheme Example test >/dev/null 2>&1 || true
  scratch="$(argument_after -derivedDataPath)"
  [[ "$scratch" == "$root/$alpha_id/Scratch/scratch."*/DerivedData ]] || fail "unexpected scratch DerivedData: $scratch"
  [[ ! -e "${scratch%/DerivedData}" && -z "$(ls -A "$root/$alpha_id/Scratch")" ]] || fail "the scratch DerivedData remained after $mode"
done

# TERM stops xcodebuild and removes the scratch DerivedData and the run folder.
echo sleep > "$work/fake-mode"
rm -f "$work/sleeping"
(cd "$alpha" && IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT="$root" \
  IOS_TEMPLATE_TEST_XCODEBUILD="$fake" exec "$tool" --scratch -scheme Example test >/dev/null 2>&1) &
tool_pid=$!
for _ in $(seq 1 100); do [[ -e "$work/sleeping" ]] && break; sleep 0.1; done
[[ -e "$work/sleeping" ]] || fail 'the fake xcodebuild did not start'
started=$(date +%s)
kill -TERM "$tool_pid"
status=0
wait "$tool_pid" || status=$?
[[ "$status" == 143 ]] || fail "TERM did not stop the tool: $status"
(( $(date +%s) - started < 15 )) || fail 'TERM waited for xcodebuild to finish'
[[ -z "$(ls -A "$root/$alpha_id/Scratch")" && -z "$(ls -A "$root/$alpha_id/Runs")" ]] || fail 'TERM left the scratch DerivedData or the run folder'
for _ in $(seq 1 50); do pgrep -f "$fake" >/dev/null || break; sleep 0.2; done
! pgrep -f "$fake" >/dev/null || fail 'TERM left xcodebuild running'

# Unsafe locations and arguments stop before xcodebuild runs.
refused() {
  local expected=$1
  shift
  rm -f "$work/fake.log"
  local output status=0
  output="$("$@" 2>&1)" || status=$?
  [[ "$status" == 2 && "$output" == *"$expected"* ]] || fail "not refused ($expected): $status $output"
  [[ ! -e "$work/fake.log" ]] || fail "xcodebuild ran although $expected"
}
echo ok > "$work/fake-mode"
refused 'outside the repository' bash -c 'cd "$1" && IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT="$1/derived-data" IOS_TEMPLATE_TEST_XCODEBUILD="$2" "$3" -scheme Example build' _ "$alpha" "$fake" "$tool"
ln -s "$root" "$work/linked-root"
refused 'symbolic link' bash -c 'cd "$1" && IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT="$2" IOS_TEMPLATE_TEST_XCODEBUILD="$3" "$4" -scheme Example build' _ "$alpha" "$work/linked-root" "$fake" "$tool"
cp "$root/$beta_id/owner.json" "$root/$alpha_id/owner.json"
refused 'belongs to another worktree' run_tool "$alpha" -scheme Example build
printf '{"schemaVersion":1,"worktree":"%s"}\n' "$(cd "$alpha" && pwd -P)" > "$root/$alpha_id/owner.json"
rm -rf "$root/$alpha_id/Results"
ln -s "$work" "$root/$alpha_id/Results"
refused 'is not a directory owned by this user' run_tool "$alpha" -scheme Example build
rm "$root/$alpha_id/Results"
# A directory recorded for another worktree keeps its permissions and contents when it is refused.
mkdir -p "$root/$alpha_id/Results"
cp "$root/$beta_id/owner.json" "$root/$alpha_id/owner.json"
chmod 755 "$root/$alpha_id"
printf 'keep\n' > "$root/$alpha_id/Results/note"
refused 'belongs to another worktree' run_tool "$alpha" -scheme Example build
[[ "$(stat -f '%Lp' "$root/$alpha_id")" == 755 && "$(cat "$root/$alpha_id/Results/note")" == keep ]] || fail 'a refused directory was changed'
printf '{"schemaVersion":1,"worktree":"%s"}\n' "$(cd "$alpha" && pwd -P)" > "$root/$alpha_id/owner.json"
rm "$root/$alpha_id/Results/note"
# An existing non-empty directory without an owner record is refused as well.
mkdir -p "$root/unrecorded-$alpha_id"
rm "$root/$alpha_id/owner.json"
refused 'has no owner record' run_tool "$alpha" -scheme Example build
printf '{"schemaVersion":1,"worktree":"%s"}\n' "$(cd "$alpha" && pwd -P)" > "$root/$alpha_id/owner.json"
rmdir "$root/unrecorded-$alpha_id"
refused 'sets -derivedDataPath itself' run_tool "$alpha" -scheme Example -derivedDataPath "$work/elsewhere" build
refused 'sets -resultBundlePath itself' run_tool "$alpha" -scheme Example -resultBundlePath "$work/elsewhere.xcresult" build
refused 'name -scheme, -testProductsPath or -xctestrun' run_tool "$alpha" -list -project Example.xcodeproj
refused 'inside a Git worktree' bash -c 'cd "$1" && IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_DERIVED_DATA_ROOT="$2" IOS_TEMPLATE_TEST_XCODEBUILD="$3" "$4" -scheme Example build' _ "$work" "$root" "$fake" "$tool"
[[ -e "$root/$beta_id/owner.json" ]] || fail 'a refusal touched another worktree'

# In production the tool locates Xcode, which runs `xcodebuild -version`, only after it has verified the location.
location_line="$(grep -n '^worktree_root="\$(' "$tool" | cut -d: -f1)"
resolve_line="$(grep -n 'resolve_xcode_environment ||' "$tool" | cut -d: -f1)"
[[ -n "$location_line" && -n "$resolve_line" ]] && (( resolve_line > location_line )) || fail 'Xcode is located before the location is verified'

echo 'xcodebuild-in-worktree regressions passed'
