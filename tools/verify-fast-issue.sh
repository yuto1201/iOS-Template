#!/bin/bash -p
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
source "$script_dir/lib/xcode.sh"

# D-084: a verification starts only when the volume that will hold its attempt has this much free space.
# IOS_TEMPLATE_MINIMUM_FREE_GIB changes the threshold.
readonly DEFAULT_MINIMUM_FREE_GIB=20
readonly BYTES_PER_GIB=1073741824

# Prints the available bytes of the volume holding the nearest existing ancestor of the path. Only test mode
# may substitute the measurement.
available_bytes_for() {
  local path="$1" output="" line="" entry=""
  if [[ "${IOS_TEMPLATE_TEST_MODE-}" == 1 && -n "${IOS_TEMPLATE_TEST_FREE_BYTES+x}" ]]; then
    [[ "$IOS_TEMPLATE_TEST_FREE_BYTES" =~ ^[[:digit:]]{1,18}$ ]] || return 1
    printf '%s\n' "$((10#$IOS_TEMPLATE_TEST_FREE_BYTES))"
    return 0
  fi
  while [[ ! -d "$path" ]]; do
    path="${path%/*}"
    [[ -n "$path" ]] || path="/"
  done
  output="$(/usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C /bin/df -Pk "$path" 2>/dev/null)" || return 1
  while IFS= read -r entry || [[ -n "$entry" ]]; do line="$entry"; done <<<"$output"
  [[ "$line" =~ [[:space:]]([[:digit:]]{1,15})[[:space:]]+([[:digit:]]{1,15})[[:space:]]+([[:digit:]]{1,15})[[:space:]]+[[:digit:]]{1,3}%[[:space:]] ]] || return 1
  printf '%s\n' "$((10#${BASH_REMATCH[3]} * 1024))"
}

format_gib() {
  printf '%s.%s GiB' "$(($1 / BYTES_PER_GIB))" "$((($1 % BYTES_PER_GIB) * 10 / BYTES_PER_GIB))"
}

usage() {
  echo 'usage: tools/verify-fast-issue.sh --issue N --expected-base SHA --project PATH --scheme NAME --test-identifier TARGET/CLASS/METHOD --destination-udid UUID' >&2
  exit 2
}

issue='' expected_base='' project='' scheme='' test_identifier='' destination_udid=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) issue=${2:-}; shift 2 ;;
    --expected-base) expected_base=${2:-}; shift 2 ;;
    --project) project=${2:-}; shift 2 ;;
    --scheme) scheme=${2:-}; shift 2 ;;
    --test-identifier) test_identifier=${2:-}; shift 2 ;;
    --destination-udid) destination_udid=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$issue" =~ ^[1-9][0-9]*$ && "$expected_base" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$project" =~ ^[A-Za-z0-9_.@/-]+\.xcodeproj$ && "$project" != /* && "$project" != *..* && -d "$repo_root/$project" ]] || usage
[[ "$scheme" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || usage
[[ "$test_identifier" =~ ^[A-Za-z_][A-Za-z0-9_.-]*/[A-Za-z_][A-Za-z0-9_.-]*/[A-Za-z_][A-Za-z0-9_.-]*(\(\))?$ ]] || usage
[[ "$destination_udid" =~ ^[0-9A-Fa-f-]{36}$ ]] || usage
minimum_free_gib="${IOS_TEMPLATE_MINIMUM_FREE_GIB-$DEFAULT_MINIMUM_FREE_GIB}"
[[ "$minimum_free_gib" =~ ^[1-9][[:digit:]]{0,8}$ ]] || {
  echo 'fast verification failed: IOS_TEMPLATE_MINIMUM_FREE_GIB must be a positive integer number of GiB (at most 999999999)' >&2
  exit 2
}
[[ "$(pwd -P)" == "$repo_root" ]] || { echo 'fast verification must run from the Git top-level' >&2; exit 1; }

head_sha=$(git rev-parse HEAD)
[[ "$head_sha" =~ ^[0-9a-f]{40}$ && "$head_sha" != "$expected_base" ]] || { echo 'fast verification requires distinct Base and Head commits' >&2; exit 1; }
git merge-base --is-ancestor "$expected_base" "$head_sha" || { echo 'expected Base is not an ancestor of Head' >&2; exit 1; }
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || { echo 'fast verification requires a clean worktree' >&2; exit 1; }

contract="$repo_root/.artifacts/issues/$issue/issue-contract.json"
[[ -f "$contract" && ! -L "$contract" ]] || { echo 'canonical Issue contract is missing' >&2; exit 1; }
ruby -I"$script_dir/lib" -rjson -rissue-contract -rdelivery-profile -e '
  value=JSON.parse(File.binread(ARGV.fetch(0)))
  IOSTemplate::IssueContract.validate_snapshot!(value,issue:Integer(ARGV.fetch(1)),repository:value.fetch("repository"))
  abort "fast verification requires explicit fast delivery profile" unless IOSTemplate::DeliveryProfile.effective_name(value)=="fast"
' "$contract" "$issue"

