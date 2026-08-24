#!/usr/bin/env bash
set -euo pipefail

source_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
builder="$source_repo/tools/visual-review-packet.sh"
scratch="$(mktemp -d -t ios-visual-packet.XXXXXX)"
scratch="$(cd "$scratch" && pwd -P)"
trap '[[ "${KEEP_VISUAL_PACKET_SCRATCH-}" == 1 ]] || rm -rf "$scratch"' EXIT

if [[ ! -e "$builder" ]]; then
  if "$builder" --issue 42 --expected-base "$(printf '0%.0s' {1..40})" \
      --draft .artifacts/issues/42/$(printf '1%.0s' {1..40})/verify-draft.json \
      --output .artifacts/issues/42/$(printf '1%.0s' {1..40})/visual-packet.json \
      >"$scratch/red.stdout" 2>"$scratch/red.stderr"; then
    echo "missing visual packet builder unexpectedly succeeded" >&2
    exit 1
  fi
  grep -Eq 'No such file|not found' "$scratch/red.stderr"
  echo "visual review packet RED: production builder is absent"
  exit 1
fi

repo=""
base_sha=""
head_sha=""
draft=""
packet=""
contract=""
matrix=""
final=""

png_primary='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='

write_distinct_png() {
  local source="$1" destination="$2" label="$3"
  /usr/bin/ruby --disable-gems -rzlib - "$source" "$destination" "$label" <<'RUBY'
source, destination, label = ARGV
png = File.binread(source)
raise "bad fixture" unless png.start_with?("\x89PNG\r\n\x1a\n".b) && png.byteslice(-12, 4) == [0].pack("N") && png.byteslice(-8, 4) == "IEND"
payload = "State\0#{label}".b
type = "tEXt".b
chunk = [payload.bytesize].pack("N") + type + payload + [Zlib.crc32(type + payload)].pack("N")
File.binwrite(destination, png.byteslice(0, png.bytesize - 12) + chunk + png.byteslice(-12, 12))
RUBY
}

digest() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print "sha256:" $1}'
}

head_tree_digests() {
  /usr/bin/ruby --disable-gems -rdigest - "$1" "$2" <<'RUBY'
repository, head = ARGV
records = IO.popen(["/usr/bin/git", "-C", repository, "ls-tree", "-r", "-z", "--full-tree", head], "rb", &:read).split("\0", -1)
records.pop
entries = records.map do |record|
  metadata, path = record.split("\t", 2)
  mode, type, object = metadata.split(" ")
  raise "unexpected tree type" unless type == "blob"
  blob = IO.popen(["/usr/bin/git", "-C", repository, "cat-file", "blob", object], "rb", &:read)
  [mode, object, path, blob]
end
add = ->(digest, value) do
  bytes = value.b
  digest.update([bytes.bytesize].pack("Q>"))
  digest.update(bytes)
end
source = Digest::SHA256.new
["ios-template-source-tree-v1", head, "TemplateApp.xcodeproj"].each { |value| add.call(source, value) }
entries.each { |entry| entry.each { |value| add.call(source, value) } }
project = Digest::SHA256.new
add.call(project, "ios-template-project-v1")
prefix = "TemplateApp.xcodeproj/"
entries.select { |entry| entry[2].start_with?(prefix) }.each do |mode, _object, path, blob|
  add.call(project, mode == "100755" ? "X" : "F")
  add.call(project, path.delete_prefix(prefix))
  add.call(project, blob)
end
puts ["sha256:#{project.hexdigest}", "sha256:#{source.hexdigest}"].join("\t")
RUBY
}

