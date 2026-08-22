#!/usr/bin/env bash
set -euo pipefail

source_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
builder="$source_repo/tools/visual-review-packet.sh"
scratch="$(mktemp -d -t ios-visual-packet.XXXXXX)"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT

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

prepare_fixture() {
  local label="$1"
  repo="$scratch/$label/repository"
  /bin/mkdir -p "$repo/docs"
  repo="$(cd "$repo" && pwd -P)"
  /usr/bin/git -C "$repo" init -q
  /usr/bin/git -C "$repo" config user.name 'Visual Packet Test'
  /usr/bin/git -C "$repo" config user.email 'visual-packet@example.invalid'
  printf '%s\n' '.artifacts/' >"$repo/.gitignore"
  printf '%s\n' '# Base' >"$repo/docs/base.md"
  /usr/bin/git -C "$repo" add -- .gitignore docs/base.md
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

  CONTRACT_DIGEST="$(digest "$contract")" MATRIX_DIGEST="$(digest "$matrix")" \
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
  "build" => {"status" => "passed", "scheme" => "TemplateApp", "warningsAdded" => 0, "project" => {"path" => "TemplateApp.xcodeproj", "digest" => "sha256:" + "1" * 64}, "sourceTree" => {"headSha" => head, "digest" => "sha256:" + "2" * 64, "projectPath" => "TemplateApp.xcodeproj"}},
  "tests" => {"status" => "passed", "passed" => 1, "failed" => 0, "skipped" => 0},
  "cases" => case_rows,
  "acceptanceEvidence" => [
    {"id" => "AC-1", "evidence" => ["stage:build", "stage:unit-tests", "case:iphone-en", "case:iphone-ja", "case:ipad-en", "case:ipad-ja"]},
    {"id" => "AC-2", "evidence" => ["stage:build"]}
  ],
  "workspaceArtifacts" => {
    "derivedDataPath" => "/tmp/ios-template-verify/test/issue-42/#{head}/Attempts/attempt-fixture/DerivedData",
    "buildResultBundlePath" => "/tmp/ios-template-verify/test/issue-42/#{head}/Attempts/attempt-fixture/Build.xcresult",
    "testResultBundlePath" => "/tmp/ios-template-verify/test/issue-42/#{head}/Attempts/attempt-fixture/Tests.xcresult"
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

prepare_fixture invalid-png
printf '%s\n' 'not-a-png' >"$(dirname "$draft")/ipad-ja/settings-open.png"
expect_failure invalid-png "screenshot is not a PNG"

prepare_fixture duplicate-image
/bin/cp "$(dirname "$draft")/iphone-en/screenshot.png" "$(dirname "$draft")/iphone-en/duplicate.png"
expect_failure duplicate-image "duplicate screenshot bytes"

prepare_fixture collision
printf '%s\n' 'existing-winner' >"$packet"
if run_builder >"$scratch/collision.stdout" 2>"$scratch/collision.stderr"; then
  echo "visual packet builder overwrote an existing packet" >&2
  exit 1
fi
/usr/bin/grep -Fq 'canonical visual packet already exists' "$scratch/collision.stderr"
[[ "$(/bin/cat "$packet")" == 'existing-winner' ]] || { echo "collision changed existing packet" >&2; exit 1; }

echo "visual review packet tests passed"
