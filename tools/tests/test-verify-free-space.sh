#!/bin/bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git ruby /usr/bin/ruby /usr/bin/shasum

[[ $# == 0 ]] || exit 64

# D-084 (#373): both verify runners check the free space of the volume that will hold their attempt before
# any Build and any Simulator lease. Xcode, swift, xcrun, and the Issue-contract libraries are fakes here, so
# nothing is built, leased, or published; the fake logs show how far each run went.
source_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ios-template-free-space.XXXXXX")"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'free-space regression: %s\n' "$1" >&2; exit 1; }

gib=1073741824
fake_log="$scratch/commands.log"
fake_developer="$scratch/FakeXcode/Contents/Developer"
adapter_bin="$scratch/adapter-bin"
mkdir -p "$fake_developer/usr/bin" "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin" "$adapter_bin" "$scratch/tmp"
: >"$fake_log"

# The fakes run under the runner's scrubbed environment, so the log path is written into each of them.
write_fake() {
  local path=$1 name=$2 body=$3
  printf '#!/bin/bash\nprintf "%%s\\t%%s\\n" %q "$*" >>%q\n%s\n' "$name" "$fake_log" "$body" >"$path"
  chmod +x "$path"
}
write_fake "$fake_developer/usr/bin/xcodebuild" xcodebuild \
  'if [[ "$*" == "-version" ]]; then printf "Xcode 27.0\nBuild version 27A0000\n"; exit 0; fi; exit 1'
write_fake "$fake_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" swift 'exit 1'
write_fake "$adapter_bin/xcrun" xcrun 'exit 1'
write_fake "$adapter_bin/xcode-select" xcode-select 'exit 1'

git_commit() {
  git -C "$1" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
    commit -q --allow-empty -m "$2"
}

prepare_repo() {
  local repo=$1 runner=$2
  mkdir -p "$repo/tools/lib" "$repo/App.xcodeproj"
  /bin/cp "$source_repo/tools/$runner" "$repo/tools/$runner"
  /bin/cp "$source_repo/tools/lib/bounded-command.rb" "$repo/tools/lib/bounded-command.rb"
  /usr/bin/sed \
    -e "s|^TRUSTED_XCODE_SELECT=.*|TRUSTED_XCODE_SELECT=\"$adapter_bin/xcode-select\"|" \
    -e "s|^TRUSTED_XCRUN=.*|TRUSTED_XCRUN=\"$adapter_bin/xcrun\"|" \
    -e "s|^PREFERRED_DEVELOPER_DIR=.*|PREFERRED_DEVELOPER_DIR=\"$fake_developer\"|" \
    "$source_repo/tools/lib/xcode.sh" >"$repo/tools/lib/xcode.sh"
  grep -Fq "PREFERRED_DEVELOPER_DIR=\"$fake_developer\"" "$repo/tools/lib/xcode.sh" || fail 'xcode.sh adapter was not installed'
  printf '// placeholder\n' >"$repo/App.xcodeproj/project.pbxproj"
  printf '.artifacts/\n' >"$repo/.gitignore"
  git init -q "$repo"
  git -C "$repo" add -A
  git_commit "$repo" base
  git_commit "$repo" head
}

ios_repo="$scratch/ios-repo"
fast_repo="$scratch/fast-repo"
prepare_repo "$ios_repo" verify-ios-issue.sh
prepare_repo "$fast_repo" verify-fast-issue.sh
# verify-fast-issue.sh validates its sealed contract before the check; these stubs accept a fast contract.
mkdir -p "$fast_repo/.artifacts/issues/42"
printf '{"repository":"example/fixture"}\n' >"$fast_repo/.artifacts/issues/42/issue-contract.json"
printf 'module IOSTemplate\n  module IssueContract\n    def self.validate_snapshot!(*) end\n  end\nend\n' >"$scratch/issue-contract.rb"
printf 'module IOSTemplate\n  module DeliveryProfile\n    def self.effective_name(_) "fast" end\n  end\nend\n' >"$scratch/delivery-profile.rb"
/bin/cp "$scratch/issue-contract.rb" "$scratch/delivery-profile.rb" "$fast_repo/tools/lib/"
git -C "$fast_repo" add -A
git_commit "$fast_repo" stubs
ios_base="$(git -C "$ios_repo" rev-parse HEAD~1)"
fast_base="$(git -C "$fast_repo" rev-parse HEAD~2)"

stdout="$scratch/stdout"
stderr="$scratch/stderr"
status=0

# Runs one runner with the given environment assignments; the assignments always replace the inherited ones.
run_runner() {
  local kind=$1
  shift
  : >"$fake_log"
  status=0
  if [[ "$kind" == ios ]]; then
    (cd "$ios_repo" && env -u IOS_TEMPLATE_TEST_MODE -u IOS_TEMPLATE_TEST_FREE_BYTES -u IOS_TEMPLATE_MINIMUM_FREE_GIB "$@" \
      tools/verify-ios-issue.sh --issue 42 --expected-base "$ios_base" \
      --issue-contract .artifacts/issues/42/issue-contract.json \
      --matrix .artifacts/batches/free-space/simulator-matrix.json \
      --project App.xcodeproj --scheme App) >"$stdout" 2>"$stderr" || status=$?
  else
    (cd "$fast_repo" && env -u IOS_TEMPLATE_TEST_MODE -u IOS_TEMPLATE_TEST_FREE_BYTES -u IOS_TEMPLATE_MINIMUM_FREE_GIB \
      TMPDIR="$scratch/tmp" "$@" \
      tools/verify-fast-issue.sh --issue 42 --expected-base "$fast_base" --project App.xcodeproj --scheme App \
      --test-identifier AppTests/AppTests/testExample --destination-udid 00000000-0000-0000-0000-000000000001) \
      >"$stdout" 2>"$stderr" || status=$?
  fi
}

logged() { /usr/bin/awk -F '\t' -v name="$1" -v pattern="$2" '$1 == name && (pattern == "" || index($2, pattern)) {found=1} END {exit found ? 0 : 1}' "$fake_log"; }
show() { printf -- '--- stderr\n' >&2; /bin/cat "$stderr" >&2; printf -- '--- commands\n' >&2; /bin/cat "$fake_log" >&2; }

assert_nothing_published() {
  local label=$1 repo=$2
  if /usr/bin/find "$repo/.artifacts" -name 'verify*.json' -print 2>/dev/null | /usr/bin/grep -q .; then
    fail "$label published verification evidence"
  fi
  [[ ! -e "$repo/.artifacts/issues/42/focused-evidence-input.json" ]] || fail "$label wrote focused evidence input"
}

# A run stopped by the check: blocked:environment, before the snapshot, the Build and any lease.
assert_blocked() {
  local label=$1 kind=$2 shown=$3 threshold=$4
  [[ "$status" == 1 ]] || { show; fail "$label: expected exit 1, got $status"; }
  /usr/bin/grep -Fq "blocked:environment: free disk space $shown is below the $threshold GiB threshold" "$stderr" || { show; fail "$label: missing blocked:environment summary"; }
  /usr/bin/grep -Fq "is $shown (" "$stderr" || { show; fail "$label: free space is not shown"; }
  /usr/bin/grep -Fq "needs at least $threshold GiB (IOS_TEMPLATE_MINIMUM_FREE_GIB, default 20)" "$stderr" || { show; fail "$label: threshold is not shown"; }
  for route in 'tools/xcodebuild-in-worktree.sh' 'tools/cleanup-issue.sh' \
    'ruby tools/lib/ios-simulator-resource.rb poster-data --repository .'; do
    /usr/bin/grep -Fq "  $route" "$stderr" || { show; fail "$label: reclaim route is missing: $route"; }
  done
  ! logged xcodebuild build || { show; fail "$label: a Build started"; }
  ! logged xcrun '' || { show; fail "$label: xcrun ran"; }
  if [[ "$kind" == ios ]]; then
    ! logged swift --runner-snapshot || { show; fail "$label: the source snapshot started"; }
    logged swift --runner-record-failure || { show; fail "$label: the stop was not recorded as a failure"; }
    assert_nothing_published "$label" "$ios_repo"
  else
    ! logged xcodebuild '' || { show; fail "$label: Xcode was resolved"; }
    if /usr/bin/find "$scratch/tmp" -mindepth 1 -maxdepth 1 -name 'ios-template-fast-*' -print | /usr/bin/grep -q .; then
      fail "$label: an attempt was created"
    fi
    assert_nothing_published "$label" "$fast_repo"
  fi
  [[ ! -s "$stdout" ]] || fail "$label: printed an evidence path"
}

# A run that passed the check and went on to the next step, where the fakes stop it.
assert_continued() {
  local label=$1 kind=$2
  [[ "$status" == 1 ]] || { show; fail "$label: expected the fake next step to fail, got $status"; }
  ! /usr/bin/grep -Fq 'blocked:environment' "$stderr" || { show; fail "$label: blocked with enough space"; }
  if [[ "$kind" == ios ]]; then
    logged swift --runner-snapshot || { show; fail "$label: did not continue to the source snapshot"; }
    /usr/bin/grep -Fq 'contract or matrix validation failed' "$stderr" || { show; fail "$label: stopped for another reason"; }
  else
    logged xcodebuild build-for-testing || { show; fail "$label: did not continue to the Build"; }
    /usr/bin/grep -Fq 'focused build failed' "$stderr" || { show; fail "$label: stopped for another reason"; }
  fi
}

for kind in ios fast; do
  # Default threshold: 20 GiB. One byte below stops; exactly 20 GiB continues.
  run_runner "$kind" IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_FREE_BYTES=$((20 * gib - 1))
  assert_blocked "$kind default threshold" "$kind" '19.9 GiB' 20
  run_runner "$kind" IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_FREE_BYTES=$((12 * gib + 3 * gib / 10 + 1))
  assert_blocked "$kind low space" "$kind" '12.3 GiB' 20
  /usr/bin/grep -Fq "($((12 * gib + 3 * gib / 10 + 1)) bytes)" "$stderr" || fail "$kind low space: exact bytes are not shown"
  run_runner "$kind" IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_FREE_BYTES=$((20 * gib))
  assert_continued "$kind exact threshold" "$kind"

  # IOS_TEMPLATE_MINIMUM_FREE_GIB changes the threshold in both directions.
  run_runner "$kind" IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_FREE_BYTES=$((12 * gib)) IOS_TEMPLATE_MINIMUM_FREE_GIB=5
  assert_continued "$kind lowered threshold" "$kind"
  run_runner "$kind" IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_FREE_BYTES=$((30 * gib)) IOS_TEMPLATE_MINIMUM_FREE_GIB=31
  assert_blocked "$kind raised threshold" "$kind" '30.0 GiB' 31

  # An invalid threshold stops before anything starts.
  for value in 0 -1 1.5 '' ' 20' 20GiB 007 1000000000; do
    run_runner "$kind" IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_FREE_BYTES=$((100 * gib)) "IOS_TEMPLATE_MINIMUM_FREE_GIB=$value"
    [[ "$status" == 2 ]] || { show; fail "$kind invalid threshold '$value': expected exit 2, got $status"; }
    /usr/bin/grep -Fq 'IOS_TEMPLATE_MINIMUM_FREE_GIB must be a positive integer number of GiB' "$stderr" || { show; fail "$kind invalid threshold '$value': wrong reason"; }
    [[ ! -s "$fake_log" ]] || { show; fail "$kind invalid threshold '$value': started work"; }
  done

  # A malformed test measurement fails closed.
  run_runner "$kind" IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_FREE_BYTES=plenty
  [[ "$status" == 1 ]] && /usr/bin/grep -Fq 'blocked:environment: free disk space could not be measured' "$stderr" || {
    show; fail "$kind malformed measurement was not blocked"
  }
  ! logged xcodebuild build || fail "$kind malformed measurement started a Build"

  # Outside test mode the substitute is ignored and df measures the real volume: no real volume has 999999 GiB
  # free, while the substitute would have allowed it.
  run_runner "$kind" IOS_TEMPLATE_TEST_FREE_BYTES=999999999999999999 IOS_TEMPLATE_MINIMUM_FREE_GIB=999999
  [[ "$status" == 1 ]] && /usr/bin/grep -Fq 'GiB is below the 999999 GiB threshold' "$stderr" || {
    show; fail "$kind real measurement did not stop or the test substitute was honoured outside test mode"
  }
  /usr/bin/grep -Eq 'GiB \([0-9]+ bytes\)' "$stderr" || fail "$kind real measurement is not shown in bytes"
  run_runner "$kind" IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_FREE_BYTES=999999999999999999 IOS_TEMPLATE_MINIMUM_FREE_GIB=999999
  assert_continued "$kind test substitute" "$kind"
done

# The measured location is the attempt's: /tmp/ios-template-verify for the full runner, TMPDIR for the fast one.
run_runner ios IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_FREE_BYTES=1
/usr/bin/grep -Fq 'free space for /tmp/ios-template-verify is 0.0 GiB (1 bytes)' "$stderr" || { show; fail 'full runner measured another location'; }
run_runner fast IOS_TEMPLATE_TEST_MODE=1 IOS_TEMPLATE_TEST_FREE_BYTES=1
/usr/bin/grep -Fq "free space for $scratch/tmp is 0.0 GiB (1 bytes)" "$stderr" || { show; fail 'fast runner measured another location'; }

# A relative TMPDIR that does not exist is resolved against the working directory, and the walk to an existing
# ancestor ends: the real measurement stops at the threshold instead of looping.
: >"$fake_log"
status=0
(cd "$fast_repo" && env -u IOS_TEMPLATE_TEST_MODE -u IOS_TEMPLATE_TEST_FREE_BYTES TMPDIR=tmp-missing/attempts \
  IOS_TEMPLATE_MINIMUM_FREE_GIB=999999 /usr/bin/perl -e 'alarm 60; exec @ARGV' \
  tools/verify-fast-issue.sh --issue 42 --expected-base "$fast_base" --project App.xcodeproj --scheme App \
  --test-identifier AppTests/AppTests/testExample --destination-udid 00000000-0000-0000-0000-000000000001) \
  >"$stdout" 2>"$stderr" || status=$?
[[ "$status" == 1 ]] && /usr/bin/grep -Fq 'GiB is below the 999999 GiB threshold' "$stderr" || {
  show; fail "a relative missing TMPDIR did not end with the free-space stop (exit $status)"
}
[[ ! -e "$fast_repo/tmp-missing" ]] || fail 'the relative TMPDIR was created'

echo 'verify runner free-space tests passed'