prepare_fixture() {
  local label="$1"
  repo="$scratch/$label/repository"
  /bin/mkdir -p "$repo/docs" "$repo/TemplateApp.xcodeproj" "$repo/Sources"
  repo="$(cd "$repo" && pwd -P)"
  /usr/bin/git -C "$repo" init -q
  /usr/bin/git -C "$repo" config user.name 'Visual Packet Test'
  /usr/bin/git -C "$repo" config user.email 'visual-packet@example.invalid'
  printf '%s\n' '.artifacts/' >"$repo/.gitignore"
  printf '%s\n' '# Base' >"$repo/docs/base.md"
  printf '%s\n' '// !$*UTF8*$!' >"$repo/TemplateApp.xcodeproj/project.pbxproj"
  printf '%s\n' 'struct FixtureApp {}' >"$repo/Sources/App.swift"
  /usr/bin/git -C "$repo" add -- .gitignore docs/base.md TemplateApp.xcodeproj Sources/App.swift
  /usr/bin/git -C "$repo" commit -q -m base
  base_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"
  printf '%s\n' '# Head' >"$repo/docs/head.md"
  /usr/bin/git -C "$repo" add -- docs/head.md
  /usr/bin/git -C "$repo" commit -q -m head
  head_sha="$(/usr/bin/git -C "$repo" rev-parse HEAD)"

  contract="$repo/.artifacts/issues/42/issue-contract.json"
  matrix="$repo/.artifacts/batches/visual-fixture/simulator-matrix.json"
  draft="$repo/.artifacts/issues/42/$head_sha/verify-draft.json"
  packet="$repo/.artifacts/issues/42/$head_sha/visual-packet.json"
  final="$repo/.artifacts/issues/42/$head_sha/verify.json"
  /bin/mkdir -p "$(dirname "$contract")" "$(dirname "$matrix")" "$(dirname "$draft")"

  /usr/bin/ruby --disable-gems -rjson -rtime - "$contract" <<'RUBY'
path = ARGV.fetch(0)
ids = %w[iphone-en iphone-ja ipad-en ipad-ja]
document = {
  "schemaVersion" => 1,
  "issue" => 42,
  "repository" => "yuto1201/iOS-Template",
  "goal" => "Create a safe visual review packet",
  "specAnchors" => ["docs/verification.md#stage-d-ai-visual-evaluation"],
  "acceptanceCriteria" => [
    {"id" => "AC-1", "text" => "Screenshots are reviewed in all four standard cases"},
    {"id" => "AC-2", "text" => "Visual findings are bound to the current Head"}
  ],
  "dependencies" => [],
  "externalOperations" => [],
  "externalOperationDetailsDigest" => "sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945",
  "fetchedAt" => Time.now.iso8601,
  "verification" => {
    "bundleIdentifier" => "com.example.TemplateApp",
    "unitTestIdentifier" => "TemplateAppTests/UnitSmokeTests/testUnit",
    "cases" => ids.map { |id| {"id" => id, "assertion" => {"kind" => "launch-succeeded"}} },
    "acceptanceMappings" => [
      {"id" => "AC-1", "checks" => ["stage:build", "stage:unit-tests", "case:iphone-en", "case:iphone-ja", "case:ipad-en", "case:ipad-ja", "visual:iphone-en", "visual:iphone-ja", "visual:ipad-en", "visual:ipad-ja"]},
      {"id" => "AC-2", "checks" => ["stage:build", "visual:iphone-en", "visual:iphone-ja", "visual:ipad-en", "visual:ipad-ja"]}
    ]
  }
}
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY

  /usr/bin/ruby --disable-gems -rjson -rtime - "$matrix" <<'RUBY'
path = ARGV.fetch(0)
rows = [
  ["iphone-en", "iPhone", "en_US", "en", "00000000-0000-0000-0000-000000000001"],
  ["iphone-ja", "iPhone", "ja_JP", "ja", "00000000-0000-0000-0000-000000000002"],
  ["ipad-en", "iPad", "en_US", "en", "00000000-0000-0000-0000-000000000003"],
  ["ipad-ja", "iPad", "ja_JP", "ja", "00000000-0000-0000-0000-000000000004"]
]
document = {
  "schemaVersion" => 1, "batchId" => "visual-fixture", "resolvedAt" => Time.now.iso8601,
  "xcode" => {"path" => "/Applications/Xcode.app/Contents/Developer", "version" => "26.5", "build" => "17F42"},
  "runtime" => {"identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version" => "26.5"},
  "cases" => rows.map do |id, family, locale, language, udid|
    type = family == "iPhone" ? ["com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro"] : ["com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3", "iPad Air 13-inch (M3)"]
    {"id" => id, "family" => family, "deviceType" => {"identifier" => type[0], "name" => type[1]}, "locale" => locale, "language" => language, "udid" => udid}
  end
}
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY

  local case_id primary additional
  for case_id in iphone-en iphone-ja ipad-en ipad-ja; do
    /bin/mkdir -p "$(dirname "$draft")/$case_id"
    primary="$(dirname "$draft")/$case_id/screenshot.png"
    printf '%s' "$png_primary" | /usr/bin/base64 -D >"$primary"
    additional="$(dirname "$draft")/$case_id/settings-open.png"
    write_distinct_png "$primary" "$additional" "$case_id"
  done

  local tree_digests project_digest source_digest validator_repo root_digest workspace
  tree_digests="$(head_tree_digests "$repo" "$head_sha")"
  IFS=$'\t' read -r project_digest source_digest <<<"$tree_digests"
  validator_repo="$(/usr/bin/swift -e 'import Foundation; print(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path)' "$repo")"
  root_digest="$(printf '%s' "$validator_repo" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  workspace="/tmp/ios-template-verify/repository-$root_digest/issue-42/$head_sha/Attempts/attempt-aaaaaaaa"
  CONTRACT_DIGEST="$(digest "$contract")" MATRIX_DIGEST="$(digest "$matrix")" \
    PROJECT_DIGEST="$project_digest" SOURCE_DIGEST="$source_digest" WORKSPACE="$workspace" \
    /usr/bin/ruby --disable-gems -rjson -rtime -rdigest - "$draft" "$base_sha" "$head_sha" "$repo" <<'RUBY'
path, base, head, repo = ARGV
ids = %w[iphone-en iphone-ja ipad-en ipad-ja]
case_rows = ids.map do |id|
  image = File.join(File.dirname(path), id, "screenshot.png")
  {"id" => id, "status" => "passed", "screenshot" => "#{id}/screenshot.png", "screenshotDigest" => "sha256:#{Digest::SHA256.file(image).hexdigest}", "mechanicalCheck" => "assertion:launch-succeeded"}
end
document = {
  "schemaVersion" => 1, "status" => "awaiting-visual-review", "issue" => 42,
  "baseSha" => base, "headSha" => head,
  "issueContract" => {"path" => ".artifacts/issues/42/issue-contract.json", "digest" => ENV.fetch("CONTRACT_DIGEST")},
  "matrixFile" => ".artifacts/batches/visual-fixture/simulator-matrix.json", "matrixDigest" => ENV.fetch("MATRIX_DIGEST"),
  "executionRoute" => "xcodebuild-simctl",
  "xcode" => {"path" => "/Applications/Xcode.app/Contents/Developer", "version" => "26.5", "build" => "17F42"},
  "build" => {"status" => "passed", "scheme" => "TemplateApp", "warningsAdded" => 0, "project" => {"path" => "TemplateApp.xcodeproj", "digest" => ENV.fetch("PROJECT_DIGEST")}, "sourceTree" => {"headSha" => head, "digest" => ENV.fetch("SOURCE_DIGEST"), "projectPath" => "TemplateApp.xcodeproj"}},
  "tests" => {"status" => "passed", "passed" => 1, "failed" => 0, "skipped" => 0},
  "cases" => case_rows,
  "acceptanceEvidence" => [
    {"id" => "AC-1", "evidence" => ["stage:build", "stage:unit-tests", "case:iphone-en", "case:iphone-ja", "case:ipad-en", "case:ipad-ja"]},
    {"id" => "AC-2", "evidence" => ["stage:build"]}
  ],
  "workspaceArtifacts" => {
    "derivedDataPath" => ENV.fetch("WORKSPACE") + "/DerivedData",
    "buildResultBundlePath" => ENV.fetch("WORKSPACE") + "/Build.xcresult",
    "testResultBundlePath" => ENV.fetch("WORKSPACE") + "/Tests.xcresult"
  },
  "executionCompletedAt" => Time.now.iso8601
}
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
}