# D-084: before the attempt and the Build. The attempt is created under this directory.
free_space_location="${TMPDIR:-/tmp}"
free_bytes="$(available_bytes_for "$free_space_location")" || { echo 'blocked:environment: free disk space could not be measured' >&2; exit 1; }
if [[ "$free_bytes" -lt "$((minimum_free_gib * BYTES_PER_GIB))" ]]; then
  {
    echo "fast verification: free space for $free_space_location is $(format_gib "$free_bytes") ($free_bytes bytes); a verification needs at least $minimum_free_gib GiB (IOS_TEMPLATE_MINIMUM_FREE_GIB, default $DEFAULT_MINIMUM_FREE_GIB)."
    echo "fast verification: nothing was built and no verify.json was published. Reclaim space, then run again:"
    echo "  tools/xcodebuild-in-worktree.sh: build and test ad hoc in the worktree's one DerivedData, not a new -derivedDataPath per task (#368)"
    echo "  tools/cleanup-issue.sh --repo OWNER/REPO --issue N: after an Issue is done, removes its worktree with that worktree's DerivedData and verification data (#369)"
    echo "  ruby tools/lib/ios-simulator-resource.rb poster-data --repository .: sizes of the shut-down dedicated Simulators' poster data; add --apply to remove it (#378)"
    echo "blocked:environment: free disk space $(format_gib "$free_bytes") is below the $minimum_free_gib GiB threshold"
  } >&2
  exit 1
fi

resolve_xcode_environment || { echo 'Xcode could not be resolved' >&2; exit 1; }
attempt_root=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-fast-${issue}-${head_sha}.XXXXXX")
trap 'rm -rf "$attempt_root"' EXIT
derived_data="$attempt_root/DerivedData"
build_result="$attempt_root/Build.xcresult"
test_result="$attempt_root/Tests.xcresult"

run_xcodebuild -project "$project" -scheme "$scheme" -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$destination_udid" -derivedDataPath "$derived_data" \
  -resultBundlePath "$build_result" -parallel-testing-enabled NO build-for-testing \
  >"$attempt_root/build.log" 2>&1 || { echo 'focused build failed' >&2; exit 1; }
run_xcrun xcresulttool get build-results --schema-version 0.1.0 --path "$build_result" --compact \
  >"$attempt_root/build-diagnostics.json"
ruby -rjson -e '
  value=JSON.parse(File.read(ARGV.fetch(0)))
  abort "focused build diagnostics are not clean" unless value["status"]=="succeeded" && value.values_at("warningCount","analyzerWarningCount","errorCount")==[0,0,0]
' "$attempt_root/build-diagnostics.json"

run_xcodebuild -project "$project" -scheme "$scheme" -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$destination_udid" -derivedDataPath "$derived_data" \
  -resultBundlePath "$test_result" -parallel-testing-enabled NO \
  -only-testing:"$test_identifier" test-without-building \
  >"$attempt_root/tests.log" 2>&1 || { echo 'focused unit test failed' >&2; exit 1; }
run_xcrun xcresulttool get test-results summary --schema-version 0.1.0 --path "$test_result" --compact \
  >"$attempt_root/test-summary.json"
counts=$(ruby -rjson -e '
  value=JSON.parse(File.read(ARGV.fetch(0)))
  passed,failed,skipped,total=value.values_at("passedTests","failedTests","skippedTests","totalTestCount")
  abort "focused test summary is invalid" unless value["result"]=="Passed" && [passed,failed,skipped,total].all?{|item| item.is_a?(Integer)} && passed.positive? && failed==0 && skipped==0 && total==passed
  puts [passed,failed,skipped].join("\t")
' "$attempt_root/test-summary.json")
IFS=$'\t' read -r passed failed skipped <<<"$counts"

input="$repo_root/.artifacts/issues/$issue/focused-evidence-input.json"
mkdir -p "$(dirname "$input")"
temporary=$(mktemp "${input}.tmp.XXXXXX")
ISSUE_REASON='Explicit fast profile: focused Build and selected Unit Test passed; Simulator matrix and visual review are intentionally not applicable.' \
XCODE_PATH="$XCODE_DEVELOPER_DIR" XCODE_VERSION="$XCODE_VERSION" XCODE_BUILD="$XCODE_BUILD" \
SCHEME="$scheme" PASSED="$passed" FAILED="$failed" SKIPPED="$skipped" \
ruby -rjson -e '
  value={"schemaVersion"=>1,"reason"=>ENV.fetch("ISSUE_REASON"),"xcode"=>{"path"=>ENV.fetch("XCODE_PATH"),"version"=>ENV.fetch("XCODE_VERSION"),"build"=>ENV.fetch("XCODE_BUILD")},"scheme"=>ENV.fetch("SCHEME"),"tests"=>{"passed"=>Integer(ENV.fetch("PASSED")),"failed"=>Integer(ENV.fetch("FAILED")),"skipped"=>Integer(ENV.fetch("SKIPPED"))}}
  STDOUT.write(JSON.pretty_generate(value)+"\n")
' >"$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$input"

run_xcode_swift "$script_dir/validate-verify-json.swift" --publish-focused \
  --issue "$issue" --expected-base "$expected_base" --expected-head "$head_sha" \
  --input ".artifacts/issues/$issue/focused-evidence-input.json"
printf '\n'
