#!/usr/bin/env bash
set -euo pipefail

source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
[[ $# == 0 || ( $# == 1 && "$1" == scoped ) ]] || exit 64
scope="${1:-full}"
case_ids=(iphone-en iphone-ja ipad-en ipad-ja)
[[ "$scope" != scoped ]] || case_ids=(iphone-ja)
fixtures="$source_root/tools/tests/fixtures/verify"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ios-template-render.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT

primary="$scratch/repo"
worktree="$primary/.worktrees/42-render"
issue=42
mkdir -p "$primary/tools/lib" "$primary/docs" "$primary/TemplateApp.xcodeproj"
cp "$source_root/tools/render-pr-body.sh" "$primary/tools/"
cp "$source_root/tools/validate-verify-json.swift" "$primary/tools/"
cp "$source_root/tools/lib/descriptor-files.rb" "$primary/tools/lib/"
cp "$source_root/tools/lib/review-contract.rb" "$primary/tools/lib/"
cp "$source_root/tools/lib/review-sealing.rb" "$primary/tools/lib/"
cp "$source_root/tools/lib/delivery-profile.rb" "$primary/tools/lib/"
cp "$source_root/tools/lib/delivery-stage.rb" "$primary/tools/lib/"
cp "$source_root/tools/lib/verification-scope.rb" "$primary/tools/lib/"
cp "$source_root/tools/lib/prepare-review-packet.rb" "$source_root/tools/lib/review-artifacts.rb" "$primary/tools/lib/"
printf '%s\n' '{}' >"$primary/TemplateApp.xcodeproj/project.pbxproj"
printf '%s\n' '# Initial' >"$primary/docs/initial.md"
git -C "$primary" init -q
git -C "$primary" config user.name 'Renderer Test'
git -C "$primary" config user.email 'renderer@example.invalid'
git -C "$primary" add -- tools docs TemplateApp.xcodeproj
git -C "$primary" commit -q -m initial
printf '%s\n' '# Base' >"$primary/docs/base.md"
git -C "$primary" add -- docs/base.md
git -C "$primary" commit -q -m base
base=$(git -C "$primary" rev-parse HEAD)
printf '%s\n' '# Renderer evidence' >"$primary/docs/render.md"
git -C "$primary" add -- docs/render.md
git -C "$primary" commit -q -m head
head=$(git -C "$primary" rev-parse HEAD)
git -C "$primary" worktree add -q -b codex/42-render "$worktree" "$head"
ln -s ../../.artifacts "$worktree/.artifacts"

issue_dir="$primary/.artifacts/issues/$issue"
head_dir="$issue_dir/$head"
matrix_dir="$primary/.artifacts/batches/evidence-fixture"
contract="$issue_dir/issue-contract.json"
verify="$head_dir/verify.json"
review="$head_dir/review.json"
review_packet="$head_dir/review-packet.json"
review_diff="$head_dir/review.diff"
draft="$head_dir/verify-draft.json"
packet="$head_dir/visual-packet.json"
matrix="$matrix_dir/simulator-matrix.json"
mkdir -p "$head_dir" "$matrix_dir"
cp "$fixtures/issue-contract.json" "$contract"
for id in "${case_ids[@]}"; do cp -R "$fixtures/screenshots/$id" "$head_dir/"; done

ruby -rjson - "$matrix" <<'RUBY'
path = ARGV.fetch(0)
matrix = {
  "schemaVersion" => 1, "batchId" => "evidence-fixture",
  "resolvedAt" => "2026-08-21T12:00:00+09:00",
  "xcode" => {"path" => "/Applications/Xcode.app/Contents/Developer", "version" => "26.5", "build" => "17F42"},
  "runtime" => {"identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version" => "26.5"},
  "cases" => [
    ["iphone-en", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro", "en_US", "en", "00000000-0000-0000-0000-000000000001"],
    ["iphone-ja", "iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro", "ja_JP", "ja", "00000000-0000-0000-0000-000000000002"],
    ["ipad-en", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "en_US", "en", "00000000-0000-0000-0000-000000000003"],
    ["ipad-ja", "iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)", "ja_JP", "ja", "00000000-0000-0000-0000-000000000004"]
  ].map do |id, family, identifier, name, locale, language, udid|
    {"id" => id, "family" => family, "deviceType" => {"identifier" => identifier, "name" => name}, "locale" => locale, "language" => language, "udid" => udid}
  end
}
File.write(path, JSON.pretty_generate(matrix) + "\n")
RUBY

if [[ "$scope" == scoped ]]; then
  ruby -rjson - "$contract" "$matrix" <<'RUBY'
contract_path, matrix_path = ARGV
contract = JSON.parse(File.read(contract_path))
contract["verificationScope"] = {"name"=>"iphone-ja", "stage"=>"feature", "reason"=>"Japanese iPhone first; finishing deferred."}
contract["verification"]["cases"].select! { |entry| entry["id"] == "iphone-ja" }
contract["verification"]["acceptanceMappings"].each { |entry| entry["checks"].select! { |check| check.start_with?("stage:") || check.end_with?(":iphone-ja") } }
matrix = JSON.parse(File.read(matrix_path))
matrix["scope"] = "iphone-ja"; matrix["cases"].select! { |entry| entry["id"] == "iphone-ja" }
File.write(contract_path, JSON.generate(contract)); File.write(matrix_path, JSON.generate(matrix))
RUBY
fi
png_fixture="$scratch/one-pixel.png"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' | /usr/bin/base64 -D >"$png_fixture"
for id in "${case_ids[@]}"; do
  cp "$png_fixture" "$head_dir/$id/screenshot.png"
  /usr/bin/ruby -rzlib - "$png_fixture" "$head_dir/$id/settings.png" "$id" <<'RUBY'
source, destination, label = ARGV
png = File.binread(source); payload = "State\0#{label}".b; type = "tEXt".b
chunk = [payload.bytesize].pack("N") + type + payload + [Zlib.crc32(type + payload)].pack("N")
File.binwrite(destination, png.byteslice(0, png.bytesize - 12) + chunk + png.byteslice(-12, 12))
RUBY
done

contract_digest=$(shasum -a 256 "$contract" | awk '{print $1}')
matrix_digest=$(shasum -a 256 "$matrix" | awk '{print $1}')
source_tree_digest=$(/usr/bin/ruby -rdigest - "$worktree" "$head" <<'RUBY'
repository, head = ARGV
records = IO.popen(["/usr/bin/git", "-C", repository, "ls-tree", "-r", "-z", "--full-tree", head], "rb", &:read).split("\0", -1)
records.pop
digest = Digest::SHA256.new
add = ->(value) { bytes = value.b; digest.update([bytes.bytesize].pack("Q>")); digest.update(bytes) }
add.call("ios-template-source-tree-v1"); add.call(head); add.call("TemplateApp.xcodeproj")
records.each do |record|
  metadata, path = record.split("\t", 2); mode, type, object = metadata.split(" "); next unless type == "blob"
  blob = IO.popen(["/usr/bin/git", "-C", repository, "cat-file", "blob", object], "rb", &:read)
  [mode, object, path].each { |value| add.call(value) }; add.call(blob)
end
puts digest.hexdigest
RUBY
)

ruby -rjson - "$fixtures/passed.json" "$verify" "$base" "$head" "$contract_digest" "$matrix_digest" "$source_tree_digest" <<'RUBY'
source, destination, base, head, contract, matrix, tree = ARGV
text = File.read(source)
{"BASE_SHA"=>base,"HEAD_SHA"=>head,"CONTRACT_DIGEST"=>contract,"MATRIX_DIGEST"=>matrix,"SOURCE_TREE_DIGEST"=>tree}.each { |key, value| text = text.gsub(key, value) }
File.write(destination, JSON.pretty_generate(JSON.parse(text)) + "\n")
RUBY

canonical_root=$(/usr/bin/swift -e 'import Foundation; print(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path)' "$worktree")
root_digest=$(printf '%s' "$canonical_root" | shasum -a 256 | awk '{print $1}')
workspace="/tmp/ios-template-verify/$(basename "$canonical_root")-$root_digest/issue-42/$head/Attempts/attempt-aaaaaaaa"
REPOSITORY="$worktree" EVIDENCE="$verify" DRAFT="$draft" WORKSPACE="$workspace" ruby -rjson -rdigest <<'RUBY'
final = JSON.parse(File.read(ENV.fetch("EVIDENCE")))
actions = JSON.parse(File.read(File.join(ENV.fetch("REPOSITORY"), ".artifacts/issues/42/issue-contract.json"))).fetch("verification").fetch("cases")
ids = actions.map { |entry| entry.fetch("id") }
final["cases"].select! { |entry| ids.include?(entry["id"]) }
final["acceptanceEvidence"].each { |entry| entry["evidence"].select! { |check| check.start_with?("stage:") || ids.any? { |id| check.end_with?(":#{id}") } } }
root = File.dirname(ENV.fetch("EVIDENCE"))
final.fetch("cases").each { |entry| entry["screenshotDigest"] = "sha256:#{Digest::SHA256.file(File.join(root, entry.fetch("screenshot"))).hexdigest}" }
File.write(ENV.fetch("EVIDENCE"), JSON.pretty_generate(final) + "\n")
draft = {
  "schemaVersion"=>1,"status"=>"awaiting-visual-review","issue"=>42,"baseSha"=>final.fetch("baseSha"),"headSha"=>final.fetch("headSha"),
  "issueContract"=>final.fetch("issueContract"),"matrixFile"=>final.fetch("matrixFile"),"matrixDigest"=>final.fetch("matrixDigest"),
  "executionRoute"=>"xcodebuild-simctl","xcode"=>final.fetch("xcode"),"build"=>final.fetch("build"),"tests"=>final.fetch("tests"),
  "cases"=>ids.map.with_index { |id,index| image=File.join(root,id,"screenshot.png"); {"id"=>id,"status"=>"passed","screenshot"=>"#{id}/screenshot.png","screenshotDigest"=>"sha256:#{Digest::SHA256.file(image).hexdigest}","mechanicalCheck"=>actions[index].key?("testIdentifier") ? "test:#{actions[index].fetch('testIdentifier')}" : "assertion:launch-succeeded"} },
  "acceptanceEvidence"=>final.fetch("acceptanceEvidence").map { |entry| {"id"=>entry.fetch("id"),"evidence"=>entry.fetch("evidence").reject { |check| check.start_with?("visual:") }} },
  "workspaceArtifacts"=>{"derivedDataPath"=>"#{ENV.fetch("WORKSPACE")}/DerivedData","buildResultBundlePath"=>"#{ENV.fetch("WORKSPACE")}/Build.xcresult","testResultBundlePath"=>"#{ENV.fetch("WORKSPACE")}/Tests.xcresult"},
  "executionCompletedAt"=>"2026-08-21T12:30:00+09:00"
}
File.write(ENV.fetch("DRAFT"), JSON.pretty_generate(draft) + "\n")
RUBY

STATE="$issue_dir/state.json" HEAD="$head" BASE="$base" CONTRACT_DIGEST="$contract_digest" ruby -rjson -e '
state={"schemaVersion"=>1,"issue"=>42,"repository"=>"yuto1201/iOS-Template","branch"=>"codex/42-render","worktree"=>".worktrees/42-render","baseSha"=>ENV.fetch("BASE"),"headSha"=>ENV.fetch("HEAD"),"primaryImplementer"=>"codex","issueContract"=>{"path"=>".artifacts/issues/42/issue-contract.json","digest"=>"sha256:#{ENV.fetch("CONTRACT_DIGEST")}"},"state"=>"in-progress","previousState"=>"claimed","resumeState"=>nil,"executor"=>"codex"};File.write(ENV.fetch("STATE"),JSON.generate(state))'
(
  cd "$worktree"
  /usr/bin/swift tools/validate-verify-json.swift --visual-packet --issue 42 --expected-base "$base" --draft ".artifacts/issues/42/$head/verify-draft.json" --output ".artifacts/issues/42/$head/visual-packet.json" >/dev/null
)
EVIDENCE="$verify" PACKET="$packet" ruby -rjson -rdigest -e '
path=ENV.fetch("EVIDENCE");value=JSON.parse(File.read(path));packet=JSON.parse(File.read(ENV.fetch("PACKET")));
value["visualEvaluation"]={"status"=>"passed","packet"=>{"path"=>".artifacts/issues/42/#{value.fetch("headSha")}/visual-packet.json","digest"=>"sha256:#{Digest::SHA256.file(ENV.fetch("PACKET")).hexdigest}"},"cases"=>packet.fetch("cases").map{|entry|{"id"=>entry.fetch("id"),"images"=>entry.fetch("images").map{|image|{"state"=>image.fetch("state"),"path"=>image.fetch("path"),"digest"=>image.fetch("digest"),"status"=>"passed","findings"=>[]}}}},"findings"=>[]};File.write(path,JSON.pretty_generate(value)+"\n")'

seal_review() {
  REPOSITORY="$worktree" CONTRACT="$contract" VERIFY="$verify" REVIEW_PACKET="$review_packet" REVIEW_DIFF="$review_diff" REVIEW="$review" HEAD="$head" BASE="$base" \
    ruby -I "$primary/tools/lib" -rjson -rdigest -rreview-contract -rprepare-review-packet <<'RUBY'
repo = File.realpath(ENV.fetch("REPOSITORY"))
contract_path = ENV.fetch("CONTRACT")
verify_path = ENV.fetch("VERIFY")
packet_path = ENV.fetch("REVIEW_PACKET")
diff_path = ENV.fetch("REVIEW_DIFF")
result_path = ENV.fetch("REVIEW")
base = ENV.fetch("BASE")
head = ENV.fetch("HEAD")
contract_bytes = File.binread(contract_path)
verify_bytes = File.binread(verify_path)
verify = JSON.parse(verify_bytes)
File.unlink(packet_path) if File.exist?(packet_path)
File.unlink(diff_path) if File.exist?(diff_path)
IOSTemplate::PrepareReviewPacket.prepare(repo: repo, primary: "codex", issue: 42, base_sha: base, head_sha: head)
packet_bytes = File.binread(packet_path)
result = {
  "schemaVersion" => 2, "issue" => 42, "reviewerModel" => "claude", "baseSha" => base,
  "headSha" => head, "verifySha" => head, "issueContractDigest" => IOSTemplate::ReviewContract.digest(contract_bytes),
  "verdict" => "approved", "findings" => [],
  "acceptanceAssessment" => verify.fetch("acceptanceEvidence").map { |item| {"id" => item.fetch("id"), "status" => "supported", "evidence" => ["verify.json#acceptanceEvidence"]} },
  "reviewedAt" => "2026-08-21T13:01:00+09:00", "reviewPacketDigest" => IOSTemplate::ReviewContract.digest(packet_bytes)
}
File.binwrite(result_path, JSON.generate(result))
RUBY
}
seal_review

cp "$contract" "$scratch/contract.good"; cp "$verify" "$scratch/verify.good"; cp "$review" "$scratch/review.good"; cp "$review_packet" "$scratch/review-packet.good"; cp "$review_diff" "$scratch/review-diff.good"; cp "$matrix" "$scratch/matrix.good"; cp "$packet" "$scratch/packet.good"
for id in "${case_ids[@]}"; do cp "$head_dir/$id/screenshot.png" "$scratch/$id-screenshot.good"; cp "$head_dir/$id/settings.png" "$scratch/$id-settings.good"; done

run_renderer() { "$worktree/tools/render-pr-body.sh" --issue "$issue" --head-sha "$head"; }
restore_application() {
  cp "$scratch/contract.good" "$contract"; cp "$scratch/verify.good" "$verify"; cp "$scratch/review.good" "$review"; cp "$scratch/review-packet.good" "$review_packet"; cp "$scratch/review-diff.good" "$review_diff"; cp "$scratch/matrix.good" "$matrix"; rm -f "$packet"; cp "$scratch/packet.good" "$packet"
  for id in "${case_ids[@]}"; do cp "$scratch/$id-screenshot.good" "$head_dir/$id/screenshot.png"; cp "$scratch/$id-settings.good" "$head_dir/$id/settings.png"; done
}
expect_refusal() {
  local label=$1
  if run_renderer >"$scratch/$label.out" 2>"$scratch/$label.err"; then echo "unsafe visual evidence was rendered: $label" >&2; exit 1; fi
  if grep -Fq 'None for this Issue' "$scratch/$label.out"; then echo "unsafe evidence overclaimed Remaining work: $label" >&2; exit 1; fi
}

body=$(run_renderer)
if [[ "$scope" == scoped ]]; then
  grep -Fq 'iPhone Pro / Japanese (`iphone-ja`): `passed`' <<<"$body"
  [[ "$(grep -c 'deferred / unverified' <<<"$body")" == 3 ]]
  ! grep -Eq '(English|iPad).*`passed`' <<<"$body"
  ruby -rjson - "$review_packet" <<'RUBY'
value = JSON.parse(File.read(ARGV[0]))
abort "packet contains unverified languages/devices" unless value["imageFiles"].all? { |entry| entry["path"].include?("/iphone-ja/") }
RUBY
  printf '\n' >>"$matrix"; expect_refusal scoped-stale-matrix
  echo 'PASS: one-case canonical review packet and PR keep English/iPad deferred/unverified'
  exit 0
fi
for expected in \
  'Closes #42' \
  '`docs/verification.md#stage-e-evidence`' \
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

printf '\n' >>"$matrix"; expect_refusal current-matrix-corruption; restore_application
printf 'corruption' >>"$head_dir/iphone-en/screenshot.png"; expect_refusal current-primary-screenshot-corruption; restore_application
chmod u+w "$packet"; printf '\n' >>"$packet"; expect_refusal current-packet-corruption; restore_application
printf 'corruption' >>"$head_dir/iphone-en/settings.png"; expect_refusal current-referenced-image-corruption; restore_application

# Wait until the renderer retains visual-packet.json, then atomically replace the
# visual packet with identical bytes. A digest-only check must not hide this.
ruby - "$packet" <<'RUBY' &
packet = ARGV.fetch(0)
guard = File.open(packet, "rb")
loop do
  if guard.flock(File::LOCK_EX | File::LOCK_NB)
    guard.flock(File::LOCK_UN); sleep 0.001
  else
    replacement = "#{packet}.swap"; File.binwrite(replacement, File.binread(packet)); File.rename(replacement, packet); break
  end
end
RUBY
swapper=$!
if run_renderer >"$scratch/same-byte-swap.out" 2>"$scratch/same-byte-swap.err"; then wait "$swapper" || true; echo 'same-byte atomic packet swap was rendered as merge-ready' >&2; exit 1; fi
wait "$swapper"
restore_application

# The strict review packet itself is retained too. Replacing it atomically with
# identical bytes must still invalidate the merge-ready claim.
ruby - "$review_packet" <<'RUBY' &
packet = ARGV.fetch(0)
guard = File.open(packet, "rb")
loop do
  if guard.flock(File::LOCK_EX | File::LOCK_NB)
    guard.flock(File::LOCK_UN); sleep 0.001
  else
    replacement = "#{packet}.swap"; File.binwrite(replacement, File.binread(packet)); File.rename(replacement, packet); break
  end
end
RUBY
swapper=$!
if run_renderer >"$scratch/same-byte-review-packet-swap.out" 2>"$scratch/same-byte-review-packet-swap.err"; then wait "$swapper" || true; echo 'same-byte atomic review packet swap was rendered as merge-ready' >&2; exit 1; fi
wait "$swapper"
restore_application

ln "$verify" "$verify.hardlink"; expect_refusal hardlinked-verify
grep -Fq 'single-link' "$scratch/hardlinked-verify.err" || { echo 'hardlink refusal was not explicit' >&2; exit 1; }
rm "$verify.hardlink"

expect_verify_mutation() {
  local label=$1 code=$2
  restore_application
  MUTATION="$code" VERIFY="$verify" ruby -rjson -e 'p=ENV.fetch("VERIFY");v=JSON.parse(File.read(p));eval(ENV.fetch("MUTATION"),binding);File.write(p,JSON.generate(v))'
  expect_refusal "$label"
}
expect_verify_mutation failed-build 'v["build"]["status"]="failed"'
expect_verify_mutation warnings-added 'v["build"]["warningsAdded"]=1'
expect_verify_mutation skipped-tests 'v["tests"]["skipped"]=1'
expect_verify_mutation missing-case 'v["cases"].pop'
expect_verify_mutation missing-visual-case 'v["visualEvaluation"]["cases"].pop'
expect_verify_mutation incomplete-schema 'v.delete("executionRoute")'
restore_application

cp "$scratch/review.good" "$review"; ruby -rjson -e 'p=ARGV[0];v=JSON.parse(File.read(p));v["acceptanceAssessment"][0]["status"]="unsupported";File.write(p,JSON.generate(v))' "$review"; expect_refusal unsupported-review; restore_application
cp "$scratch/review.good" "$review"; ruby -rjson -e 'p=ARGV[0];v=JSON.parse(File.read(p));v["unexpected"]="field";File.write(p,JSON.generate(v))' "$review"; expect_refusal review-schema; restore_application

# Merge-ready rendering requires the sealed schema-v2 review closure, not the
# legacy result shape that lacks an exact packet-byte digest.
ruby -rjson -e 'p=ARGV.fetch(0);v=JSON.parse(File.binread(p));v["schemaVersion"]=1;v.delete("reviewPacketDigest");File.binwrite(p,JSON.generate(v))' "$review"
expect_refusal legacy-v1-review; restore_application

ruby -rjson -e 'p=ARGV.fetch(0);v=JSON.parse(File.binread(p));v["reviewPacketDigest"]="sha256:"+("f"*64);File.binwrite(p,JSON.generate(v))' "$review"
expect_refusal result-packet-digest-mismatch; restore_application

ruby -rjson -e 'p=ARGV.fetch(0);v=JSON.parse(File.binread(p));v["specAnchors"]=["specs/other.md#packet-swap"];File.binwrite(p,JSON.generate(v))' "$review_packet"
expect_refusal review-packet-swap; restore_application

PACKET="$review_packet" REVIEW="$review" ruby -rjson -rdigest -e '
packet=JSON.parse(File.binread(ENV.fetch("PACKET")));packet["primaryModel"]="untrusted";packet["reviewerModel"]="codex";bytes=JSON.generate(packet);File.binwrite(ENV.fetch("PACKET"),bytes);result=JSON.parse(File.binread(ENV.fetch("REVIEW")));result["reviewerModel"]="codex";result["reviewPacketDigest"]="sha256:#{Digest::SHA256.hexdigest(bytes)}";File.binwrite(ENV.fetch("REVIEW"),JSON.generate(result))'
expect_refusal invalid-primary-model; restore_application

# Even a self-consistent packet/result digest cannot bless bytes that are not
# the deterministic actual Base..Head diff.
printf 'bogus but self-consistent diff\n' >"$review_diff"
DIFF="$review_diff" PACKET="$review_packet" REVIEW="$review" ruby -rjson -rdigest -e '
packet=JSON.parse(File.binread(ENV.fetch("PACKET")));packet.fetch("diff")["digest"]="sha256:#{Digest::SHA256.file(ENV.fetch("DIFF")).hexdigest}";bytes=JSON.generate(packet);File.binwrite(ENV.fetch("PACKET"),bytes);result=JSON.parse(File.binread(ENV.fetch("REVIEW")));result["reviewPacketDigest"]="sha256:#{Digest::SHA256.hexdigest(bytes)}";File.binwrite(ENV.fetch("REVIEW"),JSON.generate(result))'
expect_refusal bogus-actual-diff; restore_application

ruby -rjson -e 'p=ARGV.fetch(0);v=JSON.parse(File.binread(p));v["externalOperationDetailsDigest"]="sha256:"+("1"*64);File.binwrite(p,JSON.generate(v))' "$contract"
expect_refusal changed-contract-details; restore_application

ruby -rjson -e 'p=ARGV.fetch(0);v=JSON.parse(File.binread(p));v.delete("externalOperationDetailsDigest");File.binwrite(p,JSON.generate(v))' "$contract"
expect_refusal missing-operation-details-digest; restore_application

mv "$head_dir" "$head_dir.real"; ln -s "$head.real" "$head_dir"
expect_refusal symlinked-head
grep -Fq 'descriptor' "$scratch/symlinked-head.err" || { echo 'symlink component refusal was not explicit' >&2; exit 1; }
rm "$head_dir"; mv "$head_dir.real" "$head_dir"

# Documentation-only evidence remains valid without visual artifacts.
VERIFY="$verify" ruby -rjson -e '
p=ENV.fetch("VERIFY");v=JSON.parse(File.read(p));v["status"]="not-applicable";v["changeClassification"]="documentation-only";v["reason"]="Only allowlisted Markdown documentation changed";v["matrixFile"]=nil;v["matrixDigest"]=nil;v["executionRoute"]="none";v["xcode"]=nil;v["build"]={"status"=>"not-applicable","scheme"=>nil,"warningsAdded"=>nil,"project"=>nil,"sourceTree"=>nil};v["tests"]={"status"=>"not-applicable","passed"=>nil,"failed"=>nil,"skipped"=>nil};v["cases"]=[];v["visualEvaluation"]={"status"=>"not-applicable","findings"=>[]};v["acceptanceEvidence"]=[{"id"=>"AC-1","status"=>"passed","evidence"=>["documents:renderer"]},{"id"=>"AC-2","status"=>"passed","evidence"=>["links:renderer"]}];File.write(p,JSON.pretty_generate(v)+"\n")'
VERIFY="$verify" REVIEW="$review" ruby -rjson -e '
v=JSON.parse(File.read(ENV.fetch("VERIFY")));r=JSON.parse(File.read(ENV.fetch("REVIEW")));r["acceptanceAssessment"]=v.fetch("acceptanceEvidence").map{|item|{"id"=>item.fetch("id"),"status"=>"supported","evidence"=>["review.diff"]}};File.write(ENV.fetch("REVIEW"),JSON.generate(r))'
seal_review
documentation_body=$(run_renderer)
grep -Fq 'Verify status: `not-applicable`' <<<"$documentation_body" || { echo 'documentation-only PR body was rejected' >&2; exit 1; }

# Explicit fast renders current-Head evidence without opening or requiring any
# opposite-model artifact.
CONTRACT="$contract" VERIFY="$verify" STATE="$issue_dir/state.json" ruby -rjson -rdigest -e '
contract_path=ENV.fetch("CONTRACT"); contract=JSON.parse(File.binread(contract_path)); contract.delete("verification"); contract["deliveryProfile"]={"name"=>"fast","reason"=>"Non-UI low-risk renderer fixture."}; File.binwrite(contract_path,JSON.generate(contract)); digest="sha256:#{Digest::SHA256.file(contract_path).hexdigest}"; verify_path=ENV.fetch("VERIFY"); verify=JSON.parse(File.binread(verify_path)); verify.fetch("issueContract")["digest"]=digest; File.binwrite(verify_path,JSON.pretty_generate(verify)+"\n"); state_path=ENV.fetch("STATE"); state=JSON.parse(File.binread(state_path)); state.fetch("issueContract")["digest"]=digest; File.binwrite(state_path,JSON.generate(state))'
rm -f "$review" "$review_packet" "$review_diff" "$head_dir/review-receipt.json"
fast_body=$(run_renderer)
grep -Fq 'Not required by this non-release, non-strict contract.' <<<"$fast_body" || { echo 'fast PR body did not record the review waiver' >&2; exit 1; }

echo 'PASS: PR body readiness is bound to canonical current visual evidence and documentation-only validation remains available'
bash "$source_root/tools/tests/test-render-pr-body.sh" scoped