mutate_json() {
  local path="$1" expression="$2"
  MUTATION="$expression" /usr/bin/ruby --disable-gems -rjson - "$path" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.read(path))
eval(ENV.fetch("MUTATION"), binding, "fixture mutation")
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
}

refresh_contract_digest() {
  DIGEST="$(digest "$contract")" mutate_json "$draft" 'document.fetch("issueContract")["digest"] = ENV.fetch("DIGEST")'
}

refresh_matrix_digest() {
  DIGEST="$(digest "$matrix")" mutate_json "$draft" 'document["matrixDigest"] = ENV.fetch("DIGEST")'
}

write_visual_result() {
  local visual="$(dirname "$draft")/visual-result.json"
  /usr/bin/ruby --disable-gems -rjson -rtime -rdigest - "$draft" "$packet" "$visual" <<'RUBY'
draft_path, packet_path, visual_path = ARGV
draft = JSON.parse(File.read(draft_path))
packet = JSON.parse(File.read(packet_path))
document = {
  "schemaVersion" => 1,
  "status" => "approved",
  "issue" => draft.fetch("issue"),
  "headSha" => draft.fetch("headSha"),
  "draft" => {
    "path" => ".artifacts/issues/42/#{draft.fetch("headSha")}/verify-draft.json",
    "digest" => "sha256:#{Digest::SHA256.file(draft_path).hexdigest}"
  },
  "visualPacket" => {
    "path" => ".artifacts/issues/42/#{draft.fetch("headSha")}/visual-packet.json",
    "digest" => "sha256:#{Digest::SHA256.file(packet_path).hexdigest}"
  },
  "cases" => packet.fetch("cases").map do |entry|
    {
      "id" => entry.fetch("id"),
      "status" => "approved",
      "images" => entry.fetch("images").map do |image|
        {
          "state" => image.fetch("state"),
          "path" => image.fetch("path"),
          "digest" => image.fetch("digest"),
          "findings" => []
        }
      end,
      "findings" => []
    }
  end,
  "findings" => [],
  "reviewedAt" => Time.now.iso8601
}
File.write(visual_path, JSON.pretty_generate(document) + "\n")
RUBY
}

