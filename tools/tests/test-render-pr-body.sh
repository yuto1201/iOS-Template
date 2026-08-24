#!/usr/bin/env bash
set -euo pipefail

source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-render.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
primary="$scratch/repo"; worktree="$primary/.worktrees/42-render"; issue=42
head=0123456789abcdef0123456789abcdef01234567; base=fedcba9876543210fedcba9876543210fedcba98
mkdir -p "$worktree/tools/lib" "$primary/.artifacts/issues/$issue/$head"
cp "$source_root/tools/render-pr-body.sh" "$worktree/tools/"
cp "$source_root/tools/lib/descriptor-files.rb" "$worktree/tools/lib/"
ln -s ../../.artifacts "$worktree/.artifacts"
contract="$primary/.artifacts/issues/$issue/issue-contract.json"
verify="$primary/.artifacts/issues/$issue/$head/verify.json"
review="$primary/.artifacts/issues/$issue/$head/review.json"
CONTRACT="$contract" ruby -rjson -e 'File.binwrite(ENV.fetch("CONTRACT"),JSON.generate({"schemaVersion"=>1,"issue"=>42,"repository"=>"yuto1201/iOS-Template","goal"=>"Render complete merge evidence.","specAnchors"=>["specs/features/render.md#acceptance","docs/verification.md#4-evidence"],"acceptanceCriteria"=>[{"id"=>"AC-1","text"=>"All cases pass."}],"dependencies"=>[],"externalOperations"=>[],"fetchedAt"=>"2026-08-24T00:00:00Z"}))'
digest="sha256:$(shasum -a 256 "$contract" | awk '{print $1}')"
VERIFY="$verify" HEAD="$head" BASE="$base" DIGEST="$digest" ruby -rjson -e '
  cases=%w[iphone-en iphone-ja ipad-en ipad-ja].map{|id|{"id"=>id,"status"=>"passed","screenshot"=>"#{id}/screenshot.png","screenshotDigest"=>"sha256:"+"a"*64}}
  value={"schemaVersion"=>1,"status"=>"passed","changeClassification"=>"application-code","reason"=>nil,"issue"=>42,"baseSha"=>ENV.fetch("BASE"),"headSha"=>ENV.fetch("HEAD"),"issueContract"=>{"path"=>".artifacts/issues/42/issue-contract.json","digest"=>ENV.fetch("DIGEST")},"matrixFile"=>".artifacts/batches/batch/simulator-matrix.json","matrixDigest"=>"sha256:"+"b"*64,"executionRoute"=>"xcodebuild-simctl","xcode"=>{"path"=>"/Applications/Xcode.app/Contents/Developer","version"=>"26.5","build"=>"17F42"},"build"=>{"status"=>"passed","scheme"=>"TemplateApp","warningsAdded"=>0,"project"=>{},"sourceTree"=>{}},"tests"=>{"status"=>"passed","passed"=>24,"failed"=>0,"skipped"=>0},"cases"=>cases,"visualEvaluation"=>{"status"=>"passed","findings"=>[]},"acceptanceEvidence"=>[{"id"=>"AC-1","status"=>"passed","evidence"=>["stage:build","stage:unit-tests","case:iphone-en","case:iphone-ja","case:ipad-en","case:ipad-ja"]}],"completedAt"=>"2026-08-24T00:01:00Z"};File.binwrite(ENV.fetch("VERIFY"),JSON.generate(value))'
REVIEW="$review" HEAD="$head" BASE="$base" DIGEST="$digest" ruby -rjson -e 'File.binwrite(ENV.fetch("REVIEW"),JSON.generate({"schemaVersion"=>1,"issue"=>42,"reviewerModel"=>"claude","baseSha"=>ENV.fetch("BASE"),"headSha"=>ENV.fetch("HEAD"),"verifySha"=>ENV.fetch("HEAD"),"issueContractDigest"=>ENV.fetch("DIGEST"),"verdict"=>"approved","findings"=>[],"acceptanceAssessment"=>[{"id"=>"AC-1","status"=>"supported","evidence"=>["review.diff"]}],"reviewedAt"=>"2026-08-24T00:02:00Z"}))'

body=$("$worktree/tools/render-pr-body.sh" --issue "$issue" --head-sha "$head")
for expected in \
  'Closes #42' \
  '`specs/features/render.md#acceptance`' \
  'Verify digest: `sha256:' \
  'Tests: `passed` (passed: `24`, failed: `0`, skipped: `0`)' \
  'iPhone Pro / English (`iphone-en`): `passed`' \
  'iPhone Pro / Japanese (`iphone-ja`): `passed`' \
  'iPad Air / English (`ipad-en`): `passed`' \
  'iPad Air / Japanese (`ipad-ja`): `passed`' \
  'Reviewer model: `claude`' \
  'Remaining work' \
  'None for this Issue.'
do
  grep -Fq "$expected" <<<"$body" || { echo "missing PR body evidence: $expected" >&2; exit 1; }
done
if grep -Fqi 'gate is pending' <<<"$body"; then echo 'PR body claims a pending gate' >&2; exit 1; fi

ln "$verify" "$verify.hardlink"
if "$worktree/tools/render-pr-body.sh" --issue "$issue" --head-sha "$head" >"$scratch/hardlink.out" 2>"$scratch/hardlink.err"; then
  echo 'hardlinked verify artifact was accepted' >&2
  exit 1
fi
grep -Fq 'single-link regular file' "$scratch/hardlink.err" || { echo 'hardlink refusal was not explicit' >&2; exit 1; }
rm "$verify.hardlink"

cp "$verify" "$scratch/verify.good"
ruby -rjson -e 'path=ARGV[0];value=JSON.parse(File.binread(path));value["build"]["status"]="failed";File.binwrite(path,JSON.generate(value))' "$verify"
if "$worktree/tools/render-pr-body.sh" --issue "$issue" --head-sha "$head" >"$scratch/failed-build.out" 2>"$scratch/failed-build.err"; then
  echo 'failed Build was rendered as merge-ready' >&2; exit 1
fi
if grep -Fq 'None for this Issue' "$scratch/failed-build.out"; then echo 'failed Build overclaimed Remaining work' >&2; exit 1; fi
cp "$scratch/verify.good" "$verify"

cp "$review" "$scratch/review.good"
ruby -rjson -e 'path=ARGV[0];value=JSON.parse(File.binread(path));value["acceptanceAssessment"][0]["status"]="unsupported";File.binwrite(path,JSON.generate(value))' "$review"
if "$worktree/tools/render-pr-body.sh" --issue "$issue" --head-sha "$head" >"$scratch/unsupported.out" 2>"$scratch/unsupported.err"; then
  echo 'unsupported review assessment was rendered as merge-ready' >&2; exit 1
fi
cp "$scratch/review.good" "$review"

mv "$primary/.artifacts/issues/$issue/$head" "$primary/.artifacts/issues/$issue/$head.real"
ln -s "$head.real" "$primary/.artifacts/issues/$issue/$head"
if "$worktree/tools/render-pr-body.sh" --issue "$issue" --head-sha "$head" >"$scratch/symlink.out" 2>"$scratch/symlink.err"; then
  echo 'symlinked Head artifact directory was accepted' >&2; exit 1
fi
grep -Fq 'descriptor' "$scratch/symlink.err" || { echo 'symlink component refusal was not explicit' >&2; exit 1; }

echo 'PASS: PR body reports exact verify/review identity, tests, all four matrix cases, and specification anchors'
