#!/usr/bin/env bash
set -euo pipefail

[[ $# == 0 ]] || exit 64
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/ios-runner-fixture.sh"

prepare_repo first-run valid absent-head
run_execute
[[ -f "$draft" ]] || { echo "first run did not create and publish into the canonical Head directory" >&2; exit 1; }

prepare_repo contained-source-symlink
git -C "$repo" mv Sources/App.swift Sources/RealApp.swift
/bin/ln -s RealApp.swift "$repo/Sources/App.swift"
git -C "$repo" add -- Sources/App.swift
git -C "$repo" commit -q -m 'use contained source symlink'
refresh_head_paths
run_execute
[[ -f "$draft" ]] || { echo "contained source symlink was not materialized" >&2; exit 1; }

prepare_repo contained-config-symlink
git -C "$repo" mv Config/App.xcconfig Config/RealApp.xcconfig
/bin/ln -s RealApp.xcconfig "$repo/Config/App.xcconfig"
git -C "$repo" add -- Config/App.xcconfig
git -C "$repo" commit -q -m 'use contained config symlink'
refresh_head_paths
run_execute
[[ -f "$draft" ]] || { echo "contained config symlink was not materialized" >&2; exit 1; }

prepare_repo escaping-source-symlink
git -C "$repo" rm -q Sources/App.swift
/bin/mkdir -p "$repo/Sources"
/bin/ln -s ../../outside.swift "$repo/Sources/App.swift"
git -C "$repo" add -- Sources/App.swift
git -C "$repo" commit -q -m 'add escaping source symlink'
refresh_head_paths
expect_execute_failure escaping-source-symlink "contract or matrix validation failed"
assert_no_failed_attempts
if /usr/bin/awk -F '\t' '$1 == "xcodebuild" && $0 ~ /build-for-testing$/ {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
  echo "escaping source symlink reached Build" >&2; exit 1
fi

prepare_repo cyclic-source-symlink
git -C "$repo" rm -q Sources/App.swift
/bin/mkdir -p "$repo/Sources"
/bin/ln -s Loop.swift "$repo/Sources/App.swift"
/bin/ln -s App.swift "$repo/Sources/Loop.swift"
git -C "$repo" add -- Sources/App.swift Sources/Loop.swift
git -C "$repo" commit -q -m 'add cyclic source symlinks'
refresh_head_paths
expect_execute_failure cyclic-source-symlink "contract or matrix validation failed"
assert_no_failed_attempts
if /usr/bin/awk -F '\t' '$1 == "xcodebuild" && $0 ~ /build-for-testing$/ {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
  echo "cyclic source symlink reached Build" >&2; exit 1
fi

prepare_repo atomic-failure-evidence
FAKE_BUILD_MODE=fail expect_execute_failure atomic-failure-evidence "build command failed"
assert_no_failed_attempts
failure_file="$(/usr/bin/find "$(dirname "$draft")/failures" -type f -name 'failure-*.json' -print -quit)"
[[ -n "$failure_file" ]] || { echo "failure evidence was not published" >&2; exit 1; }
[[ "$(/usr/bin/stat -f '%Lp' "$failure_file")" == 400 ]] || { echo "failure evidence was not sealed read-only" >&2; exit 1; }
/usr/bin/ruby -rjson -e 'document = JSON.parse(File.read(ARGV.fetch(0))); abort unless document["status"] == "failed" && document["stage"] == "build"' "$failure_file"
if /usr/bin/find "$(dirname "$draft")/failures" -type f ! -name 'failure-*.json' -print -quit | /usr/bin/grep -q .; then
  echo "failure publication left a temporary file" >&2
  exit 1
fi

test_stubborn_probe

prepare_repo malicious-git-policy
malicious_hooks="$scratch/malicious-hooks"
mkdir -p "$malicious_hooks"
/usr/bin/sed "s|@SENTINEL@|$git_policy_sentinel|g" >"$scratch/malicious-fsmonitor" <<'SH'
#!/bin/sh
printf '%s\n' fsmonitor-executed >>'@SENTINEL@'
exit 1
SH
/usr/bin/sed "s|@SENTINEL@|$git_policy_sentinel|g" >"$malicious_hooks/post-index-change" <<'SH'
#!/bin/sh
printf '%s\n' hook-executed >>'@SENTINEL@'
exit 0
SH
chmod +x "$scratch/malicious-fsmonitor" "$malicious_hooks/post-index-change"
git -C "$repo" config core.fsmonitor "$scratch/malicious-fsmonitor"
git -C "$repo" config core.hooksPath "$malicious_hooks"
touch "$repo/docs/head.md"
/bin/rm -f "$git_policy_sentinel"
run_execute
[[ ! -e "$git_policy_sentinel" ]] || {
  echo "trusted Git executed repository-local fsmonitor or hooks" >&2
  /bin/cat "$git_policy_sentinel" >&2
  exit 1
}

prepare_repo ignored-project
printf '%s\n' 'Evil.xcodeproj/' >>"$repo/.git/info/exclude"
mkdir -p "$repo/Evil.xcodeproj"
printf '%s\n' '{}' >"$repo/Evil.xcodeproj/project.pbxproj"
FAKE_PROJECT_PATH=Evil.xcodeproj expect_execute_failure ignored-project "project"
if /usr/bin/awk -F '\t' '$1 == "xcodebuild" && ($0 ~ /build-for-testing$/ || $0 ~ /test-without-building$/) {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
  echo "ignored project reached Build" >&2; exit 1
fi

prepare_repo ignored-synchronized-source
printf '%s\n' 'Sources/Ignored.swift' >>"$repo/.git/info/exclude"
printf '%s\n' 'IGNORED-SOURCE' >"$repo/Sources/Ignored.swift"
run_execute
[[ -f "$draft" ]] || { echo "ignored source prevented isolated raw-Head execution" >&2; exit 1; }

prepare_repo assume-unchanged-source
git -C "$repo" update-index --assume-unchanged Sources/App.swift
printf '%s\n' MUTATED >"$repo/Sources/App.swift"
expect_execute_failure assume-unchanged-source "working tree must be clean"

prepare_repo assume-unchanged-xcconfig
git -C "$repo" update-index --assume-unchanged Config/App.xcconfig
printf '%s\n' MUTATED >"$repo/Config/App.xcconfig"
expect_execute_failure assume-unchanged-xcconfig "working tree must be clean"

prepare_repo hostile-filter
filter_sentinel="$scratch/filter-sentinel"
git -C "$repo" config filter.hostile.smudge "/bin/sh -c 'printf filter-executed >>$filter_sentinel; /bin/cat'"
git -C "$repo" config filter.hostile.clean /bin/cat
printf '%s\n' '*.swift filter=hostile' >"$repo/.git/info/attributes"
/bin/rm -f "$filter_sentinel"
run_execute
[[ ! -e "$filter_sentinel" ]] || { echo "runner executed a hostile conversion filter" >&2; exit 1; }

prepare_repo missing-project-member
git -C "$repo" rm -q Sources/App.swift
git -C "$repo" commit -q -m 'remove project member fixture'
refresh_head_paths
FAKE_BUILD_MODE= expect_execute_failure missing-project-member "build command failed"

prepare_repo mutate-worktree-during-build
FAKE_MUTATE_WORKTREE=1 expect_execute_failure mutate-worktree-during-build "verification inputs changed"
/usr/bin/ruby - "$fake_log" <<'RUBY'
lines = File.readlines(ARGV.fetch(0), chomp: true).map { |line| line.split("\t") }
build = lines.index { |fields| fields[0] == "xcodebuild" && fields.last == "build-for-testing" }
abort "worktree mutation fixture did not reach Build" unless build
after_build = lines.drop(build + 1)
abort "worktree mutation reached post-Build tests" if after_build.any? { |fields| fields[0] == "xcodebuild" }
owned = "00000000-0000-0000-0000-000000000001"
simctl = after_build.select { |fields| fields[0] == "xcrun" && fields[2] == "simctl" }
allowed_cleanup = simctl.all? do |fields|
  case fields[3]
  when "list"
    fields[4..] == ["devices", "--json"]
  when "terminate"
    fields[4] == owned && fields[5] == "com.example.TemplateApp"
  when "shutdown", "erase"
    fields[4] == owned
  else
    false
  end
end
abort "worktree mutation reached non-cleanup Simulator commands" unless allowed_cleanup
abort "worktree mutation did not reclaim the Build destination" unless
  simctl.any? { |fields| fields[3] == "shutdown" && fields[4] == owned } &&
  simctl.any? { |fields| fields[3] == "erase" && fields[4] == owned }
RUBY

prepare_repo intermediate-project-symlink
mkdir -p "$repo/RealProjects/TemplateApp.xcodeproj"
printf '%s\n' '{}' >"$repo/RealProjects/TemplateApp.xcodeproj/project.pbxproj"
/bin/ln -s RealProjects "$repo/LinkedProjects"
git -C "$repo" add -- RealProjects LinkedProjects
git -C "$repo" commit -q -m 'add linked project fixture'
refresh_head_paths
FAKE_PROJECT_PATH=LinkedProjects/TemplateApp.xcodeproj expect_execute_failure intermediate-project-symlink "project"
if /usr/bin/awk -F '\t' '$1 == "xcodebuild" && ($0 ~ /build-for-testing$/ || $0 ~ /test-without-building$/) {found=1} END {exit found ? 0 : 1}' "$fake_log"; then
  echo "symlinked project reached Build" >&2; exit 1
fi


assert_runner_publication_cleanup
echo "identity iOS runner tests passed"