run_finalizer() {
  (
    cd "$repo"
    /usr/bin/swift "$source_repo/tools/validate-verify-json.swift" --runner-finalize \
      --issue 42 --expected-base "$base_sha" --expected-head "$head_sha" \
      --draft ".artifacts/issues/42/$head_sha/verify-draft.json" \
      --visual-result ".artifacts/issues/42/$head_sha/visual-result.json"
  )
}

run_standalone_validator() {
  (
    cd "$repo"
    /usr/bin/swift "$source_repo/tools/validate-verify-json.swift" \
      --file ".artifacts/issues/42/$head_sha/verify.json" --expected-issue 42 \
      --expected-base "$base_sha" --expected-head "$head_sha"
  )
}

run_builder() {
  (
    cd "$repo"
    BASH_ENV="$scratch/poison-bash-env" RUBYOPT='-r/nonexistent-poison' SWIFT_EXEC=/nonexistent-poison \
      PATH=/nonexistent "$builder" --issue 42 --expected-base "$base_sha" \
      --draft ".artifacts/issues/42/$head_sha/verify-draft.json" \
      --output ".artifacts/issues/42/$head_sha/visual-packet.json"
  )
}

expect_failure() {
  local label="$1" diagnostic="$2"
  if run_builder >"$scratch/$label.stdout" 2>"$scratch/$label.stderr"; then
    echo "visual packet builder unexpectedly accepted $label" >&2
    exit 1
  fi
  if ! /usr/bin/grep -Fq -- "$diagnostic" "$scratch/$label.stderr"; then
    echo "visual packet builder rejected $label for the wrong reason; expected: $diagnostic" >&2
    /bin/cat "$scratch/$label.stderr" >&2
    exit 1
  fi
  [[ ! -e "$packet" ]] || { echo "$label left a canonical packet" >&2; exit 1; }
}

expect_finalize_failure() {
  local label="$1" diagnostic="$2"
  if run_finalizer >"$scratch/$label.finalize.stdout" 2>"$scratch/$label.finalize.stderr"; then
    echo "visual finalizer unexpectedly accepted $label" >&2
    exit 1
  fi
  if ! /usr/bin/grep -Fq -- "$diagnostic" "$scratch/$label.finalize.stderr"; then
    echo "visual finalizer rejected $label for the wrong reason; expected: $diagnostic" >&2
    /bin/cat "$scratch/$label.finalize.stderr" >&2
    exit 1
  fi
  [[ ! -e "$final" ]] || { echo "$label left final evidence" >&2; exit 1; }
}

prepare_fixture valid
run_builder >/dev/null
PACKET="$packet" HOME_PATH="$HOME" /usr/bin/ruby --disable-gems -rjson - <<'RUBY'
packet = JSON.parse(File.read(ENV.fetch("PACKET")))
raise "keys" unless packet.keys.sort == %w[acceptanceCriteria cases draft headSha issue issueContract matrix reviewChecks schemaVersion status].sort
raise "identity" unless packet["schemaVersion"] == 1 && packet["status"] == "ready-for-visual-review" && packet["issue"] == 42
raise "cases" unless packet.fetch("cases").map { |entry| entry.fetch("id") } == %w[iphone-en iphone-ja ipad-en ipad-ja]
packet.fetch("cases").each do |entry|
  raise "images" unless entry.fetch("images").map { |image| image.fetch("state") } == %w[primary settings-open]
  raise "primary" unless entry.fetch("images").first.fetch("primary") == true
  entry.fetch("images").each do |image|
    raise "dimension" unless image.fetch("width") == 1 && image.fetch("height") == 1
    raise "path" if image.fetch("path").start_with?("/") || image.fetch("path").include?("..")
  end
end
serialized = File.binread(ENV.fetch("PACKET"))
raise "personal path leaked" if serialized.include?(ENV.fetch("HOME_PATH"))
raise "checks" unless packet.fetch("reviewChecks") == %w[acceptance-criteria clipping overlap translation information-hierarchy ipad-adaptation dynamic-type-indicators tap-targets spec-comparison]
RUBY
write_visual_result
run_finalizer >/dev/null
run_standalone_validator >/dev/null
FINAL="$final" PACKET="$packet" /usr/bin/ruby --disable-gems -rjson -rdigest - <<'RUBY'
final = JSON.parse(File.read(ENV.fetch("FINAL")))
visual = final.fetch("visualEvaluation")
raise "visual keys" unless visual.keys.sort == %w[cases findings packet status].sort
raise "packet ref" unless visual.fetch("packet").fetch("digest") == "sha256:#{Digest::SHA256.file(ENV.fetch("PACKET")).hexdigest}"
raise "all images" unless visual.fetch("cases").all? { |entry| entry.fetch("images").map { |image| image.fetch("state") } == %w[primary settings-open] }
RUBY

prepare_fixture missing-image
/bin/rm "$(dirname "$draft")/iphone-en/screenshot.png"
expect_failure missing-image "primary screenshot is unavailable"

prepare_fixture outside-image
mutate_json "$draft" 'document.fetch("cases").fetch(0)["screenshot"] = "../outside.png"'
expect_failure outside-image "draft primary screenshot path is invalid"

prepare_fixture symlink-image
printf '%s' "$png_primary" | /usr/bin/base64 -D >"$repo/outside.png"
/bin/ln -s "$repo/outside.png" "$(dirname "$draft")/iphone-en/outside.png"
expect_failure symlink-image "additional screenshot must be a regular non-symbolic-link file"

prepare_fixture secret-name
/bin/cp "$(dirname "$draft")/iphone-en/settings-open.png" "$(dirname "$draft")/iphone-en/api-token.png"
expect_failure secret-name "secret-like screenshot filename"

prepare_fixture mismatched-head
mutate_json "$draft" 'document["headSha"] = "0" * 40'
expect_failure mismatched-head "draft Head does not match current Git Head"

prepare_fixture mismatched-contract-digest
mutate_json "$draft" 'document.fetch("issueContract")["digest"] = "sha256:" + "0" * 64'
expect_failure mismatched-contract-digest "issueContract.digest does not match exact file bytes"

prepare_fixture mismatched-matrix-digest
mutate_json "$draft" 'document["matrixDigest"] = "sha256:" + "0" * 64'
expect_failure mismatched-matrix-digest "draft matrixDigest does not match exact file bytes"

prepare_fixture mismatched-project-digest
mutate_json "$draft" 'document.fetch("build").fetch("project")["digest"] = "sha256:" + "0" * 64'
expect_failure mismatched-project-digest "build.project does not match the current project at expected Head"

prepare_fixture mismatched-source-digest
mutate_json "$draft" 'document.fetch("build").fetch("sourceTree")["digest"] = "sha256:" + "0" * 64'
expect_failure mismatched-source-digest "build.sourceTree does not match exact Head"

prepare_fixture mismatched-workspace
mutate_json "$draft" 'document.fetch("workspaceArtifacts")["derivedDataPath"] = "/tmp/unbound/DerivedData"'
expect_failure mismatched-workspace "draft workspaceArtifacts do not match the current physical worktree"

prepare_fixture mismatched-route
mutate_json "$draft" 'document["executionRoute"] = "xcodebuild-mcp"'
expect_failure mismatched-route "draft execution identity is invalid"

prepare_fixture future-draft-time
mutate_json "$draft" 'document["executionCompletedAt"] = "2099-01-01T00:00:00Z"'
expect_failure future-draft-time "draft executionCompletedAt is implausibly in the future"

prepare_fixture stale-draft-time
mutate_json "$draft" 'document["executionCompletedAt"] = "2026-08-21T11:59:59+09:00"'
expect_failure stale-draft-time "draft executionCompletedAt precedes canonical inputs"

prepare_fixture malicious-contract-text
mutate_json "$contract" 'document.fetch("acceptanceCriteria").fetch(0)["text"] = "password=do-not-print-this-value"'
refresh_contract_digest
expect_failure malicious-contract-text "unsafe serialized metadata"
! /usr/bin/grep -Fq 'do-not-print-this-value' "$scratch/malicious-contract-text.stderr" || {
  echo "secret appeared in contract rejection diagnostic" >&2; exit 1;
}

prepare_fixture generic-credential-labels
mutate_json "$contract" 'document.fetch("acceptanceCriteria").fetch(0)["text"] = "Password: Required; Token: Optional"'
refresh_contract_digest
run_builder >/dev/null
PACKET="$packet" /usr/bin/ruby --disable-gems -rjson -e '
  text = JSON.parse(File.read(ENV.fetch("PACKET"))).fetch("acceptanceCriteria").first.fetch("text")
  abort "generic labels changed" unless text == "Password: Required; Token: Optional"
'

prepare_fixture malicious-matrix-text
mutate_json "$matrix" 'document.fetch("cases").first(2).each { |entry| entry.fetch("deviceType")["name"] = "/Users/alice/private/device" }'
refresh_matrix_digest
expect_failure malicious-matrix-text "unsafe serialized metadata"
! /usr/bin/grep -Fq '/Users/alice/private/device' "$scratch/malicious-matrix-text.stderr" || {
  echo "personal path appeared in matrix rejection diagnostic" >&2; exit 1;
}

prepare_fixture stale-candidate
printf '%s\n' stale >"$(dirname "$packet")/.visual-packet-candidate-stale"
/bin/chmod 0400 "$(dirname "$packet")/.visual-packet-candidate-stale"
run_builder >/dev/null
[[ ! -e "$(dirname "$packet")/.visual-packet-candidate-stale" ]] || {
  echo "owned stale visual packet candidate was not recovered" >&2; exit 1;
}

prepare_fixture unsafe-stale-candidate
/bin/ln -s "$repo/docs/base.md" "$(dirname "$packet")/.visual-packet-candidate-unsafe"
expect_failure unsafe-stale-candidate "interrupted publication candidate is unsafe"
[[ -L "$(dirname "$packet")/.visual-packet-candidate-unsafe" ]] || {
  echo "unsafe stale candidate was destructively removed" >&2; exit 1;
}

prepare_fixture invalid-png
printf '%s\n' 'not-a-png' >"$(dirname "$draft")/ipad-ja/settings-open.png"
expect_failure invalid-png "screenshot is not a PNG"

prepare_fixture duplicate-image
/bin/cp "$(dirname "$draft")/iphone-en/screenshot.png" "$(dirname "$draft")/iphone-en/duplicate.png"
expect_failure duplicate-image "duplicate screenshot bytes"

prepare_fixture incomplete-visual-attestation
run_builder >/dev/null
write_visual_result
mutate_json "$(dirname "$draft")/visual-result.json" 'document.fetch("cases").fetch(0).fetch("images").pop'
expect_finalize_failure incomplete-visual-attestation "visual result image attestations do not match visual packet"

prepare_fixture wrong-visual-packet-digest
run_builder >/dev/null
write_visual_result
mutate_json "$(dirname "$draft")/visual-result.json" 'document.fetch("visualPacket")["digest"] = "sha256:" + "0" * 64'
expect_finalize_failure wrong-visual-packet-digest "visual packet digest mismatch"

prepare_fixture changes-requested-visual-result
run_builder >/dev/null
write_visual_result
mutate_json "$(dirname "$draft")/visual-result.json" '
  finding = "case=iphone-en; image=iphone-en/screenshot.png; check=overlap; finding=visible overlap; requiredChange=remove the overlap"
  document["status"] = "changes-requested"
  document.fetch("cases").fetch(0)["status"] = "changes-requested"
  document.fetch("cases").fetch(0)["findings"] = [finding]
  document["findings"] = [finding]
'
expect_finalize_failure changes-requested-visual-result "visual result is not approved"

prepare_fixture changed-additional-image
run_builder >/dev/null
write_visual_result
printf '%s\n' changed >"$(dirname "$draft")/iphone-en/settings-open.png"
expect_finalize_failure changed-additional-image "reviewed image digest does not match current bytes"

prepare_fixture added-image-after-review
run_builder >/dev/null
write_visual_result
write_distinct_png "$(dirname "$draft")/iphone-en/screenshot.png" "$(dirname "$draft")/iphone-en/late-state.png" late-state
expect_finalize_failure added-image-after-review "reviewed image set does not match current case files"

prepare_fixture collision
printf '%s\n' 'existing-winner' >"$packet"
if run_builder >"$scratch/collision.stdout" 2>"$scratch/collision.stderr"; then
  echo "visual packet builder overwrote an existing packet" >&2
  exit 1
fi
/usr/bin/grep -Fq 'canonical visual packet already exists' "$scratch/collision.stderr"
[[ "$(/bin/cat "$packet")" == 'existing-winner' ]] || { echo "collision changed existing packet" >&2; exit 1; }

echo "visual review packet tests passed"
